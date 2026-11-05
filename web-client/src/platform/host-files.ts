export class HostFileBusy extends Error {
  constructor(
    message: string,
    readonly retryAfterMs: number | undefined,
  ) {
    super(message);
  }
}

export async function readHostFile(
  hostId: string,
  path: string,
  cwd: string,
  signal: AbortSignal,
  maximumBytes: number,
) {
  const resolved = path.startsWith("/") ? path : `${cwd.replace(/\/$/, "")}/${path}`;
  const response = await fetch(`/api/hosts/${encodeURIComponent(hostId)}/download`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path: resolved }),
    signal,
  });
  if (!response.ok) {
    const value = await response.json();
    if (response.status === 429) {
      const header = response.headers.get("Retry-After");
      const delay =
        header === null
          ? undefined
          : /^\d+(\.\d+)?$/.test(header)
            ? Number(header) * 1000
            : Date.parse(header) - Date.now();
      throw new HostFileBusy(
        value.error ?? "The host is busy downloading files",
        delay !== undefined && Number.isFinite(delay) ? Math.max(0, delay) : undefined,
      );
    }
    throw new Error(value.error ?? "The host file could not be downloaded");
  }
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let bytes = 0;
  const reader = response.body?.getReader();
  if (!reader) throw new Error("The host returned no file content");
  try {
    if (Number(response.headers.get("Content-Length")) > maximumBytes)
      throw new Error("The file is too large to preview");
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maximumBytes) throw new Error("The file is too large to preview");
      chunks.push(value);
    }
    return new Blob(chunks, { type: response.headers.get("Content-Type") ?? "" });
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
