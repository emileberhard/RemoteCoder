import { expect, test } from "bun:test";
import { targetKey } from "../src/execution-context";
import type { Rpc } from "../src/gateway";
import { ConversationMarksStore } from "../src/workspace/conversation-marks-store";

const snapshot = (revision = 1, threads = {}) => ({ schemaVersion: 3, revision, readBaseline: 100, threads });
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
function storage() {
  const data = new Map<string, string>();
  let broken = false;
  return {
    data,
    break: () => {
      broken = true;
    },
    value: {
      getItem: (key: string) => data.get(key) ?? null,
      removeItem: (key: string) => {
        data.delete(key);
      },
      setItem: (key: string, value: string) => {
        if (broken) throw new Error("disk full");
        data.set(key, value);
      },
    } as Storage,
  };
}
function rpc(call: Rpc["call"]): Rpc {
  return {
    call,
    capture: async () => {
      throw new Error("Unused capture");
    },
    notify: () => {},
    reply: () => {},
  };
}
const tick = () => new Promise((done) => setTimeout(done, 0));

test("notifications do not establish coverage; in-flight notifications survive a full read", async () => {
  const read = deferred<unknown>();
  const store = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(() => read.promise),
    undefined,
    () => {},
  );
  store.receive(snapshot(2, { t: { revision: 2, pinName: "Before read" } }));
  expect(store.marks).toBeUndefined();
  const sync = store.sync();
  await tick();
  store.receive(snapshot(3, { t: { revision: 3, pinName: "Newest" } }));
  read.resolve(snapshot(1, { t: { revision: 1, pinName: "Stale" } }));
  await sync;
  expect(store.isReadStateKnown).toBe(true);
  expect(store.marks?.threads.t?.pinName).toBe("Newest");
  store.dispose();
});

test("captured acknowledgments preserve later local edits and serialize batches", async () => {
  const disk = storage();
  const first = deferred<unknown>();
  const updates: unknown[] = [];
  const remote = rpc(async (method, params) => {
    if (method.endsWith("/read"))
      return updates.length >= 2 ? snapshot(3, { t: { revision: 3, pinName: "Second" } }) : snapshot();
    updates.push(params);
    if (updates.length === 1) return first.promise;
    return { delta: snapshot(3, { t: { revision: 3, pinName: "Second" } }) };
  });
  const store = new ConversationMarksStore({ hostId: "mini" }, remote, disk.value, () => {});
  await store.sync();
  store.recordChanges([{ op: "pin", threadId: "t", name: "First" }]);
  await tick();
  store.recordChanges([{ op: "pin", threadId: "t", name: "Second" }]);
  expect(store.marks?.threads.t?.pinName).toBe("Second");
  expect(JSON.parse([...disk.data.values()][0] ?? "{}").pending).toHaveLength(2);
  first.resolve({ delta: snapshot(2, { t: { revision: 2, pinName: "First" } }) });
  await store.sync();
  expect(store.pendingCount).toBe(0);
  expect(store.marks?.threads.t?.pinName).toBe("Second");
  expect(updates).toHaveLength(2);
  expect(Object.keys(updates[0] as object)).toEqual(["changes"]);
  store.dispose();
});

test("disk failure prevents dispatch and retains pending changes after RPC failure", async () => {
  const disk = storage();
  let updates = 0;
  const remote = rpc(async (method) => {
    if (method.endsWith("/read")) return snapshot();
    updates++;
    throw new Error("offline");
  });
  const store = new ConversationMarksStore({ hostId: "mini" }, remote, disk.value, () => {});
  await store.sync();
  disk.break();
  expect(() => store.recordChanges([{ op: "markUnread", threadId: "t" }])).toThrow("disk full");
  await tick();
  expect(updates).toBe(0);
  const goodDisk = storage();
  const other = new ConversationMarksStore({ hostId: "mini" }, remote, goodDisk.value, () => {});
  await other.sync();
  other.recordChanges([{ op: "markUnread", threadId: "t" }]);
  await tick();
  expect(other.pendingCount).toBe(1);
  expect(other.status).toBe("failed");
  const restored = new ConversationMarksStore({ hostId: "mini" }, remote, goodDisk.value, () => {});
  expect(restored.pendingCount).toBe(1);
  expect(restored.marks?.threads.t?.markedUnread).toBe(true);
  store.dispose();
  other.dispose();
  restored.dispose();
});

test("exact enrollment generation isolates storage and disposed reads cannot publish", async () => {
  const disk = storage();
  const read = deferred<unknown>();
  const target = {
    hostId: "mini",
    enrollment: { accountId: "00000000-0000-0000-0000-000000000001", generation: 1 },
  };
  const remote = rpc(async () => snapshot());
  const old = new ConversationMarksStore(target, remote, disk.value, () => {});
  await old.sync();
  old.recordChanges([{ op: "markUnread", threadId: "t" }]);
  old.dispose();
  const next = new ConversationMarksStore(
    { ...target, enrollment: { ...target.enrollment, generation: 2 } },
    rpc(() => read.promise),
    disk.value,
    () => {},
  );
  expect(next.marks).toBeUndefined();
  const syncing = next.sync();
  await tick();
  next.dispose();
  read.resolve(snapshot());
  await syncing;
  expect(next.marks).toBeUndefined();
});

test("bounded pending queue rejects overflow without dropping saved changes; batches cap at 500", async () => {
  const disk = storage();
  const gate = deferred<unknown>();
  const sizes: number[] = [];
  const remote = rpc(async (method, params) => {
    if (method.endsWith("/read")) return snapshot();
    sizes.push((params as { changes: unknown[] }).changes.length);
    if (sizes.length === 1) await gate.promise;
    return { delta: null };
  });
  const store = new ConversationMarksStore({ hostId: "mini" }, remote, disk.value, () => {});
  await store.sync();
  store.recordChanges(
    Array.from({ length: 2000 }, (_, index) => ({ op: "markUnread" as const, threadId: `t${index}` })),
  );
  await tick();
  expect(() => store.recordChanges([{ op: "markUnread", threadId: "overflow" }])).toThrow();
  expect(store.pendingCount).toBe(2000);
  gate.resolve(null);
  await store.sync();
  expect(sizes).toEqual([500, 500, 500, 500]);
  expect(store.pendingCount).toBe(0);
  store.dispose();
});

test("undecodable saved marks are quarantined once and fresh authoritative coverage can recover", async () => {
  const disk = storage();
  const key = `remotecoder.web.marks.v1:${targetKey({ hostId: "mini" })}`;
  disk.data.set(key, "broken pending data");
  const store = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async () => snapshot()),
    disk.value,
    () => {},
  );
  expect(store.status).toBe("unread");
  expect(store.restoreWarning).toContain("set aside");
  expect(store.isReadStateKnown).toBe(false);
  expect(disk.data.get(`${key}.quarantine`)).toBe("broken pending data");
  expect(disk.data.has(key)).toBe(false);
  await store.sync();
  expect(store.status).toBe("ready");
  expect(store.isReadStateKnown).toBe(true);
  store.dispose();
  const restored = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async () => snapshot()),
    disk.value,
    () => {},
  );
  expect(restored.restoreWarning).toBeUndefined();
  restored.dispose();
  disk.data.set(key, "another broken value");
  const next = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async () => snapshot()),
    disk.value,
    () => {},
  );
  expect(disk.data.get(`${key}.quarantine`)).toBe("another broken value");
  expect([...disk.data.keys()].filter((key) => key.endsWith(".quarantine"))).toHaveLength(1);
  next.dispose();
});

test("a failed quarantine write retains the original raw marks and blocks dispatch", async () => {
  const disk = storage();
  const key = `remotecoder.web.marks.v1:${targetKey({ hostId: "mini" })}`;
  disk.data.set(key, "broken pending data");
  disk.break();
  let calls = 0;
  const store = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async () => {
      calls++;
      return snapshot();
    }),
    disk.value,
    () => {},
  );
  expect(store.status).toBe("failed");
  expect(() => store.recordChanges([{ op: "markUnread", threadId: "t" }])).toThrow("unavailable");
  await store.sync();
  expect(calls).toBe(0);
  expect(disk.data.get(key)).toBe("broken pending data");
  store.dispose();
});

for (const reentrant of [false, true]) {
  test(`marks queued at successful publication finish synchronize without another external trigger (reentrant=${reentrant})`, async () => {
    let reads = 0;
    let writes = 0;
    let queued = false;
    let again: Promise<void> | undefined;
    const store = new ConversationMarksStore(
      { hostId: "mini" },
      rpc(async (method) => {
        if (method.endsWith("/read")) {
          reads++;
          return snapshot();
        }
        writes++;
        return { delta: snapshot(2, { t: { revision: 2, markedUnread: true } }) };
      }),
      storage().value,
      () => {
        if (store.status !== "ready" || queued) return;
        queued = true;
        const enqueue = () => {
          store.recordChanges([{ op: "markUnread", threadId: "t" }]);
          again = store.sync();
        };
        if (reentrant) enqueue();
        else queueMicrotask(enqueue);
      },
    );
    await store.sync();
    await again;
    expect(reads).toBe(2);
    expect(writes).toBe(1);
    expect(store.pendingCount).toBe(0);
    expect(store.marks?.threads.t?.markedUnread).toBe(true);
    store.dispose();
  });
}

test("known no-op edits do not consume pending capacity or send repeated acknowledgments", async () => {
  let writes = 0;
  const gate = deferred<unknown>();
  const store = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async (method) => {
      if (method.endsWith("/read"))
        return writes ? snapshot(2, { t: { revision: 2, pinName: "Pinned" } }) : snapshot();
      writes++;
      return gate.promise;
    }),
    storage().value,
    () => {},
  );
  await store.sync();
  store.recordChanges([
    { op: "markRead", threadId: "t", through: 100 },
    { op: "unpin", threadId: "absent" },
    { op: "markAllRead", through: 99 },
  ]);
  expect(store.pendingCount).toBe(0);
  store.recordChanges([
    { op: "pin", threadId: "t", name: "Pinned" },
    { op: "pin", threadId: "t", name: "Pinned" },
  ]);
  expect(store.pendingCount).toBe(1);
  await tick();
  expect(writes).toBe(1);
  gate.resolve({ delta: snapshot(2, { t: { revision: 2, pinName: "Pinned" } }) });
  await store.sync();
  store.recordChanges([{ op: "pin", threadId: "t", name: "Pinned" }]);
  expect(store.pendingCount).toBe(0);
  store.dispose();
});

test("older gateway schema drops unsupported pending settlements and still synchronizes remaining edits", async () => {
  const disk = storage();
  const key = `remotecoder.web.marks.v1:${targetKey({ hostId: "mini" })}`;
  disk.data.set(
    key,
    JSON.stringify({
      acknowledged: snapshot(),
      pending: [
        { id: "settle", change: { op: "settle", threadId: "t", through: 100 } },
        { id: "unsettle", change: { op: "unsettle", threadId: "u", through: 100 } },
        { id: "unread", change: { op: "markUnread", threadId: "t" } },
        { id: "pin", change: { op: "pin", threadId: "t", name: "Pinned" } },
      ],
    }),
  );
  const sent: unknown[] = [];
  const store = new ConversationMarksStore(
    { hostId: "mini" },
    rpc(async (method, params) => {
      if (method.endsWith("/read")) return { ...snapshot(), schemaVersion: 1 };
      sent.push(params);
      return { delta: null };
    }),
    disk.value,
    () => {},
  );
  await store.sync();
  expect(sent).toEqual([
    {
      changes: [
        { op: "markUnread", threadId: "t" },
        { op: "pin", threadId: "t", name: "Pinned" },
      ],
    },
  ]);
  expect(store.pendingCount).toBe(0);
  expect(store.status).toBe("ready");
  expect(JSON.parse(disk.data.get(key) ?? "{}").pending).toEqual([]);
  store.dispose();
});
