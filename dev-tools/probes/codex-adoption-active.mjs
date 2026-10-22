import assert from "node:assert/strict";
import { mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { NativeClient } from "./codex-adoption.mjs";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = process.argv[2];
assert(binary, "Usage: bun codex-adoption-active.mjs GATEWAY_BINARY");
const lab = await IsolatedGateway.create(resolve(binary));
const retiredId = "393971f9-71aa-4a14-aa7e-e103f296dfc2";
const source = lab.path(`.rca/${retiredId.replaceAll("-", "")}/c`);
const marker = "ADOPTION_ACTIVE_NATIVE_TURN";
let release;
const held = new Promise(resolve => { release = resolve; });
const modelRequests = [];
const model = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    if (request.method !== "POST") return Response.json({ data: [] });
    const body = await request.json();
    modelRequests.push(body);
    const id = `resp_active_${modelRequests.length}`;
    const encode = event => new TextEncoder().encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
    return new Response(new ReadableStream({ start(controller) {
        controller.enqueue(encode({ type: "response.created", response: { id } }));
        held.then(() => {
            try {
                controller.enqueue(encode({ type: "response.output_item.done", item: { type: "message", id: "active_final", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: "Original active turn resumed exactly." }] } }));
                controller.enqueue(encode({ type: "response.completed", response: { id, usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20 } } }));
                controller.close();
            } catch {}
        });
    } }), { headers: { "Content-Type": "text/event-stream" } });
} });

async function call(client, method, params = {}) {
    const response = await client.rpc(method, params);
    assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
    return response.result;
}
async function lifecycle(home, action) {
    const child = Bun.spawn([lab.codex, "app-server", "daemon", action], {
        env: { ...lab.safeEnv, CODEX_HOME: home }, cwd: lab.root,
        stdout: Bun.file(lab.path(`daemon-${action}.log`)), stderr: Bun.file(lab.path(`daemon-${action}-errors.log`)),
    });
    assert.equal(await lab.within(child.exited, 20000, `Native daemon ${action} timed out`), 0, `Native daemon ${action} failed`);
}
let sourceClient, failure;
try {
    for (const home of [source, lab.nativeDefault]) {
        await mkdir(join(home, "packages/app-server-daemon"), { recursive: true, mode: 0o700 });
        await symlink(join(lab.realHome, ".codex/packages/standalone/current"), join(home, "packages/app-server-daemon/current"));
        await writeFile(join(home, "config.toml"), `model = "gpt-5.4"\nmodel_provider = "fixture"\napproval_policy = "never"\nsandbox_mode = "read-only"\n[model_providers.fixture]\nname = "fixture"\nbase_url = "http://127.0.0.1:${model.port}/v1"\nwire_api = "responses"\n[analytics]\nenabled = false\n`, { mode: 0o600 });
    }
    await lab.writeGatewayEnv([]);
    await mkdir(lab.path(".remote-coder"), { recursive: true, mode: 0o700 });
    await writeFile(lab.path(".remote-coder/account-enrollments.json"), JSON.stringify({ schemaVersion: 1, accounts: [{ id: retiredId, provider: "codex", label: "Active native fixture", enabled: true, generation: 7, identity: null }] }), { mode: 0o600 });
    await lifecycle(source, "start");
    sourceClient = await new NativeClient(lab.codex, source, lab.root, "proxy").initialize();
    const { thread } = await call(sourceClient, "thread/start", { cwd: lab.root, model: "gpt-5.4", modelProvider: "fixture", historyMode: "paginated", approvalPolicy: "never", sandbox: "read-only" });
    const { turn } = await call(sourceClient, "turn/start", { threadId: thread.id, input: [{ type: "text", text: marker }] });
    await lab.waitFor(() => modelRequests.length === 1, 20);
    const original = await call(sourceClient, "thread/read", { threadId: thread.id, includeTurns: true });
    assert(original.thread.turns.some(value => value.id === turn.id && value.status === "inProgress"), "Source turn was not active");
    const defaultGeneration = "interrupted-default-adoption";
    await writeFile(lab.path(".remote-coder/codex-restart-recovery.json"), JSON.stringify({
        schemaVersion: 2, generationId: defaultGeneration, capability: "0123456789abcdef0123456789abcdef",
        createdAtUnixMs: Date.now(), phase: "captured", tasks: [], runtimeSwap: null, error: null,
    }), { mode: 0o600 });
    const starting = lab.start();
    starting.catch(() => {});
    await lab.waitFor(() => modelRequests.length >= 2, 60);
    assert.equal(modelRequests.length, 2, "Active user prompt was submitted more than once during recovery");
    release();
    await starting;
    const client = await lab.connect(retiredId, 999999);
    const recovered = await lab.waitFor(async () => {
        const result = await call(client, "thread/turns/list", { threadId: thread.id, itemsView: "full", limit: 20 });
        return result.data.some(value => value.id === turn.id && value.status === "completed") && result;
    }, 30);
    assert.equal(recovered.data.length, 1, "Recovery created another turn");
    assert.equal(recovered.data[0].id, turn.id, "Recovery replaced the original turn identity");
    assert.equal(recovered.data[0].items.filter(item => item.type === "userMessage").length, 1, "Recovery replayed the persisted user prompt");
    assert.equal(recovered.data[0].items.filter(item => item.type === "agentMessage" && item.text === "Original active turn resumed exactly.").length, 1, "Recovery did not complete exactly once");
    assert(!await lab.hasNativeDaemon(source), "Retired enrollment daemon survived cutover");
    assert(await lab.hasNativeDaemon(lab.nativeDefault), "Default daemon is absent");
    await lab.waitFor(async () => {
        const recovery = JSON.parse(await readFile(lab.path(".remote-coder/codex-restart-recovery.json"), "utf8"));
        assert.equal(recovery.generationId, defaultGeneration, "Adoption replaced the interrupted default recovery generation");
        return recovery.tasks.some(task => task.threadId === thread.id && task.turnId === turn.id && task.status === "completed");
    }, 15);
    console.log(JSON.stringify({ passed: true, threadId: thread.id, turnId: turn.id, defaultGeneration, modelRequests: modelRequests.length, userMessages: 1, completed: 1 }));
} catch (error) {
    failure = error;
    console.error(JSON.stringify({ passed: false, root: lab.root, modelRequests: modelRequests.length, error: String(error.stack) }));
} finally {
    release();
    if (sourceClient) await sourceClient.stop();
    try { await lab.stop(); } catch { await lab.forceStop(); }
    for (const home of [source, lab.nativeDefault]) await lab.stopNativeDaemon(home);
    await model.stop(true);
    if (!failure) await lab.removeRoot();
}
if (failure) process.exitCode = 1;
