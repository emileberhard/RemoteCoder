import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const project = resolve(import.meta.dir, "..");
const compatibility = await Bun.file(join(project, "../docs/codex/compatibility.json")).json();
const binary =
  process.env.CODEX_BIN ?? join(process.env.HOME ?? "", ".codex/packages/standalone/current/codex");
const version = (await new Response(Bun.spawn([binary, "--version"]).stdout).text()).trim();
if (version !== `codex-cli ${compatibility.codexCliVersion}`)
  throw new Error("CODEX_BIN must match docs/codex/compatibility.json");
const temporary = await mkdtemp(join(tmpdir(), "remotecoder-web-protocol-"));
const destination = join(project, "src/protocol/generated");
try {
  const generation = Bun.spawn([binary, "app-server", "generate-ts", "--experimental", "--out", temporary], {
    stdout: "ignore",
    stderr: "inherit",
  });
  if (await generation.exited) throw new Error("Protocol generation failed");
  await rm(destination, { recursive: true, force: true });
  const pending = [
    "v2/Thread.ts",
    "v2/ThreadItem.ts",
    "v2/ThreadItemEntry.ts",
    "v2/Model.ts",
    "v2/UserInput.ts",
    "v2/QueuedSubmission.ts",
    "v2/ThreadTokenUsage.ts",
    "v2/TurnStartParams.ts",
    "v2/ThreadStartParams.ts",
    "v2/ThreadItemsListResponse.ts",
    "v2/ThreadTurnsListResponse.ts",
    "v2/ThreadSubscribeParams.ts",
    "v2/ThreadSubscribeResponse.ts",
    "v2/CommandExecResponse.ts",
  ];
  const seen = new Set<string>();
  while (pending.length) {
    const file = pending.pop();
    if (!file || seen.has(file)) continue;
    seen.add(file);
    const source = await readFile(join(temporary, file), "utf8");
    for (const match of source.matchAll(/from "([^"]+)"/g)) {
      const dependency = join(dirname(file), `${match[1]}.ts`);
      if (!dependency.startsWith("..")) pending.push(dependency);
    }
    await mkdir(dirname(join(destination, file)), { recursive: true });
    await writeFile(
      join(destination, file),
      source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\/\/.*\n/gm, ""),
    );
  }
  await writeFile(
    join(project, "src/protocol/provenance.json"),
    `${JSON.stringify({ codexCliVersion: compatibility.codexCliVersion, codexForkCommit: compatibility.codexForkCommit, experimental: true, files: seen.size }, null, 2)}\n`,
  );
} finally {
  await rm(temporary, { recursive: true, force: true });
}
