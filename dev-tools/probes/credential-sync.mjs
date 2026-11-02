import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = resolve(process.argv[2]);
const gateway = await IsolatedGateway.create(binary);
let failure;
try {
    await gateway.writeGatewayEnv([]);
    await gateway.start();
    const request = async (path, token, body, expected = 200) => {
        const response = await fetch(gateway.base + path, {
            method: path === "/health" ? "GET" : "POST",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: body === undefined ? undefined : JSON.stringify(body),
            signal: AbortSignal.timeout(10000),
        });
        assert.equal(response.status, expected, `${path}: expected HTTP ${expected}`);
        if (expected === 200 && path !== "/health") assert.equal(response.headers.get("cache-control"), "no-store");
        return response.json();
    };
    const enrollment = id => ({ installationId: id, label: `Probe ${id}` });
    const phone = (await request("/credentials/enroll", gateway.token, enrollment("phone"))).token;
    const shared = (await request("/credentials/share", phone)).token;
    assert(shared.startsWith("rcs1.phone."));
    await request("/health", shared, undefined, 401);
    await request("/credentials/share", shared, undefined, 401);
    await request("/credentials/enroll", phone, enrollment("forbidden"), 403);
    const mac = (await request("/credentials/enroll", shared, enrollment("mac"))).token;
    const tablet = (await request("/credentials/enroll", shared, enrollment("tablet"))).token;
    assert(mac !== tablet, "Enrollment reused another device identity");
    assert(mac === (await request("/credentials/enroll", shared, enrollment("mac"))).token, "Enrollment retry changed its result");
    const operator = gateway.token;
    gateway.token = mac;
    const client = await gateway.connect();
    const read = await client.rpc("host/info");
    assert(!read.error);
    gateway.token = operator;
    await gateway.stop();
    await gateway.start();
    await request("/health", mac);
    const revoke = Bun.spawn([binary, "credentials", "revoke", "phone"], {
        env: gateway.safeEnv, cwd: gateway.root, stdout: "ignore", stderr: "pipe",
    });
    assert.equal(await revoke.exited, 0, "Source installation revoke failed");
    await request("/health", mac, undefined, 401);
    await request("/health", tablet, undefined, 401);
    await request("/credentials/enroll", shared, enrollment("escape"), 403);
    const persisted = await readFile(gateway.path(".remote-coder/installation-credentials.json"), "utf8");
    for (const secret of [phone, shared, mac, tablet]) assert(!persisted.includes(secret));
} catch (error) {
    failure = error;
} finally {
    try { await gateway.stop(); } catch (error) { failure ??= error; await gateway.forceStop(); }
    try { assert.equal(await gateway.stopNativeDaemon(gateway.nativeDefault), 0); } catch (error) { failure ??= error; }
    await gateway.router?.stop(true);
    if (!failure) await gateway.removeRoot();
}
if (failure) {
    console.error(`Credential probe retained private evidence at ${gateway.root}`);
    throw failure;
}
console.log(JSON.stringify({ passed: true, devices: 3, isolated: true, restart: true, revocation: true, secretsPersisted: false }));
