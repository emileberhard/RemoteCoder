import assert from "node:assert/strict";
import { mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { homedir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import { createHash, randomBytes } from "node:crypto";

const routerCodexAccount = "probe-account";

function syntheticCodexToken() {
    const expiry = Math.floor(Date.now() / 1000) + 7200;
    const claims = { exp: expiry, "https://api.openai.com/auth": { chatgpt_account_id: routerCodexAccount } };
    const access = `e30.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.probe`;
    return {
        access_token: access, account_id: routerCodexAccount, plan_type: "pro",
        expires_at: new Date(expiry * 1000).toISOString(),
        generation: createHash("sha256").update(access).digest("hex"),
    };
}

export function startStubRouter(inference) {
    const server = Bun.serve({
        hostname: "127.0.0.1", port: 0, idleTimeout: 0,
        fetch: async (request) => {
            const url = new URL(request.url);
            if (["/codex/token", "/codex/renew"].includes(url.pathname)) return Response.json(syntheticCodexToken());
            if (!inference) return Response.json({ error: { code: "not_found" } }, { status: 404 });
            const headers = new Headers(request.headers);
            headers.delete("host");
            headers.set("authorization", `Bearer ${inference.key}`);
            if (headers.has("x-api-key")) headers.set("x-api-key", inference.key);
            return fetch(inference.url + url.pathname + url.search, {
                method: request.method, headers, body: request.body, duplex: "half",
            });
        },
    });
    server.unref();
    return server;
}

async function availablePort() {
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") });
    const port = server.port;
    await server.stop(true);
    return port;
}

export class IsolatedGateway {
    constructor(binary, root, token, port) {
        this.binary = binary;
        this.root = root;
        this.token = token;
        this.port = port;
        this.realHome = homedir();
        this.codex = join(this.realHome, ".codex/packages/standalone/current/codex");
        this.nativeDefault = join(root, ".codex");
        this.safeEnv = {
            HOME: root, CODEX_HOME: this.nativeDefault, USER: userInfo().username, SHELL: "/bin/zsh",
            LANG: "en_US.UTF-8", PATH: "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ...(process.env.SSL_CERT_FILE ? { SSL_CERT_FILE: process.env.SSL_CERT_FILE } : {}), RUST_LOG: "warn",
        };
        this.clients = new Set();
        this.child = null;
    }

    static async create(binary) {
        return new IsolatedGateway(
            binary, await realpath(await mkdtemp("/tmp/r")),
            randomBytes(32).toString("hex"), await availablePort(),
        );
    }

    get base() { return `http://127.0.0.1:${this.port}`; }

    path(name) { return join(this.root, name); }

    async write(path, value) { await writeFile(path, value, { mode: 0o600 }); }

    async writeGatewayEnv(extraLines) {
        this.router ??= startStubRouter();
        const routerUrl = `http://127.0.0.1:${this.router.port}`;
        await this.write(this.path("router-key"), `llmr_${"p".repeat(43)}\n`);
        await this.write(this.path("gateway.env"), [
            "RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1",
            `RC_CODEX_GATEWAY_PORT=${this.port}`,
            `RC_CODEX_GATEWAY_AUTH_TOKEN=${this.token}`,
            `RC_CODEX_GATEWAY_CODEX_PATH=${this.codex}`,
            "RC_CODEX_GATEWAY_PUSH_BROKER_ENABLED=false",
            `RC_CODEX_GATEWAY_ROUTER_URL=${routerUrl}`,
            `RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL=${routerUrl}`,
            `RC_CODEX_GATEWAY_ROUTER_KEY_FILE=${this.path("router-key")}`,
            `RC_CODEX_GATEWAY_ROUTER_CODEX_ACCOUNT=${routerCodexAccount}`,
            ...extraLines,
            `CODEX_HOME=${this.nativeDefault}`,
            "RUST_LOG=warn",
        ].join("\n") + "\n");
    }

    async request(path, method = "GET", body, allowed = [200]) {
        const response = await fetch(this.base + path, {
            method,
            headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
            body: body === undefined ? undefined : JSON.stringify(body),
            signal: AbortSignal.timeout(95000),
        });
        assert(allowed.includes(response.status), `${method} ${path.split("?")[0]} status ${response.status}`);
        return response.headers.get("Content-Type")?.includes("json")
            ? await response.json() : await response.text();
    }

    async waitFor(condition, seconds = 90) {
        const end = Date.now() + seconds * 1000;
        while (Date.now() < end) {
            if (this.child && this.child.exitCode !== null) {
                throw new Error(`Owned gateway exited with code ${this.child.exitCode}; inspect its retained log`);
            }
            try {
                const result = await condition();
                if (result) return result;
            } catch {
                if (this.child && this.child.exitCode !== null) {
                    throw new Error(`Owned gateway exited with code ${this.child.exitCode}; inspect its retained log`);
                }
            }
            await Bun.sleep(400);
        }
        throw new Error("Acceptance condition timed out");
    }

    async start() {
        this.child = Bun.spawn([this.binary, "--env-file", this.path("gateway.env")], {
            env: this.safeEnv, cwd: this.root,
            stdout: Bun.file(this.path("gateway.log")),
            stderr: Bun.file(this.path("gateway-errors.log")),
        });
        await this.waitFor(async () => (await this.request("/health")).status === "ok");
        const recorder = Bun.spawn([
            "python3", resolve(import.meta.dir, "../../scripts/bench_lab.py"), this.root, String(this.port),
            createHash("sha256").update(this.token).digest("hex"), this.binary, String(this.child.pid), String(process.pid),
        ], { env: this.safeEnv, stdout: "ignore", stderr: "pipe" });
        try {
            const [status, error] = await this.within(
                Promise.all([recorder.exited, new Response(recorder.stderr).text()]),
                15000, "Isolated gateway identity recording did not finish",
            );
            assert(status === 0, `Cannot record the isolated gateway identity: ${error.trim()}`);
        } finally {
            if (recorder.exitCode === null) recorder.kill("SIGKILL");
            await recorder.exited;
        }
    }

    async within(promise, ms, message) {
        let timer;
        try {
            return await Promise.race([promise, new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error(message)), ms);
            })]);
        } finally {
            clearTimeout(timer);
        }
    }

    async stop() {
        try {
            for (const client of this.clients) client.close();
            this.clients.clear();
            if (this.child && this.child.exitCode === null) {
                this.child.kill("SIGTERM");
                await this.within(this.child.exited, 55000, "Owned gateway did not drain");
            }
        } finally {
            await rm(this.path("isolated-gateway.json"), { force: true });
        }
    }

    async forceStop() {
        if (this.child && this.child.exitCode === null) this.child.kill("SIGKILL");
        if (this.child) await this.child.exited;
    }

    async hasNativeDaemon(home) {
        return await Bun.file(join(home, "app-server-daemon/app-server.pid")).exists()
            || await Bun.file(join(home, "app-server-daemon/daemon.pid")).exists();
    }

    async stopNativeDaemon(home) {
        const child = Bun.spawn([this.codex, "app-server", "daemon", "stop"], {
            env: { ...this.safeEnv, CODEX_HOME: home }, stdout: "ignore", stderr: "ignore",
        });
        return await this.within(child.exited, 12000, "Owned native daemon did not stop").catch(async () => {
            child.kill("SIGTERM");
            await child.exited;
            return -1;
        });
    }

    async removeRoot() { await rm(this.root, { recursive: true, force: true }); }

    async connect(id, generation = 1, denied = false) {
        assert(this.clients.size < 32, "Too many open probe sockets");
        const query = id ? `?accountId=${id}&accountGeneration=${generation}` : "";
        const ws = new WebSocket(this.base.replace("http:", "ws:") + "/ws" + query, {
            headers: { Authorization: `Bearer ${this.token}` },
        });
        const opened = await new Promise(resolve => {
            const timer = setTimeout(() => { ws.close(); resolve(false); }, 95000);
            ws.onopen = () => { clearTimeout(timer); resolve(true); };
            ws.onerror = () => { clearTimeout(timer); resolve(false); };
        });
        if (denied) {
            if (opened) ws.close();
            assert(!opened, "Stale enrollment connection was accepted");
            return;
        }
        if (!opened) ws.close();
        assert(opened, "Account WebSocket did not open");
        let next = 0;
        const pending = new Map();
        const failPending = () => {
            for (const waiter of pending.values()) {
                clearTimeout(waiter.timer);
                waiter.reject(new Error("Account WebSocket closed"));
            }
            pending.clear();
            this.clients.delete(client);
        };
        const client = { ws, close: () => { ws.close(); failPending(); } };
        this.clients.add(client);
        ws.onclose = failPending;
        ws.onerror = failPending;
        ws.onmessage = event => {
            const message = JSON.parse(String(event.data));
            const waiter = pending.get(message.id);
            if (waiter) {
                clearTimeout(waiter.timer);
                pending.delete(message.id);
                waiter.resolve(message);
            }
        };
        const rpc = (method, params = {}) => new Promise((resolve, reject) => {
            if (pending.size >= 1024) {
                reject(new Error("Too many pending probe requests"));
                return;
            }
            const id = ++next;
            const timer = setTimeout(() => {
                pending.delete(id);
                reject(new Error(`${method} timed out`));
            }, 45000);
            pending.set(id, { resolve, reject, timer });
            try { ws.send(JSON.stringify({ id, method, params })); }
            catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
        });
        const init = await rpc("initialize", {
            clientInfo: { name: "account_acceptance", title: "Isolated accounts", version: "1" },
            capabilities: { experimentalApi: true },
        });
        assert(!init.error, "Initialize failed");
        ws.send(JSON.stringify({ method: "initialized", params: {} }));
        return { ws, rpc };
    }
}
