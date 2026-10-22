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
  activeTurnId: string | null | undefined;
  questions: Load<Questions>;
  queue: Load<QueuedSubmission[]>;
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

export class ConversationSession {
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
  removeQueuedSubmission(id: string) {
    this.state.rows = this.state.rows.filter((row) => row.entry.item.id !== id);
  }
  removeRestoredSteer(row: Row) {
    this.state.rows = this.state.rows.filter((candidate) => candidate !== row);
    this.state.bytes -= row.bytes;
    this.renderer?.remove(renderKey(this.state.address, row.entry.item.id));
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
  async load() {
    const current = this.state;
    const nameRevision = this.nameRevision;
    const host = this.host;
    const address = current.address;
    current.controller.abort();
    current.controller = new AbortController();
    current.status = "loading";
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
      const activityRead = this.hosts.beginActivityRead(host);
      const [pageCapture, activityValue] = await Promise.all([
        checkpoint && captured && checkpoint.itemsBackwardsCursor == null
          ? Promise.resolve({ value: { data: [], nextCursor: null }, receipt: captured.receipt })
          : host.rpc.capture(
              "thread/items/list",
              {
                threadId: address.threadId,
                sortDirection: "desc",
                limit: 60,
                ...(checkpoint ? { cursor: checkpoint.itemsBackwardsCursor } : {}),
              },
              { signal: controller.signal },
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
      const page = object(pageCapture.value);
      const entries = array(page.data, 100).map(entry).reverse();
      const existing = new Map(current.rows.map((row) => [row.entry.item.id, row]));
      current.rows = [];
      current.bytes = 0;
      for (const value of entries)
        this.upsert(value, value.isComplete !== false, existing.get(value.item.id), undefined, false);
      if (checkpoint)
        for (const value of array(checkpoint.liveItems, 200).map(entry))
          this.upsert(value, value.isComplete === true, undefined, undefined, true);
      if (claudeSnapshot)
        for (const value of array(claudeSnapshot.liveItems, 200).map(entry))
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
    } catch (error) {
      if (controller.signal.aborted) return;
      current.observationBuffer = undefined;
      current.status = "failed";
      current.error = failure(error);
      this.publish();
      throw error;
    }
  }
  async older() {
    const conversation = this.state;
    if (!conversation?.older) return;
    const cursor = conversation.older;
    const controller = conversation.controller;
    const response = object(
      await this.host.rpc.call(
        "thread/items/list",
        { threadId: conversation.address.threadId, sortDirection: "desc", limit: 60, cursor },
        { signal: controller.signal },
      ),
    );
    if (conversation.controller !== controller || controller.signal.aborted || conversation.older !== cursor)
      return;
    const previous = conversation.rows;
    conversation.rows = [];
    conversation.bytes = 0;
    for (const value of array(response.data, 100).map(entry).reverse())
      this.upsert(value, value.isComplete !== false);
    const identities = new Set(conversation.rows.map((row) => row.entry.item.id));
    conversation.rows.push(...previous.filter((row) => !identities.has(row.entry.item.id)));
    conversation.bytes = conversation.rows.reduce((total, row) => total + row.bytes, 0);
    while (conversation.rows.length > 240 || conversation.bytes > 8 * 1024 * 1024) {
      let drop = conversation.rows.findLastIndex(
        (row) =>
          row.entry.turnId !== conversation.activeTurnId &&
          row.delivery !== "sending" &&
          row.delivery !== "uncertain",
      );
      if (drop < 0) {
        drop = 0;
        conversation.error =
          "The active transcript exceeded its retained window. Some earlier output is available in stored history.";
      }
      const [removed] = conversation.rows.splice(drop, 1);
      if (removed) {
        conversation.bytes -= removed.bytes;
        this.renderer?.remove(renderKey(conversation.address, removed.entry.item.id));
      }
    }
    const next = optionalString(response.nextCursor);
    if (next === cursor) throw new Error("History cursor did not advance");
    conversation.older = next;
    this.publish();
  }
  async refreshQueue() {
    const conversation = this.state;
    if (conversation.header.provider === "claude") {
      conversation.queueRead += 1;
      conversation.queue = { status: "failed", error: "Queued submissions are unavailable for Claude." };
      this.publish();
      return;
    }
    const controller = conversation.controller;
    const read = ++conversation.queueRead;
    try {
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
      conversation.queue = { status: "ready", value: array(result.data, 50) as QueuedSubmission[] };
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
    this.trimRows();
    const text = source(value.item);
    if (text !== undefined) {
      if (delta !== undefined)
        this.renderer?.append(renderKey(conversation.address, value.item.id), delta, revision, text);
      else this.renderer?.update(renderKey(conversation.address, value.item.id), text, revision, complete);
    }
  }
  private trimRows() {
    const conversation = this.state;
    while (conversation.rows.length > 240 || conversation.bytes > 8 * 1024 * 1024) {
      const index = conversation.rows.findIndex(
        (row) => !row.steer || !this.actions.receipts().has(row.entry.item.id),
      );
      if (index < 0)
        throw new Error("Unconfirmed steer inputs exceed the transcript capacity. Restore one to its draft.");
      const [dropped] = conversation.rows.splice(index, 1);
      if (dropped) {
        conversation.bytes -= dropped.bytes;
        this.renderer?.remove(renderKey(conversation.address, dropped.entry.item.id));
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
      if (!row) return;
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
