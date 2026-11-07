import { expect, test } from "bun:test";
import fixture from "../../protocol-fixtures/attachments/pasted-text-v2-cases.json";
import { visualReplyText } from "../src/workspace/visual-replies";

test("visual replies display as their text and malformed envelopes stay visible", () => {
  const cases = fixture.filter((value) => value.prompt.includes("<remotecoder_visual_reply_v1"));
  expect(cases.length).toBeGreaterThan(0);
  for (const value of cases) expect(visualReplyText(value.prompt)).toBe(value.expanded);
});
