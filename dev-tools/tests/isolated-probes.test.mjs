import { test, expect } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { installSeed } from "../probes/delegated-job-seed.mjs";
import { IsolatedGateway } from "../probes/isolated-gateway.mjs";

const tools = resolve(import.meta.dir, "..");

test("account isolation probe requires an explicit candidate", () => {
  const result = Bun.spawnSync(["bun", resolve(tools, "probes/accounts.mjs")]);
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("Pass the built gateway executable");
});

test("delegated jobs probe requires the matched runtime package", () => {
  const result = Bun.spawnSync([
    "bun",
    resolve(tools, "probes/delegated-jobs.mjs"),
    "/synthetic/candidate",
  ]);
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("Pass the matched Codex runtime package directory");
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


test("copied job seed remaps provider homes and disables execution without changing its source", async () => {
  const lab = new IsolatedGateway("/synthetic/gateway", await mkdtemp("/tmp/rc-seed-test-"), "synthetic", 12345);
  const snapshot = lab.path("private-snapshot");
  try {
    for (const kind of ["jobs", "agents", "uncertainties"]) await mkdir(join(snapshot, "store", kind), { recursive: true });
    const job = { jobId: "fixture-job", source: "runtime", stop: { kind: "requested", mutationId: "fixture", atMs: 1 },
      execution: { conversation: { provider: "claude", providerHome: { kind: "known", path: "/original/private/home" } } },
      spec: { cwd: "/original/worktree", toolScope: { kind: "readOnly", root: "/original/worktree" } } };
    const original = JSON.stringify(job);
    const source = join(snapshot, "store/jobs/fixture.json");
    await writeFile(source, original);
    const manifest = join(snapshot, "manifest.json");
    await writeFile(manifest, JSON.stringify({ version: 1, snapshot: true, jobStore: "store", transcripts: [],
      queries: [{ threadId: "fixture-parent", expectedAgentIds: ["fixture-agent"] }] }));
    const seeded = await installSeed(lab, manifest);
    const copied = JSON.parse(await readFile(seeded.snapshots[0].path, "utf8"));
    expect(await readFile(source, "utf8")).toBe(original);
    expect(copied.source).toBe("imported");
    expect(copied.stop).toEqual({ kind: "notRequested" });
    expect(copied.execution.conversation.providerHome.path).toBe(lab.path(".claude"));
    expect(copied.spec.cwd.startsWith(lab.path("work/seed/"))).toBe(true);
    expect(copied.spec.toolScope.root).toBe(copied.spec.cwd);
    expect(seeded.summary.importedSnapshots).toEqual([{ jobId: "fixture-job", source: "runtime", stop: "requested" }]);
    await rm(lab.path(".remote-coder"), { recursive: true });
    await writeFile(source, JSON.stringify({ ...job, previousJobId: "uncopied-predecessor" }));
    await expect(installSeed(lab, manifest)).rejects.toThrow("Private seed is missing referenced job uncopied-predecessor");
  } finally {
    await lab.removeRoot();
  }
});
