import assert from "node:assert/strict";
import { mkdir, readFile, writeFile, symlink, access } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { IsolatedGateway } from "./isolated-gateway.mjs";

export class NativeClient {
    constructor(codex, home, root, transport = "stdio") {
        this.pending = new Map();
        this.events = [];
        this.next = 0;
        this.child = Bun.spawn([codex, "app-server", transport === "proxy" ? "proxy" : "--stdio"], {
            env: { HOME: root, CODEX_HOME: home, PATH: "/opt/homebrew/bin:/usr/bin:/bin", USER: "developer", RUST_LOG: "error" },
            cwd: root, stdin: "pipe", stdout: "pipe", stderr: Bun.file(join(root, "native-errors.log")),
        });
        this.reader = this.read();
    }
    async read() {
        let buffered = "";
        const decoder = new TextDecoder();
        for await (const chunk of this.child.stdout) {
            buffered += decoder.decode(chunk, { stream: true });
            while (buffered.includes("\n")) {
                const end = buffered.indexOf("\n"), line = buffered.slice(0, end);
                buffered = buffered.slice(end + 1);
                if (!line) continue;
                const value = JSON.parse(line), waiter = this.pending.get(value.id);
                if (waiter) { this.pending.delete(value.id); waiter(value); }
                else this.events.push(value);
            }
        }
    }
    async rpc(method, params = {}) {
        const id = ++this.next;
        const promise = new Promise(resolve => this.pending.set(id, resolve));
        this.child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
        let timer;
        try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${method} timed out`)), 45000); })]); }
        finally { clearTimeout(timer); }
    }
    async initialize() {
        await call(this, "initialize", { clientInfo: { name: "codex_adoption_fixture", version: "1" }, capabilities: { experimentalApi: true } });
        this.child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
        return this;
    }
    async stop() {
        this.child.stdin.end();
        const result = await Promise.race([this.child.exited, Bun.sleep(5000).then(() => null)]);
        if (result === null) { this.child.kill("SIGTERM"); await this.child.exited; }
        await this.reader;
    }
}

async function call(client, method, params) {
    const response = await client.rpc(method, params).catch(error => { throw new Error(`${method} ${params.threadId ?? ""}: ${error.message}`); });
    assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
    return response.result;
}

async function pages(client, method, params) {
    const data = [], seen = new Set();
    let cursor;
    do {
        const result = await call(client, method, { ...params, cursor, limit: 20 });
        assert(Array.isArray(result.data), `${method} returned no data array`);
        data.push(...result.data);
        cursor = result.nextCursor;
        if (cursor) { assert(!seen.has(cursor), `${method} repeated a cursor`); seen.add(cursor); }
        assert(seen.size < 100000, "Unbounded history traversal");
    } while (cursor);
    return data;
}

export async function snapshot(client, homes = [], nativeRows = []) {
    const hash = value => {
        const normalize = (_, item) => {
            if (!item || typeof item !== "object" || Array.isArray(item)) return item;
            if (item.type === "image" && typeof item.data === "string" && item.data) {
                item = { ...item, data: "", rcImageOmitted: { mimeType: item.mimeType ?? null, omittedBytes: Buffer.byteLength(item.data) } };
            }
            for (const key of ["imageUrl", "url"]) {
                if (typeof item[key] === "string" && item[key].startsWith("data:")) {
                    const mimeType = item[key].slice(5).split(",")[0].split(";")[0] || "text/plain";
                    item = { ...item, [key]: "", rcImageOmitted: { mimeType, omittedBytes: Buffer.byteLength(item[key]) } };
                }
            }
            if (item.type === "text" && typeof item.text === "string" && item.text.trimStart().startsWith("{") && item.text.includes('"content"')) {
                try { item = { ...item, text: JSON.stringify(JSON.parse(item.text), normalize) }; } catch {}
            }
            return Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b)));
        };
        let text = JSON.stringify(value, normalize);
        for (const home of homes) text = text.replaceAll(home, "<CODEX_HOME>");
        return createHash("sha256").update(text).digest("hex");
    };
    const output = {};
    for (const archived of [false, true]) {
        const headers = await pages(client, "thread/list", {
            archived, useStateDbOnly: true, modelProviders: [], sourceKinds: ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"],
        });
        assert.equal(new Set(headers.map(thread => thread.id)).size, headers.length, "Duplicate thread/list IDs");
        const listed = new Set(headers.map(thread => thread.id));
        for (const row of nativeRows.filter(row => Boolean(row.archived) === archived)) {
            if (!listed.has(row.id)) headers.push(row);
        }
        const selected = nativeRows.length ? headers.filter(header => nativeRows.some(row => row.id === header.id)) : headers;
        const descendants = [];
        for (const parent of selected) descendants.push(...await pages(client, "thread/list", { archived, ancestorThreadId: parent.id, modelProviders: [], useStateDbOnly: true }));
        for (const child of descendants) listed.add(child.id);
        for (const header of [...selected, ...descendants]) {
            if (output[header.id]) continue;
            const read = await call(client, "thread/read", { threadId: header.id, includeTurns: false });
            const turns = await pages(client, "thread/turns/list", { threadId: header.id, sortDirection: "asc", itemsView: "notLoaded" });
            const items = await pages(client, "thread/items/list", { threadId: header.id, sortDirection: "asc" });
            const queue = archived ? null : await pages(client, "thread/queue/list", { threadId: header.id });
            output[header.id] = { archived, listed: listed.has(header.id), name: read.thread.name, previewSha256: hash(read.thread.preview),
                turns: turns.length, items: items.length, turnsSha256: hash(turns), itemsSha256: hash(items),
                queueCount: queue === null ? null : queue.length, queueSha256: hash(queue) };
        }
    }
    return output;
}

function modelServer() {
    let spawned = false, count = 0;
    return Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
        if (request.method !== "POST") return Response.json({ data: [] });
        const body = await request.json();
        const text = JSON.stringify(body.input);
        const id = `resp_${++count}`;
        const events = [{ type: "response.created", response: { id } }];
        if (text.includes("ADOPTION_SPAWN") && !spawned) {
            spawned = true;
            events.push({ type: "response.output_item.done", item: { type: "function_call", call_id: "adoption_spawn", namespace: "collaboration", name: "spawn_agent",
                arguments: JSON.stringify({ message: "Child fixture", task_name: "fixture_child", fork_turns: "none" }) } });
        } else {
            for (let n = 0; n < 55; n++) events.push({ type: "response.output_item.done", item: {
                type: "message", role: "assistant", id: `msg_${count}_${n}`, phase: n === 54 ? "final_answer" : "commentary",
                content: [{ type: "output_text", text: `Adoption native item ${n}.` }] } });
        }
        events.push({ type: "response.completed", response: { id, usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20 } } });
        return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""), { headers: { "Content-Type": "text/event-stream" } });
    } });
}

export async function fixture(codex, home, root) {
    await mkdir(home, { recursive: true, mode: 0o700 });
    const server = modelServer();
    await writeFile(join(home, "config.toml"), `model = "gpt-5.4"\nmodel_provider = "fixture"\napproval_policy = "never"\nsandbox_mode = "read-only"\n[features]\ncollab = true\nmulti_agent_v2 = true\n[model_providers.fixture]\nname = "fixture"\nbase_url = "http://127.0.0.1:${server.port}/v1"\nwire_api = "responses"\n[analytics]\nenabled = false\n`, { mode: 0o600 });
    const client = await new NativeClient(codex, home, root).initialize();
    try {
        for (const historyMode of ["legacy", "paginated"]) {
            const { thread } = await call(client, "thread/start", { cwd: root, historyMode, model: "gpt-5.4", approvalPolicy: "never", sandbox: "read-only" });
            for (let n = 0; n < 3; n++) {
                const { turn } = await call(client, "turn/start", { threadId: thread.id, input: [{ type: "text", text: n === 0 && historyMode === "paginated" ? "ADOPTION_SPAWN" : `Fixture ${n}` }] });
                const until = Date.now() + 20000;
                while (!client.events.some(event => event.method === "turn/completed" && event.params?.turn?.id === turn.id)) {
                    assert(Date.now() < until, "Fixture turn did not complete; inspect native-errors.log");
                    await Bun.sleep(20);
                }
                const completed = client.events.find(event => event.method === "turn/completed" && event.params?.turn?.id === turn.id);
                assert.equal(completed.params.turn.status, "completed", JSON.stringify(completed));
            }
            await call(client, "thread/name/set", { threadId: thread.id, name: `Native adoption ${historyMode}` });
            if (historyMode === "legacy") await call(client, "thread/archive", { threadId: thread.id });

        }
        await Bun.sleep(500);
        const spawned = client.events.find(event => event.method === "item/completed" && event.params?.item?.type === "subAgentActivity" && event.params.item.agentThreadId);
        if (spawned) await call(client, "thread/name/set", { threadId: spawned.params.item.agentThreadId, name: "Native adoption child" });
        } finally { await client.stop(); await server.stop(true); }
    const reopened = await new NativeClient(codex, home, root).initialize();
    try {
        const data = await snapshot(reopened);
        const threadId = Object.keys(data).find(id => data[id].name === "Native adoption paginated");
        assert(threadId, "Missing native paginated fixture");
        await call(reopened, "thread/queue/add", { threadId, input: [{ type: "text", text: "Preserved native queue" }], clientUserMessageId: "adoption-queue" });
        return await snapshot(reopened);
    } finally { await reopened.stop(); }
}

async function command(argv, env) {
    const child = Bun.spawn(argv, { env, stdout: "pipe", stderr: "pipe" });
    const [code, error] = await Promise.all([child.exited, new Response(child.stderr).text()]);
    assert.equal(code, 0, `${argv[0]} failed: ${error}`);
}

export async function prepareClones(lab, id = "393971f9-71aa-4a14-aa7e-e103f296dfc2", profile = lab.path(`.rca/${id.replaceAll("-", "")}`), source = join(profile, "c")) {
    const cloneEntries = async (original, destination, entries) => {
        await mkdir(destination, { recursive: true, mode: 0o700 });
        for (const entry of entries) {
            const path = join(original, entry);
            try { await access(path); } catch { continue; }
            await command(["/bin/cp", "-cR", path, join(destination, entry)]);
        }
    };
    const originalProfile = join(lab.realHome, ".rca", id.replaceAll("-", ""));
    for (const [original, home] of [[join(lab.realHome, ".codex"), lab.nativeDefault], [join(originalProfile, "c"), source]]) {
        const databases = ["state_5.sqlite", "thread_history_1.sqlite", "queue_1.sqlite", "goals_1.sqlite", "memories_1.sqlite", "memories_v2_1.sqlite"];
        await cloneEntries(original, home, ["sessions", "archived_sessions", "shell_snapshots", "memories", "memories_v2", "attachments", "session_index.jsonl",
            ...databases.flatMap(name => [name, name + "-wal", name + "-shm"])]);
        await command(["python3", resolve(import.meta.dir, "codex-adoption-rebase.py"), original, home]);
        await writeFile(join(home, "config.toml"), "cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n", { mode: 0o600 });
    }
    const states = ["session-metadata-v2.json", "agent-calls.json", "live-activity-finished-turns.json", "conversation-marks.json",
        "conversation-marks.v2.json", "conversation-marks.v3.json", "questions", "queues"];
    await cloneEntries(join(originalProfile, "state"), join(profile, "state"), states);
    await cloneEntries(join(lab.realHome, ".remote-coder"), lab.path(".remote-coder"), [...states, "account-enrollments.json", "claude-profile-migration.json"]);
}

if (import.meta.main) {
    const [binary, mode = "fixture", preparedRoot] = process.argv.slice(2);
    assert(binary, "Usage: bun codex-adoption.mjs GATEWAY_BINARY [fixture|clones]");
    assert(["fixture", "clones"].includes(mode));
    const lab = await IsolatedGateway.create(resolve(binary));
    if (preparedRoot) {
        assert(mode === "clones" && preparedRoot.startsWith("/private/tmp/r"), "Expected an isolated prepared APFS-clone root");
        await lab.removeRoot();
        lab.root = preparedRoot;
        lab.nativeDefault = join(preparedRoot, ".codex");
        lab.safeEnv.HOME = preparedRoot;
        lab.safeEnv.CODEX_HOME = lab.nativeDefault;
    }
    const id = "393971f9-71aa-4a14-aa7e-e103f296dfc2";
    const profile = lab.path(`.rca/${id.replaceAll("-", "")}`), source = join(profile, "c");
    let failure;
    try {
        await mkdir(profile, { recursive: true, mode: 0o700 });
        if (mode === "clones") {
            if (!preparedRoot) await prepareClones(lab, id, profile, source);
        } else await fixture(lab.codex, source, lab.root);
        const inventory = Bun.spawn(["python3", "-c", "import sqlite3,json,sys; c=sqlite3.connect(\"file:\"+sys.argv[1]+\"?mode=ro\",uri=True); print(json.dumps([{\"id\":r[0],\"archived\":r[1]} for r in c.execute(\"SELECT id,archived FROM threads\")]))", join(source,"state_5.sqlite")], { stdout: "pipe", stderr: "pipe" });
        const nativeRows = JSON.parse(await new Response(inventory.stdout).text());
        assert.equal(await inventory.exited, 0, "Could not enumerate cloned native source IDs");
        const sourceClient = await new NativeClient(lab.codex, source, lab.root).initialize();
        let before;
        try { before = await snapshot(sourceClient, [source, lab.nativeDefault], nativeRows); } finally { await sourceClient.stop(); }
        assert(Object.keys(before).length > 0, "No source conversations");
        for (const home of [lab.nativeDefault, source]) {
            const current = join(home, "packages/app-server-daemon/current");
            await mkdir(join(home, "packages/app-server-daemon"), { recursive: true, mode: 0o700 });
            try { await access(current); }
            catch { await symlink(join(lab.realHome, ".codex/packages/standalone/current"), current); }
        }
        await lab.writeGatewayEnv([]);
        const migrated = await Bun.file(lab.path(".remote-coder/codex-profile-migration.json")).json().catch(() => null);
        if (!migrated?.complete) {
            await command([lab.codex, "app-server", "daemon", "start"], { ...lab.safeEnv, CODEX_HOME: source });
            assert(await lab.hasNativeDaemon(source), "Source enrollment daemon did not start");
        }
        const normalize = value => JSON.parse(JSON.stringify(value).replaceAll(source, "<CODEX_HOME>").replaceAll(lab.nativeDefault, "<CODEX_HOME>"));
        const receipt = [];
        let firstAfter, migrationReceipt;
        for (let startup = 0; startup < 2; startup++) {
            await lab.start();
            const accounts = await lab.request("/accounts");
            assert.deepEqual(accounts.accounts.map(account => account.id).sort(), ["default-claude", "default-codex"]);
            const client = await lab.connect();
            await lab.waitFor(async () => (await call(client, "daemon/activeTurns", {})).coverage.codex === true);
            const after = await snapshot(client, [source, lab.nativeDefault], nativeRows);
            if (firstAfter) assert.deepEqual(after, firstAfter, "Second startup changed native history");
            else firstAfter = after;
            const persistedReceipt = await readFile(lab.path(".remote-coder/codex-profile-migration.json"), "utf8");
            if (migrationReceipt) assert.equal(persistedReceipt, migrationReceipt, "Second startup changed the adoption receipt");
            else migrationReceipt = persistedReceipt;
            assert(!await lab.hasNativeDaemon(source), "Retired native enrollment daemon still has a PID file");
            assert(await lab.hasNativeDaemon(lab.nativeDefault), "Default native daemon is not running");
            for (const [thread, data] of Object.entries(before)) assert.deepEqual(normalize(after[thread]), normalize(data), `Thread changed: ${thread}`);
            for (const generation of [0, 1, 999999]) {
                const redirected = await lab.connect(id, generation);
                const threadId = Object.keys(before)[0];
                await call(redirected, "thread/read", { threadId, includeTurns: false });
                redirected.ws.close();
            }
            receipt.push({ startup: startup + 1, threads: Object.keys(before).length,
                turns: Object.values(before).reduce((n, t) => n + t.turns, 0), items: Object.values(before).reduce((n, t) => n + t.items, 0) });
            await lab.stop();
        }
        await command(["python3", resolve(import.meta.dir, "codex-adoption-native-check.py"), source, lab.nativeDefault]);
        await writeFile(lab.path("adoption-acceptance.json"), JSON.stringify(receipt, null, 2));
        console.log(JSON.stringify({ passed: true, mode, receipt }));
    } catch (error) { failure = error; console.error(JSON.stringify({ passed: false, root: lab.root, error: String(error.stack) })); }
    finally {
        try { await lab.stop(); } catch { await lab.forceStop(); }
        for (const home of [source, lab.nativeDefault]) await lab.stopNativeDaemon(home);
        if (!failure) await lab.removeRoot();
    }
    if (failure) process.exitCode = 1;
}
