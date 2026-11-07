import { expect, test } from "bun:test";
import fixture from "../../protocol-fixtures/attachments/pasted-text-v2-cases.json";
import { visualReplyText } from "../src/workspace/visual-replies";

test("visual replies display as their text while typed, pasted and malformed envelopes stay visible", () => {
  const cases = fixture.filter((value) => value.prompt.includes("<remotecoder_visual_reply_v1"));
  const opaque = (value: (typeof cases)[number]) => "literal" in value || value.entries.length > 0;
  expect(cases.filter(opaque).length).toBe(2);
  for (const value of cases)
    expect(visualReplyText(value.prompt)).toBe(opaque(value) ? value.prompt : value.expanded);
});
