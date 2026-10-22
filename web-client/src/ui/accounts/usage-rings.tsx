import { ChevronsUpDown, Users } from "lucide-react";
import type { ReactNode } from "react";
import type { Provider } from "../../protocol/boundary";
import type { AccountUsageSnapshot, ProviderUsage, UsageRow } from "../../workspace/account-usage-store";
import { useAnchoredPopover } from "../design-system/anchored-popover";
import { Menu, MenuChoice, MenuItem } from "../design-system/menu";
import { ProviderMark } from "../design-system/provider-mark";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";
import { remainingColor, UsageDetailsContent } from "./usage-details";

type Hsb = readonly [hue: number, saturation: number, brightness: number];
const lime: Hsb = [80, 0.85, 0.92];
const orange: Hsb = [32, 1, 1];
const alert: Hsb = [3, 0.82, 1];

function css([hue, saturation, brightness]: Hsb): string {
  const lightness = brightness * (1 - saturation / 2);
  const hslSaturation =
    lightness === 0 || lightness === 1 ? 0 : (brightness - lightness) / Math.min(lightness, 1 - lightness);
  return `hsl(${hue} ${hslSaturation * 100}% ${lightness * 100}%)`;
}
function runOutColor(severity: number): string {
  const [from, to, fraction] =
    severity < 0.5 ? [lime, orange, severity * 2] : [orange, alert, (severity - 0.5) * 2];
  const blend = (index: 0 | 1 | 2) => from[index] + (to[index] - from[index]) * fraction;
  return css([blend(0), blend(1), blend(2)]);
}

function Ring({ row, color, radius }: { row?: UsageRow; color: string; radius: number }) {
  const circumference = 2 * Math.PI * radius;
  return (
    <g style={{ color }}>
      <circle className={`usage-ring-track ${row ? "" : "unknown"}`} r={radius} />
      {row && (
        <circle
          className="usage-ring-value"
          r={radius}
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - row.remainingPercent / 100)}
          opacity={row.stale ? 0.5 : 1}
        />
      )}
    </g>
  );
}

function UsageRings({ provider, usage }: { provider: Provider; usage: ProviderUsage }) {
  const { weekly, innerRing } = usage;
  const warning = innerRing?.runOutWarning;
  return (
    <span className="usage-rings">
      <svg viewBox="-18 -18 36 36" aria-hidden="true">
        <Ring row={weekly} color={weekly ? remainingColor(weekly) : "var(--muted)"} radius={16.5} />
        {innerRing && warning && (
          <Ring
            row={innerRing}
            color={innerRing.stale ? "var(--muted)" : runOutColor(warning.severity)}
            radius={12.5}
          />
        )}
      </svg>
      <span className="usage-ring-mark" style={{ opacity: weekly && !weekly.stale ? 1 : 0.5 }}>
        <ProviderMark provider={provider} />
      </span>
    </span>
  );
}

function ringAccessibilityValue(usage: ProviderUsage): string {
  const rows = [usage.weekly, usage.innerRing].filter((row): row is UsageRow => Boolean(row));
  if (!rows.length) return "Unavailable";
  return rows
    .map((row) => `${row.title}: ${row.remainingPercent} percent left${row.stale ? ", last known" : ""}`)
    .join(". ");
}

function UsageDetails({
  provider,
  usage,
  header,
  showAccounts,
}: {
  provider: Provider;
  usage: ProviderUsage;
  header?: ReactNode;
  showAccounts(): void;
}) {
  const account = usage.account;
  return (
    <div className="usage-details">
      {header ?? (
        <button type="button" className="usage-account" onClick={showAccounts}>
          <ProviderMark provider={provider} />
          <span>{account?.title ?? "Codex"}</span>
          <Users size={14} />
        </button>
      )}
      {usage.error && <p className="error">{usage.error}</p>}
      <UsageDetailsContent rows={account?.rows ?? []} notice={account?.notice} loading={usage.loading} />
    </div>
  );
}

function UsageRingButton({
  provider,
  usage,
  showAccounts,
}: {
  provider: Provider;
  usage: ProviderUsage;
  showAccounts(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const { id, trigger, surface } = useAnchoredPopover("center");
  const name = provider === "claude" ? "Claude" : "Codex";
  const refresh = () => run(() => workspace.refreshAccountUsage(provider, true));
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className="usage-ring-button"
        title={`Show ${name} usage`}
        aria-label={`${name} usage, ${usage.account?.title ?? "no account selected"}`}
        aria-description={ringAccessibilityValue(usage)}
        popoverTarget={id}
        onClick={refresh}
        onContextMenu={(event) => {
          event.preventDefault();
          refresh();
        }}
      >
        <UsageRings provider={provider} usage={usage} />
      </button>
      <div
        ref={surface}
        id={id}
        popover="auto"
        className="popover-surface"
        role="dialog"
        aria-label={`${name} usage`}
      >
        {provider === "claude" ? (
          <ClaudeUsageDetails
            usage={workspace.accountUsage.claude}
            showAccounts={() => {
              surface.current?.hidePopover();
              showAccounts();
            }}
          />
        ) : (
          <UsageDetails
            provider={provider}
            usage={usage}
            showAccounts={() => {
              surface.current?.hidePopover();
              showAccounts();
            }}
          />
        )}
      </div>
    </>
  );
}

function ClaudeUsageDetails({
  usage,
  showAccounts,
}: {
  usage: AccountUsageSnapshot["claude"];
  showAccounts(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const title = usage.preference == null ? "Automatic" : (usage.account?.title ?? "Choose Account");
  return (
    <UsageDetails
      provider="claude"
      usage={usage}
      header={
        <Menu
          label="Claude account"
          className="usage-account"
          align="start"
          icon={
            <>
              <ProviderMark provider="claude" />
              <span>{title}</span>
              <ChevronsUpDown size={14} />
            </>
          }
        >
          <MenuChoice
            selected={usage.preference == null}
            disabled={!usage.canSelect}
            onSelect={() => run(() => workspace.setClaudeAccountPreference(null))}
          >
            Automatic
          </MenuChoice>
          {usage.accounts.map((account) => (
            <MenuChoice
              key={account.id}
              selected={usage.preference === account.id}
              disabled={!usage.canSelect}
              onSelect={() => run(() => workspace.setClaudeAccountPreference(account.id))}
            >
              {account.title}
              {account.id === usage.automatic ? " · Automatic" : ""}
            </MenuChoice>
          ))}
          <hr />
          <MenuItem icon={<Users size={16} />} onSelect={showAccounts}>
            All Accounts
          </MenuItem>
        </Menu>
      }
      showAccounts={showAccounts}
    />
  );
}

export function UsageRingsControl({ showAccounts }: { showAccounts(): void }) {
  const { accountUsage } = useSnapshot();
  return (
    <span className="usage-capsule">
      <UsageRingButton provider="claude" usage={accountUsage.claude} showAccounts={showAccounts} />
      <UsageRingButton provider="codex" usage={accountUsage.codex} showAccounts={showAccounts} />
    </span>
  );
}
