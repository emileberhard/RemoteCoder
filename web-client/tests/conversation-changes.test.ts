import { afterEach, expect, test } from "bun:test";
import {
  decodeChangeRead,
  diffLines,
  gitPath,
  patchPath,
  readConversationChanges,
  reviewComment,
} from "../src/workspace/conversation-changes";
import { applyMarkChange, decodeConversationMarks } from "../src/workspace/conversation-marks";
import { cleanupWorkspaces, setup } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);
const patch =
  'diff --git "a/space\\t\\303\\245.ts" "b/space\\t\\303\\245.ts"\n--- "a/space\\t\\303\\245.ts"\n+++ "b/space\\t\\303\\245.ts"\n@@ -4,2 +4,2 @@\n-old\n+new\n same\n\\ No newline at end of file\n';
const file = { patch, additions: 1, deletions: 1, replacedInvalidUtf8: false };
const ready = {
  status: "ready",
  snapshot: { root: "/repo", files: [file], complete: true, unlistedFiles: 0 },
};

test("patch paths and line anchors preserve Git quoting, UTF-8 and removed line coordinates", () => {
  expect(gitPath('"space\\t\\303\\245.ts"')).toBe("space\tå.ts");
  expect(patchPath(patch)).toBe("space\tå.ts");
  expect(patchPath("diff --git a/old.ts b/new.ts\nrename from old.ts\nrename to new.ts\n")).toBe("new.ts");
  expect(
    patchPath("diff --git a/file with spaces b/file with spaces\nold mode 100644\nnew mode 100755\n"),
  ).toBe("file with spaces");
  const lines = diffLines(patch);
  expect(lines.find((line) => line.kind === "deletion")).toMatchObject({ oldNumber: 4, text: "old" });
  expect(lines.find((line) => line.kind === "addition")).toMatchObject({ newNumber: 4, text: "new" });
  expect(lines.find((line) => line.kind === "context")).toMatchObject({
    oldNumber: 5,
    newNumber: 5,
    text: "same",
  });
  expect(new Set(lines.map((line) => line.offset)).size).toBe(lines.length);
});

test("combined patches retain first-parent and result coordinates without inventing deleted-line positions", () => {
  const lines = diffLines(
    "diff --cc file.ts\n@@@ -1,2 -1,2 +1,3 @@@\n--old\n -other parent\n++new\n  same\n",
  );
  expect(lines[2]).toMatchObject({ kind: "deletion", oldNumber: 1, text: "old" });
  expect(lines[3]?.oldNumber).toBeUndefined();
  expect(lines[4]).toMatchObject({ kind: "addition", newNumber: 1, text: "new" });
  expect(lines[5]).toMatchObject({ kind: "context", oldNumber: 2, newNumber: 2 });
});

test("change reads retain incomplete coverage and quote review comments against the captured checkout and comparison", () => {
  const read = decodeChangeRead(ready, "Branch");
  if (read.status !== "ready" || !read.files[0]) throw new Error("Missing parsed patch");
  const line = diffLines(patch).find((line) => line.kind === "deletion");
  if (!line) throw new Error("Missing removed line");
  expect(reviewComment(read.files[0], line, "Last Turn (turn-7)", " Keep this check ")).toBe(
    "Review comments on Last Turn (turn-7) in /repo:\n\nspace\tå.ts:4 (removed line)\n> - old\nKeep this check",
  );
  expect(decodeChangeRead({ status: "noRecentEdits", complete: false }, "Last Turn")).toMatchObject({
    status: "ready",
    complete: false,
    files: [],
  });
  expect(() =>
    decodeChangeRead({ ...ready, snapshot: { ...ready.snapshot, complete: undefined } }, "Branch"),
  ).toThrow("coverage");
  expect(() =>
    decodeChangeRead({ ...ready, snapshot: { ...ready.snapshot, root: undefined } }, "Branch"),
  ).toThrow();
});

test("the browser uses native change endpoints and falls back only when the branch comparison has no base", async () => {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const reader = {
    request: async (method: string, params: Record<string, unknown>) => {
      calls.push({ method, params });
      return params.source === "branch" ? { status: "unavailable", reason: "noMergeBase" } : ready;
    },
  };
  const signal = new AbortController().signal;
  expect(await readConversationChanges(reader, "exact-thread", "/repo", undefined, signal)).toMatchObject({
    status: "ready",
    label: "Uncommitted",
  });
  expect(calls.map((call) => call.params.source)).toEqual(["branch", "uncommitted"]);
  calls.length = 0;
  await readConversationChanges(
    reader,
    "exact-thread",
    "/repo",
    { kind: "since", turnId: "turn-7", boundary: "end" },
    signal,
  );
  expect(calls).toEqual([
    {
      method: "changes/turn",
      params: { threadId: "exact-thread", since: { turnId: "turn-7", boundary: "end" } },
    },
  ]);
});

test("native changes views survive marks projection without changing unread or pin state", () => {
  let marks = decodeConversationMarks({
    schemaVersion: 4,
    revision: 7,
    readBaseline: 0,
    threads: {
      t: {
        revision: 7,
        markedUnread: true,
        pinName: "Work",
        changesView: { kind: "since", turnId: "old", boundary: "end" },
      },
    },
  });
  expect(marks.threads.t?.changesView).toMatchObject({ turnId: "old" });
  marks = applyMarkChange(marks, { op: "setChangesView", threadId: "t", view: { kind: "lastTurn" } });
  expect(marks.threads.t).toMatchObject({
    markedUnread: true,
    pinName: "Work",
    changesView: { kind: "lastTurn" },
  });
  marks = applyMarkChange(marks, { op: "setChangesView", threadId: "t", view: null });
  expect(marks.threads.t?.changesView).toBeUndefined();
});

test("adding review comments preserves the exact conversation draft and refuses a changed destination", async () => {
  const { workspace } = await setup();
  const address = { hostId: "mini", threadId: "shared" };
  await workspace.selectConversation(address);
  workspace.updateDraft({ text: "My existing draft" });
  workspace.appendReviewComment(address, "Review this line");
  expect(workspace.draft.text).toBe("My existing draft\n\nReview this line");
  await workspace.selectConversation({ hostId: "mini", threadId: "other" });
  expect(() => workspace.appendReviewComment(address, "Wrong destination")).toThrow("reviewed conversation");
  expect(workspace.draft.text).not.toContain("Wrong destination");
});
