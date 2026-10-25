import assert from "node:assert/strict";
import { copyFile, mkdir, readFile, rm, symlink } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

if (process.argv[2] === "--help") {
    console.log("Usage: bun dev-tools/probes/provider-fallback.mjs CANDIDATE_BINARY\nRuns an owned isolated gateway against the host router with the Codex subscription sign-in failing on purpose. Proves Codex reports the Copilot fallback, a Claude turn completes and a new Codex turn runs on Copilot. Production stays unchanged.");
    process.exit(0);
}
const [binary] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
const lab = await IsolatedGateway.create(binary);
const wrapper = resolve(import.meta.dir, "../rc-gateway");
const secrets = [lab.path("router-key"), lab.path("copilot-key")];
let failure;

function envValues(source) {
    return Object.fromEntries(source.split("\n").flatMap(line => {
        const match = line.match(/^(?:export\s+)?([A-Z_][A-Z_0-9]*)=(.*)$/);
        if (!match) return [];
        const raw = match[2].trim();
        return [[match[1], /^(["']).*\1$/.test(raw) ? raw.slice(1, -1) : raw]];
    }));
}

async function readyProviders() {
    const ws = new WebSocket(lab.base.replace("http:", "ws:") + "/ws", {
        headers: { Authorization: `Bearer ${lab.token}` },
    });
    try {
        const ready = await lab.within(new Promise((resolve, reject) => {
            ws.onmessage = event => resolve(JSON.parse(String(event.data)));
            ws.onerror = () => reject(new Error("WebSocket failed"));
            ws.onclose = () => reject(new Error("WebSocket closed before ready"));
        }), 10000, "No ready frame");
        assert.equal(ready.method, "daemon/ready");
        return ready.params.providers;
    } finally {
        ws.close();
    }
}

async function turn(provider, model, prompt) {
    const cwd = lab.path(provider);
    await mkdir(cwd, { recursive: true, mode: 0o700 });
    const events = lab.path(`${provider}.events.jsonl`);
    const args = [wrapper, "--host", "127.0.0.1", "--port", String(lab.port), "--scheme", "ws", "--no-ssh-env",
        "--local-config", lab.path("no-config.json"), provider === "claude" ? "claude-turn" : "turn",
        "--model", model, "--effort", "medium", "--cwd", cwd, "--purpose", "probe", "--timeout", "300",
        "--event-log", events, ...(provider === "claude" ? [prompt] : ["--prompt", prompt, "--print-assistant"])];
    const child = Bun.spawn(args, {
        env: { ...process.env, RC_CODEX_GATEWAY_AUTH_TOKEN: lab.token },
        cwd: resolve(import.meta.dir, "../.."), stdout: "pipe", stderr: "pipe",
    });
    const [exitCode, stdout, stderr] = await Promise.all([
        child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    const lines = await Bun.file(events).exists() ? (await readFile(events, "utf8")).split("\n").filter(Boolean) : [];
    const threadId = lines.map(line => JSON.parse(line)).find(event => event.type === "thread.started")?.thread_id;
    return { provider, model, exitCode, threadId, stdout: stdout.trim().slice(-500), stderr: stderr.trim().slice(-2000) };
}

try {
    const values = envValues(await readFile(join(lab.realHome, ".remote-coder/codex-gateway.env"), "utf8"));
    const keys = ["RC_CODEX_GATEWAY_ROUTER_URL", "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL", "RC_CODEX_GATEWAY_ROUTER_KEY_FILE"];
    for (const key of [...keys, "RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE"]) assert(values[key], `Host setting is missing: ${key}`);
    const copilot = JSON.parse(await readFile(values.RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE, "utf8"))
        .providers.find(provider => provider.id === "copilot");
    assert(copilot, "The host has no copilot external provider");
    await copyFile(values.RC_CODEX_GATEWAY_ROUTER_KEY_FILE, secrets[0]);
    await copyFile(copilot.keyFile, secrets[1]);
    await lab.write(lab.path("external-providers.json"), JSON.stringify({ providers: [{
        ...copilot, keyFile: secrets[1], models: ["copilot/gpt-6.1-sol", "copilot/gemini-4-argon"],
    }] }));
    await mkdir(join(lab.nativeDefault, "packages/standalone"), { recursive: true, mode: 0o700 });
    await symlink(join(lab.realHome, ".codex/packages/standalone/current"), join(lab.nativeDefault, "packages/standalone/current"));
    await lab.write(join(lab.nativeDefault, "config.toml"), 'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    await mkdir(lab.path(".claude"), { recursive: true, mode: 0o700 });
    await lab.write(lab.path("gateway.env"), [
        "RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1", `RC_CODEX_GATEWAY_PORT=${lab.port}`,
        `RC_CODEX_GATEWAY_AUTH_TOKEN=${lab.token}`, `RC_CODEX_GATEWAY_CODEX_PATH=${lab.codex}`,
        "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false",
        `RC_CODEX_GATEWAY_ROUTER_URL=${values.RC_CODEX_GATEWAY_ROUTER_URL}`,
        `RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL=${values.RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL}`,
        `RC_CODEX_GATEWAY_ROUTER_KEY_FILE=${secrets[0]}`,
        "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT=provider-fallback-probe-missing-account",
        `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`,
        `RC_CLAUDE_HOME=${lab.path(".claude")}`, `RC_CLAUDE_PATH=${values.RC_CLAUDE_PATH ?? `${lab.realHome}/.local/bin/claude`}`,
        `CODEX_HOME=${lab.nativeDefault}`, "RUST_LOG=warn",
    ].join("\n") + "\n");
    await lab.start();
    const providers = await lab.waitFor(async () => {
        const current = await readyProviders();
        return current?.codex?.state === "fallback" ? current : null;
    }, 120);
    assert.equal(providers.codex.fallback, "copilot");
    const turns = await Promise.all([
        turn("claude", "claude-sonnet-5-5", "Reply with exactly: claude ok"),
        turn("codex", "gpt-6.1-sol", "Reply with exactly: copilot ok"),
    ]);
    const client = await lab.connect();
    const codex = turns.find(result => result.provider === "codex");
    assert(codex.threadId, "The Codex turn never created a thread");
    const read = await client.rpc("thread/read", { threadId: codex.threadId, includeTurns: false });
    const claude = turns.find(result => result.provider === "claude");
    if (claude.threadId) await client.rpc("claude/thread/release", { threadId: claude.threadId });
    const receipt = {
        providers, turns, codexThread: { modelProvider: read.result?.thread?.modelProvider, model: read.result?.thread?.model },
    };
    console.log(JSON.stringify(receipt, null, 2));
    for (const result of turns) assert.equal(result.exitCode, 0, `${result.provider} turn failed: ${result.stderr}`);
    assert.equal(receipt.codexThread.modelProvider, "copilot");
} catch (error) {
    failure = error;
    console.error(JSON.stringify({ error: String(error.message), isolatedHome: lab.root }));
} finally {
    try { await lab.stop(); } catch (error) { failure ??= error; await lab.forceStop(); }
    try { await lab.stopNativeDaemon(lab.nativeDefault); } catch (error) { failure ??= error; }
    await Promise.all(secrets.map(path => rm(path, { force: true })));
    if (!failure) await lab.removeRoot();
}
process.exit(failure ? 1 : 0);
