import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, MemoryStorage, setup } from "../../tests/fixtures/workspace";

afterEach(cleanupWorkspaces);

test("a failed required flush restores the draft so retry inserts dictated text once", async () => {
  class FailOnceStorage extends MemoryStorage {
    failures = 0;
    override setItem(key: string, value: string) {
      if (this.failures > 0 && key === "remotecoder.web.drafts.v1") {
        this.failures -= 1;
        throw new Error("Quota exceeded");
      }
      super.setItem(key, value);
    }
  }
  const storage = new FailOnceStorage();
  const { workspace } = await setup(["mini"], storage);
  const key = workspace.draftKey;
  workspace.updateDraft({ text: "Existing words" }, key);
  storage.failures = 2;
  expect(() => workspace.applyDictation(key, "dictated words")).toThrow("could not save your draft");
  expect(() => workspace.applyDictation(key, "dictated words")).toThrow("could not save your draft");
  expect(workspace.getSnapshot().drafts.get(key)?.text).toBe("Existing words");
  await new Promise((resolve) => setTimeout(resolve, 1100));
  expect(storage.getItem("remotecoder.web.drafts.v1")).toContain("Existing words");
  expect(storage.getItem("remotecoder.web.drafts.v1")).not.toContain("dictated words");
  workspace.applyDictation(key, "dictated words");
  expect(workspace.getSnapshot().drafts.get(key)?.text).toBe("Existing words\ndictated words");
  expect(storage.getItem("remotecoder.web.drafts.v1")).toContain("Existing words\\ndictated words");
});
