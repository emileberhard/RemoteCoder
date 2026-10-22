import { Laptop, Monitor, MoreHorizontal, Pencil, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { api } from "../../gateway";
import type { Host } from "../../protocol/boundary";
import type { HostState } from "../../workspace/host-services";
import { Menu, MenuItem } from "../design-system/menu";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";

export function HostsSettings() {
  const workspace = useWorkspace();
  const run = useRun();
  const { hosts } = useSnapshot();
  const [editing, setEditing] = useState<Host>();
  useEffect(() => run(() => workspace.refreshVersions()), [workspace, run]);
  return (
    <>
      <section className="settings-section">
        <h3>Gateway hosts</h3>
        <div className="host-cards">
          {hosts.map((state) =>
            editing?.id === state.host.id ? (
              <HostEditor key={state.host.id} host={state.host} done={() => setEditing(undefined)} />
            ) : (
              <div className="host-card" key={state.host.id}>
                <div className="host-card-heading">
                  {state.host.name.includes("MacBook") ? <Laptop size={22} /> : <Monitor size={22} />}
                  <div>
                    <strong>{state.host.name}</strong>
                    <small>{gatewayVersion(state)}</small>
                  </div>
                  <span className={`status-dot ${state.status}`} title={state.status} />
                  <Menu label={`Options for ${state.host.name}`} icon={<MoreHorizontal size={18} />}>
                    {!state.host.id.startsWith("fixture-") && (
                      <MenuItem icon={<Pencil size={15} />} onSelect={() => setEditing(state.host)}>
                        Edit
                      </MenuItem>
                    )}
                    <MenuItem
                      icon={<RefreshCw size={15} />}
                      onSelect={() => run(() => workspace.refreshHost(state.host.id))}
                    >
                      Reconnect
                    </MenuItem>
                  </Menu>
                </div>
                {state.error && <p className="error">{state.error}</p>}
                {state.host.credentialStatus === "unavailable" && (
                  <p className="error">The bridge cannot read this host's credential.</p>
                )}
              </div>
            ),
          )}
        </div>
      </section>
      <section className="settings-section host-setup">
        <h3>Add a host</h3>
        <pre>
          bun scripts/host.ts --id my-mac --name "My Mac" \<br /> --url https://gateway.example.com \<br />{" "}
          --token-file /absolute/path/to/gateway-token \<br /> --cwd /Users/you/Projects
        </pre>
        <button type="button" className="secondary" onClick={() => run(() => workspace.refreshHosts())}>
          <RefreshCw size={15} />
          Refresh hosts
        </button>
      </section>
    </>
  );
}
function HostEditor({ host, done }: { host: Host; done(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [name, setName] = useState(host.name);
  const [cwd, setCwd] = useState(host.cwd);
  return (
    <form
      className="host-card settings-form"
      onSubmit={(event) => {
        event.preventDefault();
        run(async () => {
          await api("/api/hosts", { method: "PUT", body: JSON.stringify({ id: host.id, name, cwd }) });
          await workspace.refreshHosts();
          done();
        });
      }}
    >
      <label>
        Name
        <input value={name} onChange={(event) => setName(event.target.value)} required />
      </label>
      <label>
        Default folder
        <input value={cwd} onChange={(event) => setCwd(event.target.value)} />
      </label>
      <div className="form-actions">
        <button type="button" className="secondary" onClick={done}>
          Cancel
        </button>
        <button type="submit" className="primary">
          Save
        </button>
      </div>
    </form>
  );
}
function gatewayVersion(state: HostState): string {
  const read = state.version;
  if (read.status === "failed") return `Version unavailable · ${state.host.url}`;
  if (read.status !== "ready") return state.host.url;
  const { version, commit } = read.value;
  return commit ? `Gateway ${version} · ${commit.slice(0, 7)}` : `Gateway ${version}`;
}
