import { expect, test } from "bun:test";
import { RpcError } from "../src/gateway";
import { DirectoryPickerModel } from "../src/workspace/directory-picker-model";
import { HostDirectories } from "../src/workspace/host-directories";
import { deferred, Harness, MemoryStorage } from "./fixtures/workspace";

function setup(storage = new MemoryStorage(), hostId = "mini") {
  const rpc = new Harness(() => undefined);
  const directories = new HostDirectories(hostId, rpc, storage, () => undefined);
  return { rpc, directories, storage };
}
const entries = (...names: string[]) => ({
  entries: names.map((fileName) => ({ fileName, isDirectory: true })),
});

test("favorites notifications fence old reads, while an uncontested read accepts a restored host revision", async () => {
  const { rpc, directories } = setup();
  const read = deferred<unknown>();
  rpc.handler = () => read.promise;
  directories.receiveFavorites({ revision: 10, paths: ["/before"] });
  const sync = directories.syncFavorites();
  await Promise.resolve();
  directories.receiveFavorites({ revision: 11, paths: ["/notification"] });
  read.resolve({ revision: 9, paths: ["/stale"] });
  await sync;
  expect(directories.favorites).toEqual(["/notification"]);
  rpc.handler = () => ({ revision: 1, paths: ["/restored"] });
  await directories.syncFavorites();
  expect(directories.favorites).toEqual(["/restored"]);
  directories.dispose();
});

test("acknowledging an update preserves edits queued during the write and their ordering", async () => {
  const { rpc, directories } = setup();
  const firstWrite = deferred<unknown>();
  const writing = deferred<void>();
  let writes = 0;
  rpc.handler = (method) => {
    if (method === "directory/favorites/read") return { revision: 1, paths: ["/existing"] };
    if (++writes === 1) {
      writing.resolve();
      return firstWrite.promise;
    }
    return { revision: 3, paths: ["/second", "/existing"] };
  };
  await directories.syncFavorites();
  directories.toggleFavorite("/first");
  await writing.promise;
  directories.toggleFavorite("/second");
  directories.removeFavorite("/first");
  expect(directories.favorites).toEqual(["/second", "/existing"]);
  firstWrite.resolve({ revision: 2, paths: ["/first", "/existing"] });
  await directories.syncFavorites();
  expect(directories.favorites).toEqual(["/second", "/existing"]);
  expect(directories.favoritesState.status).toBe("ready");
  directories.dispose();
});

test("offline edits survive recreation per physical host and reject unsafe or excess changes", async () => {
  const { rpc, directories, storage } = setup();
  rpc.handler = () => Promise.reject(new Error("offline"));
  for (const path of ["relative", "/new\nline", `/${"å".repeat(600)}`])
    expect(() => directories.toggleFavorite(path)).toThrow();
  for (let index = 0; index < 100; index++) directories.toggleFavorite(`/folder${index}`);
  expect(() => directories.toggleFavorite("/overflow")).toThrow();
  await directories.syncFavorites();
  expect(directories.favoritesState.status).toBe("failed");
  directories.dispose();
  const restored = setup(storage);
  const otherHost = setup(storage, "macbook");
  expect(restored.directories.favorites).toHaveLength(100);
  expect(restored.directories.favorites[0]).toBe("/folder99");
  expect(otherHost.directories.favorites).toEqual([]);
  restored.rpc.handler = (method) =>
    method === "directory/favorites/read"
      ? { revision: 0, paths: [] }
      : { revision: 1, paths: ["/from-host"] };
  await restored.directories.syncFavorites();
  expect(restored.directories.favorites).toEqual(["/from-host"]);
  restored.directories.dispose();
  otherHost.directories.dispose();
});

test("server-rejected batches are discarded before authoritative readback", async () => {
  const { rpc, directories } = setup();
  rpc.handler = (method) =>
    method === "directory/favorites/update"
      ? Promise.reject(new RpcError("invalid", -32602))
      : { revision: 7, paths: ["/server"] };
  directories.toggleFavorite("/invalid-on-server");
  await directories.syncFavorites();
  expect(directories.favorites).toEqual(["/server"]);
  expect(directories.favoritesState.status).toBe("ready");
  directories.dispose();
});

test("home resolution coalesces, listing validates remote child names, retirement fences late home", async () => {
  const { rpc, directories } = setup();
  rpc.handler = (method) =>
    method === "host/info" ? { homeDirectory: "/Users/test" } : entries("folder10", ".hidden", "folder2");
  const [one, two] = await Promise.all([directories.list("~"), directories.list("~/child")]);
  expect(one).toEqual({ path: "/Users/test", childNames: ["folder2", "folder10"] });
  expect(two.path).toBe("/Users/test/child");
  expect(rpc.calls.filter((call) => call.method === "host/info")).toHaveLength(1);
  rpc.handler = () => entries("child/escape");
  await expect(directories.list("/safe")).rejects.toThrow("invalid directory name");
  directories.dispose();
  const late = setup();
  const response = deferred<unknown>();
  late.rpc.handler = () => response.promise;
  const home = late.directories.resolveHomePath();
  await Promise.resolve();
  late.directories.dispose();
  response.resolve({ homeDirectory: "/late" });
  await expect(home).rejects.toThrow();
  expect(late.directories.home.status).not.toBe("ready");
});

test("picker retains independent tree branches and distinguishes unread, loading, empty and failed", async () => {
  const { rpc, directories } = setup();
  const pending = deferred<unknown>();
  rpc.handler = (method, params) => {
    if (method === "host/info") return { homeDirectory: "/home" };
    if (params.path === "/home") return entries("a", "b");
    if (params.path === "/home/a") return pending.promise;
    return Promise.reject(new Error("no access"));
  };
  const picker = new DirectoryPickerModel(directories, undefined, () => undefined);
  await picker.loadInitialChildren();
  expect(picker.visibleRows().map(({ item, level }) => [item.path, level])).toEqual([
    ["~", 0],
    ["/home/a", 0],
    ["/home/b", 0],
  ]);
  const a = picker.toggleExpansion("/home/a");
  expect(picker.visibleRows()[1]?.item.children.status).toBe("loading");
  await picker.toggleExpansion("/home/b");
  expect(picker.visibleRows()[2]?.item.children.status).toBe("failed");
  pending.resolve(entries());
  await a;
  expect(picker.visibleRows()[1]?.item.children).toEqual({ status: "ready", value: [] });
  expect(picker.visibleRows()[2]?.item.children.status).toBe("failed");
  picker.dispose();
  directories.dispose();
});

test("a closed picker cannot select a late home resolution", async () => {
  const { rpc, directories } = setup();
  const home = deferred<unknown>();
  rpc.handler = () => home.promise;
  const picker = new DirectoryPickerModel(directories, "/selected", () => undefined);
  const selection = picker.selectDirectory("~");
  await Promise.resolve();
  picker.dispose();
  home.resolve({ homeDirectory: "/late" });
  await expect(selection).rejects.toThrow();
  expect(picker.selectedPath).toBe("/selected");
  directories.dispose();
});

test("retiring a directory owner prevents a late read from publishing or overwriting the cache", async () => {
  const storage = new MemoryStorage();
  const rpc = new Harness(() => undefined);
  let publications = 0;
  const directories = new HostDirectories("mini", rpc, storage, () => publications++);
  directories.receiveFavorites({ revision: 1, paths: ["/cached"] });
  const response = deferred<unknown>();
  rpc.handler = () => response.promise;
  const sync = directories.syncFavorites();
  await Promise.resolve();
  directories.dispose();
  const before = publications;
  response.resolve({ revision: 2, paths: ["/late"] });
  await sync;
  expect(publications).toBe(before);
  expect(directories.favorites).toEqual(["/cached"]);
  const reopened = setup(storage);
  expect(reopened.directories.favorites).toEqual(["/cached"]);
  reopened.directories.dispose();
});

for (const reentrant of [false, true]) {
  test(`favorite edits and rereads arriving as sync finishes are processed (reentrant=${reentrant})`, async () => {
    const rpc = new Harness(() => undefined);
    let reads = 0;
    let queued = false;
    let again: Promise<void> | undefined;
    const directories = new HostDirectories("mini", rpc, new MemoryStorage(), () => {
      if (directories.favoritesState.status !== "ready" || queued) return;
      queued = true;
      const enqueue = () => {
        directories.toggleFavorite("/finishing");
        again = directories.syncFavorites();
      };
      if (reentrant) enqueue();
      else queueMicrotask(enqueue);
    });
    rpc.handler = (method) => {
      if (method === "directory/favorites/read") {
        reads++;
        return { revision: 0, paths: [] };
      }
      return undefined;
    };
    await directories.syncFavorites();
    await again;
    expect(reads).toBe(2);
    expect(rpc.calls.filter((call) => call.method === "directory/favorites/update")).toHaveLength(1);
    expect(directories.favorites).toEqual(["/finishing"]);
    directories.dispose();
  });
}
