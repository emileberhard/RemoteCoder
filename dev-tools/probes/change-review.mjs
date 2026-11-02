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
    const other = lab.path("other");
    await mkdir(other);
    git(other, "init", "-q", "-b", "main");

    const session = crypto.randomUUID();
    const app = join(repository, "src/app.swift");
    const todo = lab.path("notes/todo.md");
    await mkdir(lab.path("notes"));
    await writeFile(app, "let a = 1\nlet b = 4\n");
    await writeFile(todo, "# Todo\n");
    const at = second => new Date(Date.now() - 60000 + second * 1000).toISOString();
    const record = (type, uuid, second, message, extra = {}) =>
        JSON.stringify({ type, uuid, cwd: lab.root, isSidechain: false, sessionId: session, timestamp: at(second), message, ...extra });
    const tool = (uuid, second, id, name, input) =>
        record("assistant", uuid, second, { id: `m-${uuid}`, role: "assistant", content: [{ type: "tool_use", id, name, input }] });
    const result = (uuid, second, id, toolUseResult) =>
        record("user", uuid, second, { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: "ok", is_error: false }] },
            { toolUseResult });
    const project = lab.path(`.claude/projects/${lab.root.replace(/[^A-Za-z0-9]/g, "-")}`);
    await mkdir(project, { recursive: true });
    await writeFile(join(project, `${session}.jsonl`), [
        record("user", "u1", 0, { role: "user", content: "Bump b and start a todo list." }),
        tool("a1", 1, "toolu_edit", "Edit", { file_path: app, old_string: "let b = 3", new_string: "let b = 4" }),
        result("r1", 2, "toolu_edit", { filePath: app, oldString: "let b = 3", newString: "let b = 4", originalFile: "let a = 1\nlet b = 3\n",
            structuredPatch: [{ oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [" let a = 1", "-let b = 3", "+let b = 4"] }],
            userModified: false, replaceAll: false }),
        tool("a2", 3, "toolu_write", "Write", { file_path: todo, content: "# Todo\n" }),
        result("r2", 4, "toolu_write", { type: "create", filePath: todo, content: "# Todo\n", structuredPatch: [], originalFile: null }),
        tool("a3", 5, "toolu_bash", "Bash", { command: "ls" }),
        result("r3", 6, "toolu_bash", { stdout: "notes", stderr: "", interrupted: false }),
        record("assistant", "a4", 7, { id: "m-a4", role: "assistant", content: [{ type: "text", text: "Done." }] }),
    ].join("\n") + "\n");

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

    const thread = `claude_${session}`;
    const turn = await call("changes/turn", { threadId: thread });
    assert.equal(turn.result?.status, "ready", JSON.stringify(turn));
    assert.deepEqual([turn.result.turn.latest, turn.result.turn.running], [true, false]);
    assert.deepEqual(turn.result.files.map(file => [file.root, file.patch]), [
        [repository, "diff --git a/src/app.swift b/src/app.swift\n--- a/src/app.swift\n+++ b/src/app.swift\n@@ -1,2 +1,2 @@\n let a = 1\n-let b = 3\n+let b = 4\n"],
        [lab.path("notes"), "diff --git a/todo.md b/todo.md\nnew file mode 100644\n--- /dev/null\n+++ b/todo.md\n@@ -0,0 +1 @@\n+# Todo\n"],
    ]);
    assert.deepEqual([turn.result.commands, turn.result.omittedAgents, turn.result.complete], [1, 0, true]);
    const checkouts = await call("changes/checkouts", { threadId: thread, directory: lab.root });
    assert.deepEqual(checkouts.result, {
        workedIn: [{ root: repository, evidence: ["edited"] }], inFolder: [other], complete: true,
    }, JSON.stringify(checkouts));
    assert.deepEqual((await readFile(join(repository, ".git/index"))).compare(index), 0, "A conversation read changed the index");
    console.log(JSON.stringify({ ok: true, files: uncommitted.result.snapshot.files.length, turnFiles: turn.result.files.length }));
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
