import { afterEach, expect, test } from "bun:test";

import { cleanupWorkspaces, deferred, inventory, setup, setupClaude } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("Claude source-event markers may skip or stamp several notifications without losing text or completion", async () => {
  const { workspace, harness } = await setupClaude();
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  harness.emit(
    "turn/started",
    { threadId: "claude_owned", turn: { id: "active" } },
    { epoch: "stream", sequence: 1 },
  );
  harness.emit(
    "item/started",
    { threadId: "claude_owned", turnId: "active", item: { type: "agentMessage", id: "a", text: "Hello " } },
    { epoch: "stream", sequence: 2 },
  );
  harness.emit(
    "item/agentMessage/delta",
    { threadId: "claude_owned", turnId: "active", itemId: "a", delta: "world" },
    { epoch: "stream", sequence: 5 },
  );
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "Hello world" });
  expect(workspace.selectedConversation?.error).toBeUndefined();
  harness.emit(
    "item/completed",
    {
      threadId: "claude_owned",
      turnId: "active",
      item: { type: "agentMessage", id: "a", text: "Hello world" },
    },
    { epoch: "stream", sequence: 6 },
  );
  harness.emit(
    "turn/completed",
    { threadId: "claude_owned", turn: { id: "active" } },
    { epoch: "stream", sequence: 6 },
  );
  expect(workspace.selectedConversation?.rows[0]?.entry.isComplete).toBe(true);
  expect(workspace.selectedConversation?.activeTurnId).toBeNull();
});

test("live deltas received during a delayed history read survive the subscribe barrier", async () => {
  const { workspace, harness } = await setup();
  const page = deferred<unknown>();
  harness.handler = (method) => (method === "thread/items/list" ? page.promise : undefined);
  const read = workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  harness.emit("item/started", {
    threadId: "shared",
    turnId: "t",
    item: { type: "agentMessage", id: "a", text: "" },
  });
  harness.emit("item/agentMessage/delta", {
    threadId: "shared",
    turnId: "t",
    itemId: "a",
    delta: "Kept live",
  });
  page.resolve({ data: [], nextCursor: null });
  await read;
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "Kept live" });
});

test("an older question read cannot resurrect a question resolved by a newer read", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  const earlier = deferred<unknown>();
  let reads = 0;
  harness.handler = (method) =>
    method === "conversation/questions/read"
      ? ++reads === 1
        ? earlier.promise
        : inventory(false, 3)
      : undefined;
  const first = workspace.refreshQuestions();
  await workspace.refreshQuestions();
  earlier.resolve(inventory(true, 2));
  await first;
  const current = workspace.selectedConversation?.questions;
  expect(current?.status).toBe("ready");
  if (current?.status === "ready") {
    expect(current.value.pendingItemIds).toEqual([]);
    expect(current.value.revision).toBe(3);
  }
});

test("command and reasoning wire deltas use their exact notification names", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("item/started", {
    threadId: "shared",
    turnId: "t",
    item: {
      type: "commandExecution",
      id: "command",
      command: "pwd",
      cwd: "/workspace",
      status: "inProgress",
      aggregatedOutput: "",
    },
  });
  harness.emit("item/commandExecution/outputDelta", {
    threadId: "shared",
    turnId: "t",
    itemId: "command",
    delta: "/workspace\n",
  });
  harness.emit("item/started", {
    threadId: "shared",
    turnId: "t",
    item: { type: "reasoning", id: "reasoning", summary: [], content: [] },
  });
  harness.emit("item/reasoning/summaryTextDelta", {
    threadId: "shared",
    turnId: "t",
    itemId: "reasoning",
    summaryIndex: 0,
    delta: "Thinking",
  });
  harness.emit("item/reasoning/textDelta", {
    threadId: "shared",
    turnId: "t",
    itemId: "reasoning",
    contentIndex: 0,
    delta: "Details",
  });
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({
    aggregatedOutput: "/workspace\n",
  });
  expect(workspace.selectedConversation?.rows[1]?.entry.item).toMatchObject({
    summary: ["Thinking"],
    content: ["Details"],
  });
});

test("Claude history uses its scoped content route and never asks Codex for observation, queue or questions", async () => {
  const { workspace, harness } = await setupClaude();
  harness.calls = [];
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  expect(workspace.selectedConversation?.status).toBe("ready");
  expect(workspace.selectedConversation?.queue.status).toBe("failed");
  expect(workspace.selectedConversation?.questions.status).toBe("failed");
  expect(harness.calls.map((call) => call.method)).toEqual([
    "conversation/subscriptions/set",
    "thread/items/list",
    "daemon/activeTurns",
    "claude/thread/liveCheckpoint",
  ]);
  expect(harness.calls[0]?.params).toEqual({ threadIds: ["claude_owned"] });
  expect(workspace.getSnapshot().error).toBeUndefined();
});

test("Claude checkpoint markers reject already included delayed frames and admit their exact continuation", async () => {
  const { workspace, harness } = await setupClaude();
  const pending = deferred<unknown>();
  const previous = harness.handler;
  harness.handler = (method, params) =>
    method === "claude/thread/liveCheckpoint" ? pending.promise : previous?.(method, params);
  const loading = workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  for (let index = 0; index < 20; index++) await Promise.resolve();
  harness.emit(
    "item/started",
    { threadId: "claude_owned", turnId: "active", item: { type: "agentMessage", id: "a", text: "AB" } },
    { epoch: "prefix", sequence: 2 },
  );
  harness.emit(
    "item/agentMessage/delta",
    { threadId: "claude_owned", turnId: "active", itemId: "a", delta: "C" },
    { epoch: "prefix", sequence: 3 },
  );
  pending.resolve({
    status: "observed",
    threadId: "claude_owned",
    turnId: "active",
    epoch: "prefix",
    throughSequence: 2,
    liveItems: [{ turnId: "active", item: { type: "agentMessage", id: "a", text: "AB" }, isComplete: false }],
    unknownItems: [],
  });
  await loading;
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "ABC" });
  expect(workspace.selectedConversation?.activeTurnId).toBe("active");
  harness.emit(
    "item/agentMessage/delta",
    { threadId: "claude_owned", turnId: "active", itemId: "a", delta: "B" },
    { epoch: "prefix", sequence: 2 },
  );
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "ABC" });
  harness.emit(
    "item/agentMessage/delta",
    { threadId: "claude_owned", turnId: "active", itemId: "a", delta: "D" },
    { epoch: "prefix", sequence: 6 },
  );
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "ABCD" });
  expect(workspace.selectedConversation?.error).toBeUndefined();
  harness.emit(
    "item/completed",
    { threadId: "claude_owned", turnId: "active", item: { type: "agentMessage", id: "a", text: "ABCD" } },
    { epoch: "prefix", sequence: 7 },
  );
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "ABCD" });
});

test("an unknown Claude prefix never appends missing live text to an incomplete historical row", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  harness.handler = (method, params) =>
    method === "thread/items/list"
      ? {
          data: [
            { turnId: "active", item: { type: "agentMessage", id: "a", text: "Known" }, isComplete: false },
          ],
          nextCursor: null,
        }
      : previous?.(method, params);
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_owned" });
  harness.emit("item/agentMessage/delta", {
    threadId: "claude_owned",
    turnId: "active",
    itemId: "a",
    delta: " tail",
  });
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "Known" });
  harness.emit("item/completed", {
    threadId: "claude_owned",
    turnId: "active",
    item: { type: "agentMessage", id: "a", text: "Known missing tail" },
  });
  expect(workspace.selectedConversation?.rows[0]?.entry.item).toMatchObject({ text: "Known missing tail" });
});

test("successful publication stays visible until a completed rendered answer claims its placement", async () => {
  const { renderMarkdown } = await import("../src/markdown");
  const { timelineSegments } = await import("../src/ui/chat/transcript/timeline-segments");
  const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  const embed = `![Chart](rc-visual:${digest})`;
  for (const type of ["mcpToolCall", "dynamicToolCall"]) {
    for (const [text, placed] of [
      [embed, true],
      [`\`\`\`\n${embed}\n\`\`\``, false],
      [`See ${embed} here`, false],
      [`rc-visual:${digest}`, false],
    ] as const) {
      const { workspace, harness } = await setup();
      await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
      workspace.setRenderer({
        update(id, source, revision) {
          workspace.markdownReady(id, { revision, blocks: [renderMarkdown(source)] });
        },
        append() {},
        remove() {},
        dispose() {},
      });
      harness.emit("item/completed", {
        threadId: "shared",
        turnId: "t",
        item: {
          type,
          id: "publication",
          server: "remotecoder",
          namespace: "remotecoder",
          tool: "publish_visual",
          status: "completed",
          success: true,
          arguments: {},
          rcVisual: { digest, title: "Chart" },
        },
      });
      const automatic = () =>
        timelineSegments(workspace.selectedConversation?.rows ?? [], false).flatMap((segment) =>
          segment.kind === "row" && segment.visual ? [segment.row.entry.item.id] : [],
        );
      expect(automatic()).toEqual(["publication"]);
      harness.emit("item/started", {
        threadId: "shared",
        turnId: "t",
        item: { type: "agentMessage", id: "answer", text },
      });
      expect(automatic()).toEqual(["publication"]);
      harness.emit("item/completed", {
        threadId: "shared",
        turnId: "t",
        item: { type: "agentMessage", id: "answer", text },
      });
      expect(automatic()).toEqual(placed ? [] : ["publication"]);
      harness.emit("item/completed", {
        threadId: "shared",
        turnId: "next",
        item: {
          type,
          id: "again",
          server: "remotecoder",
          namespace: "remotecoder",
          tool: "publish_visual",
          status: "completed",
          success: true,
          arguments: {},
          rcVisual: { digest, title: "Chart" },
        },
      });
      expect(automatic()).toContain("again");
    }
  }
});

test("same-title revisions replace drafts within their turn and preserve publisher titles", async () => {
  const { timelineSegments } = await import("../src/ui/chat/transcript/timeline-segments");
  for (const type of ["mcpToolCall", "dynamicToolCall"]) {
    const { workspace, harness } = await setup();
    await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
    for (const [id, title, turnId, digest] of [
      ["draft", "Chart", "t", "a"],
      ["fixed", "Chart", "t", "b"],
      ["other", "Other", "t", "c"],
      ["format", "\uFEFF", "t", "d"],
      ["later", "Chart", "next", "b"],
    ]) {
      harness.emit("item/completed", {
        threadId: "shared",
        turnId,
        item: {
          type,
          id,
          server: "remotecoder",
          namespace: "remotecoder",
          tool: "publish_visual",
          status: "completed",
          success: true,
          arguments: {},
          rcVisual: { digest: digest?.repeat(64), title },
        },
      });
    }
    const automatic = timelineSegments(workspace.selectedConversation?.rows ?? [], false).flatMap(
      (segment) => (segment.kind === "row" && segment.visual ? [segment.row.entry.item.id] : []),
    );
    expect(automatic).toEqual(["fixed", "other", "format", "later"]);
    expect(workspace.selectedConversation?.error).toBeUndefined();
  }
});

test("retained rendered placement survives a completed-item upsert until deferred rendering replaces it", async () => {
  const { renderMarkdown } = await import("../src/markdown");
  const { timelineSegments } = await import("../src/ui/chat/transcript/timeline-segments");
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  const pending = new Map<string, { source: string; revision: number }>();
  workspace.setRenderer({
    update(id, source, revision) {
      pending.set(id, { source, revision });
    },
    append() {},
    remove() {},
    dispose() {},
  });
  const digest = "a".repeat(64);
  harness.emit("item/completed", {
    threadId: "shared",
    turnId: "t",
    item: {
      type: "dynamicToolCall",
      id: "publication",
      namespace: "remotecoder",
      tool: "publish_visual",
      status: "completed",
      success: true,
      arguments: {},
      rcVisual: { digest, title: "Chart" },
    },
  });
  const answer = (text: string) =>
    harness.emit("item/completed", {
      threadId: "shared",
      turnId: "t",
      item: { type: "agentMessage", id: "answer", text },
    });
  const automatic = () =>
    timelineSegments(workspace.selectedConversation?.rows ?? [], false).some(
      (segment) => segment.kind === "row" && segment.visual !== undefined,
    );
  const finishRender = () => {
    for (const [id, { source, revision }] of pending)
      workspace.markdownReady(id, { revision, blocks: [renderMarkdown(source)] });
    pending.clear();
  };
  const embed = `![Chart](rc-visual:${digest})`;
  answer(embed);
  expect(automatic()).toBe(true);
  finishRender();
  expect(automatic()).toBe(false);
  answer(embed);
  expect(pending.size).toBe(1);
  expect(automatic()).toBe(false);
  finishRender();
  answer("Revised answer without an embed");
  expect(automatic()).toBe(false);
  finishRender();
  expect(automatic()).toBe(true);
});
