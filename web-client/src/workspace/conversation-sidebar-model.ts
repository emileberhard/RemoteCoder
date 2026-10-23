import { type ExecutionTarget, targetKey } from "../execution-context";
import { providerForThread } from "../protocol/agent-provider";
import { type Address, addressKey, type Questions, questions } from "../protocol/boundary";
import type { Draft } from "./composer-draft-store";
import type { ConversationActivityState } from "./conversation-activity";
import { type ConversationActivity, conversationActivity } from "./conversation-activity";
import type { ConversationDrawerArrangement } from "./conversation-drawer-preferences";
import { type ConversationHeader, isDelegatedAgent, latestActivityAt } from "./conversation-header";
import {
  type ConversationMarkChange,
  isUnread,
  isUnseenQuestion,
  normalizedPinName,
} from "./conversation-marks";
import { ConversationMarksStore } from "./conversation-marks-store";
import { ConversationProjects } from "./conversation-projects";
import type { Conversation } from "./conversation-session";
import {
  admitDrawerLayout,
  type ConversationDrawerLayout,
  type ConversationSidebarHostInput,
  type ConversationSidebarSnapshot,
  captureDrawerLayout,
  conversationRowMarkState,
  projectConversationSidebar,
} from "./conversation-sidebar-projection";
import { type DrawerUndo, drawerUndo } from "./drawer-undo";
import type { HostServices, HostState } from "./host-services";
import { failure } from "./load-state";

type HostInputState = {
  host: HostState;
  marks: ConversationMarksStore;
  projects: ConversationProjects;
  activityValue?: unknown;
  activityThreads?: readonly ConversationHeader[];
  activity: ConversationActivity;
  activityRead: number;
  questions: ReadonlyMap<string, readonly number[] | undefined>;
  questionRead: number;
  questionTask?: Promise<void>;
  questionRequested: Set<string>;
  errors: readonly string[];
  settlementEdits: ReadonlyMap<string, number>;
  input?: ConversationSidebarHostInput;
  managedActivity?: {
    base: ReadonlyMap<string, ConversationActivityState>;
    ids: readonly string[];
    value: ReadonlyMap<string, ConversationActivityState>;
  };
};
type SettlementBatch = { changes: ConversationMarkChange[]; undo: ConversationMarkChange[] };
export class ConversationSidebarModel {
  private readonly states = new Map<string, HostInputState>();
  private layout?: ConversationDrawerLayout;
  private capturedAt?: number;
  private memo?: { inputs: readonly unknown[]; value: ConversationSidebarSnapshot };
  constructor(
    private readonly hosts: HostServices,
    private readonly storage: Storage | undefined,
    private readonly publish: () => void,
    private readonly report: (error: unknown) => void,
  ) {}
  reconcile() {
    for (const [key, state] of this.states)
      if (!this.hosts.present(state.host)) {
        state.marks.dispose();
        state.projects.dispose();
        this.states.delete(key);
      }
  }
  private state(host: HostState): HostInputState {
    this.reconcile();
    const key = targetKey(host.target);
    let state = this.states.get(key);
    if (!state) {
      state = {
        host,
        marks: new ConversationMarksStore(host.target, host.rpc, this.storage, () => {
          void this.recoverPins(host);
          this.publish();
        }),
        projects: new ConversationProjects(host.rpc, this.publish),
        activity: { states: new Map(), waitingSince: new Map() },
        activityRead: 0,
        questions: new Map(),
        questionRead: 0,
        questionRequested: new Set(),
        errors: [],
        settlementEdits: new Map(),
      };
      this.states.set(key, state);
      void this.recoverPins(host);
    }
    return state;
  }
  private recoverPins(host: HostState): Promise<void> {
    if (!this.hosts.present(host)) return Promise.resolve();
    const state = this.states.get(targetKey(host.target));
    const marks = state?.marks.marks;
    if (!marks) return Promise.resolve();
    return this.hosts.protectPinnedThreads(
      host,
      Object.entries(marks.threads)
        .filter(([, marks]) => marks.pinName !== undefined)
        .map(([id]) => id),
    );
  }
  marks(target: ExecutionTarget) {
    return this.state(this.hosts.get(target)).marks;
  }
  async refresh(host: HostState) {
    const state = this.state(host);
    state.errors = [];
    const read = ++state.activityRead;
    const ids = host.threads
      .filter((thread) => !isDelegatedAgent(thread) && thread.provider === "codex")
      .slice(0, 32)
      .map((thread) => thread.id);
    await Promise.allSettled([
      state.marks.sync(),
      state.projects.refresh(host.threads.map((thread) => thread.cwd)),
      this.requestQuestions(state, ids),
      (async () => {
        try {
          const value = await host.rpc.call("daemon/activeTurns", {}, { signal: host.controller.signal });
          if (this.hosts.present(host) && state.activityRead === read) this.receiveActivity(host, value);
        } catch (error) {
          if (this.hosts.present(host) && state.activityRead === read) {
            state.activityValue = undefined;
            state.activity = { states: new Map(), waitingSince: new Map() };
            state.errors = [...state.errors, failure(error)];
            this.publish();
          }
        }
      })(),
    ]);
    if (this.hosts.present(host)) {
      await this.recoverPins(host);
      if (this.hosts.present(host)) this.publish();
    }
  }
  receiveActivity(host: HostState, value: unknown) {
    const state = this.state(host);
    state.activityRead++;
    state.activity = conversationActivity(value, host.threads);
    state.activityValue = value;
    state.activityThreads = host.threads;
  }
  receiveQuestions(host: HostState, threadId: string, inventory: Questions) {
    const state = this.state(host);
    state.questionRead++;
    const pending = new Set(inventory.pendingItemIds ?? []);
    const askTimes =
      inventory.coverage === "ready" && inventory.pendingItemIds !== undefined
        ? inventory.records
            .filter((record) => pending.has(record.itemId))
            .flatMap((record) => (record.askedAtMs == null ? [] : [record.askedAtMs]))
        : undefined;
    const entries = new Map(state.questions);
    entries.delete(threadId);
    entries.set(threadId, askTimes);
    while (entries.size > 32) entries.delete(entries.keys().next().value as string);
    state.questions = entries;
  }
  private requestQuestions(state: HostInputState, ids: readonly string[]) {
    for (const id of ids) if (providerForThread(id) === "codex") state.questionRequested.add(id);
    while (state.questionRequested.size > 32)
      state.questionRequested.delete(state.questionRequested.values().next().value as string);
    if (state.questionTask) return state.questionTask;
    const task = Promise.resolve().then(async () => {
      try {
        while (state.questionRequested.size && this.hosts.present(state.host)) {
          const batch = [...state.questionRequested].slice(0, 16);
          for (const id of batch) state.questionRequested.delete(id);
          const read = state.questionRead;
          try {
            const value = await state.host.rpc.call(
              "conversation/questions/read",
              { queries: batch.map((threadId) => ({ threadId, itemIds: [] })) },
              { signal: state.host.controller.signal },
            );
            if (!this.hosts.present(state.host)) return;
            if (read !== state.questionRead) {
              for (const id of batch) state.questionRequested.add(id);
              while (state.questionRequested.size > 32)
                state.questionRequested.delete(state.questionRequested.values().next().value as string);
              continue;
            }
            const parsed = batch.map((id) => ({ id, inventory: questions(value, id) }));
            for (const { id, inventory } of parsed) this.receiveQuestions(state.host, id, inventory);
          } catch (error) {
            if (!this.hosts.present(state.host)) return;
            if (read !== state.questionRead) {
              for (const id of batch) state.questionRequested.add(id);
              while (state.questionRequested.size > 32)
                state.questionRequested.delete(state.questionRequested.values().next().value as string);
              continue;
            }
            const next = new Map(state.questions);
            for (const id of batch) next.set(id, undefined);
            state.questions = next;
            state.errors = [...state.errors.slice(-3), failure(error)];
          }
          this.publish();
        }
      } finally {
        state.questionTask = undefined;
      }
    });
    state.questionTask = task;
    return task;
  }
  changedQuestions(host: HostState, params: Record<string, unknown>) {
    if (typeof params.threadId !== "string") throw new Error("Question notification lacks a thread");
    const state = this.state(host);
    state.questionRead++;
    const next = new Map(state.questions);
    next.set(params.threadId, undefined);
    while (next.size > 32) next.delete(next.keys().next().value as string);
    state.questions = next;
    this.publish();
    void this.requestQuestions(state, [params.threadId]);
  }
  disconnected(host: HostState) {
    const state = this.state(host);
    state.activityRead++;
    state.questionRead++;
    state.activityValue = undefined;
    state.activity = { states: new Map(), waitingSince: new Map() };
    state.questions = new Map();
  }
  record(target: ExecutionTarget, changes: readonly ConversationMarkChange[]) {
    const state = this.state(this.hosts.get(target));
    state.marks.recordChanges(changes);
    const edits = changes.filter((change) => change.op === "settle" || change.op === "unsettle");
    if (edits.length) {
      const next = new Map(state.settlementEdits);
      for (const change of edits)
        if ("threadId" in change) next.set(change.threadId, (next.get(change.threadId) ?? 0) + 1);
      state.settlementEdits = next;
      this.publish();
    }
  }
  pin(address: Address, name: string) {
    const normalized = normalizedPinName(name);
    if (!normalized) throw new Error("Enter a pin name");
    this.record(address, [{ op: "pin", threadId: address.threadId, name: normalized }]);
  }
  private settlement(address: Address) {
    const state = this.state(this.hosts.get(address));
    const header = state.host.threads.find((header) => header.id === address.threadId);
    if (!header || isDelegatedAgent(header)) throw new Error("The conversation cannot be settled");
    const marks = state.marks.marks;
    const times =
      state.questions
        .get(address.threadId)
        ?.filter((time) => marks && isUnseenQuestion(marks, time, address.threadId))
        .map((time) => Math.trunc(time / 1000)) ?? [];
    const waiting = state.activity.waitingSince.get(address.threadId);
    const through = Math.max(latestActivityAt(header) ?? -Infinity, waiting ?? -Infinity, ...times);
    if (!Number.isFinite(through))
      throw new Error("Conversation activity time is unknown; refresh before settling");
    return { state, header, through };
  }
  liveAddresses(): readonly Address[] {
    return [...this.states.values()].flatMap((state) =>
      this.hosts.present(state.host)
        ? [...state.activity.states]
            .filter(([, activity]) => activity === "working" || activity === "waiting")
            .map(([threadId]) => ({ ...state.host.target, threadId }))
        : [],
    );
  }
  settle(address: Address, settled: boolean) {
    if (settled) return this.settleConversations([address]);
    const { through } = this.settlement(address);
    this.record(address, [{ op: "unsettle", threadId: address.threadId, through }]);
  }
  settleConversations(addresses: readonly Address[]): DrawerUndo {
    const batches = new Map<HostInputState, SettlementBatch>();
    const unique = new Set<string>();
    for (const address of addresses) {
      const key = addressKey(address);
      if (unique.has(key)) continue;
      unique.add(key);
      const { state, header, through } = this.settlement(address);
      const marks = state.marks.marks;
      if (!marks || marks.schemaVersion < 2) throw new Error("Refresh conversation marks before settling");
      if (state.activity.states.get(address.threadId) === "working")
        throw new Error("A running conversation cannot be settled");
      const batch = batches.get(state) ?? { changes: [], undo: [] };
      batch.changes.push({ op: "settle", threadId: address.threadId, through });
      batch.undo.push({ op: "unsettle", threadId: address.threadId, through });
      const pinName = marks.threads[address.threadId]?.pinName;
      if (pinName) batch.undo.push({ op: "pin", threadId: address.threadId, name: pinName });
      if (
        isUnread(marks, {
          id: header.id,
          latestActivityAt: latestActivityAt(header),
          lastTurnCompletedAt: header.lastTurnCompletedAt,
        })
      )
        batch.undo.push({ op: "markUnread", threadId: address.threadId });
      batches.set(state, batch);
    }
    for (const [state, batch] of batches)
      if (state.marks.pendingCount + batch.changes.length > 2000)
        throw new Error("Sync pending conversation changes before settling more");
    const completed = new Map<HostInputState, SettlementBatch>();
    const failures: string[] = [];
    for (const [state, batch] of batches) {
      try {
        if (!this.hosts.present(state.host))
          throw new Error("The conversation's execution context was retired");
        this.record(state.host.target, batch.changes);
        completed.set(state, batch);
      } catch (error) {
        failures.push(`${state.host.host.name}: ${failure(error)}`);
      }
    }
    if (failures.length) this.report(new Error(failures.join("\n")));
    return drawerUndo(
      [...completed.values()].reduce((count, batch) => count + batch.changes.length, 0),
      () => {
        const failures: string[] = [];
        for (const [state, batch] of completed) {
          try {
            if (!this.hosts.present(state.host))
              throw new Error("The conversation's execution context was retired");
            this.record(state.host.target, batch.undo);
            completed.delete(state);
          } catch (error) {
            failures.push(`${state.host.host.name}: ${failure(error)}`);
          }
        }
        if (failures.length) throw new Error(failures.join("\n"));
      },
    );
  }
  rowState(address: Address, conversation: Conversation | undefined, now: number) {
    const state = this.state(this.hosts.get(address));
    const header = state.host.threads.find((header) => header.id === address.threadId);
    if (!header || isDelegatedAgent(header)) return undefined;
    return conversationRowMarkState(
      header,
      {
        marks: state.marks.marks,
        activity: conversation?.activeTurnId
          ? new Map([[address.threadId, "working"]])
          : state.activity.states,
        waitingSince: state.activity.waitingSince,
        questionAskTimes: state.questions,
        settlementEdits: state.settlementEdits,
      },
      now,
      this.layout?.get(addressKey(address)),
    );
  }
  get isOpen() {
    return this.layout !== undefined;
  }
  private inputs(
    conversations: ReadonlyMap<string, Conversation>,
    home: (hostId: string) => string | undefined,
  ): ConversationSidebarHostInput[] {
    return [...this.hosts.allContexts.values()].map((host) => {
      const state = this.state(host);
      if (state.activityValue && state.activityThreads !== host.threads) {
        state.activity = conversationActivity(state.activityValue, host.threads);
        state.activityThreads = host.threads;
      }
      const activeIds: string[] = [];
      let loadingThreadId: string | undefined;
      for (const conversation of conversations.values()) {
        if (targetKey(conversation.address) !== targetKey(host.target)) continue;
        if (conversation.activeTurnId) activeIds.push(conversation.address.threadId);
        if (conversation.status === "loading") loadingThreadId = conversation.address.threadId;
      }
      let activity = state.activity.states;
      if (activeIds.length) {
        const cached = state.managedActivity;
        if (
          cached?.base === activity &&
          activeIds.length === cached.ids.length &&
          activeIds.every((id, index) => cached.ids[index] === id)
        )
          activity = cached.value;
        else {
          const overlay = new Map(activity);
          for (const id of activeIds) overlay.set(id, "working");
          state.managedActivity = { base: activity, ids: activeIds, value: overlay };
          activity = overlay;
        }
      } else state.managedActivity = undefined;
      const input: ConversationSidebarHostInput = {
        target: host.target,
        hostName: host.host.name,
        threads: host.threads,
        marks: state.marks.marks,
        homePath: home(host.host.id),
        activity,
        waitingSince: state.activity.waitingSince,
        questionAskTimes: state.questions,
        projects: state.projects.snapshot,
        settlementEdits: state.settlementEdits,
        loadingThreadId,
        isLoading: host.history === "loading",
        history: host.history,
        marksStatus: state.marks.status,
        errors: [
          ...host.historyErrors,
          ...host.agentWarnings,
          ...(host.pinnedRecoveryError ? [host.pinnedRecoveryError] : []),
          ...state.errors,
          ...(state.marks.error ? [state.marks.error] : []),
          ...(state.marks.restoreWarning ? [state.marks.restoreWarning] : []),
          ...(state.projects.error ? [state.projects.error] : []),
        ],
        canLoadMore: Object.values(host.cursors).some((cursor) => typeof cursor === "string"),
      };
      const previous = state.input;
      if (
        previous &&
        Object.entries(input).every(([key, value]) =>
          key === "errors"
            ? input.errors.length === previous.errors.length &&
              input.errors.every((error, index) => previous.errors[index] === error)
            : previous[key as keyof ConversationSidebarHostInput] === value,
        )
      )
        return previous;
      state.input = input;
      return input;
    });
  }
  open(
    conversations: ReadonlyMap<string, Conversation>,
    home: (hostId: string) => string | undefined,
    now: number,
  ) {
    this.capturedAt = now;
    this.layout = captureDrawerLayout(this.inputs(conversations, home), now);
    this.memo = undefined;
    this.publish();
  }
  close() {
    this.layout = undefined;
    this.capturedAt = undefined;
    this.memo = undefined;
  }
  snapshot(
    selected: Address | undefined,
    drafts: ReadonlyMap<string, Draft>,
    conversations: ReadonlyMap<string, Conversation>,
    arrangement: ConversationDrawerArrangement,
    home: (hostId: string) => string | undefined,
    now: number,
  ): ConversationSidebarSnapshot {
    const hosts = this.inputs(conversations, home);
    const references: unknown[] = [
      selected ? addressKey(selected) : undefined,
      drafts,
      arrangement,
      Math.floor(now / 60),
      ...hosts,
    ];
    if (
      this.memo &&
      references.length === this.memo.inputs.length &&
      references.every((value, index) => value === this.memo?.inputs[index])
    )
      return this.memo.value;
    if (this.layout) this.layout = admitDrawerLayout(this.layout, hosts, this.capturedAt ?? now);
    const value = projectConversationSidebar(hosts, selected, drafts, arrangement, now, this.layout);
    this.memo = { inputs: references, value };
    return value;
  }
  unfoldedRows(
    selected: Address | undefined,
    drafts: ReadonlyMap<string, Draft>,
    conversations: ReadonlyMap<string, Conversation>,
    arrangement: ConversationDrawerArrangement,
    home: (hostId: string) => string | undefined,
    now: number,
  ) {
    const unfolded = {
      ...arrangement,
      isPinnedFolded: false,
      isAutomationsFolded: false,
      isSettledFolded: false,
      foldedProjects: new Set<string>(),
      projectRowLimit: Number.MAX_SAFE_INTEGER,
      automationRowLimit: Number.MAX_SAFE_INTEGER,
      settledRowLimit: Number.MAX_SAFE_INTEGER,
    };
    return projectConversationSidebar(
      this.inputs(conversations, home),
      selected,
      drafts,
      unfolded,
      now,
      this.layout,
    ).sections.flatMap((section) => section.rows);
  }
  dispose() {
    for (const state of this.states.values()) {
      state.marks.dispose();
      state.projects.dispose();
    }
    this.states.clear();
  }
}
