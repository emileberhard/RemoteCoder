import { expect, test } from "bun:test";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import nativeDefaults from "../src/protocol/native-model-defaults.json";

test("native model generation derives the browser initial model from NewChatDefaults", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "rc-web-native-defaults-"));
  try {
    const models = join(temporary, "Core/Sources/RemoteCoderCore/Models");
    const scripts = join(temporary, "web-client/scripts");
    const protocol = join(temporary, "web-client/src/protocol");
    await Promise.all([models, scripts, protocol].map((path) => mkdir(path, { recursive: true })));
    await copyFile(
      join(import.meta.dir, "../scripts/generate-native-models.ts"),
      join(scripts, "generate-native-models.ts"),
    );
    await copyFile(
      join(import.meta.dir, "../../Core/Sources/RemoteCoderCore/Models/ModelOptions.swift"),
      join(models, "ModelOptions.swift"),
    );
    const source = await readFile(
      join(import.meta.dir, "../../Core/Sources/RemoteCoderCore/Models/NewChatDefaults.swift"),
      "utf8",
    );
    const generate = async (source: string) => {
      await writeFile(join(models, "NewChatDefaults.swift"), source);
      const generation = Bun.spawn([process.execPath, join(scripts, "generate-native-models.ts")], {
        stdout: "ignore",
        stderr: "pipe",
      });
      const error = await new Response(generation.stderr).text();
      expect(await generation.exited, error).toBe(0);
      return JSON.parse(await readFile(join(protocol, "native-model-defaults.json"), "utf8"));
    };
    expect(await generate(source)).toEqual(nativeDefaults);
    expect(
      await generate(
        source.replace(/(static let initialCodexModelID = )"[^"]+"/, '$1"native-fixture-model"'),
      ),
    ).toEqual({ initialCodexModelID: "native-fixture-model" });
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
