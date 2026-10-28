import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const [binary] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
const lab = await IsolatedGateway.create(binary);
let failure;
try {
    await mkdir(lab.path(".claude"), { recursive: true });
    await lab.writeGatewayEnv(["RC_CLAUDE_ENABLED=false", `RC_CLAUDE_HOME=${lab.path(".claude")}`]);
    await lab.start();
    const ws = new WebSocket(lab.base.replace("http:", "ws:") + "/ws", {
        headers: { Authorization: `Bearer ${lab.token}` },
    });
    const responses = new Map();
    let resolveReady;
    let resolveInitialized;
    let complete;
    let rejectCompleted;
    let messageError;
    let resolveSentinel;
    const readyFrame = new Promise(resolve => { resolveReady = resolve; });
    const initialized = new Promise(resolve => { resolveInitialized = resolve; });
    const completed = new Promise((resolve, reject) => { complete = resolve; rejectCompleted = reject; });
    const sentinel = new Promise(resolve => { resolveSentinel = resolve; });
    ws.onmessage = event => {
        const message = JSON.parse(String(event.data));
        if (message.method === "daemon/ready") resolveReady(message);
        if (message.id === "initialize") resolveInitialized(message);
        if (message.id === "sentinel") resolveSentinel(message);
        if (typeof message.id !== "string" || !message.id.startsWith("burst-")) return;
        if (responses.has(message.id)) {
            messageError = new Error(`Duplicate terminal response: ${message.id}`);
            rejectCompleted(messageError);
            return;
        }
        responses.set(message.id, message);
        if (responses.size === 20) complete();
    };
    lab.clients.add(ws);
    const ready = await lab.within(readyFrame, 10000, "Ready capability was not received");
    assert.equal(ready.params.capabilities.cancelRequest, true);
    ws.send(JSON.stringify({ id: "initialize", method: "initialize", params: {
        clientInfo: { name: "query_admission_probe", version: "1" },
        capabilities: { experimentalApi: true },
    } }));
    assert(!(await lab.within(initialized, 10000, "Initialize did not finish")).error);
    ws.send(JSON.stringify({ method: "initialized", params: {} }));
    const cancelled = new Set(["burst-1", "burst-9", "burst-19"]);
    const started = performance.now();
    for (let id = 0; id < 20; id++) {
        ws.send(JSON.stringify({
            id: `burst-${id}`, method: "conversation/agents/list",
            params: { threadId: "claude_e1741c43-3d9a-4448-9f4a-3c7e5906e852" },
        }));
    }
    for (const id of cancelled) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", method: "$/cancelRequest", params: { id } }));
    }
    await lab.within(completed, 20000, "Burst did not finish");
    for (const [id, response] of responses) {
        assert.notEqual(response.error?.data?.kind, "capacity", `${id} rejected on burst admission`);
        if (cancelled.has(id)) {
            assert.equal(response.error?.code, -32800);
            assert.equal(response.error?.message, "Request cancelled");
            assert.deepEqual(response.error?.data, { kind: "requestCancelled", retryable: false });
        } else {
            assert(response.result, `${id} failed: ${JSON.stringify(response.error)}`);
        }
    }
    const elapsedMs = Math.round(performance.now() - started);
    ws.send(JSON.stringify({ jsonrpc: "2.0", method: "$/cancelRequest", params: { id: "burst-0" } }));
    ws.send(JSON.stringify({ id: "sentinel", method: "host/info", params: {} }));
    assert((await lab.within(sentinel, 10000, "Post-cancellation read did not finish")).result);
    assert.equal(responses.size, 20);
    assert(!messageError, messageError?.message);
    console.log(JSON.stringify({
        passed: true, readyCapability: ready.params.capabilities.cancelRequest,
        requests: responses.size, cancelled: cancelled.size, capacityErrors: 0, elapsedMs,
        root: lab.root,
    }));
} catch (error) {
    failure = error;
} finally {
    try { await lab.stop(); } catch (error) { failure ??= error; await lab.forceStop(); }
    try { assert.equal(await lab.stopNativeDaemon(lab.nativeDefault), 0); } catch (error) { failure ??= error; }
    await lab.router?.stop(true);
    if (!failure) await lab.removeRoot();
}
if (failure) throw failure;
