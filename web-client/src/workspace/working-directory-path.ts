export function condensedPath(path: string, home: string | undefined) {
  const root = home?.replace(/\/$/, "");
  return root && (path === root || path.startsWith(`${root}/`)) ? `~${path.slice(root.length)}` : path;
}
