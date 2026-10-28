import assert from "node:assert/strict";
import {cp,mkdir,readFile,realpath,symlink,writeFile} from "node:fs/promises";
import {join} from "node:path";
import {randomUUID} from "node:crypto";

const marker = /^RCJOB_(SPAWN|SPAWNHOLD|HOLD|ECHO):(\S+)/;
const shellTools = ["exec_command", "shell_command", "shell"];
const probeProvider = "probe";
const probeModel = "rcjob-mock";

export function startModel() {
    const holds = new Map();
    const requests = [];
    const hold = name => {
        if (!holds.has(name)) {
            let release;
            holds.set(name, { promise: new Promise(resolve => { release = resolve; }), release });
        }
        return holds.get(name);
    };
    const message = text => ({ type: "response.output_item.done", item: {
        type: "message", role: "assistant", id: `msg_${randomUUID()}`, phase: "final_answer",
        content: [{ type: "output_text", text }] } });
    const call = (body, command) => {
        const tool = (body.tools ?? []).map(entry => entry.name ?? entry.function?.name).find(name => shellTools.includes(name));
        assert(tool, `No shell tool offered: ${JSON.stringify((body.tools ?? []).map(entry => entry.name ?? entry.type))}`);
        const args = tool === "exec_command" ? { cmd: command, yield_time_ms: 30000 }
            : tool === "shell_command" ? { command } : { command: ["/bin/zsh", "-c", command] };
        return { type: "response.output_item.done", item: { type: "function_call", call_id: `call_${randomUUID()}`,
            namespace: "functions", name: tool, arguments: JSON.stringify(args) } };
    };
    const frame = event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
    const server = Bun.serve({
        hostname: "127.0.0.1", port: 0, idleTimeout: 0,
        async fetch(request) {
            const path = new URL(request.url).pathname;
            if (request.method === "GET" && path.endsWith("/models")) {
                return Response.json({ data: [{ id: probeModel, capabilities: { endpoints: ["/v1/responses"],
                    streaming: true, tool_calls: true, prompt_tokens: 128000, reasoning_efforts: ["medium"],
                    input_modalities: ["text"] } }] });
            }
            if (request.method !== "POST" || !path.endsWith("/responses")) {
                return new Response("", { status: 404 });
            }
            const body = await request.json();
            const input = body.input ?? [];
            const lastUser = input.findLastIndex(item => item.role === "user");
            const texts = input.filter(item => item.role === "user")
                .map(item => (item.content ?? []).map(part => part.text ?? "").join("\n"));
            const latest = texts.at(-1) ?? "";
            const answered = input.slice(lastUser + 1).some(item => item.type === "function_call_output");
            const [, kind, name] = latest.match(marker) ?? [];
            requests.push({ kind: kind ?? "other", name: name ?? null, answered });
            const id = `resp_${randomUUID()}`;
            const done = { type: "response.completed", response: { id, usage: { input_tokens: 1,
                input_tokens_details: null, output_tokens: 1, output_tokens_details: null, total_tokens: 2 } } };
            const head = frame({ type: "response.created", response: { id } });
            const headers = { "Content-Type": "text/event-stream" };
            if (kind === "HOLD" || kind === "SPAWNHOLD" && answered) {
                const gate = hold(kind === "SPAWNHOLD" ? name.split(".")[1] : name);
                return new Response(new ReadableStream({
                    async start(controller) {
                        controller.enqueue(head);
                        await gate.promise;
                        if (request.signal.aborted) return;
                        controller.enqueue(frame(message(`RCJOB_RESULT:${name}`)) + frame(done));
                        controller.close();
                    },
                }), { headers });
            }
            const output = ["SPAWN", "SPAWNHOLD"].includes(kind) && !answered
                ? call(body, Buffer.from(kind === "SPAWNHOLD" ? name.split(".")[0] : name, "base64url").toString())
                : message(kind === "ECHO" || kind === "HOLD" ? `RCJOB_RESULT:${name}` : `ack:${kind ?? "other"}`);
            return new Response(head + frame(output) + frame(done), { headers });
        },
    });
    return { server, requests, release: name => hold(name).release() };
}

export async function installPackage(lab,runtimePackage) {
    const standalone = lab.path(".codex/packages/standalone");
    const manifest = JSON.parse(await readFile(join(runtimePackage, "codex-package.json"), "utf8"));
    const release = join(standalone, "releases", `${manifest.version}-${manifest.target}`);
    await mkdir(join(standalone, "releases"), { recursive: true });
    await cp(runtimePackage, release, { recursive: true, verbatimSymlinks: true });
    const executable = join(release, "codex");
    if (await Bun.file(executable).exists()) {
        assert.equal(await realpath(executable), await realpath(join(release, manifest.entrypoint)),
            "Copied runtime executable must resolve to its matching package entrypoint");
    } else await symlink(manifest.entrypoint, executable);
    await symlink(release, join(standalone, "current"));
    lab.codex = join(standalone, "current/codex");
}

export async function writeProviderConfig(lab, model) {
    await writeFile(lab.path(".codex/config.toml"), `approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false
`, { mode: 0o600 });
    await writeFile(lab.path("probe-provider.key"), "probe-key\n", { mode: 0o600 });
    await writeFile(lab.path("external-providers.json"), JSON.stringify({ providers: [{ id: probeProvider,
        name: "Probe", baseUrl: `http://127.0.0.1:${model.server.port}/v1`, keyFile: lab.path("probe-provider.key"),
        models: [probeModel] }] }), { mode: 0o600 });
}

