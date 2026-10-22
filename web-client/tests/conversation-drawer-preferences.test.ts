import { expect, test } from "bun:test";
import { ConversationDrawerPreferences } from "../src/workspace/conversation-drawer-preferences";
import { MemoryStorage } from "./fixtures/workspace";

const storageKey = "remotecoder.web.drawer.v1";

test("existing local drawer preferences migrate with Automations expanded and persist its fold per storage", () => {
  const storage = new MemoryStorage();
  storage.setItem(
    storageKey,
    JSON.stringify({
      unreadOnly: true,
      isPinnedFolded: true,
      isSettledFolded: false,
      foldedProjects: ["project"],
    }),
  );
  const restore = (source: Storage) =>
    new ConversationDrawerPreferences(
      source,
      () => "priority",
      () => {},
    );
  const preferences = restore(storage);
  expect(preferences.restoreError).toBeUndefined();
  expect(preferences.snapshot).toMatchObject({
    unreadOnly: true,
    isPinnedFolded: true,
    isSettledFolded: false,
    isAutomationsFolded: false,
  });
  expect(preferences.snapshot.foldedProjects.has("project")).toBe(true);
  preferences.setAutomationsFolded(true);
  preferences.setQuery("temporary");
  expect(restore(storage).snapshot).toMatchObject({ isAutomationsFolded: true, query: "" });
  expect(restore(new MemoryStorage()).snapshot.isAutomationsFolded).toBe(false);
  preferences.setAutomationsFolded(false);
  expect(restore(storage).snapshot.isAutomationsFolded).toBe(false);
});

test("invalid saved automation folds report a restore failure rather than silently accepting it", () => {
  const storage = new MemoryStorage();
  storage.setItem(
    storageKey,
    JSON.stringify({
      unreadOnly: false,
      isPinnedFolded: false,
      isSettledFolded: true,
      isAutomationsFolded: "false",
      foldedProjects: [],
    }),
  );
  const preferences = new ConversationDrawerPreferences(
    storage,
    () => "priority",
    () => {},
  );
  expect(preferences.restoreError).toBe("Invalid drawer preferences");
});
