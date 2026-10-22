import { condensedPath } from "./working-directory-path";
export type FavoriteFolder = Readonly<{
  id: string;
  hostId: string;
  path: string;
  hostName: string;
  showsHostLabel: boolean;
  title: string;
  displayPath: string;
}>;
export function favoriteFolders(
  hosts: readonly Readonly<{
    id: string;
    name: string;
    paths: readonly string[];
    homePath: string | undefined;
  }>[],
): readonly FavoriteFolder[] {
  return hosts.flatMap((host) => {
    const displayPaths = host.paths.map((path) => condensedPath(path, host.homePath));
    const names = host.paths.map((path, index) =>
      displayPaths[index] === "~" ? "Home" : (path.split("/").filter(Boolean).at(-1) ?? path),
    );
    const repeated = new Set(names.filter((name, index) => names.indexOf(name) !== index));
    return host.paths.map((path, index) => ({
      id: JSON.stringify([host.id, path]),
      hostId: host.id,
      path,
      hostName: host.name,
      showsHostLabel: hosts.length > 1,
      title: repeated.has(names[index] ?? "") ? (displayPaths[index] ?? path) : (names[index] ?? path),
      displayPath: displayPaths[index] ?? path,
    }));
  });
}
