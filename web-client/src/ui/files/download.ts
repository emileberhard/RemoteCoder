import { basename } from "../formatting";

export async function downloadFile(hostId: string, path: string, cwd: string) {
  const resolved = path.startsWith("/") ? path : `${cwd.replace(/\/$/, "")}/${path}`;
  const response = await fetch(`/api/hosts/${hostId}/download`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path: resolved }),
  });
  if (!response.ok) {
    const value = await response.json();
    throw new Error(value.error ?? "The host file could not be downloaded");
  }
  const blob = await response.blob();
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = basename(path);
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
