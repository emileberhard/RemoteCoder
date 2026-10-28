import assert from "node:assert/strict";
import { mkdir, readFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomBytes, randomInt, randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { IsolatedGateway, availablePort, startStubRouter } from "./isolated-gateway.mjs";
import { startModel, installPackage, writeProviderConfig } from "./delegated-model.mjs";

const quote = text => `'${text.replaceAll("'", "'\\''")}'`;
const jobId = () => `agent-codex-${BigInt(Date.now()) * 1_000_000n + BigInt(randomInt(1_000_000))}-${randomBytes(4).toString("hex")}`;
const terminal = job => job.execution.kind === "terminal" ? job.execution.terminal : null;

async function worker(binary, runtimePackage) {
    const lab = await IsolatedGateway.create(binary);
    const model = startModel();
    let client;
    const rpc = async (method, params) => {
        const response = await client.rpc(method, params);
        if (response.error) throw new Error(JSON.stringify(response.error));
        return response.result;
    };
    const close = async () => {
        const errors = [];
        for (const cleanup of [() => lab.stop(), () => lab.forceStop(),
            () => lab.stopNativeDaemon(lab.nativeDefault), () => model.server.stop(true),
            () => lab.router?.stop(true), () => lab.removeRoot()]) {
            try { await cleanup(); } catch (error) { errors.push(String(error)); }
        }
        assert.equal(errors.length, 0, errors.join("\n"));
    };
    try {
        await mkdir(lab.path("work"), { recursive: true });
        await mkdir(lab.path(".claude"), { recursive: true });
        await installPackage(lab, runtimePackage);
        await writeProviderConfig(lab, model);
        const config = await readFile(join(lab.realHome, ".remote-coder/codex-gateway.env"), "utf8");
        const value = name => config.match(new RegExp(`^${name}="?([^"\\n]+)"?$`, "m"))?.[1];
        const url = value("RC_CODEX_GATEWAY_ROUTER_URL");
        const keyFile = value("RC_CODEX_GATEWAY_ROUTER_KEY_FILE");
        assert(url && keyFile, "Claude probe requires the configured host router");
        lab.router = startStubRouter({ url, key: (await readFile(keyFile, "utf8")).trim() });
        await lab.writeGatewayEnv([
            `RC_CODEX_GATEWAY_LAN_PORT=${await availablePort()}`,
            `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`,
            "RC_CLAUDE_ENABLED=true", `RC_CLAUDE_HOME=${lab.path(".claude")}`,
            `RC_CLAUDE_PATH=${join(lab.realHome, ".local/bin/claude")}`,
        ]);
        await lab.start();
        client = await lab.connect();
        for await (const line of createInterface({ input: process.stdin })) {
            const { id, method, params = {} } = JSON.parse(line);
            try {
                let result;
                switch (method) {
                    case "describe": result = { ...(await rpc("cluster/list", {})).self,
                        binary, env: lab.path("gateway.env"), cwd: lab.path("work") }; break;
                    case "rpc": result = await rpc(params.method, params.params); break;
                    case "release": model.release(params.name); result = true; break;
                    case "stop": await lab.stop(); result = true; break;
                    case "start": await lab.start(); client = await lab.connect(); result = true; break;
                    case "requests": result = model.requests; break;
                    case "inputs": {
                        assert(/^claude_[0-9a-f-]{36}$/.test(params.thread));
                        const rows = [];
                        for await (const path of new Bun.Glob(`**/${params.thread.slice(7)}.jsonl`).scan({ cwd: lab.path(".claude/projects"), absolute: true })) {
                            for (const line of (await readFile(path, "utf8")).split("\n").filter(Boolean)) {
                                const row = JSON.parse(line);
                                if (row.type === "user" && JSON.stringify(row.message).includes(params.needle)) {
                                    rows.push({ id: row.uuid, source: "claudeTranscript" });
                                }
                            }
                        }
                        result = rows; break;
                    }
                    case "agent": {
                        const child = Bun.spawn([binary, "--env-file", lab.path("gateway.env"), "agent", ...params.args], {
                            env: lab.safeEnv, cwd: lab.path("work"), stdout: "pipe", stderr: "pipe" });
                        const [status, stdout, stderr] = await lab.within(Promise.all([
                            child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
                        ]), 90000, "Agent CLI did not finish").finally(() => {
                            if (child.exitCode === null) child.kill("SIGKILL");
                        });
                        result = { status, stdout, stderr }; break;
                    }
                    case "close": result = true; break;
                    default: throw new Error("Unknown probe control method");
                }
                process.stdout.write(JSON.stringify({ id, result }) + "\n");
            } catch (error) {
                process.stdout.write(JSON.stringify({ id, error: String(error) }) + "\n");
            }
            if (method === "close") break;
        }
    } finally { await close(); }
}

async function openWorker(command) {
    const child = Bun.spawn(command, { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
    const waiters = new Map();
    let next = 0;
    const reading = (async () => {
        const decoder = new TextDecoder();
        let pending = "";
        for await (const bytes of child.stdout) {
            pending += decoder.decode(bytes, { stream: true });
            assert(pending.length < 32 * 1024 * 1024, "Probe control frame exceeds capacity");
            let end;
            while ((end = pending.indexOf("\n")) >= 0) {
                const value = JSON.parse(pending.slice(0, end));
                pending = pending.slice(end + 1);
                const waiter = waiters.get(value.id);
                assert(waiter, "Unmatched probe response");
                waiters.delete(value.id);
                clearTimeout(waiter.timer);
                value.error ? waiter.reject(new Error(value.error)) : waiter.resolve(value.result);
            }
        }
        for (const waiter of waiters.values()) {
            clearTimeout(waiter.timer);
            waiter.reject(new Error("Probe worker closed"));
        }
    })();
    const call = (method, params) => new Promise((resolve, reject) => {
        const id = ++next;
        const timer = setTimeout(() => { waiters.delete(id); reject(new Error(`Probe ${method} timed out`)); }, 180000);
        waiters.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
        child.stdin.flush();
    });
    return { call, rpc: (method, params = {}) => call("rpc", { method, params }),
        async close() {
            try { await call("close"); } finally { child.stdin.end(); }
            const status = await child.exited;
            await reading;
            assert.equal(status, 0, "Probe worker cleanup failed");
        } };
}

async function waitFor(condition, seconds = 180) {
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
        const value = await condition();
        if (value) return value;
        await Bun.sleep(300);
    }
    throw new Error("Cluster lifecycle acceptance timed out");
}

async function pair(a, b, aName, bName) {
    const membership = randomUUID();
    const [left, right] = await Promise.all([
        a.rpc("cluster/issue", { protocol: 1, for: b.info.hostId, name: bName, membership }),
        b.rpc("cluster/issue", { protocol: 1, for: a.info.hostId, name: aName, membership }),
    ]);
    const accept = (receipt, name) => ({ protocol: 1, host: receipt.host, name, membership,
        pin: receipt.pin, routes: receipt.routes, credential: receipt.credential });
    await Promise.all([a.rpc("cluster/accept", accept(right, bName)), b.rpc("cluster/accept", accept(left, aName))]);
}

async function nativeParent(host, provider) {
    const params = { cwd: host.info.cwd, model: provider === "codex" ? "rcjob-mock" : "sonnet",
        ...(provider === "codex" ? { modelProvider: "probe" } : { provider: "claude" }) };
    const response = await host.rpc("thread/start", params);
    return response.thread.id;
}

async function nativeCommand(host, thread, provider, command) {
    const text = provider === "codex" ? `RCJOB_SPAWN:${Buffer.from(command).toString("base64url")}`
        : `Run exactly this shell command once, then reply with ADMITTED. Do not call any other tools:\n${command}`;
    await host.rpc("turn/start", { threadId: thread,
        ...(provider === "claude" ? { cwd: host.info.cwd, model: "sonnet" } : {}),
        input: [{ type: "text", text, text_elements: [] }] });
}

async function remoteSpawn(parentHost, childHost, provider, name) {
    const parent = await nativeParent(parentHost, provider);
    const id = jobId();
    const interimId = randomUUID();
    const interim = [childHost.info.binary, "--env-file", childHost.info.env, "agent", "message", "parent",
        `Interim cluster probe ${name}`, "--delivery-id", interimId, "--json"].map(quote).join(" ");
    const childPrompt = `RCJOB_SPAWNHOLD:${Buffer.from(interim).toString("base64url")}.${name}`;
    const command = [parentHost.info.binary, "--env-file", parentHost.info.env, "agent", "spawn",
        "codex", "rcjob-mock", childPrompt, "--host", childHost.info.hostId,
        "--cwd", childHost.info.cwd, "--job-id", id, "--json"].map(quote).join(" ");
    await nativeCommand(parentHost, parent, provider, command);
    const job = await waitFor(async () => {
        const rows = await childHost.rpc("agent/jobs/list", { selector: { kind: "recent" }, limit: 100, cursor: null });
        if (!rows.jobs.some(row => row.jobId === id)) return null;
        const view = await childHost.rpc("agent/jobs/read", { jobId: id });
        return view.job.execution.kind === "running" ? view.job : null;
    });
    assert.equal(job.admissionOrigin.kind, "remoteParent");
    assert.equal(job.admissionOrigin.host, parentHost.info.hostId);
    assert.equal(job.admissionOrigin.conversation.threadId, parent);
    assert.equal(job.recipient.hostId, parentHost.info.hostId);
    assert.deepEqual(job.spec.spec.toolScope, { kind: "full" });
    await waitFor(async () => {
        return (await observedInput(parentHost, parent, interimId)).length;
    });
    return { id, parent, name, provider, interimId };
}

async function observedInput(host, thread, needle) {
    if (thread.startsWith("claude_")) return host.call("inputs", { thread, needle });
    const page = await host.rpc("thread/items/list", { threadId: thread, limit: 100, sortDirection: "asc" });
    return page.data.filter(entry => entry.item?.type === "userMessage" && JSON.stringify(entry.item).includes(needle));
}

async function observedCompletion(host, thread, id) {
    return observedInput(host, thread, `${id}:completion`);
}

async function journey(a, b, suffix) {
    const children = [];
    for (const provider of ["codex", "claude"]) {
        console.error(`${suffix}: native ${provider} parent spawns a remote child`);
        children.push(await remoteSpawn(a, b, provider, `${provider}-${suffix}`));
    }
    console.error(`${suffix}: receiver stops with remote children running`);
    await a.call("stop");
    await Promise.all(children.map(child => b.call("release", { name: child.name })));
    for (const child of children) {
        await waitFor(async () => {
            const job = (await b.rpc("agent/jobs/read", { jobId: child.id })).job;
            assert(!terminal(job) || terminal(job).outcome.kind === "completed");
            return ["unreachable", "uncertain"].includes(terminal(job)?.completion?.delivery?.kind);
        });
    }
    console.error(`${suffix}: receiver restarts for completion delivery`);
    const resumed = Date.now();
    await a.call("start");
    await a.rpc("agent/cluster/dispatch", { host: b.info.hostId, method: "agent/jobs/read",
        request: { jobId: children[0].id }, caller: { kind: "operator" } });
    for (const child of children) {
        await waitFor(async () => {
            const job = (await b.rpc("agent/jobs/read", { jobId: child.id })).job;
            return ["accepted", "recorded"].includes(terminal(job)?.completion?.delivery?.kind);
        });
        const entries = await waitFor(async () => {
            const found = await observedCompletion(a, child.parent, child.id);
            return found.length ? found : null;
        });
        assert.equal(entries.length, 1, "Completion entered the parent's native history twice");
    }
    console.error(`${suffix}: canonical parent inputs confirm one completion each`);
    return { parentHostId: a.info.hostId, ownerHostId: b.info.hostId,
        children: children.map(({ id, parent, provider, interimId }) => ({ id, parent, provider, interimId })),
        callbackAfterReturnMs: Date.now() - resumed };
}

async function main() {
    const [binary, runtimePackage, ...options] = process.argv.slice(2);
    assert(isAbsolute(binary) && isAbsolute(runtimePackage), "Pass absolute candidate and matched package paths");
    const remote = options.indexOf("--remote");
    const countIndex = options.indexOf("--members");
    const count = countIndex < 0 ? 3 : Number(options[countIndex + 1]);
    assert([2, 3].includes(count));
    const workers = [];
    const errors = [];
    try {
        for (let i = 0; i < count; i++) {
            const command = i === 1 && remote >= 0
                ? ["ssh", "-o", "BatchMode=yes", options[remote + 1],
                    ["/opt/homebrew/bin/bun", options[remote + 4], "--worker", options[remote + 2], options[remote + 3]].map(quote).join(" ")]
                : [process.execPath, import.meta.path, "--worker", binary, runtimePackage];
            const host = await openWorker(command);
            workers.push(host);
            host.info = await host.call("describe");
        }
        for (let i = 0; i < workers.length; i++) {
            for (let j = i + 1; j < workers.length; j++) await pair(workers[i], workers[j], `probe-${i}`, `probe-${j}`);
        }
        await waitFor(async () => {
            const pages = await Promise.all(workers.map(host => host.rpc("cluster/list")));
            return pages.every(page => page.members.length === count - 1
                && page.members.every(member => member.reachability.state === "reachable"
                    && member.reachability.lastSeenAt));
        });
        const outward = await journey(workers[0], workers[1], "outward");
        const reverse = await journey(workers[1], workers[0], "reverse");
        const pages = await Promise.all(workers.map(host => host.rpc("agent/cluster/list", { limit: 100 })));
        for (const page of pages) {
            assert.equal(page.coverage.length, count);
            assert(page.coverage.every(row => row.state === "ok"));
        }
        if (count === 3) {
            const child = outward.children[0];
            const job = (await workers[1].rpc("agent/jobs/read", { jobId: child.id })).job;
            const address = { hostId: workers[1].info.hostId, threadId: terminal(job).execution.conversation.threadId };
            const root = await nativeParent(workers[2], "codex");
            const moved = await workers[1].rpc("agent/parent/set", { protocol: 1, agent: address,
                parent: { hostId: workers[2].info.hostId, threadId: root }, caller: { kind: "operator" } });
            assert.equal(moved.parent.hostId, workers[2].info.hostId);
            const continued = jobId();
            const command = [workers[2].info.binary, "--env-file", workers[2].info.env,
                "agent", "spawn", `RCJOB_ECHO:Moved child result ${continued}`,
                "--resume", child.id, "--host", workers[1].info.hostId,
                "--job-id", continued, "--json"].map(quote).join(" ");
            await nativeCommand(workers[2], root, "codex", command);
            await waitFor(async () => {
                const rows = await workers[1].rpc("agent/jobs/list", {selector:{kind:"recent"},limit:100,cursor:null});
                if (!rows.jobs.some(row => row.jobId === continued)) return false;
                const view = await workers[1].rpc("agent/jobs/read", {jobId:continued});
                return ["accepted", "recorded"].includes(terminal(view.job)?.completion?.delivery?.kind);
            });
            assert.equal((await observedCompletion(workers[2], root, continued)).length, 1);
            assert.equal((await observedCompletion(workers[0], child.parent, continued)).length, 0);
            const promoted = await workers[1].rpc("agent/parent/set", { protocol: 1, agent: address,
                parent: null, caller: { kind: "operator" } });
            assert.equal(promoted.parent, null);
        }
        console.log(JSON.stringify({ members: count, crossMac: remote >= 0, outward, reverse,
            completeCoverage: true, moveAndPromotion: count === 3 }));
    } finally {
        for (const host of workers.reverse()) {
            try { await host.close(); } catch (error) { errors.push(String(error)); }
        }
        assert.equal(errors.length, 0, errors.join("\n"));
    }
}

if (process.argv[2] === "--worker") await worker(process.argv[3], process.argv[4]);
else await main();
