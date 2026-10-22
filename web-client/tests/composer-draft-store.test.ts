import { expect, spyOn, test } from "bun:test";
import { blank, ComposerDraftStore } from "../src/workspace/composer-draft-store";
import { MemoryStorage } from "./fixtures/workspace";

test("browser edits persist their time while delivery metadata and historical restores preserve unknown time", () => {
  const storage = new MemoryStorage();
  storage.setItem(
    "remotecoder.web.drafts.v1",
    JSON.stringify([
      ["historical", { ...blank(), text: "older draft" }],
      ["invalid", { ...blank(), text: "bad time", modifiedAt: "yesterday" }],
      ["known", { ...blank(), text: "known draft", modifiedAt: 1000 }],
    ]),
  );
  const store = new ComposerDraftStore(
    storage,
    () => ({ key: "historical", host: undefined }),
    () => new Set(),
    () => undefined,
    () => undefined,
  );
  const clock = spyOn(Date, "now").mockReturnValue(2000);
  try {
    store.restore();
    expect(store.get("historical")?.modifiedAt).toBeUndefined();
    expect(store.get("invalid")?.modifiedAt).toBeUndefined();
    expect(store.get("known")?.modifiedAt).toBe(1000);
    store.update({ model: "default-model" });
    expect(store.get("historical")?.modifiedAt).toBeUndefined();
    store.update({ uncertain: "receipt" });
    expect(store.get("historical")?.modifiedAt).toBeUndefined();
    store.update({ text: "edited draft" });
    expect(store.get("historical")?.modifiedAt).toBe(2000);
    clock.mockReturnValue(3000);
    store.update({ model: "selected-model" });
    expect(store.get("historical")?.modifiedAt).toBe(2000);
    store.update({ uncertain: undefined });
    expect(store.get("historical")?.modifiedAt).toBe(2000);
    store.flush();
    const restored = new ComposerDraftStore(
      storage,
      () => ({ key: "historical", host: undefined }),
      () => new Set(),
      () => undefined,
      () => undefined,
    );
    restored.restore();
    expect(restored.get("historical")?.modifiedAt).toBe(2000);
    restored.flush();
  } finally {
    store.flush();
    clock.mockRestore();
  }
});
