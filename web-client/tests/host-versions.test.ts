import { expect, test } from "bun:test";
import { HostServices } from "../src/workspace/host-services";
import { HostVersions } from "../src/workspace/host-versions";
import { deferred, host } from "./fixtures/workspace";

function hosts(ids: string[]) {
  const services = new HostServices(undefined, undefined, {
    event() {},
    disconnected() {},
    async restore() {},
    retiring() {},
    canRetire: () => true,
    selectedTarget: () => undefined,
    protectedAddresses: () => [],
    syncPreferences() {},
    catalogReady() {},
    publish() {},
    report() {},
  });
  services.configure(ids.map(host));
  return services;
}
test("physical hosts keep independent gateway version coverage without reading usage", async () => {
  const services = hosts(["mini", "book", "offline"]);
  const paths: string[] = [];
  const versions = new HostVersions(
    () => services.snapshot,
    () => {},
    async (path) => {
      paths.push(path);
      if (path.includes("offline")) throw new Error("Host is offline");
      return path.includes("book")
        ? { version: "dev", commit: null }
        : { version: "3.64.0", commit: "a".repeat(40), modified: false };
    },
  );
  versions.reconcile();
  expect(versions.read("mini").status).toBe("unread");
  await versions.refresh();
  expect(versions.read("mini")).toEqual({
    status: "ready",
    value: { version: "3.64.0", commit: "a".repeat(40), modified: false },
  });
  expect(versions.read("book")).toEqual({ status: "ready", value: { version: "dev", commit: null } });
  expect(versions.read("offline")).toEqual({ status: "failed", error: "Host is offline" });
  expect(versions.read("unknown").status).toBe("unread");
  expect(paths.sort()).toEqual([
    "/api/hosts/book/version",
    "/api/hosts/mini/version",
    "/api/hosts/offline/version",
  ]);
  versions.dispose();
  services.dispose();
});
test("HTTP concurrency is bounded to three and overlapping refreshes coalesce", async () => {
  const services = hosts(["a", "b", "c", "d"]);
  const gate = deferred<void>();
  let active = 0;
  let maximum = 0;
  let reads = 0;
  const versions = new HostVersions(
    () => services.snapshot,
    () => {},
    async () => {
      reads++;
      active++;
      maximum = Math.max(maximum, active);
      await gate.promise;
      active--;
      return { version: "dev", commit: null };
    },
  );
  const first = versions.refresh();
  const second = versions.refresh();
  expect(versions.read("a").status).toBe("loading");
  expect(versions.read("d").status).toBe("unread");
  gate.resolve();
  await Promise.all([first, second]);
  expect(reads).toBe(4);
  expect(maximum).toBe(3);
  expect(versions.read("d").status).toBe("ready");
  versions.dispose();
  services.dispose();
});
test("host replacement aborts old reads and fences late versions before refreshing its replacement", async () => {
  const services = hosts(["mini"]);
  const gate = deferred<unknown>();
  let reads = 0;
  let oldSignal: AbortSignal | null | undefined;
  const versions = new HostVersions(
    () => services.snapshot,
    () => {},
    async (_path, init) => {
      if (++reads === 1) {
        oldSignal = init?.signal;
        return gate.promise;
      }
      return { version: "dev", commit: "b".repeat(40), modified: true };
    },
  );
  const old = versions.refresh();
  services.configure([{ ...host("mini"), url: "https://replacement.example" }]);
  versions.reconcile();
  expect(oldSignal?.aborted).toBe(true);
  expect(versions.read("mini").status).toBe("unread");
  const replacement = versions.refresh();
  gate.resolve({ version: "dev", commit: "a".repeat(40), modified: false });
  await Promise.all([old, replacement]);
  expect(versions.read("mini")).toEqual({
    status: "ready",
    value: { version: "dev", commit: "b".repeat(40), modified: true },
  });
  versions.dispose();
  services.dispose();
});
test("malformed version responses fail their own read and disposal aborts pending transport", async () => {
  const services = hosts(["mini"]);
  const versions = new HostVersions(
    () => services.snapshot,
    () => {},
    async () => ({ version: "", commit: 123 }),
  );
  await versions.refresh();
  expect(versions.read("mini").status).toBe("failed");
  versions.dispose();
  const gate = deferred<unknown>();
  let signal: AbortSignal | null | undefined;
  let publications = 0;
  const pending = new HostVersions(
    () => services.snapshot,
    () => {
      publications++;
    },
    async (_path, init) => {
      signal = init?.signal;
      return gate.promise;
    },
  );
  const task = pending.refresh();
  pending.dispose();
  expect(signal?.aborted).toBe(true);
  const beforeLate = publications;
  gate.resolve({ version: "dev", commit: null });
  await task;
  expect(publications).toBe(beforeLate);
  expect(pending.read("mini").status).toBe("unread");
  services.dispose();
});

test("gateway build identity preserves optional native source fields and validates release provenance", async () => {
  const services = hosts(["mini"]);
  let response: unknown = { version: "dev" };
  const versions = new HostVersions(
    () => services.snapshot,
    () => {},
    async () => response,
  );
  await versions.refresh();
  expect(versions.read("mini")).toEqual({ status: "ready", value: { version: "dev", commit: null } });
  response = { version: "dev", commit: "unrecorded", modified: true };
  await versions.refresh();
  expect(versions.read("mini")).toEqual({
    status: "ready",
    value: { version: "dev", commit: null, modified: true },
  });
  for (const invalid of [
    { version: "3.64.0" },
    { version: "3.64.0", commit: "a".repeat(40) },
    { version: "3.64.0", commit: "a".repeat(40), modified: true },
    { version: "03.64.0", commit: "a".repeat(40), modified: false },
    { version: "3.1000.0", commit: "a".repeat(40), modified: false },
    { version: "dev", modified: "unknown" },
  ]) {
    response = invalid;
    await versions.refresh();
    expect(versions.read("mini").status).toBe("failed");
  }
  versions.dispose();
  services.dispose();
});
