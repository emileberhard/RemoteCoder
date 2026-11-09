import { decodeAddress, type ExecutionTarget, sameBinding } from "../execution-context";
import { providerForThread } from "../protocol/agent-provider";
import {
  type Address,
  addressKey,
  array,
  type Entry,
  entry,
  type Frame,
  type Item,
  identifier,
  item,
  object,
  optionalString,
  type QuestionRecord,
  type Questions,
  questions,
  type Receipt,
  string,
} from "../protocol/boundary";
import type { QueuedSubmission } from "../protocol/generated/v2/QueuedSubmission";
import type { MarkdownBlocks } from "../rendering";
import { type ConversationTokenUsage, threadTokenUsage } from "./context-window-usage";
import { type ConversationHeader, conversationHeader, retainHeaderKnowledge } from "./conversation-header";
import type { HostServices, HostState } from "./host-services";
import { failure, type Load } from "./load-state";
import type { SubmissionReceipt } from "./turn-dispatcher";
export type Row = {
  steer: boolean;
  bytes: number;
  entry: Entry;
  revision: number;
  markdown?: MarkdownBlocks;
  visualPlacements?: string[];
  livePrefix?: boolean;
  delivery?: "sending" | "admitted" | "uncertain" | "failed";
  error?: string;
};
export type RequestCard = { id: string | number; method: string; params: Record<string, unknown> };
type ConversationState = {
  resumeRequired: boolean;
  bytes: number;
  observationBuffer?: { events: Frame[]; bytes: number };
  observationReceipt?: Receipt;
  claudeCheckpoint?: { epoch: string; sequence: number; turnId: string };
  questionRead: number;
  queueRead: number;
  address: Address;
  header: ConversationHeader;
  rows: Row[];
  status: "loading" | "ready" | "failed";
  error?: string;
  older: string | null;
  newer: string | null;
  historyLoading?: "older" | "newer";
  historyError?: string;
  historyReloadRequired: boolean;
  activeTurnId: string | null | undefined;
  questions: Load<Questions>;
  queue: Load<{ entries: QueuedSubmission[]; hold: string | null }>;
  usage?: ConversationTokenUsage;
  requests: RequestCard[];
  diff?: string;
  plan?: { step: string; status: string }[];
  submitting: boolean;
  observation?: string;
  controller: AbortController;
};
export type Conversation = Readonly<ConversationState>;
export type Renderer = {
  append(id: string, delta: string, revision: number, source?: string): void;
  update(id: string, source: string, revision: number, complete: boolean): void;
  remove(id: string): void;
  dispose(): void;
};
const source = (item: Item) => (item.type === "agentMessage" || item.type === "plan" ? item.text : undefined);
const renderKey = (address: Address, id: string) => `${JSON.stringify(address)}\u0000${id}`;
const itemSize = (value: Item) => JSON.stringify(value).length * 2;

type HistoryPage = { ids: Set<string>; older: string | null; newer: string | null };

export class ConversationSession {
  private pages: HistoryPage[] = [];
  private rebuilding = false;
  private historyRead?: Promise<void>;
  private readonly state: ConversationState;
  private nameRevision = 0;
  constructor(
    private host: HostState,
    address: Address,
    header: ConversationHeader,
    started: boolean,
    private readonly hosts: HostServices,
    private readonly actions: {
      publish(live?: boolean): void;
      renderer(): Renderer | undefined;
      present(session: ConversationSession): boolean;
      receipts(): ReadonlyMap<string, SubmissionReceipt>;
      reconcileReceipts(conversation: ConversationState): void;
      syncClaudeSubscriptions(host: HostState): Promise<void>;
      claudeQueue(hostId: string): Promise<boolean | undefined>;
      applyActivity(host: HostState, value: unknown): void;
      receiveQuestions(host: HostState, threadId: string, inventory: Questions): void;
      replay(target: ExecutionTarget, notification: Frame): void;
    },
  ) {
    this.state = {
      resumeRequired: !started,
      bytes: 0,
      questionRead: 0,
      queueRead: 0,
      address,
      header,
      rows: [],
      status: started ? "ready" : "loading",
      older: null,
      newer: null,
      historyReloadRequired: false,
      activeTurnId: started ? null : undefined,
      questions: { status: "unread" },
      queue: { status: "unread" },
      requests: [],
      submitting: false,
      controller: new AbortController(),
    };
  }
  get snapshot(): Conversation {
    return this.state;
  }
  private get renderer() {
    return this.actions.renderer();
  }
  private publish(live = false) {
    this.actions.publish(live);
  }
  rebind(host: HostState, address: Address) {
    const conversation = this.state;
    if (sameBinding(conversation.address, address)) return;
    if (conversation.submitting)
      throw new Error("The previous execution binding is awaiting a submission acknowledgment");
    conversation.controller.abort();
    for (const row of conversation.rows)
      this.renderer?.remove(renderKey(conversation.address, row.entry.item.id));
    this.host = host;
    conversation.address = address;
    conversation.activeTurnId = undefined;
    conversation.requests = [];
    conversation.observation = undefined;
    conversation.observationReceipt = undefined;
  }
  disconnected() {
    this.state.activeTurnId = undefined;
    this.state.claudeCheckpoint = undefined;
    this.state.rows = this.state.rows.map((row) => (row.livePrefix ? { ...row, livePrefix: false } : row));
    this.state.questions = { status: "unread" };
    this.state.requests = [];
  }
  setError(error: string) {
    this.state.error = error;
  }
  updateName(name: string | null) {
    this.nameRevision++;
    this.state.header = { ...this.state.header, name };
  }
  seedPreview(preview: string) {
    if (!this.state.header.preview) this.state.header = { ...this.state.header, preview };
  }
  setSubmitting(submitting: boolean) {
    this.state.submitting = submitting;
  }
  markResumed() {
    this.state.resumeRequired = false;
  }
  admitTurn(id: string) {
    this.state.activeTurnId = id;
  }
  setDelivery(id: string, steer: boolean, delivery: Row["delivery"], error?: string) {
    const index = this.state.rows.findIndex((row) => row.entry.item.id === id);
    const row = this.state.rows[index];
    if (row && (row.delivery || delivery === "sending"))
      this.state.rows[index] = { ...row, steer, delivery, error };
  }
  appendSubmission(entry: Entry) {
    this.upsert(entry, true);
  }
  removeSubmission(id: string) {
    const row = this.state.rows.find((row) => row.entry.item.id === id);
    if (!row) return;
    this.state.rows = this.state.rows.filter((candidate) => candidate !== row);
    this.state.bytes -= row.bytes;
    this.renderer?.remove(renderKey(this.state.address, id));
  }
  applyActivity(active: Record<string, unknown>[], coverage: Record<string, unknown>) {
    const turn = active.find((turn) => turn.threadId === this.state.address.threadId);
    this.state.activeTurnId = turn
      ? identifier(turn.turnId)
      : coverage[this.state.header.provider] === true
        ? null
        : undefined;
    if (this.state.status !== "loading") this.reconcileSteers();
  }
  load() {
    return this.loadTail("latest");
  }
  private async loadTail(position: "latest" | "window") {
    const current = this.state;
    const previousPages = this.pages;
    const nameRevision = this.nameRevision;
    const host = this.host;
    const address = current.address;
    current.controller.abort();
    current.controller = new AbortController();
    current.status = "loading";
    current.historyLoading = undefined;
    current.historyError = undefined;
    this.historyRead = undefined;
    current.error = undefined;
    const controller = current.controller;
    current.observationBuffer = { events: [], bytes: 0 };
    current.claudeCheckpoint = undefined;
    current.rows = current.rows.map((row) => (row.livePrefix ? { ...row, livePrefix: false } : row));
    this.publish();
    const checked = () => {
      if (controller.signal.aborted || current.controller !== controller || !this.actions.present(this))
        throw new DOMException("Canceled", "AbortError");
    };
    try {
      const claude = current.header.provider === "claude";
      const captured = claude
        ? undefined
        : await host.rpc.capture(
            "thread/subscribe",
            { threadId: address.threadId },
            { signal: controller.signal },
          );
      checked();
      const subscription = captured ? object(captured.value) : undefined;
      current.resumeRequired = subscription?.status !== "subscribed";
      if (subscription?.status === "subscribed") {
        current.observation = identifier(subscription.subscriptionId);
        const header = retainHeaderKnowledge(
          conversationHeader(subscription.thread, current.header.provider),
          current.header,
        );
        current.header =
          this.nameRevision === nameRevision ? header : { ...header, name: current.header.name };
      }
      try {
        await this.actions.syncClaudeSubscriptions(host);
      } catch (error) {
        checked();
        current.error = `Live subscription unavailable: ${failure(error)}`;
      }
      checked();
      const checkpoint = subscription?.status === "subscribed" ? object(subscription.checkpoint) : undefined;
      if (checkpoint?.historyUnavailable === true)
        current.historyError = "Stored history is unavailable. The live window is still shown.";
      const checkpointItems = checkpoint ? array(checkpoint.liveItems, 200).map(entry) : [];
      const activityRead = this.hosts.beginActivityRead(host);
      let [pageCapture, activityValue] = await Promise.all([
        checkpoint && captured && checkpoint.itemsBackwardsCursor == null
          ? Promise.resolve({
              response: { data: [], nextCursor: null },
              values: [],
              receipt: captured.receipt,
            })
          : this.readPage(
              "desc",
              checkpoint ? optionalString(checkpoint.itemsBackwardsCursor) : null,
              controller,
              checkpointItems,
            ),
        host.rpc.call("daemon/activeTurns", {}, { signal: controller.signal }),
      ]);
      checked();
      let claudeSnapshot: Record<string, unknown> | undefined;
      if (claude) {
        try {
          const value = object(
            await host.rpc.call(
              "claude/thread/liveCheckpoint",
              { threadId: address.threadId },
              { signal: controller.signal },
            ),
          );
          checked();
          if (value.threadId !== address.threadId) throw new Error("Claude checkpoint identity changed");
          if (value.status === "observed") {
            if (!Number.isSafeInteger(value.throughSequence) || Number(value.throughSequence) < 0)
              throw new Error("Claude checkpoint sequence is invalid");
            current.claudeCheckpoint = {
              epoch: identifier(value.epoch),
              sequence: Number(value.throughSequence),
              turnId: identifier(value.turnId),
            };
            claudeSnapshot = value;
          } else if (value.status !== "unknown") throw new Error("Claude checkpoint status is invalid");
        } catch (error) {
          checked();
          current.error = `Live prefix unavailable: ${failure(error)}`;
        }
      }
      const liveItems = claudeSnapshot ? array(claudeSnapshot.liveItems, 200).map(entry) : checkpointItems;
      if (claudeSnapshot && !this.pageFits(pageCapture.values, liveItems))
        pageCapture = await this.readPage("desc", null, controller, liveItems);
      checked();
      const page = object(pageCapture.response);
      const entries = [...pageCapture.values].reverse();
      const existing = new Map(current.rows.map((row) => [row.entry.item.id, row]));
      current.rows = [];
      current.bytes = 0;
      current.newer = null;
      current.historyReloadRequired = false;
      this.pages = [
        {
          ids: new Set(entries.map((value) => value.item.id)),
          older: optionalString(page.nextCursor),
          newer: checkpoint || claudeSnapshot ? optionalString(page.backwardsCursor) : null,
        },
      ];
      if (liveItems.length)
        this.pages.push({
          ids: new Set(liveItems.map((value) => value.item.id)),
          older: checkpoint
            ? optionalString(checkpoint.itemsBackwardsCursor)
            : optionalString(page.backwardsCursor),
          newer: null,
        });
      this.rebuilding = true;
      for (const value of entries)
        this.upsert(value, value.isComplete !== false, existing.get(value.item.id), undefined, false);
      for (const value of liveItems)
        this.upsert(value, value.isComplete === true, undefined, undefined, true);
      const previousRows = [...existing.values()];
      for (const [index, row] of previousRows.entries()) {
        const input = row.entry.item;
        if (
          !row.delivery ||
          input.type !== "userMessage" ||
          current.rows.some(
            (candidate) =>
              candidate.entry.item.id === input.id ||
              (input.clientId &&
                candidate.entry.item.type === "userMessage" &&
                candidate.entry.item.clientId === input.clientId),
          )
        )
          continue;
        this.upsert(row.entry, true, row);
        const retained = current.rows.pop();
        if (!retained) continue;
        const before = previousRows.slice(0, index).map((value) => value.entry.item.id);
        const after = previousRows.slice(index + 1).map((value) => value.entry.item.id);
        const preceding = current.rows.findLastIndex((value) => before.includes(value.entry.item.id));
        const following = current.rows.findIndex((value) => after.includes(value.entry.item.id));
        current.rows.splice(
          preceding >= 0 ? preceding + 1 : following >= 0 ? following : current.rows.length,
          0,
          {
            ...retained,
            steer: row.steer,
            delivery: row.delivery,
            error: row.error,
          },
        );
      }
      current.older = optionalString(page.nextCursor);
      if (position === "window") {
        const first = current.rows[0]?.entry.item.id;
        const overlap = previousRows.findIndex((row) => row.entry.item.id === first);
        const pageIndex = previousPages.findIndex((page) => first && page.ids.has(first));
        const overlappingPage = previousPages[pageIndex];
        if (overlap >= 0 && overlappingPage) {
          const prefix = previousRows.slice(0, overlap);
          const identities = new Set(current.rows.map((row) => row.entry.item.id));
          current.rows = [...prefix.filter((row) => !identities.has(row.entry.item.id)), ...current.rows];
          current.bytes = current.rows.reduce((sum, row) => sum + row.bytes, 0);
          this.pages = [
            ...previousPages.slice(0, pageIndex),
            {
              ids: new Set([...overlappingPage.ids, ...identities]),
              older: overlappingPage.older,
              newer: null,
            },
          ];
          current.older = this.pages[0]?.older ?? null;
        }
      }
      this.rebuilding = false;
      this.trimRows();
      const activityCurrent = host.activityRead === activityRead;
      if (activityCurrent) this.actions.applyActivity(host, activityValue);
      if (claudeSnapshot && current.claudeCheckpoint && activityCurrent) {
        this.hosts.beginActivityRead(host);
        current.activeTurnId = current.claudeCheckpoint.turnId;
      }
      this.restoreSteers(this.actions.receipts());
      this.reconcileSteers();
      const receipt = claude
        ? { connection: pageCapture.receipt.connection, sequence: 0 }
        : checkpoint && captured
          ? captured.receipt
          : pageCapture.receipt;
      const buffered = current.observationBuffer?.events ?? [];
      current.observationBuffer = undefined;
      current.observationReceipt = receipt;
      current.status = "ready";
      this.hosts.recordThread(host, current.header);
      this.actions.reconcileReceipts(current);
      for (const notification of buffered)
        if (
          notification.receipt?.connection === receipt.connection &&
          notification.receipt.sequence > receipt.sequence
        )
          this.actions.replay(host.target, notification);
      this.publish();
      await Promise.allSettled([this.refreshQuestions(), this.refreshQueue()]);
      checked();
      return true;
    } catch (error) {
      if (controller.signal.aborted) return false;
      this.rebuilding = false;
      current.observationBuffer = undefined;
      current.status = "failed";
      current.error = failure(error);
      this.publish();
      throw error;
    }
  }
  older() {
    return this.readHistory("older");
  }
  newer() {
    return this.readHistory("newer");
  }
  private readHistory(direction: "older" | "newer"): Promise<void> {
    if (this.historyRead) return this.historyRead;
    const conversation = this.state;
    if (conversation.status !== "ready") return Promise.resolve();
    if (direction === "older" && conversation.historyReloadRequired) return this.load().then(() => undefined);
    const cursor = conversation[direction];
    if (!cursor) return Promise.resolve();
    const controller = conversation.controller;
    conversation.historyLoading = direction;
    conversation.historyError = undefined;
    this.publish();
    const read = this.fetchHistory(direction, cursor, controller)
      .catch((error) => {
        if (conversation.controller !== controller || controller.signal.aborted) return;
        conversation.historyError = failure(error);
        throw error;
      })
      .finally(() => {
        if (this.historyRead !== read) return;
        this.historyRead = undefined;
        conversation.historyLoading = undefined;
        this.publish();
      });
    this.historyRead = read;
    return read;
  }
  private async fetchHistory(direction: "older" | "newer", cursor: string, controller: AbortController) {
    const conversation = this.state;
    const { response, values } = await this.readPage(
      direction === "older" ? "desc" : "asc",
      cursor,
      controller,
      [],
    );
    if (conversation[direction] !== cursor) return;
    const next = optionalString(response.nextCursor);
    if (next === cursor) throw new Error("History cursor did not advance");
    if (!values.length) {
      conversation[direction] = next;
      const edge = direction === "older" ? this.pages[0] : this.pages.at(-1);
      if (edge) edge[direction] = next;
      if (direction === "newer" && next === null) await this.loadTail("window");
      return;
    }
    if (direction === "older") values.reverse();
    const incoming: HistoryPage = {
      ids: new Set(values.map((value) => value.item.id)),
      older: direction === "older" ? next : optionalString(response.backwardsCursor),
      newer: direction === "newer" ? next : optionalString(response.backwardsCursor),
    };
    const existingIds = new Set(conversation.rows.map((row) => row.entry.item.id));
    const freshIds = values.filter((value) => !existingIds.has(value.item.id));
    if (!freshIds.length) {
      for (const value of values) this.upsert(value, value.isComplete !== false);
      conversation[direction] = next;
      const edge = direction === "older" ? this.pages[0] : this.pages.at(-1);
      if (edge) edge[direction] = next;
      if (direction === "newer" && next === null) await this.loadTail("window");
      return;
    }
    if (direction === "older" && this.pages.at(-1)?.newer === null) {
      const tail = this.pages.at(-1);
      if (tail)
        tail.ids = new Set(
          conversation.rows
            .map((row) => row.entry.item.id)
            .filter((id) => !this.pages.slice(0, -1).some((page) => page.ids.has(id))),
        );
    }
    const previous = conversation.rows;
    this.rebuilding = true;
    if (direction === "older") {
      conversation.rows = [];
      conversation.bytes = 0;
    }
    for (const value of values)
      this.upsert(
        value,
        value.isComplete !== false,
        previous.find((row) => row.entry.item.id === value.item.id),
      );
    if (direction === "older") {
      conversation.rows.push(...previous.filter((row) => !incoming.ids.has(row.entry.item.id)));
      conversation.bytes = conversation.rows.reduce((sum, row) => sum + row.bytes, 0);
      this.pages.unshift(incoming);
    } else this.pages.push(incoming);
    this.rebuilding = false;
    conversation[direction] = next;
    this.trimRows(direction);
    this.publish();
    if (direction === "newer" && next === null) await this.loadTail("window");
  }
  private async readPage(
    direction: "asc" | "desc",
    cursor: string | null,
    controller: AbortController,
    retained: Entry[],
  ) {
    let limit = 60;
    while (true) {
      controller.signal.throwIfAborted();
      const captured = await this.host.rpc.capture(
        "thread/items/list",
        {
          threadId: this.state.address.threadId,
          sortDirection: direction,
          limit,
          ...(cursor ? { cursor } : {}),
        },
        { signal: controller.signal },
      );
      controller.signal.throwIfAborted();
      if (this.state.controller !== controller || !this.actions.present(this))
        throw new DOMException("Canceled", "AbortError");
      const response = object(captured.value);
      const values = array(response.data, 100).map(entry);
      if (this.pageFits(values, retained)) return { response, values, receipt: captured.receipt };
      if (limit === 1) throw new Error("This history item exceeds the transcript capacity.");
      limit = Math.max(1, Math.floor(limit / 2));
    }
  }
  private pageFits(values: Entry[], retained: Entry[]) {
    const bytes = new Map(values.map((value) => [value.item.id, itemSize(value.item)]));
    for (const value of retained) bytes.set(value.item.id, itemSize(value.item));
    for (const row of this.state.rows) if (this.protected(row)) bytes.set(row.entry.item.id, row.bytes);
    return [...bytes.values()].reduce((sum, value) => sum + value, 0) <= 8 * 1024 * 1024;
  }
  async refreshQueue() {
    const conversation = this.state;
    const controller = conversation.controller;
    const read = ++conversation.queueRead;
    try {
      if (conversation.header.provider === "claude") {
        const supported = await this.actions.claudeQueue(this.host.host.id);
        if (
          controller.signal.aborted ||
          conversation.controller !== controller ||
          conversation.queueRead !== read
        )
          return;
        if (supported === undefined) return;
        if (!supported) {
          conversation.queue = { status: "ready", value: { entries: [], hold: null } };
          this.publish();
          return;
        }
      }
      const result = object(
        await this.host.rpc.call(
          "thread/queue/list",
          { threadId: conversation.address.threadId, limit: 50 },
          { signal: controller.signal },
        ),
      );
      if (
        controller.signal.aborted ||
        conversation.controller !== controller ||
        conversation.queueRead !== read
      )
        return;
      const hold = result.hold === undefined || result.hold === null ? null : object(result.hold).message;
      conversation.queue = {
        status: "ready",
        value: {
          entries: array(result.data, 50) as QueuedSubmission[],
          hold: typeof hold === "string" ? hold : null,
        },
      };
    } catch (error) {
      if (
        !controller.signal.aborted &&
        conversation.controller === controller &&
        conversation.queueRead === read
      )
        conversation.queue = { status: "failed", error: failure(error) };
    }
    this.publish();
  }
  async deleteQueued(id: string) {
    const conversation = this.state;
    await this.host.rpc.call("thread/queue/delete", {
      threadId: conversation.address.threadId,
      queuedSubmissionId: id,
    });
    await this.refreshQueue();
  }
  async refreshQuestions() {
    const conversation = this.state;
    if (conversation.header.provider === "claude") {
      conversation.questionRead += 1;
      conversation.questions = {
        status: "failed",
        error: "Canonical question inventory is unavailable for Claude.",
      };
      this.publish();
      return;
    }
    const controller = conversation.controller;
    const read = ++conversation.questionRead;
    conversation.questions = { status: "loading" };
    this.publish();
    try {
      const value = await this.host.rpc.call(
        "conversation/questions/read",
        { queries: [{ threadId: conversation.address.threadId, itemIds: [] }] },
        { signal: controller.signal },
      );
      if (
        controller.signal.aborted ||
        conversation.controller !== controller ||
        conversation.questionRead !== read
      )
        return;
      const next = questions(value, conversation.address.threadId);
      conversation.questions = { status: "ready", value: next };
      this.actions.receiveQuestions(this.host, conversation.address.threadId, next);
    } catch (error) {
      if (
        !controller.signal.aborted &&
        conversation.controller === controller &&
        conversation.questionRead === read
      )
        conversation.questions = { status: "failed", error: failure(error) };
    }
    this.publish();
  }
  async dismissQuestion(record: QuestionRecord) {
    const conversation = this.state;
    if (conversation?.questions.status !== "ready") return;
    await this.host.rpc.call("conversation/question/dismiss", {
      threadId: conversation.address.threadId,
      itemId: record.itemId,
      expectedEpoch: conversation.questions.value.epoch,
      expectedRecordRevision: record.revision,
      mutationId: crypto.randomUUID(),
    });
    await this.refreshQuestions();
  }
  answerRequest(request: RequestCard, result: unknown) {
    const conversation = this.state;
    this.host.rpc.reply(request.id, result);
    conversation.requests = conversation.requests.filter((candidate) => candidate.id !== request.id);
    this.publish();
  }
  private upsert(value: Entry, complete: boolean, previous?: Row, delta?: string, livePrefix?: boolean) {
    const conversation = this.state;
    if (value.item.type === "userMessage" && value.item.clientId) {
      const clientId = value.item.clientId;
      conversation.rows = conversation.rows.filter((row) => {
        const keep =
          row.entry.item.id === value.item.id ||
          row.entry.item.type !== "userMessage" ||
          row.entry.item.clientId !== clientId;
        if (!keep) conversation.bytes -= row.bytes;
        return keep;
      });
    }
    const index = conversation.rows.findIndex((row) => row.entry.item.id === value.item.id);
    const old = index >= 0 ? conversation.rows[index] : previous;
    const revision = (old?.revision ?? 0) + 1;
    const bytes = delta !== undefined && old ? old.bytes + delta.length * 2 : itemSize(value.item);
    const row: Row = {
      steer: false,
      bytes,
      entry: value,
      revision,
      markdown: old?.markdown,
      visualPlacements: old?.visualPlacements,
      livePrefix: livePrefix ?? (!complete && old?.livePrefix === true),
    };
    conversation.bytes += bytes - (index >= 0 ? (old?.bytes ?? 0) : 0);
    if (index >= 0) conversation.rows[index] = row;
    else conversation.rows.push(row);
    if (!this.rebuilding) this.trimRows();
    const text = source(value.item);
    if (text !== undefined) {
      if (delta !== undefined)
        this.renderer?.append(renderKey(conversation.address, value.item.id), delta, revision, text);
      else this.renderer?.update(renderKey(conversation.address, value.item.id), text, revision, complete);
    }
  }
  private protected(row: Row) {
    return (
      row.delivery === "sending" ||
      row.delivery === "uncertain" ||
      (row.steer && this.actions.receipts().has(row.entry.item.id))
    );
  }
  private trimRows(direction: "older" | "newer" = "newer") {
    if (this.rebuilding) return;
    const conversation = this.state;
    while (conversation.rows.length > 240 || conversation.bytes > 8 * 1024 * 1024) {
      if (this.pages.length > 1) {
        const removed = direction === "older" ? this.pages.pop() : this.pages.shift();
        if (!removed) break;
        conversation.rows = conversation.rows.filter((row) => {
          if (
            !removed.ids.has(row.entry.item.id) ||
            this.protected(row) ||
            this.pages.some((page) => page.ids.has(row.entry.item.id))
          )
            return true;
          conversation.bytes -= row.bytes;
          this.renderer?.remove(renderKey(conversation.address, row.entry.item.id));
          return false;
        });
        conversation.older = this.pages[0]?.older ?? null;
        conversation.newer = this.pages.at(-1)?.newer ?? null;
        continue;
      }
      const index = conversation.rows.findIndex((row) => !this.protected(row));
      if (index < 0)
        throw new Error("Unconfirmed steer inputs exceed the transcript capacity. Restore one to its draft.");
      const [dropped] = conversation.rows.splice(index, 1);
      if (dropped) {
        conversation.bytes -= dropped.bytes;
        this.renderer?.remove(renderKey(conversation.address, dropped.entry.item.id));
        conversation.historyReloadRequired = true;
      }
    }
  }
  private restoreSteers(receipts: ReadonlyMap<string, SubmissionReceipt>) {
    const conversation = this.state;
    for (const [id, receipt] of receipts) {
      if (!receipt.steer || addressKey(receipt.address) !== addressKey(conversation.address)) continue;
      if (
        conversation.rows.some(
          (row) => row.entry.item.type === "userMessage" && row.entry.item.clientId === id,
        )
      )
        continue;
      const value = receipt.steer.entry;
      const row: Row = {
        steer: true,
        bytes: itemSize(value.item),
        entry: value,
        revision: 1,
        delivery: receipt.steer.acknowledged ? "admitted" : "uncertain",
      };
      const ownTurn = conversation.rows.findLastIndex((candidate) => candidate.entry.turnId === value.turnId);
      const laterTurn = conversation.rows.find(
        (candidate) =>
          candidate.entry.turnId !== value.turnId &&
          (candidate.entry.turnId === conversation.activeTurnId ||
            (candidate.entry.startedAtMs !== null &&
              value.startedAtMs !== null &&
              candidate.entry.startedAtMs > value.startedAtMs)),
      )?.entry.turnId;
      const later = laterTurn
        ? conversation.rows.findIndex((candidate) => candidate.entry.turnId === laterTurn)
        : -1;
      conversation.rows.splice(
        ownTurn >= 0 ? ownTurn + 1 : later >= 0 ? later : conversation.rows.length,
        0,
        row,
      );
      conversation.bytes += row.bytes;
      this.trimRows();
    }
  }
  private reconcileSteers() {
    const conversation = this.state;
    if (conversation.activeTurnId === undefined) return;
    const finished = new Set(
      conversation.rows
        .filter(
          (row) => row.steer && row.delivery === "admitted" && row.entry.turnId !== conversation.activeTurnId,
        )
        .map((row) => row.entry.turnId),
    );
    for (const turnId of finished) this.finishSteers(turnId);
  }
  private finishSteers(turnId: string) {
    const conversation = this.state;
    conversation.rows = conversation.rows.map((row) =>
      row.steer && row.delivery === "admitted" && row.entry.turnId === turnId
        ? { ...row, delivery: "uncertain" }
        : row,
    );
  }

  markdownReady(id: string, result: MarkdownBlocks) {
    const separator = id.indexOf("\u0000");
    const address = decodeAddress(JSON.parse(id.slice(0, separator)));
    const conversation = this.state;
    if (!sameBinding(conversation.address, address)) return;
    const index = conversation.rows.findIndex((row) => row.entry.item.id === id.slice(separator + 1));
    const row = conversation.rows[index];
    if (!row || row.revision !== result.revision) return;
    const visualPlacements =
      row.entry.isComplete === true && row.entry.item.type === "agentMessage"
        ? result.blocks.flatMap((block) =>
            [...block.matchAll(/<div class="html-visual" data-visual-digest="([0-9a-f]{64})"/g)].flatMap(
              (match) => (match[1] ? [match[1]] : []),
            ),
          )
        : [];
    conversation.rows[index] = { ...row, markdown: result, visualPlacements };
    this.publish(true);
  }
  ingest(notification: Frame) {
    if (!notification.method) return;
    const params = object(notification.params ?? {});
    const conversation = this.state;
    const host = this.host;
    if (conversation?.observationBuffer && notification.id === undefined) {
      const buffer = conversation.observationBuffer;
      buffer.bytes += JSON.stringify(notification).length * 2;
      if (buffer.bytes > 4 * 1024 * 1024 || buffer.events.length >= 8192) {
        conversation.controller.abort();
        conversation.status = "failed";
        conversation.error = "Live catch-up exceeded its buffer. Refresh this conversation.";
        conversation.observationBuffer = undefined;
        this.publish();
        return;
      }
      buffer.events.push(notification);
      return;
    }
    if (
      conversation?.observationReceipt &&
      notification.receipt &&
      (notification.receipt.connection !== conversation.observationReceipt.connection ||
        notification.receipt.sequence <= conversation.observationReceipt.sequence)
    )
      return;
    const marker = notification.rcClaudeLive;
    const prefix = conversation?.claudeCheckpoint;
    if (
      marker &&
      prefix &&
      ((marker.epoch === prefix.epoch && marker.sequence <= prefix.sequence) ||
        (marker.epoch !== prefix.epoch && params.turnId === prefix.turnId))
    )
      return;
    if (notification.id !== undefined && conversation) {
      if (conversation.requests.length >= 32) throw new Error("Too many outstanding agent requests");
      conversation.requests = [
        ...conversation.requests.filter((value) => value.id !== notification.id),
        { id: notification.id, method: notification.method, params },
      ];
      this.publish();
      return;
    }
    if (notification.method === "thread/started") {
      const record = object(params.thread);
      this.hosts.recordThread(host, conversationHeader(record, providerForThread(identifier(record.id))));
      void this.hosts.refreshAgentClassifications(host);
      this.publish();
      return;
    }
    if (["item/started", "item/completed"].includes(notification.method)) {
      const value = item(params.item);
      if (conversation.newer !== null) return;
      this.upsert(
        {
          turnId: identifier(params.turnId),
          item: value,
          startedAtMs: null,
          completedAtMs: notification.method === "item/completed" ? Date.now() : null,
          isComplete: notification.method === "item/completed",
        },
        notification.method === "item/completed",
        undefined,
        undefined,
        notification.method === "item/started",
      );
      this.actions.reconcileReceipts(conversation);
      this.publish();
    } else if (
      [
        "item/agentMessage/delta",
        "item/plan/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/commandExecution/outputDelta",
      ].includes(notification.method) &&
      typeof params.itemId === "string" &&
      typeof params.delta === "string"
    ) {
      const row = conversation.rows.find((row) => row.entry.item.id === params.itemId);
      if (!row || conversation.newer !== null) return;
      if (conversation.header.provider === "claude" && !row.livePrefix) return;
      const value = row.entry.item;
      let updated: Item = value;
      if (value.type === "agentMessage" || value.type === "plan")
        updated = { ...value, text: value.text + params.delta };
      else if (value.type === "commandExecution")
        updated = { ...value, aggregatedOutput: (value.aggregatedOutput ?? "") + params.delta };
      else if (value.type === "reasoning") {
        const field = notification.method.includes("summary") ? "summary" : "content";
        const values = [...value[field]];
        const index = Number(params.summaryIndex ?? params.contentIndex ?? 0);
        if (!Number.isInteger(index) || index < 0 || index >= 128)
          throw new Error("Reasoning segment exceeds limit");
        values[index] = (values[index] ?? "") + params.delta;
        updated = { ...value, [field]: values };
      }
      this.upsert({ ...row.entry, item: updated, isComplete: false }, false, undefined, params.delta);
      this.publish(true);
    } else if (notification.method === "turn/started") {
      this.hosts.beginActivityRead(host);
      conversation.activeTurnId = identifier(object(params.turn).id);
      this.publish();
    } else if (notification.method === "turn/completed") {
      this.hosts.beginActivityRead(host);
      const turn = object(params.turn);
      if (conversation.activeTurnId === turn.id) conversation.activeTurnId = null;
      if (turn.completedAt != null) {
        if (typeof turn.completedAt !== "number" || !Number.isSafeInteger(turn.completedAt))
          throw new Error("Invalid turn completion time");
        if (turn.completedAt > (conversation.header.lastTurnCompletedAt ?? -Infinity))
          conversation.header = { ...conversation.header, lastTurnCompletedAt: turn.completedAt };
      }
      this.finishSteers(identifier(turn.id));
      if (turn.error) conversation.error = string(object(turn.error).message);
      conversation.requests = [];
      void this.refreshQueue();
      void this.refreshQuestions();
      this.publish();
    } else if (notification.method === "thread/tokenUsage/updated") {
      conversation.usage = threadTokenUsage(params.tokenUsage);
      this.publish(true);
    } else if (notification.method === "turn/diff/updated") {
      conversation.diff = string(params.diff);
      this.publish(true);
    } else if (notification.method === "turn/plan/updated") {
      conversation.plan = array(params.plan, 128).map((value) => {
        const step = object(value);
        return { step: string(step.step), status: string(step.status) };
      });
      this.publish(true);
    } else if (notification.method === "conversation/questions/changed") {
      conversation.questions = { status: "unread" };
      void this.refreshQuestions();
    } else if (notification.method === "thread/queue/changed") void this.refreshQueue();
    else if (notification.method === "error") {
      conversation.error = string(object(params.error).message);
      this.publish();
    }
  }
  cancel() {
    this.state.controller.abort();
  }
  dispose() {
    this.state.controller.abort();
    for (const row of this.state.rows)
      this.renderer?.remove(renderKey(this.state.address, row.entry.item.id));
    if (this.state.observation)
      void this.host.rpc
        .call("thread/subscription/close", { subscriptionId: this.state.observation })
        .catch(() => undefined);
  }
}
