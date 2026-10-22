import { condensedPath } from "../workspace/working-directory-path";
export const basename = (path: string) => path.replace(/\/$/, "").split("/").at(-1) || path;
export const directoryTitle = (path: string, home: string | undefined) => {
  const display = condensedPath(path, home);
  return display === "~" ? "Home" : display;
};
export function age(seconds: number) {
  const minutes = Math.floor((Date.now() / 1000 - seconds) / 60);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 60 * 24) return `${Math.floor(minutes / 60)}h`;
  if (minutes < 60 * 24 * 7) return `${Math.floor(minutes / (60 * 24))}d`;
  if (minutes < 60 * 24 * 365) return `${Math.floor(minutes / (60 * 24 * 7))}w`;
  return `${Math.floor(minutes / (60 * 24 * 365))}y`;
}
export const inputText = (input: { type: string; text?: string }[]) =>
  input
    .filter((entry) => entry.type === "text")
    .map((entry) => entry.text)
    .join("\n\n");
export const effortLabel = (effort: string) =>
  !effort ? "Auto" : effort === "xhigh" ? "Extra high" : effort.charAt(0).toUpperCase() + effort.slice(1);
