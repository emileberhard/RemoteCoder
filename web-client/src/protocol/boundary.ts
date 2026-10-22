import { type ConversationAddress, conversationKey } from "../execution-context";
import { providerForThread } from "./agent-provider";
import type { Model } from "./generated/v2/Model";
import type { ThreadItem } from "./generated/v2/ThreadItem";
import type { ThreadItemEntry } from "./generated/v2/ThreadItemEntry";

export type Provider = "codex" | "claude";
export type Address = ConversationAddress;
export const addressKey = conversationKey;
export function codexDesktopLink(address: Address): string | undefined {
  return providerForThread(address.threadId) === "codex" ? `codex://threads/${address.threadId}` : undefined;
}
export type Host = {
  id: string;
  name: string;
  url: string;
  cwd: string;
  credentialStatus: "notChecked" | "ready" | "unavailable";
};
export type UnknownItem = { type: "unknown"; id: string; wireType: string; payload: Record<string, unknown> };
export type VisualPublication = { digest: string; title: string };
export type Item = (ThreadItem & { rcVisual?: VisualPublication }) | UnknownItem;
export type Entry = Omit<ThreadItemEntry, "item"> & { item: Item };
export type QuestionSlot = {
  index: number;
  title: string;
  options: string[];
  resolution: "pending" | "answered" | "dismissed" | "superseded";
  answer: { text: string } | null;
};
export type QuestionRecord = {
  askedAtMs?: number | null;
  itemId: string;
  turnId: string;
  revision: number;
  questions: QuestionSlot[];
};
export type Questions = {
  threadId: string;
  epoch: string;
  revision: number;
  coverage: "ready" | "catchingUp" | "unavailable";
  reason?: string;
  records: QuestionRecord[];
  pendingItemIds: string[] | null;
};
export type Receipt = { connection: number; sequence: number };
export type Frame = {
  receipt?: Receipt;
  rcClaudeLive?: { epoch: string; sequence: number };
  id?: string | number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
};

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Gateway sent an invalid object");
  return value as Record<string, unknown>;
}
export function string(value: unknown, name = "value"): string {
  if (typeof value !== "string" || value.length > 8 * 1024 * 1024)
    throw new Error(`Gateway sent an invalid ${name}`);
  return value;
}
export function identifier(value: unknown): string {
  const id = string(value, "identity");
  if (!id || id.length > 4096) throw new Error("Gateway identity is missing or too large");
  return id;
}
export function array(value: unknown, limit = 500): unknown[] {
  if (!Array.isArray(value) || value.length > limit)
    throw new Error("Gateway collection exceeds the supported limit");
  return value;
}
export function optionalString(value: unknown): string | null {
  return value == null ? null : string(value);
}
export function frame(value: unknown): Frame {
  const result = object(value);
  if (result.id !== undefined && typeof result.id !== "string" && typeof result.id !== "number")
    throw new Error("Invalid RPC identity");
  if (result.method !== undefined) identifier(result.method);
  if (result.rcClaudeLive !== undefined) {
    const marker = object(result.rcClaudeLive);
    identifier(marker.epoch);
    if (!Number.isSafeInteger(marker.sequence) || Number(marker.sequence) < 0)
      throw new Error("Invalid Claude live sequence");
  }
  if (result.error !== undefined) {
    const error = object(result.error);
    string(error.message);
    if (typeof error.code !== "number") throw new Error("Invalid RPC error");
  }
  return result as Frame;
}
const known = new Set([
  "userMessage",
  "hookPrompt",
  "agentMessage",
  "functionCallOutput",
  "plan",
  "reasoning",
  "commandExecution",
  "fileChange",
  "mcpToolCall",
  "dynamicToolCall",
  "collabAgentToolCall",
  "subAgentActivity",
  "webSearch",
  "imageView",
  "sleep",
  "imageGeneration",
  "enteredReviewMode",
  "exitedReviewMode",
  "contextCompaction",
]);
export function item(value: unknown): Item {
  const record = object(value);
  const id = identifier(record.id);
  const type = identifier(record.type);
  if (!known.has(type)) return { type: "unknown", id, wireType: type, payload: record };
  if (["agentMessage", "plan"].includes(type)) string(record.text);
  if (type === "userMessage")
    for (const entry of array(record.content, 128)) {
      const input = object(entry);
      identifier(input.type);
      if (input.type === "text") string(input.text);
    }
  if (type === "reasoning") {
    for (const text of array(record.summary, 128)) string(text);
    for (const text of array(record.content, 128)) string(text);
  }
  if (type === "commandExecution") {
    string(record.command);
    string(record.cwd);
    identifier(record.status);
    if (record.aggregatedOutput != null) string(record.aggregatedOutput);
  }
  if (type === "fileChange")
    for (const change of array(record.changes, 128)) {
      const file = object(change);
      string(file.path);
      string(file.diff ?? "");
    }
  if (["mcpToolCall", "dynamicToolCall"].includes(type)) {
    identifier(record.tool);
    identifier(record.status);
    if (record.rcVisual != null) {
      const visual = object(record.rcVisual);
      if (!/^[0-9a-f]{64}$/.test(string(visual.digest))) throw new Error("Invalid visual digest");
      string(visual.title);
    }
  }
  return record as Item;
}

export function publishedVisual(item: Item): VisualPublication | undefined {
  if (item.type === "mcpToolCall" || item.type === "dynamicToolCall") return item.rcVisual;
  return undefined;
}
export function entry(value: unknown): Entry {
  const record = object(value);
  return {
    turnId: identifier(record.turnId),
    item: item(record.item),
    startedAtMs: typeof record.startedAtMs === "number" ? record.startedAtMs : null,
    completedAtMs: typeof record.completedAtMs === "number" ? record.completedAtMs : null,
    isComplete: typeof record.isComplete === "boolean" ? record.isComplete : undefined,
    startedAtOrdinal: typeof record.startedAtOrdinal === "number" ? record.startedAtOrdinal : undefined,
  };
}
export function models(value: unknown): Model[] {
  return array(object(value).data, 200).map((value) => {
    const record = object(value);
    identifier(record.id);
    identifier(record.model);
    string(record.displayName);
    array(record.supportedReasoningEfforts, 16);
    return record as Model;
  });
}
export function questions(value: unknown, threadId: string): Questions {
  const record = object(
    array(object(value).threads, 16).find((value) => object(value).threadId === threadId),
  );
  if (!["ready", "catchingUp", "unavailable"].includes(String(record.coverage)))
    throw new Error("Invalid question coverage");
  if (record.coverage === "ready" && (!record.epoch || !Array.isArray(record.pendingItemIds)))
    throw new Error("Question coverage is incomplete");
  const records = array(record.records, 256).map((value) => {
    const candidate = object(value);
    identifier(candidate.itemId);
    if (
      candidate.askedAtMs != null &&
      (typeof candidate.askedAtMs !== "number" || !Number.isSafeInteger(candidate.askedAtMs))
    )
      throw new Error("Invalid question timestamp");
    identifier(candidate.turnId);
    if (typeof candidate.revision !== "number") throw new Error("Invalid question revision");
    array(candidate.questions, 128).forEach((slot, index) => {
      const question = object(slot);
      if (
        question.index !== index ||
        !["pending", "answered", "dismissed", "superseded"].includes(String(question.resolution))
      )
        throw new Error("Invalid question slot");
      identifier(question.title);
      for (const option of array(question.options, 128)) string(option);
      if (question.resolution === "answered") string(object(question.answer).text);
    });
    return candidate as QuestionRecord;
  });
  if (new Set(records.map((value) => value.itemId)).size !== records.length)
    throw new Error("Duplicate question record");
  return { ...record, records } as Questions;
}
export function questionEnvelope(record: QuestionRecord, answers: Record<number, string>) {
  const slots = record.questions.filter(
    (question) => question.resolution === "pending" && answers[question.index]?.trim(),
  );
  if (!slots.length) throw new Error("Choose or write an answer first");
  return `<send_user_message_question_reply>\n${JSON.stringify(slots.map((question) => ({ questionItemId: JSON.stringify(["request_user_input_async", record.itemId, question.index]), question: question.title, answer: answers[question.index] })))}\n</send_user_message_question_reply>`;
}
