import { record, requiredString } from "./contracts";

export type BrowserUploadedFile = { path: string; bytes: number; sha256: string };
export type BrowserUploadOptions = {
  fetch?: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
};

export const browserUploadLimit = 50 * 1024 * 1024;
let activeUploads = 0;

async function uploadReply(response: Response): Promise<Record<string, unknown>> {
  const limit = 64 * 1024;
  const declared = response.headers.get("content-length");
  if (declared && Number(declared) > limit) {
    await response.body?.cancel();
    throw new Error("The upload reply exceeds browser capacity");
  }
  if (!response.body) throw new Error("The gateway returned no upload reply");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new Error("The upload reply exceeds browser capacity");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let result: Record<string, unknown>;
  try {
    result = record(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    throw new Error(`The gateway returned an unreadable upload reply (HTTP ${response.status})`);
  }
  if (response.status !== 201) {
    throw new Error(
      typeof result.error === "string" ? result.error : `File upload returned HTTP ${response.status}`,
    );
  }
  return result;
}

export class BrowserUploadService {
  private readonly operations = new Set<AbortController>();
  private retired = false;

  constructor(
    readonly hostId: string,
    private readonly options: BrowserUploadOptions = {},
  ) {
    requiredString(hostId, "upload host");
  }

  async upload(file: File, options: { signal?: AbortSignal } = {}): Promise<BrowserUploadedFile> {
    if (this.retired) throw new Error("The attachment upload service has been retired");
    options.signal?.throwIfAborted();
    if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > browserUploadLimit) {
      throw new Error("Each attachment must be between 1 byte and 50 MiB");
    }
    if (!file.name.trim() || file.name.length > 1024) throw new Error("The attachment filename is invalid");
    if (activeUploads >= 2)
      throw new Error("Two attachment uploads are already active. Try again after one finishes.");
    const controller = new AbortController();
    const cancel = () => controller.abort(options.signal?.reason);
    options.signal?.addEventListener("abort", cancel, { once: true });
    this.operations.add(controller);
    activeUploads += 1;
    try {
      const bytes = await file.arrayBuffer();
      controller.signal.throwIfAborted();
      if (bytes.byteLength !== file.size)
        throw new Error("The selected file changed while it was being read");
      const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
        .map((value) => value.toString(16).padStart(2, "0"))
        .join("");
      controller.signal.throwIfAborted();
      const response = await (this.options.fetch ?? fetch)(
        `/api/hosts/${encodeURIComponent(this.hostId)}/uploads?name=${encodeURIComponent(file.name)}`,
        {
          method: "POST",
          signal: controller.signal,
          headers: { "Content-Type": "application/octet-stream", "X-RemoteCoder-SHA256": digest },
          body: file,
        },
      );
      const result = await uploadReply(response);
      controller.signal.throwIfAborted();
      const path = requiredString(result.path, "uploaded host path");
      if (
        !path.startsWith("/") ||
        /[\0\r\n]/.test(path) ||
        path.split("/").some((part) => part === "." || part === "..")
      ) {
        throw new Error("The gateway returned an invalid uploaded host path");
      }
      if (result.sha256 !== digest || result.bytes !== file.size) {
        throw new Error("The gateway stored a different file than was sent");
      }
      return { path, bytes: file.size, sha256: digest };
    } finally {
      options.signal?.removeEventListener("abort", cancel);
      this.operations.delete(controller);
      activeUploads -= 1;
    }
  }

  dispose(): void {
    this.retired = true;
    for (const operation of this.operations) operation.abort();
  }
}
