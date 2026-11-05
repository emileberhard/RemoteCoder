import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, MemoryStorage, setup } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("preparing to reload requires saved drafts and preserves memory after a storage failure", async () => {
  class Storage extends MemoryStorage {
    unavailable = true;
    override setItem(key: string, value: string) {
      if (this.unavailable && key === "remotecoder.web.drafts.v1") throw new Error("Quota exceeded");
      super.setItem(key, value);
    }
  }
  const storage = new Storage();
  const { workspace } = await setup(["mini"], storage);
  workspace.updateDraft({ text: "Keep this unsent message" });
  expect(() => workspace.prepareForReload()).toThrow("Keep this tab open");
  expect(workspace.draft.text).toBe("Keep this unsent message");
  expect(storage.getItem("remotecoder.web.drafts.v1")).toBeNull();
  storage.unavailable = false;
  workspace.prepareForReload();
  expect(storage.getItem("remotecoder.web.drafts.v1")).toContain("Keep this unsent message");
});
