import { expect, test } from "bun:test";
import { type CommandPaletteCandidate, commandPaletteResults } from "../src/workspace/command-palette-search";

const candidate = (title: string, detail = "", id = title): CommandPaletteCandidate<string> => ({
  id,
  title,
  detail,
});

test("empty queries and equal scores retain candidate order within the limit", () => {
  const candidates = [candidate("Chat 3"), candidate("Chat 1"), candidate("Chat 2")];
  expect(commandPaletteResults("  ", candidates, 2)).toEqual(["Chat 3", "Chat 1"]);
  expect(commandPaletteResults("chat", candidates, 2)).toEqual(["Chat 3", "Chat 1"]);
  expect(commandPaletteResults("chat", candidates, 0)).toEqual([]);
});

test("title prefix outranks word start, substring, detail occurrence, and scattered letters", () => {
  const candidates = [
    candidate("A rerun job"),
    candidate("Stop"),
    candidate("Ruin now"),
    candidate("Dry run"),
    candidate("Run tests"),
    candidate("Launch", "Run command"),
  ];
  expect(commandPaletteResults("run", candidates, 10)).toEqual([
    "Run tests",
    "Dry run",
    "A rerun job",
    "Launch",
    "Ruin now",
  ]);
});

test("each token must match a title or detail and detail never matches a subsequence", () => {
  const candidates = [
    candidate("Fix build", "~/app · Mini", "mini build"),
    candidate("Fix build", "~/app · MacBook", "book build"),
    candidate("Fix docs", "~/site · Mini", "mini docs"),
  ];
  expect(commandPaletteResults("fix mini", candidates, 10)).toEqual(["mini build", "mini docs"]);
  expect(commandPaletteResults("build mini", candidates, 10)).toEqual(["mini build"]);
  expect(commandPaletteResults("fx mn", candidates, 10)).toEqual([]);
});

test("folding ignores case and diacritics while respecting distinct letters", () => {
  const candidates = [
    candidate("Café menu"),
    candidate("Straße"),
    candidate("ẞ"),
    candidate("ΟΣ"),
    candidate("ﬃ tool"),
    candidate("ı marker"),
  ];
  expect(commandPaletteResults("CAFE", candidates, 10)).toEqual(["Café menu"]);
  expect(commandPaletteResults("cafés", candidates, 10)).toEqual([]);
  expect(commandPaletteResults("STRASSE", candidates, 10)).toEqual(["Straße"]);
  expect(commandPaletteResults("οσ", candidates, 10)).toEqual(["ΟΣ"]);
  expect(commandPaletteResults("σ", candidates, 10)).toEqual(["ΟΣ"]);
  expect(commandPaletteResults("ss", candidates, 10)).toEqual(["ẞ", "Straße"]);
  expect(commandPaletteResults("ffi", candidates, 10)).toEqual(["ﬃ tool"]);
  expect(commandPaletteResults("I marker", candidates, 10)).toEqual([]);
});

test("subsequence ordering and spread determine the score", () => {
  const candidates = [
    candidate("RemoteCoder"),
    candidate("Credentials"),
    candidate("R some M some C"),
    candidate("RMC tools"),
  ];
  expect(commandPaletteResults("rmc", candidates, 10)).toEqual([
    "RMC tools",
    "RemoteCoder",
    "R some M some C",
  ]);
});

test("title and detail search are independently bounded to 256 folded graphemes", () => {
  const candidates = [
    candidate(`${"x".repeat(256)}needle`, "", "past title"),
    candidate(`${"x".repeat(250)}needle`, "", "at title boundary"),
    candidate("Other", `${"y".repeat(256)}needle`, "past detail"),
    candidate("Other", `${"y".repeat(250)}needle`, "at detail boundary"),
    candidate(`${"👨‍👩‍👧‍👦".repeat(255)}z`, "", "grapheme boundary"),
  ];
  expect(commandPaletteResults("needle", candidates, 10)).toEqual([
    "at title boundary",
    "at detail boundary",
  ]);
  expect(commandPaletteResults("z", candidates, 10)).toEqual(["grapheme boundary"]);
  expect(commandPaletteResults("x".repeat(257), candidates, 10)).toEqual([]);
});

test("folding preserves vowel marks and emoji presentation while Unicode whitespace separates tokens", () => {
  const candidates = [
    candidate("कि"),
    candidate("क"),
    candidate("☀️"),
    candidate("☀"),
    candidate("Fix build", "Mini"),
  ];
  expect(commandPaletteResults("कि", candidates, 10)).toEqual(["कि"]);
  expect(commandPaletteResults("☀️", candidates, 10)).toEqual(["☀️"]);
  expect(commandPaletteResults("fix\u0085mini", candidates, 10)).toEqual(["Fix build"]);
});

test("query changes reuse each candidate's folded text until the candidate snapshot changes", () => {
  let titleReads = 0;
  let detailReads = 0;
  const candidates = [
    {
      id: "build",
      get title() {
        titleReads++;
        return "Fíx build";
      },
      get detail() {
        detailReads++;
        return "Mini";
      },
    },
  ];
  expect(commandPaletteResults("fix", candidates, 10)).toEqual(["build"]);
  expect(commandPaletteResults("mini build", candidates, 10)).toEqual(["build"]);
  expect(titleReads).toBe(1);
  expect(detailReads).toBe(1);
  expect(commandPaletteResults("release", [candidate("Release", "Mini", "build")], 10)).toEqual(["build"]);
});
