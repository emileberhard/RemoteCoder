import { expect, test } from "bun:test";
import type { Item } from "../src/protocol/boundary";
import { timelineSegments } from "../src/ui/chat/transcript/timeline-segments";
import type { Row } from "../src/workspace/conversation-session";

const row = (turnId: string, type: string, id: string, steer = false): Row => ({
  steer,
  bytes: 0,
  revision: 0,
  ...(steer ? { delivery: "admitted" as const } : {}),
  entry: {
    turnId,
    item: { type, id, text: id, content: [] } as unknown as Item,
    startedAtMs: 0,
    completedAtMs: 0,
    isComplete: true,
  },
});
const shape = (rows: Row[], active: boolean) =>
  timelineSegments(rows, active).map((segment) =>
    segment.kind === "row"
      ? `${segment.row.entry.item.id}${segment.reply ? " reply" : ""}`
      : `[${segment.rows.map((entry) => entry.entry.item.id).join(",")}${segment.live ? " live" : ""}]`,
  );

test("a pending steer stays at its live turn's tail past later commentary", () => {
  const rows = [
    row("t1", "userMessage", "prompt"),
    row("t1", "commandExecution", "tool1"),
    row("t1", "userMessage", "steer", true),
    row("t1", "agentMessage", "commentary"),
    row("t1", "commandExecution", "tool2"),
  ];
  expect(shape(rows, true)).toEqual(["prompt", "[tool1]", "commentary", "[tool2 live]", "steer"]);
});

test("an unconfirmed steer closes its own turn, before the next turn", () => {
  const rows = [
    row("t1", "userMessage", "prompt"),
    row("t1", "commandExecution", "tool1"),
    row("t1", "userMessage", "steer", true),
    row("t1", "agentMessage", "answer"),
    row("t2", "userMessage", "next"),
    row("t2", "commandExecution", "tool2"),
  ];
  expect(shape(rows, false)).toEqual(["prompt", "[tool1]", "answer reply", "steer", "next", "[tool2]"]);
});
