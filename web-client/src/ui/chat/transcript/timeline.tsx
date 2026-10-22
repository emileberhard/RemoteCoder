import { ChevronRight } from "lucide-react";
import { type ReactNode, useState } from "react";
import type { Row } from "../../../workspace/conversation-session";

export function timelineLabel(rows: Row[]) {
  const started = Math.min(...rows.map((row) => row.entry.startedAtMs ?? Number.POSITIVE_INFINITY));
  const completed = Math.max(...rows.map((row) => row.entry.completedAtMs ?? Number.NEGATIVE_INFINITY));
  const seconds = Math.round((completed - started) / 1000);
  if (Number.isFinite(seconds) && seconds >= 1) {
    const minutes = Math.floor(seconds / 60);
    return `Thought for ${minutes ? `${minutes}m ${seconds % 60}s` : `${seconds}s`}`;
  }
  return rows.length === 1 ? "Thought through 1 action" : `Thought through ${rows.length} actions`;
}
export function Timeline({
  rows,
  live,
  renderRow,
}: {
  rows: Row[];
  live: boolean;
  renderRow(row: Row): ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  return (
    <section className={`timeline ${expanded ? "expanded" : ""}`}>
      <button
        type="button"
        className="timeline-header"
        aria-expanded={expanded}
        disabled={!rows.length}
        onClick={() => setExpanded(!expanded)}
      >
        {live ? (
          <span className="thinking-label">
            Thinking
            <span className="thinking-dots" aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
          </span>
        ) : (
          <span>{timelineLabel(rows)}</span>
        )}
        <ChevronRight size={14} strokeWidth={2.4} />
      </button>
      {expanded && (
        <ol className="timeline-events">
          {rows.map((row) => (
            <li
              key={row.entry.item.id}
              className={`timeline-event ${row.entry.item.type === "commandExecution" && row.entry.item.status === "failed" ? "failed" : ""}`}
            >
              {renderRow(row)}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
