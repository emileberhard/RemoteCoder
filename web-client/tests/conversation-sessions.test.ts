import { afterEach, expect, test } from "bun:test";
import { RpcError } from "../src/gateway";
import { addressKey } from "../src/protocol/boundary";

import { cleanupWorkspaces, deferred, header, setup, setupClaude } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("new sends refuse a seventh pinned conversation before creating a thread", async () => {
  const { workspace, harness } = await setup();
  for (let index = 0; index < 6; index++) {
    workspace.newConversation();
    workspace.updateDraft({ model: "test-model", text: `Work ${index}` });
    await workspace.send();
  }
  workspace.newConversation();
  workspace.updateDraft({ model: "test-model", text: "Seventh" });
  await expect(workspace.send()).rejects.toThrow("Six conversations");
  expect(workspace.getSnapshot().conversations.size).toBe(6);
  expect(harness.calls.filter((call) => call.method === "thread/start")).toHaveLength(6);
});

test("idle conversations retain unconfirmed inputs until canonical history makes them evictable", async () => {
  const { workspace, harness } = await setup();
  for (let index = 0; index < 6; index++) {
    workspace.newConversation();
    workspace.updateDraft({ model: "test-model", text: `Pending echo ${index}` });
    await workspace.send();
    harness.emit("turn/completed", {
      threadId: workspace.selectedConversation?.address.threadId,
      turn: { id: "running", status: "completed" },
    });
  }
  workspace.newConversation();
  workspace.updateDraft({ model: "test-model", text: "Seventh" });
  await expect(workspace.send()).rejects.toThrow("unconfirmed work");
  const first = [...workspace.getSnapshot().conversations.values()][0];
  const pending = first?.rows[0]?.entry.item;
  if (!first || pending?.type !== "userMessage") throw new Error("Missing pending fixture input");
  harness.emit("item/completed", {
    threadId: first.address.threadId,
    turnId: "running",
    item: { ...pending, id: "canonical" },
  });
  await workspace.send();
  expect(workspace.getSnapshot().conversations.has(addressKey(first.address))).toBe(false);
  expect(workspace.getSnapshot().conversations.size).toBe(6);
});

test("pending new conversations reserve capacity before their setup acknowledgements", async () => {
  const { workspace, harness } = await setup();
  const starts: ReturnType<typeof deferred<unknown>>[] = [];
  harness.handler = (method) => {
    if (method !== "thread/start") return;
    const pending = deferred<unknown>();
    starts.push(pending);
    return pending.promise;
  };
  const sends: Promise<void>[] = [];
  for (let index = 0; index < 6; index++) {
    workspace.newConversation();
    workspace.updateDraft({ model: "test-model", text: `Draft ${index}` });
    sends.push(workspace.send());
  }
  workspace.newConversation();
  workspace.updateDraft({ model: "test-model", text: "Seventh" });
  await expect(workspace.send()).rejects.toThrow("Six conversations");
  expect(harness.calls.filter((call) => call.method === "thread/start")).toHaveLength(6);
  for (const [index, pending] of starts.entries()) pending.resolve({ thread: header(`created-${index}`) });
  await Promise.all(sends);
  expect(workspace.getSnapshot().conversations.size).toBe(6);
});

test("a fresh Claude conversation settles scoped content intent before its first turn without reading history", async () => {
  const { workspace, harness } = await setup();
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("The native Claude catalog is unavailable");
  workspace.updateDraft({ model: choice.id, provider: "claude", text: "A Claude fixture prompt" });
  harness.handler = (method) =>
    method === "thread/start" ? { thread: header("claude_created") } : undefined;
  harness.calls = [];
  await workspace.send();
  expect(workspace.selectedConversation?.address.threadId).toBe("claude_created");
  expect(harness.calls.map((call) => call.method)).toEqual([
    "thread/start",
    "conversation/subscriptions/set",
    "turn/start",
  ]);
  expect(harness.calls[1]?.params).toEqual({ threadIds: ["claude_created"] });
});

test("an unchanged rejected Claude content intent leaves history available without a hidden retry", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  harness.handler = (method, params) => {
    if (method === "conversation/subscriptions/set") throw new RpcError("Scoped content unsupported", -32601);
    return previous?.(method, params);
  };
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  await workspace.loadConversation({ hostId: "mini", threadId: "claude_owned" });
  expect(workspace.selectedConversation?.status).toBe("ready");
  expect(workspace.selectedConversation?.error).toContain("Scoped content unsupported");
  expect(harness.calls.filter((call) => call.method === "conversation/subscriptions/set")).toHaveLength(1);
  expect(workspace.getSnapshot().error).toBeUndefined();
});

for (const open of [false, true]) {
  for (const [threadId, modelProvider, provider] of [
    ["claude_owned", "anthropic", "claude"],
    ["shared", "claude", "codex"],
  ] as const) {
    test(`${open ? "open" : "unopened"} thread notifications classify ${threadId} by identity rather than model provider`, async () => {
      const { workspace, harness } = await setupClaude();
      if (open) await workspace.selectConversation({ hostId: "mini", threadId });
      harness.emit("thread/started", {
        threadId,
        thread: { ...header(threadId), modelProvider },
      });
      expect(workspace.selectedHost?.threads.find((value) => value.id === threadId)?.provider).toBe(provider);
    });
  }
}

test("an authoritative old header enters history before transcript loading completes or fails", async () => {
  const { workspace, harness } = await setup();
  const subscription = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method) => {
    if (method === "thread/read") return { thread: { ...header("older"), cwd: "/old/project" } };
    if (method === "thread/subscribe") {
      requested.resolve();
      return subscription.promise;
    }
    return undefined;
  };
  const loading = workspace.selectConversation({ hostId: "mini", threadId: "older" });
  await requested.promise;
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "older")?.cwd).toBe("/old/project");
  harness.emit("thread/name/updated", { threadId: "older", threadName: "Live title" });
  subscription.resolve(Promise.reject(new Error("Transcript unavailable")));
  await loading;
  expect(workspace.selectedConversation?.status).toBe("failed");
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "older")?.name).toBe("Live title");
});

test("session-only delegated agent headers are classified and excluded from drawer actions", async () => {
  const { workspace, harness } = await setupClaude();
  const parent = { hostId: "mini", threadId: "claude_owned" };
  const child = { hostId: "mini", threadId: "claude_outside_history" };
  const previous = harness.handler;
  harness.handler = (method, params) => {
    if (method === "thread/read" && params.threadId === child.threadId)
      return { thread: header(child.threadId) };
    if (method === "conversation/agents/classify")
      return {
        relations: {
          [child.threadId]: { parentThreadId: parent.threadId, parentAccountId: null, agentId: "agent" },
        },
        knownRoots: [],
        warnings: [],
      };
    return previous?.(method, params);
  };
  await workspace.selectConversation(parent);
  await workspace.openAgentConversation(child, parent);
  expect(workspace.selectedConversation?.status).toBe("ready");
  expect(
    workspace.selectedHost?.threads.find((thread) => thread.id === child.threadId)?.agentClassification,
  ).toMatchObject({ kind: "child", relation: { parentThreadId: parent.threadId } });
  expect(
    workspace.conversationDrawer.sections
      .flatMap((section) => section.rows)
      .some((row) => row.address.threadId === child.threadId),
  ).toBe(false);
  expect(workspace.selectedConversationRowState).toBeUndefined();
  expect(() => workspace.settleConversation(child)).toThrow("The conversation cannot be settled");
});

test("Claude queueing follows the host's claudeQueue capability", async () => {
  for (const claudeQueue of [false, true]) {
    const { workspace, harness } = await setupClaude(["mini"], undefined, claudeQueue);
    await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
    const choice = workspace.choices().find((choice) => choice.provider === "claude");
    if (!choice) throw new Error("The native Claude catalog is unavailable");
    workspace.updateDraft({ model: choice.id, provider: "claude", text: "A queued Claude follow-up" });
    harness.calls = [];
    if (!claudeQueue) {
      await expect(workspace.send("queue")).rejects.toThrow("does not support queued Claude messages");
      expect(harness.calls.map((call) => call.method)).not.toContain("thread/queue/add");
      continue;
    }
    await workspace.send("queue");
    const add = harness.calls.find((call) => call.method === "thread/queue/add");
    expect(add?.params).toMatchObject({ threadId: "claude_owned", input: [{ type: "text" }] });
    expect(typeof add?.params.clientUserMessageId).toBe("string");
    expect(harness.calls.map((call) => call.method)).not.toContain("turn/start");
    expect(harness.calls.at(-1)?.method).toBe("thread/queue/list");
  }
});
