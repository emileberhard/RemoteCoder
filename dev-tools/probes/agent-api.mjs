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
try {
    await mkdir(lab.path("work"));
    await mkdir(lab.path(".claude"));
    await installPackage(lab, runtimePackage);
    await writeProviderConfig(lab, model);
    await lab.writeGatewayEnv(["RC_CLAUDE_ENABLED=false", `RC_CLAUDE_HOME=${lab.path(".claude")}`,
        `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`]);
    await lab.start();
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
    console.log(JSON.stringify({ passed: true, jobs: [first.jobId, second.jobId, third.jobId],
        agentId: first.agentId, threadId: third.provider_session_id, sameReceipt: true,
        selfHost: self.name, topLevelLifecycle: true }));
} catch (error) {
    failure = error;
} finally {
    try { await lab.stop(); } catch (error) { failure ??= error; await lab.forceStop(); }
    if (await lab.hasNativeDaemon(lab.nativeDefault)) await lab.stopNativeDaemon(lab.nativeDefault);
    model.server.stop(true);
    lab.router?.stop(true);
    await lab.removeRoot();
}
if (failure) throw failure;
