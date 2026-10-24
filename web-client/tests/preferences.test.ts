import { afterEach, expect, test } from "bun:test";
import type { Captured, Rpc } from "../src/gateway";
import { type PreferenceDocument, type PreferenceEntry, SyncedPreferences } from "../src/preferences";
import { type Frame, type Host, object } from "../src/protocol/boundary";
import { Workspace } from "../src/workspace/workspace";

const entry = (value: PreferenceEntry["value"], updatedAt = 100, device = "native"): PreferenceEntry => ({
  value,
  updatedAt,
  device,
});
const model = (id: string, hidden = false, isDefault = false) => ({
  id,
  model: id,
  displayName: id,
  hidden,
  isDefault,
  supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"].map((reasoningEffort) => ({
    reasoningEffort,
  })),
  defaultReasoningEffort: "medium",
  serviceTiers: [{ id: "fast" }],
  inputModalities: ["text", "image"],
});
const header = (id = "conversation", selected = "hidden") => ({
  id,
  model: selected,
  name: id,
  preview: "",
  cwd: "/workspace",
  reasoningEffort: "high",
  status: { type: "idle" },
  updatedAt: 1700000000,
  extra: null,
});
const configuration = (id: string): Host => ({
  id,
  name: id,
  cwd: "/workspace",
  url: "https://gateway.example",
  credentialStatus: "ready",
});
class MemoryStorage implements Storage {
  private readonly data = new Map<string, string>();
  get length() {
    return this.data.size;
  }
  clear() {
    this.data.clear();
  }
  getItem(key: string) {
    return this.data.get(key) ?? null;
  }
  key(index: number) {
    return [...this.data.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.data.delete(key);
  }
  setItem(key: string, value: string) {
    this.data.set(key, value);
  }
}
class Gateway implements Rpc {
  document: PreferenceDocument = { entries: {} };
  catalog = [model("gpt-6.1-sol"), model("other", false, true), model("hidden", true)];
  selectedModel = "hidden";
  offline = false;
  updates: PreferenceDocument[] = [];
  read?: () => Promise<unknown>;
  readModels?: () => Promise<unknown>;
  updateSettings?: () => Promise<unknown>;
  settings: Record<string, unknown>[] = [];
  constructor(readonly emit: (frame: Frame) => void) {}
  async call(method: string, params: unknown = {}): Promise<unknown> {
    if (method === "preferences/read") {
      if (this.offline) throw new Error("Offline host");
      return this.read ? this.read() : structuredClone(this.document);
    }
    if (method === "preferences/update") {
      if (this.offline) throw new Error("Offline host");
      const update = params as PreferenceDocument;
      this.updates.push(structuredClone(update));
      for (const [key, received] of Object.entries(update.entries)) {
        const previous = object(this.document.entries)[key] as PreferenceEntry | undefined;
        if (
          !previous ||
          received.updatedAt > previous.updatedAt ||
          (received.updatedAt === previous.updatedAt && received.device > previous.device)
        )
          Object.assign(this.document.entries, { [key]: structuredClone(received) });
      }
      this.emit({ method: "preferences/changed", params: structuredClone(this.document) });
      return structuredClone(this.document);
    }
    if (method === "model/list")
      return this.readModels ? this.readModels() : { data: this.catalog, nextCursor: null };
    if (method === "thread/list")
      return { data: [header("conversation", this.selectedModel)], nextCursor: null };
    if (method === "claude/thread/list")
      return { data: [header("claude_conversation", "claude-opus-4-6")], nextCursor: null };
    if (method === "thread/subscribe")
      return {
        status: "subscribed",
        subscriptionId: "s",
        thread: header("conversation", this.selectedModel),
        checkpoint: { itemsBackwardsCursor: null, liveItems: [] },
      };
    if (method === "thread/items/list" || method === "thread/queue/list")
      return { data: [], nextCursor: null };
    if (method === "conversation/questions/read") return { threads: [] };
    if (method === "claude/thread/liveCheckpoint")
      return { status: "unknown", threadId: "claude_conversation", reason: "noLiveState" };
    if (method === "daemon/activeTurns")
      return { epoch: "test", revision: 1, activeTurns: [], coverage: { codex: true, claude: true } };
    if (method === "conversation/settings/update") {
      this.settings.push(object(params));
      return this.updateSettings ? this.updateSettings() : { status: "applied" };
    }
    return {};
  }
  async capture(method: string, params?: unknown): Promise<Captured> {
    return { value: await this.call(method, params), receipt: { connection: 1, sequence: 0 } };
  }
  changed(document: PreferenceDocument) {
    this.document = structuredClone(document);
    this.emit({ method: "preferences/changed", params: structuredClone(document) });
  }
  notify() {}
  reply() {}
}
const workspaces: Workspace[] = [];
function setup(ids = ["mini"], storage?: Storage) {
  const gateways = new Map<string, Gateway>();
  const workspace = new Workspace((host, event) => {
    const gateway = new Gateway(event);
    gateways.set(host.id, gateway);
    return gateway;
  }, storage);
  workspaces.push(workspace);
  workspace.configureHosts(ids.map(configuration));
  const gateway = gateways.get(ids[0] ?? "mini");
  if (!gateway) throw new Error("Missing test gateway");
  return { workspace, gateways, gateway };
}
afterEach(() => {
  for (const workspace of workspaces.splice(0)) workspace.dispose();
});

test("a model change clamps capabilities locally without changing global reasoning or Fast choices", async () => {
  const { workspace, gateway } = setup();
  gateway.catalog.push({
    ...model("limited"),
    supportedReasoningEfforts: [{ reasoningEffort: "low" }],
    defaultReasoningEffort: "low",
    serviceTiers: [],
  });
  const reasoning = entry("effort-high");
  const fast = entry(true);
  gateway.document = {
    entries: {
      "codex.defaultModelID": entry("gpt-6.1-sol"),
      "codex.defaultReasoningSelection": reasoning,
      "codex.fastModeEnabled": fast,
    },
  };
  await workspace.refreshHost("mini");
  const limited = workspace.choices().find((choice) => choice.id === "limited");
  if (!limited) throw new Error("Missing limited model");
  await workspace.chooseModel(limited);
  await workspace.syncPreferences();
  expect(workspace.draft).toMatchObject({ model: "limited", effort: "low", fast: false });
  expect(gateway.document.entries["codex.defaultModelID"]?.value).toBe("limited");
  expect(gateway.document.entries["codex.defaultReasoningSelection"]).toEqual(reasoning);
  expect(gateway.document.entries["codex.fastModeEnabled"]).toEqual(fast);
  const selectedModel = structuredClone(gateway.document.entries["codex.defaultModelID"]);
  await workspace.chooseReasoning("");
  await workspace.syncPreferences();
  expect(gateway.document.entries["codex.defaultModelID"]).toEqual(selectedModel);
  expect(gateway.document.entries["codex.defaultReasoningSelection"]?.value).toBe("automatic");
  expect(gateway.document.entries["codex.fastModeEnabled"]).toEqual(fast);
  const automatic = structuredClone(gateway.document.entries["codex.defaultReasoningSelection"]);
  await workspace.chooseFastMode(false);
  await workspace.syncPreferences();
  expect(workspace.draft.effort).toBe("");
  expect(gateway.document.entries["codex.defaultModelID"]).toEqual(selectedModel);
  expect(gateway.document.entries["codex.defaultReasoningSelection"]).toEqual(automatic);
  expect(gateway.document.entries["codex.fastModeEnabled"]?.value).toBe(false);
});

test("a delayed picker acknowledgement cannot replace a newer native model choice", async () => {
  const { workspace, gateway } = setup();
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  const other = workspace.choices().find((choice) => choice.id === "other");
  if (!other) throw new Error("Missing alternative model");
  let acknowledge: (value: unknown) => void = () => {};
  gateway.updateSettings = () =>
    new Promise((resolve) => {
      acknowledge = resolve;
    });
  const choosing = workspace.chooseModel(other);
  const later = entry("gpt-6.1-sol", Number.MAX_SAFE_INTEGER - 10, "later-native-choice");
  gateway.changed({ entries: { ...gateway.document.entries, "codex.defaultModelID": later } });
  acknowledge({ status: "applied" });
  await choosing;
  await workspace.syncPreferences();
  expect(workspace.draft.model).toBe("other");
  expect(workspace.preference("codex.defaultModelID")).toBe("gpt-6.1-sol");
  expect(gateway.document.entries["codex.defaultModelID"]).toEqual(later);
  workspace.newConversation();
  expect(workspace.draft.model).toBe("gpt-6.1-sol");
});

test("catalog discovery seeds an edited draft without replacing its content, directory or explicit settings", async () => {
  for (const explicit of [false, true]) {
    const { workspace, gateway } = setup();
    gateway.document = {
      entries: {
        "codex.defaultModelID": entry("gpt-6.1-sol"),
        "codex.defaultReasoningSelection": entry("effort-high"),
        "codex.fastModeEnabled": entry(true),
      },
    };
    let resolveCatalog: (value: unknown) => void = () => {};
    let requested: () => void = () => {};
    const catalogRequested = new Promise<void>((resolve) => {
      requested = resolve;
    });
    gateway.readModels = () => {
      requested();
      return new Promise((resolve) => {
        resolveCatalog = resolve;
      });
    };
    const refreshing = workspace.refreshHost("mini");
    await catalogRequested;
    const attachment = {
      id: "file",
      name: "notes.txt",
      bytes: 3,
      type: "text/plain",
      path: "/chosen/notes.txt",
      sha256: "a".repeat(64),
    };
    workspace.updateDraft({
      text: "Typed before discovery",
      attachments: [attachment],
      cwd: "/chosen",
      ...(explicit ? { model: "other", provider: "codex" as const, effort: "low", fast: false } : {}),
    });
    const key = workspace.draftKey;
    resolveCatalog({ data: gateway.catalog, nextCursor: null });
    await refreshing;
    expect(workspace.draftKey).toBe(key);
    expect(workspace.draft).toMatchObject({
      model: explicit ? "other" : "gpt-6.1-sol",
      provider: "codex",
      effort: explicit ? "low" : "high",
      fast: !explicit,
      text: "Typed before discovery",
      attachments: [attachment],
      cwd: "/chosen",
    });
    expect(gateway.updates).toHaveLength(0);
  }
});

test("replicas merge independently per key and propagate native changes across every host", async () => {
  const { workspace, gateway: mini, gateways } = setup(["mini", "book"]);
  const book = gateways.get("book");
  if (!book) throw new Error("Missing book");
  mini.document = {
    entries: {
      "claude.modelVisibility": entry("-opus", 20),
      "appearance.selectedThemeID": entry("night", 50),
    },
  };
  book.document = {
    entries: { "claude.modelVisibility": entry("-fable", 30), "codex.fastModeEnabled": entry(true, 40) },
  };
  await workspace.syncPreferences();
  await workspace.syncPreferences();
  expect(workspace.preference("claude.modelVisibility")).toBe("-fable");
  expect(workspace.selectedThemeID).toBe("night");
  expect(workspace.preference("codex.fastModeEnabled")).toBe(true);
  expect(mini.document).toEqual(book.document);
  book.changed({
    entries: { ...book.document.entries, "appearance.selectedThemeID": entry("paperLight", 60) },
  });
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("paperLight");
  expect(mini.document.entries["appearance.selectedThemeID"]?.value).toBe("paperLight");
});

test("visibility keeps native upstream defaults, explicit overrides, and the active hidden model", async () => {
  const { workspace, gateway } = setup();
  gateway.document = {
    entries: {
      "codex.modelVisibility": entry("-other\n+hidden"),
      "claude.modelVisibility": entry("-opus\n-sonnet"),
    },
  };
  await workspace.refreshHost("mini");
  expect(workspace.choices().map((choice) => choice.id)).toEqual(["gpt-6.1-sol", "hidden", "fable", "haiku"]);
  expect(workspace.modelVisibilityChoices().find((choice) => choice.id === "other")?.visible).toBe(false);
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  workspace.setModelVisible("codex", "hidden", false);
  await workspace.syncPreferences();
  expect(workspace.draft.model).toBe("hidden");
  expect(
    workspace
      .choices()
      .filter((choice) => choice.provider === "codex")
      .map((choice) => choice.id),
  ).toEqual(["gpt-6.1-sol", "hidden"]);
  workspace.newConversation();
  expect(workspace.choices().some((choice) => choice.id === "hidden")).toBe(false);
  expect(gateway.document.entries["codex.modelVisibility"]?.value).toBe("-other");
  await workspace.selectConversation({ hostId: "mini", threadId: "claude_conversation" });
  expect(workspace.draft.model).toBe("opus");
  expect(workspace.choices().filter((choice) => choice.id === "opus")).toHaveLength(1);
  expect(workspace.modelVisibilityChoices().find((choice) => choice.id === "opus")?.visible).toBe(false);
});

test("unlisted Codex models remain selectable only in the conversation already using them", async () => {
  const { workspace, gateway } = setup();
  gateway.selectedModel = "retired-model";
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  expect(workspace.choices().find((choice) => choice.id === "retired-model")).toMatchObject({
    efforts: ["high"],
    images: true,
  });
  workspace.newConversation();
  expect(workspace.choices().some((choice) => choice.id === "retired-model")).toBe(false);
});

test("web visibility writes canonical native keys and removing an override restores the catalog default", async () => {
  const { workspace, gateway } = setup();
  await workspace.refreshHost("mini");
  workspace.setModelVisible("claude", "claude-opus-4-6", false);
  workspace.setModelVisible("codex", "hidden", true);
  await workspace.syncPreferences();
  expect(gateway.document.entries["claude.modelVisibility"]?.value).toBe("-opus");
  expect(gateway.document.entries["codex.modelVisibility"]?.value).toBe("+hidden");
  workspace.setModelVisible("claude", "opus", true);
  await workspace.syncPreferences();
  expect(gateway.document.entries["claude.modelVisibility"]?.value).toBe("");
});

test("a disconnected host catches up without turning a read failure into empty preferences", async () => {
  const { workspace, gateway: mini, gateways } = setup(["mini", "book"]);
  const book = gateways.get("book");
  if (!book) throw new Error("Missing book");
  book.offline = true;
  mini.document = { entries: { "appearance.selectedThemeID": entry("orchidNight") } };
  await workspace.syncPreferences();
  expect(workspace.getSnapshot().hosts[1]?.preferences.status).toBe("failed");
  expect(workspace.selectedThemeID).toBe("orchidNight");
  workspace.setPreference("appearance.selectedThemeID", "paperLight");
  await workspace.syncPreferences();
  book.offline = false;
  await workspace.restoreContext({ hostId: "book" });
  expect(book.document.entries["appearance.selectedThemeID"]?.value).toBe("paperLight");
  expect(workspace.getSnapshot().hosts[1]?.preferences.status).toBe("ready");
});

test("device tie breaks, stale reads, monotonic local changes and reset tombstones preserve newest values", async () => {
  const { workspace, gateway } = setup();
  const future = Number.MAX_SAFE_INTEGER - 10;
  gateway.document = { entries: { "appearance.selectedThemeID": entry("night", future, "z") } };
  await workspace.syncPreferences();
  gateway.changed({ entries: { "appearance.selectedThemeID": entry("paperLight", future, "a") } });
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("night");
  workspace.setPreference("appearance.selectedThemeID", "forestDusk");
  await workspace.syncPreferences();
  expect(gateway.document.entries["appearance.selectedThemeID"]?.updatedAt).toBe(future + 1);
  let resolve: (document: PreferenceDocument) => void = () => {};
  gateway.read = () =>
    new Promise((done) => {
      resolve = done;
    });
  const syncing = workspace.syncPreferences();
  gateway.changed({ entries: { "appearance.selectedThemeID": entry(null, future + 2) } });
  gateway.read = undefined;
  resolve({ entries: { "appearance.selectedThemeID": entry("night", future) } });
  await syncing;
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("caribbeanSunset");
  expect(workspace.preference("appearance.selectedThemeID")).toBeNull();
  expect(gateway.document.entries["appearance.selectedThemeID"]?.value).toBeNull();
});

test("cached values survive reload and the old browser theme is adopted without publishing a computed default", async () => {
  const storage = new MemoryStorage();
  storage.setItem("remotecoder.web.theme", "paperLight");
  const { workspace, gateway } = setup(["mini"], storage);
  expect(workspace.selectedThemeID).toBe("paperLight");
  await workspace.refreshHost("mini");
  expect(gateway.updates).toHaveLength(0);
  workspace.setPreference("appearance.selectedThemeID", "night");
  await workspace.syncPreferences();
  workspace.dispose();
  const reloaded = setup(["mini"], storage);
  expect(reloaded.workspace.selectedThemeID).toBe("night");
  await reloaded.workspace.syncPreferences();
  expect(reloaded.gateway.document.entries["appearance.selectedThemeID"]?.value).toBe("night");
});

test("fixed and last-selected defaults seed only the next fresh chat, preserving open drafts and native reasoning visibility", async () => {
  const { workspace, gateway } = setup();
  gateway.document = {
    entries: {
      "codex.newChatModel": entry("claude-opus-4-6"),
      "codex.newChatReasoning": entry("effort-max"),
      "reasoning.visibleLevels.claude": entry("low,high"),
      "codex.fastModeEnabled": entry(true),
    },
  };
  await workspace.refreshHost("mini");
  expect(workspace.draft).toMatchObject({ model: "opus", provider: "claude", effort: "high", fast: true });
  expect(workspace.choices().find((choice) => choice.id === "opus")?.efforts).toEqual(["low", "high"]);
  workspace.updateDraft({ text: "Keep this setup" });
  gateway.changed({
    entries: {
      ...gateway.document.entries,
      "codex.newChatModel": entry("gpt-6.1-sol", 200),
      "codex.newChatReasoning": entry("automatic", 200),
    },
  });
  await workspace.syncPreferences();
  expect(workspace.draft).toMatchObject({ model: "opus", text: "Keep this setup", effort: "high" });
  workspace.newConversation();
  expect(workspace.draft).toMatchObject({ model: "gpt-6.1-sol", effort: "", fast: true });
  workspace.setPreference("codex.newChatModel", "last-selected");
  workspace.setPreference("codex.newChatReasoning", "last-selected");
  const other = workspace.choices().find((choice) => choice.id === "other");
  await workspace.chooseModel(other);
  await workspace.chooseReasoning("low");
  await workspace.chooseFastMode(false);
  await workspace.syncPreferences();
  workspace.newConversation();
  expect(workspace.draft).toMatchObject({ model: "other", effort: "low", fast: false });
  expect(gateway.document.entries["codex.defaultReasoningSelection"]?.value).toBe("effort-low");
});

test("all models hidden never changes the preferred provider or invents a model", async () => {
  const { workspace, gateway } = setup();
  gateway.document = {
    entries: { "codex.modelVisibility": entry("-gpt-6.1-sol\n-other"), "codex.newChatModel": entry("other") },
  };
  await workspace.refreshHost("mini");
  expect(workspace.draft).toMatchObject({ model: "", provider: "codex" });
  expect(workspace.choices().filter((choice) => choice.provider === "codex")).toHaveLength(0);
  expect(gateway.updates).toHaveLength(0);
});

test("native-only keys stay outside the browser replica and unknown theme values do not publish defaults", async () => {
  const storage = new MemoryStorage();
  const { workspace, gateway } = setup(["mini"], storage);
  gateway.document = {
    entries: {
      "appearance.selectedThemeID": entry("future-theme"),
      "conversationDrawer.mode": entry("projects"),
    },
  };
  const nativeOnly = {
    "accounts.names-by-group.v1": entry({ "codex:group": "Personal" }),
    "transcription.model": entry("elevenLabsScribeV2Realtime"),
    "transcription.language": entry("englishAndSwedish"),
    ttsAutoSpeakEnabled: entry(true),
    "realtimeVoice.selectedVoice": entry("voice-id"),
  };
  Object.assign(gateway.document.entries, nativeOnly);
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("caribbeanSunset");
  expect(gateway.updates).toHaveLength(0);
  const saved = JSON.parse(storage.getItem("remotecoder.web.preferences.v1") ?? "{}");
  expect(Object.keys(saved.entries)).toEqual(["appearance.selectedThemeID", "conversationDrawer.mode"]);
  expect(workspace.drawerArrangement.mode).toBe("projects");
  expect(gateway.document.entries).toMatchObject(nativeOnly);
});

test("invalid wire versions and oversized values fail the host read without replacing known values", async () => {
  const { workspace, gateway } = setup();
  gateway.document = { entries: { "appearance.selectedThemeID": entry("night") } };
  await workspace.syncPreferences();
  for (const invalid of [
    entry("paperLight", 0),
    entry("paperLight", Number.MAX_SAFE_INTEGER + 1),
    entry("x".repeat(8193)),
  ]) {
    gateway.document = { entries: { "appearance.selectedThemeID": invalid } };
    await workspace.syncPreferences();
    expect(workspace.getSnapshot().hosts[0]?.preferences.status).toBe("failed");
    expect(workspace.selectedThemeID).toBe("night");
  }
});

test("a retired host cannot apply a delayed preference read or notification to its replacement", async () => {
  const { workspace, gateway } = setup();
  let resolve: (document: PreferenceDocument) => void = () => {};
  gateway.read = () =>
    new Promise((done) => {
      resolve = done;
    });
  const reading = workspace.syncPreferences();
  workspace.configureHosts([{ ...configuration("mini"), url: "https://replacement.example" }]);
  gateway.changed({ entries: { "appearance.selectedThemeID": entry("night") } });
  resolve({ entries: { "appearance.selectedThemeID": entry("paperLight") } });
  await reading;
  expect(workspace.selectedThemeID).toBe("caribbeanSunset");
  expect(workspace.getSnapshot().hosts[0]?.preferences.status).toBe("unread");
});

test("separate browser replicas preserve the other tab's stored keys before recording a local choice", async () => {
  const storage = new MemoryStorage();
  const first = setup(["first"], storage);
  const second = setup(["second"], storage);
  first.workspace.setPreference("appearance.selectedThemeID", "paperLight");
  second.workspace.setPreference("codex.fastModeEnabled", true);
  await Promise.all([first.workspace.syncPreferences(), second.workspace.syncPreferences()]);
  expect(second.workspace.selectedThemeID).toBe("paperLight");
  expect(second.gateway.document.entries["appearance.selectedThemeID"]?.value).toBe("paperLight");
  expect(second.gateway.document.entries["codex.fastModeEnabled"]?.value).toBe(true);
});

test("an unreadable browser cache is reported and repaired by a host read without publishing guessed defaults", async () => {
  const storage = new MemoryStorage();
  storage.setItem("remotecoder.web.preferences.v1", "broken");
  const { workspace, gateway } = setup(["mini"], storage);
  expect(workspace.getSnapshot().error).toContain("Saved preferences could not be read");
  gateway.document = { entries: { "appearance.selectedThemeID": entry("night") } };
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("night");
  expect(gateway.updates).toHaveLength(0);
  workspace.setPreference("appearance.selectedThemeID", "forestDusk");
  await workspace.syncPreferences();
  const reloaded = setup(["mini"], storage);
  expect(reloaded.workspace.selectedThemeID).toBe("forestDusk");
});

test("a value native defaults cannot represent is ignored without blocking other keys or publishing older data over it", async () => {
  const { workspace, gateway } = setup();
  gateway.document = { entries: { "appearance.selectedThemeID": entry("night") } };
  await workspace.syncPreferences();
  gateway.document = {
    entries: {
      "appearance.selectedThemeID": entry({ nested: null }, 200),
      "codex.fastModeEnabled": entry(true, 200),
    },
  };
  await workspace.syncPreferences();
  expect(workspace.selectedThemeID).toBe("night");
  expect(workspace.preference("codex.fastModeEnabled")).toBe(true);
  expect(workspace.getSnapshot().hosts[0]?.preferences.status).toBe("ready");
  expect(gateway.updates).toHaveLength(0);
});

test("an edit queued as an exchange finishes is included before sync settles", async () => {
  const { workspace, gateway } = setup();
  let queued = false;
  const unsubscribe = workspace.subscribe(() => {
    if (queued || workspace.getSnapshot().hosts[0]?.preferences.status !== "ready") return;
    queued = true;
    queueMicrotask(() => workspace.setPreference("appearance.selectedThemeID", "paperLight"));
  });
  await workspace.syncPreferences();
  unsubscribe();
  expect(gateway.document.entries["appearance.selectedThemeID"]?.value).toBe("paperLight");
});

test("Fast and reasoning controls keep an old conversation's model and preserve the other setting", async () => {
  const { workspace, gateway } = setup();
  const reasoning = entry("effort-high");
  const defaultModel = entry("gpt-6.1-sol");
  gateway.selectedModel = "other";
  gateway.document = {
    entries: { "codex.defaultModelID": defaultModel, "codex.defaultReasoningSelection": reasoning },
  };
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  await workspace.chooseFastMode(true);
  await workspace.syncPreferences();
  expect(gateway.settings.at(-1)).toMatchObject({ model: "other", effort: "high", serviceTier: "fast" });
  expect(gateway.document.entries["codex.defaultModelID"]).toEqual(defaultModel);
  expect(gateway.document.entries["codex.defaultReasoningSelection"]).toEqual(reasoning);
  await workspace.chooseReasoning("low");
  await workspace.syncPreferences();
  expect(gateway.settings.at(-1)).toMatchObject({ model: "other", effort: "low", serviceTier: "fast" });
  expect(gateway.document.entries["codex.defaultModelID"]).toEqual(defaultModel);
  expect(gateway.document.entries["codex.fastModeEnabled"]?.value).toBe(true);
});

test("a hung preference read does not hold history, catalog discovery or conversation recovery", async () => {
  for (const recovering of [false, true]) {
    const { workspace, gateway } = setup();
    if (recovering) {
      await workspace.refreshHost("mini");
      await workspace.syncPreferences();
      await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
    }
    let resolveRead: (value: unknown) => void = () => {};
    gateway.read = () =>
      new Promise((resolve) => {
        resolveRead = resolve;
      });
    const ready = (
      recovering ? workspace.restoreContext({ hostId: "mini" }) : workspace.refreshHost("mini")
    ).then(() => true);
    let deadline: ReturnType<typeof setTimeout> | undefined;
    const settled = await Promise.race([
      ready,
      new Promise<boolean>((resolve) => {
        deadline = setTimeout(() => resolve(false), 30);
      }),
    ]).finally(() => clearTimeout(deadline));
    const stateBeforeSettings = workspace.getSnapshot().hosts[0];
    const historyReady = stateBeforeSettings?.history;
    const catalogReady = stateBeforeSettings?.choices.status;
    const preferencesBeforeSettings = stateBeforeSettings?.preferences.status;
    const modelBeforeSettings = workspace.draft.model;
    gateway.read = undefined;
    gateway.document = { entries: { "codex.defaultModelID": entry("other") } };
    resolveRead(gateway.document);
    await ready;
    await workspace.syncPreferences();
    expect(settled).toBe(true);
    expect(historyReady).toBe("ready");
    expect(catalogReady).toBe("ready");
    expect(preferencesBeforeSettings).toBe("loading");
    if (recovering) expect(workspace.selectedConversation?.status).toBe("ready");
    else {
      expect(modelBeforeSettings).toBe("");
      expect(workspace.draft.model).toBe("other");
    }
  }
});

test("local theme and visibility choices repair a corrupt cache before any host read", () => {
  for (const key of ["theme", "visibility"]) {
    const storage = new MemoryStorage();
    storage.setItem("remotecoder.web.preferences.v1", "corrupt");
    const preferences = new SyncedPreferences(storage);
    expect(preferences.restoreError).toBeDefined();
    if (key === "theme")
      expect(() => preferences.set("appearance.selectedThemeID", "paperLight")).not.toThrow();
    else expect(() => preferences.setModelVisible("claude", "opus", false, true)).not.toThrow();
    const reloaded = new SyncedPreferences(storage);
    expect(reloaded.restoreError).toBeUndefined();
    if (key === "theme") expect(reloaded.themeID).toBe("paperLight");
    else expect(reloaded.modelVisible("claude", "opus", true)).toBe(false);
  }
});

test("reasoning then Fast applies locally immediately and serializes the complete latest settings", async () => {
  const { workspace, gateway } = setup();
  gateway.selectedModel = "other";
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  let acknowledge: (value: unknown) => void = () => {};
  gateway.updateSettings = () =>
    new Promise((resolve) => {
      acknowledge = resolve;
    });
  const reasoning = workspace.chooseReasoning("xhigh");
  expect(workspace.draft.effort).toBe("xhigh");
  const fast = workspace.chooseFastMode(true);
  expect(workspace.draft).toMatchObject({ effort: "xhigh", fast: true });
  expect(gateway.settings).toHaveLength(1);
  gateway.updateSettings = undefined;
  acknowledge({ status: "applied" });
  await Promise.all([reasoning, fast]);
  expect(gateway.settings).toHaveLength(2);
  expect(gateway.settings[1]).toMatchObject({ effort: "xhigh", serviceTier: "fast" });
  expect(workspace.draft).toMatchObject({ effort: "xhigh", fast: true });
});

test("failed picker settings restore only the latest selection and preserve newer pending choices", async () => {
  const { workspace, gateway } = setup();
  gateway.selectedModel = "other";
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  let reject: (error: Error) => void = () => {};
  gateway.updateSettings = () =>
    new Promise((_, fail) => {
      reject = fail;
    });
  const reasoning = workspace.chooseReasoning("xhigh");
  const fast = workspace.chooseFastMode(true);
  gateway.updateSettings = undefined;
  reject(new Error("Rejected old settings"));
  await reasoning;
  await fast;
  expect(workspace.draft).toMatchObject({ effort: "xhigh", fast: true });
  gateway.updateSettings = async () => {
    throw new Error("Rejected latest settings");
  };
  const rejected = workspace.chooseReasoning("low");
  workspace.updateDraft({ text: "Typed while settings were pending" });
  await expect(rejected).rejects.toThrow("Rejected latest settings");
  expect(workspace.draft).toMatchObject({
    effort: "xhigh",
    fast: true,
    text: "Typed while settings were pending",
  });
});

test("picker updates coalesce waiting choices to the latest settings", async () => {
  const { workspace, gateway } = setup();
  gateway.selectedModel = "other";
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  let acknowledge: (value: unknown) => void = () => {};
  gateway.updateSettings = () =>
    new Promise((resolve) => {
      acknowledge = resolve;
    });
  const reasoning = workspace.chooseReasoning("xhigh");
  const fast = workspace.chooseFastMode(true);
  const latest = workspace.chooseReasoning("low");
  expect(gateway.settings).toHaveLength(1);
  gateway.updateSettings = undefined;
  acknowledge({ status: "applied" });
  await Promise.all([reasoning, fast, latest]);
  expect(gateway.settings).toHaveLength(2);
  expect(gateway.settings[1]).toMatchObject({ effort: "low", serviceTier: "fast" });
});

test("a focus exchange cannot delay fresh-chat seeding after the replica has synced once", async () => {
  const { workspace, gateway } = setup();
  gateway.document = { entries: { "codex.defaultModelID": entry("other") } };
  await workspace.refreshHost("mini");
  await workspace.syncPreferences();
  let complete: (value: unknown) => void = () => {};
  gateway.read = () =>
    new Promise((resolve) => {
      complete = resolve;
    });
  const syncing = workspace.syncPreferences();
  workspace.newConversation();
  expect(workspace.draft).toMatchObject({ model: "other", effort: "high" });
  gateway.read = undefined;
  complete(gateway.document);
  await syncing;
});

test("reentrant preference refreshes wait for the owning exchange rather than overlap its first read", async () => {
  const { workspace, gateway } = setup();
  let active = 0;
  let peak = 0;
  let reads = 0;
  let again: Promise<void> | undefined;
  gateway.read = async () => {
    reads++;
    active++;
    peak = Math.max(peak, active);
    if (reads === 1) again = workspace.syncPreferences();
    await Promise.resolve();
    active--;
    return structuredClone(gateway.document);
  };
  await workspace.syncPreferences();
  await again;
  expect(peak).toBe(1);
  expect(reads).toBe(2);
  expect(workspace.getSnapshot().hosts[0]?.preferences.status).toBe("ready");
});

test("a conversation on an external model provider offers only that provider's models", async () => {
  const { workspace, gateway } = setup();
  gateway.catalog = [
    model("gpt-6.1-sol"),
    { ...model("relay/model-a"), displayName: "Model A", modelProvider: "relay", modelProviderName: "Relay" },
  ];
  await workspace.refreshHost("mini");
  expect(workspace.choices().find((choice) => choice.id === "relay/model-a")?.name).toBe("Model A · Relay");
  expect(workspace.choices().filter((choice) => choice.provider === "codex")).toHaveLength(2);

  gateway.selectedModel = "relay/model-a";
  await workspace.refreshHost("mini");
  await workspace.selectConversation({ hostId: "mini", threadId: "conversation" });
  expect(
    workspace
      .choices()
      .filter((choice) => choice.provider === "codex")
      .map((choice) => choice.id),
  ).toEqual(["relay/model-a"]);
});
