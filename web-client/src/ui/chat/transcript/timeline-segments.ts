import { publishedVisual, type VisualPublication } from "../../../protocol/boundary";
import type { Row } from "../../../workspace/conversation-session";

const narrativeTypes = new Set([
  "userMessage",
  "agentMessage",
  "plan",
  "contextCompaction",
  "imageGeneration",
  "hookPrompt",
]);
export type Segment =
  | { kind: "row"; row: Row; reply: boolean; visual?: VisualPublication }
  | { kind: "timeline"; rows: Row[]; live: boolean };
function isTimelineEvent(row: Row) {
  const item = row.entry.item;
  if (narrativeTypes.has(item.type)) return false;
  if (item.type === "reasoning") return [...item.summary, ...item.content].some((text) => text.trim());
  return true;
}
export function timelineSegments(rows: Row[], turnActive: boolean): Segment[] {
  const segments: Segment[] = [];
  const placements = new Map<string, Set<string>>();
  const latestPublications = new Map<string, Map<string, string>>();
  for (const row of rows) {
    const visual = publishedVisual(row.entry.item);
    if (visual) {
      const latest = latestPublications.get(row.entry.turnId) ?? new Map<string, string>();
      latest.set(visual.title, row.entry.item.id);
      latestPublications.set(row.entry.turnId, latest);
    }
    if (row.entry.item.type !== "agentMessage" || row.entry.isComplete !== true) continue;
    for (const digest of row.visualPlacements ?? []) {
      const placed = placements.get(row.entry.turnId) ?? new Set<string>();
      placed.add(digest);
      placements.set(row.entry.turnId, placed);
    }
  }
  const steers: Row[] = [];
  const flushSteers = () => {
    for (const row of steers.splice(0)) segments.push({ kind: "row", row, reply: false });
  };
  for (const row of rows) {
    if (row.entry.item.type === "reasoning" && !isTimelineEvent(row)) continue;
    if (steers[0] && steers[0].entry.turnId !== row.entry.turnId) flushSteers();
    if (row.steer) {
      steers.push(row);
      continue;
    }
    const last = segments.at(-1);
    if (!isTimelineEvent(row)) segments.push({ kind: "row", row, reply: false });
    else if (last?.kind === "timeline") last.rows.push(row);
    else segments.push({ kind: "timeline", rows: [row], live: false });
    const visual = publishedVisual(row.entry.item);
    if (
      visual &&
      latestPublications.get(row.entry.turnId)?.get(visual.title) === row.entry.item.id &&
      !placements.get(row.entry.turnId)?.has(visual.digest)
    )
      segments.push({ kind: "row", row, reply: false, visual });
  }
  const last = segments.at(-1);
  if (turnActive && last?.kind === "timeline") last.live = true;
  else if (turnActive) segments.push({ kind: "timeline", rows: [], live: true });
  flushSteers();
  segments.forEach((segment, index) => {
    const next = segments[index + 1];
    if (segment.kind === "row" && segment.row.entry.item.type === "agentMessage")
      segment.reply = !next || (next.kind === "row" && next.row.entry.item.type === "userMessage");
  });
  return segments;
}
