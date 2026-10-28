import assert from "node:assert/strict";
import { cp, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomBytes, randomInt, randomUUID } from "node:crypto";
import { IsolatedGateway, startStubRouter } from "./isolated-gateway.mjs";
import { installSeed, inspectSeed } from "./delegated-job-seed.mjs";

const [binary, runtimePackage, ...options] = process.argv.slice(2);
assert(options.length === 0 || options.length === 2 && options[0] === "--seed" && isAbsolute(options[1]),
    "Optional --seed requires an absolute private seed manifest path");
const seedPath = options[1];
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
assert(runtimePackage && isAbsolute(runtimePackage), "Pass the matched Codex runtime package directory");

import { startModel, installPackage, writeProviderConfig } from "./delegated-model.mjs";
const probeModel="rcjob-mock";
const probeProvider="probe";
const newJobId = provider => `agent-${provider}-${BigInt(Date.now()) * 1_000_000n + BigInt(randomInt(1_000_000))}-${randomBytes(4).toString("hex")}`;

async function hostRouter() {
    const env = await readFile(join(process.env.HOME, ".remote-coder/codex-gateway.env"), "utf8");
    const value = name => env.match(new RegExp(`^${name}="?([^"\\n]+)"?$`, "m"))?.[1];
    const url = value("RC_CODEX_GATEWAY_ROUTER_URL");
    const keyFile = value("RC_CODEX_GATEWAY_ROUTER_KEY_FILE");
    assert(url && keyFile, "The host gateway has no router for Claude inference");
    return { url, key: (await readFile(keyFile, "utf8")).trim() };
}

async function prepare(lab, model, inference) {
    await mkdir(lab.path(".claude"), { recursive: true });
    await mkdir(lab.path("work"), { recursive: true });
    await installPackage(lab,runtimePackage);
    await writeProviderConfig(lab, model);
    lab.router = startStubRouter(inference);
    await lab.writeGatewayEnv([
        `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`,
        "RC_CLAUDE_ENABLED=true",
        `RC_CLAUDE_HOME=${lab.path(".claude")}`,
        `RC_CLAUDE_PATH=${join(lab.realHome, ".local/bin/claude")}`,
    ]);
}

async function agent(lab, args, { allowFailure = false } = {}) {
    const child = Bun.spawn([binary, "--env-file", lab.path("gateway.env"), "agent", ...args], {
        env: lab.safeEnv, cwd: lab.path("work"), stdout: "pipe", stderr: "pipe",
    });
    const [status, stdout, stderr] = await Promise.all([
        child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    if (allowFailure) return { status, stdout, stderr };
    assert.equal(status, 0, `agent ${args[0]} failed: ${stderr.trim()}`);
    return JSON.parse(stdout);
}

const read = async (lab, jobId) => (await agent(lab, ["read", jobId, "--json"])).job;

async function settle(lab, jobId, predicate, seconds = 120) {
    return await lab.waitFor(async () => {
        const job = await read(lab, jobId);
        return predicate(job) ? job : null;
    }, seconds);
}

const terminal = job => job.execution.kind === "terminal" ? job.execution.terminal : null;
const delivered = job => ["accepted", "recorded"].includes(terminal(job)?.completion?.delivery?.kind);
const running = job => job.execution.kind === "running";

async function parentItems(client, threadId) {
    const page = await client.rpc("thread/items/list", { threadId, limit: 100, sortDirection: "desc" });
    assert(!page.error, `thread/items/list failed: ${JSON.stringify(page.error)}`);
    return JSON.stringify(page.result.data);
}

async function runtimeFlows(lab, model) {
    const receipt = {};
    const client = await lab.connect();
    const started = await client.rpc("thread/start", { cwd: lab.path("work"), model: probeModel,
        modelProvider: probeProvider });
    assert(!started.error, `thread/start failed: ${JSON.stringify(started.error)}`);
    const parent = started.result.thread.id;
    receipt.parent = parent;
    const childIds = new Set();
    const spawn = (provider, model, prompt) => {
        const id = newJobId(provider);
        childIds.add(id);
        return [binary, "--env-file", lab.path("gateway.env"), "agent", "spawn", provider,
        model, prompt, "--job-id", id, "--json"].map(part => `'${part.replaceAll("'", "'\\''")}'`).join(" ");
    };
    const command = [
        spawn("codex", probeModel, "RCJOB_ECHO:codex-child"),
        spawn("claude", "sonnet", "Reply with exactly RCJOB_RESULT:claude-child and nothing else. Do not use tools."),
    ].join(" && ");
    const turn = await client.rpc("turn/start", { threadId: parent,
        input: [{ type: "text", text: `RCJOB_SPAWN:${Buffer.from(command).toString("base64url")}`, text_elements: [] }] });
    assert(!turn.error, `parent turn/start failed: ${JSON.stringify(turn.error)}`);

    const children = await lab.waitFor(async () => {
        const list = await agent(lab, ["list", "--json", "--last", "10"]);
        const rows = list.agents.filter(row => childIds.has(row.run_id));
        return rows.length >= 2 ? rows : null;
    }, 120);
    for (const provider of ["codex", "claude"]) {
        const row = children.find(entry => entry.provider === provider);
        assert(row, `No ${provider} child was admitted from the parent's tool process`);
        const job = await settle(lab, row.run_id, delivered, 240);
        const result = JSON.stringify(terminal(job).result);
        assert.equal(terminal(job).outcome.kind, "completed", `${provider} child did not complete`);
        assert(result.includes(`RCJOB_RESULT:${provider}-child`), `${provider} child result is missing its marker`);
        receipt[`${provider}Child`] = { jobId: row.run_id, origin: job.admissionOrigin,
            delivery: terminal(job).completion.delivery.kind };
    }
    const items = await lab.waitFor(async () => {
        const text = await parentItems(client, parent);
        return children.every(row => text.includes(`${row.run_id}:completion`)) ? text : null;
    }, 120);
    receipt.parentCallbacks = children.map(row => items.includes(`${row.run_id}:completion`));

    receipt.runningMessage = await runningMessageFlow(lab, model);
    receipt.messages = await messageFlows(lab, receipt.codexChild.jobId);
    receipt.scopedTitle = await scopedTitleFlow(lab, receipt.codexChild.jobId, parent);

    const stopId = newJobId("codex");
    await agent(lab, ["spawn", "codex", probeModel, "RCJOB_HOLD:stop-child", "--job-id", stopId, "--operator", "--json"]);
    await settle(lab, stopId, running);
    await agent(lab, ["stop", stopId]);
    const stopped = await settle(lab, stopId, job => terminal(job) !== null);
    assert.equal(terminal(stopped).outcome.kind, "stopped", "Stop did not end the running child");
    model.release("stop-child");
    receipt.stop = terminal(stopped).outcome;

    const restartId = newJobId("codex");
    await agent(lab, ["spawn", "codex", probeModel, "RCJOB_HOLD:restart-child", "--job-id", restartId, "--operator", "--json"]);
    const before = await settle(lab, restartId, running);
    await lab.stop();
    await lab.start();
    const after = await read(lab, restartId);
    assert.equal(after.execution.kind === "terminal", false, "Restart finalized a job the provider had not finished");
    model.release("restart-child");
    const finished = await settle(lab, restartId, job => terminal(job) !== null);
    assert.equal(terminal(finished).outcome.kind, "completed", "The interrupted child did not resume to completion");
    assert.equal(terminal(finished).execution.turnId, before.execution.binding.turnId, "Recovery switched to a different turn");
    const dispatches = model.requests.filter(entry => entry.name === "restart-child").length;
    receipt.restart = { stateAfterRestart: after.execution.kind, turnId: before.execution.binding.turnId, modelRequests: dispatches };

    const duplicate = await agent(lab, ["spawn", "codex", probeModel, "RCJOB_HOLD:restart-child", "--job-id", restartId, "--operator", "--json"]);
    receipt.idempotentRetry = duplicate;
    return receipt;
}

async function cwdResumeFlow(lab, jobId) {
    const job = await settle(lab, jobId, job => terminal(job)?.cleanup === "complete");
    const threadId = terminal(job).execution.conversation.threadId;
    assert(threadId.startsWith("claude_"));
    const session = threadId.slice(7);
    await lab.stop();
    const projects = lab.path(".claude/projects");
    const candidates = await Promise.all((await readdir(projects)).map(async directory => {
        const path = join(projects, directory, `${session}.jsonl`);
        return await Bun.file(path).exists() ? path : null;
    }));
    const found = candidates.filter(Boolean);
    assert.equal(found.length, 1, "Completed isolated Claude child has ambiguous transcript identity");
    const original = found[0];
    assert(Bun.file(original).size <= 16 * 1024 * 1024, "Isolated child transcript exceeds the copy bound");
    const rows = (await readFile(original, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line));
    const missingCwd = lab.path("work/removed-worktree");
    assert(!(await Bun.file(missingCwd).exists()), "Missing-cwd fixture unexpectedly exists");
    const firstUser = rows.find(row => row.type === "user" && row.sessionId === session && row.cwd);
    assert(firstUser, "Isolated Claude transcript has no authoritative cwd record");
    firstUser.cwd = missingCwd;
    assert(rows.some(row => row.type === "assistant" && row.sessionId === session && row.cwd === lab.path("work")),
        "Copied transcript lacks evidence for the existing replacement directory");
    const project = join(projects, missingCwd.replace(/[^a-zA-Z0-9]/g, "-"));
    await mkdir(project, { recursive: true });
    const copied = join(project, `${session}.jsonl`);
    await writeFile(copied, rows.map(row => JSON.stringify(row)).join("\n") + "\n", { mode: 0o600, flag: "wx" });
    await rm(original);
    await lab.start();
    const client = await lab.connect();
    const inputId = randomUUID();
    const marker = `RCJOB_CWD_RESUMED_${randomUUID()}`;
    const response = await client.rpc("turn/start", { threadId, cwd: missingCwd, model: "sonnet",
        clientUserMessageId: inputId,
        input: [{ type: "text", text: `Reply with exactly ${marker} and nothing else. Do not use tools.`, text_elements: [] }] });
    assert(!response.error, `Deleted-cwd copied transcript did not resume: ${JSON.stringify(response.error)}`);
    const turnId = response.result.turn.id;
    const evidence = await lab.waitFor(async () => {
        const records = (await readFile(copied, "utf8")).trimEnd().split("\n").flatMap(line => {
            try { return [JSON.parse(line)]; } catch { return []; }
        });
        const input = records.findIndex(row => row.type === "user" && row.sessionId === session && row.uuid === inputId);
        if (input < 0) return null;
        const answer = records.slice(input + 1).find(row => row.type === "assistant" && row.sessionId === session
            && (row.message?.content ?? []).some(part => part.type === "text" && part.text.includes(marker)));
        return answer ? { inputUuid: records[input].uuid, answerUuid: answer.uuid, sessionId: answer.sessionId, cwd: answer.cwd } : null;
    }, 120);
    assert.equal(evidence.sessionId, session, "Resume forked or replaced the exact isolated session");
    assert.equal(evidence.cwd, lab.path("work"), "Resumed process did not use the proven replacement cwd");
    assert(!(await Bun.file(original).exists()), "Resume wrote a second transcript instead of the exact copied path");
    await lab.waitFor(async () => {
        const active = await client.rpc("daemon/activeTurns");
        assert(!active.error);
        return !active.result.activeTurns.some(turn => turn.threadId === threadId);
    });
    const released = await client.rpc("claude/thread/release", { threadId });
    assert(!released.error);
    await lab.stop();
    const jobPath = lab.path(`.remote-coder/agent-jobs/v1/jobs/${jobId}.json`);
    const imported = JSON.parse(await readFile(jobPath, "utf8"));
    const originalScope = imported.spec.spec.toolScope;
    imported.source = "imported";
    imported.spec = { kind: "unknown", reason: "Isolated historical-settings reconstruction fixture" };
    await writeFile(jobPath, JSON.stringify(imported), { mode: 0o600 });
    await lab.start();
    const continuationId = newJobId("claude");
    const importedMarker = `RCJOB_IMPORTED_RESUMED_${randomUUID()}`;
    await agent(lab, ["spawn", "--resume", jobId, `Reply with exactly ${importedMarker} and nothing else. Do not use tools.`,
        "--job-id", continuationId, "--operator", "--json"]);
    const continued = await settle(lab, continuationId, job => terminal(job)?.cleanup === "complete", 180);
    assert.equal(terminal(continued).outcome.kind, "completed");
    assert.deepEqual(terminal(continued).execution.conversation, terminal(job).execution.conversation,
        "Imported settings reconstruction switched provider conversation or home");
    assert.deepEqual(continued.spec.spec.toolScope, originalScope, "Imported Continue changed permission scope");
    const continuedRecords = (await readFile(copied, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line));
    const continuedInput = continuedRecords.findIndex(row => row.type === "user" && row.sessionId === session
        && row.uuid === terminal(continued).execution.inputId);
    assert(continuedInput >= 0, "Imported Continue input was not consumed by the exact copied transcript");
    assert(continuedRecords.slice(continuedInput + 1).some(row => row.type === "assistant" && row.sessionId === session
        && (row.message?.content ?? []).some(part => part.type === "text" && part.text.includes(importedMarker))),
        "Imported Continue response was absent from the exact copied transcript");
    assert(!(await Bun.file(original).exists()), "Imported Continue wrote another transcript path");
    return { threadId, turnId, ...evidence, originalTask: "completed isolated probe child",
        copiedTranscript: true, changedFixtureFields: ["first user cwd", "project directory"], exactCopiedPath: true,
        importedContinue: { jobId: continuationId, previousJobId: jobId,
            changedFixtureFields: ["job source", "execution settings evidence"], inputId: terminal(continued).execution.inputId,
            sameConversation: true, sameScope: true, exactCopiedPath: true } };
}

async function runningMessageFlow(lab, model) {
    const jobId = newJobId("codex");
    const holdName = `running-message-${randomUUID()}`;
    const messageName = `steer-${randomUUID()}`;
    const text = `RCJOB_ECHO:${messageName}`;
    const deliveryId = randomUUID();
    await agent(lab, ["spawn", "codex", probeModel, `RCJOB_HOLD:${holdName}`, "--job-id", jobId,
        "--operator", "--json"]);
    const before = await settle(lab, jobId, running);
    const { conversation, turnId } = before.execution.binding;
    await lab.waitFor(() => model.requests.some(request => request.name === holdName), 120);
    const client = await lab.connect();
    try {
        const args = ["message", jobId, text, "--delivery-id", deliveryId, "--operator", "--json"];
        const first = await agent(lab, args);
        assert(["accepted", "recorded"].includes(first.deliveryState.kind), "Running message was not admitted");
        assert.equal(first.resolved.targetJobId, jobId);
        assert.equal(first.resolved.continuation, null, "Running message admitted a successor job");
        assert.deepEqual(await agent(lab, args), first, "Same-ID running message changed its receipt");
        model.release(holdName);
        const canonical = await lab.waitFor(async () => {
            const reply = await client.rpc("thread/items/list", { threadId: conversation.threadId, limit: 100,
                sortDirection: "desc" });
            assert(!reply.error, `Running message items failed: ${JSON.stringify(reply.error)}`);
            return reply.result.data.find(entry => entry.item.type === "userMessage"
                && entry.item.clientId === deliveryId && entry.item.content.some(part => part.type === "text" && part.text === text));
        }, 120);
        assert.equal(canonical.turnId, turnId, "Running message landed in a different native turn");
        const ended = await settle(lab, jobId, job => terminal(job) !== null);
        assert.equal(terminal(ended).execution.turnId, turnId, "Running message replaced its job's turn");
        assert(model.requests.some(request => request.name === messageName && request.kind === "ECHO"),
            "The running model never received the message body");
        assert.deepEqual(await agent(lab, args), first, "Accepted message replayed after its turn ended");
        return { jobId, threadId: conversation.threadId, turnId, deliveryId,
            deliveryState: first.deliveryState.kind, canonicalTurnId: canonical.turnId,
            modelReceived: true, sameIdReceiptUnchanged: true };
    } finally {
        model.release(holdName);
        client.ws.close();
    }
}

async function messageFlows(lab, finishedJob) {
    await settle(lab, finishedJob, job => terminal(job)?.cleanup === "complete");
    const deliveryId = randomUUID();
    const args = ["message", finishedJob, "RCJOB_ECHO:message-continuation", "--delivery-id", deliveryId, "--operator", "--json"];
    const first = await agent(lab, args);
    assert.equal(first.deliveryState.kind, "accepted", "Message to a finished job was not admitted as a continuation");
    const successor = first.resolved?.continuation?.jobId;
    assert(successor, "Message receipt has no exact continuation job ID");
    const duplicate = await agent(lab, args);
    assert.equal(duplicate.resolved.continuation.jobId, successor, "Duplicate message admitted another continuation");
    const completed = await settle(lab, successor, job => terminal(job) !== null);
    assert.equal(terminal(completed).outcome.kind, "completed");
    assert(JSON.stringify(terminal(completed).result).includes("RCJOB_RESULT:message-continuation"));
    const afterCompletion = await agent(lab, args);
    assert.equal(afterCompletion.resolved.continuation.jobId, successor, "Retry after completion followed the newer job");
    const stored = await agent(lab, ["receipt", deliveryId, "--json"]);
    assert.deepEqual(stored, first, "Stored accepted message receipt changed after duplicate requests");
    const list = await agent(lab, ["list", "--json", "--last", "20"]);
    const related = list.agents.filter(row => row.run_id === successor);
    assert.equal(related.length, 1, "The continuation was missing or duplicated in the real list");

    const unreachableId = randomUUID();
    const unreachableSession = randomUUID();
    const unreachableTarget = `claude_${unreachableSession}`;
    const project = lab.path(`.claude/projects/${lab.path("work").replace(/[^a-zA-Z0-9]/g, "-")}`);
    await mkdir(project, { recursive: true });
    await writeFile(join(project, `${unreachableSession}.jsonl`), JSON.stringify({ type: "user", uuid: randomUUID(),
        sessionId: unreachableSession, cwd: lab.path("work"), timestamp: new Date().toISOString(),
        message: { role: "user", content: "Isolated native parent with no live route holder" } }) + "\n", { mode: 0o600 });
    const unreachableArgs = ["message", unreachableTarget, "Isolated unreachable delivery fixture", "--delivery-id", unreachableId,
        "--operator", "--json"];
    const refused = await agent(lab, unreachableArgs, { allowFailure: true });
    assert.notEqual(refused.status, 0, "Unreachable message command falsely exited successfully");
    const refusedReceipt = await agent(lab, ["receipt", unreachableId, "--json"]);
    assert(["unreachable", "failed", "blocked"].includes(refusedReceipt.deliveryState.kind),
        "Refused delivery has no durable failure receipt");
    await lab.stop();
    await lab.start();
    assert.deepEqual(await agent(lab, ["receipt", unreachableId, "--json"]), refusedReceipt,
        "Failure receipt was lost across isolated gateway restart");
    assert.deepEqual(await agent(lab, ["receipt", deliveryId, "--json"]), first,
        "Accepted continuation receipt was lost across isolated gateway restart");
    const retried = await agent(lab, unreachableArgs, { allowFailure: true });
    assert.notEqual(retried.status, 0, "Unreachable retry falsely exited successfully");
    const retryReceipt = await agent(lab, ["receipt", unreachableId, "--json"]);
    assert.equal(retryReceipt.requestFingerprint, refusedReceipt.requestFingerprint);
    assert.equal(retryReceipt.createdAtMs, refusedReceipt.createdAtMs);
    assert.equal(retryReceipt.resolved?.continuation ?? null, null, "Failed retry admitted unrelated work");
    return { deliveryId, successor, duplicateSuccessor: duplicate.resolved.continuation.jobId,
        unreachableId, refusedExit: refused.status, retryExit: retried.status,
        refusedState: refusedReceipt.deliveryState.kind, retryState: retryReceipt.deliveryState.kind,
        persistedAcrossRestart: true };
}

async function scopedTitleFlow(lab, finishedJob, parent) {
    await settle(lab, finishedJob, job => terminal(job)?.cleanup === "complete");
    const view = await agent(lab, ["read", finishedJob, "--json"]);
    assert.equal(view.agent.conversation.kind, "known");
    const threadId = view.agent.conversation.conversation.threadId;
    const name = "Scoped continuation probe";
    const deliveryId = randomUUID();
    const commands = [
        [binary, "--env-file", lab.path("gateway.env"), "agent", "set-title", name, "--mutation-id", randomUUID()],
        [binary, "--env-file", lab.path("gateway.env"), "agent", "message", "parent", "RCJOB_ECHO:scoped-parent-message",
            "--delivery-id", deliveryId, "--json"],
    ];
    const command = commands.map(args => args.map(part => `'${part.replaceAll("'", "'\\''")}'`).join(" ")).join(" && ");
    const client = await lab.connect();
    try {
        const loaded = await client.rpc("thread/resume", { threadId, excludeTurns: true });
        assert(!loaded.error && loaded.result.thread.id === threadId,
            `Native continued thread could not be loaded: ${JSON.stringify(loaded.error)}`);
        const resumed = await client.rpc("turn/start", { threadId,
            clientUserMessageId: randomUUID(),
            input: [{ type: "text", text: `RCJOB_SPAWN:${Buffer.from(command).toString("base64url")}`, text_elements: [] }] });
        assert(!resumed.error, `Native continued turn failed: ${JSON.stringify(resumed.error)}`);
        const turnId = resumed.result.turn.id;
        await lab.waitFor(async () => {
            const reply = await client.rpc("thread/read", { threadId, includeTurns: false });
            assert(!reply.error, `Title read failed: ${JSON.stringify(reply.error)}`);
            return reply.result.thread.name === name;
        }, 120);
        const ended = await lab.waitFor(async () => {
            const reply = await client.rpc("thread/turns/list", { threadId, limit: 100 });
            assert(!reply.error, `Turn read failed: ${JSON.stringify(reply.error)}`);
            return reply.result.data.find(turn => turn.id === turnId && turn.status !== "inProgress");
        }, 120);
        assert.equal(ended.status, "completed");
        await lab.waitFor(async () => (await parentItems(client, parent)).includes(deliveryId), 120);
        return { threadId, turnId, name, completed: true, path: "native-continued-tool", parent,
            parentDeliveryId: deliveryId, parentRecorded: true };
    } finally { client.ws.close(); }
}

const model = startModel();
const inference = await hostRouter();
const lab = await IsolatedGateway.create(binary);
let failure;
try {
    await prepare(lab, model, inference);
    await lab.start();
    const receipt = { runtime: await runtimeFlows(lab, model) };
    receipt.cwdResume = await cwdResumeFlow(lab, receipt.runtime.claudeChild.jobId);
    if (seedPath) {
        await lab.stop();
        const seed = await installSeed(lab, seedPath);
        await lab.start();
        receipt.seed = await inspectSeed(lab, seed);
        await lab.write(lab.path("acceptance-receipt.json"), JSON.stringify(receipt, null, 1));
        const gc = Bun.spawn(["python3", join(import.meta.dir, "worktree-gc-candidate.py"), "--binary", binary,
            "--env-file", lab.path("gateway.env"), "--isolated-home", lab.root, "--configs", join(lab.realHome, "configs")],
            { env: process.env, cwd: lab.root, stdout: "pipe", stderr: "pipe" });
        const [gcStatus, gcOutput, gcError] = await Promise.all([gc.exited, new Response(gc.stdout).text(), new Response(gc.stderr).text()]);
        assert.equal(gcStatus, 0, `Actual worktree-gc candidate dry run failed: ${gcError.trim()}`);
        receipt.worktreeGc = JSON.parse(gcOutput);
    }
    console.log(JSON.stringify(receipt, null, 1));
} catch (error) {
    failure = error;
} finally {
    await lab.stop().catch(() => lab.forceStop());
    if (await lab.hasNativeDaemon(lab.path(".codex"))) await lab.stopNativeDaemon(lab.path(".codex"));
    model.server.stop(true);
    lab.router?.stop(true);
    if (failure) {
        console.error(`Delegated-jobs acceptance failed; evidence retained at ${lab.root}`);
        throw failure;
    }
    await lab.removeRoot();
}
