import { afterEach, expect, test } from "bun:test";
import { RpcError } from "../src/gateway";
import { addressKey } from "../src/protocol/boundary";

import { cleanupWorkspaces, deferred, header, MemoryStorage, setup, setupClaude } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("the same thread ID on two hosts retains distinct content and selection", async () => {
  const { workspace, harnesses } = await setup(["mini", "laptop"]);
  for (const [id, harness] of harnesses)
    harness.handler = (method) =>
      method === "thread/items/list"
        ? {
            data: [{ turnId: "t", item: { type: "agentMessage", id: "a", text: id }, isComplete: true }],
            nextCursor: null,
          }
        : undefined;
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  await workspace.selectConversation({ hostId: "laptop", threadId: "shared" });
  expect(workspace.getSnapshot().conversations.size).toBe(2);
  for (const id of ["mini", "laptop"])
    expect(
      workspace.getSnapshot().conversations.get(addressKey({ hostId: id, threadId: "shared" }))?.rows[0]
        ?.entry.item,
    ).toMatchObject({ text: id });
});

test("an exact address opens from its authoritative header while history is still loading", async () => {
  for (const threadId of ["outside-first-page", "claude_outside-first-page"]) {
    const { workspace, harness, harnesses } = await setup(["mini", "laptop"]);
    const listing = deferred<unknown>();
    harness.handler = (method, params) => {
      if (method === "thread/list") return listing.promise;
      if (method === "thread/read") return { thread: header(String(params.threadId)) };
      if (method === "claude/thread/liveCheckpoint") return { status: "unknown", threadId: params.threadId };
    };
    const refresh = workspace.refreshHost("mini");
    await workspace.selectConversation({ hostId: "mini", threadId });
    expect(workspace.selectedConversation?.status).toBe("ready");
    expect(workspace.selectedConversation?.header).toMatchObject({
      id: threadId,
      provider: threadId.startsWith("claude_") ? "claude" : "codex",
    });
    expect(harness.calls.find((call) => call.method === "thread/read")?.params).toEqual({
      threadId,
      includeTurns: false,
    });
    expect(harness.calls.some((call) => call.method === "thread/resume")).toBe(false);
    expect(harnesses.get("laptop")?.calls.some((call) => call.method === "thread/read")).toBe(false);
    listing.resolve({ data: [], nextCursor: null });
    await refresh;
  }
});

test("an exact header read rejects a different returned conversation", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method) => (method === "thread/read" ? { thread: header("wrong") } : undefined);
  await workspace.selectConversation({ hostId: "mini", threadId: "requested" });
  expect(workspace.selectedConversation).toBeUndefined();
  expect(workspace.getSnapshot().error).toContain("identity");
  expect(harness.calls.some((call) => call.method === "thread/items/list")).toBe(false);
});

test("a pending exact header cannot create a replacement conversation through send or voice preparation", async () => {
  const { workspace, harness } = await setup();
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/read" ? pending.promise : undefined);
  const loading = workspace.selectConversation({ hostId: "mini", threadId: "outside-first-page" });
  workspace.updateDraft({ model: "test-model", text: "Wait for the exact thread" });
  await expect(workspace.send()).rejects.toThrow("header to load");
  await expect(workspace.prepareVoiceConversation()).rejects.toThrow("header to load");
  expect(harness.calls.some((call) => call.method === "thread/start")).toBe(false);
  pending.resolve({ thread: header("outside-first-page") });
  await loading;
});

test("an existing Claude thread owns its directory despite a restored draft with another cwd", async () => {
  const storage = new MemoryStorage();
  const address = { hostId: "mini", threadId: "claude_owned" };
  storage.setItem(
    "remotecoder.web.drafts.v1",
    JSON.stringify([
      [
        addressKey(address),
        {
          revision: 3,
          text: "Unsent retry",
          attachments: [],
          model: "test-model",
          provider: "claude",
          effort: "",
          fast: false,
          cwd: "/old-default",
        },
      ],
    ]),
  );
  const { workspace, harness } = await setupClaude(["mini"], storage);
  const previous = harness.handler;
  harness.handler = (method, params) =>
    method === "claude/thread/list"
      ? { data: [{ ...header("claude_owned"), cwd: "/projects/owned" }], nextCursor: null }
      : previous?.(method, params);
  await workspace.refreshHost("mini");
  await workspace.selectConversation(address);
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("The native Claude catalog is unavailable");
  workspace.updateDraft({ model: choice.id });
  expect(workspace.draft.text).toBe("Unsent retry");
  expect(workspace.draft.cwd).toBe("/projects/owned");
  await workspace.send();
  expect(harness.calls.find((call) => call.method === "turn/start")?.params.cwd).toBe("/projects/owned");
  expect(harness.calls.some((call) => call.method === "thread/start")).toBe(false);
});

test("model defaults seeded while Claude history loads cannot replace its directory", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  const history = deferred<unknown>();
  harness.handler = (method, params) => {
    if (method === "claude/thread/list")
      return { data: [{ ...header("claude_owned"), cwd: "/projects/owned" }], nextCursor: null };
    if (method === "thread/items/list") return history.promise;
    return previous?.(method, params);
  };
  await workspace.refreshHost("mini");
  const loading = workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("The native Claude catalog is unavailable");
  workspace.updateDraft({
    model: choice.id,
    provider: "claude",
    effort: choice.defaultEffort,
    text: "Fixture",
  });
  expect(workspace.draft.cwd).toBe("/projects/owned");
  history.resolve({ data: [], nextCursor: null });
  await loading;
  await workspace.send();
  expect(harness.calls.find((call) => call.method === "turn/start")?.params.cwd).toBe("/projects/owned");
});

test("choosing another directory starts a fresh draft and preserves the existing thread's unsent input", async () => {
  const { workspace, harness } = await setupClaude();
  const address = { hostId: "mini", threadId: "claude_owned" };
  await workspace.selectConversation(address);
  workspace.updateDraft({ text: "Keep on the original thread", provider: "claude" });
  workspace.selectWorkingDirectory("/other-project");
  expect(workspace.selectedConversation).toBeUndefined();
  expect(workspace.draft.cwd).toBe("/other-project");
  expect(workspace.draft.text).toBe("");
  expect(workspace.draft.provider).toBe("claude");
  expect(workspace.getSnapshot().drafts.get(addressKey(address))?.text).toBe("Keep on the original thread");
  expect(harness.calls.some((call) => call.method === "thread/start")).toBe(false);
});

test("a folder change during thread creation keeps its successor draft separate from the acknowledged thread", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ cwd: "/project-a", model: "test-model", text: "Prompt A" });
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? pending.promise : undefined);
  const sending = workspace.send();
  workspace.selectWorkingDirectory("/project-b");
  workspace.updateDraft({ text: "Successor B" });
  pending.resolve({ thread: { ...header("created"), cwd: "/project-a" } });
  await sending;
  expect(workspace.selectedConversation).toBeUndefined();
  expect(workspace.draft.cwd).toBe("/project-b");
  expect(workspace.draft.text).toBe("Successor B");
  expect(harness.calls.find((call) => call.method === "turn/start")?.params.cwd).toBe("/project-a");
});

test("a failed background restore stays with its owner while another host's fixture remains selected", async () => {
  const { workspace, harness } = await setupClaude(["mini", "fixture"]);
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  await workspace.selectConversation({ hostId: "fixture", threadId: "shared" });
  const previous = harness.handler;
  harness.handler = (method, params) => {
    if (method === "thread/items/list") throw new RpcError("Owning history unavailable", -32602);
    return previous?.(method, params);
  };
  await workspace.restoreContext({ hostId: "mini" });
  expect(workspace.selectedConversation?.address.hostId).toBe("fixture");
  expect(workspace.selectedConversation?.status).toBe("ready");
  expect(workspace.getSnapshot().error).toBeUndefined();
  expect(
    workspace.getSnapshot().conversations.get(addressKey({ hostId: "mini", threadId: "claude_owned" }))
      ?.error,
  ).toBe("Owning history unavailable");
});
