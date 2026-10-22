import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Sessions, sameOrigin, validateBrowserAccess } from "../server/security";

type ClientSocket = globalThis.WebSocket & Pick<Bun.WebSocket, "pause" | "resume" | "terminate">;
declare const WebSocket: {
  new (url: string | URL, options?: Bun.WebSocketOptions): ClientSocket;
  readonly OPEN: 1;
};

const sessionRequest = (id: string) =>
  new Request("http://localhost/api/session", { headers: { Cookie: `rc_session=${id}` } });

test("external links admit static navigation while API and socket origins stay enforced", () => {
  const headers = {
    "Sec-Fetch-Site": "cross-site",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Dest": "document",
  };
  const origin = "https://rc.example.com";
  expect(sameOrigin(new Request(`${origin}/`, { headers }), origin, false)).toBe(true);
  expect(sameOrigin(new Request(`${origin}/api/session`, { headers }), origin, false)).toBe(false);
  expect(sameOrigin(new Request(`${origin}/api/hosts/mini/ws`, { headers }), origin, true)).toBe(false);
  expect(sameOrigin(new Request("https://other.example.com/", { headers }), origin, false)).toBe(false);
  expect(
    sameOrigin(
      new Request(`${origin}/`, {
        headers: { ...headers, "Sec-Fetch-Dest": "iframe" },
      }),
      origin,
      false,
    ),
  ).toBe(false);
});

test("remote browser origins require a key or an explicit authenticated private proxy", () => {
  expect(() => validateBrowserAccess("127.0.0.1", "https://chat.example.com", undefined, undefined)).toThrow(
    "RC_WEB_ACCESS_KEY_FILE",
  );
  expect(() =>
    validateBrowserAccess("127.0.0.1", "https://chat.example.com", undefined, "true"),
  ).not.toThrow();
  expect(() => validateBrowserAccess("0.0.0.0", "https://chat.example.com", undefined, "true")).toThrow(
    "RC_WEB_ACCESS_KEY_FILE",
  );
  expect(() => validateBrowserAccess("127.0.0.1", "http://chat.example.com", undefined, "true")).toThrow();
  expect(() =>
    validateBrowserAccess("127.0.0.1", "https://chat.example.com", "/private/key", undefined),
  ).not.toThrow();
  expect(() => validateBrowserAccess("::1", "http://[::1]:4173", undefined, undefined)).not.toThrow();
  expect(() =>
    validateBrowserAccess("127.0.0.1", "http://localhost:4173/path", undefined, undefined),
  ).toThrow();
});

describe("browser session connection ownership", () => {
  test("revocation fences attached connections and releases detached connections", () => {
    const sessions = new Sessions();
    const id = sessions.create();
    let closed = 0;
    let detachedClosed = 0;
    try {
      sessions.attach(id, () => {
        expect(sessions.valid(id)).toBe(false);
        closed += 1;
      });
      const detach = sessions.attach(id, () => {
        detachedClosed += 1;
      });
      detach?.();
      sessions.revoke(sessionRequest(id));
      sessions.revoke(sessionRequest(id));
      expect(closed).toBe(1);
      expect(detachedClosed).toBe(0);
      expect(sessions.authorized(sessionRequest(id))).toBe(false);
    } finally {
      sessions.dispose();
    }
  });

  test("expiry closes an idle attached connection without another request", async () => {
    const sessions = new Sessions(50);
    const id = sessions.create();
    try {
      await new Promise<void>((resolve) => {
        sessions.attach(id, resolve);
      });
      expect(sessions.valid(id)).toBe(false);
    } finally {
      sessions.dispose();
    }
  });

  test("capacity eviction closes the evicted session connections", () => {
    const sessions = new Sessions();
    const id = sessions.create();
    let closed = false;
    try {
      sessions.attach(id, () => {
        closed = true;
      });
      for (let index = 0; index < 32; index += 1) sessions.create();
      expect(closed).toBe(true);
      expect(sessions.valid(id)).toBe(false);
    } finally {
      sessions.dispose();
    }
  });
});

describe("live browser bridge socket transport", () => {
  let directory: string;
  let upstream: Bun.Server<{ path: string }>;
  let bridge: Bun.Subprocess<"ignore", "pipe", "pipe">;
  let origin: string;
  let closedUpstream = 0;
  let onUpstreamClosed: (() => void) | undefined;
  let onSpeechCancelled: (() => void) | undefined;
  const upstreamRequests: {
    method: string;
    path: string;
    body: string;
    authorization: string | null;
    contentType: string | null;
    providerKey: string | null;
  }[] = [];

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "remotecoder-web-sockets-"));
    upstream = Bun.serve<{ path: string }>({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request, server) {
        const url = new URL(request.url);
        const path = `${url.pathname}${url.search}`;
        if (request.headers.get("upgrade") === "websocket")
          return server.upgrade(request, { data: { path } })
            ? undefined
            : new Response("WebSocket required", { status: 400 });
        const body = await request.text();
        upstreamRequests.push({
          method: request.method,
          path,
          body,
          authorization: request.headers.get("authorization"),
          contentType: request.headers.get("content-type"),
          providerKey: request.headers.get("x-goog-api-key"),
        });
        if (url.pathname === "/speech/openai/v1/audio/transcriptions")
          return new Response("provider unavailable", {
            status: 429,
            headers: {
              "Content-Type": "text/plain",
              "X-Speech-Relay-Rejection": "capacity",
              "Retry-After": "3",
            },
          });
        if (url.pathname === "/speech/gemini/v1beta/models/test:streamGenerateContent") {
          let ended = false;
          const finish = () => {
            if (ended) return;
            ended = true;
            onSpeechCancelled?.();
            onSpeechCancelled = undefined;
          };
          request.signal.addEventListener("abort", finish, { once: true });
          return new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(new TextEncoder().encode("stream-started\n"));
              },
              cancel: finish,
            }),
            { headers: { "Content-Type": "text/plain" } },
          );
        }
        return Response.json({ method: request.method, path, body });
      },
      websocket: {
        backpressureLimit: 64 * 1024 * 1024,
        message(socket, message) {
          if (message === "large-history") {
            socket.send(JSON.stringify({ id: "history", result: { output: "x".repeat(31 * 1024 * 1024) } }));
            socket.send(
              JSON.stringify({
                method: "turn/completed",
                params: { threadId: "thread-1", turn: { id: "turn-1" } },
              }),
            );
          } else if (message === "relay-info") socket.send(JSON.stringify({ path: socket.data.path }));
          else if (message === "speech-rejection") socket.close(4429, "speech-relay-rejection:capacity");
          else socket.send(message);
        },
        close() {
          closedUpstream += 1;
          onUpstreamClosed?.();
          onUpstreamClosed = undefined;
        },
      },
    });
    const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
    const port = probe.port;
    await probe.stop(true);
    origin = `http://127.0.0.1:${port}`;
    const tokenFile = join(directory, "gateway-token");
    const configFile = join(directory, "hosts.json");
    await writeFile(tokenFile, "isolated-test-gateway-token", { mode: 0o600 });
    const staticDirectory = join(directory, "assets");
    await mkdir(staticDirectory);
    await writeFile(join(staticDirectory, "index.html"), "<html>Isolated Swift assets</html>");
    await writeFile(
      configFile,
      JSON.stringify([
        { id: "test-host", name: "Test", url: `http://127.0.0.1:${upstream.port}`, tokenFile, cwd: "/tmp" },
      ]),
    );
    await startBridge();
  });

  async function startBridge(accessKeyFile = "") {
    bridge = Bun.spawn([process.execPath, resolve(import.meta.dir, "../server/index.ts")], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        RC_WEB_PORT: new URL(origin).port,
        RC_WEB_BIND: "127.0.0.1",
        RC_WEB_ORIGIN: origin,
        RC_WEB_CONFIG: join(directory, "hosts.json"),
        RC_WEB_FIXTURE: "0",
        RC_WEB_ACCESS_KEY_FILE: accessKeyFile,
        RC_WEB_STATIC_DIR: join(directory, "assets"),
        RC_WEB_ALLOW_WASM: "1",
        RC_WEB_ALLOW_JSDELIVR: "1",
      },
    });
    const reader = bridge.stdout.getReader();
    const ready = await reader.read();
    reader.releaseLock();
    if (ready.done) throw new Error(await new Response(bridge.stderr).text());
    expect(new TextDecoder().decode(ready.value)).toContain("RemoteCoder browser client");
  }

  afterAll(async () => {
    bridge?.kill("SIGTERM");
    if (bridge) await bridge.exited;
    if (upstream) await upstream.stop(true);
    if (directory) await rm(directory, { recursive: true, force: true });
  });

  async function createSession() {
    const response = await fetch(`${origin}/api/session`, { method: "POST", headers: { Origin: origin } });
    const cookie = response.headers.get("set-cookie")?.split(";")[0];
    if (!cookie) throw new Error("Browser session was not created");
    return cookie;
  }

  async function connect(path = "ws") {
    const cookie = await createSession();
    const socket = new WebSocket(`${origin.replace("http:", "ws:")}/api/hosts/test-host/${path}`, {
      headers: { Origin: origin, Cookie: cookie },
    });
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener("error", reject, { once: true });
    });
    return { socket, cookie };
  }

  test("logout closes both transports and denies further HTTP access", async () => {
    const { socket, cookie } = await connect();
    try {
      const echoed = new Promise<string>((resolve) => {
        socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
      });
      const command = JSON.stringify({
        id: "command",
        method: "command/exec",
        params: { command: ["true"] },
      });
      socket.send(command);
      expect(await echoed).toBe(command);
      const closedBefore = closedUpstream;
      const upstreamClosed = new Promise<void>((resolve) => {
        onUpstreamClosed = resolve;
      });
      const closed = new Promise<CloseEvent>((resolve) => {
        socket.addEventListener("close", resolve, { once: true });
      });
      const response = await fetch(`${origin}/api/session`, {
        method: "DELETE",
        headers: { Origin: origin, Cookie: cookie },
      });
      expect(response.status).toBe(200);
      expect((await closed).code).toBe(1008);
      await upstreamClosed;
      expect(closedUpstream).toBe(closedBefore + 1);
      expect((await fetch(`${origin}/api/hosts`, { headers: { Cookie: cookie } })).status).toBe(401);
    } finally {
      socket.terminate();
    }
  });

  test("a no-key session recovers after a real bridge restart and reuses the recovered cookie", async () => {
    const oldCookie = await createSession();
    bridge.kill("SIGTERM");
    await bridge.exited;
    await startBridge();
    expect((await fetch(`${origin}/api/hosts`, { headers: { Cookie: oldCookie } })).status).toBe(401);
    const recovered = await fetch(`${origin}/api/session`, { headers: { Cookie: oldCookie } });
    expect(await recovered.json()).toMatchObject({ authenticated: true, loginRequired: false });
    const cookie = recovered.headers.get("Set-Cookie")?.split(";")[0];
    if (!cookie) throw new Error("Session recovery did not issue its new cookie");
    expect(cookie).not.toBe(oldCookie);
    const reused = await fetch(`${origin}/api/session`, { headers: { Cookie: cookie } });
    expect(await reused.json()).toMatchObject({ authenticated: true });
    expect(reused.headers.get("Set-Cookie")).toBeNull();
    expect((await fetch(`${origin}/api/hosts`, { headers: { Cookie: cookie } })).status).toBe(200);
  });

  test("access-key session recovery remains unavailable until a valid explicit login", async () => {
    const keyFile = join(directory, "browser-access-key");
    await writeFile(keyFile, "isolated-browser-access-key", { mode: 0o600 });
    bridge.kill("SIGTERM");
    await bridge.exited;
    await startBridge(keyFile);
    try {
      const unread = await fetch(`${origin}/api/session`);
      expect(await unread.json()).toMatchObject({ authenticated: false, loginRequired: true });
      expect(unread.headers.get("Set-Cookie")).toBeNull();
      const rejected = await fetch(`${origin}/api/session`, {
        method: "POST",
        headers: { Origin: origin, "Content-Type": "application/json" },
        body: JSON.stringify({ key: "incorrect" }),
      });
      expect(rejected.status).toBe(401);
      const login = await fetch(`${origin}/api/session`, {
        method: "POST",
        headers: { Origin: origin, "Content-Type": "application/json" },
        body: JSON.stringify({ key: "isolated-browser-access-key" }),
      });
      const cookie = login.headers.get("Set-Cookie")?.split(";")[0];
      if (!cookie) throw new Error("Explicit login did not issue its cookie");
      const authenticated = await fetch(`${origin}/api/session`, { headers: { Cookie: cookie } });
      expect(await authenticated.json()).toMatchObject({ authenticated: true, loginRequired: true });
      expect(authenticated.headers.get("Set-Cookie")).toBeNull();
    } finally {
      bridge.kill("SIGTERM");
      await bridge.exited;
      await startBridge();
    }
  });

  test("enrolled sockets retain their exact UUID and generation query and reject incomplete bindings", async () => {
    const accountId = "8dc8844a-15b0-4117-9c52-f61246c8012a";
    const { socket, cookie } = await connect(`ws?accountId=${accountId}&accountGeneration=7`);
    try {
      const info = new Promise<string>((resolve) =>
        socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true }),
      );
      socket.send("relay-info");
      expect(JSON.parse(await info).path).toBe(`/ws?accountId=${accountId}&accountGeneration=7`);
      const incomplete = await fetch(`${origin}/api/hosts/test-host/ws?accountId=${accountId}`, {
        headers: { Origin: origin, Cookie: cookie, Upgrade: "websocket" },
      });
      expect(incomplete.status).toBe(400);
    } finally {
      socket.close();
    }
  });

  test("a paused browser receives a valid large history frame and its following notification", async () => {
    const { socket } = await connect();
    try {
      const messages: string[] = [];
      const delivered = new Promise<void>((resolve, reject) => {
        socket.addEventListener("message", (event) => {
          messages.push(String(event.data));
          if (messages.length === 2) resolve();
        });
        socket.addEventListener(
          "close",
          (event) =>
            reject(new Error(`Bridge closed during valid history delivery: ${event.code} ${event.reason}`)),
          { once: true },
        );
      });
      socket.pause();
      socket.send("large-history");
      await Bun.sleep(250);
      socket.resume();
      await delivered;
      const first = messages[0];
      const second = messages[1];
      if (!first || !second) throw new Error("History delivery was incomplete");
      expect(JSON.parse(first).result.output.length).toBe(31 * 1024 * 1024);
      expect(JSON.parse(second).method).toBe("turn/completed");
      expect(socket.readyState).toBe(WebSocket.OPEN);
    } finally {
      socket.terminate();
    }
  }, 15000);

  test("a rebuilt static asset ignores its older gzip sibling and admits a fresh compressed representation", async () => {
    const original = join(directory, "assets", "fixture.wasm");
    const compressed = `${original}.gz`;
    await writeFile(original, "new-original");
    await writeFile(compressed, Bun.gzipSync(new TextEncoder().encode("stale-compressed")));
    await utimes(original, new Date(2000), new Date(2000));
    await utimes(compressed, new Date(1000), new Date(1000));
    const stale = await fetch(`${origin}/fixture.wasm`, { headers: { "Accept-Encoding": "gzip" } });
    expect(stale.status).toBe(200);
    expect(stale.headers.get("Content-Encoding")).toBeNull();
    expect(stale.headers.get("Vary")).toBe("Accept-Encoding");
    expect(await stale.text()).toBe("new-original");
    await writeFile(compressed, Bun.gzipSync(new TextEncoder().encode("new-original")));
    const fresh = await fetch(`${origin}/fixture.wasm`, { headers: { "Accept-Encoding": "gzip" } });
    expect(fresh.headers.get("Content-Encoding")).toBe("gzip");
    expect(fresh.headers.get("Content-Type")).toBe("application/wasm");
    expect(await fresh.text()).toBe("new-original");
    const disabled = await fetch(`${origin}/fixture.wasm`, { headers: { "Accept-Encoding": "gzip;q=0" } });
    expect(disabled.headers.get("Content-Encoding")).toBeNull();
    expect(await disabled.text()).toBe("new-original");
  });

  test("a no-key initial asset visit creates a port-scoped session and the configured WASM CSP", async () => {
    const response = await fetch(origin);
    const cookie = response.headers.get("set-cookie")?.split(";")[0];
    if (!cookie) throw new Error("Initial asset visit did not create a browser session");
    expect(await response.text()).toContain("Isolated Swift assets");
    expect(cookie).toStartWith(`rc_session_${new URL(origin).port}=`);
    expect(response.headers.get("content-security-policy")).toContain("'wasm-unsafe-eval'");
    expect(response.headers.get("content-security-policy")).toContain("https://cdn.jsdelivr.net");
    expect((await fetch(`${origin}/api/hosts`, { headers: { Cookie: cookie } })).status).toBe(200);
  });

  test("account routes preserve refresh, verbs, and bodies and reject unlisted routes", async () => {
    const cookie = await createSession();
    const id = "12345678-1234-1234-1234-123456789abc";
    const cases = [
      { path: "accounts?refresh=true", method: "GET" },
      { path: `accounts/${id}`, method: "PATCH", body: { generation: 7, enabled: false } },
      { path: `accounts/${id}/remove`, method: "POST", body: { generation: 7 } },
      { path: "claude/accounts", method: "GET" },
      { path: "claude/accounts/refresh", method: "POST", body: {} },
      { path: "claude/accounts/preference", method: "PUT", body: { accountId: null } },
    ];
    for (const item of cases) {
      const body = item.body ? JSON.stringify(item.body) : undefined;
      const response = await fetch(`${origin}/api/hosts/test-host/${item.path}`, {
        method: item.method,
        headers: { Cookie: cookie, Origin: origin, "Content-Type": "application/json" },
        body,
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ method: item.method, path: `/${item.path}`, body: body ?? "" });
    }
    const count = upstreamRequests.length;
    expect(
      (
        await fetch(`${origin}/api/hosts/test-host/accounts/${id}/unexpected`, {
          headers: { Cookie: cookie },
        })
      ).status,
    ).toBe(404);
    expect(
      (await fetch(`${origin}/api/hosts/test-host/accounts/${id}`, { headers: { Cookie: cookie } })).status,
    ).toBe(405);
    expect(upstreamRequests.length).toBe(count);
  });

  test("speech HTTP preserves multipart, query, rejection, and status using only the server credential", async () => {
    const cookie = await createSession();
    const form = new FormData();
    form.set("model", "gpt-4o-transcribe");
    form.set("file", new Blob(["isolated-audio"], { type: "audio/webm" }), "recording.webm");
    const response = await fetch(
      `${origin}/api/hosts/test-host/speech/openai/v1/audio/transcriptions?language=en`,
      {
        method: "POST",
        headers: {
          Cookie: cookie,
          Origin: origin,
          Authorization: "Bearer browser-supplied",
          "X-Goog-Api-Key": "browser-supplied",
        },
        body: form,
      },
    );
    expect(response.status).toBe(429);
    expect(response.headers.get("x-speech-relay-rejection")).toBe("capacity");
    expect(response.headers.get("retry-after")).toBe("3");
    expect(await response.text()).toBe("provider unavailable");
    const request = upstreamRequests.at(-1);
    if (!request) throw new Error("Speech request did not reach the gateway");
    expect(request.path).toBe("/speech/openai/v1/audio/transcriptions?language=en");
    expect(request.contentType).toStartWith("multipart/form-data; boundary=");
    expect(request.body).toContain("isolated-audio");
    expect(request.authorization).toBe("Bearer isolated-test-gateway-token");
    expect(request.providerKey).toBeNull();
    const count = upstreamRequests.length;
    expect(
      (
        await fetch(`${origin}/api/hosts/test-host/speech/openai/v1/audio/speech`, {
          method: "POST",
          headers: { Cookie: cookie, Origin: origin },
          body: "{}",
        })
      ).status,
    ).toBe(404);
    expect(upstreamRequests.length).toBe(count);
  });

  test("speech WebSocket relays binary, preserves query, and retains gateway rejection close markers", async () => {
    const { socket } = await connect("speech/openai/v1/realtime?intent=transcription");
    socket.binaryType = "arraybuffer";
    try {
      const info = new Promise<string>((resolve) => {
        socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
      });
      socket.send("relay-info");
      expect(JSON.parse(await info).path).toBe("/speech/openai/v1/realtime?intent=transcription");
      const binary = new Promise<ArrayBuffer>((resolve) => {
        socket.addEventListener("message", (event) => resolve(event.data), { once: true });
      });
      socket.send(new Uint8Array([0, 1, 128, 255]));
      expect([...new Uint8Array(await binary)]).toEqual([0, 1, 128, 255]);
      const closed = new Promise<CloseEvent>((resolve) =>
        socket.addEventListener("close", resolve, { once: true }),
      );
      socket.send("speech-rejection");
      const event = await closed;
      expect(event.code).toBe(4429);
      expect(event.reason).toBe("speech-relay-rejection:capacity");
    } finally {
      socket.terminate();
    }
  });

  test("logout cancels an active speech response and its gateway request", async () => {
    const cookie = await createSession();
    const cancelled = new Promise<void>((resolve) => {
      onSpeechCancelled = resolve;
    });
    const response = await fetch(
      `${origin}/api/hosts/test-host/speech/gemini/v1beta/models/test:streamGenerateContent`,
      {
        method: "POST",
        headers: { Cookie: cookie, Origin: origin, "Content-Type": "application/json" },
        body: "{}",
      },
    );
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Speech response body was missing");
    expect(new TextDecoder().decode((await reader.read()).value)).toBe("stream-started\n");
    await fetch(`${origin}/api/session`, { method: "DELETE", headers: { Cookie: cookie, Origin: origin } });
    await cancelled;
    let ended = false;
    try {
      ended = (await reader.read()).done;
    } catch {
      ended = true;
    }
    expect(ended).toBe(true);
  });

  test("speech admission is bounded and cancellation releases a relay slot", async () => {
    const connections: Awaited<ReturnType<typeof connect>>[] = [];
    try {
      for (let index = 0; index < 4; index += 1) {
        const connection = await connect("speech/openai/v1/realtime?intent=transcription");
        connections.push(connection);
        const ready = new Promise<void>((resolve) =>
          connection.socket.addEventListener("message", () => resolve(), { once: true }),
        );
        connection.socket.send("relay-info");
        await ready;
      }
      const cookie = await createSession();
      const request = () =>
        fetch(`${origin}/api/hosts/test-host/speech/openai/v1/audio/transcriptions`, {
          method: "POST",
          headers: { Cookie: cookie, Origin: origin },
          body: "isolated-audio",
        });
      expect((await request()).status).toBe(429);
      const first = connections[0];
      if (!first) throw new Error("Speech connection was missing");
      const closed = new Promise<CloseEvent>((resolve) =>
        first.socket.addEventListener("close", resolve, { once: true }),
      );
      await fetch(`${origin}/api/session`, {
        method: "DELETE",
        headers: { Cookie: first.cookie, Origin: origin },
      });
      expect((await closed).code).toBe(1008);
      const response = await request();
      expect(response.headers.get("x-speech-relay-rejection")).toBe("capacity");
      expect(await response.text()).toBe("provider unavailable");
    } finally {
      for (const connection of connections) connection.socket.terminate();
    }
  });
});
