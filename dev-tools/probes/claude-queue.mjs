import assert from "node:assert/strict";
import { mkdir, readFile, symlink } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { IsolatedGateway, startStubRouter } from "./isolated-gateway.mjs";

if (process.argv[2] === "--help") {
    console.log("Usage: bun dev-tools/probes/claude-queue.mjs CANDIDATE_BINARY [CLAUDE_MODEL]\nRuns an owned isolated gateway whose Claude turns use the host router. Queues Claude messages behind a running shell turn and proves they run as separate FIFO successor turns carrying their canonical clientUserMessageId, that a removed message never runs, that the thread ends idle, that the queue holds after Stop until Send Now, that queued messages survive a planned gateway restart and run after the resumed turn, and that a planned restart during a queue-started turn resumes that turn once and still runs the next message as its own successor turn without a hold. Production stays unchanged; success removes the isolated home, failure retains it.");
    process.exit(0);
}
const [binary, model = "claude-sonnet-5"] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
const lab = await IsolatedGateway.create(binary);
const work = lab.path("work");
const marker = crypto.randomUUID().slice(0, 8);
const clientId = label => `rc-claude-queue-${marker}-${label}`;
const HELD_SECONDS = 20;
let failure;
let client;
let threadId;

async function hostRouter() {
    const env = await readFile(join(lab.realHome, ".remote-coder/codex-gateway.env"), "utf8");
    const value = name => env.match(new RegExp(`^(?:export\\s+)?${name}="?([^"\\n]+)"?$`, "m"))?.[1];
    const url = value("RC_CODEX_GATEWAY_ROUTER_URL");
    const keyFile = value("RC_CODEX_GATEWAY_ROUTER_KEY_FILE");
    assert(url && keyFile, "The host gateway has no router for Claude inference");
    return { url, key: (await readFile(keyFile, "utf8")).trim() };
}

async function connect() {
    const connection = await lab.connect();
    const notifications = [];
    connection.ws.addEventListener("message", event => {
        const message = JSON.parse(String(event.data));
        if (message.method && message.params?.threadId === threadId) notifications.push(message);
    });
    const call = async (method, params) => {
        const response = await connection.rpc(method, params);
        assert(!response.error, `${method} failed: ${JSON.stringify(response.error)}`);
        return response.result;
    };
    if (threadId) await call("conversation/subscriptions/set", { threadIds: [threadId] });
    return { ...connection, notifications, call };
}

const text = value => [{ type: "text", text: value }];

async function history() {
    const turns = await client.call("thread/turns/list", { threadId, limit: 100, sortDirection: "asc" });
    const items = [];
    let cursor = null;
    do {
        const page = await client.call("thread/items/list", { threadId, limit: 100, cursor });
        items.push(...page.data);
        cursor = page.nextCursor ?? null;
    } while (cursor);
    return turns.data.map(turn => ({
        id: turn.id,
        status: turn.status,
        clientIds: items.filter(entry => entry.turnId === turn.id && entry.item.type === "userMessage")
            .map(entry => entry.item.clientId).filter(Boolean),
    }));
}

async function queued() {
    const result = await client.call("thread/queue/list", { threadId, limit: 100 });
    assert.equal(result.nextCursor ?? null, null, "The probe queue spans more than one page");
    return { ids: result.data.map(entry => entry.clientUserMessageId), hold: result.hold ?? null, data: result.data };
}

async function idle() {
    const active = await client.call("daemon/activeTurns", {});
    assert.equal(active.coverage?.claude, true, "Claude activity coverage is unavailable");
    return !active.activeTurns.some(turn => turn.threadId === threadId);
}

async function busyTurn(label, seconds) {
    const id = clientId(label);
    const result = await client.call("turn/start", {
        threadId, input: text(`RemoteCoder queued-message probe. Run exactly /bin/sleep ${seconds} with your Bash tool, then reply with only ACK. Do not read or write files and do not run any other command.`),
        clientUserMessageId: id, model, effort: "low", cwd: work,
    });
    const turnId = result.turn?.id;
    assert(turnId, "turn/start returned no exact turn id");
    await lab.waitFor(() => client.notifications.some(message => message.method === "item/started"
        && message.params.turnId === turnId && message.params.item?.type === "commandExecution"), 120);
    return { turnId, clientId: id };
}

async function enqueue(label, seconds = 0) {
    const id = clientId(label);
    const input = text(seconds
        ? `RemoteCoder queued-message probe ${label}. Run exactly /bin/sleep ${seconds} with your Bash tool, then reply with only QUEUED. Do not read or write files and do not run any other command.`
        : `RemoteCoder queued-message probe ${label}. Reply with only QUEUED. Do not use tools.`);
    const added = await client.call("thread/queue/add", { threadId, input, clientUserMessageId: id });
    assert.equal(added.queuedSubmission?.clientUserMessageId, id, "thread/queue/add did not echo the canonical clientUserMessageId");
    const repeated = await client.call("thread/queue/add", { threadId, input, clientUserMessageId: id });
    assert.equal(repeated.queuedSubmission?.id, added.queuedSubmission.id, "a repeated add created a second entry");
    return { id, submissionId: added.queuedSubmission.id };
}

async function settled(seconds = 300) {
    await lab.waitFor(async () => (await queued()).ids.length === 0 && await idle(), seconds);
    return await history();
}

function successors(turns, running, expected) {
    const index = turns.findIndex(turn => turn.id === running.turnId);
    assert(index >= 0, `turn ${running.turnId} is missing from history`);
    const carrying = turns.slice(index + 1).filter(turn => turn.clientIds.length);
    for (const id of expected) assert(!turns[index].clientIds.includes(id), `${id} joined the running turn`);
    assert.deepEqual(carrying.map(turn => turn.clientIds), expected.map(id => [id]),
        "queued messages did not run as separate FIFO successor turns");
    for (const turn of carrying) assert.equal(turn.status, "completed", `queued turn ${turn.id} ended ${turn.status}`);
    return carrying.map(turn => turn.id);
}

async function fifoPhase() {
    const running = await busyTurn("running", 20);
    const first = await enqueue("first");
    const removed = await enqueue("removed");
    const second = await enqueue("second");
    assert.deepEqual((await queued()).ids, [first.id, removed.id, second.id]);
    assert(client.notifications.some(message => message.method === "thread/queue/changed"),
        "a scoped subscriber never received thread/queue/changed");
    assert.equal((await client.call("thread/queue/delete", { threadId, queuedSubmissionId: removed.submissionId })).deleted, true);
    assert.deepEqual((await queued()).ids, [first.id, second.id], "Remove from Queue left the message listed");
    const turns = await settled();
    assert.equal(turns.find(turn => turn.id === running.turnId)?.status, "completed");
    const queuedTurnIds = successors(turns, running, [first.id, second.id]);
    assert(!turns.some(turn => turn.clientIds.includes(removed.id)), "a removed message ran");
    return { runningTurnId: running.turnId, queuedTurnIds, removedClientId: removed.id };
}

async function heldPhase() {
    const stopped = await busyTurn("stopped", 30);
    const held = await enqueue("held");
    await client.call("turn/interrupt", { threadId, turnId: stopped.turnId });
    await lab.waitFor(async () => (await history()).find(turn => turn.id === stopped.turnId)?.status === "interrupted", 60);
    const before = (await history()).length;
    await Bun.sleep(HELD_SECONDS * 1000);
    assert.equal((await history()).length, before, "a queued message started after Stop instead of being held");
    assert.deepEqual((await queued()).ids, [held.id], "the held message is no longer queued");
    assert(await idle(), "the thread is busy while its queue is held");
    const started = await client.call("thread/queue/start", { threadId, queuedSubmissionId: held.submissionId });
    const sendNowTurnId = started.turn?.id;
    assert(sendNowTurnId, "thread/queue/start returned no exact turn id");
    const turns = await settled();
    const sendNow = turns.find(turn => turn.id === sendNowTurnId);
    assert.deepEqual(sendNow?.clientIds, [held.id], "the Send Now turn did not carry the held message");
    assert.equal(sendNow.status, "completed");
    assert(!turns.find(turn => turn.id === stopped.turnId).clientIds.includes(held.id), "the held message joined the stopped turn");
    return { stoppedTurnId: stopped.turnId, heldSeconds: HELD_SECONDS, sendNowTurnId };
}

async function restartPhase() {
    const running = await busyTurn("restarted", 25);
    const first = await enqueue("after-restart-first");
    const second = await enqueue("after-restart-second");
    const restartMs = await restart();
    const survived = await queued();
    const recorded = await history();
    const ran = recorded.filter(turn => turn.clientIds.includes(first.id) || turn.clientIds.includes(second.id));
    assert.deepEqual([...ran.flatMap(turn => turn.clientIds), ...survived.ids], [first.id, second.id],
        "queued messages did not survive the planned restart in order");
    const turns = await settled();
    const queuedTurnIds = successors(turns, running, [first.id, second.id]);
    const resumed = turns.slice(turns.findIndex(turn => turn.id === running.turnId) + 1)
        .filter(turn => !turn.clientIds.length);
    assert(resumed.length > 0, "the planned restart did not resume the interrupted turn before the queue drained");
    return { restartedTurnId: running.turnId, restartMs, listedAfterRestart: survived.ids.length,
        resumedTurnIds: resumed.map(turn => turn.id), queuedTurnIds };
}

async function restart() {
    const stopStarted = Date.now();
    await lab.stop();
    await lab.start();
    const restartMs = Date.now() - stopStarted;
    client = await connect();
    return restartMs;
}

async function queueStartedRestartPhase() {
    const running = await busyTurn("before-queued-restart", 10);
    const first = await enqueue("queued-restart-first", 30);
    const second = await enqueue("queued-restart-second");
    let firstTurnId;
    await lab.waitFor(async () => {
        firstTurnId = (await history()).find(turn => turn.clientIds.includes(first.id))?.id;
        return firstTurnId && client.notifications.some(message => message.method === "item/started"
            && message.params.turnId === firstTurnId && message.params.item?.type === "commandExecution");
    }, 180);
    assert.deepEqual((await queued()).ids, [second.id], "the first queued message did not leave the queue when its turn started");
    const restartMs = await restart();
    const holds = [];
    await lab.waitFor(async () => {
        const listed = await queued();
        if (listed.hold) holds.push(listed.hold);
        return listed.ids.length === 0 && await idle();
    }, 300);
    assert.deepEqual(holds, [], "the queue was held after a planned restart of a queue-started turn");
    const turns = await history();
    const firstIndex = turns.findIndex(turn => turn.id === firstTurnId);
    const carrying = id => turns.filter(turn => turn.clientIds.includes(id));
    assert.equal(carrying(first.id).length, 1, "the restarted queued message ran more than once");
    assert.equal(carrying(second.id).length, 1, "the second queued message did not run exactly once");
    const secondTurn = carrying(second.id)[0];
    const secondIndex = turns.indexOf(secondTurn);
    assert.deepEqual(secondTurn.clientIds, [second.id], "the second queued message joined another turn");
    assert.equal(secondTurn.status, "completed", `the second queued turn ended ${secondTurn.status}`);
    const resumed = turns.slice(firstIndex + 1, secondIndex).filter(turn => !turn.clientIds.length);
    assert(firstIndex > turns.findIndex(turn => turn.id === running.turnId), "the first queued message did not run after the busy turn");
    assert.equal(turns[firstIndex].status, "interrupted", "the planned restart did not interrupt the queue-started turn");
    assert(resumed.length > 0, "the planned restart did not resume the queue-started turn before the next message");
    return { firstTurnId, firstStatus: turns[firstIndex].status, restartMs, resumedTurnIds: resumed.map(turn => turn.id),
        secondTurnId: secondTurn.id, holds: holds.length };
}

try {
    const inference = await hostRouter();
    await mkdir(lab.path(".claude"), { recursive: true, mode: 0o700 });
    await mkdir(work, { recursive: true, mode: 0o700 });
    await mkdir(join(lab.nativeDefault, "packages/standalone"), { recursive: true, mode: 0o700 });
    await symlink(join(lab.realHome, ".codex/packages/standalone/current"), join(lab.nativeDefault, "packages/standalone/current"));
    await lab.write(join(lab.nativeDefault, "config.toml"), 'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    lab.router = startStubRouter(inference);
    await lab.writeGatewayEnv([
        "RC_CLAUDE_ENABLED=true",
        `RC_CLAUDE_HOME=${lab.path(".claude")}`,
        `RC_CLAUDE_PATH=${join(lab.realHome, ".local/bin/claude")}`,
    ]);
    await lab.start();
    client = await connect();
    const info = await client.call("host/info", {});
    assert.equal(info.claudeQueue, true, "host/info does not report claudeQueue");
    const started = await client.call("thread/start", { provider: "claude", model, cwd: work });
    threadId = started.thread?.id;
    assert(threadId?.startsWith("claude_"), "thread/start returned no Claude thread");
    await client.call("conversation/subscriptions/set", { threadIds: [threadId] });
    const receipt = { threadId, model, fifo: await fifoPhase(), held: await heldPhase(), restart: await restartPhase(),
        queuedRestart: await queueStartedRestartPhase() };
    assert(await idle(), "the thread is not idle after the probe");
    receipt.finalActivity = "idle";
    await client.call("claude/thread/release", { threadId });
    console.log(JSON.stringify(receipt, null, 2));
} catch (error) {
    failure = error;
    console.error(JSON.stringify({ error: String(error.message), isolatedHome: lab.root }));
} finally {
    try { await lab.stop(); } catch (error) { failure ??= error; await lab.forceStop(); }
    try { if (await lab.hasNativeDaemon(lab.nativeDefault)) await lab.stopNativeDaemon(lab.nativeDefault); } catch (error) { failure ??= error; }
    lab.router?.stop(true);
    if (!failure) await lab.removeRoot();
}
process.exit(failure ? 1 : 0);
