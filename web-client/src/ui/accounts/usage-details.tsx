import type { UsageRow } from "../../workspace/account-usage-store";

const kindOrder: Record<UsageRow["kind"], number> = { fiveHour: 0, weekly: 1, fable: 2, other: 3 };
const resetFormat = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});
const resetDayFormat = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

export function remainingColor(row: UsageRow): string {
  if (row.stale) return "var(--muted)";
  if (row.remainingPercent <= 10) return "var(--danger)";
  if (row.remainingPercent <= 25) return "var(--usage-low)";
  return "var(--foreground)";
}
function resetText(resetsAt: number | undefined): string | undefined {
  if (resetsAt === undefined) return undefined;
  const date = new Date(resetsAt * 1000);
  const soon = date.getTime() - Date.now() < 86_400_000;
  return `Resets ${(soon ? resetFormat : resetDayFormat).format(date)}`;
}

export function UsageDetailsContent({
  rows,
  notice,
  loading,
}: {
  rows: readonly UsageRow[];
  notice?: string;
  loading: boolean;
}) {
  const ordered = [...rows].sort((a, b) => kindOrder[a.kind] - kindOrder[b.kind]);
  return (
    <>
      {notice && <p className="subtle">{notice}</p>}
      {!ordered.length && !notice && (
        <p className="subtle">{loading ? "Reading usage…" : "Usage unavailable"}</p>
      )}
      {ordered.map((row) => {
        const reset = resetText(row.resetsAt);
        return (
          <div key={row.id} className="usage-row">
            <div>
              <span>{row.title}</span>
              <strong style={{ color: remainingColor(row) }}>{row.remainingPercent}% left</strong>
            </div>
            <span className="usage-bar" style={{ opacity: row.stale ? 0.5 : 1 }}>
              <span style={{ width: `${row.remainingPercent}%`, background: remainingColor(row) }} />
            </span>
            {reset && <small>{reset}</small>}
          </div>
        );
      })}
    </>
  );
}
