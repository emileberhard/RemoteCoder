import { useEffect, useState } from "react";
import { sameBinding, targetKey } from "../../execution-context";
import { useSnapshot, useWorkspace } from "../workspace-context";

export function ExecutionPicker() {
  const workspace = useWorkspace();
  const snapshot = useSnapshot();
  const physical = snapshot.hosts.find((host) => host.host.id === snapshot.selectedHostId);
  const selected = workspace.selectedHost;
  const hostId = physical?.host.id;
  const [selecting, setSelecting] = useState(false);
  useEffect(() => {
    if (hostId && !hostId.startsWith("fixture-")) void workspace.refreshAccounts(hostId);
  }, [hostId, workspace]);
  if (!physical || !selected || hostId?.startsWith("fixture-")) return null;
  const catalog = physical.accounts.status === "ready" ? physical.accounts.value : undefined;
  const choices = catalog?.choices.filter((choice) => choice.target.enrollment) ?? [];
  const current = choices.find((choice) => sameBinding(choice.target, selected.target));
  const selectedKey = targetKey(selected.target);
  const defaultKey = targetKey({ hostId: physical.host.id });
  return (
    <section className="settings-section">
      <h3>Codex account on {physical.host.name}</h3>
      <select
        className="settings-select"
        aria-label="Codex account"
        value={selectedKey}
        disabled={selecting}
        onChange={(event) => {
          const choice = choices.find((choice) => targetKey(choice.target) === event.target.value);
          const target = event.target.value === defaultKey ? { hostId: physical.host.id } : choice?.target;
          if (!target) return;
          setSelecting(true);
          void workspace
            .selectTarget(target)
            .catch((error) => workspace.report(error))
            .finally(() => setSelecting(false));
        }}
      >
        <option value={defaultKey}>Host default</option>
        {selected.target.enrollment && !current && (
          <option value={selectedKey} disabled>
            Previous account generation
          </option>
        )}
        {choices.map((choice) => (
          <option key={targetKey(choice.target)} value={targetKey(choice.target)} disabled={!choice.usable}>
            {choice.identity?.email || choice.label || "Codex account"}
            {choice.usable ? "" : ` · ${choice.state}`}
          </option>
        ))}
      </select>
      {physical.accounts.status === "failed" && <p className="error">{physical.accounts.error}</p>}
    </section>
  );
}
