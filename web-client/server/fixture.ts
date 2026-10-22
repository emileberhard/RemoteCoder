import { newerPreference, type PreferenceEntry, preferenceEntry } from "../src/preferences";
import { type Frame, object, string } from "../src/protocol/boundary";
import claudeCatalog from "../src/protocol/claude-models.json";
import type { PublicHost } from "./config";

export const fixtureHosts: PublicHost[] = [
  {
    id: "fixture-mini",
    name: "Mac mini · fixture",
    url: "http://127.0.0.1",
    cwd: "/Users/developer/RemoteCoder",
    credentialStatus: "ready",
  },
  {
    id: "fixture-macbook",
    name: "MacBook Pro · fixture",
    url: "http://127.0.0.1",
    cwd: "/Users/developer/Projects",
    credentialStatus: "ready",
  },
];
const emitters = new Map<string, Set<(frame: unknown) => void>>();
const databases = new Map<string, Map<string, Record<string, unknown>>>();
const preferences = new Map<string, Map<string, PreferenceEntry>>();
const epoch = "fixture-epoch-20261013";
const agent = (id: string, text: string, phase = "final_answer") => ({
  type: "agentMessage",
  id,
  text,
  phase,
  delivery: null,
  questions: null,
});
const user = (id: string, text: string, clientId: string | null = null) => ({
  type: "userMessage",
  id,
  clientId,
  content: [{ type: "text", text, text_elements: [] }],
});
const initialItems = [
  user(
    "user-1",
    "Make the conversation feel calm while the agent is working. Keep the transcript readable and the controls close at hand.",
  ),
  {
    type: "reasoning",
    id: "reasoning-1",
    summary: ["Checking the transcript ownership and publication cadence."],
    content: [],
  },
  {
    type: "commandExecution",
    id: "command-1",
    command: "rg streamingPublicationInterval Core/Sources",
    cwd: "/Users/developer/RemoteCoder",
    status: "completed",
    commandActions: [],
    aggregatedOutput: "ConversationSession.swift: streamingPublicationInterval = .milliseconds(80)\n",
    exitCode: 0,
    durationMs: 14,
  },
  agent(
    "agent-1",
    "The transcript already has a clear owner. I kept settled rows stable, let the active message update at the existing cadence, and brought the composer closer to the reading surface.\n\n### A quieter conversation\n\n- **Stable history** while new text arrives\n- A single place for model, reasoning and Fast\n- Questions stay visible until you answer or dismiss them\n\n```typescript\nconst address = { hostId, threadId };\nconst conversation = sessions.get(addressKey(address));\n\nif (conversation.activeTurnId) {\n  await gateway.interrupt(address, conversation.activeTurnId);\n}\n```\n\nThe same conversation ID on another host remains a separate conversation.",
  ),
  agent(
    "diagram-1",
    "```mermaid\nflowchart LR\n  accTitle: Exact conversation ownership\n  Browser --> Bridge\n  Bridge --> Mini[Mac mini]\n  Bridge --> Book[MacBook Pro]\n  Mini --> MiniThread[Host and thread]\n  Book --> BookThread[Host and thread]\n```",
  ),
  {
    type: "fileChange",
    id: "files-1",
    status: "completed",
    changes: [
      {
        path: "web-client/src/workspace.ts",
        kind: { type: "update", movePath: null },
        diff: "@@ -1,3 +1,4 @@\n-const key = threadId;\n+const key = addressKey({ hostId, threadId });\n+const publicationInterval = 80;\n",
      },
    ],
  },
  {
    ...agent("question-1", "Which appearance feels best for the browser?"),
    delivery: "async",
    questions: [
      {
        title: "Which appearance feels best for the browser?",
        options: ["Paper (Recommended)", "Midnight Ocean"],
      },
    ],
  },
];
function database(hostId: string) {
  const existing = databases.get(hostId);
  if (existing) return existing;
  const records = new Map<string, Record<string, unknown>>();
  for (const [index, name] of [
    "A calmer conversation",
    "Keep host identity exact",
    "Review the file changes",
    "Make room for the composer",
  ].entries()) {
    const claude = index === 3;
    const id = index === 0 ? "shared-thread-id" : `${claude ? "claude_" : ""}fixture-thread-${index}`;
    const thread = {
      id,
      name,
      preview:
        index === 0
          ? "A quieter transcript, stable history and a glass composer."
          : "Review the next small improvement.",
      cwd: fixtureHosts.find((host) => host.id === hostId)?.cwd,
      modelProvider: claude ? "claude" : "openai",
      model: claude ? claudeCatalog[0]?.id : "gpt-6.1-sol",
      reasoningEffort: "high",
      updatedAt: 1791891000 - index * 3600,
      createdAt: 1791800000,
      status: { type: "idle" },
      canAcceptDirectInput: true,
      extra: { fastModeSelection: false },
      turns: [],
      entries:
        index === 0
          ? initialItems.map((item, ordinal) => ({
              turnId: "fixture-turn-1",
              item,
              isComplete: true,
              startedAtOrdinal: ordinal,
              startedAtMs: 1791890000000 + ordinal * 1000,
              completedAtMs: 1791890000100 + ordinal * 1000,
            }))
          : [
              {
                turnId: "fixture-turn-1",
                item: agent(
                  "intro-1",
                  `This is a synthetic conversation on **${hostId === "fixture-mini" ? "Mac mini" : "MacBook Pro"}**. Try sending a message, queuing a follow-up, switching hosts, or opening Command.`,
                ),
                isComplete: true,
              },
            ],
      queue: [],
      activeTurnId: null,
      questionPending: index === 0,
      questionRevision: 1,
    };
    records.set(id, thread);
  }
  databases.set(hostId, records);
  return records;
}
const catalog = [
  {
    id: "gpt-6.1-sol",
    model: "gpt-6.1-sol",
    displayName: "GPT-6.1 Sol",
    description: "Coding and everyday work",
    hidden: false,
    isDefault: true,
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"].map((reasoningEffort) => ({
      reasoningEffort,
      description: reasoningEffort,
    })),
    defaultReasoningEffort: "high",
    inputModalities: ["text", "image"],
    serviceTiers: [{ id: "fast", name: "Fast", description: "Priority processing" }],
    additionalSpeedTiers: ["fast"],
  },
  {
    id: "gpt-6-astra",
    model: "gpt-6-astra",
    displayName: "GPT-6 Astra",
    description: "Demanding work",
    hidden: false,
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"].map((reasoningEffort) => ({
      reasoningEffort,
    })),
    defaultReasoningEffort: "medium",
    inputModalities: ["text", "image"],
    serviceTiers: [],
    additionalSpeedTiers: [],
  },
];

export class FixtureConnection {
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private closed = false;
  constructor(
    private readonly hostId: string,
    private readonly emit: (frame: unknown) => void,
  ) {
    database(hostId);
    const set = emitters.get(hostId) ?? new Set();
    set.add(emit);
    emitters.set(hostId, set);
  }
  private broadcast(method: string, params: unknown) {
    for (const emit of emitters.get(this.hostId) ?? []) emit({ method, params });
  }
  private later(delay: number, callback: () => void) {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      if (!this.closed) callback();
    }, delay);
    this.timers.add(timer);
  }
  receive(raw: string) {
    let frame: Frame;
    try {
      frame = JSON.parse(raw);
      if (!frame.method || frame.id === undefined) return;
      const result = this.dispatch(frame.method, object(frame.params ?? {}));
      this.emit({ id: frame.id, result });
    } catch (error) {
      const value = JSON.parse(raw);
      this.emit({
        id: value.id,
        error: { code: -32602, message: error instanceof Error ? error.message : "Fixture request failed" },
      });
    }
  }
  private dispatch(method: string, params: Record<string, unknown>): unknown {
    const records = database(this.hostId);
    const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
    const thread = threadId ? records.get(threadId) : undefined;
    const requireThread = () => {
      if (!thread) throw new Error("Unknown exact fixture conversation");
      return thread;
    };
    const headers = () =>
      [...records.values()].map(
        ({ entries, queue, activeTurnId, questionPending, questionRevision, ...header }) => header,
      );
    if (
      [
        "initialize",
        "device/tools/declare",
        "conversation/subscriptions/set",
        "thread/subscription/close",
      ].includes(method)
    )
      return {};
    if (method === "model/list") return { data: catalog, nextCursor: null };
    if (method === "preferences/read" || method === "preferences/update") {
      const entries = new Map(preferences.get(this.hostId));
      let changed = false;
      if (method === "preferences/update") {
        const incoming = Object.entries(object(params.entries));
        if (!incoming.length || incoming.length > 64)
          throw new Error("Preference update requires 1 to 64 keys");
        for (const [key, value] of incoming) {
          if (!key || Buffer.byteLength(key) > 128 || /\p{Cc}/u.test(key))
            throw new Error("Invalid preference key");
          const received = preferenceEntry(value, false);
          if (!entries.has(key) && entries.size >= 64) continue;
          if (newerPreference(received, entries.get(key))) {
            entries.set(key, received);
            changed = true;
          }
        }
        preferences.set(this.hostId, entries);
      }
      const document = { entries: Object.fromEntries(entries) };
      if (changed) this.broadcast("preferences/changed", document);
      return document;
    }
    if (method === "thread/list")
      return { data: headers().filter((header) => header.modelProvider !== "claude"), nextCursor: null };
    if (method === "claude/thread/list")
      return { data: headers().filter((header) => header.modelProvider === "claude"), nextCursor: null };
    if (method === "thread/read" || method === "thread/resume") return { thread: requireThread() };
    if (method === "claude/thread/liveCheckpoint")
      return { status: "unknown", threadId: requireThread().id, reason: "noLiveState" };
    if (method === "thread/subscribe") {
      const value = requireThread();
      if (value.modelProvider === "claude") throw new Error("Claude has no Codex observation subscription");
      return {
        status: "subscribed",
        subscriptionId: crypto.randomUUID(),
        thread: value,
        checkpoint: {
          liveItems: [],
          activeTurn: value.activeTurnId ? { id: value.activeTurnId } : null,
          historyUnavailable: false,
          itemsBackwardsCursor: "fixture-tail",
          turnsBackwardsCursor: null,
        },
      };
    }
    if (method === "thread/items/list") {
      const value = requireThread();
      return {
        data: [...(value.entries as unknown[])].reverse().slice(0, Number(params.limit ?? 60)),
        nextCursor: null,
        backwardsCursor: null,
      };
    }
    if (method === "daemon/activeTurns")
      return {
        epoch,
        revision: 1,
        activeTurns: [...records.values()]
          .filter((value) => value.activeTurnId)
          .map((value) => ({ threadId: value.id, turnId: value.activeTurnId })),
        coverage: { codex: true, claude: true },
        externalActivity: { sessions: [], claudeAvailable: true, codexAvailable: true },
        agentOwners: {},
      };
    if (method === "thread/start" || method === "thread/fork") {
      const id = params.provider === "claude" ? `claude_${crypto.randomUUID()}` : crypto.randomUUID();
      const value = {
        id,
        name: null,
        preview: "New conversation",
        cwd: params.cwd ?? thread?.cwd,
        modelProvider: params.provider === "claude" ? "claude" : "openai",
        model: params.model ?? thread?.model,
        reasoningEffort: "high",
        updatedAt: Date.now() / 1000,
        status: { type: "idle" },
        canAcceptDirectInput: true,
        extra: { fastModeSelection: false },
        entries: method === "thread/fork" ? [...(requireThread().entries as unknown[])] : [],
        queue: [],
        questionPending: false,
        questionRevision: 1,
        activeTurnId: null,
      };
      records.set(id, value);
      return { thread: value };
    }
    if (method === "conversation/settings/update") {
      Object.assign(requireThread(), {
        model: params.model,
        reasoningEffort: params.effort,
        extra: { fastModeSelection: params.serviceTier === "fast" },
      });
      return {
        status: thread?.activeTurnId ? "nextTurn" : "applied",
        currentTurnId: thread?.activeTurnId,
        warning: null,
      };
    }
    if (method === "thread/queue/list") return { data: requireThread().queue, nextCursor: null };
    if (method === "thread/queue/add") {
      const value = requireThread();
      const queuedSubmission = {
        id: crypto.randomUUID(),
        input: params.input,
        clientUserMessageId: params.clientUserMessageId,
      };
      (value.queue as unknown[]).push(queuedSubmission);
      this.broadcast("thread/queue/changed", { threadId: value.id });
      return { queuedSubmission };
    }
    if (method === "thread/queue/delete") {
      const value = requireThread();
      value.queue = (value.queue as Record<string, unknown>[]).filter(
        (entry) => entry.id !== params.queuedSubmissionId,
      );
      return {};
    }
    if (method === "thread/name/set") {
      requireThread().name = string(params.name);
      return {};
    }
    if (method === "thread/archive") {
      requireThread();
      records.delete(String(threadId));
      return {};
    }
    if (method === "thread/compact/start") return {};
    if (method === "turn/interrupt") {
      const value = requireThread();
      if (value.activeTurnId !== params.turnId) throw new Error("Turn is not running");
      value.activeTurnId = null;
      this.broadcast("turn/completed", {
        threadId,
        turn: { id: params.turnId, status: "interrupted", error: null },
      });
      return {};
    }
    if (method === "turn/start" || method === "turn/steer") {
      const value = requireThread();
      if (method === "turn/steer" && params.expectedTurnId !== value.activeTurnId)
        throw new Error("Turn identity changed");
      const id = String(value.activeTurnId ?? crypto.randomUUID());
      value.activeTurnId = id;
      const content = Array.isArray(params.input) ? params.input : [];
      const userItem = {
        type: "userMessage",
        id: crypto.randomUUID(),
        clientId: params.clientUserMessageId,
        content,
      };
      (value.entries as unknown[]).push({ turnId: id, item: userItem, isComplete: true });
      this.broadcast("turn/started", { threadId, turn: { id, status: "inProgress" } });
      this.broadcast("item/completed", { threadId, turnId: id, item: userItem });
      if (
        content.some(
          (input) =>
            object(input).text && String(object(input).text).includes("send_user_message_question_reply"),
        )
      )
        value.questionPending = false;
      const itemId = crypto.randomUUID();
      const text =
        'The browser sent your message through the same JSON-RPC transport used by the native app.\n\nThis fixture lets you test **streaming, questions, queueing, attachments, host switching and interrupt** without starting a production agent.\n\n```typescript\nawait gateway.call("turn/start", {\n  threadId,\n  input,\n  clientUserMessageId,\n});\n```\n\nYour prompt remains tied to this exact host and conversation.';
      this.broadcast("item/started", { threadId, turnId: id, item: agent(itemId, "", "commentary") });
      const fragments = text.match(/.{1,24}/gs) ?? [];
      fragments.forEach((delta, index) => {
        this.later(120 + index * 75, () => {
          if (value.activeTurnId === id)
            this.broadcast("item/agentMessage/delta", { threadId, turnId: id, itemId, delta });
        });
      });
      this.later(250 + fragments.length * 75, () => {
        if (value.activeTurnId !== id) return;
        const result = agent(itemId, text);
        (value.entries as unknown[]).push({ turnId: id, item: result, isComplete: true });
        this.broadcast("item/completed", { threadId, turnId: id, item: result });
        value.activeTurnId = null;
        this.broadcast("thread/tokenUsage/updated", {
          threadId,
          tokenUsage: {
            total: { totalTokens: 3200 },
            last: { totalTokens: 3200, inputTokens: 2900, outputTokens: 300 },
            modelContextWindow: 128000,
          },
        });
        this.broadcast("turn/completed", { threadId, turn: { id, status: "completed", error: null } });
        this.broadcast("conversation/questions/changed", { threadId });
      });
      return method === "turn/start" ? { turn: { id, status: "inProgress" } } : { turnId: id };
    }
    if (method === "conversation/questions/read") {
      const queries = Array.isArray(params.queries) ? params.queries : [];
      return {
        threads: queries.map((query) => {
          const id = String(object(query).threadId);
          const value = records.get(id);
          const pending = value?.questionPending === true;
          return {
            threadId: id,
            epoch,
            revision: Number(value?.questionRevision ?? 1),
            coverage: "ready",
            records:
              value &&
              (value.entries as Record<string, unknown>[]).some(
                (entry) => object(entry.item).id === "question-1",
              )
                ? [
                    {
                      itemId: "question-1",
                      turnId: "fixture-turn-1",
                      revision: Number(value.questionRevision),
                      questions: [
                        {
                          index: 0,
                          title: "Which appearance feels best for the browser?",
                          options: ["Paper (Recommended)", "Midnight Ocean"],
                          resolution: pending ? "pending" : "dismissed",
                          answer: null,
                        },
                      ],
                    },
                  ]
                : [],
            pendingItemIds: pending ? ["question-1"] : [],
            missingItemIds: [],
          };
        }),
      };
    }
    if (method === "conversation/question/dismiss") {
      const value = requireThread();
      if (params.expectedEpoch !== epoch || params.expectedRecordRevision !== value.questionRevision)
        return { status: "conflict" };
      value.questionPending = false;
      value.questionRevision = Number(value.questionRevision) + 1;
      this.broadcast("conversation/questions/changed", { threadId });
      return { status: "applied", epoch };
    }
    if (method === "account/rateLimits/read")
      return {
        rateLimits: {
          primary: { usedPercent: 18, windowDurationMins: 300, resetsAt: 1791896400 },
          secondary: { usedPercent: 37, windowDurationMins: 10080, resetsAt: 1792100000 },
        },
      };
    if (method === "fs/readDirectory")
      return {
        entries: ["RemoteCoder", "Core", "web-client", "docs"].map((fileName) => ({
          fileName,
          isDirectory: true,
          isFile: false,
        })),
      };
    if (method === "command/exec")
      return {
        exitCode: 0,
        stdout:
          "Synthetic command workspace\nRemoteCoder/\nCore/\nweb-client/\n\nNo command ran on a production host.\n",
        stderr: "",
      };
    throw new Error(`Fixture method unavailable: ${method}`);
  }
  close() {
    this.closed = true;
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
    emitters.get(this.hostId)?.delete(this.emit);
  }
}
