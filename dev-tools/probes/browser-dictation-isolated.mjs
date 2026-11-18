import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = process.argv[2];
assert(binary, "Pass the candidate gateway binary");
const gateway = await IsolatedGateway.create(resolve(binary));
try {
    await gateway.writeGatewayEnv([]);
    await gateway.start();
    const requester = await gateway.connect();
    const wav = new Uint8Array(44 + 320);
    const view = new DataView(wav.buffer);
    wav.set(Buffer.from("RIFF"), 0); view.setUint32(4, wav.length - 8, true);
    wav.set(Buffer.from("WAVEfmt "), 8); view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, 16000, true);
    view.setUint32(28, 32000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    wav.set(Buffer.from("data"), 36); view.setUint32(40, 320, true);
    const response = await fetch(`${gateway.base}/uploads?name=recording.wav`, {
        method: "POST", headers: { Authorization: `Bearer ${gateway.token}`, "Content-Type": "application/octet-stream",
            "X-RemoteCoder-SHA256": createHash("sha256").update(wav).digest("hex") }, body: wav,
    });
    assert.equal(response.status, 201);
    const { path } = await response.json();
    const absent = await requester.rpc("dictation/transcribe", { path, durationMs: 10 });
    assert.equal(absent.error.data.reason, "noHost");
    const host = await gateway.connect();
    const previous = host.ws.onmessage;
    let mode = "success";
    host.ws.onmessage = async event => {
        previous(event);
        const message = JSON.parse(String(event.data));
        if (message.method !== "dictation/host/transcribe") return;
        if (mode === "disconnect") { host.ws.close(); return; }
        const download = await fetch(`${gateway.base}/files/download`, {
            method: "POST", headers: { Authorization: `Bearer ${gateway.token}`, "Content-Type": "application/json" },
            body: JSON.stringify({ path: message.params.path }),
        });
        assert.equal(download.status, 200);
        assert.deepEqual(new Uint8Array(await download.arrayBuffer()), wav);
        const result = await host.rpc("dictation/host/result", { operationId: message.params.operationId,
            outcome: "succeeded", text: "Isolated dictation", model: "batch" });
        assert.equal(result.result.accepted, true);
    };
    assert(!((await host.rpc("dictation/host/declare", { serving: true })).error));
    const success = await requester.rpc("dictation/transcribe", { path, durationMs: 10 });
    assert.deepEqual(success.result, { text: "Isolated dictation", model: "batch" });
    mode = "disconnect";
    const lost = await requester.rpc("dictation/transcribe", { path, durationMs: 10 });
    assert.equal(lost.error.data.reason, "hostLost");
    console.log(JSON.stringify({ status: "passed", upload: true, download: true, transcript: true, noHost: true, hostLost: true }));
} finally {
    await gateway.stop();
    await gateway.stopNativeDaemon(gateway.nativeDefault);
    await gateway.removeRoot();
}
