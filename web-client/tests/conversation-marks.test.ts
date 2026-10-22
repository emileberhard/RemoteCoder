import { expect, test } from "bun:test";
import {
  applyMarkChange,
  coversRequest,
  decodeConversationMarks,
  isProbablyDone,
  isSettled,
  isUnread,
  isUnseenQuestion,
  mergeMarks,
  normalizedPinName,
} from "../src/workspace/conversation-marks";

const base = () =>
  decodeConversationMarks({
    schemaVersion: 3,
    revision: 4,
    readBaseline: 100,
    threads: {
      t: { revision: 4, seenThrough: 110, pinName: "Pinned", markedUnread: true, doneThrough: 120 },
    },
  });
const thread = { id: "t", latestActivityAt: 120, lastTurnCompletedAt: 115 };

test("explicit unread, completion, purpose and question seen-through retain distinct semantics", () => {
  let marks = base();
  expect(isUnread(marks, thread)).toBe(true);
  marks = applyMarkChange(marks, { op: "markRead", threadId: "t", through: 114 });
  expect(isUnread(marks, thread)).toBe(true);
  expect(isUnseenQuestion(marks, 114999, "t")).toBe(false);
  expect(isUnseenQuestion(marks, 115000, "t")).toBe(true);
  marks = applyMarkChange(marks, { op: "setPurpose", threadId: "t", purpose: "probe" });
  expect(isUnread(marks, thread)).toBe(false);
  marks = applyMarkChange(marks, { op: "markUnread", threadId: "t" });
  expect(isUnread(marks, thread)).toBe(true);
  marks = applyMarkChange(marks, { op: "markAllRead", through: 200 });
  expect(isUnread(marks, thread)).toBe(false);
  expect(marks.threads.t?.seenThrough).toBeUndefined();
});

test("settlement clears pin and unread, preserves done, and reopening clears done", () => {
  const settled = applyMarkChange(base(), { op: "settle", threadId: "t", through: 120 });
  expect(settled.threads.t?.pinName).toBeUndefined();
  expect(isUnread(settled, thread)).toBe(false);
  expect(isSettled(settled, thread, false, 121)).toBe(true);
  expect(isSettled(settled, thread, true, 121)).toBe(false);
  expect(isProbablyDone(settled, thread)).toBe(true);
  const reopened = applyMarkChange(settled, { op: "unsettle", threadId: "t", through: 120 });
  expect(isProbablyDone(reopened, thread)).toBe(false);
  expect(isSettled(reopened, thread, false, 999999)).toBe(false);
  expect(coversRequest(reopened, 100, thread, 999999)).toBe(false);
});

test("three day automatic settlement respects schema, explicit active and unknown activity", () => {
  const marks = decodeConversationMarks({ schemaVersion: 2, revision: 0, readBaseline: 1000, threads: {} });
  expect(isSettled(marks, thread, false, 120 + 259199)).toBe(false);
  expect(isSettled(marks, thread, false, 120 + 259200)).toBe(true);
  expect(isSettled({ ...marks, schemaVersion: 1 }, thread, false, 999999)).toBe(false);
  expect(isSettled(marks, { ...thread, latestActivityAt: null }, false, 999999)).toBe(false);
  expect(coversRequest(marks, null, thread, 999999)).toBe(false);
  expect(coversRequest(marks, 120, thread, 999999)).toBe(true);
});

test("deltas merge newest per thread and retain the greatest baseline", () => {
  const merged = mergeMarks(
    base(),
    decodeConversationMarks({
      schemaVersion: 2,
      revision: 8,
      readBaseline: 150,
      threads: { t: { revision: 3, pinName: "Old" }, other: { revision: 8, markedUnread: true } },
    }),
  );
  expect(merged.threads.t?.pinName).toBe("Pinned");
  expect(merged.threads.t?.seenThrough).toBeUndefined();
  expect(merged.threads.other?.markedUnread).toBe(true);
  expect(mergeMarks(merged, base()).readBaseline).toBe(150);
  expect(() =>
    decodeConversationMarks({ revision: 1, readBaseline: 0, threads: { t: { revision: 2 } } }),
  ).toThrow();
  expect(normalizedPinName(` ${"🧑‍💻".repeat(40)} `)?.length).toBeLessThan(200);
});
