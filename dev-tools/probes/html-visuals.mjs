import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

if (process.argv[2] === "--help") {
    console.log("Usage: bun dev-tools/probes/html-visuals.mjs CANDIDATE_BINARY ABSOLUTE_EVIDENCE_DIRECTORY [COMMA_SEPARATED_CASE_IDS]\nRuns 12 fresh cases each through Claude Opus 5.5 and Codex GPT-6.1 Sol using an owned isolated gateway/daemon and the host router. Production stays unchanged.");
    process.exit(0);
}
const [binary, evidence, selectedCases] = process.argv.slice(2);
assert(binary && evidence && isAbsolute(binary) && isAbsolute(evidence), "Pass absolute candidate and evidence paths");
assert(!hostname().includes("mac-mini"), "Run real-provider evaluation on the MacBook");
await mkdir(evidence, { recursive: true, mode: 0o700 });
const lab = await IsolatedGateway.create(binary);
const wrapper = resolve(import.meta.dir, "../rc-gateway");
const cases = [
    { id: "publication-only", useful: true, omitEmbed: true, prompt: "Publish an inline HTML visual comparing option A at 10 ms and option B at 30 ms. Once publication succeeds, finish with only the sentence: Option A is faster. Do not paste any embed, URI, digest or reference in your answer." },
    { id: "latency", useful: true, prompt: "Help me see how typical and slow API request latency changed across these eight days. p50 milliseconds: 110,115,118,122,125,130,126,120. p95: 210,215,230,310,390,420,350,280. Show the trends together and explain when tail latency diverged." },
    { id: "pricing", useful: true, prompt: "Compare total costs over 1–24 months for A: $120 setup+$12/month, B: no setup+$20/month, C: $240 setup+$8/month. I want to see their cost curves and break-even points as I change how long I keep the service. Explain which is cheapest in the different ranges." },
    { id: "weekly-layout", useful: true, prompt: "Make an at-a-glance weekly study plan with a compact visual layout: Mon algorithms 09–11, Tue databases 13–15, Wed algorithms 09–11 plus project 13–16, Thu databases 10–12, Fri project 09–12. Keep days aligned, give subjects distinct colors, and make durations visible without reading each time." },
    { id: "growth", useful: true, prompt: "Help me explore compound growth starting from 10. Let me vary growth rate from 0 to 30 percent and years from 1 to 20 and immediately see the resulting curve and final value. Explain the key idea in a sentence." },
    { id: "local-images", useful: true, images: true, prompt: "photo.heic and screen.png in the current directory are two images I want to compare. Show them side by side with each one's pixel dimensions underneath, and tell me in a sentence which is larger." },
    { id: "tradeoffs", useful: true, prompt: "Compare SQLite and PostgreSQL for a small single-server web app on setup, concurrency, backups and scaling, then recommend one." },
    { id: "animation", useful: true, prompt: "Animate bubble sort on [5, 1, 4, 2, 8] so I can watch each comparison and swap happen." },
    { id: "fact", useful: false, prompt: "What is the capital of Sweden? One sentence." },
    { id: "command", useful: false, prompt: "Give me the rg command to find files containing TODO under src, with filenames and line numbers. I need to copy the command." },
    { id: "sequence", useful: true, prompt: "Show the standard sequence of browser sending GET /profile, API reading the user from the database, database returning the user, and API returning JSON to the browser. Use a simple sequence diagram." },
    { id: "code-change", useful: false, prompt: "Create clamp.py with clamp(value, lower, upper) returning value constrained to the inclusive bounds, rejecting lower greater than upper. Use simple Python and briefly tell me how to call it." },
];
const selected = selectedCases ? new Set(selectedCases.split(",")) : new Set(cases.map(test => test.id));
assert(selected.size && [...selected].every(id => cases.some(test => test.id === id || ["claude", "codex"].some(provider => `${provider}-${test.id}` === id))), "Unknown evaluation case ID");
const results = [];
const children = new Set();
let failure;
let cleanupPassed = true;
let interrupted = false;
let hostValues;
let productionBefore;
function interrupt() {
    interrupted = true;
    for (const child of children) child.kill("SIGTERM");
}
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);

function digest(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function jsonLines(text) { return text.split("\n").filter(Boolean).map(line => JSON.parse(line)); }
function textContent(item) {
    const blocks = item.result?.content ?? item.contentItems ?? [];
    return blocks.flatMap(block => {
        if (typeof block.text !== "string") return [];
        try {
            const nested = JSON.parse(block.text);
            if (Array.isArray(nested.content)) return nested.content.flatMap(content => typeof content.text === "string" ? [content.text] : []);
        } catch {}
        return [block.text];
    });
}
function visibleEmbedLine(text, embed) {
    let fence;
    for (const line of text.split("\n")) {
        const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
        if (marker) {
            if (!fence) fence = marker[1][0];
            else if (fence === marker[1][0]) fence = undefined;
        } else if (!fence && line === embed) return true;
    }
    return false;
}
async function productionSnapshot(values) {
    if (!values.RC_CODEX_GATEWAY_PORT || !values.RC_CODEX_GATEWAY_AUTH_TOKEN) return null;
    try {
        const request = path => fetch(`http://127.0.0.1:${values.RC_CODEX_GATEWAY_PORT}${path}`, {
            headers: { Authorization: `Bearer ${values.RC_CODEX_GATEWAY_AUTH_TOKEN}` },
            signal: AbortSignal.timeout(10000),
        }).then(response => { assert(response.ok, "Production snapshot unavailable"); return response.json(); });
        const [version, health] = await Promise.all([request("/version"), request("/health")]);
        return { version, codexPid: health.codexPid };
    } catch { return null; }
}
async function rpc(client, method, params) {
    const response = await client.rpc(method, params);
    assert(!response.error, `${method} failed: ${response.error?.message}`);
    return response.result;
}
async function itemsFor(client, threadId) {
    const items = [];
    let cursor;
    for (let page = 0; page < 10; page++) {
        const result = await rpc(client, "thread/items/list", { threadId, limit: 100, sortDirection: "asc", ...(cursor ? { cursor } : {}) });
        assert(Array.isArray(result.data), "History page has no data");
        items.push(...result.data.map(entry => entry.item));
        cursor = result.nextCursor;
        if (!cursor) return items;
    }
    throw new Error("Case exceeded 1,000 history items");
}
async function modelEvidence(provider, cwd, threadId, events) {
    const path = provider === "claude"
        ? join(lab.realHome, ".claude/projects", cwd.replaceAll("/", "-"), `${threadId.slice(7)}.jsonl`)
        : events.map(event => event.result?.thread?.path).find(Boolean);
    if (!path || !(await Bun.file(path).exists())) return null;
    const models = [...new Set(jsonLines(await readFile(path, "utf8")).flatMap(record => [record.payload?.model, record.message?.model, ...Object.keys(record.modelUsage ?? {})]).filter(value => typeof value === "string"))];
    return models.length ? models : null;
}
async function publicationDetails(threadId) {
    const found = value => value && typeof value === "object"
        ? value.tool === "publish_visual" && value.threadId === threadId && value.detail ? [value] : Object.values(value).flatMap(found)
        : [];
    const details = [];
    for await (const path of new Bun.Glob("Library/Logs/remote-coder/journal/gateway-*").scan({ cwd: lab.root, absolute: true, onlyFiles: true })) {
        details.push(...jsonLines(await readFile(path, "utf8")).flatMap(found).map(record => ({ outcome: record.outcome, ...record.detail })));
    }
    return details;
}
async function download(visualDigest) {
    return fetch(lab.base + "/files/download", {
        method: "POST",
        headers: { Authorization: `Bearer ${lab.token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ visualDigest }),
        signal: AbortSignal.timeout(10000),
    });
}
async function evaluate(provider, model) {
    for (const test of cases.filter(test => selected.has(test.id) || selected.has(`${provider}-${test.id}`))) {
        assert(!interrupted, "Evaluation interrupted");
        const id = `${provider}-${test.id}`;
        const cwd = lab.path(id);
        await mkdir(cwd, { recursive: true, mode: 0o700 });
        if (test.images) {
            const photo = "/System/Library/Desktop Pictures/Sonoma.heic";
            await writeFile(join(cwd, "photo.heic"), await readFile(photo), { mode: 0o600 });
            const converted = Bun.spawnSync(["/usr/bin/sips", "-s", "format", "png", "-z", "2048", "2732", photo, "--out", join(cwd, "screen.png")]);
            assert.equal(converted.exitCode, 0, "Could not prepare screen.png");
        }
        const eventPath = join(evidence, `${id}.events.jsonl`);
        const prompt = `${test.prompt}\nAny files you need should stay in the current scratch directory.`;
        await writeFile(join(evidence, `${id}.prompt.txt`), prompt, { mode: 0o600 });
        const args = [wrapper, "--host", "127.0.0.1", "--port", String(lab.port), "--scheme", "ws", "--no-ssh-env", "--local-config", lab.path("no-config.json"), provider === "claude" ? "claude-turn" : "turn", "--model", model, "--effort", "medium", "--cwd", cwd, "--purpose", "probe", "--timeout", "300", "--event-log", eventPath];
        args.push(...(provider === "claude" ? [prompt] : ["--prompt", prompt, "--print-assistant"]));
        const child = Bun.spawn(args, {
            env: { ...process.env, RC_CODEX_GATEWAY_AUTH_TOKEN: lab.token },
            cwd: resolve(import.meta.dir, "../.."),
            stdout: Bun.file(join(evidence, `${id}.stdout.txt`)),
            stderr: Bun.file(join(evidence, `${id}.stderr.txt`)),
        });
        children.add(child);
        const exitCode = await child.exited;
        children.delete(child);
        const events = jsonLines(await readFile(eventPath, "utf8"));
        const threadId = events.find(event => event.type === "thread.started")?.thread_id;
        assert(threadId, `${id} never created a thread`);
        const client = await lab.connect();
        let caseFailure;
        try {
            const items = await itemsFor(client, threadId);
            await writeFile(join(evidence, `${id}.items.json`), JSON.stringify(items, null, 2), { mode: 0o600 });
            const calls = items.filter(item => item.tool === "publish_visual" && ["dynamicToolCall", "mcpToolCall"].includes(item.type));
            const messages = items.filter(item => item.type === "agentMessage").map(item => ({ phase: item.phase, text: item.text }));
            const assistant = messages.filter(message => message.phase !== "commentary").map(message => message.text).join("\n");
            const embeds = calls.flatMap(textContent).flatMap(text => text.split("\n")).filter(text => /^!\[(?:\\.|[^\]\\])*\]\(rc-visual:[a-f0-9]{64}\)$/.test(text));
            const fixtures = [];
            for (const embed of embeds) {
                const hash = embed.match(/rc-visual:([a-f0-9]{64})/)[1];
                const path = lab.path(`.remote-coder/visuals/${hash}.html`);
                const bytes = await readFile(path);
                const metadata = await stat(path);
                assert(bytes.length <= 2 * 1024 * 1024 && digest(bytes) === hash && (metadata.mode & 0o777) === 0o400, "Published store identity, cap or permissions failed");
                const response = await download(hash);
                assert.equal(response.status, 200, "Published visual download failed");
                const downloaded = Buffer.from(await response.arrayBuffer());
                assert.equal(digest(downloaded), hash, "Authenticated download bytes differ from published visual");
                assert(downloaded.equals(bytes), "Authenticated download changed published bytes");
                const fixture = join(evidence, `${id}-${hash}.html`);
                await writeFile(fixture, bytes, { mode: 0o600 });
                const html = bytes.toString("utf8");
                fixtures.push({ hash, fixture, bytes: bytes.length, embeddedImages: (html.match(/data:image\/(?:png|jpeg|gif);base64,/g) ?? []).length, referencesCwd: html.includes(cwd), downloadVerified: true, serverMaximumBytes: 2097152, embed, exactLine: messages.filter(message => message.phase !== "commentary").some(message => visibleEmbedLine(message.text, embed)) });
            }
            const streamed = events.filter(event => event.method === "item/completed").map(event => event.params?.item).filter(Boolean);
            const automaticMetadata = fixtures.every(fixture => calls.some(call => call.rcVisual?.digest === fixture.hash && call.rcVisual?.title === call.arguments?.title));
            const liveMetadataMatches = calls.filter(call => call.rcVisual).every(call => streamed.some(item => item.id === call.id && JSON.stringify(item.rcVisual) === JSON.stringify(call.rcVisual)));
            const omittedEmbed = !assistant.includes("rc-visual:");
            const observedModels = await modelEvidence(provider, cwd, threadId, events);
            const publications = await publicationDetails(threadId);
            const result = { id, provider, requestedModel: model, observedModels, threadId, exitCode, expectedPublish: test.useful, calls: calls.length, successfulEmbeds: embeds.length, messages, fixtures, publications, decisionPassed: test.useful ? fixtures.length > 0 && (!test.images || fixtures.some(fixture => fixture.embeddedImages >= 2 && !fixture.referencesCwd) && publications.some(detail => detail.outcome === "ok" && detail.images >= 2 && detail.converted >= 1)) : calls.length === 0, automaticMetadata, liveMetadataMatches, omittedEmbed, placementPassed: automaticMetadata && liveMetadataMatches && (!test.omitEmbed || omittedEmbed), hasTextSummary: assistant.split("\n").some(line => line.trim() && !line.includes("rc-visual:")), evidenceDirectory: evidence };
            results.push(result);
            await writeFile(join(evidence, "results.json"), JSON.stringify(results, null, 2), { mode: 0o600 });
            console.log(JSON.stringify({ ...result, messages: undefined }));
        } catch (error) {
            caseFailure = error;
        } finally {
            try {
                if (provider === "claude") await rpc(client, "claude/thread/release", { threadId });
            } catch (error) { caseFailure ??= error; }
            client.ws.close();
        }
        if (caseFailure) throw caseFailure;
    }
}

try {
    const source = await readFile(join(lab.realHome, ".remote-coder/codex-gateway.env"), "utf8");
    const values = Object.fromEntries(source.split("\n").flatMap(line => {
        const match = line.match(/^(?:export\s+)?([A-Z_][A-Z_0-9]*)=(.*)$/);
        if (!match) return [];
        const raw = match[2].trim();
        return [[match[1], raw.startsWith('"') && raw.endsWith('"') || raw.startsWith("'") && raw.endsWith("'") ? raw.slice(1, -1) : raw]];
    }));
    hostValues = values;
    productionBefore = await productionSnapshot(values);
    const keys = ["RC_CODEX_GATEWAY_ROUTER_URL", "RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL", "RC_CODEX_GATEWAY_ROUTER_KEY_FILE", "RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT"];
    for (const key of keys) assert(values[key], `Host router setting is missing: ${key}`);
    await mkdir(join(lab.nativeDefault, "packages/standalone"), { recursive: true, mode: 0o700 });
    await symlink(join(lab.realHome, ".codex/packages/standalone/current"), join(lab.nativeDefault, "packages/standalone/current"));
    await lab.write(join(lab.nativeDefault, "config.toml"), 'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    await lab.write(lab.path("gateway.env"), [
        "RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1", `RC_CODEX_GATEWAY_PORT=${lab.port}`,
        `RC_CODEX_GATEWAY_AUTH_TOKEN=${lab.token}`, `RC_CODEX_GATEWAY_CODEX_PATH=${lab.codex}`,
        "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false", ...keys.map(key => `${key}=${values[key]}`),
        `RC_CLAUDE_HOME=${lab.realHome}/.claude`, `RC_CLAUDE_PATH=${values.RC_CLAUDE_PATH ?? `${lab.realHome}/.local/bin/claude`}`,
        `CODEX_HOME=${lab.nativeDefault}`, "RUST_LOG=warn",
        ...(values.RC_CLAUDE_KEYCHAIN_SHIM_DIR ? [`RC_CLAUDE_KEYCHAIN_SHIM_DIR=${values.RC_CLAUDE_KEYCHAIN_SHIM_DIR}`] : []),
    ].join("\n") + "\n");
    await lab.start();
    const oversizedDigest = "f".repeat(64);
    await mkdir(lab.path(".remote-coder/visuals"), { recursive: true, mode: 0o700 });
    const oversized = lab.path(`.remote-coder/visuals/${oversizedDigest}.html`);
    await writeFile(oversized, Buffer.alloc(2097153, 65), { mode: 0o600 });
    const capResponse = await download(oversizedDigest);
    assert.equal(capResponse.status, 413, "Server visual download limit did not reject oversized file");
    const capBody = await capResponse.json();
    assert.equal(capBody.kind, "tooLarge", "Oversized rejection lacked explicit size failure");
    await writeFile(join(evidence, "transport-cap.json"), JSON.stringify({ serverMaximumBytes: 2097152, fixtureBytes: 2097153, status: capResponse.status, response: capBody }, null, 2), { mode: 0o600 });
    const identity = await lab.request("/version");
    await writeFile(join(evidence, "candidate.json"), JSON.stringify({ identity, binary, binarySha256: digest(await readFile(binary)), isolatedHome: lab.root, port: lab.port, productionBefore }, null, 2), { mode: 0o600 });
    const evaluations = await Promise.allSettled([evaluate("claude", "claude-opus-5-5"), evaluate("codex", "gpt-6.1-sol")]);
    const failed = evaluations.find(result => result.status === "rejected");
    if (failed) throw failed.reason;
    assert(results.every(result => result.exitCode === 0 && result.decisionPassed && result.placementPassed && result.hasTextSummary), "Agent behavior evaluation failed; inspect results.json");
} catch (error) {
    failure = error;
    console.error(JSON.stringify({ error: String(error.message), evidenceDirectory: evidence, isolatedHome: lab.root }));
} finally {
    for (const child of children) child.kill("SIGTERM");
    await Promise.allSettled([...children].map(child => child.exited));
    try {
        for (const name of ["gateway.log", "gateway-errors.log"]) {
            const path = lab.path(name);
            if (await Bun.file(path).exists()) await writeFile(join(evidence, name), await readFile(path), { mode: 0o600 });
        }
        for (const [name, relative] of [["owned-trace.log", "Library/Logs/remote-coder/codex-gateway"], ["owned-journal.jsonl", "Library/Logs/remote-coder/journal/gateway-"]]) {
            const files = [];
            for await (const path of new Bun.Glob(relative + "*").scan({ cwd: lab.root, absolute: true, onlyFiles: true })) files.push(path);
            await writeFile(join(evidence, name), Buffer.concat(await Promise.all(files.sort().map(path => readFile(path)))), { mode: 0o600 });
        }
    } catch (error) { failure ??= error; }
    try { await lab.stop(); } catch (error) { cleanupPassed = false; failure ??= error; await lab.forceStop(); }
    try { if (await lab.stopNativeDaemon(lab.nativeDefault) !== 0) cleanupPassed = false; } catch (error) { cleanupPassed = false; failure ??= error; }
    const productionAfter = hostValues ? await productionSnapshot(hostValues) : null;
    await writeFile(join(evidence, "summary.json"), JSON.stringify({ productionBefore, productionAfter, productionIdentityStable: productionBefore && productionAfter ? JSON.stringify(productionBefore) === JSON.stringify(productionAfter) : null, cases: results.length, decisionPassed: results.filter(result => result.decisionPassed).length, placementPassed: results.every(result => result.placementPassed), cleanupPassed, failure: failure ? String(failure.message) : null, isolatedHome: lab.root }, null, 2), { mode: 0o600 });
    if (cleanupPassed) await lab.removeRoot();
}
if (failure || !cleanupPassed) process.exitCode = 1;
