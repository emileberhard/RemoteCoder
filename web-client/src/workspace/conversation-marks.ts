import { object } from "../protocol/boundary";

export type ConversationPurpose = "probe" | "automation";
export type ConversationSettlement = { state: "settled" | "active"; through: number };
export type ThreadMarks = {
  revision: number;
  seenThrough?: number;
  markedUnread: boolean;
  pinName?: string;
  purpose?: ConversationPurpose;
  settlement?: ConversationSettlement;
  doneThrough?: number;
};
export type ConversationMarks = {
  schemaVersion: number;
  revision: number;
  readBaseline: number;
  threads: Readonly<Record<string, ThreadMarks>>;
  supportsRetiredScopeRead?: boolean;
};
export type MarkedConversation = {
  id: string;
  latestActivityAt: number | null;
  lastTurnCompletedAt: number | null;
};
export type ConversationMarkChange =
  | { op: "markRead" | "settle" | "unsettle"; threadId: string; through: number }
  | { op: "markUnread" | "unpin"; threadId: string }
  | { op: "pin"; threadId: string; name: string }
  | { op: "setPurpose"; threadId: string; purpose: ConversationPurpose }
  | { op: "markAllRead"; through: number }
  | { op: "markRetiredScopeRead"; scopeId: string; through: number };
export const automaticSettlementAfter = 3 * 86400;
const bytes = (text: string) => new TextEncoder().encode(text).length;
function integer(value: unknown, name: string, minimum = Number.MIN_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum)
    throw new Error(`Invalid marks ${name}`);
  return value;
}
function text(value: unknown, maximum: number): string {
  if (typeof value !== "string" || !value || value.trim() !== value || bytes(value) > maximum)
    throw new Error("Invalid marks identifier or pin name");
  return value;
}
function purpose(value: unknown): ConversationPurpose {
  if (value !== "probe" && value !== "automation") throw new Error("Invalid conversation purpose");
  return value;
}
export function normalizedPinName(value: string): string | undefined {
  let name = "";
  for (const { segment } of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
    value.trim(),
  )) {
    if (bytes(name + segment) > 256) break;
    name += segment;
  }
  return name.trim() || undefined;
}
export function decodeMarkChange(value: unknown): ConversationMarkChange {
  const entry = object(value);
  if (entry.op === "markAllRead") return { op: entry.op, through: integer(entry.through, "through") };
  if (entry.op === "markRetiredScopeRead") {
    const scopeId = text(entry.scopeId, 36);
    if (scopeId !== "default" && !/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/.test(scopeId))
      throw new Error("Invalid retired marks scope");
    return { op: entry.op, scopeId, through: integer(entry.through, "through") };
  }
  const threadId = text(entry.threadId, 512);
  switch (entry.op) {
    case "markRead":
    case "settle":
    case "unsettle":
      return { op: entry.op, threadId, through: integer(entry.through, "through") };
    case "markUnread":
    case "unpin":
      return { op: entry.op, threadId };
    case "pin":
      return { op: entry.op, threadId, name: text(entry.name, 256) };
    case "setPurpose":
      return { op: entry.op, threadId, purpose: purpose(entry.purpose) };
    default:
      throw new Error("Invalid conversation mark operation");
  }
}
export function decodeConversationMarks(value: unknown): ConversationMarks {
  const entry = object(value);
  const revision = integer(entry.revision, "revision", 0);
  const threads: Record<string, ThreadMarks> = Object.create(null);
  for (const [id, value] of Object.entries(object(entry.threads))) {
    text(id, 512);
    const row = object(value);
    const marks: ThreadMarks = { revision: integer(row.revision, "thread revision", 0), markedUnread: false };
    if (marks.revision > revision) throw new Error("Thread marks revision exceeds snapshot revision");
    if (row.markedUnread != null) {
      if (typeof row.markedUnread !== "boolean") throw new Error("Invalid unread mark");
      marks.markedUnread = row.markedUnread;
    }
    if (row.seenThrough != null) marks.seenThrough = integer(row.seenThrough, "seenThrough");
    if (row.doneThrough != null) marks.doneThrough = integer(row.doneThrough, "doneThrough");
    if (row.pinName != null) marks.pinName = text(row.pinName, 256);
    if (row.purpose != null) marks.purpose = purpose(row.purpose);
    if (row.settlement != null) {
      const settlement = object(row.settlement);
      if (settlement.state !== "active" && settlement.state !== "settled")
        throw new Error("Invalid settlement");
      marks.settlement = {
        state: settlement.state,
        through: integer(settlement.through, "settlement through"),
      };
    }
    threads[id] = marks;
  }
  if (entry.supportsRetiredScopeRead != null && typeof entry.supportsRetiredScopeRead !== "boolean")
    throw new Error("Invalid retired scope support");
  return {
    schemaVersion: integer(entry.schemaVersion ?? 1, "schemaVersion", 1),
    revision,
    readBaseline: integer(entry.readBaseline, "readBaseline"),
    threads,
    ...(entry.supportsRetiredScopeRead == null
      ? {}
      : { supportsRetiredScopeRead: entry.supportsRetiredScopeRead as boolean }),
  };
}
export function mergeMarks(base: ConversationMarks, delta: ConversationMarks): ConversationMarks {
  const threads = { ...base.threads };
  const readBaseline = Math.max(base.readBaseline, delta.readBaseline);
  for (const [id, incoming] of Object.entries(delta.threads))
    if (incoming.revision >= (threads[id]?.revision ?? 0)) threads[id] = incoming;
  for (const [id, marks] of Object.entries(threads))
    if (marks.seenThrough !== undefined && marks.seenThrough <= readBaseline)
      threads[id] = { ...marks, seenThrough: undefined };
  return {
    ...base,
    schemaVersion: Math.max(base.schemaVersion, delta.schemaVersion),
    revision: Math.max(base.revision, delta.revision),
    readBaseline,
    threads,
  };
}
export function applyMarkChange(base: ConversationMarks, change: ConversationMarkChange): ConversationMarks {
  if (change.op === "markRetiredScopeRead") return base;
  const threads = { ...base.threads };
  if (change.op === "markAllRead") {
    const readBaseline = Math.max(base.readBaseline, change.through);
    for (const [id, marks] of Object.entries(threads))
      threads[id] = {
        ...marks,
        markedUnread: false,
        seenThrough:
          marks.seenThrough !== undefined && marks.seenThrough > readBaseline ? marks.seenThrough : undefined,
      };
    return { ...base, readBaseline, threads };
  }
  const marks = { ...(threads[change.threadId] ?? { revision: 0, markedUnread: false }) };
  switch (change.op) {
    case "settle":
    case "markRead":
      if (change.op === "settle") {
        marks.pinName = undefined;
        marks.settlement = { state: "settled", through: change.through };
      }
      marks.markedUnread = false;
      marks.seenThrough = Math.max(marks.seenThrough ?? -Infinity, change.through);
      break;
    case "markUnread":
      marks.markedUnread = true;
      break;
    case "pin":
      marks.pinName = normalizedPinName(change.name);
      break;
    case "unpin":
      marks.pinName = undefined;
      break;
    case "setPurpose":
      marks.purpose = change.purpose;
      break;
    case "unsettle":
      marks.settlement = { state: "active", through: change.through };
      marks.doneThrough = undefined;
      break;
  }
  if (marks.seenThrough !== undefined && marks.seenThrough <= base.readBaseline)
    marks.seenThrough = undefined;
  threads[change.threadId] = marks;
  return { ...base, threads };
}
export function isUnread(marks: ConversationMarks, thread: MarkedConversation): boolean {
  const row = marks.threads[thread.id];
  return (
    row?.markedUnread === true ||
    (!row?.purpose &&
      thread.lastTurnCompletedAt !== null &&
      thread.lastTurnCompletedAt > Math.max(marks.readBaseline, row?.seenThrough ?? -Infinity))
  );
}
export function isUnseenQuestion(marks: ConversationMarks, askedAtMs: number, threadId: string): boolean {
  return (
    Math.trunc(askedAtMs / 1000) >
    Math.max(marks.readBaseline, marks.threads[threadId]?.seenThrough ?? -Infinity)
  );
}
export function isProbablyDone(marks: ConversationMarks, thread: MarkedConversation): boolean {
  const row = marks.threads[thread.id];
  return (
    !row?.purpose &&
    !row?.pinName &&
    row?.doneThrough !== undefined &&
    thread.latestActivityAt !== null &&
    thread.latestActivityAt <= row.doneThrough
  );
}
export function coversRequest(
  marks: ConversationMarks,
  requestAt: number | null,
  thread: MarkedConversation,
  now: number,
): boolean {
  if (marks.schemaVersion < 2) return false;
  const settlement = marks.threads[thread.id]?.settlement;
  const automaticThrough = now - automaticSettlementAfter;
  if (settlement?.state === "settled")
    return requestAt === null
      ? thread.latestActivityAt !== null && thread.latestActivityAt <= settlement.through
      : requestAt <= Math.max(settlement.through, automaticThrough);
  if (
    settlement?.state === "active" &&
    thread.latestActivityAt !== null &&
    thread.latestActivityAt <= settlement.through
  )
    return false;
  return requestAt !== null && requestAt <= automaticThrough;
}
export function isSettled(
  marks: ConversationMarks,
  thread: MarkedConversation,
  isLive: boolean,
  now: number,
): boolean {
  if (marks.schemaVersion < 2 || isLive) return false;
  const row = marks.threads[thread.id];
  if (row?.pinName || isUnread(marks, thread)) return false;
  if (
    row?.settlement?.state === "settled" &&
    (row.purpose || (thread.latestActivityAt !== null && thread.latestActivityAt <= row.settlement.through))
  )
    return true;
  if (
    row?.settlement?.state === "active" &&
    thread.latestActivityAt !== null &&
    thread.latestActivityAt <= row.settlement.through
  )
    return false;
  return thread.latestActivityAt !== null && thread.latestActivityAt <= now - automaticSettlementAfter;
}
