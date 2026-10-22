import { AlertTriangle, Circle, CircleCheck, RefreshCw } from "lucide-react";
import { useCallback, useEffect } from "react";
import type { UsageAccount } from "../../workspace/account-usage-store";
import { IconButton } from "../design-system/icon-button";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";
import { remainingColor, UsageDetailsContent } from "./usage-details";

const capitalized = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);
const availabilityFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });

function availabilityText(account: UsageAccount): string | undefined {
  if (!account.availability) return undefined;
  const state = capitalized(account.availability);
  return account.availableAt !== undefined && account.availability !== "available"
    ? `${state} until ${availabilityFormat.format(new Date(account.availableAt * 1000))}`
    : state;
}

function SelectionMark({ selected }: { selected: boolean }) {
  return selected ? (
    <CircleCheck size={20} className="account-mark selected" />
  ) : (
    <Circle size={20} className="account-mark" />
  );
}

function CodexAccount({ account }: { account: UsageAccount }) {
  return (
    <div className="account-card">
      <strong>{account.title}</strong>
      {account.plan && <small className="subtle">{capitalized(account.plan)}</small>}
      <div className="account-remaining">
        {(["fiveHour", "weekly"] as const).map((kind) => {
          const row = account.rows.find((row) => row.kind === kind);
          return (
            <div key={kind}>
              <small>{kind === "fiveHour" ? "5-hour" : "Weekly"}</small>
              <strong style={{ color: row ? remainingColor(row) : "var(--muted)" }}>
                {row ? `${row.remainingPercent}%` : "—"}
              </strong>
            </div>
          );
        })}
      </div>
      {account.notice && <small className="subtle">{account.notice}</small>}
    </div>
  );
}

export function AccountsOverview() {
  const workspace = useWorkspace();
  const run = useRun();
  const { claude, codex } = useSnapshot().accountUsage;
  const refresh = useCallback(() => {
    run(() => workspace.refreshAccountUsage("claude", true));
    run(() => workspace.refreshAccountUsage("codex", true));
  }, [workspace, run]);
  useEffect(refresh, [refresh]);
  const choose = (account: string | null) => run(() => workspace.setClaudeAccountPreference(account));
  const failed = [claude.error, codex.error].filter((error): error is string => Boolean(error));
  return (
    <>
      {claude.accounts.length > 0 && (
        <section className="settings-section account-section">
          <h3>Claude</h3>
          <button
            type="button"
            className="account-choice"
            aria-pressed={claude.preference == null}
            disabled={!claude.canSelect}
            onClick={() => choose(null)}
          >
            <SelectionMark selected={claude.preference == null} />
            <span>Automatic</span>
          </button>
          {claude.accounts.map((account) => (
            <div key={account.id} className="account-card">
              <button
                type="button"
                className="account-choice"
                aria-pressed={claude.preference === account.id}
                disabled={!claude.canSelect}
                onClick={() => choose(account.id)}
              >
                <SelectionMark selected={claude.preference === account.id} />
                <strong>{account.title}</strong>
                {account.id === claude.automatic && <small className="subtle">Automatic</small>}
              </button>
              <div className="account-details">
                <small className="subtle">
                  {[
                    account.plan && capitalized(account.plan),
                    account.shared ? "Shared" : undefined,
                    availabilityText(account),
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </small>
                <UsageDetailsContent rows={account.rows} notice={account.notice} loading={claude.loading} />
              </div>
            </div>
          ))}
        </section>
      )}
      {codex.accounts.length > 0 && (
        <section className="settings-section account-section">
          <div className="account-heading">
            <h3>Codex</h3>
            <small className="subtle">Remaining</small>
          </div>
          {codex.accounts.map((account) => (
            <CodexAccount key={account.id} account={account} />
          ))}
        </section>
      )}
      {!claude.accounts.length && !codex.accounts.length && (
        <p className="empty-card">
          {[claude.status, codex.status].some((status) => status === "unread" || status === "loading")
            ? "Loading accounts…"
            : [claude.status, codex.status].includes("failed")
              ? "Accounts unavailable"
              : "No accounts. Accounts are managed in llm-router."}
        </p>
      )}
      {failed.length > 0 && (
        <div className="inline-error">
          <AlertTriangle size={16} />
          <span>Some accounts couldn't be updated. {failed.join(" ")}</span>
          <IconButton label="Refresh" onClick={refresh}>
            <RefreshCw size={14} />
          </IconButton>
        </div>
      )}
    </>
  );
}
