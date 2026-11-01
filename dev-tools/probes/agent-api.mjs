import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";
import { installPackage, startModel, writeProviderConfig } from "./delegated-model.mjs";

const [binary, runtimePackage] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the candidate executable as an absolute path");
assert(runtimePackage && isAbsolute(runtimePackage), "Pass the matched runtime package as an absolute path");
const lab = await IsolatedGateway.create(binary);
const model = startModel();
async function agent(...args) {
    const child = Bun.spawn([binary, "--env-file", lab.path("gateway.env"), "agent", ...args, "--json"], {
        env: lab.safeEnv, cwd: lab.path("work"), stdout: "pipe", stderr: "pipe",
    });
    const [code, output, error] = await Promise.all([
        child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    assert.equal(code, 0, `${args[0]} failed: ${error}`);
    return JSON.parse(output);
}
const settle = id => lab.waitFor(async () => {
    const view = await agent("read", id);
    return view.job.execution.kind === "terminal" ? view : null;
});
let failure;
let stage = "gateway startup";
let observedJob;
const checkpoint = name => { stage = name; console.log(`agent-api: ${name}`); };
try {
    await mkdir(lab.path("work"));
    await mkdir(lab.path(".claude"));
    await installPackage(lab, runtimePackage);
    await writeProviderConfig(lab, model);
    await lab.writeGatewayEnv(["RC_CLAUDE_ENABLED=false", `RC_CLAUDE_HOME=${lab.path(".claude")}`,
        `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`]);
    await lab.start();
    checkpoint("agent ID after Continue");
    const self = (await agent("cluster", "list")).self;
    const admitted = await agent("spawn", "codex", "rcjob-mock", "RCJOB_ECHO:first", "--operator", "--host", self.name);
    assert.equal(admitted.detailsLoaded, true);
    const first = await settle(admitted.jobId);
    assert.equal(first.status, "completed");
    assert.equal(first.resultText, "RCJOB_RESULT:first");
    assert.equal(first.delivery, null);
    const continued = await agent("spawn", "--resume", first.agentId, "RCJOB_ECHO:second", "--operator");
    const second = await settle(continued.jobId);
    assert.equal(second.resultText, "RCJOB_RESULT:second");
    const sent = await agent("message", first.agentId, "RCJOB_ECHO:third", "--operator", "--delivery-id", "agent-after-continue");
    assert.equal(sent.deliveryState.kind, "accepted");
    assert.equal(sent.resolved.targetJobId, second.jobId);
    const third = await settle(sent.resolved.continuation.jobId);
    assert.equal(third.status, "completed");
    assert.equal(third.resultText, "RCJOB_RESULT:third");
    assert.equal(third.agentId, first.agentId);
    assert.equal(third.provider_session_id, first.provider_session_id);
    assert.deepEqual(await agent("message", first.agentId, "RCJOB_ECHO:third", "--operator", "--delivery-id", "agent-after-continue"), sent);
    const historical = await agent("list", first.jobId);
    assert.equal(historical.jobId, first.jobId);
    assert.equal(historical.latestJobId, third.jobId);
    assert.equal(historical.resultText, "RCJOB_RESULT:first");
    const page = await agent("list", "--host", self.name, "--local", "--last", "3");
    assert.equal(page.coverage[0].state, "ok");
    assert(page.agents.every(row => row.detailsLoaded === false && row.result.kind === "notLoaded"));
    const client = await lab.connect();
    const rpc = async (method, params) => {
        const response = await client.rpc(method, params);
        assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
        return response.result;
    };
    const nativeThread = async () => (await rpc("thread/start", {
        cwd: lab.path("work"), model: "rcjob-mock", modelProvider: "probe",
    })).thread.id;
    const nativeTurn = (threadId, text, clientId) => rpc("turn/start", {
        threadId, clientId, input: [{ type: "text", text, text_elements: [] }],
    });
    const waitNative = threadId => lab.waitFor(async () => {
        const turns = await rpc("thread/turns/list", { threadId, limit: 1, sortDirection: "desc", itemsView: "notLoaded" });
        return turns.data[0]?.status === "completed" ? turns.data[0] : null;
    });
    const nativeJobs = async thread => (await agent("list", "--local", "--last", "20")).agents
        .filter(row => row.provider_session_id === thread && row.jobId);
    const parent = await nativeThread();
    await nativeTurn(parent, "RCJOB_ECHO:native-parent", "native-parent-input");
    await waitNative(parent);
    const adopted = await nativeThread();
    checkpoint("adopt running native turn");
    await nativeTurn(adopted, "RCJOB_HOLD:native-running", "native-running-input");
    await lab.waitFor(() => model.requests.some(request => request.name === "native-running"));
    await agent("set-parent", adopted, parent, "--operator");
    const adoptedJob = await lab.waitFor(async () => (await nativeJobs(adopted))[0] ?? null);
    observedJob = adoptedJob.jobId;
    model.release("native-running");
    checkpoint("native adoption completion");
    const adoptionResult = await settle(adoptedJob.jobId);
    assert.equal(adoptionResult.resultText, "RCJOB_RESULT:native-running");
    assert.equal(adoptionResult.job.spec.kind, "unknown");
    const callback = id => lab.waitFor(async () => {
        const items = await rpc("thread/items/list", { threadId: parent, limit: 100, sortDirection: "desc" });
        return JSON.stringify(items.data).includes(`${id}:completion`);
    });
    await callback(adoptedJob.jobId);
    checkpoint("app turn without a callback");
    await waitNative(parent);
    await nativeTurn(adopted, "RCJOB_ECHO:app-initiated", "app-initiated-input");
    await waitNative(adopted);
    assert.equal((await nativeJobs(adopted)).length, 1);
    const command = [binary, "--env-file", lab.path("gateway.env"), "agent", "message", adopted,
        "RCJOB_HOLD:parent-input", "--delivery-id", "adopted-parent-input", "--json"]
        .map(part => `'${part.replaceAll("'", "'\\''")}'`).join(" ");
    await nativeTurn(parent, `RCJOB_SPAWN:${Buffer.from(command).toString("base64url")}`, "parent-tool-input");
    checkpoint("parent input creates a native job");
    await lab.waitFor(() => model.requests.some(request => request.name === "parent-input"));
    const parentJob = await lab.waitFor(async () => (await nativeJobs(adopted)).find(row => row.jobId !== adoptedJob.jobId) ?? null);
    observedJob = parentJob.jobId;
    await lab.waitFor(async () => (await agent("read", parentJob.jobId)).job.execution.kind === "running");
    checkpoint("steering retains the completion obligation");
    await agent("message", parentJob.jobId, "RCJOB_ECHO:steer", "--operator", "--delivery-id", "adopted-steer");
    model.release("parent-input");
    const parentResult = await settle(parentJob.jobId);
    assert.equal(parentResult.job.spec.kind, "unknown");
    await callback(parentJob.jobId);
    assert.equal((await nativeJobs(adopted)).length, 2);
    client.ws.close();
    console.log(JSON.stringify({ passed: true, jobs: [first.jobId, second.jobId, third.jobId],
        agentId: first.agentId, threadId: third.provider_session_id, sameReceipt: true,
        selfHost: self.name, topLevelLifecycle: true, nativeJobs: [adoptedJob.jobId, parentJob.jobId],
        nativeCallbacks: 2, appTurnWithoutCallback: true, steeringRetainsObligation: true }));
} catch (error) {
    failure = new Error(`Agent API probe failed during ${stage}`, { cause: error });
    if (observedJob) {
        try {
            const { job } = await agent("read", observedJob);
            console.error(JSON.stringify({ jobId: job.jobId, execution: job.execution.kind,
                reason: job.execution.reason, outcome: job.execution.terminal?.outcome,
                delivery: job.execution.terminal?.completion?.delivery }));
        } catch {}
    }
} finally {
    try { await lab.stop(); } catch (error) { failure ??= error; await lab.forceStop(); }
    try {
        if (await lab.hasNativeDaemon(lab.nativeDefault)) assert.equal(await lab.stopNativeDaemon(lab.nativeDefault), 0);
    } catch (error) { failure ??= error; }
    model.server.stop(true);
    lab.router?.stop(true);
    await lab.removeRoot();
}
if (failure) throw failure;
