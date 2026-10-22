import { accountCatalog, type ExecutionTarget, gatewayPath } from "../src/execution-context";
import { array, object, string } from "../src/protocol/boundary";
import { parseAgents } from "../src/ui/agents/agents-panel";
import { automationValue } from "../src/ui/remote-operations";
import { parseClaudeUsageDirectory, parseCodexUsageDirectory } from "../src/workspace/account-usage-store";

declare const WebSocket: {
  new (url: string, options: Bun.WebSocketOptions): globalThis.WebSocket;
};

const origin = process.argv[2] ?? process.env.RC_WEB_PROBE_ORIGIN ?? "";
if (!origin) throw new Error("Pass the browser origin as an argument or set RC_WEB_PROBE_ORIGIN");
const initial = await fetch(`${origin}/`);
if (!initial.ok) throw new Error(`Browser entry returned ${initial.status}`);
const cookie = initial.headers.get("set-cookie")?.split(";")[0];
if (!cookie) throw new Error("Private browser entry did not establish a session");
const catalogResponse = await fetch(`${origin}/api/hosts`, { headers: { Cookie: cookie } });
const catalog = object(await catalogResponse.json());
const hosts = array(catalog.hosts, 24)
  .map(object)
  .filter((host) => !string(host.id).startsWith("fixture-"));
const evidence: unknown[] = [];
async function readEnrolled(target: ExecutionTarget) {
  const socket = new WebSocket(`${origin.replace(/^http/, "ws")}${gatewayPath(target)}`, {
    headers: { Cookie: cookie ?? "", Origin: origin },
  });
  const pending = new Map<string, { resolve(value: unknown): void; reject(error: Error): void }>();
  socket.onmessage = (event) => {
    const frame = object(JSON.parse(String(event.data)));
    if (typeof frame.id !== "string") return;
    const request = pending.get(frame.id);
    pending.delete(frame.id);
    if (frame.error) request?.reject(new Error(string(object(frame.error).message)));
    else request?.resolve(frame.result);
  };
  socket.onclose = () => {
    for (const request of pending.values()) request.reject(new Error("The enrolled socket closed"));
    pending.clear();
  };
  const deadline = setTimeout(() => socket.close(), 60000);
  try {
    await new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error("The exact enrolled connection was rejected"));
    });
    const call = (method: string, params: unknown) =>
      new Promise<unknown>((resolve, reject) => {
        const id = crypto.randomUUID();
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params }));
      });
    await call("initialize", {
      clientInfo: { name: "remotecoder_web_enrolled_read_probe", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    socket.send(JSON.stringify({ method: "initialized", params: {} }));
    await call("device/tools/declare", { tools: [] });
    const [catalog, history, activity] = await Promise.all([
      call("model/list", { includeHidden: false }),
      call("thread/list", { limit: 5, useStateDbOnly: false }),
      call("daemon/activeTurns", {}),
    ]);
    const entries = array(object(history).data, 10).map(object);
    const thread = entries[0];
    let tailItems: number | undefined;
    if (thread)
      tailItems = array(
        object(
          await call("thread/items/list", { threadId: string(thread.id), sortDirection: "desc", limit: 10 }),
        ).data,
        20,
      ).length;
    return {
      accountId: target.enrollment?.accountId,
      generation: target.enrollment?.generation,
      models: array(object(catalog).data, 200).length,
      historyEntries: entries.length,
      activityCoverage: object(activity).coverage,
      tailItems,
    };
  } finally {
    clearTimeout(deadline);
    socket.close();
  }
}
for (const host of hosts) {
  const hostId = string(host.id);
  const socket = new WebSocket(`${origin.replace(/^http/, "ws")}/api/hosts/${hostId}/ws`, {
    headers: { Cookie: cookie, Origin: origin },
  });
  const pending = new Map<string, { resolve(value: unknown): void; reject(error: Error): void }>();
  socket.onmessage = (event) => {
    const frame = object(JSON.parse(String(event.data)));
    if (typeof frame.id !== "string") return;
    const request = pending.get(frame.id);
    if (!request) return;
    pending.delete(frame.id);
    if (frame.error) request.reject(new Error(string(object(frame.error).message)));
    else request.resolve(frame.result);
  };
  socket.onclose = () => {
    for (const request of pending.values())
      request.reject(new Error("Host socket closed before its read completed"));
    pending.clear();
  };
  const deadline = setTimeout(() => socket.close(), 60000);
  try {
    await new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error("Private host socket could not connect"));
    });
    const call = (method: string, params: unknown) =>
      new Promise<unknown>((resolve, reject) => {
        const id = crypto.randomUUID();
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params }));
      });
    await call("initialize", {
      clientInfo: { name: "remotecoder_web_read_probe", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    socket.send(JSON.stringify({ method: "initialized", params: {} }));
    await call("device/tools/declare", { tools: [] });
    const [modelsValue, historyValue, activityValue, claudeHistoryValue] = await Promise.all([
      call("model/list", { includeHidden: false }),
      call("thread/list", { limit: 5, sortKey: "updated_at", useStateDbOnly: false }),
      call("daemon/activeTurns", {}),
      call("claude/thread/list", { limit: 5, sortKey: "updated_at" }),
    ]);
    const history = array(object(historyValue).data, 10).map(object);
    const claudeHistory = array(object(claudeHistoryValue).data, 10).map(object);
    let claudeRead: { historyEntries: number; tailItems?: number; checkpointStatus?: string } | undefined;
    const claudeThread = claudeHistory[0];
    if (claudeThread) {
      const threadId = string(claudeThread.id);
      if (!threadId.startsWith("claude_")) throw new Error("Claude history returned a noncanonical identity");
      await call("conversation/subscriptions/set", { threadIds: [threadId] });
      const tail = object(await call("thread/items/list", { threadId, sortDirection: "desc", limit: 10 }));
      const checkpoint = object(await call("claude/thread/liveCheckpoint", { threadId }));
      if (checkpoint.threadId !== threadId || !["observed", "unknown"].includes(String(checkpoint.status)))
        throw new Error("Claude checkpoint did not retain its exact owner");
      if (checkpoint.status === "observed") {
        string(checkpoint.epoch);
        if (!Number.isSafeInteger(checkpoint.throughSequence))
          throw new Error("Claude checkpoint returned an invalid sequence");
        array(checkpoint.liveItems, 200);
      }
      claudeRead = {
        historyEntries: claudeHistory.length,
        tailItems: array(tail.data, 20).length,
        checkpointStatus: string(checkpoint.status),
      };
    }
    let observationStatus: string | undefined;
    let tailItems: number | undefined;
    const thread = history[0];
    let agents: number | undefined;
    if (thread) {
      const observed = object(await call("thread/subscribe", { threadId: string(thread.id) }));
      observationStatus = string(observed.status);
      if (observed.status === "subscribed") {
        const checkpoint = object(observed.checkpoint);
        if (checkpoint.itemsBackwardsCursor != null) {
          const tail = object(
            await call("thread/items/list", {
              threadId: string(thread.id),
              cursor: checkpoint.itemsBackwardsCursor,
              sortDirection: "desc",
              limit: 10,
            }),
          );
          tailItems = array(tail.data, 20).length;
        } else tailItems = array(checkpoint.liveItems, 200).length;
        await call("thread/subscription/close", { subscriptionId: string(observed.subscriptionId) });
      } else {
        const tail = object(
          await call("thread/items/list", { threadId: string(thread.id), sortDirection: "desc", limit: 10 }),
        );
        tailItems = array(tail.data, 20).length;
      }
      agents = parseAgents(await call("conversation/agents/list", { threadId: string(thread.id) })).agents
        .length;
    }
    const files = array(
      object(await call("fs/readDirectory", { path: string(host.cwd) })).entries,
      10_000,
    ).length;
    const get = async (path: string) => {
      const response = await fetch(`${origin}/api/hosts/${hostId}/${path}`, { headers: { Cookie: cookie } });
      if (!response.ok) throw new Error(`${path} returned ${response.status}`);
      return response.json();
    };
    const accountValue = await get("accounts");
    const accounts = parseCodexUsageDirectory(hostId, accountValue);
    const execution = accountCatalog(hostId, accountValue);
    const enrolledContexts = [];
    for (const choice of execution.choices)
      if (choice.usable && choice.target.enrollment) enrolledContexts.push(await readEnrolled(choice.target));
    const claude = parseClaudeUsageDirectory(await get("claude/accounts"));
    let automations: number | undefined;
    if (hostId === process.env.RC_WEB_AUTOMATION_HOST_ID) {
      automationValue(await call("automations/status", {}));
      const definitions = automationValue(await call("automations/list", {}));
      automations = array(
        definitions.automations ?? definitions.definitions ?? definitions.items,
        500,
      ).length;
    }
    evidence.push({
      hostId,
      name: string(host.name),
      models: array(object(modelsValue).data, 200).length,
      historyEntries: history.length,
      activityCoverage: object(activityValue).coverage,
      observationStatus,
      tailItems,
      agents,
      directoryEntries: files,
      accounts: accounts.length,
      claudeAccounts: claude.accounts.length,
      claudeRead,
      verifiedExecutionChoices: execution.choices.filter((choice) => choice.usable).length,
      enrolledContexts,
      automations,
    });
  } finally {
    clearTimeout(deadline);
    socket.close();
  }
}
console.log(
  JSON.stringify(
    { capturedAt: new Date().toISOString(), origin, mode: "authenticated reads only", hosts: evidence },
    null,
    2,
  ),
);
