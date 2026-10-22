import { afterEach, beforeEach, expect, test } from "bun:test";
import { GatewayConnection } from "../src/gateway";

const globals = new Map<string, PropertyDescriptor | undefined>();
const connections: GatewayConnection[] = [];
let sockets: FakeSocket[];
let requests: string[];
function install(name: string, value: unknown) {
  if (!globals.has(name)) globals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
class FakeSocket extends EventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 3;
  readyState = 0;
  constructor(readonly url: URL) {
    super();
    sockets.push(this);
    requests.push("socket");
    queueMicrotask(() => {
      if (this.readyState !== 0) return;
      this.readyState = 1;
      this.dispatchEvent(new Event("open"));
    });
  }
  send(text: string) {
    const value = JSON.parse(text);
    requests.push(value.method ?? "reply");
    if (value.id)
      queueMicrotask(() => {
        this.dispatchEvent(
          new MessageEvent("message", { data: JSON.stringify({ id: value.id, result: {} }) }),
        );
      });
  }
  close(code = 1000, reason = "") {
    this.readyState = 3;
    const event = new Event("close");
    Object.defineProperties(event, { code: { value: code }, reason: { value: reason } });
    this.dispatchEvent(event);
  }
}
beforeEach(() => {
  sockets = [];
  requests = [];
  install("location", new URL("https://bridge.example:8762/"));
  install("WebSocket", FakeSocket);
  install("fetch", async () => {
    requests.push("session");
    return Response.json({ authenticated: true, loginRequired: false });
  });
});
afterEach(() => {
  for (const connection of connections.splice(0)) connection.retire();
  for (const [name, descriptor] of globals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
  globals.clear();
});
test("concurrent callers recover the bridge session once before opening the exact enrolled socket", async () => {
  const enrollment = { accountId: "8dc8844a-15b0-4117-9c52-f61246c8012a", generation: 7 };
  const connection = new GatewayConnection(
    "mini",
    () => undefined,
    () => undefined,
    () => undefined,
    enrollment,
  );
  connections.push(connection);
  const first = connection.connect();
  expect(connection.connect()).toBe(first);
  await first;
  expect(requests).toEqual(["session", "socket", "initialize", "initialized", "device/tools/declare"]);
  expect(sockets).toHaveLength(1);
  expect(sockets[0]?.url.href).toBe(
    `wss://bridge.example:8762/api/hosts/mini/ws?accountId=${enrollment.accountId}&accountGeneration=7`,
  );
});
test("a bridge disconnect retries session recovery before creating its replacement socket", async () => {
  let resolve: () => void = () => undefined;
  const restored = new Promise<void>((done) => {
    resolve = done;
  });
  const connection = new GatewayConnection(
    "mini",
    () => undefined,
    () => undefined,
    resolve,
  );
  connections.push(connection);
  await connection.connect();
  sockets[0]?.close(1008, "Bridge restarted");
  await restored;
  expect(sockets).toHaveLength(2);
  expect(requests.filter((value) => value === "session")).toHaveLength(2);
  expect(requests.slice(5, 7)).toEqual(["session", "socket"]);
});
test("retirement during session recovery cancels its HTTP owner and fences a late socket", async () => {
  let signal: AbortSignal | undefined;
  let resolve: (value: Response) => void = () => undefined;
  install("fetch", (_path: unknown, options: RequestInit) => {
    signal = options.signal ?? undefined;
    return new Promise<Response>((done) => {
      resolve = done;
    });
  });
  const connection = new GatewayConnection(
    "mini",
    () => undefined,
    () => undefined,
    () => undefined,
  );
  connections.push(connection);
  const opening = connection.connect();
  connection.retire();
  expect(signal?.aborted).toBe(true);
  resolve(Response.json({ authenticated: true, loginRequired: false }));
  await expect(opening).rejects.toMatchObject({ name: "AbortError" });
  expect(sockets).toHaveLength(0);
});
test("an access-key deployment cannot open a socket from an unauthenticated session response", async () => {
  install("fetch", async () => Response.json({ authenticated: false, loginRequired: true }));
  const statuses: { state: string; error?: string }[] = [];
  const connection = new GatewayConnection(
    "mini",
    () => undefined,
    (state, error) => statuses.push({ state, error }),
    () => undefined,
  );
  connections.push(connection);
  await expect(connection.connect()).rejects.toThrow("sign in");
  expect(sockets).toHaveLength(0);
  expect(statuses.at(-1)).toMatchObject({ state: "disconnected" });
});
