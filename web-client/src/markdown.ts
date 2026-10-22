import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import diff from "highlight.js/lib/languages/diff";
import json from "highlight.js/lib/languages/json";
import python from "highlight.js/lib/languages/python";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import { Marked, Renderer, type TokensList } from "marked";

for (const [name, grammar] of Object.entries({ typescript, swift, python, bash, json, diff }))
  hljs.registerLanguage(name, grammar);
export const escapeHtml = (text: string) =>
  text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
export function safeLink(value: string): string | undefined {
  if (value.startsWith("/") && !value.startsWith("//")) return value;
  try {
    const url = new URL(value);
    return ["https:", "http:", "mailto:"].includes(url.protocol) ? url.href : undefined;
  } catch {
    return undefined;
  }
}
const renderer = new Renderer();
renderer.html = ({ text }) => escapeHtml(text);
renderer.link = function ({ href, tokens }) {
  const label = this.parser.parseInline(tokens);
  const safe = safeLink(href);
  if (!safe) return label;
  if (safe.startsWith("/")) return `<a href="#" data-host-path="${escapeHtml(safe)}">${label}</a>`;
  return `<a href="${escapeHtml(safe)}" target="_blank" rel="noopener noreferrer">${label}</a>`;
};
renderer.image = ({ href, text }) => {
  if (/^data:image\/(png|jpeg|gif|webp);base64,[a-zA-Z0-9+/=]+$/.test(href))
    return `<img src="${escapeHtml(href)}" alt="${escapeHtml(text)}" loading="lazy">`;
  return `<span class="markdown-image">${escapeHtml(text || "Image")}</span>`;
};
export function closedCodeFence(raw: string): boolean {
  const lines = raw.split("\n");
  const opening = /^ {0,3}(`{3,}|~{3,})/.exec(lines[0] ?? "");
  const fence = opening?.[1];
  if (!fence) return false;
  const closing = new RegExp(`^ {0,3}${fence[0]}{${fence.length},}[ \\t]*\\r?$`);
  return lines.slice(1).some((line) => closing.test(line));
}
renderer.code = ({ text, lang, raw }) => {
  const requested = lang?.split(/\s/)[0]?.toLowerCase() ?? "";
  if (requested === "mermaid")
    return `<div class="code-block mermaid-diagram" data-mermaid-source="${escapeHtml(text)}" data-mermaid-complete="${closedCodeFence(raw)}"><div class="code-toolbar"><span>Diagram</span><button type="button" data-copy-code="true">Copy source</button><button type="button" data-retry-diagram="true" hidden>Try again</button></div><div class="diagram-preview"></div><p class="diagram-status" role="status"></p><details class="diagram-source" open><summary>View source</summary><pre><code>${escapeHtml(text)}</code></pre></details></div>`;
  const language =
    (
      {
        ts: "typescript",
        tsx: "typescript",
        js: "typescript",
        javascript: "typescript",
        sh: "bash",
        shell: "bash",
        py: "python",
      } as Record<string, string>
    )[requested] ?? requested;
  const content = hljs.getLanguage(language) ? hljs.highlight(text, { language }).value : escapeHtml(text);
  return `<div class="code-block"><div class="code-toolbar"><span>${escapeHtml(requested || "Code")}</span><button type="button" data-copy-code="true">Copy</button></div><pre><code>${content}</code></pre></div>`;
};
const parser = new Marked({ renderer, gfm: true, breaks: false });
const visualLine = /^ {0,3}!\[((?:\\.|[^\\\]\n])*)\]\((rc-visual:[^\s)]*)\)[ \t]*(?:\n+|$)/;
parser.use({
  extensions: [
    {
      name: "htmlVisual",
      level: "block",
      start(source) {
        const match = /(?:^|\n) {0,3}!\[(?:\\.|[^\\\]\n])*\]\(rc-visual:/.exec(source);
        return match ? match.index + (match[0].startsWith("\n") ? 1 : 0) : undefined;
      },
      tokenizer(source) {
        const match = visualLine.exec(source);
        return match
          ? {
              type: "htmlVisual",
              raw: match[0],
              title: (match[1] ?? "").replace(/\\([!-/:-@[-`{-~])/g, "$1"),
              href: match[2] ?? "",
            }
          : undefined;
      },
      renderer({ title, href }) {
        const digest = /^rc-visual:([0-9a-f]{64})$/.exec(href)?.[1];
        return digest
          ? `<div class="html-visual" data-visual-digest="${digest}" data-visual-title="${escapeHtml(title)}"></div>`
          : `<p class="html-visual-unavailable">${escapeHtml(title || "Visual")} is unavailable.</p>`;
      },
    },
  ],
});
export function renderMarkdown(text: string): string {
  return parser.parse(text, { async: false });
}
export class IncrementalMarkdown {
  private source = "";
  private tail = "";
  private settled = 0;
  append(delta: string) {
    this.source += delta;
    this.tail += delta;
    if (this.source.length > 2 * 1024 * 1024) throw new Error("Message exceeds the 2 MiB rendering limit");
  }
  flush() {
    const tokens = parser.lexer(this.tail);
    const contentIndices = tokens
      .map((token, index) => (token.type === "space" ? -1 : index))
      .filter((index) => index >= 0);
    const boundary = contentIndices.length > 2 ? (contentIndices[contentIndices.length - 2] ?? 0) : 0;
    const newlySettled = tokens.slice(0, boundary);
    const consumed = newlySettled.reduce((length, token) => length + token.raw.length, 0);
    this.tail = this.tail.slice(consumed);
    const added = newlySettled
      .filter((token) => token.type !== "space")
      .map((token) => renderMarkdown(token.raw));
    const offset = this.settled;
    this.settled += added.length;
    const trailing = tokens
      .slice(boundary)
      .filter((token) => token.type !== "space")
      .map((token) => renderMarkdown(token.raw));
    return { offset, added, tail: trailing };
  }
  finish() {
    const tokens = parser.lexer(this.source);
    return tokens
      .filter((token) => token.type !== "space")
      .map((token) => {
        const block = [token] as TokensList;
        block.links = tokens.links;
        return parser.parser(block);
      });
  }
}
