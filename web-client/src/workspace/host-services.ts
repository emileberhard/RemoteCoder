import {
  type AccountCatalog as ExecutionCatalog,
  type ExecutionTarget,
  sameBinding,
  targetKey,
} from "../execution-context";
import { api, type ConnectionState, GatewayConnection, type Rpc } from "../gateway";
import type { PreferenceDocument } from "../preferences";
import { providerForThread } from "../protocol/agent-provider";
import {
  type Address,
  array,
  type Frame,
  type Host,
  identifier,
  models,
  object,
  optionalString,
  type Provider,
} from "../protocol/boundary";
import claudeCatalog from "../protocol/claude-models.json";
import type { Model } from "../protocol/generated/v2/Model";
import { AccountUsageStore } from "./account-usage-store";
import { ConversationAgentClassifier } from "./conversation-agent-classifier";
import { type ConversationHeader, conversationHeader, retainHeaderKnowledge } from "./conversation-header";
import { type GatewayVersion, HostVersions } from "./host-versions";
import { failure, type Load } from "./load-state";
export type ModelChoice = {
  id: string;
  name: string;
  provider: Provider;
  efforts: string[];
  fast: boolean;
  images: boolean;
  defaultEffort: string;
  hiddenUpstream?: boolean;
  upstreamDefault?: boolean;
  modelProvider?: string;
};
type HostContext = {
  preferences: Load<PreferenceDocument>;
  target: ExecutionTarget;
  accounts: Load<ExecutionCatalog>;
  historyRead: number;
  catalogRead: number;
  activityRead: number;
  restoreRead: number;
  host: Host;
  status: ConnectionState;
  error?: string;
  threads: ConversationHeader[];
  history: "unread" | "loading" | "ready" | "failed";
  cursors: Partial<Record<Provider, string | null>>;
  historyErrors: string[];
  agentWarnings: string[];
  pinnedRecoveryError?: string;
  choices: Load<ModelChoice[]>;
  version: Load<GatewayVersion>;
  rpc: Rpc;
  connection?: GatewayConnection;
  controller: AbortController;
};

export type HostState = Readonly<HostContext>;
export type RpcFactory = (host: Host, event: (frame: Frame) => void, target: ExecutionTarget) => Rpc;
type PinnedHeaderRecovery = {
  ids: Set<string>;
  failures: Map<string, { retryAt: number; interval: number }>;
  task?: Promise<void>;
  overLimit: boolean;
  requested?: boolean;
  retry?: ReturnType<typeof setTimeout>;
  retryAt?: number;
};
type HeaderRead = { threadId: string; name?: { value: string | null } };
type ExternalModel = Model & { modelProvider: string; modelProviderName: string };
function external(model: Model): model is ExternalModel {
  const route = model as Partial<ExternalModel>;
  return typeof route.modelProvider === "string" && typeof route.modelProviderName === "string";
}
export class HostServices {
  private readonly versions: HostVersions;
  readonly accountUsage: AccountUsageStore;
  private hosts: HostContext[] = [];
  private readonly contexts = new Map<string, HostContext>();
  private readonly headerReads = new WeakMap<HostState, Set<HeaderRead>>();
  private readonly pinnedHeaders = new WeakMap<HostState, PinnedHeaderRecovery>();
  private readonly classifiers = new WeakMap<HostState, ConversationAgentClassifier>();
  private readonly featureListeners = new Map<string, Set<(frame: Frame) => void>>();
  constructor(
    private readonly rpcFactory: RpcFactory | undefined,
    accountReader: ((hostId: string) => Promise<unknown>) | undefined,
    private readonly actions: {
      event(target: ExecutionTarget, frame: Frame): void;
      disconnected(host: HostState): void;
      restore(target: ExecutionTarget): Promise<void>;
      retiring(host: HostState): void;
      canRetire(target: ExecutionTarget): boolean;
      selectedTarget(): ExecutionTarget | undefined;
      protectedAddresses(): readonly Address[];
      syncPreferences(host: HostState): void;
      catalogReady(): void;
      publish(): void;
      report(error: unknown): void;
    },
  ) {
    this.accountUsage = new AccountUsageStore(
      () => this.hosts,
      () => this.actions.publish(),
      accountReader
        ? (path, init) => {
            const match = /^\/api\/hosts\/([^/]+)\/accounts(?:\?|$)/.exec(path);
            return match?.[1] ? accountReader(decodeURIComponent(match[1])) : api(path, init);
          }
        : undefined,
    );
    this.versions = new HostVersions(
      () => this.hosts,
      () => this.actions.publish(),
    );
  }
  get snapshot(): HostState[] {
    return this.hosts;
  }
  get allContexts(): ReadonlyMap<string, HostState> {
    return this.contexts;
  }
  get(owner: string | ExecutionTarget): HostState {
    const target = typeof owner === "string" ? { hostId: owner } : owner;
    const host = this.contexts.get(targetKey(target));
    if (!host) throw new Error("The conversation's exact execution context is unavailable");
    return host;
  }
  present(host: HostState) {
    return !host.controller.signal.aborted && this.contexts.get(targetKey(host.target)) === host;
  }
  setPreferences(host: HostState, preferences: Load<PreferenceDocument>) {
    this.mutable(host).preferences = preferences;
  }
  private mutable(host: HostState): HostContext {
    const current = this.contexts.get(targetKey(host.target));
    if (current !== host) throw new Error("The execution context was retired");
    return current;
  }
  beginActivityRead(host: HostState) {
    return ++this.mutable(host).activityRead;
  }
  recordThread(host: HostState, header: ConversationHeader) {
    const retained = retainHeaderKnowledge(
      header,
      host.threads.find((thread) => thread.id === header.id),
    );
    this.mutable(host).threads = this.retainHeaders(host, [
      retained,
      ...host.threads.filter((thread) => thread.id !== header.id),
    ]);
  }
  async readHeader(
    host: HostState,
    threadId: string,
    admit: (header: ConversationHeader) => void,
  ): Promise<ConversationHeader> {
    this.mutable(host);
    identifier(threadId);
    const provider = providerForThread(threadId);
    if (host.target.enrollment && provider === "claude")
      throw new Error("Claude conversation cannot be read through a Codex enrollment");
    let reads = this.headerReads.get(host);
    if (!reads) {
      reads = new Set();
      this.headerReads.set(host, reads);
    }
    if (reads.size >= 32) throw new Error("Thirty-two conversation header reads already await this host");
    const read: HeaderRead = { threadId };
    reads.add(read);
    try {
      const response = object(
        await host.rpc.call(
          "thread/read",
          { threadId, includeTurns: false },
          { signal: host.controller.signal },
        ),
      );
      if (!this.present(host)) throw new DOMException("Canceled", "AbortError");
      const header = conversationHeader(response.thread, provider);
      if (header.id !== threadId) throw new Error("The requested conversation identity changed");
      const retained = retainHeaderKnowledge(
        header,
        host.threads.find((thread) => thread.id === threadId),
      );
      const prepared = read.name ? { ...retained, name: read.name.value } : retained;
      admit(prepared);
      return prepared;
    } finally {
      reads.delete(read);
    }
  }
  updateThreadName(host: HostState, id: string, name: string | null) {
    for (const read of this.headerReads.get(host) ?? [])
      if (read.threadId === id) read.name = { value: name };
    this.mutable(host).threads = host.threads.map((thread) =>
      thread.id === id ? { ...thread, name } : thread,
    );
  }
  recordTurnCompletion(host: HostState, id: string, completedAt: number) {
    this.mutable(host).threads = host.threads.map((thread) =>
      thread.id === id && completedAt > (thread.lastTurnCompletedAt ?? -Infinity)
        ? { ...thread, lastTurnCompletedAt: completedAt }
        : thread,
    );
  }
  seedThreadPreview(host: HostState, id: string, preview: string) {
    this.mutable(host).threads = host.threads.map((thread) =>
      thread.id === id && !thread.preview ? { ...thread, preview } : thread,
    );
  }
  setError(host: HostState, error: unknown) {
    this.mutable(host).error = failure(error);
  }
  private createContext(configuration: Host, target: ExecutionTarget): HostState {
    const versions = this.versions;
    const accountUsage = this.accountUsage;
    const state: HostContext = {
      preferences: { status: "unread" },
      target,
      get accounts() {
        return accountUsage.readCatalog(state.host.id);
      },
      historyRead: 0,
      catalogRead: 0,
      activityRead: 0,
      restoreRead: 0,
      host: configuration,
      status: "disconnected",
      threads: [],
      history: "unread",
      cursors: {},
      historyErrors: [],
      agentWarnings: [],
      choices: { status: "unread" },
      get version() {
        return versions.read(state.host.id);
      },
      rpc: undefined as unknown as Rpc,
      controller: new AbortController(),
    };
    if (this.rpcFactory)
      state.rpc = this.rpcFactory(
        configuration,
        (frame) => {
          if (this.present(state)) this.actions.event(target, frame);
        },
        target,
      );
    else {
      const connection = new GatewayConnection(
        configuration.id,
        (frame) => {
          if (this.present(state)) this.actions.event(target, frame);
        },
        (status, error) => {
          state.status = status;
          state.error = error;
          if (status !== "connected") {
            if (status !== "connecting") {
              state.historyRead++;
              state.catalogRead++;
              state.activityRead++;
              state.restoreRead++;
              state.preferences = { status: "unread" };
            }
            this.actions.disconnected(state);
          }
          this.actions.publish();
        },
        () => {
          void this.actions.restore(target);
        },
        target.enrollment,
      );
      state.rpc = connection;
      state.connection = connection;
    }
    this.contexts.set(targetKey(target), state);
    return state;
  }

  configure(hosts: Host[]) {
    const bindings = new Map(hosts.map((host) => [host.id, host]));
    for (const [key, context] of this.contexts) {
      const replacement = bindings.get(context.host.id);
      if (replacement && replacement.url === context.host.url) {
        context.host = replacement;
        continue;
      }
      this.actions.retiring(context);
      context.controller.abort();
      context.connection?.retire();
      this.contexts.delete(key);
    }
    this.hosts = hosts.map(
      (host) =>
        this.contexts.get(targetKey({ hostId: host.id })) ?? this.createContext(host, { hostId: host.id }),
    );
    this.versions.reconcile();
    this.accountUsage.reconcile();
  }
  refreshVersions() {
    return this.versions.refresh();
  }
  refreshAccounts(hostId: string) {
    return this.accountUsage.refreshHost(hostId);
  }
  async ensure(target: ExecutionTarget) {
    const existing = this.contexts.get(targetKey(target));
    if (existing) return existing;
    const physical = this.get(target.hostId);
    if (!target.enrollment) return physical;
    if (physical.accounts.status !== "ready") await this.refreshAccounts(target.hostId);
    const catalog = physical.accounts;
    if (catalog.status !== "ready")
      throw new Error("The account directory is unavailable. Refresh it before selecting an enrollment.");
    const choice = catalog.value.choices.find((choice) => sameBinding(choice.target, target));
    if (!choice?.usable)
      throw new Error(
        "This exact enrollment and generation cannot start work. Refresh accounts and choose an available connection.",
      );
    if (this.contexts.size >= 24) {
      const removable = [...this.contexts].find(
        ([, context]) =>
          context.target.enrollment &&
          !sameBinding(context.target, this.actions.selectedTarget() ?? { hostId: "unconfigured" }) &&
          this.actions.canRetire(context.target),
      );
      if (!removable)
        throw new Error(
          "Twenty-four execution connections are retained. Close an unused context before adding another.",
        );
      removable[1].controller.abort();
      removable[1].connection?.retire();
      this.contexts.delete(removable[0]);
    }
    return this.createContext(physical.host, target);
  }
  async refresh(id: string | ExecutionTarget, older = false) {
    const host = this.mutable(this.get(id));
    const names = new Map(host.threads.map((thread) => [thread.id, thread.name]));
    if (!older && !host.target.enrollment) this.actions.syncPreferences(host);
    const controller = host.controller;
    const read = ++host.historyRead;
    host.history = "loading";
    host.historyErrors = [];
    this.actions.publish();
    const providers: Provider[] = host.target.enrollment ? ["codex"] : ["codex", "claude"];
    const results = await Promise.allSettled(
      providers.map(async (provider) => {
        const cursor = older ? host.cursors[provider] : undefined;
        if (older && cursor === null) return { provider, entries: [], cursor: null };
        const response = object(
          await host.rpc.call(
            provider === "claude" ? "claude/thread/list" : "thread/list",
            { limit: 50, cursor, sortKey: "updated_at", useStateDbOnly: false },
            { signal: host.controller.signal },
          ),
        );
        return {
          provider,
          cursor: optionalString(response.nextCursor),
          entries: array(response.data, 100).map((value) => conversationHeader(value, provider)),
        };
      }),
    );
    if (controller.signal.aborted || host.historyRead !== read || !this.present(host)) return;
    const pinned = this.pinnedHeaders.get(host)?.ids;
    const protectedIDs = this.protectedThreadIDs(host);
    const collected: ConversationHeader[] = older
      ? [...host.threads]
      : host.threads.filter((thread) => pinned?.has(thread.id) || protectedIDs.has(thread.id));
    for (const [index, result] of results.entries()) {
      if (result.status === "fulfilled") {
        collected.push(...result.value.entries);
        host.cursors[result.value.provider] = result.value.cursor;
      } else {
        host.historyErrors.push(failure(result.reason));
        const provider = providers[index];
        collected.push(...host.threads.filter((thread) => thread.provider === provider));
      }
    }
    const current = new Map(host.threads.map((thread) => [thread.id, thread]));
    const distinct = new Map(
      collected.map((thread) => {
        const latest = current.get(thread.id);
        return [
          thread.id,
          retainHeaderKnowledge(
            latest && latest.name !== names.get(thread.id) ? { ...thread, name: latest.name } : thread,
            latest,
          ),
        ];
      }),
    );
    host.threads = this.retainHeaders(host, [...distinct.values()]);
    host.history = results.some((result) => result.status === "rejected") ? "failed" : "ready";
    this.actions.publish();
    if (!older && host.choices.status !== "ready") {
      const catalogRead = ++host.catalogRead;
      host.choices = { status: "loading" };
      this.actions.publish();
      try {
        let cursor: string | null = null;
        const catalog: Model[] = [];
        const seen = new Set<string>();
        do {
          const response = object(
            await host.rpc.call(
              "model/list",
              { cursor, includeHidden: true },
              { signal: host.controller.signal },
            ),
          );
          catalog.push(...models(response));
          cursor = optionalString(response.nextCursor);
          if (cursor && seen.has(cursor)) throw new Error("Model catalog repeated its cursor");
          if (cursor) seen.add(cursor);
        } while (cursor && catalog.length < 200);
        if (controller.signal.aborted || host.catalogRead !== catalogRead || !this.present(host)) return;
        const modelIDs = new Set<string>();
        host.choices = {
          status: "ready",
          value: [
            ...catalog
              .filter((model) => {
                if (modelIDs.has(model.model)) return false;
                modelIDs.add(model.model);
                return true;
              })
              .map((model) => ({
                id: model.model,
                name: external(model)
                  ? `${model.displayName} · ${model.modelProviderName}`
                  : model.displayName,
                provider: "codex" as const,
                modelProvider: external(model) ? model.modelProvider : undefined,
                efforts: model.supportedReasoningEfforts.map((effort) => effort.reasoningEffort),
                defaultEffort: model.defaultReasoningEffort,
                hiddenUpstream: model.hidden,
                upstreamDefault: model.isDefault,
                fast:
                  model.serviceTiers?.some((tier) => tier.id === "fast") ??
                  model.additionalSpeedTiers?.includes("fast") ??
                  false,
                images: model.inputModalities?.includes("image") ?? false,
              })),
            ...claudeCatalog,
          ] as ModelChoice[],
        };
      } catch (error) {
        if (controller.signal.aborted || host.catalogRead !== catalogRead || !this.present(host)) return;
        host.choices = { status: "failed", error: failure(error) };
      }
      this.actions.catalogReady();
      this.actions.publish();
    }
    await this.refreshAgentClassifications(host);
  }

  protectPinnedThreads(host: HostState, ids: readonly string[]): Promise<void> {
    if (!this.present(host)) return Promise.resolve();
    let recovery = this.pinnedHeaders.get(host);
    if (!recovery) {
      recovery = { ids: new Set(), failures: new Map(), overLimit: false };
      this.pinnedHeaders.set(host, recovery);
      const owner = recovery;
      host.controller.signal.addEventListener("abort", () => this.cancelPinnedRetry(owner), { once: true });
    }
    const distinct = [...new Set(ids)].sort();
    const next = new Set(distinct.slice(0, 500));
    const changed = next.size !== recovery.ids.size || [...next].some((id) => !recovery.ids.has(id));
    recovery.ids = next;
    recovery.overLimit = distinct.length > 500;
    for (const id of recovery.failures.keys()) if (!next.has(id)) recovery.failures.delete(id);
    if (changed) {
      this.cancelPinnedRetry(recovery);
      this.mutable(host).threads = this.retainHeaders(host, host.threads);
    }
    if (recovery.task && changed) recovery.requested = true;
    return this.refreshPinnedRecovery(host, recovery);
  }
  private refreshPinnedRecovery(host: HostState, recovery: PinnedHeaderRecovery): Promise<void> {
    if (recovery.task) return recovery.task;
    const owned = recovery;
    owned.task = Promise.resolve().then(async () => {
      try {
        do {
          owned.requested = false;
          await this.recoverPinnedHeaders(host, owned);
        } while (owned.requested && this.present(host));
      } finally {
        owned.task = undefined;
        this.schedulePinnedRetry(host, owned);
      }
    });
    return owned.task;
  }
  private protectedThreadIDs(host: HostState): Set<string> {
    return new Set(
      this.actions
        .protectedAddresses()
        .filter((address) => sameBinding(address, host.target))
        .map((address) => address.threadId),
    );
  }
  private retainHeaders(host: HostState, headers: readonly ConversationHeader[]): ConversationHeader[] {
    const pinned = this.pinnedHeaders.get(host)?.ids;
    const protectedIDs = this.protectedThreadIDs(host);
    const priority = (header: ConversationHeader) =>
      protectedIDs.has(header.id) ? 0 : pinned?.has(header.id) ? 1 : 2;
    const compare = (first: ConversationHeader, second: ConversationHeader) =>
      (second.updatedAt ?? -Infinity) - (first.updatedAt ?? -Infinity);
    return [...headers]
      .sort((first, second) => priority(first) - priority(second) || compare(first, second))
      .slice(0, 500)
      .sort(compare);
  }
  private cancelPinnedRetry(recovery: PinnedHeaderRecovery) {
    clearTimeout(recovery.retry);
    recovery.retry = undefined;
    recovery.retryAt = undefined;
  }
  private pinnedWindowFull(host: HostState, recovery: PinnedHeaderRecovery): boolean {
    const protectedIDs = this.protectedThreadIDs(host);
    return (
      host.threads.filter((header) => protectedIDs.has(header.id) || recovery.ids.has(header.id)).length >=
      500
    );
  }
  private schedulePinnedRetry(host: HostState, recovery: PinnedHeaderRecovery) {
    if (!this.present(host) || this.pinnedWindowFull(host, recovery)) {
      this.cancelPinnedRetry(recovery);
      return;
    }
    const loaded = new Set(host.threads.map((thread) => thread.id));
    const times = [...recovery.failures]
      .filter(([id]) => recovery.ids.has(id) && !loaded.has(id))
      .map(([, failure]) => failure.retryAt);
    const next = times.length ? Math.min(...times) : undefined;
    if (recovery.retry && recovery.retryAt === next) return;
    this.cancelPinnedRetry(recovery);
    if (next === undefined) return;
    recovery.retryAt = next;
    recovery.retry = setTimeout(
      () => {
        recovery.retry = undefined;
        recovery.retryAt = undefined;
        if (this.present(host)) void this.refreshPinnedRecovery(host, recovery);
      },
      Math.max(0, next - Date.now()),
    );
  }
  private async recoverPinnedHeaders(host: HostState, recovery: PinnedHeaderRecovery): Promise<void> {
    const attempted = new Set<string>();
    let added = false;
    for (let count = 0; count < 32 && this.present(host); count++) {
      const loaded = new Set(host.threads.map((thread) => thread.id));
      const id = [...recovery.ids].find(
        (id) =>
          !loaded.has(id) && !attempted.has(id) && (recovery.failures.get(id)?.retryAt ?? 0) <= Date.now(),
      );
      if (!id || this.pinnedWindowFull(host, recovery)) break;
      attempted.add(id);
      try {
        await this.readHeader(host, id, (header) => {
          if (!this.present(host) || !recovery.ids.has(id) || host.threads.some((thread) => thread.id === id))
            return;
          this.recordThread(host, header);
          recovery.failures.delete(id);
          added = true;
          this.actions.publish();
        });
      } catch {
        if (!this.present(host)) return;
        if (!recovery.ids.has(id) || host.threads.some((thread) => thread.id === id)) continue;
        const interval = Math.min((recovery.failures.get(id)?.interval ?? 15000) * 2, 600000);
        recovery.failures.set(id, { interval, retryAt: Date.now() + interval });
      }
    }
    if (!this.present(host)) return;
    const loaded = new Set(host.threads.map((thread) => thread.id));
    for (const id of recovery.failures.keys()) if (loaded.has(id)) recovery.failures.delete(id);
    const missing = [...recovery.ids].some((id) => !loaded.has(id));
    const error =
      recovery.overLimit || (missing && this.pinnedWindowFull(host, recovery))
        ? "Pinned, selected and active conversations exceed the 500-header history limit. Unpin a conversation to load another."
        : missing
          ? recovery.failures.size
            ? "Some pinned conversations could not be loaded. Retrying when their cooldown expires."
            : "Some pinned conversations are not loaded yet. Refresh to load more."
          : undefined;
    if (host.pinnedRecoveryError !== error) {
      this.mutable(host).pinnedRecoveryError = error;
      this.actions.publish();
    }
    if (added) await this.refreshAgentClassifications(host);
  }

  refreshAgentClassifications(host: HostState) {
    return this.classifier(host).refresh();
  }

  private classifier(host: HostState) {
    let classifier = this.classifiers.get(host);
    if (!classifier) {
      classifier = new ConversationAgentClassifier(
        host.rpc,
        host.controller.signal,
        () => host.threads,
        (classifications, warnings) => {
          if (!this.present(host)) return;
          const context = this.mutable(host);
          context.threads = host.threads.map((header) => ({
            ...header,
            agentClassification:
              header.agentClassification.kind === "unresolved"
                ? (classifications.get(header.id) ?? header.agentClassification)
                : header.agentClassification,
          }));
          context.agentWarnings = warnings;
          this.actions.publish();
        },
      );
      this.classifiers.set(host, classifier);
    }
    return classifier;
  }

  featureTransport(host: HostState, cwd: string) {
    const hostId = host.host.id;
    const listenerKey = targetKey(host.target);
    return {
      hostId,
      hostName: host.host.name,
      target: host.target,
      cwd,
      http: (path: string, init?: RequestInit) =>
        api(`/api/hosts/${encodeURIComponent(hostId)}/${path.replace(/^\//, "")}`, init),
      request: (method: string, params: unknown = {}, options?: { signal?: AbortSignal; timeout?: number }) =>
        host.rpc.call(method, params, options),
      subscribe: (listener: (frame: Frame) => void) => {
        const listeners = this.featureListeners.get(listenerKey) ?? new Set();
        listeners.add(listener);
        this.featureListeners.set(listenerKey, listeners);
        return () => {
          listeners.delete(listener);
          if (!listeners.size) this.featureListeners.delete(listenerKey);
        };
      },
    };
  }
  notifyFeatures(target: ExecutionTarget, frame: Frame) {
    for (const listener of this.featureListeners.get(targetKey(target)) ?? []) {
      try {
        listener(frame);
      } catch (error) {
        this.actions.report(error);
      }
    }
  }
  beginRestore(host: HostState) {
    return ++this.mutable(host).restoreRead;
  }
  dispose() {
    this.accountUsage.dispose();
    this.versions.dispose();
    for (const host of this.contexts.values()) {
      host.controller.abort();
      host.connection?.retire();
    }
    this.featureListeners.clear();
  }
}
