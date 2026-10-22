import { FoldVertical } from "lucide-react";
import type { ContextWindowUsage } from "../../../workspace/context-window-usage";
import { useAnchoredPopover } from "../../design-system/anchored-popover";

const compact = new Intl.NumberFormat(undefined, { notation: "compact" });
const fill = {
  normal: "var(--foreground)",
  amber: "var(--usage-low)",
  red: "var(--danger)",
} satisfies Record<ContextWindowUsage["level"], string>;
const radius = 8;

export const contextTokensText = (usage: ContextWindowUsage) =>
  `${compact.format(usage.usedTokens)} of ${compact.format(usage.contextWindow)} tokens`;
const circumference = 2 * Math.PI * radius;

export function ContextWindowGauge({ usage }: { usage: ContextWindowUsage }) {
  const { id, trigger, surface } = useAnchoredPopover("end");
  const tokens = contextTokensText(usage);
  const color = fill[usage.level];
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className="context-gauge"
        title="Context window"
        aria-label="Context window"
        aria-description={`${usage.usedPercent} percent full, ${tokens}`}
        popoverTarget={id}
      >
        <svg viewBox="-11 -11 22 22" aria-hidden="true" style={{ color }}>
          <circle className="usage-ring-track" r={radius} />
          <circle
            className="usage-ring-value"
            r={radius}
            strokeDasharray={circumference}
            strokeDashoffset={circumference * (1 - usage.usedFraction)}
          />
        </svg>
      </button>
      <div
        ref={surface}
        id={id}
        popover="auto"
        className="popover-surface context-details"
        role="dialog"
        aria-label="Context window"
      >
        <div>
          <span>Context window</span>
          <strong style={{ color }}>{usage.usedPercent}% full</strong>
        </div>
        <span className="usage-bar">
          <span style={{ width: `${usage.usedFraction * 100}%`, background: color }} />
        </span>
        <small>{tokens}</small>
        <small className="context-compaction">
          <FoldVertical size={13} />
          Compacts automatically when nearly full
        </small>
      </div>
    </>
  );
}
