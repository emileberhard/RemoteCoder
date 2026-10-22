import { type Address, addressKey } from "../protocol/boundary";
import type { ConversationSidebarRow } from "./conversation-sidebar-projection";

function currentIndex(current: Address | undefined, rows: readonly ConversationSidebarRow[]): number {
  if (!current) return -1;
  const key = addressKey(current);
  return rows.findIndex((row) => addressKey(row.address) === key);
}
export function neighbor(
  direction: "previous" | "next",
  current: Address | undefined,
  rows: readonly ConversationSidebarRow[],
): Address | undefined {
  const index = currentIndex(current, rows);
  if (index === -1) return rows[direction === "next" ? 0 : rows.length - 1]?.address;
  return rows[index + (direction === "next" ? 1 : -1)]?.address;
}
export function nextNeedingAttention(
  after: Address | undefined,
  rows: readonly ConversationSidebarRow[],
): Address | undefined {
  const index = currentIndex(after, rows);
  const candidates = index === -1 ? rows : [...rows.slice(index + 1), ...rows.slice(0, index)];
  return (
    candidates.find((row) => (row.questionCount ?? 0) > 0)?.address ??
    candidates.find((row) => row.isUnread === true)?.address
  );
}
