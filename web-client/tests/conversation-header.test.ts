import { expect, test } from "bun:test";
import {
  type ConversationAgentClassification,
  conversationHeader,
  retainHeaderKnowledge,
} from "../src/workspace/conversation-header";
import { header } from "./fixtures/workspace";

const root: ConversationAgentClassification = { kind: "root" };
const child: ConversationAgentClassification = {
  kind: "child",
  relation: { parentThreadId: "parent", parentAccountId: null, agentId: "child" },
};
const replacement: ConversationAgentClassification = {
  kind: "child",
  relation: { parentThreadId: "new-parent", parentAccountId: "account", agentId: "new-child" },
};

for (const [previous, incoming, expected] of [
  [root, child, child],
  [child, root, root],
  [child, replacement, replacement],
  [child, { kind: "unresolved" }, child],
  [root, { kind: "unresolved" }, root],
] satisfies [
  ConversationAgentClassification,
  ConversationAgentClassification,
  ConversationAgentClassification,
][]) {
  test(`incoming ${incoming.kind} ancestry replaces previous ${previous.kind} only when definitive`, () => {
    const original = { ...conversationHeader(header(), "codex"), agentClassification: previous };
    const refreshed = { ...conversationHeader(header(), "codex"), agentClassification: incoming };
    expect(retainHeaderKnowledge(refreshed, original).agentClassification).toEqual(expected);
  });
}
