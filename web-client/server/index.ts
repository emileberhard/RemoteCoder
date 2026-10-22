import { stat } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { object } from "../src/protocol/boundary";
import { HostRegistry, readCredential } from "./config";
import { FixtureConnection, fixtureHosts } from "./fixture";
import { matchesSecret, Sessions, sameOrigin, validateBrowserAccess } from "./security";
import {
  unavailableVisual,
  unavailableVisualHeaders,
  verifiedVisual,
  visualDigestPattern,
  visualDocument,
  visualHeaders,
} from "./visuals";

type ClientSocket = globalThis.WebSocket & Pick<Bun.WebSocket, "pause" | "resume" | "terminate">;
declare const WebSocket: {
  new (url: string | URL, options?: Bun.WebSocketOptions): ClientSocket;
  readonly OPEN: 1;
};

const port = Number(process.env.RC_WEB_PORT ?? 4173);
const hostname = process.env.RC_WEB_BIND ?? "127.0.0.1";
const origin =
  process.env.RC_WEB_ORIGIN ?? `http://${hostname.includes(":") ? `[${hostname}]` : hostname}:${port}`;
const local = ["localhost", "127.0.0.1", "::1"].includes(hostname);
const accessFile = process.env.RC_WEB_ACCESS_KEY_FILE;
validateBrowserAccess(hostname, origin, accessFile, process.env.RC_WEB_TRUST_PRIVATE_PROXY);
const fixture = process.env.RC_WEB_FIXTURE === "1";
if (fixture && !local) throw new Error("Fixture mode is restricted to loopback");
const registry = new HostRegistry(process.env.RC_WEB_CONFIG ?? join(import.meta.dir, "../hosts.local.json"));
await registry.load();
const cookieName = `rc_session_${new URL(origin).port || (origin.startsWith("https:") ? "443" : "80")}`;
const sessions = new Sessions(12 * 60 * 60 * 1000, cookieName);
const staticDirectory = process.env.RC_WEB_STATIC_DIR;
if (staticDirectory && !isAbsolute(staticDirectory))
  throw new Error("RC_WEB_STATIC_DIR must use an absolute path");
const root = resolve(staticDirectory ?? resolve(import.meta.dir, "../dist"));
const build = (
  await Bun.file(join(root, "build-id.txt"))
    .text()
    .catch(() => "")
).trim();
const buildHeader: Record<string, string> = build ? { "X-RemoteCoder-Web-Build": build } : {};
const scriptSources = [
  "'self'",
  ...(process.env.RC_WEB_ALLOW_WASM === "1" ? ["'wasm-unsafe-eval'"] : []),
  ...(process.env.RC_WEB_ALLOW_JSDELIVR === "1" ? ["https://cdn.jsdelivr.net"] : []),
].join(" ");
const cookie = (id: string) =>
  `${cookieName}=${id}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200${origin.startsWith("https:") ? "; Secure" : ""}`;
const headers = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": `default-src 'self'; script-src ${scriptSources}; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`,
  "Permissions-Policy": "camera=(), microphone=(self), geolocation=()",
};
const json = (value: unknown, status = 200, extra: Record<string, string> = {}) =>
  Response.json(value, { status, headers: { ...headers, ...extra } });

type BridgeData = {
  hostId: string;
  sessionId: string;
  upstreamPath?: string;
  speech?: boolean;
  releaseSpeech?: () => void;
  releaseSession?: () => void;
  upstream?: ClientSocket;
  fixture?: FixtureConnection;
  closed: boolean;
  pending: (string | ArrayBuffer | Uint8Array<ArrayBuffer>)[];
  pendingBytes: number;
  drainDeadline?: ReturnType<typeof setTimeout>;
};
const maximumFrameBytes = 32 * 1024 * 1024;
const maximumBufferedBytes = 2 * maximumFrameBytes;
let activeSpeech = 0;

function claimSpeech() {
  if (activeSpeech >= 4) return undefined;
  activeSpeech += 1;
  let released = false;
  return () => {
    if (released) return;
    released = true;
    activeSpeech -= 1;
  };
}

function speechTransport(provider: string, method: string, path: string) {
  if (path.split("/").some((part) => !/^[A-Za-z0-9_.:-]+$/.test(part) || part === "." || part === ".."))
    return undefined;
  const route = `${provider} ${method} ${path}`;
  if (
    [
      "openai GET v1/realtime",
      "elevenlabs GET v1/speech-to-text/realtime",
      "gemini GET ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
      "assemblyai GET v3/ws",
    ].includes(route)
  )
    return "websocket";
  if (
    [
      "openai POST v1/audio/transcriptions",
      "elevenlabs POST v1/speech-to-text",
      "gemini POST upload/v1beta/files",
      "gemini POST v1beta/interactions",
      "assemblyai POST v2/upload",
      "assemblyai POST v2/transcript",
      "azure POST speechtotext/transcriptions:transcribe",
    ].includes(route) ||
    /^gemini POST v1beta\/models\/[A-Za-z0-9_.-]+:(?:generateContent|streamGenerateContent)$/.test(route) ||
    /^gemini DELETE v1beta\/files\/[A-Za-z0-9_.-]+$/.test(route) ||
    /^assemblyai GET v2\/transcript\/[A-Za-z0-9_.-]+$/.test(route)
  )
    return "http";
  return undefined;
}

async function proxyHttp(
  request: Request,
  sessionId: string,
  endpoint: URL,
  upstreamHeaders: Headers,
  responseHeaderNames: readonly string[],
  timeout?: number,
  release?: () => void,
) {
  const cancellation = new AbortController();
  let deadline: ReturnType<typeof setTimeout> | undefined;
  let releaseSession: (() => void) | undefined;
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    clearTimeout(deadline);
    request.signal.removeEventListener("abort", cancel);
    releaseSession?.();
    release?.();
  };
  const cancel = () => {
    cancellation.abort();
    finish();
  };
  releaseSession = sessions.attach(sessionId, cancel);
  if (!releaseSession || request.signal.aborted) {
    cancel();
    return json({ error: "Browser session or request ended" }, 401);
  }
  request.signal.addEventListener("abort", cancel, { once: true });
  if (timeout) {
    deadline = setTimeout(cancel, timeout);
    deadline.unref();
  }
  try {
    const upstream = await fetch(endpoint, {
      method: request.method,
      headers: upstreamHeaders,
      body: ["POST", "PUT", "PATCH"].includes(request.method) ? request.body : undefined,
      signal: cancellation.signal,
      redirect: "error",
      decompress: false,
    });
    if (cancellation.signal.aborted) {
      await upstream.body?.cancel();
      return json({ error: "Browser session or request ended" }, 401);
    }
    const responseHeaders = new Headers(headers);
    for (const name of responseHeaderNames) {
      const value = upstream.headers.get(name);
      if (value) responseHeaders.set(name, value);
    }
    const reader = upstream.body?.getReader();
    if (!reader) {
      finish();
      return new Response(null, { status: upstream.status, headers: responseHeaders });
    }
    const body = new ReadableStream<Uint8Array<ArrayBuffer>>({
      async pull(controller) {
        try {
          const chunk = await reader.read();
          if (chunk.done) {
            finish();
            controller.close();
          } else controller.enqueue(chunk.value);
        } catch (error) {
          finish();
          controller.error(error);
        }
      },
      async cancel() {
        cancel();
        await reader.cancel();
      },
    });
    return new Response(body, { status: upstream.status, headers: responseHeaders });
  } catch (error) {
    finish();
    throw error;
  }
}

function releaseBridge(data: BridgeData) {
  if (data.closed) return;
  data.closed = true;
  clearTimeout(data.drainDeadline);
  data.drainDeadline = undefined;
  data.releaseSession?.();
  data.releaseSession = undefined;
  data.releaseSpeech?.();
  data.releaseSpeech = undefined;
  data.upstream?.terminate();
  data.fixture?.close();
  data.pending = [];
  data.pendingBytes = 0;
}

function closeBridge(socket: Bun.ServerWebSocket<BridgeData>, code: number, reason: string) {
  if (socket.data.closed) return;
  releaseBridge(socket.data);
  socket.close(code, reason);
}

function authorizedSocket(socket: Bun.ServerWebSocket<BridgeData>) {
  if (socket.data.closed) return false;
  if (sessions.valid(socket.data.sessionId)) return true;
  closeBridge(socket, 1008, "Browser session ended; unlock this browser again");
  return false;
}

function frameBytes(message: string | ArrayBuffer | Uint8Array<ArrayBuffer>) {
  return typeof message === "string" ? Buffer.byteLength(message) : message.byteLength;
}

function forwardToBrowser(
  socket: Bun.ServerWebSocket<BridgeData>,
  message: string | ArrayBuffer | Uint8Array<ArrayBuffer>,
) {
  if (!authorizedSocket(socket)) return;
  const bytes = frameBytes(message);
  if (bytes > maximumFrameBytes) {
    closeBridge(socket, 1009, "Gateway frame exceeds transport capacity");
    return;
  }
  if (socket.getBufferedAmount() + bytes > maximumBufferedBytes) {
    closeBridge(socket, 1013, "Browser receive buffer is full; reconnect to refresh state");
    return;
  }
  const sent = socket.send(message);
  if (sent === 0) {
    closeBridge(socket, 1011, "Browser transport dropped a gateway message; reconnect to refresh state");
  } else if (sent === -1) {
    socket.data.upstream?.pause();
    if (!socket.data.drainDeadline) {
      socket.data.drainDeadline = setTimeout(() => {
        closeBridge(socket, 1013, "Browser receive stalled; reconnect to refresh state");
      }, 60000);
      socket.data.drainDeadline.unref();
    }
  }
}

function forwardToGateway(
  socket: Bun.ServerWebSocket<BridgeData>,
  message: string | ArrayBuffer | Uint8Array<ArrayBuffer>,
) {
  if (!authorizedSocket(socket)) return;
  const upstream = socket.data.upstream;
  if (!upstream || upstream.readyState !== WebSocket.OPEN) return;
  const bytes = frameBytes(message);
  if (bytes > maximumFrameBytes) {
    closeBridge(socket, 1009, "Browser frame exceeds transport capacity");
    return;
  }
  if (upstream.bufferedAmount + bytes > maximumBufferedBytes) {
    closeBridge(socket, 1013, "Gateway send buffer is full; reconnect to refresh state");
    return;
  }
  upstream.send(message);
}
const server = Bun.serve<BridgeData>({
  port,
  hostname,
  maxRequestBodySize: 64 * 1024 * 1024,
  async fetch(request, current) {
    const url = new URL(request.url);
    if (
      !sameOrigin(
        request,
        origin,
        request.headers.get("upgrade")?.toLowerCase() === "websocket" ||
          !["GET", "HEAD"].includes(request.method),
      )
    )
      return json({ error: "This action must come from the configured browser origin" }, 403);
    if (url.pathname === "/api/session") {
      if (request.method === "DELETE") {
        sessions.revoke(request);
        return json({}, 200, { "Set-Cookie": cookie("") });
      }
      if (request.method === "POST") {
        if (accessFile) {
          const body: unknown = await request.json();
          const key = body && typeof body === "object" ? (body as Record<string, unknown>).key : undefined;
          if (typeof key !== "string" || !matchesSecret(key, await readCredential(accessFile)))
            return json({ error: "The access key was not accepted" }, 401);
        }
        return json({ authenticated: true }, 200, {
          ...buildHeader,
          "Set-Cookie": cookie(sessions.create()),
        });
      }
      if (!["GET", "HEAD"].includes(request.method)) return json({ error: "Method not allowed" }, 405);
      const current = sessions.session(request);
      const recovered = !accessFile && !current ? sessions.create() : undefined;
      return json(
        { authenticated: Boolean(current || recovered), loginRequired: Boolean(accessFile), fixture },
        200,
        { ...buildHeader, ...(recovered ? { "Set-Cookie": cookie(recovered) } : {}) },
      );
    }
    if (url.pathname.startsWith("/api/")) {
      const sessionId = sessions.session(request);
      if (!sessionId) return json({ error: "Unlock this browser session first" }, 401);
      try {
        if (url.pathname === "/api/hosts") {
          if (request.method === "GET") {
            await registry.load();
            const hosts = await Promise.all(
              registry.list().map(async (host) => {
                try {
                  await readCredential(registry.get(host.id).tokenFile);
                  return { ...host, credentialStatus: "ready" };
                } catch {
                  return { ...host, credentialStatus: "unavailable" };
                }
              }),
            );
            return json({ hosts: [...hosts, ...(fixture ? fixtureHosts : [])] });
          }

          if (request.method === "PUT") {
            const value = object(await request.json());
            const existing = registry.get(String(value.id));
            if ((value.url !== undefined && value.url !== existing.url) || value.tokenFile !== undefined)
              return json(
                { error: "Gateway addresses and credentials are configured on the bridge host" },
                403,
              );
            return json({ hosts: await registry.updateMetadata(String(value.id), value.name, value.cwd) });
          }
          if (request.method === "DELETE")
            return json({ hosts: await registry.remove(url.searchParams.get("id") ?? "") });
        }
        const match = url.pathname.match(/^\/api\/hosts\/([\w-]+)\/(.+)$/);
        if (!match) return json({ error: "Unknown browser endpoint" }, 404);
        const hostId = match[1];
        const action = match[2];
        if (!hostId || !action) return json({ error: "Invalid host route" }, 400);
        const speechMatch = action.match(/^speech\/([a-z]+)\/(.+)$/);
        const speechProvider = speechMatch?.[1];
        const speechPath = speechMatch?.[2];
        const speech =
          speechProvider && speechPath && speechTransport(speechProvider, request.method, speechPath);
        const visualDigest = action.match(/^visuals\/(.+)$/)?.[1];
        if (visualDigest !== undefined && !visualDigestPattern.test(visualDigest))
          return new Response(unavailableVisual("This visual reference is invalid."), {
            status: 400,
            headers: unavailableVisualHeaders,
          });
        const accountId = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
        const method =
          action === "ws" ||
          action === "health" ||
          action === "version" ||
          action === "accounts" ||
          action === "claude/accounts" ||
          visualDigest
            ? "GET"
            : action === "uploads" ||
                action === "download" ||
                action === "claude/accounts/refresh" ||
                new RegExp(`^accounts/${accountId}/remove$`).test(action)
              ? "POST"
              : action === "claude/accounts/preference"
                ? "PUT"
                : new RegExp(`^accounts/${accountId}$`).test(action)
                  ? "PATCH"
                  : undefined;
        if (!speech && !method) return json({ error: "Unknown browser endpoint" }, 404);
        if (!speech && request.method !== method) return json({ error: "Method not allowed" }, 405);
        const socketRoute = action === "ws" || speech === "websocket";
        let accountQuery = "";
        if (action === "ws") {
          const account = url.searchParams.get("accountId");
          const generation = url.searchParams.get("accountGeneration");
          if (
            url.searchParams.size &&
            (url.searchParams.size !== 2 ||
              !account ||
              !generation ||
              !new RegExp(`^${accountId}$`).test(account) ||
              !/^[1-9][0-9]{0,15}$/.test(generation) ||
              !Number.isSafeInteger(Number(generation)))
          )
            return json({ error: "An enrolled socket requires its exact account UUID and generation" }, 400);
          if (account && generation)
            accountQuery = `?${new URLSearchParams({ accountId: account, accountGeneration: generation })}`;
        }
        if (socketRoute && request.headers.get("upgrade")?.toLowerCase() !== "websocket")
          return json({ error: "WebSocket upgrade required" }, 400);
        if (fixture && fixtureHosts.some((host) => host.id === hostId)) {
          if (speech) return json({ error: "Speech requires a configured gateway" }, 503);
          if (action === "ws") {
            if (current.pendingWebSockets >= 24) return json({ error: "Too many browser connections" }, 429);
            if (
              current.upgrade(request, {
                data: { hostId, sessionId, closed: false, pending: [], pendingBytes: 0 },
              })
            )
              return undefined;
            return json({ error: "WebSocket upgrade failed" }, 400);
          }
          if (action === "uploads") {
            const body = await request.arrayBuffer();
            return json(
              {
                path: `/fixture/uploads/${url.searchParams.get("name")}`,
                bytes: body.byteLength,
                sha256: new Bun.CryptoHasher("sha256").update(body).digest("hex"),
              },
              201,
            );
          }
          if (action === "download") return new Response("Fixture file content\n", { headers });
          if (visualDigest)
            return new Response(unavailableVisual("Visuals need a configured gateway."), {
              status: 404,
              headers: unavailableVisualHeaders,
            });
          return json({ status: "ok", version: "fixture", commit: "synthetic", accounts: [] });
        }
        const host = registry.get(hostId);
        const token = await readCredential(host.tokenFile);
        if (!sessions.valid(sessionId)) return json({ error: "Unlock this browser session first" }, 401);
        if (socketRoute) {
          if (current.pendingWebSockets >= 24) return json({ error: "Too many browser connections" }, 429);
          const releaseSpeech = speech ? claimSpeech() : undefined;
          if (speech && !releaseSpeech) return json({ error: "Too many active speech relays" }, 429);
          try {
            if (
              current.upgrade(request, {
                data: {
                  hostId,
                  sessionId,
                  upstreamPath: speech ? `/${action}${url.search}` : `/ws${accountQuery}`,
                  speech: Boolean(speech),
                  releaseSpeech,
                  closed: false,
                  pending: [],
                  pendingBytes: 0,
                },
              })
            )
              return undefined;
          } catch (error) {
            releaseSpeech?.();
            throw error;
          }
          releaseSpeech?.();
          return json({ error: "WebSocket upgrade failed" }, 400);
        }
        if (visualDigest) {
          try {
            const upstream = await fetch(new URL("/files/download", host.url), {
              method: "POST",
              headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
              body: JSON.stringify({ visualDigest }),
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(15_000)]),
              redirect: "error",
            });
            if (!upstream.ok) {
              await upstream.body?.cancel();
              return new Response(
                unavailableVisual(
                  upstream.status === 404
                    ? "This visual is no longer on its host."
                    : "This visual is unavailable.",
                ),
                { status: upstream.status === 404 ? 404 : 502, headers: unavailableVisualHeaders },
              );
            }
            return new Response(visualDocument(await verifiedVisual(upstream, visualDigest)), {
              headers: visualHeaders,
            });
          } catch {
            return new Response(unavailableVisual("This visual is unavailable."), {
              status: 502,
              headers: unavailableVisualHeaders,
            });
          }
        }
        const endpoint = new URL(action === "download" ? "/files/download" : `/${action}`, host.url);
        if (action === "uploads") endpoint.searchParams.set("name", url.searchParams.get("name") ?? "");
        else if (speech || action.startsWith("accounts") || action.startsWith("claude/accounts"))
          endpoint.search = url.search;
        const upstreamHeaders = new Headers({ Authorization: `Bearer ${token}` });
        if (action === "uploads") {
          const length = request.headers.get("content-length");
          const digest = request.headers.get("x-remotecoder-sha256");
          if (!length || !digest || !/^[a-f0-9]{64}$/.test(digest))
            return json({ error: "Uploads require a length and SHA-256 digest" }, 400);
          upstreamHeaders.set("Content-Length", length);
          upstreamHeaders.set("Content-Type", "application/octet-stream");
          upstreamHeaders.set("X-RemoteCoder-SHA256", digest);
        } else if (speech) {
          for (const name of [
            "accept",
            "accept-encoding",
            "content-length",
            "content-type",
            "api-revision",
            "x-goog-upload-command",
            "x-goog-upload-header-content-length",
            "x-goog-upload-header-content-type",
            "x-goog-upload-offset",
            "x-goog-upload-protocol",
          ]) {
            const value = request.headers.get(name);
            if (value) upstreamHeaders.set(name, value);
          }
        } else if (["POST", "PUT", "PATCH"].includes(request.method))
          upstreamHeaders.set("Content-Type", "application/json");
        const releaseSpeech = speech ? claimSpeech() : undefined;
        if (speech && !releaseSpeech) return json({ error: "Too many active speech relays" }, 429);
        return await proxyHttp(
          request,
          sessionId,
          endpoint,
          upstreamHeaders,
          [
            "content-type",
            "content-length",
            "content-encoding",
            "content-disposition",
            "x-remotecoder-sha256",
            ...(speech
              ? ["retry-after", "x-goog-upload-status", "x-goog-upload-url", "x-speech-relay-rejection"]
              : []),
          ],
          speech
            ? undefined
            : action === "uploads" || action === "download"
              ? 120000
              : action.startsWith("accounts") || action.startsWith("claude/accounts")
                ? 45000
                : 15000,
          releaseSpeech,
        );
      } catch (error) {
        return json(
          {
            error:
              error instanceof Error && !error.message.includes("Bearer")
                ? error.message
                : "The gateway request failed",
          },
          502,
        );
      }
    }
    if (!["GET", "HEAD"].includes(request.method)) return json({ error: "Method not allowed" }, 405);
    const path = url.pathname === "/" ? "/index.html" : url.pathname;
    const location = resolve(root, `.${path}`);
    if (!location.startsWith(`${root}/`)) return json({ error: "Invalid path" }, 400);
    let file = Bun.file(location);
    if (!(await file.exists())) return json({ error: "Browser asset missing; run bun run build" }, 404);
    let compressed = false;
    if (
      /\.(wasm|js)$/.test(path) &&
      /(?:^|,)\s*gzip(?:\s*;\s*q=(?!0(?:\.0*)?(?:\s*,|\s*$))[\d.]+)?\s*(?:,|$)/i.test(
        request.headers.get("accept-encoding") ?? "",
      )
    ) {
      const gzip = Bun.file(`${location}.gz`);
      const [originalInfo, compressedInfo] = await Promise.all([
        stat(location),
        stat(`${location}.gz`).catch(() => undefined),
      ]);
      if (compressedInfo && compressedInfo.mtimeMs >= originalInfo.mtimeMs) {
        file = gzip;
        compressed = true;
      }
    }
    return new Response(file, {
      headers: {
        ...headers,
        "Cache-Control": path === "/index.html" ? "no-store" : "no-cache",
        ...(/\.(wasm|js)$/.test(path) ? { Vary: "Accept-Encoding" } : {}),
        ...(compressed
          ? {
              "Content-Encoding": "gzip",
              "Content-Type": path.endsWith(".wasm") ? "application/wasm" : "text/javascript; charset=utf-8",
              Vary: "Accept-Encoding",
            }
          : {}),
        ...(!accessFile && request.method === "GET" && path === "/index.html" && !sessions.authorized(request)
          ? { "Set-Cookie": cookie(sessions.create()) }
          : {}),
      },
    });
  },
  websocket: {
    maxPayloadLength: maximumFrameBytes,
    backpressureLimit: maximumBufferedBytes,
    closeOnBackpressureLimit: true,
    async open(socket) {
      const data = socket.data;
      if (!authorizedSocket(socket)) return;
      data.releaseSession = sessions.attach(data.sessionId, () => {
        closeBridge(socket, 1008, "Browser session ended; unlock this browser again");
      });
      if (!data.releaseSession) {
        closeBridge(socket, 1008, "Browser session ended; unlock this browser again");
        return;
      }
      if (fixture && fixtureHosts.some((host) => host.id === data.hostId)) {
        data.fixture = new FixtureConnection(data.hostId, (frame) => {
          forwardToBrowser(socket, JSON.stringify(frame));
        });
        return;
      }
      try {
        const host = registry.get(data.hostId);
        const token = await readCredential(host.tokenFile);
        if (!authorizedSocket(socket)) return;
        const url = new URL(data.upstreamPath ?? "/ws", host.url);
        url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
        const upstream = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
        upstream.binaryType = "arraybuffer";
        data.upstream = upstream;
        upstream.addEventListener("open", () => {
          if (!authorizedSocket(socket)) {
            upstream.terminate();
            return;
          }
          for (const message of data.pending) forwardToGateway(socket, message);
          data.pending = [];
          data.pendingBytes = 0;
        });
        upstream.addEventListener("message", (event) => {
          if (typeof event.data === "string") forwardToBrowser(socket, event.data);
          else if (data.speech && event.data instanceof ArrayBuffer) forwardToBrowser(socket, event.data);
          else closeBridge(socket, 1003, "Gateway must send JSON text frames");
        });
        upstream.addEventListener("close", (event) => {
          const validCode =
            (event.code >= 1000 && event.code <= 1014 && ![1004, 1005, 1006].includes(event.code)) ||
            (event.code >= 3000 && event.code <= 4999);
          closeBridge(
            socket,
            data.speech && validCode ? event.code : 1011,
            data.speech && validCode ? event.reason : "Gateway connection closed; reconnect to refresh state",
          );
        });
        upstream.addEventListener("error", () => {
          closeBridge(socket, 1011, "Gateway connection failed; check address and credential file");
        });
      } catch {
        closeBridge(
          socket,
          1011,
          "Gateway authentication or connection failed; check the host configuration",
        );
      }
    },
    message(socket, message) {
      const data = socket.data;
      if (!authorizedSocket(socket)) return;
      if (typeof message !== "string" && !data.speech) {
        closeBridge(socket, 1003, "JSON text frames required");
        return;
      }
      if (data.fixture) {
        if (typeof message === "string") data.fixture.receive(message);
        return;
      }
      const upstream = data.upstream;
      if (upstream?.readyState === WebSocket.OPEN) {
        forwardToGateway(socket, message);
      } else {
        const bytes = frameBytes(message);
        if (data.pending.length >= 128 || data.pendingBytes + bytes > 1024 * 1024) {
          closeBridge(socket, 1013, "Connection queue full");
          return;
        }
        data.pending.push(message);
        data.pendingBytes += bytes;
      }
    },
    close(socket) {
      releaseBridge(socket.data);
    },
    drain(socket) {
      if (!authorizedSocket(socket)) return;
      clearTimeout(socket.data.drainDeadline);
      socket.data.drainDeadline = undefined;
      socket.data.upstream?.resume();
    },
  },
});
console.log(`RemoteCoder browser client: ${origin}${fixture ? " (synthetic fixture workspace)" : ""}`);
const shutdown = () => {
  sessions.dispose();
  server.stop(true);
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
