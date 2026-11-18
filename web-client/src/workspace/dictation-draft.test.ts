import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, MemoryStorage, setup } from "../../tests/fixtures/workspace";
import { ComposerDraftStore } from "./composer-draft-store";

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

test("the per-draft limit refuses dictation and ordinary saves without replacing durable drafts", () => {
  const storage = new MemoryStorage();
  const errors: unknown[] = [];
  const createStore = () =>
    new ComposerDraftStore(
      storage,
      () => ({ key: "draft", host: undefined }),
      () => new Set(),
      () => undefined,
      (error) => errors.push(error),
    );
  const drafts = createStore();
  drafts.update({ text: "a".repeat(256_000) });
  drafts.flushRequired();
  const saved = storage.getItem("remotecoder.web.drafts.v1");
  expect(() => drafts.applyDictation("draft", "b")).toThrow("storage limits");
  expect(drafts.get("draft")?.text).toBe("a".repeat(256_000));
  expect(storage.getItem("remotecoder.web.drafts.v1")).toBe(saved);
  drafts.update({ text: "c".repeat(256_001) });
  drafts.flush();
  expect(errors).toHaveLength(1);
  expect(String(errors[0])).toContain("storage limits");
  expect(storage.getItem("remotecoder.web.drafts.v1")).toBe(saved);
  const restored = createStore();
  restored.restore();
  expect(restored.get("draft")?.text).toBe("a".repeat(256_000));
  restored.update({ text: "under the limit" });
  restored.flushRequired();
  const after = createStore();
  after.restore();
  expect(after.get("draft")?.text).toBe("under the limit");
});
