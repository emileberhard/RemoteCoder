import assert from "node:assert/strict";
import { mkdir, readFile, readdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";
import { IsolatedGateway, availablePort } from "./isolated-gateway.mjs";
import { installPackage } from "./delegated-model.mjs";

const [binary, runtimePackage] = process.argv.slice(2);
assert(binary && runtimePackage && isAbsolute(binary) && isAbsolute(runtimePackage),
    "Pass the absolute candidate and matched runtime package paths");
const labs = [];
const rpc = async (host, method, params = {}) => {
    const response = await host.client.rpc(method, params);
    assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
    return response.result;
};
const hellos = async host => {
    const directory = host.lab.path("Library/Logs/remote-coder/journal");
    let count = 0;
    for (const name of await readdir(directory)) {
        if (!name.endsWith(".jsonl")) continue;
        for (const line of (await readFile(join(directory, name), "utf8")).split("\n")) {
            if (line.includes('"method":"cluster/hello"')) count++;
        }
    }
    return count;
};
const configure = async (host, routes) => host.lab.writeGatewayEnv([
    `RC_CODEX_GATEWAY_LAN_PORT=${host.lan}`,
    `RC_CLAUDE_HOME=${host.lab.path(".claude")}`,
    ...(routes ? [`RC_CODEX_GATEWAY_CLUSTER_ROUTES=${JSON.stringify(routes)}`] : []),
]);
try {
    for (let index = 0; index < 2; index++) {
        const host = { lab: await IsolatedGateway.create(binary), lan: await availablePort() };
        labs.push(host);
        await installPackage(host.lab, runtimePackage);
        await mkdir(host.lab.path(".claude/projects"), { recursive: true });
        await mkdir(host.lab.path(".codex/sessions/2026/11/01"), { recursive: true });
        const id = randomUUID();
        await host.lab.write(host.lab.path(".codex/sessions/2026/11/01/valid.jsonl"),
            `${JSON.stringify({ type: "session_meta", payload: { id, cwd: host.lab.root, source: "cli" } })}\n`);
        if (index === 1) await host.lab.write(host.lab.path(".codex/sessions/2026/11/01/legacy.jsonl"),
            '{"type":"event_msg"}\n');
        await configure(host);
        await host.lab.start();
        host.client = await host.lab.connect();
        host.identity = (await rpc(host, "cluster/list")).self;
    }
    const routes = Object.fromEntries(labs.map(host => [host.identity.hostId, `wss://127.0.0.1:${host.lan}/ws`]));
    for (const host of labs) {
        await host.lab.stop();
        await configure(host, routes);
        await host.lab.start();
        host.client = await host.lab.connect();
    }
    const [left, right] = labs;
    const membership = randomUUID();
    const receipts = await Promise.all(labs.map((host, index) => rpc(host, "cluster/issue", {
        protocol: 1, for: labs[1 - index].identity.hostId, name: `probe-${1 - index}`, membership,
    })));
    for (let index = 0; index < 2; index++) {
        const receipt = receipts[1 - index];
        await rpc(labs[index], "cluster/accept", { protocol: 1, host: receipt.host,
            name: `probe-${1 - index}`, membership, pin: receipt.pin,
            credential: receipt.credential, routes: receipt.routes });
    }
    await left.lab.waitFor(async () => (await rpc(left, "cluster/list")).members[0]?.reachability.state === "reachable");
    for (const host of labs) {
        const page = await rpc(host, "agent/cluster/list", { limit: 100 });
        assert.equal(page.agents.length, 2, JSON.stringify(page));
        assert.equal(page.nextCursor, null);
        assert(page.coverage.some(row => row.hostId === right.identity.hostId && row.state === "stale"));
        assert(page.warnings.length > 0);
    }
    const response = await left.client.rpc("agent/cluster/dispatch", {
        host: right.identity.hostId, method: "agent/cluster/resolve",
        request: { target: "missing-native-suffix", local: true }, caller: { kind: "operator" },
    });
    assert.equal(response.error?.data?.class, "not_found", JSON.stringify(response));
    assert.equal((await rpc(left, "cluster/list")).members[0].reachability.state, "reachable");
    const afterError = await rpc(left, "agent/cluster/list", { limit: 100 });
    assert.equal(afterError.agents.length, 2);
    await Bun.sleep(1500);
    const beforeIdle = await Promise.all(labs.map(hellos));
    await Bun.sleep(6500);
    assert.deepEqual(await Promise.all(labs.map(hellos)), beforeIdle, "Idle gateways emitted hellos");
    await right.lab.stop();
    await right.lab.start();
    right.client = await right.lab.connect();
    await left.lab.waitFor(async () => {
        const page = await rpc(left, "agent/cluster/list", { limit: 100 });
        return page.agents.length === 2 && page.nextCursor === null;
    });
    console.log(JSON.stringify({ passed: true, members: labs.map(host => host.identity.hostId),
        configuredRoutes: true, partialInventory: true, peerErrorPreservesReachability: true,
        idleHellos: 0, restartRecovery: true }));
} finally {
    const failures = [];
    for (const { lab } of labs) {
        for (const cleanup of [() => lab.stop(), () => lab.forceStop(),
            () => lab.stopNativeDaemon(lab.nativeDefault), () => lab.router?.stop(true), () => lab.removeRoot()]) {
            try { await cleanup(); } catch (error) { failures.push(String(error)); }
        }
    }
    assert.equal(failures.length, 0, failures.join("\n"));
}
