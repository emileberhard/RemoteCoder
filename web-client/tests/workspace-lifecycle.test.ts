import { expect, test } from "bun:test";
import { host, setup } from "./fixtures/workspace";

test("browser visibility resumes account reads and disposal releases lifecycle listeners", async () => {
  const previous = new Map(
    ["window", "document", "fetch"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]),
  );
  const browser = new EventTarget();
  const page = Object.assign(new EventTarget(), { visibilityState: "visible" });
  const reads: string[] = [];
  const install = (key: string, value: unknown) =>
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  install("window", browser);
  install("document", page);
  install("fetch", async (path: string) => {
    reads.push(path);
    if (path === "/api/hosts") return Response.json({ hosts: [host("mini")] });
    if (path.endsWith("/version")) return Response.json({ version: "dev" });
    return Response.json(
      path.endsWith("claude/accounts")
        ? {
            automatic: "fixture",
            preference: null,
            accounts: [
              {
                id: "fixture",
                label: "Fixture",
                plan: "max",
                shared: false,
                credential: "ready",
                availability: "available",
                windows: [],
              },
            ],
          }
        : { schemaVersion: 2, refreshing: false, accounts: [], retiredClaudeAccountIds: [] },
    );
  });
  let workspace: Awaited<ReturnType<typeof setup>>["workspace"] | undefined;
  try {
    ({ workspace } = await setup());
    await workspace.loadHosts();
    const count = () => reads.filter((path) => path.endsWith("claude/accounts")).length;
    expect(count()).toBe(1);
    page.visibilityState = "hidden";
    page.dispatchEvent(new Event("visibilitychange"));
    page.visibilityState = "visible";
    page.dispatchEvent(new Event("visibilitychange"));
    await workspace.refreshAccountUsage("claude", false);
    expect(count()).toBe(2);
    page.dispatchEvent(new Event("visibilitychange"));
    expect(count()).toBe(2);
    browser.dispatchEvent(new Event("pagehide"));
    browser.dispatchEvent(new Event("pageshow"));
    await workspace.refreshAccountUsage("claude", false);
    expect(count()).toBe(3);
    workspace.dispose();
    page.dispatchEvent(new Event("visibilitychange"));
    browser.dispatchEvent(new Event("pageshow"));
    expect(count()).toBe(3);
  } finally {
    workspace?.dispose();
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else Reflect.deleteProperty(globalThis, key);
    }
  }
});
