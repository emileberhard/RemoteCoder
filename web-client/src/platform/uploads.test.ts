import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { BrowserUploadService, browserUploadLimit } from "./uploads";

function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((accept) => {
    resolve = accept;
  });
  return { promise, resolve };
}

describe("shared browser upload ownership", () => {
  let directory: string;
  let upstream: Bun.Server<undefined>;
  let bridge: Bun.Subprocess<"ignore", "pipe", "pipe">;
  let origin: string;
  let cookie: string;
  const received: {
    bytes: Uint8Array;
    name: string;
    length: string | null;
    digest: string | null;
    authorization: string | null;
  }[] = [];

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "remotecoder-browser-uploads-"));
    upstream = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const url = new URL(request.url);
        if (url.pathname !== "/uploads" || request.method !== "POST")
          return new Response("Missing fixture route", { status: 404 });
        const bytes = new Uint8Array(await request.arrayBuffer());
        const name = url.searchParams.get("name") ?? "";
        received.push({
          bytes,
          name,
          length: request.headers.get("content-length"),
          digest: request.headers.get("x-remotecoder-sha256"),
          authorization: request.headers.get("authorization"),
        });
        const path = join(directory, "uploaded.bin");
        await Bun.write(path, bytes);
        return Response.json(
          {
            path,
            bytes: name === "corrupt.txt" ? bytes.byteLength + 1 : bytes.byteLength,
            sha256: new Bun.CryptoHasher("sha256").update(bytes).digest("hex"),
          },
          { status: 201 },
        );
      },
    });
    const portProbe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
    const port = portProbe.port;
    await portProbe.stop(true);
    origin = `http://127.0.0.1:${port}`;
    const tokenFile = join(directory, "synthetic-token");
    const configFile = join(directory, "hosts.json");
    await writeFile(tokenFile, "isolated-upload-test-token", { mode: 0o600 });
    await writeFile(
      configFile,
      JSON.stringify([
        {
          id: "upload-host",
          name: "Upload fixture",
          cwd: "/tmp",
          url: `http://127.0.0.1:${upstream.port}`,
          tokenFile,
        },
      ]),
    );
    bridge = Bun.spawn([process.execPath, resolve(import.meta.dir, "../../server/index.ts")], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        RC_WEB_CONFIG: configFile,
        RC_WEB_PORT: String(port),
        RC_WEB_BIND: "127.0.0.1",
        RC_WEB_ORIGIN: origin,
        RC_WEB_FIXTURE: "0",
        RC_WEB_ACCESS_KEY_FILE: "",
        RC_WEB_STATIC_DIR: directory,
      },
    });
    const reader = bridge.stdout.getReader();
    const ready = await reader.read();
    reader.releaseLock();
    if (ready.done) throw new Error(await new Response(bridge.stderr).text());
    const session = await fetch(`${origin}/api/session`, { method: "POST", headers: { Origin: origin } });
    cookie = session.headers.get("set-cookie")?.split(";")[0] ?? "";
    if (!cookie) throw new Error("The fixture browser session was not created");
  });

  afterAll(async () => {
    bridge?.kill("SIGTERM");
    if (bridge) await bridge.exited;
    if (upstream) await upstream.stop(true);
    if (directory) await rm(directory, { recursive: true, force: true });
  });

  const throughBridge = (input: RequestInfo | URL, init?: RequestInit) => {
    const path = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const headers = new Headers(init?.headers);
    headers.set("Origin", origin);
    headers.set("Cookie", cookie);
    return fetch(new URL(path, origin), { ...init, headers });
  };

  test("sends synthetic file bytes through the real BFF and verifies the stored file", async () => {
    const service = new BrowserUploadService("upload-host", { fetch: throughBridge });
    const file = new File(["abc"], "report ä.txt", { type: "text/plain" });
    try {
      const stored = await service.upload(file);
      expect(stored.bytes).toBe(3);
      expect(stored.sha256).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
      expect(await Bun.file(stored.path).text()).toBe("abc");
      const request = received.at(-1);
      expect(request?.name).toBe("report ä.txt");
      expect(request?.length).toBe("3");
      expect(request?.digest).toBe(stored.sha256);
      expect(request?.authorization).toBe("Bearer isolated-upload-test-token");
    } finally {
      service.dispose();
    }
  });

  test("rejects a successful HTTP upload whose stored byte count differs", async () => {
    const service = new BrowserUploadService("upload-host", { fetch: throughBridge });
    try {
      await expect(service.upload(new File(["abc"], "corrupt.txt"))).rejects.toThrow("different file");
    } finally {
      service.dispose();
    }
  });

  test("cancellation during file reading fences hashing and the HTTP request", async () => {
    const bytes = deferred<ArrayBuffer>();
    class PendingFile extends File {
      override arrayBuffer() {
        return bytes.promise;
      }
    }
    let requests = 0;
    const service = new BrowserUploadService("upload-host", {
      fetch: async () => {
        requests += 1;
        return new Response();
      },
    });
    const controller = new AbortController();
    const operation = service.upload(new PendingFile(["abc"], "pending.txt"), { signal: controller.signal });
    controller.abort();
    bytes.resolve(new TextEncoder().encode("abc").buffer);
    await expect(operation).rejects.toThrow("abort");
    expect(requests).toBe(0);
    service.dispose();
  });

  test("retirement aborts the HTTP owner and rejects a late accepted upload", async () => {
    const reply = deferred<Response>();
    const started = deferred<AbortSignal>();
    const service = new BrowserUploadService("upload-host", {
      fetch: async (_input, init) => {
        if (!init?.signal) throw new Error("Missing upload cancellation owner");
        started.resolve(init.signal);
        return reply.promise;
      },
    });
    const operation = service.upload(new File(["abc"], "late.txt"));
    const signal = await started.promise;
    service.dispose();
    expect(signal.aborted).toBe(true);
    reply.resolve(
      Response.json(
        {
          path: "/tmp/late.txt",
          bytes: 3,
          sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        },
        { status: 201 },
      ),
    );
    await expect(operation).rejects.toThrow("abort");
  });

  test("bounds file reads before allocating or sending an oversized attachment", async () => {
    let read = false;
    class OversizedFile extends File {
      override get size() {
        return browserUploadLimit + 1;
      }
      override async arrayBuffer() {
        read = true;
        return new ArrayBuffer(0);
      }
    }
    const service = new BrowserUploadService("upload-host");
    await expect(service.upload(new OversizedFile([], "oversized.bin"))).rejects.toThrow("50 MiB");
    expect(read).toBe(false);
    service.dispose();
  });
});
