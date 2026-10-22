import { targetKey } from "../../src/execution-context";
import type { Captured, Rpc } from "../../src/gateway";
import { type Frame, type Host, object } from "../../src/protocol/boundary";
import { applyMarkChange, type ConversationMarks } from "../../src/workspace/conversation-marks";
import { Workspace } from "../../src/workspace/workspace";
export const host = (id: string): Host => ({
  id,
  name: id,
  cwd: "/workspace",
  url: "https://gateway.example",
  credentialStatus: "notChecked",
});
export const header = (id = "shared") => ({
  id,
  name: "Conversation",
  preview: "Fixture",
  cwd: "/workspace",
  model: "test-model",
  reasoningEffort: "high",
  updatedAt: 1700000000,
  createdAt: 1700000000,
  lastTurnCompletedAt: null,
  recencyAt: null,
  status: { type: "idle" },
  extra: null,
});
export const model = {
  id: "test-model",
  model: "test-model",
  displayName: "Test model",
  supportedReasoningEfforts: [{ reasoningEffort: "high" }],
  defaultReasoningEffort: "high",
  hidden: false,
  serviceTiers: [],
  inputModalities: ["text"],
};
export const activity = (coverage = true) => ({
  epoch: "test",
  revision: 1,
  activeTurns: [],
  coverage: { codex: coverage, claude: true },
});
export const inventory = (pending: boolean, revision: number) => ({
  threads: [
    {
      threadId: "shared",
      epoch: "questions",
      revision,
      coverage: "ready",
      records: [
        {
          itemId: "q",
          turnId: "t",
          revision,
          questions: [
            {
              index: 0,
              title: "Pick one",
              options: ["A", "B"],
              resolution: pending ? "pending" : "dismissed",
              answer: null,
            },
          ],
        },
      ],
      pendingItemIds: pending ? ["q"] : [],
    },
  ],
});
export function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
export class MemoryStorage implements Storage {
  private data = new Map<string, string>();
  get length() {
    return this.data.size;
  }
  clear() {
    this.data.clear();
  }
  getItem(key: string) {
    return this.data.get(key) ?? null;
  }
  key(index: number) {
    return [...this.data.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.data.delete(key);
  }
  setItem(key: string, value: string) {
    this.data.set(key, value);
  }
}
export class Harness implements Rpc {
  sequence = 0;
  marks: ConversationMarks = { schemaVersion: 3, revision: 0, readBaseline: 0, threads: {} };
  favoritePaths: string[] = [];
  favoriteRevision = 0;
  calls: { method: string; params: Record<string, unknown> }[] = [];
  handler?: (method: string, params: Record<string, unknown>) => Promise<unknown> | unknown;
  constructor(readonly event: (frame: Frame) => void) {}
  async capture(method: string, params: unknown = {}): Promise<Captured> {
    const value = await this.call(method, params);
    return { value, receipt: { connection: 1, sequence: ++this.sequence } };
  }
  emit(method: string, params: unknown, rcClaudeLive?: Frame["rcClaudeLive"]) {
    this.event({ method, params, rcClaudeLive, receipt: { connection: 1, sequence: ++this.sequence } });
  }
  async call(method: string, value: unknown = {}): Promise<unknown> {
    const params = object(value);
    this.calls.push({ method, params });
    const custom = this.handler?.(method, params);
    if (custom !== undefined) return custom;
    if (method === "conversation/marks/read") return this.marks;
    if (method === "conversation/marks/update") {
      for (const change of params.changes as Parameters<typeof applyMarkChange>[1][])
        this.marks = applyMarkChange(this.marks, change);
      const revision = this.marks.revision + 1;
      this.marks = {
        ...this.marks,
        revision,
        threads: Object.fromEntries(
          Object.entries(this.marks.threads).map(([id, marks]) => [id, { ...marks, revision }]),
        ),
      };
      return { delta: this.marks };
    }
    if (method === "directory/favorites/read")
      return { revision: this.favoriteRevision, paths: this.favoritePaths };
    if (method === "directory/favorites/update") {
      for (const { op, path } of params.changes as { op: string; path: string }[])
        this.favoritePaths =
          op === "remove"
            ? this.favoritePaths.filter((entry) => entry !== path)
            : [...this.favoritePaths.filter((entry) => entry !== path), path];
      return { revision: ++this.favoriteRevision, paths: this.favoritePaths };
    }
    if (method === "host/info") return { homeDirectory: "/home/fixture" };
    if (method === "conversation/projects/resolve")
      return {
        projects: (params.directories as string[]).map((cwd) => ({
          cwd,
          kind: "directory",
          key: cwd,
          name: cwd,
          root: cwd,
        })),
      };
    if (method === "thread/list") return { data: [header()], nextCursor: null };
    if (method === "claude/thread/list") return { data: [], nextCursor: null };
    if (method === "model/list") return { data: [model], nextCursor: null };
    if (method === "conversation/agents/classify")
      return { relations: {}, knownRoots: params.threadIds, warnings: [] };
    if (method === "thread/subscribe")
      return {
        status: "subscribed",
        subscriptionId: "s",
        thread: header(String(params.threadId)),
        checkpoint: { itemsBackwardsCursor: "tail", liveItems: [] },
      };
    if (method === "thread/items/list") return { data: [], nextCursor: null };
    if (method === "daemon/activeTurns") return activity();
    if (method === "conversation/questions/read")
      return {
        threads: (params.queries as { threadId: string }[]).map(({ threadId }) => ({
          ...inventory(false, 1).threads[0],
          threadId,
        })),
      };
    if (method === "thread/queue/list") return { data: [], nextCursor: null };
    if (method === "thread/start") return { thread: header(crypto.randomUUID()) };
    if (method === "turn/start") return { turn: { id: "running" } };
    return {};
  }
  reply() {}
  notify() {}
}
export const workspaces: Workspace[] = [];
export async function setup(ids = ["mini"], storage?: Storage) {
  const harnesses = new Map<string, Harness>();
  const workspace = new Workspace((host, event) => {
    const harness = new Harness(event);
    harnesses.set(host.id, harness);
    return harness;
  }, storage);
  workspaces.push(workspace);
  workspace.configureHosts(ids.map(host));
  for (const id of ids) await workspace.refreshHost(id);
  return { workspace, harness: harnesses.get(ids[0] ?? "mini") as Harness, harnesses };
}

export async function setupContexts() {
  const harnesses = new Map<string, Harness>();
  let generation = 1;
  const workspace = new Workspace(
    (_host, event, target) => {
      const harness = new Harness(event);
      harness.handler = (method) =>
        method === "thread/items/list"
          ? {
              data: [
                {
                  turnId: "t",
                  isComplete: true,
                  item: { type: "agentMessage", id: "a", text: targetKey(target) },
                },
              ],
              nextCursor: null,
            }
          : undefined;
      harnesses.set(targetKey(target), harness);
      return harness;
    },
    undefined,
    async () => ({
      schemaVersion: 2,
      refreshing: false,
      retiredClaudeAccountIds: [],
      accounts: [
        {
          id: enrollmentId,
          generation,
          provider: "codex",
          label: "Subscription",
          isDefault: false,
          enabled: true,
          state: "ready",
          identity: { key: "verified" },
          windows: [],
          stale: false,
        },
      ],
    }),
  );
  workspaces.push(workspace);
  workspace.configureHosts([host("mini")]);
  await workspace.refreshHost("mini");
  return {
    workspace,
    harnesses,
    replaceGeneration: () => {
      generation += 1;
    },
  };
}

export async function setupClaude(ids = ["mini"], storage?: Storage) {
  const result = await setup(ids, storage);
  const previous = result.harness.handler;
  result.harness.handler = (method, params) => {
    if (method === "claude/thread/list") return { data: [header("claude_owned")], nextCursor: null };
    if (method === "claude/thread/liveCheckpoint")
      return { status: "unknown", threadId: params.threadId, reason: "noLiveState" };
    return previous?.(method, params);
  };
  await result.workspace.refreshHost(ids[0] ?? "mini");
  return result;
}

export const enrollmentId = "8dc8844a-15b0-4117-9c52-f61246c8012a";

export function cleanupWorkspaces() {
  for (const workspace of workspaces.splice(0)) workspace.dispose();
}
