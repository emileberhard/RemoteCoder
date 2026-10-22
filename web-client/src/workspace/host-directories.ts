import { type Rpc, RpcError } from "../gateway";
import { array, object, string } from "../protocol/boundary";
import { failure, type Load } from "./load-state";

export type DirectoryListing = { path: string; childNames: readonly string[] };
export type DirectoryFavorites = { revision: number; paths: readonly string[] };
type Change = { op: "add" | "remove"; path: string };
const limit = 100;

function absolutePath(value: unknown): string {
  const path = string(value, "directory path");
  if (!path.startsWith("/") || new TextEncoder().encode(path).length > 1024 || /\p{Cc}/u.test(path))
    throw new Error("A directory path must be absolute, at most 1024 bytes and free of control characters");
  return path;
}

function favorites(value: unknown): DirectoryFavorites {
  const result = object(value);
  if (!Number.isSafeInteger(result.revision) || Number(result.revision) < 0)
    throw new Error("Invalid directory favorites revision");
  const paths = array(result.paths, limit).map(absolutePath);
  if (new Set(paths).size !== paths.length) throw new Error("Duplicate directory favorite");
  return { revision: Number(result.revision), paths };
}

export class HostDirectories {
  private readonly controller = new AbortController();
  private acknowledged?: DirectoryFavorites;
  private pending: Change[] = [];
  private syncing?: Promise<void>;
  private readRequested = false;
  private acknowledgedGeneration = 0;
  private homeTask?: Promise<string>;
  private homeState: Load<string> = { status: "unread" };
  private syncState: Load<DirectoryFavorites> = { status: "unread" };
  private persistenceError?: string;
  private readonly storageKey: string;

  constructor(
    readonly hostId: string,
    private readonly rpc: Rpc,
    private readonly storage: Storage | undefined,
    private readonly publish: () => void,
  ) {
    this.storageKey = `remotecoder.directoryFavorites.${hostId}`;
    try {
      const stored = storage?.getItem(this.storageKey);
      if (stored) {
        if (stored.length > 256 * 1024) throw new Error("Directory favorites cache exceeds its size limit");
        const value = object(JSON.parse(stored));
        this.acknowledged = value.acknowledged == null ? undefined : favorites(value.acknowledged);
        this.pending = array(value.pending, limit).map((entry) => {
          const change = object(entry);
          if (change.op !== "add" && change.op !== "remove") throw new Error("Invalid favorite change");
          return { op: change.op, path: absolutePath(change.path) };
        });
      }
    } catch (error) {
      this.acknowledged = undefined;
      this.pending = [];
      this.persistenceError = failure(error);
    }
  }

  get home() {
    return this.homeState;
  }
  get favoritesState() {
    return this.syncState;
  }
  get cacheError() {
    return this.persistenceError;
  }
  get favorites(): readonly string[] {
    let paths = [...(this.acknowledged?.paths ?? [])];
    for (const change of this.pending) {
      if (change.op === "remove") paths = paths.filter((path) => path !== change.path);
      else if (!paths.includes(change.path)) paths.unshift(change.path);
    }
    return paths;
  }

  toggleFavorite(path: string) {
    this.record({ op: this.favorites.includes(path) ? "remove" : "add", path });
  }

  removeFavorite(path: string) {
    this.record({ op: "remove", path });
  }

  private record(change: Change) {
    this.controller.signal.throwIfAborted();
    absolutePath(change.path);
    if (this.pending.length >= limit) throw new Error("One hundred favorite changes already await the host");
    this.pending.push(change);
    this.persist();
    this.publish();
    void this.startSync();
  }

  receiveFavorites(value: unknown) {
    if (this.controller.signal.aborted) return;
    this.receive(favorites(value));
    this.persist();
    this.publish();
  }

  private receive(value: DirectoryFavorites) {
    if (this.acknowledged && this.acknowledged.revision > value.revision) return;
    this.acknowledged = value;
    this.acknowledgedGeneration++;
  }

  syncFavorites(): Promise<void> {
    if (this.controller.signal.aborted) return Promise.resolve();
    this.readRequested = true;
    return this.startSync();
  }

  private startSync(): Promise<void> {
    if (this.syncing) return this.syncing;
    this.syncing = Promise.resolve().then(() => this.runSync());
    return this.syncing;
  }

  private async runSync(): Promise<void> {
    const signal = this.controller.signal;
    try {
      if (signal.aborted) return;
      this.syncState = { status: "loading" };
      this.publish();
      while (!signal.aborted) {
        if (this.readRequested) {
          this.readRequested = false;
          const generation = this.acknowledgedGeneration;
          try {
            const value = favorites(await this.rpc.call("directory/favorites/read", {}, { signal }));
            if (signal.aborted) return;
            if (generation === this.acknowledgedGeneration) {
              this.acknowledged = value;
              this.acknowledgedGeneration++;
            } else this.receive(value);
            this.persist();
          } catch (error) {
            if (signal.aborted) return;
            this.readRequested = true;
            this.syncState = { status: "failed", error: failure(error) };
            this.publish();
            return;
          }
        }
        const batch = this.pending.slice(0, limit);
        if (!batch.length) {
          if (this.acknowledged) this.syncState = { status: "ready", value: this.acknowledged };
          this.publish();
          return;
        }
        try {
          const value = favorites(
            await this.rpc.call("directory/favorites/update", { changes: batch }, { signal }),
          );
          if (signal.aborted) return;
          this.pending.splice(0, batch.length);
          this.receive(value);
          this.persist();
          this.publish();
        } catch (error) {
          if (signal.aborted) return;
          if (error instanceof RpcError && error.code === -32602) {
            this.pending.splice(0, batch.length);
            this.readRequested = true;
            this.persist();
            this.publish();
          } else {
            this.syncState = { status: "failed", error: failure(error) };
            this.publish();
            return;
          }
        }
      }
    } finally {
      this.syncing = undefined;
      if (
        !signal.aborted &&
        this.syncState.status !== "failed" &&
        (this.readRequested || this.pending.length)
      )
        await this.startSync();
    }
  }

  private persist() {
    try {
      this.storage?.setItem(
        this.storageKey,
        JSON.stringify({ acknowledged: this.acknowledged, pending: this.pending }),
      );
      this.persistenceError = undefined;
    } catch (error) {
      this.persistenceError = failure(error);
    }
  }

  resolveHomePath(): Promise<string> {
    this.controller.signal.throwIfAborted();
    if (this.homeState.status === "ready") return Promise.resolve(this.homeState.value);
    if (this.homeTask) return this.homeTask;
    this.homeState = { status: "loading" };
    const task = Promise.resolve().then(async () => {
      try {
        this.controller.signal.throwIfAborted();
        const result = object(await this.rpc.call("host/info", {}, { signal: this.controller.signal }));
        this.controller.signal.throwIfAborted();
        const path = absolutePath(result.homeDirectory);
        this.homeState = { status: "ready", value: path };
        this.publish();
        return path;
      } catch (error) {
        if (!this.controller.signal.aborted) {
          this.homeState = { status: "failed", error: failure(error) };
          this.publish();
        }
        throw error;
      } finally {
        if (this.homeTask === task) this.homeTask = undefined;
      }
    });
    this.homeTask = task;
    this.publish();
    return task;
  }

  async expandedPath(path: string): Promise<string> {
    this.controller.signal.throwIfAborted();
    if (path === "~") return this.resolveHomePath();
    if (path.startsWith("~/")) return absolutePath(`${await this.resolveHomePath()}/${path.slice(2)}`);
    return absolutePath(path);
  }

  async list(path: string, signal?: AbortSignal): Promise<DirectoryListing> {
    const combined = signal ? AbortSignal.any([this.controller.signal, signal]) : this.controller.signal;
    combined.throwIfAborted();
    const expanded = await this.expandedPath(path);
    combined.throwIfAborted();
    const result = object(await this.rpc.call("fs/readDirectory", { path: expanded }, { signal: combined }));
    combined.throwIfAborted();
    const childNames = array(result.entries, 2000)
      .map(object)
      .filter((entry) => entry.isDirectory === true)
      .map((entry) => string(entry.fileName))
      .filter((name) => !name.startsWith("."));
    if (childNames.some((name) => !name || name.includes("/") || /\p{Cc}/u.test(name)))
      throw new Error("Gateway sent an invalid directory name");
    return {
      path: expanded,
      childNames: [...new Set(childNames)].sort((a, b) =>
        a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }),
      ),
    };
  }

  dispose() {
    this.controller.abort();
  }
}
