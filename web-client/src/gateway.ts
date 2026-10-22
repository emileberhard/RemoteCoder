import type { Enrollment } from "./execution-context";
import { type Frame, frame, type Receipt } from "./protocol/boundary";

export class RpcError extends Error {
  constructor(
    message: string,
    readonly code: number,
    readonly data?: unknown,
  ) {
    super(message);
  }
}
export type ConnectionState = "disconnected" | "connecting" | "connected" | "reconnecting";
export type Captured = { value: unknown; receipt: Receipt };
export type Rpc = {
  capture(
    method: string,
    params?: unknown,
    options?: { signal?: AbortSignal; timeout?: number },
  ): Promise<Captured>;
  call(
    method: string,
    params?: unknown,
    options?: { signal?: AbortSignal; timeout?: number },
  ): Promise<unknown>;
  reply(id: string | number, result: unknown): void;
  notify(method: string, params?: unknown): void;
};

type Pending = {
  resolve(value: unknown): void;
  reject(error: Error): void;
  cleanup(): void;
  capture: boolean;
};
class BrowserSessionRequired extends Error {}
export class GatewayConnection implements Rpc {
  private socket?: WebSocket;
  private generation = 0;
  private wireSequence = 0;
  private pending = new Map<string, Pending>();
  private retired = false;
  private retry?: ReturnType<typeof setTimeout>;
  private attempt = 0;
  private ready?: Promise<void>;
  private bootstrap?: AbortController;
  constructor(
    readonly hostId: string,
    private readonly event: (frame: Frame) => void,
    private readonly status: (state: ConnectionState, error?: string) => void,
    private readonly restored: () => void,
    readonly enrollment?: Enrollment,
  ) {}
  connect() {
    if (this.retired) return Promise.reject(new Error("This host connection has been retired"));
    if (this.ready) return this.ready;
    clearTimeout(this.retry);
    this.retry = undefined;
    const generation = ++this.generation;
    this.status(this.attempt ? "reconnecting" : "connecting");
    const controller = new AbortController();
    this.bootstrap = controller;
    this.ready = this.open(generation, controller).catch((error) => {
      if (this.generation === generation && !this.retired && this.ready) {
        this.ready = undefined;
        if (error instanceof BrowserSessionRequired) this.status("disconnected", error.message);
        else this.scheduleRetry(error);
      }
      throw error;
    });
    return this.ready;
  }
  private async open(generation: number, controller: AbortController): Promise<void> {
    try {
      const session = await api<{ authenticated: boolean; loginRequired: boolean }>("/api/session", {
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]),
        cache: "no-store",
      });
      if (this.generation !== generation || this.retired || controller.signal.aborted)
        throw new DOMException("Connection was canceled", "AbortError");
      if (session.authenticated !== true)
        throw new BrowserSessionRequired("Browser session expired. Reload this page to sign in.");
    } finally {
      if (this.bootstrap === controller) this.bootstrap = undefined;
    }
    const url = new URL(`/api/hosts/${encodeURIComponent(this.hostId)}/ws`, location.href);
    if (this.enrollment) {
      url.searchParams.set("accountId", this.enrollment.accountId);
      url.searchParams.set("accountGeneration", String(this.enrollment.generation));
    }
    url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(url);
    this.socket = socket;
    return new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", async () => {
        try {
          await this.callConnected(
            "initialize",
            {
              clientInfo: { name: "RemoteCoder", title: "RemoteCoder Web", version: "0.1.0" },
              capabilities: { experimentalApi: true },
            },
            {},
          );
          if (this.generation !== generation || this.retired) return;
          this.notify("initialized", {});
          await this.callConnected("device/tools/declare", { tools: [] }, {});
          if (this.generation !== generation || this.retired) return;
          const recovering = this.attempt > 0;
          this.attempt = 0;
          this.status("connected");
          resolve();
          if (recovering) this.restored();
        } catch (error) {
          reject(error);
          socket.close(1011, "Gateway initialization failed");
        }
      });
      socket.addEventListener("message", (message) => {
        if (this.generation !== generation || this.retired) return;
        try {
          if (typeof message.data !== "string" || message.data.length > 32 * 1024 * 1024)
            throw new Error("Gateway frame exceeds capacity");
          const value = frame(JSON.parse(message.data));
          const receipt = { connection: generation, sequence: ++this.wireSequence };
          if (value.id !== undefined && value.method === undefined) {
            const key = String(value.id);
            const pending = this.pending.get(key);
            if (!pending) return;
            this.pending.delete(key);
            pending.cleanup();
            if (value.error)
              pending.reject(new RpcError(value.error.message, value.error.code, value.error.data));
            else pending.resolve(pending.capture ? { value: value.result, receipt } : value.result);
          } else this.event({ ...value, receipt });
        } catch (error) {
          this.status("disconnected", error instanceof Error ? error.message : "Unreadable gateway message");
          socket.close(1002, "Invalid gateway message");
        }
      });
      socket.addEventListener("close", (event) => {
        if (this.generation !== generation) return;
        const error = new Error(
          event.reason ||
            "Connection lost. A submitted action may have been accepted; refresh before sending it again.",
        );
        for (const pending of this.pending.values()) {
          pending.cleanup();
          pending.reject(error);
        }
        this.pending.clear();
        reject(error);
        this.ready = undefined;
        if (this.retired) {
          this.status("disconnected");
          return;
        }
        this.scheduleRetry(error);
      });
      socket.addEventListener("error", () =>
        reject(new Error("Could not connect. Check the host address and credential file.")),
      );
    });
  }
  private scheduleRetry(error: unknown) {
    if (this.retired) return;
    this.status("reconnecting", error instanceof Error ? error.message : "Browser bridge unavailable");
    this.attempt += 1;
    clearTimeout(this.retry);
    this.retry = setTimeout(
      () => {
        this.retry = undefined;
        void this.connect().catch(() => undefined);
      },
      Math.min(30000, 1000 * 2 ** Math.min(this.attempt - 1, 5)),
    );
  }
  async call(method: string, params: unknown = {}, options: { signal?: AbortSignal; timeout?: number } = {}) {
    await this.connect();
    if (options.signal?.aborted) throw new DOMException("Canceled", "AbortError");
    return this.callConnected(method, params, options);
  }
  async capture(
    method: string,
    params: unknown = {},
    options: { signal?: AbortSignal; timeout?: number } = {},
  ): Promise<Captured> {
    await this.connect();
    if (options.signal?.aborted) throw new DOMException("Canceled", "AbortError");
    return this.callConnected(method, params, { ...options, capture: true }) as Promise<Captured>;
  }
  private callConnected(
    method: string,
    params: unknown,
    {
      signal,
      timeout = 60000,
      capture = false,
    }: { signal?: AbortSignal; timeout?: number; capture?: boolean },
  ) {
    if (this.retired || this.socket?.readyState !== WebSocket.OPEN)
      return Promise.reject(new Error("Gateway is disconnected"));
    if (this.pending.size >= 128) return Promise.reject(new Error("Too many concurrent gateway requests"));
    const id = crypto.randomUUID();
    const socket = this.socket;
    return new Promise<unknown>((resolve, reject) => {
      const abort = () => {
        this.pending.delete(id);
        cleanup();
        reject(new DOMException("Canceled", "AbortError"));
      };
      const timer = setTimeout(() => {
        this.pending.delete(id);
        cleanup();
        reject(new Error(`${method} did not acknowledge. Refresh state before retrying a submitted action.`));
      }, timeout);
      const cleanup = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
      };
      this.pending.set(id, { resolve, reject, cleanup, capture });
      signal?.addEventListener("abort", abort, { once: true });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  reply(id: string | number, result: unknown) {
    if (this.socket?.readyState !== WebSocket.OPEN)
      throw new Error("Reconnect before answering this request");
    this.socket.send(JSON.stringify({ id, result }));
  }
  notify(method: string, params: unknown = {}) {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify({ method, params }));
  }
  retire() {
    this.retired = true;
    this.bootstrap?.abort();
    clearTimeout(this.retry);
    this.socket?.close(1000, "Host connection retired");
    for (const pending of this.pending.values()) {
      pending.cleanup();
      pending.reject(new Error("Host retired"));
    }
    this.pending.clear();
  }
}

declare const RC_WEB_BUILD: string | undefined;
export const webBuild = typeof RC_WEB_BUILD === "string" ? RC_WEB_BUILD : undefined;
export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers },
  });
  const deployed = response.headers.get("x-remotecoder-web-build");
  if (
    webBuild &&
    deployed &&
    deployed !== webBuild &&
    sessionStorage.getItem("remotecoder.web.reloadedFor") !== deployed
  ) {
    sessionStorage.setItem("remotecoder.web.reloadedFor", deployed);
    location.reload();
    return new Promise<T>(() => {});
  }
  const result = await response.json();
  if (!response.ok)
    throw new Error(
      typeof result.error === "string" ? result.error : `Browser bridge returned HTTP ${response.status}`,
    );
  return result as T;
}
