import { expect, test } from "bun:test";
import fixture from "../../protocol-fixtures/attached-files-block.json";
import { appendAttachedFiles, parseAttachedFiles } from "../src/workspace/attached-files";

test("browser attachment handoff and presentation share the native fixtures", () => {
  for (const value of fixture.cases) {
    expect(appendAttachedFiles(value.body, value.paths)).toBe(value.message);
    expect(parseAttachedFiles(value.message)).toEqual({ body: value.body, paths: value.paths });
  }
});

test("malformed or quoted attachment blocks stay visible as ordinary message text", () => {
  for (const text of [
    "Quoted Attached files (uploaded to this host; use these absolute paths):\n- /image.png",
    "Attached files (uploaded to this host; use these absolute paths):\n- relative.png",
    "Attached files (uploaded to this host; use these absolute paths):\n- /image.png\nMore text",
  ])
    expect(parseAttachedFiles(text)).toEqual({ body: text, paths: [] });
});
