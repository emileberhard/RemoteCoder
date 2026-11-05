import { expect, test } from "bun:test";
import { type Item, item } from "../src/protocol/boundary";
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
      : segment.kind === "media"
        ? `images:${segment.row.entry.item.id}`
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

test("native image-view and tool media stay visible between collapsed activity groups", () => {
  const viewed = row("t1", "imageView", "view");
  viewed.entry.item = item({
    type: "imageView",
    id: "view",
    path: "/original.png",
    rcMedia: [{ path: "/retained.png", mimeType: "image/png" }],
  });
  const tool = (type: string, id: string) => {
    const value = row("t1", type, id);
    value.entry.item = item({
      type,
      id,
      server: "computer",
      tool: "screenshot",
      status: "completed",
      rcMedia: [
        { path: `/retained/${id}.png`, mimeType: "image/png", name: "Screen" },
        { path: `/retained/${id}-2.png`, mimeType: "image/png" },
      ],
    });
    return value;
  };
  const rows = [
    row("t1", "commandExecution", "before"),
    viewed,
    tool("mcpToolCall", "mcp"),
    tool("dynamicToolCall", "dynamic"),
    row("t1", "agentMessage", "answer"),
  ];
  expect(shape(rows, false)).toEqual([
    "[before]",
    "images:view",
    "[mcp]",
    "images:mcp",
    "[dynamic]",
    "images:dynamic",
    "answer reply",
  ]);
  const media = timelineSegments(rows, false).filter((segment) => segment.kind === "media");
  expect(media.map((segment) => segment.media.map((media) => media.path))).toEqual([
    ["/retained.png"],
    ["/retained/mcp.png", "/retained/mcp-2.png"],
    ["/retained/dynamic.png", "/retained/dynamic-2.png"],
  ]);
  expect(media[1]?.media.map((media) => media.name)).toEqual(["Screen", "screenshot"]);
  viewed.entry.item = item({ type: "imageView", id: "view", path: "/original.png" });
  expect(timelineSegments([viewed], false)[0]).toMatchObject({
    kind: "media",
    media: [{ path: "/original.png", name: "original.png" }],
  });
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
