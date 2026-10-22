import { expect, test } from "bun:test";
import { conversationAddress, type ExecutionTarget } from "../src/execution-context";
import { addressKey } from "../src/protocol/boundary";
import { neighbor, nextNeedingAttention } from "../src/workspace/conversation-sidebar-navigation";
import type { ConversationSidebarRow } from "../src/workspace/conversation-sidebar-projection";

const mini = { hostId: "mini" };
const address = (threadId: string, target: ExecutionTarget = mini) => conversationAddress(target, threadId);
function row(threadId: string, changes: Partial<ConversationSidebarRow> = {}): ConversationSidebarRow {
  const conversation = address(threadId);
  return {
    id: addressKey(conversation),
    address: conversation,
    hostName: "Mini",
    showsHostLabel: false,
    title: threadId,
    preview: threadId,
    timestamp: 0,
    workingDirectory: "~",
    isPinned: false,
    isAutomation: false,
    isUnread: false,
    isSelected: false,
    isLoading: false,
    activity: "idle",
    questionCount: null,
    settlement: "unsettled",
    isProbablyDone: false,
    needsInput: false,
    canSettle: true,
    ...changes,
  };
}

test("neighbors follow sidebar order and stop at either end", () => {
  const rows = [row("a"), row("b"), row("c")];
  expect(neighbor("next", address("a"), rows)).toEqual(address("b"));
  expect(neighbor("previous", address("b"), rows)).toEqual(address("a"));
  expect(neighbor("previous", address("a"), rows)).toBeUndefined();
  expect(neighbor("next", address("c"), rows)).toBeUndefined();
});

test("a selection outside the list starts at the top or bottom with exact host and account identity", () => {
  const rows = [row("a"), row("b"), row("c")];
  expect(neighbor("next", undefined, rows)).toEqual(address("a"));
  expect(neighbor("previous", undefined, rows)).toEqual(address("c"));
  expect(neighbor("next", address("b", { hostId: "book" }), rows)).toEqual(address("a"));
  expect(
    neighbor(
      "next",
      address("b", {
        hostId: "mini",
        enrollment: { accountId: "11111111-1111-1111-1111-111111111111", generation: 1 },
      }),
      rows,
    ),
  ).toEqual(address("a"));
});

test("attention prefers the next pending question and wraps around before unread completions", () => {
  const rows = [
    row("a", { isUnread: true }),
    row("b"),
    row("c", { questionCount: 1 }),
    row("d", { isUnread: true }),
    row("e", { questionCount: 2 }),
  ];
  expect(nextNeedingAttention(address("b"), rows)).toEqual(address("c"));
  expect(nextNeedingAttention(address("c"), rows)).toEqual(address("e"));
  expect(nextNeedingAttention(address("e"), rows)).toEqual(address("c"));
  expect(nextNeedingAttention(undefined, rows)).toEqual(address("c"));
  expect(nextNeedingAttention(address("other"), rows)).toEqual(address("c"));
});

test("attention falls back to unread completions in circular order", () => {
  const rows = [
    row("a", { isUnread: true }),
    row("b"),
    row("c", { questionCount: 0 }),
    row("d", { isUnread: true }),
  ];
  expect(nextNeedingAttention(address("d"), rows)).toEqual(address("a"));
  expect(nextNeedingAttention(address("a"), rows)).toEqual(address("d"));
});

test("the current conversation is excluded and unknown coverage does not invent attention", () => {
  const rows = [
    row("a", { isUnread: null }),
    row("b", { isUnread: true, questionCount: 1 }),
    row("c", { isUnread: null, questionCount: null }),
  ];
  expect(nextNeedingAttention(address("b"), rows)).toBeUndefined();
  expect(
    nextNeedingAttention(undefined, [row("a", { isUnread: null, questionCount: null })]),
  ).toBeUndefined();
  expect(
    nextNeedingAttention(address("only"), [row("only", { questionCount: 1, isUnread: true })]),
  ).toBeUndefined();
});

test("empty sidebars have no navigation destination", () => {
  expect(neighbor("next", undefined, [])).toBeUndefined();
  expect(neighbor("previous", address("a"), [])).toBeUndefined();
  expect(nextNeedingAttention(undefined, [])).toBeUndefined();
});
