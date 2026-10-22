import { afterEach, expect, test } from "bun:test";
import { executionTarget, targetKey } from "../src/execution-context";
import type { ConversationMarks } from "../src/workspace/conversation-marks";
import { Workspace } from "../src/workspace/workspace";
import {
  cleanupWorkspaces,
  deferred,
  enrollmentId,
  Harness,
  header,
  host,
  MemoryStorage,
  setup,
  setupContexts,
  workspaces,
} from "./fixtures/workspace";

afterEach(cleanupWorkspaces);
const pause = () => new Promise((resolve) => setTimeout(resolve, 0));
const pinned = (id: string, revision = 1): ConversationMarks => ({
  schemaVersion: 3,
  revision,
  readBaseline: 0,
  threads: { [id]: { revision, markedUnread: false, pinName: "Saved pin" } },
});

test("missing saved pins recover their real header after marks read and survive later first-page refreshes", async () => {
  const { workspace, harness } = await setup(["mini"], new MemoryStorage());
  harness.marks = pinned("older");
  harness.handler = (method, params) =>
    method === "thread/read"
      ? {
          thread: {
            ...header(String(params.threadId)),
            updatedAt: 100,
            cwd: "/older/project",
            name: "Real header",
          },
        }
      : undefined;
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "older")).toMatchObject({
    name: "Real header",
    cwd: "/older/project",
  });
  expect(
    workspace.conversationDrawer.sections
      .flatMap((section) => section.rows)
      .find((row) => row.address.threadId === "older")?.isPinned,
  ).toBe(true);
  const reads = harness.calls.filter((call) => call.method === "thread/read").length;
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "older")).toBe(true);
  expect(harness.calls.filter((call) => call.method === "thread/read")).toHaveLength(reads);
});

test("pins added as recovery finishes receive their own pass before the owner settles", async () => {
  const { workspace, harness } = await setup();
  let added = false;
  const acknowledgment = deferred<unknown>();
  harness.handler = (method, params) => {
    if (method === "conversation/marks/update") return acknowledgment.promise;
    if (method === "thread/read") return { thread: header(String(params.threadId)) };
    if (
      method === "conversation/agents/classify" &&
      !added &&
      (params.threadIds as string[]).includes("first")
    ) {
      added = true;
      workspace.pinConversation({ hostId: "mini", threadId: "second" }, "Second");
    }
    return undefined;
  };
  try {
    workspace.pinConversation({ hostId: "mini", threadId: "first" }, "First");
    await pause();
    expect(added).toBe(true);
    expect(workspace.selectedHost?.threads.some((thread) => thread.id === "second")).toBe(true);
  } finally {
    acknowledgment.resolve({ delta: null });
  }
});

test("restored marks and live marks acknowledgments both recover pins outside loaded history", async () => {
  const disk = new MemoryStorage();
  disk.setItem(
    `remotecoder.web.marks.v1:${targetKey({ hostId: "mini" })}`,
    JSON.stringify({ acknowledged: pinned("cached"), pending: [] }),
  );
  let harness: Harness | undefined;
  const workspace = new Workspace((_host, event) => {
    harness = new Harness(event);
    harness.marks = pinned("cached");
    harness.handler = (method, params) =>
      method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
    return harness;
  }, disk);
  workspaces.push(workspace);
  workspace.configureHosts([host("mini")]);
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "cached")).toBe(true);
  if (!harness) throw new Error("Missing fixture");
  harness.emit("conversation/marks/changed", pinned("notified", 2));
  await pause();
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "notified")).toBe(true);
  workspace.pinConversation({ hostId: "mini", threadId: "local" }, "Local pin");
  await pause();
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "local")).toBe(true);
});

test("failed or mismatched pin reads preserve loaded history, expose a diagnostic, and never invent a header", async () => {
  const { workspace, harness } = await setup();
  harness.marks = pinned("missing");
  harness.handler = (method) => (method === "thread/read" ? { thread: header("wrong") } : undefined);
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.history).toBe("ready");
  expect(workspace.selectedHost?.threads.map((thread) => thread.id)).toEqual(["shared"]);
  expect(workspace.selectedHost?.historyErrors).toEqual([]);
  expect(workspace.conversationDrawer.hostStates[0]?.errors.join(" ")).toContain(
    "pinned conversations could not be loaded",
  );
  const reads = harness.calls.filter((call) => call.method === "thread/read").length;
  await workspace.refreshHost("mini");
  expect(harness.calls.filter((call) => call.method === "thread/read")).toHaveLength(reads);
});

test("unpinned and retired exact contexts discard their in-flight protected header reads", async () => {
  const { workspace, harness, harnesses } = await setup();
  const read = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method) => {
    if (method === "thread/read") {
      requested.resolve();
      return read.promise;
    }
    return undefined;
  };
  harness.emit("conversation/marks/changed", pinned("older", 2));
  await requested.promise;
  harness.emit("conversation/marks/changed", { ...pinned("older", 3), threads: { older: { revision: 3 } } });
  read.resolve({ thread: header("older") });
  await pause();
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "older")).toBe(false);
  const retired = deferred<unknown>();
  harness.handler = (method) => (method === "thread/read" ? retired.promise : undefined);
  harness.emit("conversation/marks/changed", pinned("retired", 4));
  await pause();
  workspace.configureHosts([{ ...host("mini"), url: "https://replacement.example" }]);
  const replacement = harnesses.get("mini");
  if (!replacement) throw new Error("Missing replacement");
  retired.resolve({ thread: header("retired") });
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.map((thread) => thread.id)).toEqual(["shared"]);
});

test("pin recovery uses only the exact enrolled context for colliding thread IDs", async () => {
  const { workspace, harnesses } = await setupContexts();
  const target = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  await workspace.selectTarget(target);
  const enrolled = harnesses.get(targetKey(target));
  const physical = harnesses.get(targetKey({ hostId: "mini" }));
  if (!enrolled || !physical) throw new Error("Missing fixtures");
  enrolled.marks = pinned("older");
  enrolled.handler = (method) =>
    method === "thread/read" ? { thread: { ...header("older"), name: "Enrollment header" } } : undefined;
  await workspace.refreshHost(target);
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "older")?.name).toBe(
    "Enrollment header",
  );
  expect(physical.calls.some((call) => call.method === "thread/read")).toBe(false);
});

test("pinned retention preserves old headers while the complete history window remains capped at 500", async () => {
  const { workspace, harness } = await setup();
  harness.marks = pinned("pinned-old");
  let page = 0;
  harness.handler = (method, params) => {
    if (method === "thread/read") return { thread: { ...header(String(params.threadId)), updatedAt: 1 } };
    if (method === "thread/list") {
      const offset = page++ * 100;
      return {
        data: Array.from({ length: 100 }, (_, index) => ({
          ...header(`recent-${offset + index}`),
          updatedAt: 1000 + offset + index,
        })),
        nextCursor: `page-${page}`,
      };
    }
    return undefined;
  };
  await workspace.refreshHost("mini");
  for (let index = 0; index < 5; index++) await workspace.refreshHost("mini", true);
  expect(workspace.selectedHost?.threads).toHaveLength(500);
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "pinned-old")).toBe(true);
  expect(workspace.selectedHost?.threads.some((thread) => thread.id === "recent-599")).toBe(true);
});

test("failed provider history reads keep known pinned and ordinary headers with explicit read errors", async () => {
  const { workspace, harness } = await setup();
  harness.marks = pinned("older");
  harness.handler = (method) => (method === "thread/read" ? { thread: header("older") } : undefined);
  await workspace.refreshHost("mini");
  harness.handler = (method) => {
    if (method === "thread/list") throw new Error("history offline");
    return undefined;
  };
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.map((thread) => thread.id).sort()).toEqual(["older", "shared"]);
  expect(workspace.selectedHost?.historyErrors).toEqual(["history offline"]);
  expect(workspace.conversationDrawer.hostStates[0]?.errors).toContain("history offline");
});
