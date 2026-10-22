import { afterEach, expect, test } from "bun:test";
import { executionTarget, targetKey } from "../src/execution-context";
import { isDelegatedAgent } from "../src/workspace/conversation-header";

import {
  cleanupWorkspaces,
  deferred,
  enrollmentId,
  header,
  host,
  setup,
  setupContexts,
} from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("history classifies delegated agents, preserves definitive ancestry and keeps unknown roots visible", async () => {
  const { workspace, harness } = await setup();
  harness.calls = [];
  harness.handler = (method) => {
    if (method === "thread/list")
      return {
        data: [
          header("parent"),
          header("delegated"),
          { ...header("native"), parentThreadId: "parent" },
          { ...header("spawned"), source: { subAgent: { thread_spawn: { parent_thread_id: "parent" } } } },
          header("uncertain"),
        ],
        nextCursor: null,
      };
    if (method === "conversation/agents/classify")
      return {
        knownRoots: ["parent"],
        relations: { delegated: { parentThreadId: "parent", parentAccountId: null, agentId: "agent-run" } },
        warnings: ["Ancestry is not available for uncertain"],
      };
    return undefined;
  };
  await workspace.refreshHost("mini");
  const threads = workspace.selectedHost?.threads ?? [];
  expect(threads.filter((thread) => !isDelegatedAgent(thread)).map((thread) => thread.id)).toEqual([
    "parent",
    "uncertain",
  ]);
  expect(threads.find((thread) => thread.id === "delegated")?.agentClassification).toEqual({
    kind: "child",
    relation: { parentThreadId: "parent", parentAccountId: null, agentId: "agent-run" },
  });
  expect(threads.find((thread) => thread.id === "spawned")?.nativeParentThreadId).toBe("parent");
  expect(threads.find((thread) => thread.id === "uncertain")?.agentClassification.kind).toBe("unresolved");
  expect(workspace.selectedHost?.agentWarnings).toEqual(["Ancestry is not available for uncertain"]);
  expect(harness.calls.find((call) => call.method === "conversation/agents/classify")?.params).toEqual({
    threadIds: ["parent", "delegated", "uncertain"],
  });
  await workspace.refreshHost("mini");
  expect(harness.calls.findLast((call) => call.method === "conversation/agents/classify")?.params).toEqual({
    threadIds: ["uncertain"],
  });
  expect(
    workspace.selectedHost?.threads.find((thread) => thread.id === "delegated")?.agentClassification.kind,
  ).toBe("child");
});

test("unavailable agent classification leaves loaded history visible and recovers on an explicit refresh", async () => {
  const { workspace, harness } = await setup();
  let available = false;
  harness.handler = (method) => {
    if (method === "thread/list") return { data: [header("unknown")], nextCursor: null };
    if (method === "conversation/agents/classify") {
      if (!available) throw new Error("Fixture classification unavailable");
      return {
        knownRoots: [],
        relations: { unknown: { parentThreadId: "parent", agentId: "child" } },
        warnings: [],
      };
    }
    return undefined;
  };
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.history).toBe("ready");
  expect(workspace.selectedHost?.threads.map((thread) => thread.id)).toEqual(["unknown"]);
  const unknown = workspace.selectedHost?.threads[0];
  expect(unknown?.agentClassification.kind).toBe("unresolved");
  expect(unknown && isDelegatedAgent(unknown)).toBe(false);
  expect(workspace.selectedHost?.agentWarnings).toEqual([
    "Agent relationships unavailable; unclassified conversations remain visible.",
  ]);
  available = true;
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads[0]?.agentClassification.kind).toBe("child");
  expect(workspace.selectedHost?.agentWarnings).toEqual([]);
});

test("retiring a host fences its late classification without replacing the new context's ancestry", async () => {
  const { workspace, harness, harnesses } = await setup();
  const classification = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method) => {
    if (method === "thread/list") return { data: [header("child")], nextCursor: null };
    if (method === "conversation/agents/classify") {
      requested.resolve();
      return classification.promise;
    }
    return undefined;
  };
  const previous = workspace.refreshHost("mini");
  await requested.promise;
  workspace.configureHosts([{ ...host("mini"), url: "https://replacement.example" }]);
  const replacement = harnesses.get("mini");
  if (!replacement) throw new Error("Replacement fixture is unavailable");
  replacement.handler = (method) =>
    method === "thread/list" ? { data: [header("child")], nextCursor: null } : undefined;
  await workspace.refreshHost("mini");
  classification.resolve({
    knownRoots: [],
    relations: { child: { parentThreadId: "old-parent", agentId: "old-child" } },
    warnings: ["Old host warning"],
  });
  await previous;
  expect(workspace.selectedHost?.threads.map((thread) => thread.id)).toEqual(["child"]);
  expect(workspace.selectedHost?.threads[0]?.agentClassification.kind).toBe("root");
  expect(workspace.selectedHost?.agentWarnings).toEqual([]);
});

test("live titles update only their exact host and survive older history and subscription reads", async () => {
  const { workspace, harness, harnesses } = await setup(["mini", "laptop"]);
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  const page = deferred<unknown>();
  const subscription = deferred<unknown>();
  harness.handler = (method) =>
    method === "thread/list"
      ? page.promise
      : method === "thread/subscribe"
        ? subscription.promise
        : undefined;
  const history = workspace.refreshHost("mini");
  const transcript = workspace.loadConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("thread/name/updated", { threadId: "shared", threadName: "Early generated title" });
  expect(workspace.selectedConversation?.header.name).toBe("Early generated title");
  expect(workspace.getSnapshot().hosts[0]?.threads[0]?.name).toBe("Early generated title");
  expect(workspace.getSnapshot().hosts[1]?.threads[0]?.name).toBe("Conversation");
  page.resolve({ data: [header()], nextCursor: null });
  subscription.resolve({
    status: "subscribed",
    subscriptionId: "s",
    thread: header(),
    checkpoint: { itemsBackwardsCursor: null, liveItems: [] },
  });
  await Promise.all([history, transcript]);
  expect(workspace.selectedConversation?.header.name).toBe("Early generated title");
  expect(workspace.getSnapshot().hosts[0]?.threads[0]?.name).toBe("Early generated title");
  harnesses.get("laptop")?.emit("thread/name/updated", { threadId: "shared", threadName: null });
  expect(workspace.getSnapshot().hosts[1]?.threads[0]?.name).toBeNull();
  expect(workspace.selectedConversation?.header.name).toBe("Early generated title");
});

test("folder browsing lists visible subdirectories by their wire file names in natural order", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method) =>
    method === "fs/readDirectory"
      ? {
          entries: [
            { fileName: "project10", isDirectory: true, isFile: false },
            { fileName: ".config", isDirectory: true, isFile: false },
            { fileName: "notes.md", isDirectory: false, isFile: true },
            { fileName: "Project2", isDirectory: true, isFile: false },
          ],
        }
      : undefined;
  expect((await workspace.hostDirectories().list("/Users/developer")).childNames).toEqual([
    "Project2",
    "project10",
  ]);
  expect(harness.calls.at(-1)).toEqual({ method: "fs/readDirectory", params: { path: "/Users/developer" } });
});

test("an older host history read cannot replace a newer completed read", async () => {
  const { workspace, harness } = await setup();
  const delayed = deferred<unknown>();
  let count = 0;
  harness.handler = (method) =>
    method === "thread/list"
      ? ++count === 1
        ? delayed.promise
        : { data: [header("newer")], nextCursor: null }
      : undefined;
  const old = workspace.refreshHost("mini");
  await workspace.refreshHost("mini");
  delayed.resolve({ data: [header("older")], nextCursor: null });
  await old;
  expect(workspace.selectedHost?.threads.map((thread) => thread.id)).toEqual(["newer"]);
});

test("default and enrolled contexts retain colliding thread IDs and independent model/history owners", async () => {
  const { workspace, harnesses } = await setupContexts();
  const enrolled = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  const defaultDraft = workspace.draftKey;
  workspace.updateDraft({ text: "Default draft" });
  await workspace.selectTarget(enrolled);
  expect(workspace.draftKey).not.toBe(defaultDraft);
  await workspace.selectConversation({ ...enrolled, threadId: "shared" });
  expect(workspace.getSnapshot().conversations.size).toBe(2);
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: targetKey(enrolled) });
  expect(workspace.getSnapshot().drafts.get(defaultDraft)?.text).toBe("Default draft");
  expect(harnesses.get(targetKey(enrolled))?.calls.some((call) => call.method === "model/list")).toBe(true);
  expect(harnesses.get(targetKey(enrolled))?.calls.some((call) => call.method === "claude/thread/list")).toBe(
    false,
  );
});

test("a retired generation cannot update the replacement conversation with a late event", async () => {
  const { workspace, harnesses, replaceGeneration } = await setupContexts();
  const original = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  const replacement = executionTarget("mini", { accountId: enrollmentId, generation: 2 });
  await workspace.selectTarget(original);
  await workspace.selectConversation({ ...original, threadId: "shared" });
  replaceGeneration();
  await workspace.refreshAccounts("mini");
  await workspace.selectTarget(replacement);
  await workspace.selectConversation({ ...replacement, threadId: "shared" });
  harnesses
    .get(targetKey(original))
    ?.emit("item/agentMessage/delta", { threadId: "shared", turnId: "t", itemId: "a", delta: "STALE" });
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: targetKey(replacement) });
  expect(workspace.getSnapshot().conversations.size).toBe(1);
});
