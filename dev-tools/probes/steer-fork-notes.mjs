import assert from "node:assert/strict";
import { copyFile, mkdir, readFile, readdir, symlink, writeFile, mkdtemp } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

if (process.argv[2] === "--help") {
    console.log("Usage: bun dev-tools/probes/steer-fork-notes.mjs CANDIDATE_BINARY\nRuns the Claude steer and both provider fork live probes in a private IsolatedGateway, using the host router and fresh provider homes. Checks Claude's queued-command note representation and Codex's persisted developer injection. Removes owned processes, homes and copied secrets; retains a content-safe receipt outside the worktree.");
    process.exit(0);
}
const [binary] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the candidate executable's absolute path inside its signed app bundle");
const lab = await IsolatedGateway.create(binary);
const evidence = await mkdtemp("/tmp/steer-fork-evidence-");
const root = resolve(import.meta.dir, "../..");
const receipt = { binary, isolatedHome: lab.root, probes: [] };
let failure;

async function run(label, args) {
    const command = [join(root, "dev-tools/rc-gateway"), "--host", "127.0.0.1", "--port", String(lab.port),
        "--scheme", "ws", "--no-ssh-env", "--local-config", lab.path("no-app-config.json"), ...args];
    const child = Bun.spawn(command, { cwd: root, env: { ...process.env, RC_CODEX_GATEWAY_AUTH_TOKEN: lab.token }, stdout: "pipe", stderr: "pipe" });
    const [status, stdout, stderr] = await lab.within(Promise.all([
        child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]), 600000, `${label} did not finish`).finally(async () => {
        if (child.exitCode === null) child.kill("SIGTERM");
        await child.exited;
    });
    const result = { label, command, status, stdout: stdout.trim(), stderr: stderr.trim() };
    receipt.probes.push(result);
    console.log(JSON.stringify(result));
    assert.equal(status, 0, `${label} failed: ${stderr}`);
    return stdout;
}

async function records(directory) {
    const found = [];
    for (const entry of await readdir(directory, { withFileTypes: true }).catch(error => {
        if (error.code === "ENOENT") return [];
        throw error;
    })) {
        const file = join(directory, entry.name);
        if (entry.isDirectory()) found.push(...await records(file));
        else if (entry.name.endsWith(".jsonl")) {
            for (const line of (await readFile(file, "utf8")).split("\n").filter(Boolean)) {
                found.push({ file, record: JSON.parse(line) });
            }
        }
    }
    return found;
}

function probeIds(output) {
    return {
        source: output.match(/passed source=(\S+)/)?.[1],
        whole: output.match(/whole=(\S+)/)?.[1],
        sourceTurn: output.match(/PASS source turn 2:.* turn=(\S+)/)?.[1],
        firstForkTurn: output.match(/PASS fork note model context:.* turn=(\S+)/)?.[1],
        laterSteeredTurn: output.match(/PASS later steered turn:.* turn=(\S+)/)?.[1],
    };
}

function claudeUsage(records, thread) {
    const usage = records.filter(({ file }) => file.endsWith(`/${thread?.replace(/^claude_/, "")}.jsonl`))
        .findLast(({ record }) => record.type === "assistant" && record.message?.usage)?.record.message.usage;
    return usage ? {
        input_tokens: usage.input_tokens ?? null,
        cache_read_input_tokens: usage.cache_read_input_tokens ?? null,
        cache_creation_input_tokens: usage.cache_creation_input_tokens ?? null,
    } : null;
}

function codexUsage(records, thread, turn) {
    const file = records.find(({ record }) => record.type === "session_meta" && record.payload?.id === thread)?.file;
    let total, baseline, last, active;
    for (const entry of records.filter(entry => entry.file === file)) {
        const { record } = entry;
        const payload = record.payload;
        if (record.type !== "event_msg") continue;
        if (["task_started", "turn_started"].includes(payload?.type)) {
            active = payload.turn_id;
            if (active === turn) baseline = total;
        }
        if (payload?.type === "token_count" && payload.info) {
            total = payload.info.total_token_usage;
            if (active === turn) last = { total, response: payload.info.last_token_usage };
        }
    }
    if (!last) return null;
    return {
        turn: Object.fromEntries(["input_tokens", "cached_input_tokens"].map(key =>
            [key, last.total[key] - (baseline?.[key] ?? 0)])),
        lastResponse: last.response,
    };
}

try {
    const values = Object.fromEntries((await readFile(join(lab.realHome, ".remote-coder/codex-gateway.env"), "utf8"))
        .split("\n").flatMap(line => {
            const match = line.match(/^(?:export\s+)?([A-Z_][A-Z_0-9]*)=(.*)$/);
            if (!match) return [];
            const raw = match[2].trim();
            return [[match[1], /^(["']).*\1$/.test(raw) ? raw.slice(1, -1) : raw]];
        }));
    const keys = ["RC_CODEX_GATEWAY_ROUTER_URL", "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL", "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT"];
    for (const key of [...keys, "RC_CODEX_GATEWAY_ROUTER_KEY_FILE"]) assert(values[key], `Missing host router setting ${key}`);
    await copyFile(values.RC_CODEX_GATEWAY_ROUTER_KEY_FILE, lab.path("router-key"));
    await mkdir(join(lab.nativeDefault, "packages/standalone"), { recursive: true, mode: 0o700 });
    await symlink(join(lab.realHome, ".codex/packages/standalone/current"), join(lab.nativeDefault, "packages/standalone/current"));
    await lab.write(join(lab.nativeDefault, "config.toml"), 'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    await mkdir(lab.path(".claude"), { recursive: true, mode: 0o700 });
    await mkdir(lab.path("work"), { recursive: true, mode: 0o700 });
    const claude = values.RC_CLAUDE_PATH ?? join(lab.realHome, ".local/bin/claude");
    const version = Bun.spawn([claude, "--version"], { env: lab.safeEnv, stdout: "pipe", stderr: "pipe" });
    receipt.claudeVersion = (await new Response(version.stdout).text()).trim();
    assert.equal(await version.exited, 0, "Claude version check failed");
    await lab.write(lab.path("gateway.env"), [
        "RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1", `RC_CODEX_GATEWAY_PORT=${lab.port}`,
        `RC_CODEX_GATEWAY_AUTH_TOKEN=${lab.token}`, `RC_CODEX_GATEWAY_CODEX_PATH=${lab.codex}`,
        "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false", ...keys.map(key => `${key}=${values[key]}`),
        `RC_CODEX_GATEWAY_ROUTER_KEY_FILE=${lab.path("router-key")}`,
        ...(values.RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS ? [`RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS=${values.RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS}`] : []),
        "RC_CLAUDE_ENABLED=true", `RC_CLAUDE_HOME=${lab.path(".claude")}`, `RC_CLAUDE_PATH=${claude}`,
        `CODEX_HOME=${lab.nativeDefault}`, "RUST_LOG=warn",
    ].join("\n") + "\n");
    await lab.start();
    receipt.gateway = await lab.request("/version");
    const steer = await run("gateway-e2e-claude-steer-live", ["e2e-claude-steer-live", "--cwd", lab.path("work"), "--model", "sonnet"]);
    const steerId = steer.match(/steer=([^;\s]+)/)?.[1];
    assert(steerId, "Steer probe returned no exact client id");
    const claudeRecords = await records(lab.path(".claude/projects"));
    const queued = claudeRecords.find(({ record }) => record.type === "attachment" && record.attachment?.source_uuid === steerId);
    assert(queued, "Claude did not record the mid-tool steer as a queued_command attachment");
    assert.equal(queued.record.attachment.type, "queued_command");
    const prompt = queued.record.attachment.prompt;
    receipt.claudeQueuedSteer = { sourceUuid: steerId, type: queued.record.attachment.type, prompt };
    assert(Array.isArray(prompt), "Two-block queued steer was flattened; inspect retained receipt");
    assert.equal(prompt[0].text, "Instead reply with only STEERED.");
    assert(prompt[1].text.startsWith("<remotecoder_note>\nRemoteCoder note:"));
    assert(!JSON.stringify(prompt).includes("INTERACTION_MODE_MUST_STAY_CODEX_ONLY"));
    const claudeFork = await run("gateway-e2e-claude-fork-live", ["e2e-fork-live", "--provider", "claude", "--model", "sonnet", "--cwd", lab.path("work")]);
    const claudeIds = probeIds(claudeFork);
    const claudeHistory = await records(lab.path(".claude/projects"));
    receipt.cacheUsage = { claude: {
        sourceLastTurn: { threadId: claudeIds.source, turnId: claudeIds.sourceTurn, usage: claudeUsage(claudeHistory, claudeIds.source) },
        firstForkTurn: { threadId: claudeIds.whole, turnId: claudeIds.firstForkTurn, usage: claudeUsage(claudeHistory, claudeIds.whole) },
    } };
    console.log(JSON.stringify({ cacheUsage: receipt.cacheUsage }));
    const fork = await run("gateway-e2e-fork-live", ["e2e-fork-live", "--model", "gpt-6.1-sol", "--cwd", lab.path("work")]);
    const codexIds = probeIds(fork);
    const forkId = codexIds.whole;
    const native = await records(join(lab.nativeDefault, "sessions"));
    const forkFile = native.find(({ record }) => record.type === "session_meta" && record.payload?.id === forkId)?.file;
    assert(forkFile, "No rollout for the client-forked Codex thread");
    const rollout = native.filter(({ file }) => file === forkFile).map(({ record }) => record);
    const injected = rollout.findIndex(record => record.type === "response_item" && record.payload?.role === "developer"
        && JSON.stringify(record.payload.content).includes("RemoteCoder note: this conversation is a fork"));
    assert(injected >= 0, "Control injection was not checkpointed in the client-forked thread");
    const nextUser = rollout.findIndex((record, index) => index > injected && record.type === "response_item" && record.payload?.role === "user");
    assert(nextUser > injected, "Fork note did not precede the first new user input");
    receipt.codexInjection = { threadId: forkId, checkpointedDeveloperNote: true, precedesNewUserInput: true };
    receipt.cacheUsage.codex = {
        sourceLastTurn: { threadId: codexIds.source, turnId: codexIds.sourceTurn, usage: codexUsage(native, codexIds.source, codexIds.sourceTurn) },
        firstForkTurn: { threadId: forkId, turnId: codexIds.firstForkTurn, usage: codexUsage(native, forkId, codexIds.firstForkTurn) },
        laterSteeredTurn: { threadId: forkId, turnId: codexIds.laterSteeredTurn, usage: codexUsage(native, forkId, codexIds.laterSteeredTurn) },
    };
    console.log(JSON.stringify({ cacheUsage: receipt.cacheUsage }));
} catch (error) {
    failure = error;
    receipt.error = String(error.message);
} finally {
    try {
        await lab.stop();
        assert.equal(await lab.stopNativeDaemon(lab.nativeDefault), 0, "Owned native daemon did not stop");
    } catch (error) {
        receipt.cleanupError = String(error.message);
        failure ??= error;
        await lab.forceStop();
    }
    if (failure) {
        for (const name of ["gateway.log", "gateway-errors.log"]) {
            const file = Bun.file(lab.path(name));
            if (await file.exists()) {
                const raw = await file.text();
                await writeFile(join(evidence, name), raw.replaceAll(lab.token, "[redacted]"), { mode: 0o600 });
            }
        }
    }
    await lab.removeRoot();
    await writeFile(join(evidence, "receipt.json"), JSON.stringify(receipt, null, 2), { mode: 0o600 });
    console.log(JSON.stringify({ passed: !failure, evidenceDirectory: evidence, claudeVersion: receipt.claudeVersion }));
}
if (failure) process.exitCode = 1;
