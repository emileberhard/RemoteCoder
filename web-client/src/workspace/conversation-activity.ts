import { providerForThread } from "../protocol/agent-provider";
import { array, identifier, object } from "../protocol/boundary";
import type { ConversationHeader } from "./conversation-header";
export type ConversationActivityState = "working" | "waiting" | "idle" | "unknown";

export type ConversationActivity = Readonly<{
  states: ReadonlyMap<string, ConversationActivityState>;
  waitingSince: ReadonlyMap<string, number>;
}>;
export function conversationActivity(
  value: unknown,
  threads: readonly ConversationHeader[],
): ConversationActivity {
  const snapshot = object(value);
  const coverage = object(snapshot.coverage);
  const external = snapshot.externalActivity == null ? undefined : object(snapshot.externalActivity);
  const active = new Set(
    array(snapshot.activeTurns, 1000).map((entry) => identifier(object(entry).threadId)),
  );
  const sessions = new Map<string, ConversationActivityState>();
  const times = new Map<string, number>();
  if (external)
    for (const value of array(external.sessions, 4000)) {
      const session = object(value);
      const id = identifier(session.threadId);
      if (!["working", "waiting", "idle", "unknown"].includes(String(session.state)))
        throw new Error("Invalid conversation activity");
      if (!sessions.has(id)) sessions.set(id, session.state as ConversationActivityState);
      if (session.waitingSince != null) {
        if (typeof session.waitingSince !== "number" || !Number.isSafeInteger(session.waitingSince))
          throw new Error("Invalid waiting timestamp");
        times.set(id, Math.max(times.get(id) ?? -Infinity, session.waitingSince));
      }
    }
  const available = (id: string) =>
    providerForThread(id) === "claude"
      ? external?.claudeAvailable === true
      : external?.codexAvailable === true && coverage.codex === true;
  const state = (id: string): ConversationActivityState =>
    active.has(id) ? "working" : available(id) ? (sessions.get(id) ?? "idle") : "unknown";
  const owners = snapshot.agentOwners == null ? {} : object(snapshot.agentOwners);
  const ownerStates = new Map<string, ConversationActivityState>();
  for (const [child, raw] of Object.entries(owners)) {
    const owner = identifier(raw);
    const childState = state(child);
    if (childState === "working" || childState === "waiting") ownerStates.set(owner, "working");
    else if (childState === "unknown" && !ownerStates.has(owner)) ownerStates.set(owner, "unknown");
  }
  const states = new Map<string, ConversationActivityState>();
  const waitingSince = new Map<string, number>();
  for (const thread of threads) {
    const own = state(thread.id);
    const parent = ownerStates.get(thread.id);
    states.set(
      thread.id,
      parent === "working" ? "working" : parent === "unknown" && own === "idle" ? "unknown" : own,
    );
    const since = times.get(thread.id);
    if (since !== undefined && available(thread.id) && states.get(thread.id) === "waiting")
      waitingSince.set(thread.id, since);
  }
  return { states, waitingSince };
}
