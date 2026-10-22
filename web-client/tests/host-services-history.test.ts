import { expect, jest, test } from "bun:test";
import { executionTarget, targetKey } from "../src/execution-context";
import type { Address } from "../src/protocol/boundary";
import { conversationHeader } from "../src/workspace/conversation-header";
import { HostServices } from "../src/workspace/host-services";
import { deferred, enrollmentId, Harness, header, host } from "./fixtures/workspace";

function fixture(publish = () => {}) {
  let protectedAddresses: readonly Address[] = [];
  const rpcs = new Map<string, Harness>();
  const services = new HostServices(
    (_host, event, target) => {
      const rpc = new Harness(event);
      rpcs.set(targetKey(target), rpc);
      return rpc;
    },
    async () => ({
      schemaVersion: 2,
      refreshing: false,
      retiredClaudeAccountIds: [],
      accounts: [
        {
          id: enrollmentId,
          generation: 1,
          provider: "codex",
          label: "Test",
          isDefault: false,
          enabled: true,
          state: "ready",
          identity: { key: "test" },
          windows: [],
          stale: false,
        },
      ],
    }),
    {
      event() {},
      disconnected() {},
      async restore() {},
      retiring() {},
      canRetire: () => true,
      selectedTarget: () => undefined,
      protectedAddresses: () => protectedAddresses,
      syncPreferences() {},
      catalogReady() {},
      publish,
      report() {},
    },
  );
  services.configure([host("mini"), host("book")]);
  const mini = services.get("mini");
  const rpc = rpcs.get(targetKey(mini.target));
  if (!rpc) throw new Error("Missing fixture RPC");
  return {
    services,
    mini,
    rpc,
    rpcs,
    protect: (addresses: readonly Address[]) => {
      protectedAddresses = addresses;
    },
  };
}
const old = (id: string) => conversationHeader({ ...header(id), updatedAt: 1 }, "codex");

test("selected and live addresses outrank pins while history remains capped and other hosts stay distinct", async () => {
  const { services, mini, rpc, protect } = fixture();
  try {
    protect([
      { hostId: "mini", threadId: "selected" },
      { hostId: "mini", threadId: "live" },
      { hostId: "book", threadId: "foreign" },
    ]);
    for (const id of ["selected", "live", "foreign"]) services.recordThread(mini, old(id));
    const pins = Array.from({ length: 500 }, (_, index) => `pin-${index}`);
    for (const id of pins) services.recordThread(mini, conversationHeader(header(id), "codex"));
    await services.protectPinnedThreads(mini, pins);
    expect(mini.threads).toHaveLength(500);
    expect(mini.threads.some((thread) => thread.id === "selected")).toBe(true);
    expect(mini.threads.some((thread) => thread.id === "live")).toBe(true);
    expect(mini.threads.some((thread) => thread.id === "foreign")).toBe(false);
    expect(mini.pinnedRecoveryError).toContain("500-header history limit");
    expect(rpc.calls.some((call) => call.method === "thread/read")).toBe(false);
    await services.refresh("mini");
    expect(mini.threads).toHaveLength(500);
    expect(mini.threads.some((thread) => thread.id === "selected")).toBe(true);
    expect(mini.threads.some((thread) => thread.id === "live")).toBe(true);
  } finally {
    services.dispose();
  }
});

test("protected identity includes the exact enrollment generation", async () => {
  const { services, protect } = fixture();
  try {
    const target = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
    const enrolled = await services.ensure(target);
    protect([
      { ...target, threadId: "live" },
      { ...executionTarget("mini", { accountId: enrollmentId, generation: 2 }), threadId: "stale" },
    ]);
    services.recordThread(enrolled, old("live"));
    services.recordThread(enrolled, old("stale"));
    for (let index = 0; index < 500; index++)
      services.recordThread(enrolled, conversationHeader(header(`recent-${index}`), "codex"));
    expect(enrolled.threads).toHaveLength(500);
    expect(enrolled.threads.some((thread) => thread.id === "live")).toBe(true);
    expect(enrolled.threads.some((thread) => thread.id === "stale")).toBe(false);
  } finally {
    services.dispose();
  }
});

test("an exact header admission preserves live titles delivered while the header was absent", async () => {
  const { services, mini, rpc } = fixture();
  const response = deferred<unknown>();
  rpc.handler = (method) => (method === "thread/read" ? response.promise : undefined);
  try {
    const loading = services.readHeader(mini, "old", (header) => services.recordThread(mini, header));
    services.updateThreadName(mini, "old", "Live title");
    response.resolve({ thread: { ...header("old"), name: "Stale read" } });
    expect((await loading).name).toBe("Live title");
    expect(mini.threads.find((thread) => thread.id === "old")?.name).toBe("Live title");
    const stale = deferred<unknown>();
    rpc.handler = (method) => (method === "thread/read" ? stale.promise : undefined);
    const reading = services.readHeader(mini, "retired", () => {
      throw new Error("Retired read admitted");
    });
    services.configure([{ ...host("mini"), url: "https://replacement.example" }]);
    stale.resolve({ thread: header("retired") });
    await expect(reading).rejects.toThrow("Canceled");
    expect(services.get("mini").threads).toEqual([]);
  } finally {
    services.dispose();
  }
});

test("partial provider reads retain successful rows while history coverage remains failed", async () => {
  const { services, mini, rpc } = fixture();
  try {
    services.recordThread(mini, old("known"));
    rpc.handler = (method) => {
      if (method === "thread/list") throw new Error("Codex unavailable");
      if (method === "claude/thread/list") return { data: [header("claude_visible")], nextCursor: null };
      return undefined;
    };
    await services.refresh("mini");
    expect(mini.history).toBe("failed");
    expect(mini.historyErrors).toEqual(["Codex unavailable"]);
    expect(mini.threads.map((thread) => thread.id)).toContain("known");
    expect(mini.threads.map((thread) => thread.id)).toContain("claude_visible");
    const target = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
    const enrolled = await services.ensure(target);
    const enrolledRpc = services.get(target).rpc as Harness;
    enrolledRpc.handler = (method) => {
      if (method === "thread/list") throw new Error("Enrollment unavailable");
      return undefined;
    };
    await services.refresh(target);
    expect(enrolled.history).toBe("failed");
    expect(enrolled.historyErrors).toEqual(["Enrollment unavailable"]);
  } finally {
    services.dispose();
  }
});

test("pin retries use one timer at the earliest failed cooldown and stop after success", async () => {
  jest.useFakeTimers();
  const { services, mini, rpc } = fixture();
  let available = false;
  rpc.handler = (method, params) => {
    if (method !== "thread/read") return undefined;
    if (!available) throw new Error("Unavailable");
    return { thread: header(String(params.threadId)) };
  };
  const reads = () =>
    rpc.calls.filter((call) => call.method === "thread/read").map((call) => call.params.threadId);
  try {
    await services.protectPinnedThreads(mini, ["a"]);
    expect(jest.getTimerCount()).toBe(1);
    jest.advanceTimersByTime(10000);
    await services.protectPinnedThreads(mini, ["a", "b"]);
    expect(reads()).toEqual(["a", "b"]);
    expect(jest.getTimerCount()).toBe(1);
    jest.advanceTimersByTime(19999);
    expect(reads()).toEqual(["a", "b"]);
    jest.advanceTimersByTime(1);
    await services.protectPinnedThreads(mini, ["a", "b"]);
    expect(reads()).toEqual(["a", "b", "a"]);
    expect(jest.getTimerCount()).toBe(1);
    available = true;
    jest.advanceTimersByTime(10000);
    await services.protectPinnedThreads(mini, ["a", "b"]);
    expect(reads()).toEqual(["a", "b", "a", "b"]);
    expect(jest.getTimerCount()).toBe(1);
    jest.advanceTimersByTime(50000);
    await services.protectPinnedThreads(mini, ["a", "b"]);
    expect(reads()).toEqual(["a", "b", "a", "b", "a"]);
    expect(jest.getTimerCount()).toBe(0);
    expect(mini.pinnedRecoveryError).toBeUndefined();
  } finally {
    services.dispose();
    jest.useRealTimers();
  }
});

test("pin retry timers cancel on unpin, context retirement and disposal", async () => {
  jest.useFakeTimers();
  const { services, mini, rpc } = fixture();
  rpc.handler = (method) => {
    if (method === "thread/read") throw new Error("Unavailable");
    return undefined;
  };
  try {
    await services.protectPinnedThreads(mini, ["a"]);
    expect(jest.getTimerCount()).toBe(1);
    await services.protectPinnedThreads(mini, []);
    expect(jest.getTimerCount()).toBe(0);
    await services.protectPinnedThreads(mini, ["a"]);
    expect(jest.getTimerCount()).toBe(1);
    services.configure([{ ...host("mini"), url: "https://replacement.example" }]);
    expect(jest.getTimerCount()).toBe(0);
    const replacement = services.get("mini");
    const replacementRpc = replacement.rpc as Harness;
    replacementRpc.handler = rpc.handler;
    await services.protectPinnedThreads(replacement, ["a"]);
    expect(jest.getTimerCount()).toBe(1);
    services.dispose();
    expect(jest.getTimerCount()).toBe(0);
  } finally {
    services.dispose();
    jest.useRealTimers();
  }
});

test("successful recovery remains limited to 32 reads per pass without spinning a timer for backlog", async () => {
  jest.useFakeTimers();
  const { services, mini, rpc } = fixture();
  rpc.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  const ids = Array.from({ length: 40 }, (_, index) => `pin-${index}`);
  try {
    await services.protectPinnedThreads(mini, ids);
    expect(rpc.calls.filter((call) => call.method === "thread/read")).toHaveLength(32);
    expect(jest.getTimerCount()).toBe(0);
    expect(mini.pinnedRecoveryError).toContain("Refresh to load more");
    await services.protectPinnedThreads(mini, ids);
    expect(mini.threads).toHaveLength(40);
    expect(jest.getTimerCount()).toBe(0);
    expect(mini.pinnedRecoveryError).toBeUndefined();
    await services.protectPinnedThreads(
      mini,
      Array.from({ length: 501 }, (_, index) => `overflow-${index}`),
    );
    expect(jest.getTimerCount()).toBe(0);
    expect(mini.pinnedRecoveryError).toContain("500-header history limit");
  } finally {
    services.dispose();
    jest.useRealTimers();
  }
});

test("automatic pin retries retain overflow until an authoritative pin update removes it", async () => {
  jest.useFakeTimers();
  let observe = () => {};
  const { services, mini, rpc } = fixture(() => observe());
  const ids = Array.from({ length: 501 }, (_, index) => `pin-${String(index).padStart(4, "0")}`);
  let available = false;
  rpc.handler = (method, params) => {
    if (method !== "thread/read") return undefined;
    if (!available) throw new Error("Unavailable");
    return { thread: header(String(params.threadId)) };
  };
  try {
    for (const id of ids.slice(0, 499)) services.recordThread(mini, old(id));
    await services.protectPinnedThreads(mini, ids);
    expect(mini.pinnedRecoveryError).toContain("500-header history limit");
    expect(jest.getTimerCount()).toBe(1);
    const classified = deferred<void>();
    observe = () => {
      if (mini.threads.find((thread) => thread.id === ids[499])?.agentClassification.kind === "root")
        classified.resolve();
    };
    available = true;
    jest.advanceTimersByTime(30000);
    await classified.promise;
    expect(mini.threads).toHaveLength(500);
    expect(mini.threads.some((thread) => thread.id === ids[500])).toBe(false);
    expect(mini.pinnedRecoveryError).toContain("500-header history limit");
    expect(jest.getTimerCount()).toBe(0);
    await services.protectPinnedThreads(mini, ids.slice(0, 500));
    expect(mini.pinnedRecoveryError).toBeUndefined();
  } finally {
    services.dispose();
    jest.useRealTimers();
  }
});
