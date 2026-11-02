import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const [binary] = process.argv.slice(2);
assert(binary && isAbsolute(binary), "Pass the built gateway executable as an absolute path");
const lab = await IsolatedGateway.create(binary);

function git(cwd, ...args) {
    const result = Bun.spawnSync(["git", "-C", cwd, ...args], {
        env: { ...lab.safeEnv, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
    });
    assert.equal(result.exitCode, 0, `git ${args.join(" ")}: ${result.stderr}`);
}

let failure;
try {
    const repository = lab.path("repository");
    await mkdir(join(repository, "src"), { recursive: true });
    git(repository, "init", "-q", "-b", "main");
    git(repository, "config", "user.email", "probe@example.invalid");
    git(repository, "config", "user.name", "Probe");
    await writeFile(join(repository, "src/app.swift"), "let a = 1\nlet b = 2\n");
    await writeFile(join(repository, "staged.txt"), "before\n");
    git(repository, "add", "-A");
    git(repository, "commit", "-q", "-m", "initial");
    await writeFile(join(repository, "src/app.swift"), "let a = 1\nlet b = 3\n");
    await writeFile(join(repository, "staged.txt"), "after\n");
    git(repository, "add", "staged.txt");
    await writeFile(join(repository, "new file.md"), "# New\n");
    const index = await readFile(join(repository, ".git/index"));

    await mkdir(lab.path(".claude"), { recursive: true });
    await lab.writeGatewayEnv(["RC_CLAUDE_ENABLED=false", `RC_CLAUDE_HOME=${lab.path(".claude")}`]);
    await lab.start();
    const { rpc: call } = await lab.connect();

    const headers = reply => reply.result.snapshot.files.map(file => file.patch.split("\n")[0]);
    const uncommitted = await call("changes/read", { directory: join(repository, "src"), source: "uncommitted" });
    assert.equal(uncommitted.result.status, "ready", JSON.stringify(uncommitted));
    assert.equal(uncommitted.result.snapshot.root, repository);
    assert.equal(uncommitted.result.snapshot.branch, "main");
    assert.deepEqual(headers(uncommitted), [
        "diff --git a/new file.md b/new file.md",
        "diff --git a/src/app.swift b/src/app.swift",
        "diff --git a/staged.txt b/staged.txt",
    ]);
    const staged = await call("changes/read", { directory: repository, source: "staged" });
    assert.deepEqual(headers(staged), ["diff --git a/staged.txt b/staged.txt"]);
    assert.deepEqual((await readFile(join(repository, ".git/index"))).compare(index), 0, "The read changed the index");

    const outside = await call("changes/read", { directory: lab.path(".claude"), source: "uncommitted" });
    assert.deepEqual(outside.result, { status: "unavailable", reason: "notRepository" });
    const relative = await call("changes/read", { directory: "repository", source: "uncommitted" });
    assert.equal(relative.error?.code, -32602);
    console.log(JSON.stringify({ ok: true, files: uncommitted.result.snapshot.files.length }));
} catch (error) {
    failure = error;
} finally {
    try {
        await lab.stop();
    } catch (error) {
        failure ??= error;
    }
}
if (failure) throw failure;
