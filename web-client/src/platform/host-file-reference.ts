export function hostFileReference(value: string): { path: string; line?: number } | undefined {
  let path: string;
  let fragment: string;
  if (value.startsWith("/") && !value.startsWith("//")) {
    const match = /#L(\d+)(?:C\d+)?(?:-L?\d+)?$/.exec(value);
    path = match ? value.slice(0, match.index) : value;
    fragment = match?.[0] ?? "";
  } else {
    try {
      const url = new URL(value);
      if (url.protocol !== "file:" || (url.hostname && url.hostname !== "localhost")) return;
      path = decodeURIComponent(url.pathname);
      fragment = url.hash;
    } catch {
      return;
    }
  }
  if (!path.startsWith("/") || path.includes("\0")) return;
  const match = /^#L(\d+)(?:C\d+)?(?:-L?\d+)?$/.exec(fragment);
  const line = match ? Number(match[1]) : undefined;
  return { path, ...(line !== undefined && Number.isSafeInteger(line) && line > 0 ? { line } : {}) };
}
