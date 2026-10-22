import type { DirectoryListing, HostDirectories } from "./host-directories";
import { failure, type Load } from "./load-state";

export type DirectoryItem = {
  path: string;
  name: string;
  isExpanded: boolean;
  children: Load<readonly DirectoryItem[]>;
};
type Node = { expanded: boolean; children: Load<readonly string[]> };
export type DirectoryRow = { item: DirectoryItem; level: number };

export class DirectoryPickerModel {
  private readonly nodes = new Map<string, Node>();
  private readonly loads = new Map<string, AbortController>();
  private selection: string | undefined;
  private selectionError?: string;
  private disposed = false;

  constructor(
    readonly directories: HostDirectories,
    currentWorkingDirectory: string | undefined,
    private readonly publish: () => void,
  ) {
    this.selection = currentWorkingDirectory;
    this.nodes.set("~", { expanded: true, children: { status: "unread" } });
  }
  get hostId() {
    return this.directories.hostId;
  }
  get selectedPath() {
    return this.selection;
  }
  get errorMessage() {
    return this.selectionError;
  }
  get root(): DirectoryItem {
    return this.item("~");
  }
  visibleRows(): DirectoryRow[] {
    const rows: DirectoryRow[] = [];
    const visit = (item: DirectoryItem, level: number) => {
      rows.push({ item, level });
      if (item.isExpanded && item.children.status === "ready")
        for (const child of item.children.value) visit(child, item.path === "~" ? 0 : level + 1);
    };
    visit(this.root, 0);
    return rows;
  }
  private item(path: string): DirectoryItem {
    const node = this.nodes.get(path);
    if (!node) throw new Error("Directory tree node is unavailable");
    return {
      path,
      name: path === "~" ? "Home" : (path.split("/").filter(Boolean).at(-1) ?? path),
      isExpanded: node.expanded,
      children:
        node.children.status === "ready"
          ? { status: "ready", value: node.children.value.map((child) => this.item(child)) }
          : { ...node.children },
    };
  }
  async loadInitialChildren() {
    if (this.disposed) return;
    if (this.nodes.get("~")?.children.status !== "ready") await this.load("~");
  }
  isFavorite(path: string) {
    return this.directories.favorites.includes(path);
  }
  async toggleFavorite(path: string) {
    if (this.disposed || path === "~") return;
    const expanded = await this.directories.expandedPath(path);
    if (!this.disposed) this.directories.toggleFavorite(expanded);
  }
  async selectDirectory(path: string): Promise<string> {
    try {
      if (this.disposed) throw new DOMException("Directory picker closed", "AbortError");
      const expanded = await this.directories.expandedPath(path);
      if (this.disposed) throw new DOMException("Directory picker closed", "AbortError");
      this.selection = expanded;
      this.selectionError = undefined;
      this.publish();
      return expanded;
    } catch (error) {
      if (!this.disposed) {
        this.selectionError = failure(error);
        this.publish();
      }
      throw error;
    }
  }
  async toggleExpansion(path: string) {
    if (this.disposed || path === "~") return;
    const node = this.nodes.get(path);
    if (!node) return;
    node.expanded = !node.expanded;
    if (!node.expanded) {
      this.loads.get(path)?.abort();
      this.loads.delete(path);
      if (node.children.status === "loading") node.children = { status: "unread" };
      this.publish();
      return;
    }
    this.publish();
    if (node.children.status !== "ready") await this.load(path);
  }
  private async load(path: string) {
    const node = this.nodes.get(path);
    if (!node || this.disposed || this.loads.has(path)) return;
    if (this.loads.size >= 8 || path.split("/").length > 64) {
      node.children = {
        status: "failed",
        error: "Directory loading limit reached. Try again after other folders finish.",
      };
      this.publish();
      return;
    }
    const controller = new AbortController();
    this.loads.set(path, controller);
    node.children = { status: "loading" };
    this.publish();
    try {
      const listing = await this.directories.list(path, controller.signal);
      if (controller.signal.aborted || this.disposed || this.loads.get(path) !== controller) return;
      this.installChildren(path, listing);
    } catch (error) {
      if (controller.signal.aborted || this.disposed || this.loads.get(path) !== controller) return;
      node.children = { status: "failed", error: failure(error) };
    } finally {
      if (this.loads.get(path) === controller) {
        this.loads.delete(path);
        if (!this.disposed) this.publish();
      }
    }
  }
  private installChildren(path: string, listing: DirectoryListing) {
    const node = this.nodes.get(path);
    if (!node) return;
    const paths = listing.childNames.map((name) => `${listing.path === "/" ? "" : listing.path}/${name}`);
    const added = paths.filter((child) => !this.nodes.has(child));
    if (this.nodes.size + added.length > 4000)
      throw new Error("Directory tree limit reached. Reopen the picker to browse another branch.");
    for (const child of added) this.nodes.set(child, { expanded: false, children: { status: "unread" } });
    node.children = { status: "ready", value: paths };
  }
  private cancelPendingLoads() {
    for (const [path, controller] of this.loads) {
      controller.abort();
      const node = this.nodes.get(path);
      if (node?.children.status === "loading") node.children = { status: "unread" };
    }
    this.loads.clear();
  }
  dispose() {
    this.disposed = true;
    this.cancelPendingLoads();
  }
}
