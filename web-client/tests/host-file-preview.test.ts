import { afterEach, expect, test } from "bun:test";
import { readHostFile } from "../src/ui/files/download";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
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
