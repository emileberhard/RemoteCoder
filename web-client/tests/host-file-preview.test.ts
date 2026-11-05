import { afterEach, expect, test } from "bun:test";
import { readHostFile } from "../src/platform/host-files";
import { HostImagePreviews } from "../src/platform/host-image-previews";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("previews serialize per host, cancel queued reads and let another host proceed", async () => {
  const first = Promise.withResolvers<Response>();
  const requests: string[] = [];
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    writable: true,
    value: async (url: string, init: RequestInit) => {
      const path = JSON.parse(String(init.body)).path;
      requests.push(`${url}:${path}`);
      return path === "/first.png" ? first.promise : new Response(path);
    },
  });
  const owner = new HostImagePreviews();
  const canceled = new AbortController();
  try {
    const active = owner.read("one", "/first.png", "/", new AbortController().signal);
    const removed = owner.read("one", "/canceled.png", "/", canceled.signal).catch((error) => error);
    const next = owner.read("one", "/next.png", "/", new AbortController().signal);
    const other = owner.read("two", "/other.png", "/", new AbortController().signal);
    canceled.abort();
    expect((await removed).name).toBe("AbortError");
    expect(await (await other).text()).toBe("/other.png");
    expect(requests).toHaveLength(2);
    first.resolve(new Response("first"));
    await active;
    expect(await (await next).text()).toBe("/next.png");
    expect(requests.some((path) => path.endsWith("/canceled.png"))).toBe(false);
  } finally {
    owner.dispose();
  }
});

test("busy preview reads retry automatically while remaining admitted", async () => {
  let requests = 0;
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    writable: true,
    value: async () => {
      requests++;
      return requests === 1
        ? Response.json(
            { error: "Two downloads are already active" },
            { status: 429, headers: { "Retry-After": "0" } },
          )
        : new Response("image");
    },
  });
  const owner = new HostImagePreviews();
  try {
    expect(await (await owner.read("host", "/screen.png", "/", new AbortController().signal)).text()).toBe(
      "image",
    );
    expect(requests).toBe(2);
  } finally {
    owner.dispose();
  }
});

test("host image reads preserve the exact host, relative file and MIME type", async () => {
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    writable: true,
    value: async (url: string, init: RequestInit) => {
      expect(String(url)).toBe("/api/hosts/host%2Fone/download");
      expect(init?.body).toBe(JSON.stringify({ path: "/project/screen.png" }));
      return new Response(new Uint8Array([1, 2, 3]), { headers: { "Content-Type": "image/png" } });
    },
  });
  const file = await readHostFile("host/one", "screen.png", "/project/", new AbortController().signal, 3);
  expect(file.type).toBe("image/png");
  expect([...new Uint8Array(await file.arrayBuffer())]).toEqual([1, 2, 3]);
});

test("oversized previews cancel the file stream with or without an advertised length", async () => {
  for (const length of [undefined, "8"]) {
    let canceled = false;
    Object.defineProperty(globalThis, "fetch", {
      configurable: true,
      writable: true,
      value: async () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new Uint8Array(4));
              controller.enqueue(new Uint8Array(4));
            },
            cancel() {
              canceled = true;
            },
          }),
          { headers: length ? { "Content-Length": length } : {} },
        ),
    });
    await expect(readHostFile("host", "/screen.png", "/", new AbortController().signal, 6)).rejects.toThrow(
      "too large",
    );
    expect(canceled).toBe(true);
  }
});
