import { expect, test } from "bun:test";
import { providerForThread } from "../src/protocol/agent-provider";
import { codexDesktopLink } from "../src/protocol/boundary";
import { conversationActivity } from "../src/workspace/conversation-activity";
import { conversationHeader } from "../src/workspace/conversation-header";
import { header } from "./fixtures/workspace";

test("native activity requires external coverage, rolls delegated work up and retains waiting time", () => {
  const threads = ["root", "waiting", "idle", "claude_unknown"].map((id) =>
    conversationHeader(header(id), providerForThread(id)),
  );
  const activity = conversationActivity(
    {
      coverage: { codex: true, claude: true },
      activeTurns: [],
      externalActivity: {
        codexAvailable: true,
        claudeAvailable: false,
        sessions: [
          { threadId: "child", state: "waiting" },
          { threadId: "waiting", state: "waiting", waitingSince: 1700000000 },
        ],
      },
      agentOwners: { child: "root" },
    },
    threads,
  );
  expect([...activity.states]).toEqual([
    ["root", "working"],
    ["waiting", "waiting"],
    ["idle", "idle"],
    ["claude_unknown", "unknown"],
  ]);
  expect(activity.waitingSince.get("waiting")).toBe(1700000000);
  expect(codexDesktopLink({ hostId: "mini", threadId: "root" })).toBe("codex://threads/root");
  expect(codexDesktopLink({ hostId: "mini", threadId: "claude_unknown" })).toBeUndefined();
});
