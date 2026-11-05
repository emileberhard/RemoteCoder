const header = "Attached files (uploaded to this host; use these absolute paths):";

export function appendAttachedFiles(body: string, paths: string[]) {
  return paths.length
    ? `${body ? `${body}\n\n` : ""}${header}\n${paths.map((path) => `- ${path}`).join("\n")}`
    : body;
}

export function parseAttachedFiles(text: string) {
  const index = text.lastIndexOf(`${header}\n`);
  if (index < 0 || (index > 0 && text.slice(index - 2, index) !== "\n\n")) return { body: text, paths: [] };
  const lines = text.slice(index + header.length + 1).split("\n");
  if (!lines.length || lines.some((line) => !line.startsWith("- /") || line.length <= 3))
    return { body: text, paths: [] };
  return { body: index ? text.slice(0, index - 2) : "", paths: lines.map((line) => line.slice(2)) };
}
