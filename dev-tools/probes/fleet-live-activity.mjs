import assert from "node:assert/strict";
import { mkdir, readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { randomBytes, randomUUID } from "node:crypto";
import { IsolatedGateway, availablePort } from "./isolated-gateway.mjs";
import { installPackage, startModel, writeProviderConfig } from "./delegated-model.mjs";

const [binary, runtimePackage] = process.argv.slice(2);
assert(binary && runtimePackage && isAbsolute(binary) && isAbsolute(runtimePackage),
    "Pass the absolute candidate and matched runtime package paths");

const bundleId = "probe.fleet.liveActivity";
const brokerToken = randomBytes(24).toString("hex");
const fleetTokens = [randomBytes(32).toString("hex"), randomBytes(32).toString("hex")];
const fleetDevice = randomUUID().toUpperCase();
const legacyToken = randomBytes(32).toString("hex");
const deliveries = [];
const broker = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
        if (request.headers.get("authorization") !== `Bearer ${brokerToken}`) return new Response("", { status: 401 });
        const path = new URL(request.url).pathname;
        if (path === "/healthz") return Response.json({ capabilities: { live_activity_relevance_score: true } });
        if (path !== "/v1/internal/live-activity") return new Response("", { status: 404 });
        const body = await request.json();
        deliveries.push({ at: Date.now(), token: body.device_token, event: body.event, state: body.content_state });
        return Response.json({ apns_id: "probe" });
    },
});
const model = startModel();
const hosts = [];
const timings = [];

const rpc = async (host, method, params = {}) => {
    const response = await host.client.rpc(method, params);
    assert(!response.error, `${host.name} ${method}: ${JSON.stringify(response.error)}`);
    return response.result;
};

async function waitFor(label, condition, seconds = 90) {
    const started = performance.now();
    const deadline = Date.now() + seconds * 1000;
    let last;
    while (Date.now() < deadline) {
        try {
            last = await condition();
            if (last) {
                timings.push({ phase: label, durationMs: Math.round(performance.now() - started) });
                return last;
            }
        } catch (error) { last = String(error); }
        await Bun.sleep(250);
    }
    throw new Error(`${label} timed out; last observation ${JSON.stringify(last)}`);
}

async function start(host) {
    await host.lab.start();
    host.client = await host.lab.connect();
}

async function restart(host) {
    await host.lab.stop();
    await start(host);
}

async function pair(a, b) {
    const membership = randomUUID();
    const [left, right] = await Promise.all([
        rpc(a, "cluster/issue", { protocol: 1, for: b.id, name: b.name, membership }),
        rpc(b, "cluster/issue", { protocol: 1, for: a.id, name: a.name, membership }),
    ]);
    const accept = (receipt, name) => ({ protocol: 1, host: receipt.host, name, membership,
        pin: receipt.pin, routes: receipt.routes, credential: receipt.credential });
    await Promise.all([rpc(a, "cluster/accept", accept(right, b.name)), rpc(b, "cluster/accept", accept(left, a.name))]);
}

async function heldTurn(host, name) {
    const started = await rpc(host, "thread/start", { cwd: host.lab.path("work"), model: "rcjob-mock", modelProvider: "probe" });
    const thread = started.thread.id;
    await rpc(host, "turn/start", { threadId: thread,
        input: [{ type: "text", text: `RCJOB_HOLD:${name}`, text_elements: [] }] });
    return thread;
}

const fleetHosts = () => hosts.map(host => host.id);
const registerFleet = (host, token) => rpc(host, "devices/register", { deviceId: fleetDevice, bundleId,
    apnsEnvironment: "development", appHostId: randomUUID().toUpperCase(),
    tokens: { fleetActivity: { token, hosts: fleetHosts() } } });
const fleet = host => rpc(host, "daemon/liveActivity/fleet", { hosts: fleetHosts() });
const sent = token => deliveries.filter(entry => entry.token === token);
const unavailable = view => [...view.content.unavailableHostIDs].sort();

async function main() {
    for (const name of ["coordinator", "peer", "third"]) {
        const lab = await IsolatedGateway.create(binary);
        const host = { name, lab };
        hosts.push(host);
        await installPackage(lab, runtimePackage);
        await mkdir(lab.path("work"), { recursive: true });
        await mkdir(lab.path(".claude/projects"), { recursive: true });
        await writeProviderConfig(lab, model);
        await lab.writeGatewayEnv([
            `RC_CODEX_GATEWAY_LAN_PORT=${await availablePort()}`,
            `RC_CODEX_GATEWAY_EXTERNAL_PROVIDERS_FILE=${lab.path("external-providers.json")}`,
            `RC_CLAUDE_HOME=${lab.path(".claude")}`,
            "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=true",
            `RC_PUSH_BROKER_URL=http://127.0.0.1:${broker.port}`,
            `RC_PUSH_BROKER_TOKEN=${brokerToken}`,
            `RC_APNS_BUNDLE_ID=${bundleId}`,
        ]);
        await start(host);
        host.id = (await rpc(host, "cluster/list")).self.hostId;
        const info = await rpc(host, "host/info");
        assert.equal(info.fleetLiveActivity, true, `${name} must advertise fleetLiveActivity`);
    }
    const [coordinator, peer, third] = hosts;
    await pair(coordinator, peer);
    await pair(coordinator, third);
    await waitFor("membership reachable", async () => (await rpc(coordinator, "cluster/list")).members
        .filter(member => member.reachability.state === "reachable").length === 2);

    await rpc(coordinator, "devices/register", { deviceId: randomUUID().toUpperCase(), bundleId,
        apnsEnvironment: "development", appHostId: randomUUID().toUpperCase(), tokens: { liveActivity: legacyToken } });

    const runningThread = await heldTurn(peer, "peer-first");
    const running = await waitFor("peer running merges into the coordinator", async () => {
        const view = await fleet(coordinator);
        return view.content.activeTaskCount === 1 && unavailable(view).length === 0 ? view : null;
    });
    assert.equal(running.content.attentionCount, 0);
    const [fleetToken, secondFleetToken] = fleetTokens;
    await registerFleet(coordinator, fleetToken);
    const registry = JSON.parse(await readFile(coordinator.lab.path(".remote-coder/devices.json"), "utf8"));
    assert.equal(registry.version, 2, "A fleet token must write the version-2 registry");
    await waitFor("fleet token receives the running update", () => sent(fleetToken)
        .some(entry => entry.event === "update" && entry.state.activeTaskCount === 1));
    const local = await rpc(coordinator, "daemon/liveActivity");
    assert.equal(local.content.activeTaskCount, 0, "The legacy read stays local-only");

    model.release("peer-first");
    const attention = await waitFor("finished peer turn links to its own host", async () => {
        const view = await fleet(coordinator);
        return view.content.attentionCount === 1 && view.content.activeTaskCount === 0 ? view : null;
    });
    assert.deepEqual(attention.content.attention.map(row => [row.hostID, row.threadID]), [[peer.id, runningThread]]);
    await waitFor("fleet token receives the exact attention row", () => sent(fleetToken).some(entry =>
        entry.event === "update" && entry.state.attention?.[0]?.hostID === peer.id
        && entry.state.attention[0].threadID === runningThread));

    await third.lab.stop();
    await waitFor("a stopped member is unavailable, not empty", async () => {
        const view = await fleet(coordinator);
        return JSON.stringify(unavailable(view)) === JSON.stringify([third.id]);
    });
    await rpc(peer, "conversation/marks/update", { changes: [{ op: "markRead", threadId: runningThread, through: Date.now() + 60000 }] });
    await waitFor("an empty view with an unavailable member stays an update", async () => {
        const view = await fleet(coordinator);
        const last = sent(fleetToken).at(-1);
        return view.content.attentionCount === 0 && last.event === "update" && last.state.attentionCount === 0
            && JSON.stringify(last.state.unavailableHostIDs) === JSON.stringify([third.id]);
    });
    assert(!sent(fleetToken).some(entry => entry.event === "end"), "End must wait for every declared host");

    await start(third);
    await waitFor("every current and empty host ends the activity", () => sent(fleetToken).at(-1)?.event === "end");

    await peer.lab.stop();
    await waitFor("peer restart withdraws its currency", async () =>
        JSON.stringify(unavailable(await fleet(coordinator))) === JSON.stringify([peer.id]));
    await start(peer);
    await waitFor("restarted peer reports on its new connection", async () => unavailable(await fleet(coordinator)).length === 0);

    const firstLifetime = sent(fleetToken);
    assert.equal(firstLifetime.filter(entry => entry.event === "end").length, 1, "One End per activity lifetime");
    assert.equal(firstLifetime.at(-1).event, "end");

    const heldThread = await heldTurn(peer, "peer-second");
    await waitFor("second peer turn is running in the fleet view", async () =>
        (await fleet(coordinator)).content.activeTaskCount === 1);
    await registerFleet(coordinator, secondFleetToken);
    await waitFor("the rotated token receives the running update", () =>
        sent(secondFleetToken).at(-1)?.state?.activeTaskCount === 1);
    assert.equal(sent(fleetToken).length, firstLifetime.length, "The replaced token receives nothing more");
    const epoch = (await fleet(coordinator)).epoch;
    const beforeRestart = deliveries.length;
    await restart(coordinator);
    const restored = await fleet(coordinator);
    assert.notEqual(restored.epoch, epoch);
    await waitFor("coordinator restart converges on fresh peer reports", async () => {
        const view = await fleet(coordinator);
        return view.content.activeTaskCount === 1 && unavailable(view).length === 0;
    });
    assert(!deliveries.slice(beforeRestart).some(entry => entry.token === secondFleetToken && entry.event === "end"),
        "A restarted coordinator must not end nonempty work");
    model.release("peer-second");
    await waitFor("second finished turn becomes attention", async () => (await fleet(coordinator)).content.attentionCount === 1);
    await rpc(peer, "conversation/marks/update", { changes: [{ op: "markRead", threadId: heldThread, through: Date.now() + 60000 }] });
    await waitFor("the persisted rotated token ends after restart", () => sent(secondFleetToken).at(-1)?.event === "end");
    assert.equal(sent(secondFleetToken).filter(entry => entry.event === "end").length, 1, "One End per activity lifetime");

    const legacy = sent(legacyToken);
    assert(legacy.length > 0, "The legacy token still receives local content");
    assert(legacy.every(entry => entry.state.activeTaskCount === 0 && entry.state.attentionCount === 0
        && !("unavailableHostIDs" in entry.state)), "Legacy payloads stay local-only");

    console.log(JSON.stringify({ fleetLiveActivityProbe: "passed",
        hosts: hosts.map(host => ({ name: host.name, hostId: host.id })),
        fleetDeliveries: fleetTokens.map(token => sent(token).map(entry => ({ event: entry.event,
            activeTaskCount: entry.state.activeTaskCount, attentionCount: entry.state.attentionCount,
            unavailableHostIDs: entry.state.unavailableHostIDs }))),
        legacyDeliveries: legacy.length, timings }));
}

let failed = false;
try {
    await main();
} catch (error) {
    failed = true;
    console.error(JSON.stringify({ failure: String(error), roots: hosts.map(host => host.lab.root), timings }));
} finally {
    for (const host of hosts) {
        for (const cleanup of [() => host.lab.stop(), () => host.lab.forceStop(),
            () => host.lab.stopNativeDaemon(host.lab.nativeDefault), () => host.lab.router?.stop(true)]) {
            try { await cleanup(); } catch (error) { console.error(`${host.name} cleanup: ${error}`); }
        }
        if (!failed) await host.lab.removeRoot();
    }
    await model.server.stop(true);
    await broker.stop(true);
}
process.exit(failed ? 1 : 0);
