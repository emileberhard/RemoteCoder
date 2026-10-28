import assert from "node:assert/strict";
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";
import { installPackage, startModel, writeProviderConfig } from "./delegated-model.mjs";

const [binary, runtimePackage] = process.argv.slice(2);
assert(isAbsolute(binary) && isAbsolute(runtimePackage), "Pass absolute candidate and matched runtime package paths");
const lab = await IsolatedGateway.create(binary);
const model = startModel();
let failure;
const rpc = async (client, method, params) => {
    const response = await client.rpc(method, params);
    assert(!response.error, JSON.stringify(response.error));
    return response.result;
};
const measure = async (client, method, params) => {
    const samples = [];
    let responseBytes;
    for (let sequence = 0; sequence < 55; sequence++) {
        const start = performance.now();
        const page = await rpc(client, method, params);
        const elapsed = performance.now() - start;
        if (sequence === 0) responseBytes = Buffer.byteLength(JSON.stringify(page));
        if (method === "thread/list") assert.equal(page.data.length, 32);
        if (sequence >= 5) samples.push(elapsed);
    }
    samples.sort((a, b) => a - b);
    return { responseBytes, samples: samples.length, medianMs: samples[Math.floor(samples.length / 2)],
        p95Ms: samples[Math.floor(samples.length * .95)] };
};
try {
    await mkdir(lab.path("work"), { recursive: true });
    await installPackage(lab, runtimePackage);
    await writeProviderConfig(lab, model);
    await lab.writeGatewayEnv([
        `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`,
        "RC_CLAUDE_ENABLED=false", `RC_CLAUDE_HOME=${lab.path(".claude")}`,
    ]);
    await lab.start();
    let client = await lab.connect();
    const threads = [];
    for (let batch = 0; batch < 2; batch++) {
        threads.push(...await Promise.all(Array.from({ length: 16 }, () => rpc(client, "thread/start", {
            cwd: lab.path("work"), model: "rcjob-mock", modelProvider: "probe",
        }))));
    }
    for (let offset = 0; offset < threads.length; offset += 16) {
        await Promise.all(threads.slice(offset, offset + 16).map((response, index) => rpc(client, "turn/start", {
            threadId: response.thread.id,
            input: [{ type: "text", text: `RCJOB_ECHO:latency-${offset + index}`, text_elements: [] }],
        })));
    }
    await lab.waitFor(async () => {
        const page = await rpc(client, "thread/list", { limit: 100, modelProviders: [], useStateDbOnly: true });
        return page.data.length === 32 && page.data.every(thread => thread.status?.type === "idle");
    });
    const threadId = threads[0].thread.id;
    const header = await rpc(client, "thread/read", { threadId, includeTurns: true });
    const rollout = header.thread.path;
    assert(typeof rollout === "string" && resolve(rollout).startsWith(lab.root + "/"),
        "Probe rollout must belong to the isolated home");
    await lab.stop();
    await lab.stopNativeDaemon(lab.nativeDefault);
    const records = (await readFile(rollout, "utf8")).split("\n").filter(Boolean).map(JSON.parse);
    const message = records.findLast(row => row.type === "response_item" && row.payload?.role === "assistant");
    assert(message, "Native fixture did not persist an assistant response");
    await appendFile(rollout, JSON.stringify({ ...message, payload: { ...message.payload,
        content: [{ type: "output_text", text: "x".repeat(11 * 1024 * 1024) }] } }) + "\n");
    const store = lab.path(".remote-coder/agent-jobs/v1");
    await Promise.all([mkdir(`${store}/jobs`, { recursive: true }), mkdir(`${store}/agents`, { recursive: true })]);
    await Promise.all(Array.from({ length: 1000 }, async (_, sequence) => {
        const id = `agent-codex-1793127141860775000-${sequence.toString(16).padStart(8, "0")}`;
        const unknown = { kind: "unknown", reason: "isolated latency fixture" };
        const record = { jobId: id, agentId: id, requestFingerprint: null, createdAtMs: null, updatedAtMs: 100,
            revision: 0, previousJobId: null, providerRetries: [], source: "imported",
            admissionOrigin: { kind: "topLevel" }, unconfirmedResult: null, notices: [], spec: unknown,
            recipient: { kind: "none" }, execution: { ...unknown, conversation: null, binding: null },
            stop: { kind: "notRequested" } };
        const agent = { agentId: id, conversation: unknown, origin: { kind: "topLevel" }, toolScope: null,
            originJobId: id, latestJobId: id };
        await Promise.all([writeFile(`${store}/jobs/${id}.json`, JSON.stringify(record), { mode: 0o600 }),
            writeFile(`${store}/agents/${createHash("sha256").update(id).digest("hex")}.json`,
                JSON.stringify(agent), { mode: 0o600 })]);
    }));
    await lab.start();
    client = await lab.connect();
    const list = await measure(client, "thread/list", { limit: 100, modelProviders: [], useStateDbOnly: true });
    const read = await measure(client, "thread/read", { threadId, includeTurns: true });
    assert(read.responseBytes > 10 * 1024 * 1024, `Transcript response is only ${read.responseBytes} bytes`);
    console.log(JSON.stringify({ binary, threads: 32, jobs: 1000, list, read }));
} catch (error) { failure = error; }
finally {
    const errors = [];
    for (const cleanup of [() => lab.stop(), () => lab.forceStop(), () => lab.stopNativeDaemon(lab.nativeDefault),
        () => model.server.stop(true), () => lab.router?.stop(true), () => failure ? Promise.resolve() : lab.removeRoot()]) {
        try { await cleanup(); } catch (error) { errors.push(String(error)); }
    }
    if (errors.length) throw new AggregateError([failure, ...errors].filter(Boolean), "Latency probe cleanup failed");
}
if (failure) { console.error(`Retained isolated latency evidence: ${lab.root}`); throw failure; }
