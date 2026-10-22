import { test, expect } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { resolve } from "node:path";
import { IsolatedGateway } from "../probes/isolated-gateway.mjs";

const tools = resolve(import.meta.dir, "..");

test("account isolation probe requires an explicit candidate", () => {
  const result = Bun.spawnSync(["bun", resolve(tools, "probes/accounts.mjs")]);
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("Pass the built gateway executable");
});

test("conversation agents probe requires a matching configs checkout", () => {
  const result = Bun.spawnSync([
    "bun",
    resolve(tools, "probes/conversation-agents.mjs"),
    "/synthetic/candidate",
  ]);
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("Pass the matching configs checkout");
});

test("isolated gateway fails as soon as its owned process exits", async () => {
  const lab = new IsolatedGateway("/synthetic/gateway", "/tmp/synthetic", "synthetic", 12345);
  lab.child = { exitCode: 17 };
  await expect(lab.waitFor(async () => false)).rejects.toThrow("Owned gateway exited with code 17");
});

test("isolated gateway closes clients and waits for its owned process", async () => {
  const lab = new IsolatedGateway("/synthetic/gateway", await mkdtemp("/tmp/rc-gateway-test-"), "synthetic", 12345);
  try {
    await lab.write(lab.path("isolated-gateway.json"), "{}");
    let closed = 0;
    let signal;
    lab.clients.add({ close: () => { closed++; } });
    lab.child = { exitCode: null, exited: Promise.resolve(0), kill: value => { signal = value; } };
    await lab.stop();
    expect(closed).toBe(1);
    expect(lab.clients.size).toBe(0);
    expect(signal).toBe("SIGTERM");
    expect(await Bun.file(lab.path("isolated-gateway.json")).exists()).toBe(false);
  } finally {
    await lab.removeRoot();
  }
});
