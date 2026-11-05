import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, deferred, setup } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

async function historyFixture() {
  const { workspace, harness } = await setup();
  harness.handler = (method, params) => {
    if (method === "daemon/activeTurns")
      return {
        activeTurns: [{ threadId: "shared", turnId: "active" }],
        coverage: { codex: true, claude: true },
      };
    if (method !== "thread/items/list") return;
    const ascending = params.sortDirection === "asc";
    const [position, inclusive] = String(params.cursor ?? "tail").split(":");
    const cursor = position === "tail" ? 600 : Number(position);
    const limit = Number(params.limit);
    const anchor = cursor + (inclusive === "include" ? (ascending ? -1 : 1) : 0);
    const start = ascending ? anchor + 1 : Math.max(0, anchor - limit);
    const end = ascending ? Math.min(600, start + limit) : anchor;
    const values = Array.from({ length: end - start }, (_, offset) => ({
      turnId: "active",
      item: { type: "agentMessage", id: `item-${start + offset}`, text: `Message ${start + offset}` },
      isComplete: true,
    }));
    return {
      data: ascending ? values : values.reverse(),
      nextCursor: ascending ? (end < 600 ? String(end - 1) : null) : start > 0 ? String(start) : null,
      backwardsCursor: `${ascending ? start : end - 1}:include`,
    };
  };
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  return { workspace, harness };
}

test("older paging keeps the requested page even when all retained messages belong to the active turn", async () => {
  const { workspace } = await historyFixture();
  for (let page = 0; page < 6; page++) await workspace.older();
  expect(workspace.selectedConversation?.rows[0]?.entry.item.id).toBe("item-180");
  expect(workspace.selectedConversation?.rows).toHaveLength(240);
  expect(workspace.selectedConversation?.error).toBeUndefined();
});

test("bounded paging visits every stored item in both directions, including overlapping cursor anchors", async () => {
  const { workspace } = await historyFixture();
  const seen = new Set<string>();
  const collect = () => {
    const conversation = workspace.selectedConversation;
    expect(conversation?.rows.length).toBeLessThanOrEqual(240);
    for (const row of conversation?.rows ?? []) seen.add(row.entry.item.id);
  };
  collect();
  while (workspace.selectedConversation?.older) {
    await workspace.older();
    collect();
  }
  expect(seen.size).toBe(600);
  expect(workspace.selectedConversation?.rows[0]?.entry.item.id).toBe("item-0");
  seen.clear();
  collect();
  let reads = 0;
  while (workspace.selectedConversation?.newer) {
    expect(++reads).toBeLessThan(20);
    await workspace.newer();
    collect();
  }
  expect(seen.size).toBe(600);
  expect(workspace.selectedConversation?.rows.at(-1)?.entry.item.id).toBe("item-599");
});

test("overlapping edge requests share one read and a superseded page cannot replace a fresh tail", async () => {
  const { workspace, harness } = await historyFixture();
  const previous = harness.handler;
  const page = deferred<unknown>();
  harness.handler = (method, params) =>
    method === "thread/items/list" && params.cursor === "540" ? page.promise : previous?.(method, params);
  const first = workspace.older();
  const second = workspace.older();
  expect(
    harness.calls.filter((call) => call.method === "thread/items/list" && call.params.cursor === "540"),
  ).toHaveLength(1);
  await workspace.loadConversation({ hostId: "mini", threadId: "shared" });
  page.resolve(previous?.("thread/items/list", { cursor: "540", limit: 60, sortDirection: "desc" }));
  await Promise.all([first, second]);
  expect(workspace.selectedConversation?.rows[0]?.entry.item.id).toBe("item-540");
  expect(workspace.selectedConversation?.historyLoading).toBeUndefined();
});

test("live output stays outside a historical window and resumes after returning to the tail", async () => {
  const { workspace, harness } = await historyFixture();
  for (let page = 0; page < 6; page++) await workspace.older();
  const ids = workspace.selectedConversation?.rows.map((row) => row.entry.item.id);
  harness.emit("item/started", {
    threadId: "shared",
    turnId: "active",
    item: { type: "agentMessage", id: "live", text: "New" },
  });
  expect(workspace.selectedConversation?.rows.map((row) => row.entry.item.id)).toEqual(ids);
  await workspace.loadConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("item/started", {
    threadId: "shared",
    turnId: "active",
    item: { type: "agentMessage", id: "live", text: "New" },
  });
  harness.emit("item/agentMessage/delta", {
    threadId: "shared",
    turnId: "active",
    itemId: "live",
    delta: " output",
  });
  expect(workspace.selectedConversation?.rows.at(-1)?.entry.item).toMatchObject({ text: "New output" });
});

test("live retention exposes a reload edge instead of silently leaving an unreachable history gap", async () => {
  const { workspace, harness } = await historyFixture();
  for (let index = 0; index < 250; index++)
    harness.emit("item/completed", {
      threadId: "shared",
      turnId: "active",
      item: { type: "agentMessage", id: `live-${index}`, text: "Output" },
    });
  expect(workspace.selectedConversation?.rows).toHaveLength(240);
  expect(workspace.selectedConversation?.historyReloadRequired).toBe(true);
  expect(workspace.selectedConversation?.error).toBeUndefined();
  await workspace.older();
  expect(workspace.selectedConversation?.historyReloadRequired).toBe(false);
  expect(workspace.selectedConversation?.rows[0]?.entry.item.id).toBe("item-540");
});

test("queue admission releases the removed local row's retained bytes", async () => {
  const { workspace } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  workspace.updateDraft({ text: "A queued follow-up" });
  await workspace.send("queue");
  expect(workspace.selectedConversation?.rows).toHaveLength(0);
  expect(workspace.selectedConversation?.bytes).toBe(0);
});

test("sending from a historical window rechecks unknown activity after its fresh tail read", async () => {
  const { workspace, harness } = await historyFixture();
  for (let page = 0; page < 6; page++) await workspace.older();
  const previous = harness.handler;
  harness.handler = (method, params) =>
    method === "daemon/activeTurns"
      ? { activeTurns: [], coverage: { codex: false, claude: true } }
      : previous?.(method, params);
  workspace.updateDraft({ text: "Do not start another turn without known activity" });
  await expect(workspace.send()).rejects.toThrow("Turn status is unavailable");
  expect(harness.calls.some((call) => call.method === "turn/start" || call.method === "turn/steer")).toBe(
    false,
  );
});

test("an unavailable checkpoint history stays distinct from an exhausted history and can recover", async () => {
  const { workspace, harness } = await setup();
  const previous = harness.handler;
  let unavailable = true;
  harness.handler = (method, params) =>
    method === "thread/subscribe"
      ? {
          status: "subscribed",
          subscriptionId: "partial",
          thread: { id: "shared", cwd: "/workspace", name: "Partial", status: { type: "idle" } },
          checkpoint: { itemsBackwardsCursor: null, historyUnavailable: unavailable, liveItems: [] },
        }
      : previous?.(method, params);
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  expect(workspace.selectedConversation?.status).toBe("ready");
  expect(workspace.selectedConversation?.historyError).toContain("Stored history is unavailable");
  unavailable = false;
  await workspace.loadConversation({ hostId: "mini", threadId: "shared" });
  expect(workspace.selectedConversation?.historyError).toBeUndefined();
});
