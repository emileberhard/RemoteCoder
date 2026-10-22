import { afterEach, expect, test } from "bun:test";
import { object } from "../src/protocol/boundary";
import { favoriteFolders } from "../src/workspace/favorite-folder";
import { deferred, header, host, MemoryStorage, setup, workspaces } from "./fixtures/workspace";

afterEach(() => {
  for (const workspace of workspaces.splice(0)) workspace.dispose();
});
const rows = (workspace: Awaited<ReturnType<typeof setup>>["workspace"]) =>
  workspace.conversationDrawer.sections.flatMap((section) => section.rows);
class FailingStorage extends MemoryStorage {
  failingHost?: string;
  override setItem(key: string, value: string) {
    if (this.failingHost && key.startsWith("remotecoder.web.marks.") && key.includes(`"${this.failingHost}"`))
      throw new Error("Fixture storage unavailable");
    super.setItem(key, value);
  }
}

test("discard undo restores the saved draft and its active location until its workspace deadline", async () => {
  const { workspace } = await setup(["mini"], new MemoryStorage());
  workspace.updateDraft({ text: "Keep this unsent input" });
  const key = workspace.draftKey;
  const saved = workspace.draft;
  const discard = workspace.discardDraft(key);
  expect(discard.count).toBe(1);
  expect(discard.expiresAt).toBeGreaterThan(Date.now());
  discard.undo();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(workspace.draftKey).toBe(key);
  expect(workspace.draft).toEqual(saved);
  const expired = workspace.discardDraft(key);
  const clock = Date.now;
  try {
    Date.now = () => expired.expiresAt;
    expect(() => expired.undo()).toThrow("expired");
    expect(workspace.getSnapshot().drafts.has(key)).toBe(false);
  } finally {
    Date.now = clock;
  }
});

test("partial host write failures retain settlement Undo and do not abort mark-all-read", async () => {
  const storage = new FailingStorage();
  const { workspace } = await setup(["mini", "book"], storage);
  storage.failingHost = "book";
  const settled = workspace.settleConversations([
    { hostId: "mini", threadId: "shared" },
    { hostId: "book", threadId: "shared" },
  ]);
  expect(settled.count).toBe(1);
  expect(workspace.conversationMarks({ hostId: "mini" })?.marks?.threads.shared?.settlement?.state).toBe(
    "settled",
  );
  expect(workspace.conversationMarks({ hostId: "book" })?.marks?.threads.shared?.settlement).toBeUndefined();
  expect(workspace.getSnapshot().error).toContain("book");
  storage.failingHost = undefined;
  settled.undo();
  expect(workspace.conversationMarks({ hostId: "mini" })?.marks?.threads.shared?.settlement?.state).toBe(
    "active",
  );
  storage.failingHost = "mini";
  workspace.markAllRead();
  expect(workspace.conversationMarks({ hostId: "book" })?.marks?.readBaseline).toBeGreaterThan(0);
});

test("retrying a partial settlement Undo restores only hosts still awaiting restoration", async () => {
  const storage = new FailingStorage();
  const { workspace } = await setup(["mini", "book"], storage);
  const mini = { hostId: "mini", threadId: "shared" };
  const book = { hostId: "book", threadId: "shared" };
  workspace.pinConversation(mini, "Original Mini pin");
  workspace.pinConversation(book, "Original Book pin");
  const settled = workspace.settleConversations([mini, book]);
  storage.failingHost = "book";
  expect(() => settled.undo()).toThrow("book");
  workspace.pinConversation(mini, "New Mini pin");
  storage.failingHost = undefined;
  settled.undo();
  expect(workspace.conversationMarks(mini)?.marks?.threads.shared?.pinName).toBe("New Mini pin");
  expect(workspace.conversationMarks(book)?.marks?.threads.shared?.pinName).toBe("Original Book pin");
});

test("drawer reopening resets temporary reveals while focus recapture preserves them and pinning unfolds", async () => {
  const { workspace } = await setup();
  workspace.openDrawer();
  workspace.revealProject("project");
  workspace.revealMoreSettled();
  workspace.openDrawer();
  expect(workspace.drawerArrangement.revealedProjects.has("project")).toBe(true);
  expect(workspace.drawerArrangement.settledRowLimit).toBe(35);
  workspace.closeDrawer();
  workspace.openDrawer();
  expect(workspace.drawerArrangement.revealedProjects.size).toBe(0);
  expect(workspace.drawerArrangement.settledRowLimit).toBe(10);
  workspace.setPinnedFolded(true);
  workspace.pinConversation({ hostId: "mini", threadId: "shared" }, "Keep visible");
  expect(workspace.drawerArrangement.isPinnedFolded).toBe(false);
});

test("selected row actions read marks even when drawer filters hide the conversation", async () => {
  const { workspace } = await setup();
  const address = { hostId: "mini", threadId: "shared" };
  await workspace.selectConversation(address);
  workspace.pinConversation(address, "Selected pin");
  workspace.markConversationUnread(address);
  workspace.setDrawerQuery("nothing matches this query");
  expect(rows(workspace)).toHaveLength(0);
  expect(workspace.selectedConversationRowState).toMatchObject({
    title: "Selected pin",
    isPinned: true,
    isUnread: true,
    settlement: "unsettled",
    canSettle: true,
  });
});

test("an exact older conversation retains one header for filtered titles and settlement across refresh", async () => {
  const { workspace, harness } = await setup();
  const now = Math.floor(Date.now() / 1000);
  const address = { hostId: "mini", threadId: "outside-page" };
  const older = {
    ...header(address.threadId),
    name: null,
    preview: "First submitted message",
    createdAt: now,
    recencyAt: now,
    lastTurnCompletedAt: now - 5,
  };
  harness.handler = (method, params) => {
    if (method === "thread/read") return { thread: older };
    if (method === "thread/subscribe" && params.threadId === address.threadId)
      return {
        status: "subscribed",
        subscriptionId: "old",
        thread: older,
        checkpoint: { itemsBackwardsCursor: null, liveItems: [] },
      };
    return undefined;
  };
  await workspace.selectConversation(address);
  workspace.setDrawerQuery("not present in this conversation");
  expect(rows(workspace)).toHaveLength(0);
  expect(workspace.selectedConversationRowState).toMatchObject({
    title: "First submitted message",
    canSettle: true,
  });
  workspace.settleConversation(address);
  expect(workspace.selectedConversationRowState?.settlement).toBe("settled");
  await workspace.refreshHost("mini");
  expect(workspace.selectedHost?.threads.some((header) => header.id === address.threadId)).toBe(true);
  workspace.unsettleConversation(address);
  expect(workspace.selectedConversationRowState?.settlement).toBe("unsettled");
});

test("sidebar history distinguishes loading, partial failure and successfully empty reads", async () => {
  const { workspace, harness } = await setup();
  const page = deferred<unknown>();
  harness.handler = (method) => (method === "thread/list" ? page.promise : undefined);
  const refresh = workspace.refreshHost("mini");
  expect(workspace.getSnapshot().sidebar.hostStates[0]?.history).toBe("loading");
  page.resolve({ data: [], nextCursor: null });
  await refresh;
  expect(workspace.getSnapshot().sidebar.hostStates[0]?.history).toBe("ready");
  expect(rows(workspace)).toHaveLength(0);
  harness.handler = (method) => {
    if (method === "thread/list") throw new Error("Codex history offline");
    return undefined;
  };
  await workspace.refreshHost("mini");
  expect(workspace.conversationMarks()?.status).toBe("ready");
  expect(workspace.getSnapshot().sidebar.hostStates[0]?.history).toBe("failed");
  expect(workspace.getSnapshot().sidebar.hostStates[0]?.errors).toContain("Codex history offline");
});

test("Workspace caches sidebar projection across unrelated and streamed text publications", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  harness.emit("turn/started", { threadId: "shared", turn: { id: "live" } });
  const first = workspace.getSnapshot().sidebar;
  workspace.report("unrelated");
  expect(workspace.getSnapshot().sidebar).toBe(first);
  harness.emit("thread/tokenUsage/updated", {
    threadId: "shared",
    tokenUsage: { total: { totalTokens: 10000 }, last: { totalTokens: 745 }, modelContextWindow: 1000 },
  });
  await new Promise((resolve) => setTimeout(resolve, 90));
  expect(workspace.getSnapshot().sidebar).toBe(first);
  expect(workspace.contextWindowUsage).toMatchObject({ usedTokens: 745, usedPercent: 75, level: "amber" });
});

test("marks actions use the exact owning host, remain optimistic, and regenerate header and history titles", async () => {
  const { workspace, harnesses } = await setup(["mini", "book"], new MemoryStorage());
  const address = { hostId: "book", threadId: "shared" };
  workspace.setSettledFolded(false);
  workspace.pinConversation(address, "  Named pin  ");
  expect(rows(workspace).find((row) => row.address.hostId === "book")?.title).toBe("Named pin");
  expect(rows(workspace).find((row) => row.address.hostId === "mini")?.isPinned).toBe(false);
  workspace.markConversationUnread(address);
  expect(rows(workspace).find((row) => row.address.hostId === "book")?.isUnread).toBe(true);
  workspace.settleConversation(address);
  expect(rows(workspace).find((row) => row.address.hostId === "book")).toMatchObject({
    settlement: "settled",
    isPinned: false,
    isUnread: false,
  });
  workspace.unsettleConversation(address);
  expect(rows(workspace).find((row) => row.address.hostId === "book")?.settlement).toBe("unsettled");
  workspace.markConversationRead(address);
  workspace.markAllRead();
  await Promise.all([workspace.refreshHost("mini"), workspace.refreshHost("book")]);
  const rpc = harnesses.get("book");
  if (!rpc) throw new Error("missing fixture");
  await workspace.selectConversation(address);
  rpc.handler = (method) =>
    method === "conversation/title/regenerate" ? { name: "Generated title" } : undefined;
  await workspace.regenerateTitle();
  expect(workspace.selectedConversation?.header.name).toBe("Generated title");
  expect(workspace.getSnapshot().contexts.get(JSON.stringify(["book", null, null]))?.threads[0]?.name).toBe(
    "Generated title",
  );
  const writes = rpc.calls.filter((call) => call.method === "conversation/marks/update");
  expect(
    writes.flatMap((call) => call.params.changes as unknown[]).map((change) => object(change).op),
  ).toContain("settle");
});

test("drawer mode is synced; unread and fold preferences stay local; palette unfolds capped groups", async () => {
  const storage = new MemoryStorage();
  const { workspace, harness } = await setup(["mini"], storage);
  const now = Math.floor(Date.now() / 1000);
  harness.handler = (method) =>
    method === "thread/list"
      ? {
          data: Array.from({ length: 8 }, (_, index) => ({
            ...header(`thread${index}`),
            createdAt: now,
            recencyAt: now,
          })),
          nextCursor: null,
        }
      : undefined;
  await workspace.refreshHost("mini");
  workspace.setDrawerMode("projects");
  expect(workspace.drawerArrangement.mode).toBe("projects");
  expect(workspace.conversationDrawer.sections[0]?.hiddenCount).toBe(3);
  workspace.setProjectFolded("mini|directory|/workspace", true);
  expect(rows(workspace)).toHaveLength(0);
  expect(workspace.unfoldedConversationRows()).toHaveLength(8);
  workspace.setDrawerUnreadOnly(true);
  const synced = JSON.parse(storage.getItem("remotecoder.web.preferences.v1") ?? "{}");
  expect(synced.entries["conversationDrawer.mode"].value).toBe("projects");
  expect(synced.entries["conversationDrawer.unreadOnly"]).toBeUndefined();
  expect(JSON.parse(storage.getItem("remotecoder.web.drawer.v1") ?? "{}").unreadOnly).toBe(true);
});

test("directory selection is fenced by picker lifetime and favorites preserve physical host identity", async () => {
  const { workspace, harnesses } = await setup(["mini", "book"]);
  const mini = workspace.hostDirectories("mini");
  mini.receiveFavorites({ revision: 1, paths: ["/home/fixture", "/one/repo", "/two/repo"] });
  const favorites = workspace.getSnapshot().favoriteFolders;
  expect(favorites.map((folder) => folder.title)).toEqual(["Home", "/one/repo", "/two/repo"]);
  expect(favorites.every((folder) => folder.hostId === "mini" && folder.showsHostLabel)).toBe(true);
  harnesses.get("mini")?.calls.splice(0);
  workspace.openDirectoryPicker("mini");
  const selecting = workspace.chooseDirectory("/chosen");
  workspace.selectHost("book");
  await selecting;
  expect(workspace.selectedHost?.host.id).toBe("book");
  expect(workspace.draft.cwd).toBe("/workspace");
  expect(workspace.getSnapshot().directoryPicker).toBeUndefined();
  expect(favoriteFolders([{ id: "x", name: "X", homePath: undefined, paths: ["/"] }])[0]?.title).toBe("/");
});

test("a retired history refresh cannot create drawer owners for a replacement host", async () => {
  const { workspace, harness } = await setup();
  const waiting = deferred<unknown>();
  harness.handler = (method) => (method === "thread/list" ? waiting.promise : undefined);
  const refresh = workspace.refreshHost("mini");
  workspace.configureHosts([{ ...host("mini"), url: "https://replacement.example" }]);
  waiting.resolve({ data: [header("old")], nextCursor: null });
  await refresh;
  expect(rows(workspace)).toHaveLength(0);
  expect(workspace.conversationMarks()?.status).toBe("unread");
});

test("batch settlement undo restores captured pin and unread once, with native completion watermarks", async () => {
  const { workspace, harness } = await setup();
  const now = Math.floor(Date.now() / 1000);
  harness.handler = (method) =>
    method === "thread/list"
      ? { data: [{ ...header(), createdAt: now, lastTurnCompletedAt: now - 100 }], nextCursor: null }
      : undefined;
  await workspace.refreshHost("mini");
  const address = { hostId: "mini", threadId: "shared" };
  workspace.markConversationRead(address);
  expect(workspace.conversationMarks()?.marks?.threads.shared?.seenThrough).toBe(now - 100);
  workspace.pinConversation(address, "Restore pin");
  workspace.markConversationUnread(address);
  const settlement = workspace.settleConversations([address, address]);
  expect(settlement.count).toBe(1);
  expect(workspace.conversationMarks()?.marks?.threads.shared).toMatchObject({
    markedUnread: false,
    pinName: undefined,
    settlement: { state: "settled" },
  });
  settlement.undo();
  expect(workspace.conversationMarks()?.marks?.threads.shared).toMatchObject({
    markedUnread: true,
    pinName: "Restore pin",
    settlement: { state: "active" },
  });
  const pending = workspace.conversationMarks()?.pendingCount;
  settlement.undo();
  expect(workspace.conversationMarks()?.pendingCount).toBe(pending);
  workspace.markConversationRead(address);
  expect(workspace.conversationMarks()?.marks?.threads.shared?.seenThrough).toBe(now);
});

test("presented completions acknowledge exactly the visible loaded completion and remain deduplicated", async () => {
  const { workspace, harness } = await setup();
  const now = Math.floor(Date.now() / 1000);
  harness.handler = (method, params) =>
    method === "thread/subscribe"
      ? {
          status: "subscribed",
          subscriptionId: "s",
          thread: { ...header(String(params.threadId)), lastTurnCompletedAt: now - 100 },
          checkpoint: { itemsBackwardsCursor: null, liveItems: [] },
        }
      : undefined;
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  expect(workspace.conversationMarks()?.marks?.threads.shared?.seenThrough).toBeUndefined();
  workspace.publishSeenCompletion();
  expect(workspace.conversationMarks()?.marks?.threads.shared?.seenThrough).toBe(now - 100);
  const pending = workspace.conversationMarks()?.pendingCount;
  workspace.publishSeenCompletion();
  expect(workspace.conversationMarks()?.pendingCount).toBe(pending);
  harness.emit("turn/completed", {
    threadId: "shared",
    turn: { id: "t", status: "completed", completedAt: now },
  });
  workspace.publishSeenCompletion();
  expect(workspace.conversationMarks()?.marks?.threads.shared?.seenThrough).toBe(now);
  expect(workspace.selectedConversation?.header.lastTurnCompletedAt).toBe(now);
});

test("addressed forks use the row owner and discarding an active unsent draft opens a blank successor", async () => {
  const storage = new MemoryStorage();
  const { workspace, harnesses } = await setup(["mini", "book"], storage);
  const book = harnesses.get("book");
  if (!book) throw new Error("missing fixture");
  book.handler = (method) => (method === "thread/fork" ? { thread: header("forked") } : undefined);
  await workspace.fork({ hostId: "book", threadId: "shared" });
  expect(workspace.getSnapshot().selected).toMatchObject({ hostId: "book", threadId: "forked" });
  expect(book.calls.find((call) => call.method === "thread/fork")?.params.threadId).toBe("shared");
  workspace.newConversation();
  workspace.updateDraft({ text: "Discard this" });
  const key = workspace.draftKey;
  workspace.discardDraft(key);
  expect(workspace.draftKey).not.toBe(key);
  expect(workspace.draft.text).toBe("");
  expect(workspace.getSnapshot().drafts.has(key)).toBe(false);
  expect(
    (JSON.parse(storage.getItem("remotecoder.web.drafts.v1") ?? "[]") as [string, unknown][]).some(
      ([saved]) => saved === key,
    ),
  ).toBe(false);
});

test("collapse and expand all sections publishes once per action in both modes and preserves palette access", async () => {
  const { workspace, harness } = await setup(["mini"], new MemoryStorage());
  const now = Math.floor(Date.now() / 1000);
  harness.marks = {
    schemaVersion: 3,
    revision: 1,
    readBaseline: now,
    threads: {
      automatic: { revision: 1, markedUnread: false, purpose: "automation" },
      pinned: { revision: 1, markedUnread: false, pinName: "Keep" },
    },
  };
  harness.handler = (method) =>
    method === "thread/list"
      ? {
          data: ["user", "automatic", "pinned", "old"].map((id) => ({
            ...header(id),
            createdAt: id === "old" ? now - 5 * 86400 : now,
            recencyAt: id === "old" ? now - 5 * 86400 : now,
          })),
          nextCursor: null,
        }
      : undefined;
  await workspace.refreshHost("mini");
  for (const mode of ["priority", "projects"] as const) {
    workspace.setDrawerMode(mode);
    let publications = 0;
    const unsubscribe = workspace.subscribe(() => publications++);
    workspace.setAllSectionsFolded(true);
    expect(publications).toBe(1);
    expect(
      workspace.conversationDrawer.sections
        .filter((section) => section.kind !== "chats")
        .every((section) => section.summary.fold === "folded"),
    ).toBe(true);
    expect(rows(workspace).map((row) => row.address.threadId)).toEqual(mode === "priority" ? ["user"] : []);
    expect(workspace.unfoldedConversationRows()).toHaveLength(4);
    workspace.setAllSectionsFolded(false);
    expect(publications).toBe(2);
    expect(rows(workspace)).toHaveLength(4);
    unsubscribe();
  }
});

test("a superseded failed question batch cannot erase a newer selected-session inventory", async () => {
  const { workspace, harness } = await setup();
  const reached = deferred<void>(),
    pending = deferred<unknown>();
  let reads = 0;
  const now = Math.floor(Date.now() / 1000);
  harness.handler = (method, params) => {
    if (method === "thread/list") return { data: [{ ...header(), createdAt: now }], nextCursor: null };
    if (method !== "conversation/questions/read") return undefined;
    if (++reads === 1) {
      reached.resolve();
      return pending.promise;
    }
    return {
      threads: (params.queries as { threadId: string }[]).map(({ threadId }) => ({
        threadId,
        epoch: "q",
        revision: 5,
        coverage: "ready",
        pendingItemIds: ["question"],
        records: [
          {
            itemId: "question",
            turnId: "t",
            revision: 5,
            askedAtMs: now * 1000,
            questions: [{ index: 0, title: "Question", options: ["A"], resolution: "pending", answer: null }],
          },
        ],
      })),
    };
  };
  const refresh = workspace.refreshHost("mini");
  await reached.promise;
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  pending.resolve(Promise.reject(new Error("old read failed")));
  await refresh;
  expect(rows(workspace).find((row) => row.address.threadId === "shared")?.questionCount).toBe(1);
  expect(reads).toBe(3);
});

test("a delayed regeneration response cannot replace a newer live title", async () => {
  const { workspace, harness } = await setup();
  const result = deferred<unknown>();
  harness.handler = (method) => (method === "conversation/title/regenerate" ? result.promise : undefined);
  const generating = workspace.regenerateTitle({ hostId: "mini", threadId: "shared" });
  harness.emit("thread/name/updated", { threadId: "shared", threadName: "Newer title" });
  result.resolve({ name: "Earlier generated title" });
  await generating;
  expect(workspace.getSnapshot().hosts[0]?.threads[0]?.name).toBe("Newer title");
});

test("discarding another draft is allowed while the selected conversation awaits a send acknowledgement", async () => {
  const { workspace, harness } = await setup();
  workspace.updateDraft({ text: "Unsent other draft" });
  const other = workspace.draftKey;
  workspace.newConversation();
  workspace.updateDraft({ text: "Send this" });
  const started = deferred<void>(),
    ack = deferred<unknown>();
  harness.handler = (method) => {
    if (method === "turn/start") {
      started.resolve();
      return ack.promise;
    }
    return undefined;
  };
  const sending = workspace.send();
  await started.promise;
  const captured = workspace.getSnapshot().drafts;
  expect(captured.has(other)).toBe(true);
  workspace.discardDraft(other);
  expect(workspace.getSnapshot().drafts.has(other)).toBe(false);
  ack.resolve({ turn: { id: "t" } });
  await sending;
});
