import { expect, test } from "bun:test";
import { closedCodeFence, IncrementalMarkdown, renderMarkdown } from "../src/markdown";

const examples = [
  "A **settled** paragraph.\n\nAnother paragraph with `inline code`.\n\nLast paragraph.",
  '# Title\n\n- First\n- Second\n  - Nested\n\n```typescript\nconst value = "<script>";\n```\n\nDone.',
  "| Column | Value |\n| --- | --- |\n| One | Two |\n\n> A quote\n> on two lines\n\nAfter.",
  'A [reference][key].\n\nA second paragraph.\n\n[key]: https://example.com "Title"\n',
  "```mermaid\nflowchart LR\nA-->B\n```\n\nAfter.\n\nStill streaming.",
];
for (const example of examples)
  test(`chunk boundaries preserve Markdown: ${example.slice(0, 30)}`, () => {
    for (const size of [1, 3, 17]) {
      const parser = new IncrementalMarkdown();
      let settled: string[] = [];
      for (let offset = 0; offset < example.length; offset += size) {
        parser.append(example.slice(offset, offset + size));
        const update = parser.flush();
        settled = [...settled.slice(0, update.offset), ...update.added];
      }
      const final = parser.finish();
      expect(final.join("")).toBe(renderMarkdown(example));
      if (!example.includes("[key]")) expect(final.slice(0, settled.length)).toEqual(settled);
    }
  });
test("raw HTML and unsafe links cannot execute in transcript markup", () => {
  const html = renderMarkdown(
    '<img src=x onerror="alert(1)">\n\n[bad](javascript:alert%281%29)\n\n[good](https://example.com)\n\n```html\n<script>alert(1)</script>\n```',
  );
  expect(html).not.toContain("<img src=x");
  expect(html).not.toContain('href="javascript:');
  expect(html).toContain("&lt;script&gt;");
  expect(html).toContain('rel="noopener noreferrer"');
});
test("streaming settles old blocks without changing their markup", () => {
  const parser = new IncrementalMarkdown();
  parser.append("One.\n\nTwo.\n\nThree.\n\nFour.");
  const first = parser.flush();
  expect(first.added).toEqual(["<p>One.</p>\n", "<p>Two.</p>\n"]);
  parser.append(" Continued.\n\nFive.");
  const second = parser.flush();
  expect(second.offset).toBe(2);
  expect(second.added).toEqual(["<p>Three.</p>\n"]);
  expect(parser.finish().slice(0, 2)).toEqual(first.added);
});
test("Mermaid fence completion respects indentation, delimiter and length while source stays escaped", () => {
  expect(closedCodeFence("````mermaid\nA-->B\n```\n")).toBe(false);
  expect(closedCodeFence("~~~MERMAID\nA-->B\n```\n")).toBe(false);
  expect(closedCodeFence("  ~~~MERMAID\nA-->B\n  ~~~~  \n")).toBe(true);
  const pending = renderMarkdown("```mermaid\nflowchart LR\nA-->");
  expect(pending).toContain('data-mermaid-complete="false"');
  const complete = renderMarkdown('```mermaid\nflowchart LR\nA["<script>"]-->B\n```');
  expect(complete).toContain('data-mermaid-complete="true"');
  expect(complete).not.toContain("<script>");
  expect(complete).toContain("&lt;script&gt;");
});
test("an rc-visual image on its own line becomes a visual block", () => {
  const digest = "a".repeat(64);
  const visual = `<div class="html-visual" data-visual-digest="${digest}" data-visual-title="Chart"></div>`;
  expect(renderMarkdown(`Here is the chart:\n![Chart](rc-visual:${digest})\nIt rose.`)).toBe(
    `<p>Here is the chart:</p>\n${visual}<p>It rose.</p>\n`,
  );
  expect(renderMarkdown(`\`\`\`\n![Chart](rc-visual:${digest})\n\`\`\``)).not.toContain("data-visual-digest");
  expect(renderMarkdown(`![a\\[b\\]\\\\c](rc-visual:${digest})`)).toBe(
    `<div class="html-visual" data-visual-digest="${digest}" data-visual-title="a[b]\\c"></div>`,
  );
  expect(renderMarkdown(`![Chart <1>](rc-visual:${digest})`)).toBe(
    `<div class="html-visual" data-visual-digest="${digest}" data-visual-title="Chart &lt;1&gt;"></div>`,
  );
  expect(renderMarkdown(`![Chart](rc-visual:${"A".repeat(64)})`)).toContain("html-visual-unavailable");
  expect(renderMarkdown(`See ![Chart](rc-visual:${digest}) here`)).not.toContain("data-visual-digest");
});
