import { test } from "bun:test";
import { join } from "node:path";

test("published frontend retention preserves rollback and rejects a mismatched revision", () => {
  const result = Bun.spawnSync(
    ["python3", "-m", "unittest", "discover", "-s", "tests", "-p", "test_frontend_retention.py"],
    { cwd: join(import.meta.dir, "..") },
  );
  if (result.exitCode !== 0) throw new Error(new TextDecoder().decode(result.stderr));
});
