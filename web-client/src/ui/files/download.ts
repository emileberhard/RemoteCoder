import { basename } from "../formatting";

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

export async function downloadFile(hostId: string, path: string, cwd: string) {
  const blob = await readHostFile(hostId, path, cwd, new AbortController().signal, 1024 * 1024 * 1024);
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = basename(path);
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
