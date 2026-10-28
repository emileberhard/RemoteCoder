import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";
import { installPackage, startModel, writeProviderConfig } from "./delegated-model.mjs";

const [binary, runtimePackage, receiptPath] = process.argv.slice(2);
assert(binary && runtimePackage && receiptPath && [binary, runtimePackage, receiptPath].every(isAbsolute),
    "Pass absolute candidate, matched runtime package and receipt paths");
const lab = await IsolatedGateway.create(binary);
const model = startModel();
const receipt = { binary, binarySha256: createHash("sha256").update(await readFile(binary)).digest("hex"),
    runtimePackage, fixture: { importedJobs: 1024, nativeSessions: 1001, measuredNativeRows: 1000 },
    startedAt: new Date().toISOString(), samples: [], setup: [] };
let failure;
let phase = "setup";
const rpc = async (client, method, params) => {
    const response = await client.rpc(method, params);
    assert(!response.error, JSON.stringify({ method, error: response.error }));
    return response.result;
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
    const started = await rpc(client, "thread/start", {
        cwd: lab.path("work"), model: "rcjob-mock", modelProvider: "probe",
    });
    const seedId = started.thread.id;
    await rpc(client, "turn/start", { threadId: seedId,
        input: [{ type: "text", text: "RCJOB_ECHO:inventory-latency", text_elements: [] }] });
    const deadline = Date.now() + 60000;
    let header;
    while (Date.now() < deadline) {
        header = await rpc(client, "thread/read", { threadId: seedId, includeTurns: true });
        if (header.thread.turns?.some(turn => turn.status === "completed")) break;
        await Bun.sleep(100);
    }
    assert(header.thread.turns?.some(turn => turn.status === "completed"), "Seed turn did not complete");
    const rollout = header.thread.path;
    assert(typeof rollout === "string" && resolve(rollout).startsWith(lab.root + "/"));
    await lab.stop();
    assert.equal(await lab.stopNativeDaemon(lab.nativeDefault), 0);
    const metadata = (await readFile(rollout, "utf8")).split("\n").filter(Boolean).map(JSON.parse)
        .find(row => row.type === "session_meta");
    assert(metadata, "Native fixture is missing session_meta");
    const sessions = lab.path(".codex/sessions/2026/01/01");
    const store = lab.path(".remote-coder/agent-jobs/v1");
    await Promise.all([sessions, `${store}/jobs`, `${store}/agents`].map(path => mkdir(path, { recursive: true })));
    const nativeIds = [seedId, ...Array.from({ length: 1000 }, (_, index) =>
        `00000000-0000-4000-8000-${(index + 1).toString(16).padStart(12, "0")}`)];
    for (let offset = 0; offset < nativeIds.length; offset += 64) {
        await Promise.all(nativeIds.slice(offset, offset + 64).map(async (threadId, index) => {
            const sequence = offset + index;
            const agentId = `adopted-inventory-${String(sequence).padStart(4, "0")}`;
            const conversation = { provider: "codex", providerHome: { kind: "known", path: lab.nativeDefault }, threadId };
            const agent = { agentId, conversation: { kind: "known", conversation }, origin: { kind: "topLevel" },
                toolScope: null, originJobId: null, latestJobId: null };
            const writes = [writeFile(`${store}/agents/${createHash("sha256").update(agentId).digest("hex")}.json`,
                JSON.stringify(agent), { mode: 0o600 })];
            if (threadId !== seedId) {
                const row = structuredClone(metadata);
                row.timestamp = "2026-01-01T00:00:00.000Z";
                row.payload.id = threadId;
                if ("session_id" in row.payload) row.payload.session_id = threadId;
                row.payload.timestamp = "2026-01-01T00:00:00.000Z";
                writes.push(writeFile(`${sessions}/rollout-2026-01-01T00-00-00-${threadId}.jsonl`,
                    JSON.stringify(row) + "\n", { mode: 0o600 }));
            }
            await Promise.all(writes);
        }));
    }
    for (let offset = 0; offset < 1024; offset += 64) {
        await Promise.all(Array.from({ length: 64 }, async (_, index) => {
            const id = `agent-codex-1793127141860775000-${(offset + index).toString(16).padStart(8, "0")}`;
            const unknown = { kind: "unknown", reason: "isolated inventory latency fixture" };
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
    }
    phase = "projection-settle";
    await lab.start();
    client = await lab.connect();
    let count = 0;
    const settleDeadline = Date.now() + 90000;
    while (Date.now() < settleDeadline) {
        const result = await rpc(client, "sessions/sql", { sql: "SELECT COUNT(*) FROM session" });
        count = result.rows[0][0];
        receipt.setup.push({ sessionCount: count });
        if (count === nativeIds.length) break;
        await Bun.sleep(250);
    }
    assert.equal(count, nativeIds.length, "Session projection did not settle");
    phase = "job-pages";
    let cursor = null;
    for (let page = 0; page < 4; page++) {
        const result = await rpc(client, "agent/cluster/inventory", { limit: 256, cursor });
        assert.equal(result.agents.length, 256);
        assert(result.agents.every(entry => entry.row.run_id && entry.row.agent_id.startsWith("agent-codex-")));
        cursor = result.nextCursor;
        assert(cursor);
    }
    const decoded = JSON.parse(Buffer.from(cursor, "base64url").toString());
    assert.equal(decoded.jobsDone, true);
    assert.equal(decoded.sessions, null);
    const first = await rpc(client, "sessions/sql", {
        sql: "SELECT session_key,thread_id FROM session ORDER BY session_key LIMIT 1",
    });
    const [firstSessionKey, skippedThreadId] = first.rows[0];
    decoded.sessions = firstSessionKey;
    const measuredCursor = Buffer.from(JSON.stringify(decoded)).toString("base64url");
    const expectedIds = nativeIds.filter(id => id !== skippedThreadId).sort();
    receipt.fixture.skippedThreadId = skippedThreadId;
    receipt.fixture.cursorStartsAfterFirstSession = true;
    const validate = page => {
        assert.equal(page.agents.length, 1000);
        assert.equal(page.nextCursor, null);
        assert.deepEqual(page.agents.map(entry => entry.row.provider_session_id).sort(), expectedIds);
        assert(page.agents.every(entry => entry.row.run_id === null && entry.row.agent_id?.startsWith("adopted-inventory-")
            && entry.row.provider === "codex" && entry.row.conversation.kind === "known"));
    };
    phase = "warmup";
    for (let index = 0; index < 2; index++) {
        validate(await rpc(client, "agent/cluster/inventory", { limit: 1000, cursor: measuredCursor }));
    }
    phase = "measurement";
    for (let index = 0; index < 20; index++) {
        const start = performance.now();
        const page = await rpc(client, "agent/cluster/inventory", { limit: 1000, cursor: measuredCursor });
        const elapsedMs = performance.now() - start;
        validate(page);
        receipt.samples.push({ sequence: index, elapsedMs, rows: page.agents.length,
            responseBytes: Buffer.byteLength(JSON.stringify(page)) });
    }
    const sorted = receipt.samples.map(sample => sample.elapsedMs).sort((a, b) => a - b);
    receipt.summary = { samples: sorted.length, medianMs: (sorted[9] + sorted[10]) / 2,
        p95Ms: sorted[18], rows: 1000, responseBytes: receipt.samples[0].responseBytes };
} catch (error) {
    failure = error;
    receipt.error = { phase, message: String(error), stack: error.stack };
} finally {
    const errors = [];
    for (const cleanup of [() => lab.stop(), () => lab.forceStop(), () => lab.stopNativeDaemon(lab.nativeDefault),
        () => model.server.stop(true), () => lab.router?.stop(true), () => lab.removeRoot()]) {
        try { await cleanup(); } catch (error) { errors.push(String(error)); }
    }
    receipt.cleanupErrors = errors;
    receipt.finishedAt = new Date().toISOString();
    await writeFile(receiptPath, JSON.stringify(receipt, null, 2) + "\n", { mode: 0o600 });
    if (errors.length) throw new AggregateError([failure, ...errors].filter(Boolean), "Inventory latency cleanup failed");
}
if (failure) throw failure;
console.log(JSON.stringify(receipt.summary));
