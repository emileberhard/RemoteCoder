import {
  conversationAddress,
  decodeTarget,
  type ExecutionTarget,
  sameBinding,
  targetKey,
} from "../execution-context";
import { api } from "../gateway";
import {
  canonicalModelID,
  type PreferenceKey,
  type PreferenceValues,
  preferenceDocument,
} from "../preferences";
import { providerForThread } from "../protocol/agent-provider";
import {
  type Address,
  addressKey,
  type Frame,
  type Host,
  object,
  type Provider,
  type QuestionRecord,
  questionEnvelope,
} from "../protocol/boundary";
import type { MarkdownBlocks } from "../rendering";
import type { AccountUsageSnapshot, AccountUsageStore } from "./account-usage-store";
import { blank, ComposerDraftStore, type Draft } from "./composer-draft-store";
import { contextWindowUsage } from "./context-window-usage";
import {
  type ConversationDrawerMode,
  ConversationDrawerPreferences,
} from "./conversation-drawer-preferences";
import { conversationHeader } from "./conversation-header";
import type { Conversation, Renderer, RequestCard } from "./conversation-session";
import { ConversationSessions } from "./conversation-sessions";
import { ConversationSettingsSelection } from "./conversation-settings-selection";
import { ConversationSidebarModel } from "./conversation-sidebar-model";
import type { ConversationSidebarSnapshot } from "./conversation-sidebar-projection";
import { DirectoryPickerModel } from "./directory-picker-model";
import { drawerUndo } from "./drawer-undo";
import { type FavoriteFolder, favoriteFolders } from "./favorite-folder";
import { HostDirectories } from "./host-directories";
import { HostServices, type HostState, type ModelChoice, type RpcFactory } from "./host-services";
import { failure } from "./load-state";
import { SyncedPreferenceExchange } from "./synced-preference-exchange";
import { TurnDispatcher } from "./turn-dispatcher";
export type Snapshot = {
  hosts: HostState[];
  selectedHostId?: string;
  selectedTarget?: ExecutionTarget;
  contexts: ReadonlyMap<string, HostState>;
  selected?: Address;
  agentNavigation?: Readonly<{ parent: Address; child: Address }>;
  newDraftId: string;
  conversations: ReadonlyMap<string, Conversation>;
  drafts: ReadonlyMap<string, Draft>;
  error?: string;
  revision: number;
  sidebar: ConversationSidebarSnapshot;
  accountUsage: AccountUsageSnapshot;
  directoryPicker?: DirectoryPickerModel;
  favoriteFolders: readonly FavoriteFolder[];
};

export class Workspace {
  private state: Pick<
    Snapshot,
    "selectedHostId" | "selectedTarget" | "selected" | "agentNavigation" | "newDraftId" | "error" | "revision"
  > = { newDraftId: crypto.randomUUID(), revision: 0 };
  private snapshot: Snapshot;
  private readonly listeners = new Set<() => void>();
  private timer?: ReturnType<typeof setTimeout>;
  private selection = 0;
  private seenCompletion?: { key: string; completedAt: number };
  private disposed = false;
  private readonly hosts: HostServices;
  private readonly sessions: ConversationSessions;
  private readonly drafts: ComposerDraftStore;
  private readonly preferences: SyncedPreferenceExchange;
  private readonly settings: ConversationSettingsSelection;
  private readonly dispatcher: TurnDispatcher;
  private readonly sidebar: ConversationSidebarModel;
  private readonly drawerPreferences: ConversationDrawerPreferences;
  private readonly accountUsageStore: AccountUsageStore;
  private readonly lifecycle = new AbortController();
  private readonly directoryOwners = new Map<string, { host: HostState; directories: HostDirectories }>();
  private picker?: DirectoryPickerModel;
  private readonly storage: Storage | undefined;
  constructor(
    rpcFactory?: RpcFactory,
    storage?: Storage,
    accountReader?: (hostId: string) => Promise<unknown>,
  ) {
    this.storage = storage;
    this.hosts = new HostServices(rpcFactory, accountReader, {
      event: (target, frame) => this.event(target, frame),
      disconnected: (host) => {
        if (host.status !== "connecting") this.preferences.invalidate(host);
        this.sessions.disconnected(host);
        this.sidebar.disconnected(host);
      },
      restore: (target) => this.restoreContext(target),
      retiring: (host) => {
        this.sessions.retireHost(host);
        const navigation = this.state.agentNavigation;
        if (
          navigation &&
          [navigation.parent, navigation.child].some((address) => sameBinding(address, host.target))
        )
          this.state.agentNavigation = undefined;
      },
      canRetire: (target) => !this.sessions.hasContext(target),
      selectedTarget: () => this.selectedHost?.target,
      protectedAddresses: () => [
        ...(this.state.selected ? [this.state.selected] : []),
        ...[...this.sessions.snapshot.values()]
          .filter((conversation) => conversation.activeTurnId !== null || conversation.submitting)
          .map((conversation) => conversation.address),
        ...this.sidebar.liveAddresses(),
      ],
      syncPreferences: (host) => {
        void this.preferences.syncHost(host);
      },
      catalogReady: () => this.settings.seedNewDraft(),
      publish: () => this.publish(),
      report: (error) => this.report(error),
    });
    this.sidebar = new ConversationSidebarModel(
      this.hosts,
      storage,
      () => this.publish(),
      (error) => this.report(error),
    );
    this.accountUsageStore = this.hosts.accountUsage;
    this.drafts = new ComposerDraftStore(
      storage,
      () => ({ key: this.draftKey, host: this.selectedHost?.host }),
      () => this.dispatcher.protectedDraftKeys(),
      () => this.publish(),
      (error) => this.report(error),
    );
    this.sessions = new ConversationSessions(
      this.hosts,
      () => this.state.selected,
      (live) => this.publish(live),
      () => this.dispatcher.pendingReceipts,
      (conversation) => this.dispatcher.reconcileReceipts(conversation),
      (target, notification) => this.event(target, notification),
      (host, value) => this.sidebar.receiveActivity(host, value),
      (host, threadId, inventory) => this.sidebar.receiveQuestions(host, threadId, inventory),
    );
    this.preferences = new SyncedPreferenceExchange(
      storage,
      this.hosts,
      () => this.publish(),
      () => this.settings.seedNewDraft(),
      (error) => this.report(error),
    );
    this.drawerPreferences = new ConversationDrawerPreferences(
      storage,
      () => this.preferences.get("conversationDrawer.mode") ?? "priority",
      () => this.publish(),
    );
    this.settings = new ConversationSettingsSelection(
      this.hosts,
      this.drafts,
      this.preferences,
      () => this.current(),
      (target) => this.selectTarget(target),
      () => this.disposed,
      (error) => this.report(error),
    );
    this.dispatcher = new TurnDispatcher(
      this.hosts,
      this.sessions,
      this.drafts,
      storage,
      () => this.current(),
      {
        choices: () => this.choices(),
        selectStarted: (address, fence) => {
          if (this.selection === fence) this.state.selected = address;
        },
        isRetired: () => this.disposed,
        publish: () => this.publish(),
        report: (error) => this.report(error),
      },
    );
    if (this.drawerPreferences.restoreError)
      this.state.error = `Saved drawer preferences could not be read: ${this.drawerPreferences.restoreError}`;
    if (this.preferences.restoreError)
      this.state.error = `Saved preferences could not be read: ${this.preferences.restoreError}`;
    try {
      this.drafts.restore();
      this.dispatcher.restore();
    } catch {
      this.state.error =
        "Saved drafts or submission receipts could not be read. Browser storage was left untouched.";
    }
    this.snapshot = this.project();
    if (typeof window !== "undefined" && typeof document !== "undefined") {
      document.addEventListener("visibilitychange", () => this.syncAccountUsageForeground(), {
        signal: this.lifecycle.signal,
      });
      window.addEventListener("pageshow", () => this.syncAccountUsageForeground(), {
        signal: this.lifecycle.signal,
      });
      window.addEventListener("pagehide", () => this.accountUsageStore.stopForeground(), {
        signal: this.lifecycle.signal,
      });
    }
  }
  private current() {
    return {
      host: this.selectedHost,
      conversation: this.selectedConversation,
      draft: this.draft,
      draftKey: this.draftKey,
      selected: this.state.selected,
      selection: this.selection,
    };
  }
  private project(): Snapshot {
    return {
      ...this.state,
      hosts: this.hosts.snapshot,
      contexts: this.hosts.allContexts,
      conversations: this.sessions.snapshot,
      drafts: this.drafts.snapshot,
      sidebar: this.drawerSnapshot(),
      accountUsage: this.accountUsageStore.snapshot(Math.floor(Date.now() / 1000), this.state.selectedTarget),
      directoryPicker: this.picker,
      favoriteFolders: this.favoriteFolders,
    };
  }
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getSnapshot = () => this.snapshot;
  get isRetired() {
    return this.disposed;
  }
  get isSubmitting() {
    return this.dispatcher.isSubmitting(this.draftKey);
  }
  get selectedConversation() {
    return this.state.selected ? this.sessions.get(this.state.selected)?.snapshot : undefined;
  }
  get selectedHost() {
    const target =
      this.state.selectedTarget ??
      (this.state.selectedHostId ? { hostId: this.state.selectedHostId } : undefined);
    return target ? this.hosts.allContexts.get(targetKey(target)) : undefined;
  }
  get draftKey() {
    return this.state.selected
      ? addressKey(this.state.selected)
      : `${this.newDraftPrefix}${this.state.newDraftId}`;
  }
  get newDraftPrefix() {
    return `new:${encodeURIComponent(JSON.stringify(this.selectedHost?.target ?? { hostId: this.state.selectedHostId ?? "unconfigured" }))}:`;
  }
  get draft() {
    const saved = this.drafts.snapshot.get(this.draftKey) ?? blank(this.selectedHost?.host);
    const draft = saved.provider === "claude" ? { ...saved, model: canonicalModelID(saved.model) } : saved;
    const conversation = this.selectedConversation;
    return conversation ? { ...draft, cwd: conversation.header.cwd } : draft;
  }
  private publish(live = false) {
    if (this.disposed) return;
    if (live) {
      if (!this.timer)
        this.timer = setTimeout(() => {
          this.timer = undefined;
          this.publish();
        }, 80);
      return;
    }
    clearTimeout(this.timer);
    this.timer = undefined;
    this.state = { ...this.state, revision: this.state.revision + 1 };
    this.snapshot = this.project();
    for (const listener of this.listeners) listener();
  }
  report(error: unknown) {
    this.state.error = failure(error);
    this.publish();
  }
  clearError() {
    this.state.error = undefined;
    this.publish();
  }

  setRenderer(renderer: Renderer) {
    this.sessions.setRenderer(renderer);
  }
  markdownReady(id: string, result: MarkdownBlocks) {
    this.sessions.markdownReady(id, result);
  }
  preference<K extends PreferenceKey>(key: K): PreferenceValues[K] | null {
    return this.preferences.get(key);
  }
  setPreference<K extends PreferenceKey>(key: K, value: PreferenceValues[K] | null) {
    this.preferences.set(key, value);
  }
  get selectedThemeID() {
    return this.preferences.themeID;
  }
  syncPreferences() {
    return this.preferences.sync();
  }
  featureTransport(owner: string | ExecutionTarget | undefined = this.selectedHost?.target) {
    if (!owner) throw new Error("Choose a configured host first");
    const host = this.hosts.get(
      typeof owner === "string" && this.selectedHost?.target.hostId === owner
        ? this.selectedHost.target
        : owner,
    );
    return this.hosts.featureTransport(
      host,
      this.selectedHost && sameBinding(this.selectedHost.target, host.target)
        ? this.draft.cwd
        : host.host.cwd,
    );
  }
  async refreshHosts() {
    await this.readHosts();
    await Promise.all([
      this.refreshHistories(),
      this.refreshVersions(),
      this.refreshAccountUsage("codex", false),
      this.refreshAccountUsage("claude", false),
    ]);
  }
  async loadHosts() {
    await this.readHosts();
    void this.refreshVersions();
  }
  private async readHosts() {
    const { hosts } = await api<{ hosts: Host[] }>("/api/hosts");
    this.configureHosts(hosts);
  }

  async refreshHistories() {
    await Promise.allSettled(this.hosts.snapshot.slice(0, 3).map((host) => this.refreshHost(host.host.id)));
  }
  configureHosts(hosts: Host[]) {
    this.hosts.configure(hosts);
    this.sidebar.reconcile();
    this.accountUsageStore.reconcile();
    this.syncAccountUsageForeground();
    this.reconcileDirectories();
    if (!this.hosts.snapshot.some((host) => host.host.id === this.state.selectedHostId)) {
      this.supersedePendingNavigation();
      this.state.agentNavigation = undefined;
      this.state.selectedHostId = this.hosts.snapshot[0]?.host.id;
      this.state.selectedTarget = this.state.selectedHostId
        ? { hostId: this.state.selectedHostId }
        : undefined;
      this.state.selected = undefined;
    }
    this.publish();
  }
  async refreshAccounts(hostId = this.state.selectedHostId) {
    if (hostId) await this.hosts.refreshAccounts(hostId);
  }
  async refreshHost(id: string | ExecutionTarget, older = false) {
    const host = this.hosts.get(id);
    await this.hosts.refresh(id, older);
    if (!this.hosts.present(host)) return;
    const reads = [this.sidebar.refresh(host)];
    if (!host.target.enrollment) {
      const directories = this.hostDirectories(host.host.id);
      reads.push(
        directories.syncFavorites(),
        directories.resolveHomePath().then(() => {}),
      );
    }
    await Promise.allSettled(reads);
  }
  refreshVersions() {
    return this.hosts.refreshVersions();
  }
  async restoreContext(target: ExecutionTarget) {
    const host = this.hosts.allContexts.get(targetKey(target));
    if (!host) return;
    const controller = host.controller;
    const read = this.hosts.beginRestore(host);
    try {
      await this.refreshHost(target);
      if (controller.signal.aborted || !this.hosts.present(host) || host.restoreRead !== read) return;
      await Promise.allSettled(
        [...this.sessions.snapshot.values()]
          .filter((conversation) => sameBinding(conversation.address, target))
          .map((conversation) => this.loadConversation(conversation.address)),
      );
    } catch (error) {
      if (!controller.signal.aborted && this.hosts.present(host) && host.restoreRead === read) {
        this.hosts.setError(host, error);
        this.publish();
      }
    }
  }
  async selectTarget(target: ExecutionTarget) {
    target = decodeTarget(target);
    const fence = this.supersedePendingNavigation();
    const context = await this.hosts.ensure(target);
    if (fence !== this.selection || !this.hosts.present(context)) return;
    this.state.selectedHostId = target.hostId;
    this.state.selectedTarget = target;
    this.newConversation();
    if (context.history === "unread") await this.refreshHost(target);
  }
  selectHost(id: string) {
    this.hosts.get(id);
    this.state.selectedHostId = id;
    this.state.selectedTarget = { hostId: id };
    this.newConversation();
    if (this.hosts.get(id).history === "unread")
      void this.refreshHost(id).catch((error) => this.report(error));
  }
  newConversation() {
    this.closeDirectoryPicker();
    this.supersedePendingNavigation();
    this.state.agentNavigation = undefined;
    this.seenCompletion = undefined;
    this.state.selected = undefined;
    this.state.newDraftId = crypto.randomUUID();
    this.settings.seedNewDraft();
    this.publish();
  }
  startsNewConversation(cwd: string) {
    const path = cwd.trim();
    return (
      Boolean(path) && path !== this.draft.cwd && Boolean(this.selectedConversation || this.isSubmitting)
    );
  }
  selectWorkingDirectory(cwd: string) {
    const path = cwd.trim();
    if (!path) throw new Error("Choose a working directory");
    if (path === this.draft.cwd) return;
    if (this.startsNewConversation(path)) {
      const { model, provider, effort, fast } = this.draft;
      this.newConversation();
      this.updateDraft({ cwd: path, model, provider, effort, fast });
      return;
    }
    this.updateDraft({ cwd: path });
  }
  async selectDraft(key: string) {
    const match = /^new:([^:]+):(.+)$/.exec(key);
    const encoded = match?.[1];
    const target = encoded ? decodeTarget(JSON.parse(decodeURIComponent(encoded))) : undefined;
    const hostId = target?.hostId;
    const draftId = match?.[2];
    if (!hostId || !draftId || !this.drafts.snapshot.has(key))
      throw new Error("The saved draft is unavailable");
    if (!target) throw new Error("The saved draft target is unavailable");
    const fence = this.supersedePendingNavigation();
    await this.hosts.ensure(target);
    if (fence !== this.selection) return;
    this.state.selectedTarget = target;
    this.supersedePendingNavigation();
    this.state.agentNavigation = undefined;
    this.state.selectedHostId = hostId;
    this.state.newDraftId = draftId;
    this.state.selected = undefined;
    this.publish();
  }
  async selectConversation(address: Address) {
    address = conversationAddress(address, address.threadId);
    const fence = this.supersedePendingNavigation();
    if (!this.hosts.allContexts.has(targetKey(address))) await this.hosts.ensure(address);
    if (fence !== this.selection) return;
    this.presentConversation(address, undefined);
    try {
      await this.loadConversation(address);
      if (fence === this.selection) this.seedConversationDraft(address);
    } catch (error) {
      if (fence === this.selection) this.report(error);
    }
  }
  private supersedePendingNavigation() {
    this.selection += 1;
    return this.selection;
  }
  private presentConversation(address: Address, navigation: Snapshot["agentNavigation"]) {
    this.state.selectedHostId = address.hostId;
    this.state.selectedTarget = {
      hostId: address.hostId,
      ...(address.enrollment ? { enrollment: address.enrollment } : {}),
    };
    if (!this.state.selected || addressKey(this.state.selected) !== addressKey(address))
      this.seenCompletion = undefined;
    this.state.selected = address;
    this.state.agentNavigation = navigation;
    this.closeDirectoryPicker();
    this.publish();
  }
  private seedConversationDraft(address: Address) {
    const conversation = this.sessions.get(address)?.snapshot;
    if (conversation && !this.drafts.snapshot.has(addressKey(address)))
      this.updateDraft({
        model: conversation.header.model ?? "",
        effort: conversation.header.reasoningEffort ?? "",
        provider: conversation.header.provider,
      });
  }
  private async loadNavigationConversation(address: Address, fence: number) {
    try {
      const host = await this.hosts.ensure(address);
      if (fence !== this.selection || !this.hosts.present(host) || this.disposed) return false;
      await this.loadConversation(address);
      return (
        fence === this.selection &&
        this.hosts.present(host) &&
        !this.disposed &&
        this.sessions.get(address)?.snapshot.status === "ready"
      );
    } catch (error) {
      if (fence === this.selection && !this.disposed) throw error;
      return false;
    }
  }
  async openAgentConversation(child: Address, parent: Address) {
    child = conversationAddress(child, child.threadId);
    parent = conversationAddress(parent, parent.threadId);
    const fence = this.supersedePendingNavigation();
    if (!(await this.loadNavigationConversation(child, fence)) || fence !== this.selection || this.disposed)
      return;
    this.presentConversation(child, { parent, child });
    this.seedConversationDraft(child);
  }
  async returnToAgentParent() {
    const navigation = this.state.agentNavigation;
    if (
      !navigation ||
      !this.state.selected ||
      addressKey(this.state.selected) !== addressKey(navigation.child)
    )
      return;
    const fence = this.supersedePendingNavigation();
    if (
      !(await this.loadNavigationConversation(navigation.parent, fence)) ||
      fence !== this.selection ||
      this.disposed
    )
      return;
    if (
      this.state.agentNavigation !== navigation ||
      !this.state.selected ||
      addressKey(this.state.selected) !== addressKey(navigation.child)
    )
      return;
    this.presentConversation(navigation.parent, undefined);
    this.seedConversationDraft(navigation.parent);
  }

  loadConversation(address: Address) {
    return this.sessions.load(address);
  }
  async older() {
    await (this.state.selected ? this.sessions.get(this.state.selected)?.older() : undefined);
  }
  updateDraft(change: Partial<Draft>, key = this.draftKey) {
    this.drafts.update(change, key);
  }
  flushDrafts() {
    this.drafts.flush();
  }
  choices() {
    return this.settings.choices();
  }
  modelVisibilityChoices() {
    return this.settings.modelVisibilityChoices();
  }
  setModelVisible(provider: Provider, id: string, visible: boolean) {
    this.settings.setModelVisible(provider, id, visible);
  }
  chooseModel(choice: ModelChoice | undefined) {
    return this.settings.chooseModel(choice);
  }
  chooseReasoning(effort: string) {
    return this.settings.chooseReasoning(effort);
  }
  chooseFastMode(enabled: boolean) {
    return this.settings.chooseFastMode(enabled);
  }
  prepareConversation(): Promise<Conversation> {
    return this.dispatcher.prepareConversation();
  }
  send(mode: "send" | "queue" = "send", override?: string) {
    return this.dispatcher.send(mode, override);
  }
  interrupt() {
    return this.dispatcher.interrupt();
  }
  async deleteQueued(id: string) {
    if (this.state.selected) await this.sessions.get(this.state.selected)?.deleteQueued(id);
  }
  async refreshQuestions(conversation = this.selectedConversation) {
    if (conversation) await this.sessions.get(conversation.address)?.refreshQuestions();
  }
  async answerQuestion(record: QuestionRecord, answers: Record<number, string>) {
    const conversation = this.selectedConversation;
    const current = conversation?.questions;
    if (
      !conversation ||
      current?.status !== "ready" ||
      current.value.coverage !== "ready" ||
      !current.value.pendingItemIds?.includes(record.itemId)
    )
      throw new Error("Refresh the question's status before answering");
    const latest = current.value.records.find((value) => value.itemId === record.itemId);
    if (!latest || latest.revision !== record.revision)
      throw new Error("The question changed; refresh it before answering");
    await this.send("send", questionEnvelope(record, answers));
    await this.refreshQuestions(conversation);
  }

  async dismissQuestion(record: QuestionRecord) {
    if (this.state.selected) await this.sessions.get(this.state.selected)?.dismissQuestion(record);
  }
  answerRequest(request: RequestCard, result: unknown) {
    if (this.state.selected) this.sessions.get(this.state.selected)?.answerRequest(request, result);
  }
  async fork(address = this.state.selected) {
    if (!address) return;
    const host = this.hosts.get(address);
    const provider = providerForThread(address.threadId);
    const selection = this.selection;
    const result = object(
      await host.rpc.call(
        "thread/fork",
        { threadId: address.threadId },
        { timeout: 150000, signal: host.controller.signal },
      ),
    );
    if (!this.hosts.present(host)) return;
    const header = conversationHeader(result.thread, provider);
    this.hosts.recordThread(host, header);
    if (selection === this.selection) await this.selectConversation({ ...host.target, threadId: header.id });
    else this.publish();
  }
  readonly homePath = (hostId: string) => {
    const state = this.directoryOwners.get(hostId)?.directories.home;
    return state?.status === "ready" ? state.value : undefined;
  };
  private drawerSnapshot() {
    return this.sidebar.snapshot(
      this.state.selected,
      this.drafts.snapshot,
      this.sessions.snapshot,
      this.drawerPreferences.snapshot,
      this.homePath,
      Math.floor(Date.now() / 1000),
    );
  }
  unfoldedConversationRows() {
    return this.sidebar.unfoldedRows(
      this.state.selected,
      this.drafts.snapshot,
      this.sessions.snapshot,
      this.drawerPreferences.snapshot,
      this.homePath,
      Math.floor(Date.now() / 1000),
    );
  }
  get favoriteFolders() {
    return favoriteFolders(
      this.hosts.snapshot.map((host) => ({
        id: host.host.id,
        name: host.host.name,
        paths: this.directoryOwners.get(host.host.id)?.directories.favorites ?? [],
        homePath: this.homePath(host.host.id),
      })),
    );
  }
  async selectFavoriteFolder(folder: FavoriteFolder) {
    if (this.state.selectedHostId !== folder.hostId) this.selectHost(folder.hostId);
    this.selectWorkingDirectory(folder.path);
  }
  get conversationDrawer() {
    return this.snapshot.sidebar;
  }
  get drawerArrangement() {
    return this.drawerPreferences.snapshot;
  }
  openDrawer() {
    if (!this.sidebar.isOpen) this.drawerPreferences.resetReveals();
    this.sidebar.open(this.sessions.snapshot, this.homePath, Math.floor(Date.now() / 1000));
  }
  closeDrawer() {
    this.sidebar.close();
  }
  setDrawerMode(mode: ConversationDrawerMode) {
    this.setPreference("conversationDrawer.mode", mode);
  }
  setDrawerUnreadOnly(value: boolean) {
    this.drawerPreferences.setUnreadOnly(value);
  }
  setDrawerQuery(query: string) {
    this.drawerPreferences.setQuery(query);
  }
  setPinnedFolded(folded: boolean) {
    this.drawerPreferences.setPinnedFolded(folded);
  }
  setAutomationsFolded(folded: boolean) {
    this.drawerPreferences.setAutomationsFolded(folded);
  }
  setSettledFolded(folded: boolean) {
    this.drawerPreferences.setSettledFolded(folded);
  }
  setProjectFolded(key: string, folded: boolean) {
    this.drawerPreferences.setProjectFolded(
      key,
      folded,
      new Set(
        this.snapshot.sidebar.sections
          .filter((section) => section.kind === "project")
          .map((section) => section.id),
      ),
    );
  }
  setAllSectionsFolded(folded: boolean) {
    this.drawerPreferences.setAllSectionsFolded(
      folded,
      new Set(
        this.snapshot.sidebar.sections
          .filter((section) => section.kind === "project")
          .map((section) => section.id),
      ),
    );
  }
  revealProject(key: string) {
    this.drawerPreferences.revealProject(key);
  }
  revealAllAutomations() {
    this.drawerPreferences.revealAllAutomations();
  }
  revealMoreSettled() {
    this.drawerPreferences.revealMoreSettled();
  }
  conversationMarks(target = this.selectedHost?.target) {
    if (!target) return undefined;
    const store = this.sidebar.marks(target);
    return {
      marks: store.marks,
      status: store.status,
      error: store.error,
      pendingCount: store.pendingCount,
    } as const;
  }
  pinConversation(address: Address, name: string) {
    this.sidebar.pin(address, name);
    if (this.drawerPreferences.snapshot.isPinnedFolded) this.drawerPreferences.setPinnedFolded(false);
  }
  get selectedConversationRowState() {
    return this.state.selected
      ? this.sidebar.rowState(this.state.selected, this.selectedConversation, Math.floor(Date.now() / 1000))
      : undefined;
  }
  unpinConversation(address: Address) {
    this.sidebar.record(address, [{ op: "unpin", threadId: address.threadId }]);
  }
  markConversationRead(address: Address) {
    this.sidebar.record(address, [
      {
        op: "markRead",
        threadId: address.threadId,
        through:
          this.hosts.get(address).threads.find((header) => header.id === address.threadId)
            ?.lastTurnCompletedAt ?? 0,
      },
    ]);
  }
  publishSeenCompletion() {
    const conversation = this.selectedConversation;
    if (conversation?.status !== "ready") return;
    const completedAt = conversation.header.lastTurnCompletedAt;
    if (completedAt === null) return;
    const key = addressKey(conversation.address);
    if (this.seenCompletion?.key === key && this.seenCompletion.completedAt >= completedAt) return;
    const previous = this.seenCompletion;
    this.seenCompletion = { key, completedAt };
    try {
      this.sidebar.record(conversation.address, [
        { op: "markRead", threadId: conversation.address.threadId, through: completedAt },
      ]);
    } catch (error) {
      this.seenCompletion = previous;
      throw error;
    }
  }
  markConversationUnread(address: Address) {
    this.sidebar.record(address, [{ op: "markUnread", threadId: address.threadId }]);
  }
  settleConversation(address: Address) {
    if (this.sessions.get(address)?.snapshot.activeTurnId)
      throw new Error("A running conversation cannot be settled");
    return this.settleConversations([address]);
  }
  settleConversations(addresses: readonly Address[]) {
    if (addresses.some((address) => this.sessions.get(address)?.snapshot.activeTurnId))
      throw new Error("A running conversation cannot be settled");
    return this.sidebar.settleConversations(addresses);
  }
  unsettleConversation(address: Address) {
    this.sidebar.settle(address, false);
  }
  markAllRead() {
    const through = Math.floor(Date.now() / 1000);
    const failures: string[] = [];
    for (const host of this.hosts.allContexts.values()) {
      try {
        this.sidebar.record(host.target, [{ op: "markAllRead", through }]);
      } catch (error) {
        failures.push(`${host.host.name}: ${failure(error)}`);
      }
    }
    if (failures.length) this.report(new Error(failures.join("\n")));
  }
  discardDraft(key: string) {
    const draft = this.drafts.get(key);
    if (!key.startsWith("new:") || !draft) return drawerUndo(0, () => {});
    if (this.dispatcher.protectedDraftKeys().has(key))
      throw new Error("This draft has a pending submission and cannot be discarded");
    const previous = this.drafts.snapshot;
    this.drafts.remove(key);
    try {
      this.drafts.persist(true);
    } catch (error) {
      this.drafts.restoreSnapshot(previous);
      throw error;
    }
    const wasShown = this.draftKey === key;
    if (wasShown) this.newConversation();
    else this.publish();
    return drawerUndo(1, () => {
      if (this.drafts.get(key)) throw new Error("A draft already occupies this saved location");
      if (this.drafts.snapshot.size >= 32) throw new Error("Discard another draft before restoring this one");
      const previous = this.drafts.snapshot;
      this.drafts.restoreSnapshot(new Map([...previous, [key, draft]]));
      try {
        this.drafts.persist(true);
      } catch (error) {
        this.drafts.restoreSnapshot(previous);
        throw error;
      }
      this.publish();
      if (wasShown) void this.selectDraft(key).catch((error) => this.report(error));
    });
  }
  async regenerateTitle(address = this.state.selected) {
    if (!address) return;
    const host = this.hosts.get(address);
    const priorName = host.threads.find((thread) => thread.id === address.threadId)?.name;
    const result = object(
      await host.rpc.call(
        "conversation/title/regenerate",
        { threadId: address.threadId },
        { timeout: 150000, signal: host.controller.signal },
      ),
    );
    if (!this.hosts.present(host)) return;
    if (
      typeof result.name === "string" &&
      host.threads.find((thread) => thread.id === address.threadId)?.name === priorName
    )
      this.event(host.target, {
        method: "thread/name/updated",
        params: { threadId: address.threadId, threadName: result.name },
      });
  }
  get contextWindowUsage() {
    return contextWindowUsage(this.selectedConversation?.usage);
  }
  get accountUsage() {
    return this.accountUsageStore.snapshot(Math.floor(Date.now() / 1000), this.state.selectedTarget);
  }
  private syncAccountUsageForeground() {
    if (typeof document === "undefined" || this.disposed) return;
    if (document.visibilityState === "visible" && this.hosts.snapshot.length)
      this.accountUsageStore.startForeground();
    else this.accountUsageStore.stopForeground();
  }
  refreshAccountUsage(provider: Provider, interactive = true) {
    return this.accountUsageStore.refresh(provider, interactive);
  }
  setClaudeAccountPreference(id: string | null) {
    return this.accountUsageStore.setClaudePreference(id);
  }
  private reconcileDirectories() {
    for (const [id, entry] of this.directoryOwners)
      if (!this.hosts.present(entry.host)) {
        entry.directories.dispose();
        this.directoryOwners.delete(id);
        if (this.picker?.hostId === id) this.closeDirectoryPicker();
      }
  }
  hostDirectories(hostId = this.state.selectedHostId) {
    if (!hostId) throw new Error("Choose a host first");
    this.reconcileDirectories();
    let entry = this.directoryOwners.get(hostId);
    if (!entry) {
      const host = this.hosts.get(hostId);
      entry = {
        host,
        directories: new HostDirectories(hostId, host.rpc, this.storage, () => this.publish()),
      };
      this.directoryOwners.set(hostId, entry);
    }
    return entry.directories;
  }
  openDirectoryPicker(hostId = this.state.selectedHostId) {
    this.closeDirectoryPicker();
    const directories = this.hostDirectories(hostId);
    this.picker = new DirectoryPickerModel(
      directories,
      hostId === this.state.selectedHostId ? this.draft.cwd : undefined,
      () => this.publish(),
    );
    void directories.syncFavorites();
    void this.picker.loadInitialChildren();
    this.publish();
    return this.picker;
  }
  closeDirectoryPicker() {
    if (!this.picker) return;
    this.picker.dispose();
    this.picker = undefined;
    this.publish();
  }
  async chooseDirectory(path: string) {
    const picker = this.picker;
    if (!picker) throw new Error("Open the directory picker first");
    let selected: string;
    try {
      selected = await picker.selectDirectory(path);
    } catch (error) {
      if (this.picker !== picker || this.disposed) return;
      throw error;
    }
    if (this.picker !== picker || this.disposed) return;
    if (this.state.selectedHostId !== picker.hostId) this.selectHost(picker.hostId);
    this.selectWorkingDirectory(selected);
    this.closeDirectoryPicker();
    this.publish();
  }
  restoreSteer(address: Address, clientId: string) {
    this.dispatcher.restoreSteer(address, clientId);
  }
  event(target: ExecutionTarget, notification: Frame) {
    this.hosts.notifyFeatures(target, notification);
    try {
      if (!notification.method) return;
      const params = object(notification.params ?? {});
      const host = this.hosts.get(target);
      if (notification.method === "conversation/marks/changed") {
        this.sidebar.marks(target).receive(params);
        return;
      }
      if (notification.method === "directory/favorites/changed") {
        this.hostDirectories(target.hostId).receiveFavorites(params);
        return;
      }
      if (notification.method === "conversation/questions/changed")
        this.sidebar.changedQuestions(host, params);
      if (notification.method === "preferences/changed") {
        this.preferences.receive(preferenceDocument(params));
        return;
      }
      this.sessions.ingest(target, notification);
    } catch (error) {
      this.report(error);
    }
  }
  dispose() {
    this.disposed = true;
    this.lifecycle.abort();
    this.preferences.dispose();
    this.sidebar.dispose();
    this.closeDirectoryPicker();
    for (const entry of this.directoryOwners.values()) entry.directories.dispose();
    this.directoryOwners.clear();
    clearTimeout(this.timer);
    this.drafts.flush();
    this.hosts.dispose();
    this.sessions.dispose();
    this.listeners.clear();
  }
}
