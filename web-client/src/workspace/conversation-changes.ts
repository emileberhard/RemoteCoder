import { array, object, optionalString, string } from "../protocol/boundary";
import type { ChangesView } from "./conversation-marks";

export type ChangeFile = {
  hasLineCounts: boolean;
  root: string;
  patch: string;
  path?: string;
  additions: number;
  deletions: number;
  omitted?: string;
  replacedInvalidUtf8: boolean;
};
export type ChangeRead =
  | {
      status: "ready";
      files: ChangeFile[];
      complete: boolean;
      unlisted: number;
      label: string;
      comparison: string;
    }
  | { status: "unavailable"; reason: string };
export type DiffLine = {
  offset: number;
  text: string;
  kind: "header" | "context" | "addition" | "deletion";
  oldNumber?: number;
  newNumber?: number;
};
type Reader = {
  request(
    method: string,
    params: Record<string, unknown>,
    options: { signal: AbortSignal },
  ): Promise<unknown>;
};
const count = (value: unknown): number => {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
    throw new Error("Invalid change count");
  return value;
};
const flag = (value: unknown): boolean => {
  if (typeof value !== "boolean") throw new Error("Invalid changes coverage");
  return value;
};

export function gitPath(raw: string) {
  if (!raw.startsWith('"') || !raw.endsWith('"')) return raw;
  const encoded = new TextEncoder().encode(raw.slice(1, -1));
  const bytes: number[] = [];
  const escapes: Record<number, number> = { 97: 7, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11 };
  for (let index = 0; index < encoded.length; index++) {
    const byte = encoded[index];
    if (byte === undefined) break;
    if (byte !== 92) {
      bytes.push(byte);
      continue;
    }
    const escaped = encoded[++index];
    if (escaped === undefined) break;
    if (escaped >= 48 && escaped <= 51 && index + 2 < encoded.length) {
      const octal = String.fromCharCode(...encoded.slice(index, index + 3));
      if (/^[0-3][0-7]{2}$/.test(octal)) {
        bytes.push(Number.parseInt(octal, 8));
        index += 2;
        continue;
      }
    }
    bytes.push(escapes[escaped] ?? escaped);
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}
export function patchPath(patch: string): string | undefined {
  let path: string | undefined;
  for (const line of patch.split("\n")) {
    if (line.startsWith("@@")) break;
    const rename = /^(?:rename|copy) to (.*)$/.exec(line);
    const file = /^(?:--- |\+\+\+ )(.*)$/.exec(line);
    if (rename?.[1]) path = gitPath(rename[1]);
    else if (file?.[1] && file[1] !== "/dev/null")
      path = gitPath(file[1].replace(/\t$/, "")).replace(/^[ab]\//, "");
    else if (!path) {
      const combined = /^(?:diff --cc |diff --combined |\* Unmerged path )(.*)$/.exec(line);
      const shared = /^diff --git a\/(.*) b\/\1$/.exec(line);
      const quoted = /^diff --git ("(?:[^"\\]|\\.)*") /.exec(line);
      path = combined?.[1]
        ? gitPath(combined[1])
        : (shared?.[1] ?? (quoted?.[1] ? gitPath(quoted[1]).replace(/^a\//, "") : undefined));
    }
  }
  return path;
}
export function diffLines(patch: string): DiffLine[] {
  let parents = 0;
  let oldNumber = 0;
  let newNumber = 0;
  const result: DiffLine[] = [];
  const lines = patch.split("\n");
  if (lines.at(-1) === "") lines.pop();
  let nextOffset = 0;
  for (const raw of lines) {
    const offset = nextOffset;
    nextOffset += raw.length + 1;
    const text = raw.replace(/\r$/, "");
    const header = /^(@{2,}) ((?:-\d+(?:,\d+)? )+)\+(\d+)(?:,\d+)? \1/.exec(text);
    if (header) {
      parents = (header[1]?.length ?? 1) - 1;
      oldNumber = Number(/\d+/.exec(header[2] ?? "")?.[0]);
      newNumber = Number(header[3]);
      result.push({ offset, text, kind: "header" });
      continue;
    }
    const columns = text.slice(0, parents);
    if (!parents || columns.length !== parents || !/^[ +-]+$/.test(columns) || text.startsWith("\\")) {
      result.push({ offset, text, kind: "header" });
      continue;
    }
    if (columns.includes("-")) {
      result.push({
        offset,
        text: text.slice(parents),
        kind: "deletion",
        ...(columns[0] === "-" ? { oldNumber: oldNumber++ } : {}),
      });
    } else if (columns.includes("+")) {
      result.push({
        offset,
        text: text.slice(parents),
        kind: "addition",
        newNumber: newNumber++,
        ...(columns[0] === " " ? { oldNumber: oldNumber++ } : {}),
      });
    } else
      result.push({
        offset,
        text: text.slice(parents),
        kind: "context",
        oldNumber: oldNumber++,
        newNumber: newNumber++,
      });
  }
  return result;
}
function files(value: unknown, root: string | undefined) {
  let characters = 0;
  return array(value, 2000).map((value) => {
    const file = object(value);
    const patch = string(file.patch);
    characters += patch.length;
    if (characters > 6 * 1024 * 1024) throw new Error("Change patches exceed the response capacity");
    const headerEnd = patch.indexOf("\n@@");
    return {
      root: string(file.root ?? root, "checkout root"),
      patch,
      path: patchPath(headerEnd >= 0 ? patch.slice(0, headerEnd) : patch),
      hasLineCounts: !patch.startsWith("* Unmerged path "),
      additions: count(file.additions),
      deletions: count(file.deletions),
      omitted: file.omitted == null ? undefined : string(object(file.omitted).reason),
      replacedInvalidUtf8: flag(file.replacedInvalidUtf8),
    };
  });
}
export function decodeChangeRead(value: unknown, label: string): ChangeRead {
  const result = object(value);
  if (result.status === "unavailable") return { status: "unavailable", reason: string(result.reason) };
  if (result.status === "anchorMissing")
    return { status: "unavailable", reason: "The selected start turn is no longer available." };
  if (result.status === "noRecentEdits")
    return {
      status: "ready",
      files: [],
      complete: flag(result.complete),
      unlisted: 0,
      label,
      comparison: label,
    };
  if (result.status !== "ready") throw new Error("Invalid changes response");
  const snapshot = result.snapshot ? object(result.snapshot) : result;
  const root = optionalString(snapshot.root) ?? undefined;
  const comparison = result.turn
    ? `${label} (${string(object(result.turn).id)})`
    : result.since
      ? `Since turn ${string(object(result.since).turnId)} (${string(object(result.since).boundary)})`
      : label;
  return {
    status: "ready",
    files: files(snapshot.files, root),
    complete: flag(snapshot.complete),
    unlisted: count(snapshot.unlistedFiles),
    label,
    comparison,
  };
}
export function changesLabel(view?: ChangesView) {
  return view?.kind === "git"
    ? { uncommitted: "Uncommitted", staged: "Staged", unstaged: "Unstaged" }[view.source]
    : view?.kind === "lastTurn"
      ? "Last Turn"
      : view?.kind === "since"
        ? "Since selected turn"
        : "Branch";
}
export async function readConversationChanges(
  reader: Reader,
  threadId: string,
  directory: string,
  view: ChangesView | undefined,
  signal: AbortSignal,
) {
  const label = changesLabel(view);
  if (view?.kind === "lastTurn" || view?.kind === "since")
    return decodeChangeRead(
      await reader.request(
        "changes/turn",
        {
          threadId,
          ...(view.kind === "since" ? { since: { turnId: view.turnId, boundary: view.boundary } } : {}),
        },
        { signal },
      ),
      label,
    );
  const source = view?.source ?? "branch";
  let result = decodeChangeRead(
    await reader.request("changes/read", { directory, source }, { signal }),
    label,
  );
  if (
    source === "branch" &&
    result.status === "unavailable" &&
    ["noBaseBranch", "noMergeBase"].includes(result.reason)
  )
    result = decodeChangeRead(
      await reader.request("changes/read", { directory, source: "uncommitted" }, { signal }),
      "Uncommitted",
    );
  return result;
}
export function reviewComment(file: ChangeFile, line: DiffLine, comparison: string, comment: string) {
  const number = line.kind === "deletion" ? line.oldNumber : line.newNumber;
  if (!file.path || number === undefined || !comment.trim())
    throw new Error("This line cannot receive a review comment.");
  const marker = line.kind === "addition" ? "+" : line.kind === "deletion" ? "-" : " ";
  return `Review comments on ${comparison} in ${file.root}:\n\n${file.path}:${number}${line.kind === "deletion" ? " (removed line)" : ""}\n> ${marker} ${line.text.slice(0, 200)}${line.text.length > 200 ? "…" : ""}\n${comment.trim()}`;
}

export function changeDirectories(value: unknown) {
  const result = object(value);
  const worked = array(result.workedIn, 64).map((value) => {
    const checkout = object(value);
    const root = string(checkout.root);
    if (!["ready", "unavailable", "failed"].includes(String(checkout.status)))
      throw new Error("Invalid checkout coverage");
    return {
      root,
      source: checkout.status === "ready" ? string(object(checkout.snapshot).source) : undefined,
      changed: checkout.status === "ready" && array(object(checkout.snapshot).files, 2000).length > 0,
    };
  });
  return {
    roots: [
      ...new Set([
        ...worked.map((value) => value.root),
        ...array(result.inFolder, 64).map((value) => string(value)),
      ]),
    ],
    sources: Object.fromEntries(worked.map((checkout) => [checkout.root, checkout.source])),
    primary: worked.find((value) => value.changed)?.root ?? worked[0]?.root,
    complete: flag(result.complete),
  };
}
