import { afterEach, expect, test } from "bun:test";
import attachedFiles from "../../protocol-fixtures/attached-files-block.json";
import { executionTarget, targetKey } from "../src/execution-context";
import { RpcError } from "../src/gateway";
import { type Address, addressKey } from "../src/protocol/boundary";

import {
  activity,
  cleanupWorkspaces,
  deferred,
  enrollmentId,
  header,
  MemoryStorage,
  setup,
  setupClaude,
  setupContexts,
} from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("a locally prepared thread gains its first submitted preview without changing it on follow-ups", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method) =>
    method === "thread/start" ? { thread: { ...header("fresh"), name: null, preview: "" } } : undefined;
  workspace.updateDraft({ model: "test-model", text: "First submitted message" });
  await workspace.prepareConversation();
  expect(workspace.selectedConversation?.header.preview).toBe("");
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "fresh")?.preview).toBe("");
  await workspace.send();
  expect(workspace.selectedConversation?.header.preview).toBe("First submitted message");
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "fresh")?.preview).toBe(
    "First submitted message",
  );
  harness.emit("turn/completed", { threadId: "fresh", turn: { id: "running" } });
  workspace.updateDraft({ text: "Follow-up message" });
  await workspace.send();
  expect(workspace.selectedConversation?.header.preview).toBe("First submitted message");
  harness.emit("thread/name/updated", { threadId: "fresh", threadName: "Generated title" });
  expect(workspace.selectedConversation?.header.name).toBe("Generated title");
  expect(workspace.selectedHost?.threads.find((thread) => thread.id === "fresh")?.name).toBe(
    "Generated title",
  );
});

test("uploaded images and files use the native path handoff on both providers", async () => {
  for (const provider of ["codex", "claude"] as const) {
    for (const fixture of attachedFiles.cases) {
      const { workspace, harness } = await setup();
      const choice = workspace.choices().find((choice) => choice.provider === provider);
      if (!choice) throw new Error("Missing fixture model");
      workspace.updateDraft({
        provider,
        model: choice.id,
        text: fixture.body,
        attachments: fixture.paths.map((path, index) => ({
          id: String(index),
          path,
          name: path.split("/").at(-1) ?? "file",
          type: index === 0 ? "image/png" : "text/plain",
          bytes: 3,
          sha256: "test",
        })),
      });
      await workspace.send();
      expect(harness.calls.find((call) => call.method === "turn/start")?.params.input).toEqual([
        { type: "text", text: fixture.message, text_elements: [] },
      ]);
    }
  }
});

test("two sends before thread setup acknowledges create one conversation and one turn", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ model: "test-model", text: "First", effort: "high" });
  const start = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? start.promise : undefined);
  const first = workspace.send();
  await expect(workspace.send()).rejects.toThrow("already being submitted");
  start.resolve({ thread: header("created") });
  await first;
  expect(harness.calls.filter((call) => call.method === "thread/start")).toHaveLength(1);
  expect(harness.calls.filter((call) => call.method === "turn/start")).toHaveLength(1);
});

test("a fresh conversation starts its first turn without requiring a stored rollout", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ model: "test-model", text: "First turn" });
  harness.handler = (method) => {
    if (method === "thread/start") {
      harness.emit("thread/started", { thread: header("created") });
      return { thread: header("created") };
    }
    if (method === "thread/resume") throw new RpcError("no rollout found for thread id created", -32602);
  };
  await workspace.send();
  expect(harness.calls.some((call) => call.method === "thread/resume")).toBe(false);
  expect(harness.calls.filter((call) => call.method === "turn/start")).toHaveLength(1);
  expect(workspace.selectedHost?.threads.filter((thread) => thread.id === "created")).toHaveLength(1);
  expect(workspace.draft.text).toBe("");
});

test("successor text typed during new-thread setup moves to that conversation and survives its first acknowledgment", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ model: "test-model", text: "Prompt A" });
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? pending.promise : undefined);
  const sending = workspace.send();
  workspace.updateDraft({ text: "Successor B" });
  pending.resolve({ thread: header("created") });
  await sending;
  expect(workspace.draft.text).toBe("Successor B");
  expect(workspace.selectedConversation?.address.threadId).toBe("created");
  expect(
    [...workspace.getSnapshot().drafts.values()].filter((draft) => draft.text === "Successor B"),
  ).toHaveLength(1);
  expect(harness.calls.find((call) => call.method === "turn/start")?.params.input).toEqual([
    { type: "text", text: "Prompt A", text_elements: [] },
  ]);
});

test("a definitive send rejection replaces the published row and retains its unsent draft", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ model: "test-model", text: "Keep this draft" });
  let publishedSending: unknown;
  const unsubscribe = workspace.subscribe(() => {
    const row = workspace.selectedConversation?.rows[0];
    if (row?.delivery === "sending") publishedSending = row;
  });
  harness.handler = (method) => {
    if (method === "turn/start") throw new RpcError("Rejected input", -32602);
  };
  await expect(workspace.send()).rejects.toThrow("Rejected input");
  unsubscribe();
  expect(publishedSending).toBeDefined();
  expect(workspace.selectedConversation?.rows[0]).not.toBe(publishedSending);
  expect(workspace.selectedConversation?.rows[0]?.delivery).toBe("failed");
  expect(workspace.draft.text).toBe("Keep this draft");
  expect(workspace.draft.uncertain).toBeUndefined();
});

test("acknowledging prompt A keeps successor draft B typed while A was in flight", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  workspace.updateDraft({ model: "test-model", text: "A" });
  const turn = deferred<unknown>();
  harness.handler = (method) => (method === "turn/start" ? turn.promise : undefined);
  const sending = workspace.send();
  await Promise.resolve();
  await Promise.resolve();
  workspace.updateDraft({ text: "B" });
  turn.resolve({ turn: { id: "t" } });
  await sending;
  expect(workspace.draft.text).toBe("B");
});

test("unknown activity cannot start a second turn", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method) => (method === "daemon/activeTurns" ? activity(false) : undefined);
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  workspace.updateDraft({ model: "test-model", text: "Unsafe to guess" });
  await expect(workspace.send()).rejects.toThrow("Turn status is unavailable");
  expect(harness.calls.some((call) => call.method === "turn/start")).toBe(false);
});

test("reload during an unacknowledged dispatch restores an uncertain submission receipt", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  workspace.updateDraft({ model: "test-model", text: "Do not duplicate" });
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "turn/start" ? pending.promise : undefined);
  const sending = workspace.send();
  await Promise.resolve();
  await Promise.resolve();
  expect(storage.getItem("remotecoder.web.submissions.v1")).toContain("shared");
  const reloaded = await setup(["mini"], storage);
  await reloaded.workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  expect(reloaded.workspace.draft.uncertain).toBeTruthy();
  await expect(reloaded.workspace.send()).rejects.toThrow("uncertain delivery");
  pending.resolve({ turn: { id: "t" } });
  await sending;
});

test("canonical history reconciles a new-chat receipt after reload without retaining a duplicate draft", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  workspace.updateDraft({ model: "test-model", text: "Accepted before the browser closed" });
  const pending = deferred<unknown>();
  harness.handler = (method) =>
    method === "thread/start"
      ? { thread: header("created") }
      : method === "turn/start"
        ? pending.promise
        : undefined;
  const sending = workspace.send();
  for (let index = 0; index < 6; index++) await Promise.resolve();
  const admitted = harness.calls.find((call) => call.method === "turn/start");
  const clientId = admitted?.params.clientUserMessageId;
  expect(clientId).toBeString();
  const reloaded = await setup(["mini"], storage);
  reloaded.harness.handler = (method) => {
    if (method === "thread/list") return { data: [header("created")], nextCursor: null };
    if (method === "thread/items/list")
      return {
        data: [
          {
            turnId: "t",
            isComplete: true,
            item: {
              type: "userMessage",
              id: "canonical",
              clientId,
              content: [{ type: "text", text: "Accepted before the browser closed" }],
            },
          },
        ],
        nextCursor: null,
      };
  };
  await reloaded.workspace.refreshHost("mini");
  await reloaded.workspace.selectConversation({ hostId: "mini", threadId: "created" });
  expect(reloaded.workspace.draft.uncertain).toBeUndefined();
  expect(reloaded.workspace.draft.text).toBe("");
  pending.resolve({ turn: { id: "t" } });
  await sending;
});

test("an enrolled send stays on its captured binding while navigation preserves another draft", async () => {
  const { workspace, harnesses } = await setupContexts();
  const enrolled = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  await workspace.selectTarget(enrolled);
  workspace.updateDraft({ model: "test-model", text: "Enrolled prompt" });
  const harness = harnesses.get(targetKey(enrolled));
  if (!harness) throw new Error("The enrolled harness is unavailable");
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "turn/start" ? pending.promise : undefined);
  const sending = workspace.send();
  for (let index = 0; index < 6; index++) await Promise.resolve();
  await workspace.selectTarget({ hostId: "mini" });
  workspace.updateDraft({ text: "Successor on default" });
  pending.resolve({ turn: { id: "enrolled-turn" } });
  await sending;
  expect(workspace.draft.text).toBe("Successor on default");
  expect(harness.calls.filter((call) => call.method === "turn/start")).toHaveLength(1);
  expect(
    harnesses.get(targetKey({ hostId: "mini" }))?.calls.filter((call) => call.method === "turn/start"),
  ).toHaveLength(0);
});

test("fresh voice preparation coalesces admission and preserves the latest draft without sending input", async () => {
  const { workspace, harness } = await setup();
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? pending.promise : undefined);
  workspace.newConversation();
  workspace.updateDraft({ model: "test-model", text: "Keep this draft" });
  const key = workspace.draftKey;
  const first = workspace.prepareConversation();
  const second = workspace.prepareConversation();
  expect(second).toBe(first);
  expect(workspace.isSubmitting).toBe(true);
  await expect(workspace.send()).rejects.toThrow("already");
  const attachment = {
    id: "file",
    name: "notes.txt",
    bytes: 3,
    type: "text/plain",
    path: "/workspace/notes.txt",
    sha256: "a".repeat(64),
  };
  workspace.updateDraft({ text: "Edited during preparation", attachments: [attachment] });
  pending.resolve({ thread: header("voice-created") });
  const conversation = await first;
  expect(conversation.address).toEqual({ hostId: "mini", threadId: "voice-created" });
  expect(conversation.resumeRequired).toBe(false);
  expect(workspace.selectedConversation).toBe(conversation);
  expect(workspace.draft.text).toBe("Edited during preparation");
  expect(workspace.draft.attachments).toEqual([attachment]);
  expect(workspace.getSnapshot().drafts.has(key)).toBe(false);
  expect(workspace.isSubmitting).toBe(false);
  expect(harness.calls.filter((call) => call.method === "thread/start")).toHaveLength(1);
  expect(
    harness.calls.some((call) => ["thread/resume", "thread/items/list", "turn/start"].includes(call.method)),
  ).toBe(false);
  expect(await workspace.prepareConversation()).toBe(conversation);
  expect(harness.calls.filter((call) => call.method === "thread/start")).toHaveLength(1);
});

test("voice preparation stays on its captured enrollment while navigation retains another fresh draft", async () => {
  const { workspace, harnesses } = await setupContexts();
  const enrolled = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  await workspace.selectTarget(enrolled);
  workspace.updateDraft({ model: "test-model", text: "Original enrolled draft" });
  const harness = harnesses.get(targetKey(enrolled));
  if (!harness) throw new Error("The enrolled harness is unavailable");
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? pending.promise : undefined);
  const preparing = workspace.prepareConversation();
  for (let index = 0; index < 6; index++) await Promise.resolve();
  await workspace.selectTarget({ hostId: "mini" });
  workspace.updateDraft({ text: "Current default draft" });
  pending.resolve({ thread: header("voice-enrolled") });
  const conversation = await preparing;
  expect(conversation.address).toEqual({ ...enrolled, threadId: "voice-enrolled" });
  expect(workspace.selectedConversation).toBeUndefined();
  expect(workspace.draft.text).toBe("Current default draft");
  expect(workspace.getSnapshot().drafts.get(addressKey(conversation.address))?.text).toBe(
    "Original enrolled draft",
  );
  expect(
    harnesses.get(targetKey({ hostId: "mini" }))?.calls.some((call) => call.method === "thread/start"),
  ).toBe(false);
});

test("a generation retired during voice preparation cannot admit the returned thread or lose its draft", async () => {
  const { workspace, harnesses, replaceGeneration } = await setupContexts();
  const enrolled = executionTarget("mini", { accountId: enrollmentId, generation: 1 });
  await workspace.selectTarget(enrolled);
  workspace.updateDraft({ model: "test-model", text: "Retain after retirement" });
  const harness = harnesses.get(targetKey(enrolled));
  if (!harness) throw new Error("The enrolled harness is unavailable");
  const pending = deferred<unknown>();
  harness.handler = (method) => (method === "thread/start" ? pending.promise : undefined);
  const key = workspace.draftKey;
  const preparing = workspace.prepareConversation();
  for (let index = 0; index < 6; index++) await Promise.resolve();
  replaceGeneration();
  await workspace.refreshAccounts("mini");
  pending.resolve({ thread: header("retired-voice") });
  await expect(preparing).rejects.toThrow();
  expect(workspace.getSnapshot().drafts.get(key)?.text).toBe("Retain after retirement");
  expect(workspace.getSnapshot().conversations.size).toBe(0);
  expect(workspace.isSubmitting).toBe(false);
});

test("accepted Claude steers survive switching until the provider echoes their canonical client identity", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  const prompt = {
    turnId: "active",
    item: { type: "userMessage", id: "prompt", content: [{ type: "text", text: "Initial prompt" }] },
    isComplete: true,
  };
  let canonical: unknown[] = [prompt];
  harness.handler = (method, params) => {
    if (method === "thread/items/list" && params.threadId === "claude_owned")
      return { data: [...canonical].reverse(), nextCursor: null };
    if (method === "daemon/activeTurns")
      return { ...activity(), activeTurns: [{ threadId: "claude_owned", turnId: "active" }] };
    if (method === "turn/steer") return { turnId: "active" };
    return previous?.(method, params);
  };
  const address = { hostId: "mini", threadId: "claude_owned" };
  await workspace.selectConversation(address);
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("Missing Claude fixture model");
  workspace.updateDraft({ model: choice.id, text: "Also inspect the second file" });
  await workspace.send();
  const sent = harness.calls.find((call) => call.method === "turn/steer");
  const clientId = String(sent?.params.clientUserMessageId);
  harness.emit("item/completed", {
    threadId: address.threadId,
    turnId: "active",
    item: { type: "agentMessage", id: "after-steer", text: "Still working" },
  });
  canonical = [
    prompt,
    { turnId: "active", item: { type: "agentMessage", id: "after-steer", text: "Still working" } },
  ];
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  await workspace.selectConversation(address);
  expect(workspace.selectedConversation?.rows.map((row) => row.entry.item.id)).toEqual([
    "prompt",
    clientId,
    "after-steer",
  ]);
  expect(workspace.selectedConversation?.rows[1]?.delivery).toBe("admitted");
  expect(workspace.selectedConversation?.rows[1]?.steer).toBe(true);
  canonical = [
    prompt,
    {
      turnId: "active",
      item: { type: "userMessage", id: "provider-steer", clientId, content: sent?.params.input },
    },
    canonical[1],
  ];
  await workspace.loadConversation(address);
  expect(workspace.selectedConversation?.rows.map((row) => row.entry.item.id)).toEqual([
    "prompt",
    "provider-steer",
    "after-steer",
  ]);
  expect(workspace.selectedConversation?.rows[1]?.delivery).toBeUndefined();
  expect(workspace.selectedConversation?.rows[1]?.steer).toBe(false);
});

test("untaken steers survive eviction and reload until a canonical echo reconciles their exact input", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  let firstInput: unknown;
  let firstClientId: string | undefined;
  harness.handler = (method, params) =>
    method === "turn/steer" ? { turnId: params.expectedTurnId } : undefined;
  let firstAddress: Address | undefined;
  for (let index = 0; index < 6; index++) {
    workspace.newConversation();
    workspace.updateDraft({ model: "test-model", text: `Initial ${index}` });
    await workspace.send();
    const conversation = workspace.selectedConversation;
    const original = conversation?.rows[0]?.entry.item;
    if (!conversation || original?.type !== "userMessage") throw new Error("Missing initial input");
    firstAddress ??= conversation.address;
    harness.emit("item/completed", {
      threadId: conversation.address.threadId,
      turnId: "running",
      item: { ...original, id: `canonical-${index}` },
    });
    workspace.updateDraft({
      text: `Untaken steer ${index}`,
      attachments: [
        {
          id: "f",
          name: "plan.txt",
          path: "/workspace/plan.txt",
          bytes: 12,
          type: "text/plain",
          sha256: "test",
        },
      ],
    });
    await workspace.send();
    if (index === 0) {
      const sent = harness.calls.find((call) => call.method === "turn/steer");
      firstInput = sent?.params.input;
      firstClientId = String(sent?.params.clientUserMessageId);
    }
    harness.emit("turn/completed", {
      threadId: conversation.address.threadId,
      turn: { id: "running", status: index % 2 ? "interrupted" : "completed" },
    });
    expect(conversation.rows.at(-1)?.delivery).toBe("uncertain");
    expect(conversation.rows.at(-1)?.steer).toBe(true);
  }
  workspace.newConversation();
  workspace.updateDraft({ model: "test-model", text: "Seventh" });
  await workspace.send();
  if (!firstAddress) throw new Error("Missing first address");
  expect(workspace.getSnapshot().conversations.has(addressKey(firstAddress))).toBe(false);
  expect(workspace.getSnapshot().conversations.size).toBe(6);
  await workspace.selectConversation(firstAddress);
  expect(workspace.selectedConversation?.rows.at(-1)?.entry.item).toMatchObject({ content: firstInput });
  workspace.dispose();
  const reloaded = await setup(["mini"], storage);
  expect(reloaded.workspace.getSnapshot().error).toBeUndefined();
  reloaded.harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await reloaded.workspace.selectConversation(firstAddress);
  expect(reloaded.workspace.selectedConversation?.rows.at(-1)).toMatchObject({
    steer: true,
    delivery: "uncertain",
    entry: { item: { clientId: firstClientId, content: firstInput } },
  });
  expect(reloaded.harness.calls.some((call) => ["turn/start", "turn/steer"].includes(call.method))).toBe(
    false,
  );
  reloaded.harness.emit("item/completed", {
    threadId: firstAddress.threadId,
    turnId: "after-stop",
    item: { type: "userMessage", id: "echo-after-stop", clientId: firstClientId, content: firstInput },
  });
  expect(reloaded.workspace.selectedConversation?.rows).toHaveLength(1);
  expect(reloaded.workspace.selectedConversation?.rows[0]?.steer).toBe(false);
  expect(storage.getItem("remotecoder.web.submissions.v1")).not.toContain(firstClientId ?? "missing");
});

test("a steer acknowledgement after turn completion cannot resurrect the turn or confirm untaken input", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("turn/started", { threadId: "shared", turn: { id: "active" } });
  const pending = deferred<unknown>();
  const dispatched = deferred<void>();
  harness.handler = (method) => {
    if (method !== "turn/steer") return undefined;
    dispatched.resolve();
    return pending.promise;
  };
  workspace.updateDraft({ model: "test-model", text: "Arrived at the end" });
  const sending = workspace.send();
  await dispatched.promise;
  harness.emit("turn/completed", { threadId: "shared", turn: { id: "active", status: "completed" } });
  pending.resolve({ turnId: "active" });
  await sending;
  expect(workspace.selectedConversation?.activeTurnId).toBeNull();
  expect(workspace.selectedConversation?.rows.at(-1)?.delivery).toBe("uncertain");
  expect(workspace.selectedConversation?.rows.at(-1)?.steer).toBe(true);
});

test("recovery leaves steers pending for unknown activity and unconfirms them once the turn is known to have ended", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  let active = true;
  let covered = true;
  harness.handler = (method, params) => {
    if (method === "daemon/activeTurns")
      return {
        ...activity(),
        coverage: { codex: true, claude: covered },
        activeTurns: active ? [{ threadId: "claude_owned", turnId: "active" }] : [],
      };
    if (method === "turn/steer") return { turnId: "active" };
    return previous?.(method, params);
  };
  const address = { hostId: "mini", threadId: "claude_owned" };
  await workspace.selectConversation(address);
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("Missing Claude model");
  workspace.updateDraft({ model: choice.id, text: "Input without a terminal notification" });
  await workspace.send();
  active = false;
  covered = false;
  await workspace.loadConversation(address);
  expect(workspace.selectedConversation?.activeTurnId).toBeUndefined();
  expect(workspace.selectedConversation?.rows.at(-1)?.delivery).toBe("admitted");
  covered = true;
  await workspace.loadConversation(address);
  expect(workspace.selectedConversation?.activeTurnId).toBeNull();
  expect(workspace.selectedConversation?.rows.at(-1)?.delivery).toBe("uncertain");
});

test("a canonical user echo arriving before its send acknowledgment stays canonical", async () => {
  const { workspace, harness } = await setupClaude();
  const previous = harness.handler;
  const address = { hostId: "mini", threadId: "claude_owned" };
  harness.handler = (method, params) => {
    if (method === "daemon/activeTurns")
      return { ...activity(), activeTurns: [{ threadId: address.threadId, turnId: "active" }] };
    if (method === "turn/steer") {
      harness.emit("item/completed", {
        threadId: address.threadId,
        turnId: "active",
        item: {
          type: "userMessage",
          id: params.clientUserMessageId,
          clientId: params.clientUserMessageId,
          content: params.input,
        },
      });
      return { turnId: "active" };
    }
    return previous?.(method, params);
  };
  await workspace.selectConversation(address);
  const choice = workspace.choices().find((choice) => choice.provider === "claude");
  if (!choice) throw new Error("Missing Claude fixture model");
  workspace.updateDraft({ model: choice.id, text: "Canonical before acknowledgment" });
  await workspace.send();
  expect(workspace.selectedConversation?.rows[0]?.delivery).toBeUndefined();
});

test("a steer acknowledged during unknown activity stays admitted until activity confirms its turn ended", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("turn/started", { threadId: "shared", turn: { id: "active" } });
  const pending = deferred<unknown>();
  const dispatched = deferred<void>();
  harness.handler = (method) => {
    if (method !== "turn/steer") return undefined;
    dispatched.resolve();
    return pending.promise;
  };
  workspace.updateDraft({ model: "test-model", text: "Possibly still running" });
  const sending = workspace.send();
  await dispatched.promise;
  harness.emit("daemon/activeTurnsChanged", activity(false));
  pending.resolve({ turnId: "active" });
  await sending;
  expect(workspace.selectedConversation?.activeTurnId).toBeUndefined();
  expect(workspace.selectedConversation?.rows.at(-1)?.delivery).toBe("admitted");
  harness.emit("daemon/activeTurnsChanged", activity());
  expect(workspace.selectedConversation?.rows.at(-1)?.delivery).toBe("uncertain");
});

test("restoring an unconfirmed steer preserves draft input and attachment identities while freeing exhausted receipts", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  const address = { hostId: "mini", threadId: "shared" };
  await workspace.selectConversation(address);
  harness.handler = (method, params) =>
    method === "turn/steer" ? { turnId: params.expectedTurnId } : undefined;
  const attachment = {
    id: "original-attachment",
    name: "Original.txt",
    path: "/workspace/original.txt",
    bytes: 12,
    type: "text/plain",
    sha256: "original-hash",
  };
  let firstId = "";
  for (let index = 0; index < 64; index++) {
    const turnId = `turn-${index}`;
    harness.emit("turn/started", { threadId: "shared", turn: { id: turnId } });
    workspace.updateDraft({ text: `  Steer ${index}\n`, attachments: [attachment] });
    await workspace.send();
    if (index === 0) {
      firstId = String(harness.calls.at(-1)?.params.clientUserMessageId);
      expect(() => workspace.restoreSteer(address, firstId)).toThrow();
    }
    harness.emit("turn/completed", { threadId: "shared", turn: { id: turnId, status: "interrupted" } });
  }
  const existing = {
    ...attachment,
    id: "existing-attachment",
    name: "Existing.txt",
    path: "/workspace/existing.txt",
  };
  workspace.updateDraft({ text: "Existing draft", attachments: [existing] });
  await expect(workspace.send()).rejects.toThrow("Too many unresolved submission receipts");
  workspace.dispose();
  const reloaded = await setup(["mini"], storage);
  await reloaded.workspace.selectConversation(address);
  const removed: string[] = [];
  reloaded.workspace.setRenderer({
    append() {},
    update() {},
    remove(id) {
      removed.push(id);
    },
    dispose() {},
  });
  const before = reloaded.harness.calls.length;
  reloaded.workspace.restoreSteer({ threadId: address.threadId, hostId: address.hostId }, firstId);
  expect(reloaded.harness.calls).toHaveLength(before);
  expect(reloaded.workspace.draft).toMatchObject({
    text: "Existing draft\n  Steer 0\n",
    attachments: [existing, attachment],
  });
  expect(reloaded.workspace.selectedConversation?.rows.some((row) => row.entry.item.id === firstId)).toBe(
    false,
  );
  expect(removed).toContain(`${JSON.stringify(address)}\u0000${firstId}`);
  expect(JSON.parse(storage.getItem("remotecoder.web.submissions.v1") ?? "[]")).toHaveLength(63);
  expect(() => reloaded.workspace.restoreSteer(address, firstId)).toThrow();
  reloaded.workspace.dispose();
  const again = await setup(["mini"], storage);
  await again.workspace.selectConversation(address);
  expect(again.workspace.draft).toMatchObject({
    text: "Existing draft\n  Steer 0\n",
    attachments: [existing, attachment],
  });
  expect(again.workspace.selectedConversation?.rows.some((row) => row.entry.item.id === firstId)).toBe(false);
  await again.workspace.send();
  expect(again.harness.calls.filter((call) => call.method === "turn/start")).toHaveLength(1);
});

test("acknowledged steer receipts do not pin cleared drafts beyond the draft capacity", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method, params) =>
    method === "turn/steer" ? { turnId: params.expectedTurnId } : undefined;
  let firstAddress: Address | undefined;
  let firstId = "";
  for (let index = 0; index < 35; index++) {
    workspace.newConversation();
    workspace.updateDraft({ text: `Initial ${index}` });
    await workspace.send();
    const conversation = workspace.selectedConversation;
    const prompt = conversation?.rows[0]?.entry.item;
    if (!conversation || prompt?.type !== "userMessage") throw new Error("Missing initial input");
    harness.emit("item/completed", {
      threadId: conversation.address.threadId,
      turnId: "running",
      item: { ...prompt, id: `prompt-${index}` },
    });
    workspace.updateDraft({ text: `Untaken ${index}` });
    await workspace.send();
    if (index === 0) {
      firstAddress = conversation.address;
      firstId = String(harness.calls.at(-1)?.params.clientUserMessageId);
    }
    harness.emit("turn/completed", {
      threadId: conversation.address.threadId,
      turn: { id: "running", status: "interrupted" },
    });
  }
  if (!firstAddress) throw new Error("Missing first conversation");
  expect(workspace.getSnapshot().drafts.size).toBeLessThanOrEqual(32);
  expect(workspace.getSnapshot().drafts.has(addressKey(firstAddress))).toBe(false);
  await workspace.selectConversation(firstAddress);
  workspace.restoreSteer(firstAddress, firstId);
  expect(workspace.draft.text).toBe("Untaken 0");
});

test("loading recovered steers keeps them at their owning turn before later history and live output", async () => {
  for (const placement of ["own-turn", "later-turn", "live-later-turn", "no-later-turn"]) {
    const storage = new MemoryStorage();
    const { workspace, harness } = await setup(["mini"], storage);
    const address = { hostId: "mini", threadId: "shared" };
    await workspace.selectConversation(address);
    harness.handler = (method) => (method === "turn/steer" ? { turnId: "t1" } : undefined);
    harness.emit("turn/started", { threadId: "shared", turn: { id: "t1" } });
    workspace.updateDraft({ text: "Untaken input" });
    await workspace.send();
    const steer = workspace.selectedConversation?.rows.at(-1)?.entry;
    if (!steer || steer.startedAtMs === null) throw new Error("Missing steer");
    harness.emit("turn/completed", { threadId: "shared", turn: { id: "t1", status: "completed" } });
    workspace.dispose();
    const history = [
      {
        turnId: "t0",
        startedAtMs: steer.startedAtMs - 1000,
        item: { type: "agentMessage", id: "older", text: "Older turn" },
      },
      ...(placement === "own-turn"
        ? [
            {
              turnId: "t1",
              startedAtMs: steer.startedAtMs - 100,
              item: { type: "agentMessage", id: "own-first", text: "Own turn" },
            },
            {
              turnId: "t1",
              startedAtMs: steer.startedAtMs + 100,
              item: { type: "agentMessage", id: "own-last", text: "Own tail" },
            },
          ]
        : []),
      ...(placement !== "no-later-turn"
        ? [
            {
              turnId: "t2",
              startedAtMs: null,
              item: { type: "agentMessage", id: "later-first", text: "Next turn" },
            },
            {
              turnId: "t2",
              startedAtMs: steer.startedAtMs + 1000,
              item: { type: "agentMessage", id: "later-last", text: "Next tail" },
            },
          ]
        : []),
    ];
    const reloaded = await setup(["mini"], storage);
    reloaded.harness.handler = (method) => {
      if (method === "thread/items/list") return { data: history.toReversed(), nextCursor: null };
      if (method === "daemon/activeTurns" && placement === "live-later-turn")
        return { ...activity(), activeTurns: [{ threadId: "shared", turnId: "t2" }] };
    };
    await reloaded.workspace.selectConversation(address);
    const expected = [
      "older",
      ...(placement === "own-turn" ? ["own-first", "own-last"] : []),
      steer.item.id,
      ...(placement !== "no-later-turn" ? ["later-first", "later-last"] : []),
    ];
    expect(reloaded.workspace.selectedConversation?.rows.map((row) => row.entry.item.id)).toEqual(expected);
    await reloaded.workspace.loadConversation(address);
    expect(reloaded.workspace.selectedConversation?.rows.map((row) => row.entry.item.id)).toEqual(expected);
    expect(
      reloaded.workspace.selectedConversation?.rows.find((row) => row.entry.item.id === steer.item.id)
        ?.delivery,
    ).toBe("uncertain");
  }
});

test("a full transcript window keeps an older recovered steer available for explicit restoration", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  const address = { hostId: "mini", threadId: "shared" };
  await workspace.selectConversation(address);
  harness.handler = (method) => (method === "turn/steer" ? { turnId: "old-turn" } : undefined);
  harness.emit("turn/started", { threadId: "shared", turn: { id: "old-turn" } });
  workspace.updateDraft({ text: "Do not lose this unconfirmed input" });
  await workspace.send();
  const clientId = String(harness.calls.at(-1)?.params.clientUserMessageId);
  harness.emit("turn/completed", { threadId: "shared", turn: { id: "old-turn", status: "completed" } });
  workspace.dispose();
  const canonical = Array.from({ length: 300 }, (_, index) => ({
    turnId: "new-turn",
    startedAtMs: null,
    item: { type: "agentMessage", id: `later-${index}`, text: `Later output ${index}` },
    isComplete: true,
  }));
  const reloaded = await setup(["mini"], storage);
  reloaded.harness.handler = (method) => {
    if (method === "thread/subscribe")
      return {
        status: "subscribed",
        subscriptionId: "full",
        thread: header(),
        checkpoint: { itemsBackwardsCursor: "tail", liveItems: canonical.slice(100) },
      };
    if (method === "thread/items/list")
      return { data: canonical.slice(0, 100).toReversed(), nextCursor: null };
    if (method === "daemon/activeTurns")
      return { ...activity(), activeTurns: [{ threadId: "shared", turnId: "new-turn" }] };
  };
  await reloaded.workspace.selectConversation(address);
  expect(reloaded.workspace.selectedConversation?.rows).toHaveLength(240);
  expect(reloaded.workspace.selectedConversation?.rows[0]?.entry.item.id).toBe(clientId);
  reloaded.workspace.restoreSteer(address, clientId);
  expect(reloaded.workspace.draft.text).toBe("Do not lose this unconfirmed input");
});
