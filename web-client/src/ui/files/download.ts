import { readHostFile } from "../../platform/host-files";
import { basename } from "../formatting";

export async function downloadFile(hostId: string, path: string, cwd: string) {
  const blob = await readHostFile(hostId, path, cwd, new AbortController().signal, 1024 * 1024 * 1024);
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = basename(path);
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
