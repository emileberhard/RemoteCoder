import { type ExecutionTarget, executionTarget, targetKey } from "../execution-context";
import type { Rpc } from "../gateway";
import { object } from "../protocol/boundary";
import {
  applyMarkChange,
  type ConversationMarkChange,
  type ConversationMarks,
  decodeConversationMarks,
  decodeMarkChange,
  mergeMarks,
  type ThreadMarks,
} from "./conversation-marks";

type Pending = { id: string; change: ConversationMarkChange };
type Replica = { acknowledged?: ConversationMarks; pending: Pending[] };
const pendingLimit = 2000;
const batchLimit = 500;
const storageLimit = 8 * 1024 * 1024;
const threadValues = (marks: ThreadMarks | undefined) =>
  JSON.stringify([
    marks?.seenThrough,
    marks?.markedUnread ?? false,
    marks?.pinName,
    marks?.purpose,
    marks?.settlement?.state,
    marks?.settlement?.through,
    marks?.doneThrough,
  ]);

export class ConversationMarksStore {
  readonly target: ExecutionTarget;
  private readonly key: string;
  private replica: Replica = { pending: [] };
  private projectedReplica?: Replica;
  private projected?: ConversationMarks;
  private controller = new AbortController();
  private running?: Promise<void>;
  private readRequested = false;
  private receivedDuringRead?: ConversationMarks;
  private reading = false;
  private unavailable = false;
  private state: "unread" | "loading" | "ready" | "failed" = "unread";
  private failure?: string;
  private recoveryWarning?: string;

  constructor(
    target: ExecutionTarget,
    private readonly rpc: Rpc,
    private readonly storage: Storage | undefined,
    private readonly publish: () => void,
  ) {
    this.target = executionTarget(target.hostId, target.enrollment);
    this.key = `remotecoder.web.marks.v1:${targetKey(this.target)}`;
    let raw: string | null | undefined;
    try {
      raw = storage?.getItem(this.key);
      if (raw !== null && raw !== undefined) {
        if (raw.length > storageLimit) throw new Error("Saved conversation marks exceed the storage limit");
        const saved = object(JSON.parse(raw));
        if (!Array.isArray(saved.pending) || saved.pending.length > pendingLimit)
          throw new Error("Invalid saved pending conversation marks");
        const seen = new Set<string>();
        const pending = saved.pending.map((value: unknown): Pending => {
          const entry = object(value);
          if (typeof entry.id !== "string" || !entry.id || entry.id.length > 128 || seen.has(entry.id))
            throw new Error("Invalid saved conversation mark identity");
          seen.add(entry.id);
          return { id: entry.id, change: decodeMarkChange(entry.change) };
        });
        this.replica = {
          acknowledged: saved.acknowledged == null ? undefined : decodeConversationMarks(saved.acknowledged),
          pending,
        };
      }
    } catch (error) {
      if (raw != null && raw.length <= storageLimit) {
        try {
          storage?.setItem(`${this.key}.quarantine`, raw);
          storage?.removeItem(this.key);
          this.recoveryWarning =
            "Saved conversation marks could not be decoded and were set aside. Fresh marks will be read from the host.";
        } catch (recoveryError) {
          this.unavailable = true;
          this.fail(recoveryError);
        }
      } else {
        this.unavailable = true;
        this.fail(error);
      }
    }
  }
  get restoreWarning() {
    return this.recoveryWarning;
  }
  get marks(): ConversationMarks | undefined {
    if (this.projectedReplica !== this.replica) {
      const base = this.replica.acknowledged;
      this.projected = base
        ? this.replica.pending.reduce((marks, entry) => applyMarkChange(marks, entry.change), base)
        : undefined;
      this.projectedReplica = this.replica;
    }
    return this.projected;
  }
  get isReadStateKnown() {
    return this.replica.acknowledged !== undefined;
  }
  get pendingCount() {
    return this.replica.pending.length;
  }
  get status() {
    return this.state;
  }
  get error() {
    return this.failure;
  }

  recordChanges(changes: readonly ConversationMarkChange[]): void {
    this.requireActive();
    if (this.unavailable)
      throw new Error("Saved conversation marks are unavailable; pending changes were retained on disk");
    let effective = this.marks;
    const validated = changes.map(decodeMarkChange).filter((change) => {
      if (!effective) return true;
      const next = applyMarkChange(effective, change);
      const unchanged =
        effective.readBaseline === next.readBaseline &&
        ("threadId" in change
          ? threadValues(effective.threads[change.threadId]) === threadValues(next.threads[change.threadId])
          : Object.keys(effective.threads).every(
              (id) => threadValues(effective?.threads[id]) === threadValues(next.threads[id]),
            ));
      effective = next;
      return !unchanged;
    });
    if (!validated.length) return;
    if (
      validated.some((change) => change.op === "settle" || change.op === "unsettle") &&
      (this.replica.acknowledged?.schemaVersion ?? 0) < 2
    )
      throw new Error("Settlement is unavailable until a compatible marks snapshot is read");
    if (this.replica.pending.length + validated.length > pendingLimit)
      throw new Error(
        "Two thousand conversation changes await synchronization; sync them before adding more",
      );
    const next = {
      ...this.replica,
      pending: [...this.replica.pending, ...validated.map((change) => ({ id: crypto.randomUUID(), change }))],
    };
    try {
      this.commit(next);
    } catch (error) {
      this.fail(error);
      this.publish();
      throw error;
    }
    this.publish();
    void this.start();
  }
  sync(): Promise<void> {
    this.requireActive();
    this.readRequested = true;
    return this.start();
  }
  receive(value: unknown): void {
    if (this.controller.signal.aborted) return;
    try {
      const delta = decodeConversationMarks(value);
      if (this.reading)
        this.receivedDuringRead = this.receivedDuringRead
          ? mergeMarks(this.receivedDuringRead, delta)
          : delta;
      if (this.replica.acknowledged && !this.unavailable)
        this.commit({ ...this.replica, acknowledged: mergeMarks(this.replica.acknowledged, delta) });
    } catch (error) {
      this.fail(error);
    }
    this.publish();
  }
  dispose(): void {
    this.controller.abort();
    this.readRequested = false;
    this.receivedDuringRead = undefined;
  }
  private requireActive() {
    if (this.controller.signal.aborted) throw new Error("The conversation marks context was retired");
  }
  private commit(next: Replica) {
    if (next.acknowledged && next.acknowledged.schemaVersion < 2)
      next = {
        ...next,
        pending: next.pending.filter(({ change }) => change.op !== "settle" && change.op !== "unsettle"),
      };
    const serialized = JSON.stringify(next);
    if (serialized.length > storageLimit)
      throw new Error("Conversation marks exceed the browser storage limit");
    this.storage?.setItem(this.key, serialized);
    this.replica = next;
  }
  private fail(error: unknown) {
    this.state = "failed";
    this.failure = error instanceof Error ? error.message : String(error);
  }
  private start(): Promise<void> {
    if (this.running) return this.running;
    this.running = Promise.resolve().then(() => this.synchronize());
    return this.running;
  }
  private async synchronize(): Promise<void> {
    try {
      if (this.unavailable || this.controller.signal.aborted) return;
      do {
        if (this.readRequested || !this.replica.acknowledged) {
          this.readRequested = false;
          this.state = "loading";
          this.reading = true;
          this.receivedDuringRead = undefined;
          this.publish();
          try {
            const snapshot = decodeConversationMarks(
              await this.rpc.call("conversation/marks/read", {}, { signal: this.controller.signal }),
            );
            if (this.controller.signal.aborted) return;
            const acknowledged = this.receivedDuringRead
              ? mergeMarks(snapshot, this.receivedDuringRead)
              : snapshot;
            this.commit({ ...this.replica, acknowledged });
          } finally {
            this.reading = false;
            this.receivedDuringRead = undefined;
          }
        }
        while (this.replica.pending.length && !this.controller.signal.aborted) {
          const batch = this.replica.pending.slice(0, batchLimit);
          const response = object(
            await this.rpc.call(
              "conversation/marks/update",
              { changes: batch.map(({ change }) => change) },
              { signal: this.controller.signal },
            ),
          );
          if (this.controller.signal.aborted) return;
          if (!("delta" in response)) throw new Error("Missing conversation marks acknowledgment");
          const delta = response.delta === null ? undefined : decodeConversationMarks(response.delta);
          const ids = new Set(batch.map(({ id }) => id));
          const acknowledged =
            delta && this.replica.acknowledged
              ? mergeMarks(this.replica.acknowledged, delta)
              : this.replica.acknowledged;
          this.commit({ acknowledged, pending: this.replica.pending.filter(({ id }) => !ids.has(id)) });
        }
      } while (this.readRequested && !this.controller.signal.aborted);
      if (!this.controller.signal.aborted) {
        this.state = "ready";
        this.failure = undefined;
        this.publish();
      }
    } catch (error) {
      if (!this.controller.signal.aborted) {
        this.fail(error);
        this.publish();
      }
    } finally {
      this.running = undefined;
      if (
        !this.controller.signal.aborted &&
        !this.unavailable &&
        this.state === "ready" &&
        (this.readRequested || this.replica.pending.length)
      )
        await this.start();
    }
  }
}
