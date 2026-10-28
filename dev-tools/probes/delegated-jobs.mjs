import assert from "node:assert/strict";
import { cp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomBytes, randomInt, randomUUID } from "node:crypto";
import { IsolatedGateway, startStubRouter } from "./isolated-gateway.mjs";

const [binary, runtimePackage, ...stagedStores] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
assert(runtimePackage && isAbsolute(runtimePackage), "Pass the matched Codex runtime package directory");
assert(stagedStores.every(store => isAbsolute(store)), "Pass staged agent-jobs/v1 directories as absolute paths");

const marker = /^RCJOB_(SPAWN|HOLD|ECHO):(\S+)/;
const jobId = provider => `agent-${provider}-${BigInt(Date.now()) * 1_000_000n + BigInt(randomInt(1_000_000))}-${randomBytes(4).toString("hex")}`;
const shellTools = ["exec_command", "shell_command", "shell"];
const probeProvider = "probe";
const probeModel = "rcjob-mock";

function startModel() {
    const holds = new Map();
    const requests = [];
    const hold = name => {
        if (!holds.has(name)) {
            let release;
            holds.set(name, { promise: new Promise(resolve => { release = resolve; }), release });
        }
        return holds.get(name);
    };
    const message = text => ({ type: "response.output_item.done", item: {
        type: "message", role: "assistant", id: `msg_${randomUUID()}`, phase: "final_answer",
        content: [{ type: "output_text", text }] } });
    const call = (body, command) => {
        const tool = (body.tools ?? []).map(entry => entry.name ?? entry.function?.name).find(name => shellTools.includes(name));
        assert(tool, `No shell tool offered: ${JSON.stringify((body.tools ?? []).map(entry => entry.name ?? entry.type))}`);
        const args = tool === "exec_command" ? { cmd: command, yield_time_ms: 30000 }
            : tool === "shell_command" ? { command } : { command: ["/bin/zsh", "-c", command] };
        return { type: "response.output_item.done", item: { type: "function_call", call_id: `call_${randomUUID()}`,
            namespace: "functions", name: tool, arguments: JSON.stringify(args) } };
    };
    const frame = event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
    const server = Bun.serve({
        hostname: "127.0.0.1", port: 0, idleTimeout: 0,
        async fetch(request) {
            const path = new URL(request.url).pathname;
            if (request.method === "GET" && path.endsWith("/models")) {
                return Response.json({ data: [{ id: probeModel, capabilities: { endpoints: ["/v1/responses"],
                    streaming: true, tool_calls: true, prompt_tokens: 128000, reasoning_efforts: ["medium"],
                    input_modalities: ["text"] } }] });
            }
            if (request.method !== "POST" || !path.endsWith("/responses")) {
                return new Response("", { status: 404 });
            }
            const body = await request.json();
            const input = body.input ?? [];
            const lastUser = input.findLastIndex(item => item.role === "user");
            const texts = input.filter(item => item.role === "user")
                .map(item => (item.content ?? []).map(part => part.text ?? "").join("\n"));
            const latest = texts.findLast(text => marker.test(text)) ?? texts.at(-1) ?? "";
            const answered = input.slice(lastUser + 1).some(item => item.type === "function_call_output");
            const [, kind, name] = latest.match(marker) ?? [];
            requests.push({ kind: kind ?? "other", name: name ?? null, answered });
            const id = `resp_${randomUUID()}`;
            const done = { type: "response.completed", response: { id, usage: { input_tokens: 1,
                input_tokens_details: null, output_tokens: 1, output_tokens_details: null, total_tokens: 2 } } };
            const head = frame({ type: "response.created", response: { id } });
            const headers = { "Content-Type": "text/event-stream" };
            if (kind === "HOLD") {
                const gate = hold(name);
                return new Response(new ReadableStream({
                    async start(controller) {
                        controller.enqueue(head);
                        await gate.promise;
                        if (request.signal.aborted) return;
                        controller.enqueue(frame(message(`RCJOB_RESULT:${name}`)) + frame(done));
                        controller.close();
                    },
                }), { headers });
            }
            const output = kind === "SPAWN" && !answered
                ? call(body, Buffer.from(name, "base64url").toString())
                : message(kind === "ECHO" || kind === "HOLD" ? `RCJOB_RESULT:${name}` : `ack:${kind ?? "other"}`);
            return new Response(head + frame(output) + frame(done), { headers });
        },
    });
    return { server, requests, release: name => hold(name).release() };
}

async function installPackage(lab) {
    const standalone = lab.path(".codex/packages/standalone");
    const manifest = JSON.parse(await readFile(join(runtimePackage, "codex-package.json"), "utf8"));
    const release = join(standalone, "releases", `${manifest.version}-${manifest.target}`);
    await mkdir(join(standalone, "releases"), { recursive: true });
    await cp(runtimePackage, release, { recursive: true, verbatimSymlinks: true });
    await symlink(manifest.entrypoint, join(release, "codex"));
    await symlink(release, join(standalone, "current"));
    lab.codex = join(standalone, "current/codex");
}

async function writeProviderConfig(lab, model) {
    await writeFile(lab.path(".codex/config.toml"), `approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false
`, { mode: 0o600 });
    await writeFile(lab.path("probe-provider.key"), "probe-key\n", { mode: 0o600 });
    await writeFile(lab.path("external-providers.json"), JSON.stringify({ providers: [{ id: probeProvider,
        name: "Probe", baseUrl: `http://127.0.0.1:${model.server.port}/v1`, keyFile: lab.path("probe-provider.key"),
        models: [probeModel] }] }), { mode: 0o600 });
}

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
    await installPackage(lab);
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
    const spawn = (provider, model, prompt) => [binary, "--env-file", lab.path("gateway.env"), "agent", "spawn", provider,
        model, prompt, "--job-id", jobId(provider), "--json"].map(part => `'${part.replaceAll("'", "'\\''")}'`).join(" ");
    const command = [
        spawn("codex", probeModel, "RCJOB_ECHO:codex-child"),
        spawn("claude", "sonnet", "Reply with exactly RCJOB_RESULT:claude-child and nothing else. Do not use tools."),
    ].join(" && ");
    const turn = await client.rpc("turn/start", { threadId: parent,
        input: [{ type: "text", text: `RCJOB_SPAWN:${Buffer.from(command).toString("base64url")}`, text_elements: [] }] });
    assert(!turn.error, `parent turn/start failed: ${JSON.stringify(turn.error)}`);

    const children = await lab.waitFor(async () => {
        const list = await agent(lab, ["list", "--json", "--last", "10"]);
        const rows = list.agents.filter(row => row.conversation?.conversation?.threadId !== parent);
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

    const stopId = jobId("codex");
    await agent(lab, ["spawn", "codex", probeModel, "RCJOB_HOLD:stop-child", "--job-id", stopId, "--operator", "--json"]);
    await settle(lab, stopId, running);
    await agent(lab, ["stop", stopId]);
    const stopped = await settle(lab, stopId, job => terminal(job) !== null);
    assert.equal(terminal(stopped).outcome.kind, "stopped", "Stop did not end the running child");
    model.release("stop-child");
    receipt.stop = terminal(stopped).outcome;

    const restartId = jobId("codex");
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

async function heldStoreRead(model, inference, stagedStore) {
    const lab = await IsolatedGateway.create(binary);
    try {
        await prepare(lab, model, inference);
        const store = lab.path(".remote-coder/agent-jobs/v1");
        await mkdir(lab.path(".remote-coder/agent-jobs"), { recursive: true });
        await cp(stagedStore, store, { recursive: true });
        await rm(join(store, "owner.lock"), { force: true });
        await writeFile(join(store, "cutover.hold"), "", { mode: 0o600 });
        await lab.start();
        const list = await agent(lab, ["list", "--json", "--last", "200"]);
        assert(list.agents.length > 0, "The staged store listed no jobs");
        const states = {};
        for (const row of list.agents) states[row.state] = (states[row.state] ?? 0) + 1;
        const samples = [];
        for (const row of list.agents.slice(0, 5)) samples.push((await read(lab, row.run_id)).execution.kind);
        const refused = await agent(lab, ["spawn", "codex", probeModel, "RCJOB_ECHO:held", "--operator", "--json"],
            { allowFailure: true });
        assert.notEqual(refused.status, 0, "The held store admitted a new job");
        return { listed: list.agents.length, states, samples, spawnRefused: refused.stderr.trim().slice(0, 200) };
    } finally {
        await lab.stop().catch(() => lab.forceStop());
        if (await lab.hasNativeDaemon(lab.path(".codex"))) await lab.stopNativeDaemon(lab.path(".codex"));
        await lab.removeRoot();
    }
}

const model = startModel();
const inference = await hostRouter();
const lab = await IsolatedGateway.create(binary);
let failure;
try {
    await prepare(lab, model, inference);
    await lab.start();
    const receipt = { runtime: await runtimeFlows(lab, model) };
    receipt.heldStores = {};
    for (const store of stagedStores) receipt.heldStores[store] = await heldStoreRead(model, inference, store);
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
