import { expect, test } from "bun:test";
import { GatewayConnection } from "./gateway";

test("canceling browser dictation sends its exact RPC id", async () => {
  const names = ["location", "fetch", "WebSocket"] as const;
  const originals = names.map((name) => Object.getOwnPropertyDescriptor(globalThis, name));
  const sent: Array<{ id?: string; method: string; params?: { id?: string } }> = [];
  class Socket extends EventTarget {
    static readonly OPEN = 1;
    readyState = 1;
    constructor(_url: URL) {
      super();
      queueMicrotask(() => this.dispatchEvent(new Event("open")));
    }
    send(raw: string) {
      const message = JSON.parse(raw);
      sent.push(message);
      if (message.id && message.method !== "dictation/transcribe") {
        queueMicrotask(() =>
          this.dispatchEvent(
            new MessageEvent("message", { data: JSON.stringify({ id: message.id, result: {} }) }),
          ),
        );
      }
    }
    close() {
      this.readyState = 3;
    }
  }
  Object.defineProperty(globalThis, "location", {
    value: new URL("https://bridge.example/"),
    configurable: true,
  });
  Object.defineProperty(globalThis, "fetch", {
    value: async () => Response.json({ authenticated: true, loginRequired: false }),
    configurable: true,
  });
  Object.defineProperty(globalThis, "WebSocket", { value: Socket, configurable: true });
  const connection = new GatewayConnection(
    "host",
    () => {},
    () => {},
    () => {},
  );
  try {
    await connection.connect();
    const controller = new AbortController();
    const pending = connection.call(
      "dictation/transcribe",
      { path: "/upload", durationMs: 10 },
      { signal: controller.signal },
    );
    await Promise.resolve();
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    const request = sent.find((message) => message.method === "dictation/transcribe");
    const cancellation = sent.find((message) => message.method === "$/cancelRequest");
    expect(request?.id).toBeDefined();
    expect(cancellation?.params?.id).toBe(request?.id);
  } finally {
    connection.retire();
    names.forEach((name, index) => {
      const descriptor = originals[index];
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else Reflect.deleteProperty(globalThis, name);
    });
  }
});
