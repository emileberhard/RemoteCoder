import { expect, jest, test } from "bun:test";
import {
  AccountUsageStore,
  parseClaudeUsageDirectory,
  parseCodexUsageDirectory,
} from "../src/workspace/account-usage-store";
import { HostServices } from "../src/workspace/host-services";
import { deferred, host } from "./fixtures/workspace";

const now = 2_000_000;
const enrollment = "8dc8844a-15b0-4117-9c52-f61246c8012a";
const window = (durationMinutes: number, usedPercent: number, extras = {}) => ({
  id: String(durationMinutes),
  label: "Limit",
  durationMinutes,
  usedPercent,
  resetsAt: now + 10_800,
  model: null,
  ...extras,
});
const account = (extras = {}) => ({
  id: "default-codex",
  provider: "codex",
  generation: 0,
  isDefault: true,
  label: "Subscription",
  enabled: true,
  state: "ready",
  stale: false,
  identity: { key: "shared-identity", email: "person@example.test" },
  observedAt: now,
  windows: [window(10080, 20), window(300, 70)],
  ...extras,
});
const directory = (...accounts: unknown[]) => ({
  schemaVersion: 2,
  refreshing: false,
  accounts,
  retiredClaudeAccountIds: [],
});
const router = (extras = {}) => ({
  automatic: "first",
  preference: null,
  accounts: ["first", "second"].map((id) => ({
    id,
    label: id,
    plan: "max",
    shared: false,
    credential: "ready",
    availability: "available",
    observedAt: now,
    windows: [window(10080, 42), window(300, 70)],
  })),
  ...extras,
});
function hosts(ids = ["mini"], reader?: (hostId: string) => Promise<unknown>) {
  const services = new HostServices(undefined, reader, {
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

test("native weekly and projected five-hour rings keep model limits separate", async () => {
  const services = hosts();
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async () =>
      directory(
        account({
          windows: [window(10080, 99, { id: "fable", model: "Fable" }), window(10080, 20), window(300, 70)],
        }),
      ),
  );
  await store.refresh("codex");
  const usage = store.snapshot(now, { hostId: "mini" }).codex;
  expect(usage.weekly?.remainingPercent).toBe(80);
  expect(usage.account?.rows.find((row) => row.kind === "fable")?.remainingPercent).toBe(1);
  expect(usage.innerRing?.remainingPercent).toBe(30);
  expect(usage.innerRing?.runOutWarning?.leadSeconds).toBeCloseTo(7714.285714);
  expect(usage.innerRing?.runOutWarning?.severity).toBe(1);
  expect(store.snapshot(now + 10_800, { hostId: "mini" }).codex.innerRing).toBeUndefined();
  store.dispose();
  services.dispose();
});

test("five-hour usage alone and model-specific weekly limits never invent an overall weekly allowance", async () => {
  const services = hosts();
  for (const used of [0, 40, 70, 100]) {
    const store = new AccountUsageStore(
      () => services.snapshot,
      () => {},
      async () =>
        directory(account({ windows: [window(300, used), window(10080, 50, { model: "model-only" })] })),
    );
    await store.refresh("codex");
    const usage = store.snapshot(now, { hostId: "mini" }).codex;
    expect(usage.weekly).toBeUndefined();
    expect(usage.fiveHour?.remainingPercent).toBe(100 - used);
    expect(Boolean(usage.innerRing)).toBe(used > 40);
    store.dispose();
  }
  services.dispose();
});

test("verified identities deduplicate across hosts while selection preserves exact enrollment generation", async () => {
  const services = hosts(["mini", "book"]);
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (path) =>
      directory(
        account({
          observedAt: path.includes("book") ? now + 1 : now,
          windows: [window(10080, path.includes("book") ? 60 : 20)],
        }),
        account({
          id: enrollment,
          isDefault: false,
          generation: 3,
          identity: { key: "other" },
          windows: [window(10080, 90)],
        }),
      ),
  );
  await store.refresh("codex");
  const usage = store.snapshot(now, { hostId: "mini" }).codex;
  expect(usage.accounts).toHaveLength(2);
  expect(usage.weekly?.remainingPercent).toBe(40);
  expect(usage.account?.targets).toHaveLength(2);
  expect(
    store.snapshot(now, { hostId: "mini", enrollment: { accountId: enrollment, generation: 3 } }).codex.weekly
      ?.remainingPercent,
  ).toBe(10);
  expect(
    store.snapshot(now, { hostId: "mini", enrollment: { accountId: enrollment, generation: 2 } }).codex
      .account,
  ).toBeUndefined();
  expect(store.snapshot(now, { hostId: "unknown" }).codex.account).toBeUndefined();
  store.dispose();
  services.dispose();
});

test("unknown usage stays absent and failed refresh retains stale observations", async () => {
  const services = hosts();
  let fail = false;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async () => {
      if (fail) throw new Error("offline");
      return directory(account({ windows: [window(10080, 100)] }));
    },
  );
  expect(store.snapshot(now, { hostId: "mini" }).codex.weekly).toBeUndefined();
  await store.refresh("codex");
  expect(store.snapshot(now, { hostId: "mini" }).codex.weekly?.remainingPercent).toBe(0);
  fail = true;
  await store.refresh("codex");
  const failed = store.snapshot(now, { hostId: "mini" }).codex;
  expect(failed.error).toContain("offline");
  expect(failed.weekly?.remainingPercent).toBe(0);
  expect(failed.weekly?.stale).toBe(true);
  store.dispose();
  services.dispose();
});

test("Claude inventories are shared and staleness follows the native 900-second threshold", async () => {
  const services = hosts(["mini", "book"]);
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async () => router(),
  );
  await store.refresh("claude", false);
  const fresh = store.snapshot(now + 900, { hostId: "mini" }).claude;
  expect(fresh.accounts).toHaveLength(2);
  expect(fresh.account?.id).toBe("first");
  expect(fresh.preference).toBeNull();
  expect(fresh.weekly?.remainingPercent).toBe(58);
  expect(fresh.weekly?.stale).toBe(false);
  expect(store.snapshot(now + 901, { hostId: "mini" }).claude.weekly?.stale).toBe(true);
  store.dispose();
  services.dispose();
});

test("uncertain Claude preference writes read back without resubmitting through another host", async () => {
  const services = hosts(["mini", "book"]);
  let preference: string | null = null;
  let writes = 0;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (_path, init) => {
      if (init?.method === "PUT") {
        writes++;
        preference = JSON.parse(String(init.body)).account;
        throw new Error("acknowledgment lost");
      }
      return router({ preference });
    },
  );
  await store.refresh("claude", false);
  await store.setClaudePreference("second");
  expect(store.snapshot(now, undefined).claude.account?.id).toBe("second");
  expect(store.snapshot(now, undefined).claude.error).toBeUndefined();
  expect(writes).toBe(1);
  await store.setClaudePreference(null);
  expect(store.snapshot(now, undefined).claude.account?.id).toBe("first");
  expect(writes).toBe(2);
  store.dispose();
  services.dispose();
});

test("retiring and replacing a physical host fences delayed reads and aborts their transport", async () => {
  const services = hosts();
  const delayed = deferred<unknown>();
  let signal: AbortSignal | null | undefined;
  let reads = 0;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (_path, init) => {
      signal = init?.signal;
      return ++reads === 1 ? delayed.promise : directory(account({ windows: [window(10080, 80)] }));
    },
  );
  const old = store.refresh("codex");
  services.configure([{ ...host("mini"), url: "https://replacement.example" }]);
  store.reconcile();
  expect(signal?.aborted).toBe(true);
  await store.refresh("codex");
  delayed.resolve(directory(account()));
  await old;
  expect(store.snapshot(now, { hostId: "mini" }).codex.weekly?.remainingPercent).toBe(20);
  store.dispose();
  services.dispose();
});

test("malformed usage fails its owning read without presenting zero", async () => {
  const services = hosts();
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async () => directory(account({ windows: [window(10080, Number.NaN)] })),
  );
  await store.refresh("codex");
  const usage = store.snapshot(now, { hostId: "mini" }).codex;
  expect(usage.error).toContain("Invalid account usage");
  expect(usage.weekly).toBeUndefined();
  store.dispose();
  services.dispose();
});

test("foreground refresh owns one 120-second timer, reads both providers, and refreshes immediately after resume", async () => {
  jest.useFakeTimers();
  const services = hosts();
  const paths: string[] = [];
  const claudeMethods: (string | undefined)[] = [];
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (path, init) => {
      paths.push(path);
      if (path.includes("claude")) {
        claudeMethods.push(init?.method);
        return router();
      }
      return directory(account());
    },
  );
  const settle = async () => {
    for (let index = 0; index < 20; index++) await Promise.resolve();
  };
  try {
    store.startForeground();
    store.startForeground();
    await settle();
    expect(paths).toHaveLength(2);
    expect(jest.getTimerCount()).toBe(1);
    jest.advanceTimersByTime(119_999);
    await settle();
    expect(paths).toHaveLength(2);
    jest.advanceTimersByTime(1);
    await settle();
    expect(paths).toHaveLength(4);
    expect(jest.getTimerCount()).toBe(1);
    store.stopForeground();
    expect(jest.getTimerCount()).toBe(0);
    expect(store.snapshot(now, { hostId: "mini" }).codex.weekly?.remainingPercent).toBe(80);
    jest.advanceTimersByTime(240_000);
    await settle();
    expect(paths).toHaveLength(4);
    store.startForeground();
    await settle();
    expect(paths).toHaveLength(6);
    expect(claudeMethods).toHaveLength(3);
    expect(claudeMethods.every((method) => method === undefined)).toBe(true);
    store.dispose();
    expect(jest.getTimerCount()).toBe(0);
  } finally {
    store.dispose();
    services.dispose();
    jest.useRealTimers();
  }
});

test("foreground stop fences pending samples while explicit background reads remain usable", async () => {
  const services = hosts();
  const delayed = deferred<unknown>();
  const signals: AbortSignal[] = [];
  let delayedReads = true;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (path, init) => {
      if (init?.signal) signals.push(init.signal);
      if (delayedReads) return delayed.promise;
      return path.includes("claude")
        ? router({ preference: "second" })
        : directory(account({ windows: [window(10080, 90)] }));
    },
  );
  store.startForeground();
  store.stopForeground();
  expect(signals.every((signal) => signal.aborted)).toBe(true);
  expect(store.snapshot(now, undefined).claude.loading).toBe(false);
  delayedReads = false;
  await Promise.all([store.refresh("codex"), store.refresh("claude", false)]);
  delayed.resolve(directory(account()));
  for (let index = 0; index < 20; index++) await Promise.resolve();
  expect(store.snapshot(now, { hostId: "mini" }).codex.weekly?.remainingPercent).toBe(10);
  expect(store.snapshot(now, undefined).claude.account?.id).toBe("second");
  expect(store.snapshot(now, undefined).claude.error).toBeUndefined();
  store.dispose();
  services.dispose();
});

test("Claude settings use the shared validated inventory and retain uncertain selection readback while hidden", async () => {
  const services = hosts();
  const written = deferred<void>();
  const acknowledgment = deferred<unknown>();
  let preference: string | null = null;
  let writeSignal: AbortSignal | null | undefined;
  let malformed = false;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (path, init) => {
      if (path.includes("preference")) {
        writeSignal = init?.signal;
        preference = JSON.parse(String(init?.body)).account;
        written.resolve();
        return acknowledgment.promise;
      }
      if (!path.includes("claude")) return directory(account());
      return router({
        preference,
        ...(malformed
          ? { accounts: router().accounts.map((account) => ({ ...account, shared: "unknown" })) }
          : {}),
      });
    },
  );
  expect(store.snapshot(now, undefined).claude.status).toBe("unread");
  store.startForeground();
  await store.refresh("claude", false);
  const accountState = store.snapshot(now, undefined).claude.account;
  expect(accountState).toMatchObject({ shared: false, credential: "ready", observedAt: now });
  const selection = store.setClaudePreference("second");
  await written.promise;
  store.stopForeground();
  expect(writeSignal?.aborted).toBe(false);
  acknowledgment.resolve({ invalid: "lost acknowledgment" });
  await selection;
  expect(store.snapshot(now, undefined).claude).toMatchObject({
    preference: "second",
    status: "ready",
    selecting: false,
  });
  expect(store.snapshot(now, undefined).claude.account?.id).toBe("second");
  malformed = true;
  await store.refresh("claude", false);
  expect(store.snapshot(now, undefined).claude.status).toBe("failed");
  expect(store.snapshot(now, undefined).claude.account?.shared).toBe(false);
  expect(store.snapshot(now, undefined).claude.canSelect).toBe(false);
  store.dispose();
  services.dispose();
});

test("unread usage remains absent and invalid usage or duplicate account identities reject the response", () => {
  const unknown = account({ observedAt: undefined, windows: [], stale: true });
  const parsed = parseCodexUsageDirectory("mini", directory(unknown));
  expect(parsed[0]?.observedAt).toBeUndefined();
  expect(parsed[0]?.windows).toEqual([]);
  expect(() => parseCodexUsageDirectory("mini", directory(unknown, unknown))).toThrow(/Duplicate/);
  expect(() => parseCodexUsageDirectory("mini", directory(account({ windows: [window(300, 101)] })))).toThrow(
    "usage",
  );
});

test("routing requires exact account membership", () => {
  const account = {
    id: "personal",
    label: "Personal",
    plan: "pro",
    shared: false,
    credential: "ready",
    availability: "available",
    windows: [],
  };
  expect(
    parseClaudeUsageDirectory({ automatic: "personal", preference: null, accounts: [account] }).preference,
  ).toBeNull();
  expect(() =>
    parseClaudeUsageDirectory({ automatic: "personal", preference: "retired", accounts: [account] }),
  ).toThrow("unavailable account");
  expect(() =>
    parseClaudeUsageDirectory({ automatic: "retired", preference: null, accounts: [account] }),
  ).toThrow("unavailable account");
});

test("context catalogs and usage acknowledge one document and coalesce refreshes", async () => {
  const pending = deferred<unknown>();
  let reads = 0;
  let fail = false;
  let current: unknown;
  const services = hosts(["mini"], async () => {
    reads++;
    if (fail) throw new Error("offline");
    return current ?? pending.promise;
  });
  const store = services.accountUsage;
  const first = services.refreshAccounts("mini");
  const second = store.refresh("codex");
  expect(services.get("mini").accounts.status).toBe("loading");
  pending.resolve(directory(account({ id: enrollment, isDefault: false, generation: 1 })));
  await Promise.all([first, second]);
  expect(reads).toBe(1);
  const catalog = services.get("mini").accounts;
  expect(catalog.status).toBe("ready");
  if (catalog.status !== "ready") throw new Error("Missing acknowledged catalog");
  const usageCatalog = store.readCatalog("mini");
  if (usageCatalog.status !== "ready") throw new Error("Missing usage catalog");
  expect(catalog.value).toBe(usageCatalog.value);
  const target = catalog.value.choices[0]?.target;
  expect(target?.enrollment?.generation).toBe(1);
  expect(store.snapshot(now, target).codex.weekly?.remainingPercent).toBe(80);
  current = directory(
    account({ id: enrollment, isDefault: false, generation: 2, windows: [window(10080, 90)] }),
  );
  await services.refreshAccounts("mini");
  const next = services.get("mini").accounts;
  if (next.status !== "ready") throw new Error("Missing refreshed catalog");
  expect(next.value.choices[0]?.target.enrollment?.generation).toBe(2);
  expect(store.snapshot(now, target).codex.account).toBeUndefined();
  expect(store.snapshot(now, next.value.choices[0]?.target).codex.weekly?.remainingPercent).toBe(10);
  fail = true;
  await services.refreshAccounts("mini");
  expect(services.get("mini").accounts).toEqual({ status: "failed", error: "offline" });
  expect(store.snapshot(now, next.value.choices[0]?.target).codex.weekly).toMatchObject({
    remainingPercent: 10,
    stale: true,
  });
  services.dispose();
  expect(store.readCatalog("mini").status).toBe("unread");
});

test("provider coverage distinguishes unread, empty, loading, and partial host failure", async () => {
  const services = hosts(["mini", "book"]);
  const book = deferred<unknown>();
  let failMini = false;
  let empty = true;
  const store = new AccountUsageStore(
    () => services.snapshot,
    () => {},
    async (path) => {
      if (path.includes("book")) return book.promise;
      if (failMini) throw new Error("mini offline");
      return empty ? directory() : directory(account());
    },
  );
  store.reconcile();
  expect(store.snapshot(now, undefined).codex).toMatchObject({
    status: "unread",
    loading: false,
    accounts: [],
  });
  await store.refreshHost("mini");
  expect(store.snapshot(now, undefined).codex.status).toBe("unread");
  const refreshing = store.refreshHost("book");
  expect(store.snapshot(now, undefined).codex).toMatchObject({ status: "loading", loading: true });
  book.resolve(directory());
  await refreshing;
  expect(store.snapshot(now, undefined).codex).toMatchObject({
    status: "ready",
    loading: false,
    accounts: [],
  });
  empty = false;
  await store.refreshHost("mini");
  expect(store.snapshot(now, { hostId: "mini" }).codex.weekly?.remainingPercent).toBe(80);
  failMini = true;
  await store.refreshHost("mini");
  const failed = store.snapshot(now, { hostId: "mini" }).codex;
  expect(failed.status).toBe("failed");
  expect(failed.error).toContain("mini offline");
  expect(failed.weekly).toMatchObject({ remainingPercent: 80, stale: true });
  failMini = false;
  await store.refreshHost("mini");
  expect(store.snapshot(now, { hostId: "mini" }).codex).toMatchObject({ status: "ready", loading: false });
  store.dispose();
  services.dispose();
});
