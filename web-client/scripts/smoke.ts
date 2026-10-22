import { object } from "../src/protocol/boundary";

declare const WebSocket: {
  new (url: string, options: Bun.WebSocketOptions): globalThis.WebSocket;
};

const address = process.argv[2];
if (!address) throw new Error("Pass the bridge HTTP(S) address");
const origin = process.argv[3] ?? address;
const mode = process.argv[4] ?? "gateways";
if (!["local", "primary", "gateways"].includes(mode))
  throw new Error("Smoke mode must be local, primary or gateways");
const headers = { Host: new URL(origin).host, Origin: origin };
const entry = await fetch(`${address}/`, { headers, signal: AbortSignal.timeout(10000) });
if (!entry.ok) throw new Error(`Browser entry returned ${entry.status}`);
const html = await entry.text();
let cookie = entry.headers.get("set-cookie")?.split(";")[0];
const assets = [...html.matchAll(/(?:src|href)=["'](\/[^"']+\.(?:js|css|svg|webmanifest))["']/g)];
if (!assets.some((match) => match[1]?.endsWith(".js"))) throw new Error("Entry has no browser bundle");
for (const match of assets) {
  const response = await fetch(`${address}${match[1]}`, { headers, signal: AbortSignal.timeout(10000) });
  if (!response.ok || !(await response.arrayBuffer()).byteLength)
    throw new Error(`Static asset failed: ${match[1]}`);
}
const sessionResponse = await fetch(`${address}/api/session`, {
  headers: { ...headers, ...(cookie ? { Cookie: cookie } : {}) },
  signal: AbortSignal.timeout(10000),
});
const session = object(await sessionResponse.json());
if (!session.authenticated || session.loginRequired || session.fixture)
  throw new Error("Expected an authenticated private deployment without fixtures");
cookie = sessionResponse.headers.get("set-cookie")?.split(";")[0] ?? cookie;
if (!cookie) throw new Error("Session did not issue a browser cookie");
const response = await fetch(`${address}/api/hosts`, {
  headers: { ...headers, Cookie: cookie },
  signal: AbortSignal.timeout(10000),
});
if (!response.ok) throw new Error(`Host inventory returned ${response.status}`);
const { hosts } = (await response.json()) as {
  hosts: { id: string; url: string; credentialStatus: string }[];
};
if (!hosts.length || hosts.some((host) => host.credentialStatus !== "ready"))
  throw new Error("Expected configured gateways with readable private credentials");
const localGateway = (host: { url: string }) =>
  ["127.0.0.1", "localhost", "[::1]"].includes(new URL(host.url).hostname);
if (mode === "primary" && !hosts.some(localGateway)) throw new Error("No local gateway is configured");
const initialized: string[] = [];
const failures: { hostId: string; error: string }[] = [];
await Promise.all(
  (mode === "local" ? [] : hosts).map(async (host) => {
    try {
      await new Promise<void>((resolve, reject) => {
        const socket = new WebSocket(`${address.replace(/^http/, "ws")}/api/hosts/${host.id}/ws`, {
          headers: { ...headers, Cookie: cookie },
        });
        const timer = setTimeout(() => finish(new Error(`Gateway ${host.id} timed out`)), 10000);
        const finish = (error?: Error) => {
          clearTimeout(timer);
          socket.onclose = null;
          socket.close();
          if (error) reject(error);
          else resolve();
        };
        socket.onopen = () =>
          socket.send(
            JSON.stringify({
              id: "hosting-smoke",
              method: "initialize",
              params: {
                clientInfo: { name: "remotecoder_web_hosting_smoke", version: "1.0.0" },
                capabilities: { experimentalApi: true },
              },
            }),
          );
        socket.onmessage = (event) => {
          const frame = JSON.parse(String(event.data));
          if (frame.id !== "hosting-smoke") return;
          if (frame.error || !frame.result) finish(new Error(`Gateway ${host.id} rejected initialization`));
          else finish();
        };
        socket.onerror = () => finish(new Error(`Gateway ${host.id} WebSocket failed`));
        socket.onclose = () => finish(new Error(`Gateway ${host.id} closed before initialization`));
      });
      initialized.push(host.id);
    } catch (error) {
      if (mode === "gateways" || localGateway(host)) throw error;
      failures.push({ hostId: host.id, error: error instanceof Error ? error.message : String(error) });
    }
  }),
);
const deployment = await fetch(`${address}/deployment.json`, { headers, signal: AbortSignal.timeout(10000) });
if (!deployment.ok) throw new Error("Deployment identity is unavailable");
console.log(
  JSON.stringify({
    ...object(await deployment.json()),
    assets: assets.length,
    gatewayCoverage: mode === "local" ? "notChecked" : failures.length ? "partial" : "complete",
    initialized,
    failures,
  }),
);
