import assert from "node:assert/strict";
import { chmod, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = process.argv[2];
assert(binary, "Pass the candidate gateway binary");
const gateway = await IsolatedGateway.create(resolve(binary));
try {
    const keyFile = gateway.path("dictation.key");
    await gateway.write(keyFile, "synthetic-dictation-only-key");
    await gateway.writeGatewayEnv([
        "RC_CODEX_GATEWAY_DICTATION_ORIGIN=https://dictation.example",
        `RC_CODEX_GATEWAY_DICTATION_KEY_FILE=${keyFile}`,
    ]);
    await gateway.start();
    const fetchAccess = token => fetch(`${gateway.base}/dictation`, { headers: { Authorization: `Bearer ${token}` } });
    const refused = await fetchAccess("wrong");
    assert.equal(refused.status, 401);
    assert.equal(refused.headers.get("cache-control"), "no-store");
    const read = async (status, expected) => {
        const response = await fetchAccess(gateway.token);
        assert.equal(response.status, status);
        assert.equal(response.headers.get("cache-control"), "no-store");
        const body = await response.json();
        if (expected) assert.deepEqual(body, { origin: "https://dictation.example", key: expected });
        else assert.equal(body.key, undefined);
    };
    await read(200, "synthetic-dictation-only-key");
    await gateway.write(keyFile, "rotated-dictation-only-key");
    await read(200, "rotated-dictation-only-key");
    await gateway.write(keyFile, await readFile(gateway.path("router-key"), "utf8"));
    await read(503);
    await gateway.write(keyFile, "synthetic-dictation-only-key");
    await chmod(keyFile, 0o644);
    await read(503);
    console.log(JSON.stringify({ status: "passed", auth: true, uncached: true, rotation: true, gatewayKeyRefused: true, privateFileRequired: true }));
} finally {
    await gateway.stop();
    await gateway.stopNativeDaemon(gateway.nativeDefault);
    await gateway.removeRoot();
}
