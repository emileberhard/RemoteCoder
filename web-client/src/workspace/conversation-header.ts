import { identifier, object, optionalString, type Provider, string } from "../protocol/boundary";
import type { Thread } from "../protocol/generated/v2/Thread";
export type ConversationAgentRelation = {
  parentThreadId: string;
  parentAccountId: string | null;
  agentId: string;
};
export type ConversationAgentClassification =
  | { kind: "unresolved" }
  | { kind: "root" }
  | { kind: "child"; relation: ConversationAgentRelation };
export type ConversationHeader = Pick<
  Thread,
  | "id"
  | "name"
  | "preview"
  | "cwd"
  | "model"
  | "reasoningEffort"
  | "status"
  | "canAcceptDirectInput"
  | "extra"
> & {
  provider: Provider;
  updatedAt: number | null;
  createdAt: number | null;
  lastTurnCompletedAt: number | null;
  recencyAt: number | null;
  nativeParentThreadId: string | null;
  spawnedAsSubAgent: boolean;
  agentClassification: ConversationAgentClassification;
};
export function conversationHeader(value: unknown, provider: Provider): ConversationHeader {
  const record = object(value);
  const status = object(record.status);
  identifier(status.type);
  const timestamp = (key: string) => {
    const value = record[key];
    if (value == null) return null;
    if (typeof value !== "number" || !Number.isSafeInteger(value))
      throw new Error("Invalid thread timestamp");
    return value;
  };
  const source =
    typeof record.source === "object" && record.source !== null ? object(record.source) : undefined;
  const subAgent =
    source && typeof source.subAgent === "object" && source.subAgent !== null
      ? object(source.subAgent)
      : undefined;
  const spawn = subAgent?.thread_spawn == null ? undefined : object(subAgent.thread_spawn);
  const relation = record.agentRelation == null ? undefined : agentRelation(record.agentRelation);
  return {
    id: identifier(record.id),
    name: optionalString(record.name),
    preview: string(record.preview ?? ""),
    cwd: string(record.cwd),
    model: optionalString(record.model),
    reasoningEffort:
      record.reasoningEffort == null
        ? null
        : (string(record.reasoningEffort) as ConversationHeader["reasoningEffort"]),
    updatedAt: timestamp("updatedAt"),
    createdAt: timestamp("createdAt"),
    lastTurnCompletedAt: timestamp("lastTurnCompletedAt"),
    recencyAt: timestamp("recencyAt"),
    status: status as ConversationHeader["status"],
    canAcceptDirectInput:
      typeof record.canAcceptDirectInput === "boolean" ? record.canAcceptDirectInput : null,
    extra: record.extra == null ? null : (object(record.extra) as ConversationHeader["extra"]),
    provider,
    nativeParentThreadId: optionalString(record.parentThreadId ?? spawn?.parent_thread_id),
    spawnedAsSubAgent: spawn !== undefined,
    agentClassification: relation ? { kind: "child", relation } : { kind: "unresolved" },
  };
}

export function agentRelation(value: unknown): ConversationAgentRelation {
  const relation = object(value);
  return {
    parentThreadId: identifier(relation.parentThreadId),
    parentAccountId: optionalString(relation.parentAccountId),
    agentId: identifier(relation.agentId),
  };
}
export function isNativeAgent(header: ConversationHeader) {
  return header.nativeParentThreadId !== null || header.spawnedAsSubAgent;
}
export function isDelegatedAgent(header: ConversationHeader) {
  return isNativeAgent(header) || header.agentClassification.kind === "child";
}
export function retainHeaderKnowledge(
  header: ConversationHeader,
  previous: ConversationHeader | undefined,
): ConversationHeader {
  if (!previous) return header;
  return {
    ...header,
    lastTurnCompletedAt:
      header.lastTurnCompletedAt === null
        ? previous.lastTurnCompletedAt
        : previous.lastTurnCompletedAt === null
          ? header.lastTurnCompletedAt
          : Math.max(header.lastTurnCompletedAt, previous.lastTurnCompletedAt),
    agentClassification:
      header.agentClassification.kind === "unresolved"
        ? previous.agentClassification
        : header.agentClassification,
    nativeParentThreadId: header.nativeParentThreadId ?? previous.nativeParentThreadId,
    spawnedAsSubAgent: header.spawnedAsSubAgent || previous.spawnedAsSubAgent,
  };
}

export function latestActivityAt(header: ConversationHeader): number | null {
  const recency = header.recencyAt ?? header.createdAt;
  const completion = header.lastTurnCompletedAt ?? header.createdAt;
  if (recency === null) return completion;
  if (completion === null) return recency;
  return Math.max(recency, completion);
}
