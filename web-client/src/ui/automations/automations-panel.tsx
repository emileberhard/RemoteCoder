import { useState } from "react";
import { array, identifier, object, string } from "../../protocol/boundary";
import {
  automationValue,
  boolean,
  date,
  failure,
  MutationStatus,
  optionalNumber,
  optionalText,
  type PanelProps,
  ReadStatus,
  revision,
  unique,
  useMutation,
  useRead,
} from "../remote-operations";

const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
export function setDefinitionField(
  definition: Record<string, unknown>,
  path: string[],
  value: unknown,
): Record<string, unknown> {
  const key = path[0];
  if (!key) return definition;
  const next = { ...definition };
  if (path.length > 1) next[key] = setDefinitionField(record(definition[key]), path.slice(1), value);
  else if (value === undefined) delete next[key];
  else next[key] = value;
  return next;
}
type AutomationDefaults = { hostname: string; homeDirectory: string };
export function newAutomation(defaults: AutomationDefaults): Record<string, unknown> {
  return {
    id: "",
    enabled: false,
    cwd: defaults.homeDirectory,
    timeout: 7200,
    when: { every: "1h", timezone: "Europe/Stockholm" },
    run: {
      agent: {
        provider: "codex",
        prompt: "",
        gateway_host: defaults.hostname,
        session: "fresh",
        access: "full-access",
        if_active: "queue",
      },
    },
  };
}
export function parseAutomationDetail(value: unknown) {
  const detail = automationValue(value);
  const id = identifier(detail.id);
  const definition = object(detail.definition);
  if (definition.id !== id) throw new Error("The automation definition identity does not match its response");
  return {
    id,
    revision: revision(detail.revision),
    definition,
    removed: detail.removed === true || detail.removed === 1,
    managed: detail.managed === true,
    runs:
      detail.runs == null
        ? undefined
        : array(detail.runs, 50).map((value) => {
            const run = object(value);
            return {
              id: identifier(run.id),
              state: string(run.state),
              created: optionalNumber(run.created),
              error: optionalText(run.error),
            };
          }),
  };
}
type Draft = { definition: Record<string, unknown>; revision: number };
const drafts = new Map<string, Draft>();
function retainDraft(key: string, draft: Draft) {
  if (!drafts.has(key) && drafts.size >= 8)
    throw new Error("Eight automation drafts are already open. Save or discard one before editing another.");
  if (new TextEncoder().encode(JSON.stringify(draft.definition)).byteLength > 128 * 1024)
    throw new Error("This automation draft exceeds the browser editor limit");
  drafts.set(key, draft);
}
export function AutomationsPanel({ transport, defaults }: PanelProps & { defaults: AutomationDefaults }) {
  const [filter, setFilter] = useState("active");
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState<string>();
  const [creating, setCreating] = useState(false);
  const inventory = useRead(
    `${transport.hostId}:automations:${filter}:${query}:${offset}`,
    async (signal) => {
      const status = automationValue(await transport.request("automations/status", {}, { signal }));
      const capabilities = object(status.capabilities);
      if (capabilities.api_version !== 1 || capabilities.history_version !== 1)
        throw new Error("This gateway does not support automation management yet");
      const page = automationValue(
        await transport.request(
          "automations/list",
          {
            ...(filter !== "all" ? { state: filter } : {}),
            includeRemoved: ["all", "removed"].includes(filter),
            ...(query ? { search: query } : {}),
            limit: 50,
            offset,
          },
          { signal },
        ),
      );
      return {
        authority: optionalText(status.definition_authority),
        coverage: optionalText(status.history_coverage),
        items: unique(
          array(page.items, 50).map((value) => {
            const item = object(value);
            return {
              id: identifier(item.id),
              revision: revision(item.revision),
              name: optionalText(item.name),
              enabled: boolean(item.enabled),
              removed: item.removed === true || item.removed === 1,
              completed: item.completed === true,
              expired: item.expired === true,
              nextDue: optionalNumber(item.next_due),
              when: item.when,
            };
          }),
          (item) => item.id,
        ),
      };
    },
  );
  const available = Boolean(inventory.value && !inventory.loading && !inventory.error);
  return (
    <>
      <div className="panel-toolbar">
        <p className="panel-muted">Scheduled work · {transport.hostName}</p>
        <div className="panel-actions">
          <button
            type="button"
            onClick={() => {
              setSelected(undefined);
              setCreating(true);
            }}
            disabled={!available}
          >
            New automation
          </button>
          <button type="button" onClick={inventory.refresh} disabled={inventory.loading}>
            Refresh
          </button>
        </div>
      </div>
      <form
        className="panel-toolbar"
        onSubmit={(event) => {
          event.preventDefault();
          setOffset(0);
          setQuery(search);
        }}
      >
        <select
          aria-label="Automation state"
          value={filter}
          onChange={(event) => {
            setFilter(event.target.value);
            setOffset(0);
          }}
        >
          <option value="active">Active</option>
          <option value="paused">Paused</option>
          <option value="removed">Removed</option>
          <option value="all">All</option>
        </select>
        <input
          aria-label="Search automations"
          placeholder="Search automations"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          maxLength={256}
        />
        <button type="submit">Search</button>
      </form>
      <ReadStatus {...inventory} />
      {inventory.value && (
        <p className="panel-muted">
          Definition authority: {inventory.value.authority ?? "Unknown"} · History:{" "}
          {inventory.value.coverage ?? "Unknown"}
        </p>
      )}
      {inventory.value?.items.length === 0 && <p className="panel-muted">No automations match this view.</p>}
      <div className="panel-list">
        {inventory.value?.items.map((item) => (
          <button
            type="button"
            key={item.id}
            className={`panel-row ${selected === item.id ? "selected" : ""}`}
            onClick={() => {
              setCreating(false);
              setSelected(item.id);
            }}
          >
            <strong>{item.name || item.id}</strong>
            <span>
              {item.removed
                ? "Removed"
                : item.expired
                  ? "Expired"
                  : item.completed
                    ? "Completed"
                    : item.enabled
                      ? "Active"
                      : "Paused"}{" "}
              · Revision {item.revision}
            </span>
            {item.nextDue != null && <span>Next: {date(item.nextDue)}</span>}
          </button>
        ))}
      </div>
      <div className="panel-actions">
        <button
          type="button"
          disabled={!offset || inventory.loading}
          onClick={() => setOffset(Math.max(0, offset - 50))}
        >
          Previous
        </button>
        <span className="panel-muted">
          Rows {offset + 1}–{offset + (inventory.value?.items.length ?? 0)}
        </span>
        <button
          type="button"
          disabled={inventory.loading || inventory.value?.items.length !== 50 || offset >= 450}
          onClick={() => setOffset(offset + 50)}
        >
          Next
        </button>
      </div>
      {creating && (
        <AutomationEditor
          key={`${transport.hostId}:new`}
          transport={transport}
          initial={{ definition: newAutomation(defaults), revision: 0 }}
          scope="new"
          close={() => setCreating(false)}
          saved={inventory.refresh}
        />
      )}
      {selected && (
        <AutomationDetail
          key={`${transport.hostId}:${selected}`}
          transport={transport}
          id={selected}
          available={available}
          saved={inventory.refresh}
        />
      )}
    </>
  );
}
function AutomationDetail({
  transport,
  id,
  available,
  saved,
}: PanelProps & { id: string; available: boolean; saved(): void }) {
  const detail = useRead(`${transport.hostId}:automation:${id}`, async (signal) =>
    parseAutomationDetail(
      await transport.request("automations/show", { id, limit: 50, offset: 0 }, { signal }),
    ),
  );
  const [editing, setEditing] = useState(false);
  const [historyVisible, setHistoryVisible] = useState(false);
  const [runId, setRunId] = useState<string>();
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [error, setError] = useState<string>();
  const [eventType, setEventType] = useState("");
  const [eventSource, setEventSource] = useState("");
  const [eventData, setEventData] = useState("{}");
  const mutation = useMutation(transport, `automation:${id}`);
  const triggers = detail.value
    ? (Array.isArray(detail.value.definition.when)
        ? detail.value.definition.when
        : [detail.value.definition.when]
      ).map(record)
    : [];
  const needsEvent =
    triggers.length > 0 &&
    triggers.every((trigger) => typeof trigger.event === "string" || trigger.imessage != null);
  function refreshed() {
    detail.refresh();
    saved();
  }
  async function mutate(method: string, params: Record<string, unknown>) {
    try {
      const requestId = crypto.randomUUID();
      const event =
        method === "automations/run" && needsEvent
          ? {
              data: {
                specversion: "1.0",
                id: requestId,
                type: identifier(eventType),
                source: identifier(eventSource),
                data: object(JSON.parse(eventData)),
              },
            }
          : {};
      const result = await mutation.run(method, { id, requestId, ...event, ...params });
      const admitted = record(result).run_id;
      if (typeof admitted === "string") setRunId(admitted);
      setError(undefined);
      setConfirmRemove(false);
      refreshed();
    } catch (error) {
      setError(failure(error));
      detail.refresh();
    }
  }
  const writable =
    available &&
    detail.value &&
    !detail.error &&
    !detail.loading &&
    !detail.value.managed &&
    !id.startsWith("source/") &&
    !mutation.pending;
  return (
    <section className="panel-card">
      <div className="panel-toolbar">
        <h3>{id}</h3>
        <button type="button" onClick={detail.refresh}>
          Refresh detail
        </button>
      </div>
      <ReadStatus {...detail} />
      {detail.value && (
        <>
          <p className="panel-muted">
            Revision {detail.value.revision}
            {detail.value.managed ? " · Managed by its owning service" : ""}
          </p>
          <div className="panel-actions">
            <button
              type="button"
              onClick={() => setEditing(true)}
              disabled={!writable || detail.value.removed}
            >
              Edit
            </button>
            <button
              type="button"
              disabled={
                !writable ||
                detail.value.removed ||
                (needsEvent && (!eventType.trim() || !eventSource.trim()))
              }
              onClick={() => void mutate("automations/run", {})}
            >
              Run now
            </button>
            <button type="button" onClick={() => setHistoryVisible(!historyVisible)}>
              {historyVisible ? "Hide history" : "Revision history"}
            </button>
            {!detail.value.removed && (
              <button type="button" onClick={() => setConfirmRemove(true)} disabled={!writable}>
                Remove…
              </button>
            )}
          </div>
          {needsEvent && (
            <details>
              <summary>Event for this run</summary>
              <div className="panel-form">
                <label>
                  Event type
                  <input
                    value={eventType}
                    onChange={(event) => setEventType(event.target.value)}
                    maxLength={256}
                  />
                </label>
                <label>
                  Event source
                  <input
                    value={eventSource}
                    onChange={(event) => setEventSource(event.target.value)}
                    maxLength={2048}
                  />
                </label>
                <label>
                  Event data JSON
                  <textarea
                    value={eventData}
                    onChange={(event) => setEventData(event.target.value)}
                    maxLength={32768}
                    rows={4}
                  />
                </label>
              </div>
            </details>
          )}
          {confirmRemove && (
            <div className="panel-notice">
              <p>Remove this automation? Its revision and run history will remain available.</p>
              <div className="panel-actions">
                <button
                  type="button"
                  onClick={() =>
                    void mutate("automations/remove", { expectedRevision: detail.value?.revision })
                  }
                  disabled={!writable}
                >
                  Remove automation
                </button>
                <button type="button" onClick={() => setConfirmRemove(false)}>
                  Keep automation
                </button>
              </div>
            </div>
          )}
          {!editing && (
            <details>
              <summary>Saved definition</summary>
              <pre>{JSON.stringify(detail.value.definition, null, 2)}</pre>
            </details>
          )}
          {editing && (
            <AutomationEditor
              transport={transport}
              initial={{ definition: detail.value.definition, revision: detail.value.revision }}
              scope={id}
              close={() => setEditing(false)}
              saved={refreshed}
            />
          )}
          {detail.value.runs === undefined ? (
            <p className="panel-muted">Run history is unavailable.</p>
          ) : (
            <div className="panel-list">
              {detail.value.runs.map((run) => (
                <button key={run.id} type="button" className="panel-row" onClick={() => setRunId(run.id)}>
                  <strong>{run.state}</strong>
                  <span>
                    {date(run.created)} · {run.id}
                  </span>
                  {run.error && <span>{run.error}</span>}
                </button>
              ))}
            </div>
          )}
          {historyVisible && (
            <AutomationHistory
              transport={transport}
              id={id}
              currentRevision={detail.value.revision}
              writable={Boolean(writable)}
              saved={refreshed}
            />
          )}
        </>
      )}
      {error && <p className="panel-error">{error}</p>}
      <MutationStatus
        mutation={mutation}
        retry={() => {
          void mutation
            .retry()
            .then(refreshed)
            .catch((error) => setError(failure(error)));
        }}
      />
      {runId && <AutomationRun transport={transport} id={runId} />}
    </section>
  );
}
function AutomationEditor({
  transport,
  initial,
  scope,
  close,
  saved,
}: {
  transport: PanelProps["transport"];
  initial: Draft;
  scope: string;
  close(): void;
  saved(): void;
}) {
  const key = JSON.stringify([transport.hostId, scope]);
  const [draft, setDraft] = useState(
    () => drafts.get(key) ?? { ...initial, definition: structuredClone(initial.definition) },
  );
  const [error, setError] = useState<string>();
  const [advanced, setAdvanced] = useState<string>();
  const mutation = useMutation(transport, `automation:${scope}`);
  function change(definition: Record<string, unknown>) {
    try {
      const next = { ...draft, definition };
      retainDraft(key, next);
      setDraft(next);
      setError(undefined);
    } catch (error) {
      setError(failure(error));
    }
  }
  const definition = draft.definition;
  const agent = record(record(definition.run).agent);
  const triggers = Array.isArray(definition.when) ? definition.when : [definition.when];
  const trigger = record(triggers[0]);
  const schedule = ["every", "cron", "at", "event"].find((key) => typeof trigger[key] === "string");
  function setTrigger(next: Record<string, unknown>) {
    change({ ...definition, when: Array.isArray(definition.when) ? [next, ...triggers.slice(1)] : next });
  }
  function field(path: string[], value: unknown) {
    change(setDefinitionField(definition, path, value));
  }
  async function save() {
    try {
      if (advanced !== undefined) throw new Error("Apply or cancel the definition editor before saving");
      const id = identifier(definition.id);
      await mutation.run("automations/set", {
        id,
        data: definition,
        replaceDefinition: true,
        requestId: crypto.randomUUID(),
        expectedRevision: draft.revision,
      });
      drafts.delete(key);
      saved();
      close();
    } catch (error) {
      setError(failure(error));
    }
  }
  return (
    <form
      className="panel-form panel-card"
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <h3>{draft.revision === 0 ? "New automation" : "Edit automation"}</h3>
      <fieldset disabled={Boolean(mutation.pending)} className="panel-fields">
        <label>
          Identifier
          <input
            value={typeof definition.id === "string" ? definition.id : ""}
            onChange={(event) => field(["id"], event.target.value)}
            disabled={draft.revision !== 0}
            required
            maxLength={256}
          />
        </label>
        <label>
          Name
          <input
            value={typeof definition.name === "string" ? definition.name : ""}
            onChange={(event) => field(["name"], event.target.value)}
            maxLength={256}
          />
        </label>
        <label className="panel-checkbox">
          <input
            type="checkbox"
            checked={definition.enabled === true}
            onChange={(event) => field(["enabled"], event.target.checked)}
          />
          Enabled
        </label>
        <label>
          Working directory
          <input
            value={typeof definition.cwd === "string" ? definition.cwd : ""}
            onChange={(event) => field(["cwd"], event.target.value)}
            required
            maxLength={4096}
          />
        </label>
        {schedule ? (
          <>
            <label>
              First trigger
              <select
                value={schedule}
                onChange={(event) => {
                  const next = { ...trigger };
                  for (const key of ["every", "cron", "at", "event"]) delete next[key];
                  next[event.target.value] = event.target.value === "every" ? "1h" : "";
                  setTrigger(next);
                }}
              >
                <option value="every">Interval</option>
                <option value="cron">Cron</option>
                <option value="at">Once</option>
                <option value="event">Event</option>
              </select>
            </label>
            <label>
              {schedule === "every"
                ? "Interval (for example 1h)"
                : schedule === "cron"
                  ? "Cron expression"
                  : schedule === "at"
                    ? "Date and time"
                    : "Event name"}
              <input
                value={string(trigger[schedule])}
                onChange={(event) => setTrigger({ ...trigger, [schedule]: event.target.value })}
                required
                maxLength={1024}
              />
            </label>
            <label>
              Timezone
              <input
                value={typeof trigger.timezone === "string" ? trigger.timezone : ""}
                onChange={(event) => setTrigger({ ...trigger, timezone: event.target.value })}
                maxLength={128}
              />
            </label>
            {triggers.length > 1 && (
              <p className="panel-muted">
                The other {triggers.length - 1} triggers are preserved. Edit them in the full definition.
              </p>
            )}
          </>
        ) : (
          <p className="panel-muted">This trigger is configured through the full definition editor.</p>
        )}
        {Object.keys(agent).length > 0 ? (
          <>
            <label>
              Provider
              <select
                value={typeof agent.provider === "string" ? agent.provider : ""}
                onChange={(event) => {
                  let next = setDefinitionField(definition, ["run", "agent", "provider"], event.target.value);
                  if (event.target.value === "claude")
                    next = setDefinitionField(next, ["run", "agent", "account"], undefined);
                  change(next);
                }}
              >
                {!["codex", "claude"].includes(String(agent.provider)) && (
                  <option value={String(agent.provider)}>{String(agent.provider)}</option>
                )}
                <option value="codex">Codex</option>
                <option value="claude">Claude</option>
              </select>
            </label>
            <label>
              Prompt
              <textarea
                value={typeof agent.prompt === "string" ? agent.prompt : ""}
                onChange={(event) => field(["run", "agent", "prompt"], event.target.value)}
                rows={6}
                required
                maxLength={131072}
              />
            </label>
          </>
        ) : (
          <p className="panel-muted">
            This automation runs a command or another action. Its complete action can be edited below.
          </p>
        )}
        <details>
          <summary>Full definition</summary>
          <p className="panel-muted">
            Includes command actions, additional triggers, access, session, and model settings. The service
            validates the complete definition.
          </p>
          {advanced === undefined ? (
            <button type="button" onClick={() => setAdvanced(JSON.stringify(definition, null, 2))}>
              Edit definition
            </button>
          ) : (
            <>
              <textarea
                aria-label="Automation definition JSON"
                value={advanced}
                onChange={(event) => setAdvanced(event.target.value)}
                rows={16}
                maxLength={131072}
              />
              <div className="panel-actions">
                <button
                  type="button"
                  onClick={() => {
                    try {
                      const next = object(JSON.parse(advanced));
                      if (draft.revision && next.id !== definition.id)
                        throw new Error("An existing automation's identifier cannot change");
                      retainDraft(key, { ...draft, definition: next });
                      setDraft({ ...draft, definition: next });
                      setAdvanced(undefined);
                      setError(undefined);
                    } catch (error) {
                      setError(failure(error));
                    }
                  }}
                >
                  Apply definition
                </button>
                <button type="button" onClick={() => setAdvanced(undefined)}>
                  Cancel definition edit
                </button>
              </div>
            </>
          )}
        </details>
        <div className="panel-actions">
          <button type="submit" disabled={advanced !== undefined}>
            Save automation
          </button>
          <button type="button" onClick={close} disabled={advanced !== undefined}>
            Keep draft
          </button>
          <button
            type="button"
            onClick={() => {
              drafts.delete(key);
              close();
            }}
          >
            Discard draft
          </button>
        </div>
      </fieldset>
      {error && (
        <p className="panel-error" role="alert">
          {error}
        </p>
      )}
      <MutationStatus
        mutation={mutation}
        retry={() => {
          void mutation
            .retry()
            .then(() => {
              drafts.delete(key);
              saved();
              close();
            })
            .catch((error) => setError(failure(error)));
        }}
      />
    </form>
  );
}
function AutomationHistory({
  transport,
  id,
  currentRevision,
  writable,
  saved,
}: {
  transport: PanelProps["transport"];
  id: string;
  currentRevision: number;
  writable: boolean;
  saved(): void;
}) {
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState<number>();
  const history = useRead(`${transport.hostId}:${id}:history:${offset}`, async (signal) => {
    const page = automationValue(
      await transport.request("automations/history", { id, limit: 50, offset }, { signal }),
    );
    return array(page.items, 50).map((value) => {
      const item = object(value);
      return {
        revision: revision(item.revision),
        removed: boolean(item.removed),
        change: string(item.change_kind),
        recordedAt: item.recorded_at,
      };
    });
  });
  return (
    <section className="panel-card">
      <h3>Revision history</h3>
      <ReadStatus {...history} />
      <div className="panel-list">
        {history.value?.map((item) => (
          <button
            type="button"
            key={item.revision}
            className="panel-row"
            onClick={() => setSelected(item.revision)}
          >
            <strong>
              Revision {item.revision} · {item.change}
              {item.removed ? " · Removed" : ""}
            </strong>
            <span>
              {typeof item.recordedAt === "number"
                ? date(item.recordedAt)
                : typeof item.recordedAt === "string"
                  ? item.recordedAt
                  : "Time unknown"}
            </span>
          </button>
        ))}
      </div>
      <div className="panel-actions">
        <button
          type="button"
          onClick={() => setOffset(Math.max(0, offset - 50))}
          disabled={!offset || history.loading}
        >
          Previous
        </button>
        <button
          type="button"
          onClick={() => setOffset(offset + 50)}
          disabled={history.loading || history.value?.length !== 50 || offset >= 450}
        >
          Next
        </button>
      </div>
      {selected !== undefined && (
        <RestorePreview
          key={selected}
          transport={transport}
          id={id}
          targetRevision={selected}
          currentRevision={currentRevision}
          writable={writable}
          saved={saved}
        />
      )}
    </section>
  );
}
function RestorePreview({
  transport,
  id,
  targetRevision,
  currentRevision,
  writable,
  saved,
}: {
  transport: PanelProps["transport"];
  id: string;
  targetRevision: number;
  currentRevision: number;
  writable: boolean;
  saved(): void;
}) {
  const snapshot = useRead(`${transport.hostId}:${id}:revision:${targetRevision}`, async (signal) =>
    parseAutomationDetail(await transport.request("automations/show", { id, targetRevision }, { signal })),
  );
  const mutation = useMutation(transport, `automation:${id}`);
  const [error, setError] = useState<string>();
  return (
    <div>
      <h3>Restore preview · Revision {targetRevision}</h3>
      <ReadStatus {...snapshot} />
      {snapshot.value && (
        <>
          <pre>{JSON.stringify({ ...snapshot.value.definition, enabled: false }, null, 2)}</pre>
          <p className="panel-muted">
            Restoring creates a new paused revision. Files and conversation context keep their current state.
          </p>
          <button
            type="button"
            disabled={!writable || snapshot.loading || Boolean(snapshot.error) || Boolean(mutation.pending)}
            onClick={() => {
              if (!snapshot.value) return;
              void mutation
                .run("automations/restore", {
                  id,
                  data: { ...snapshot.value.definition, enabled: false },
                  replaceDefinition: true,
                  requestId: crypto.randomUUID(),
                  expectedRevision: currentRevision,
                  targetRevision,
                })
                .then(saved)
                .catch((error) => setError(failure(error)));
            }}
          >
            Restore paused
          </button>
        </>
      )}
      {error && <p className="panel-error">{error}</p>}
    </div>
  );
}
function AutomationRun({ transport, id }: { transport: PanelProps["transport"]; id: string }) {
  const [offset, setOffset] = useState<number>();
  const [error, setError] = useState<string>();
  const run = useRead(`${transport.hostId}:run:${id}:${offset}`, async (signal) => {
    const value = automationValue(
      await transport.request(
        "automations/show",
        { id: `run/${id}`, ...(offset !== undefined ? { outputOffset: offset } : {}), outputLimit: 32768 },
        { signal },
      ),
    );
    if (identifier(value.id) !== id) throw new Error("The run response belongs to another run");
    return {
      state: string(value.state),
      output: optionalText(value.output),
      error: optionalText(value.error),
      coverage: value.output_coverage,
      imported: value.imported === true,
    };
  });
  const mutation = useMutation(transport, `run:${id}`);
  const coverage = record(run.value?.coverage);
  const nextOffset = coverage.next_offset;
  return (
    <section className="panel-card">
      <div className="panel-toolbar">
        <h3>Run {id}</h3>
        <button type="button" onClick={run.refresh}>
          Refresh run
        </button>
      </div>
      <ReadStatus {...run} />
      {run.value && (
        <>
          <p>{run.value.state}</p>
          {run.value.output !== undefined ? (
            <pre>{run.value.output}</pre>
          ) : (
            <p className="panel-muted">Output is unavailable.</p>
          )}
          {run.value.error && <p className="panel-error">{run.value.error}</p>}
          <div className="panel-actions">
            <button type="button" onClick={() => setOffset(0)}>
              Beginning
            </button>
            <button type="button" onClick={() => setOffset(undefined)}>
              Latest
            </button>
            {typeof nextOffset === "number" && Number.isSafeInteger(nextOffset) && nextOffset >= 0 && (
              <button type="button" onClick={() => setOffset(nextOffset)}>
                Next output page
              </button>
            )}
            {!run.value.imported && ["queued", "running", "uncertain"].includes(run.value.state) && (
              <button
                type="button"
                disabled={Boolean(mutation.pending)}
                onClick={() => {
                  void mutation
                    .run("automations/run", { runId: id, cancel: true, requestId: crypto.randomUUID() })
                    .then(run.refresh)
                    .catch((error) => setError(failure(error)));
                }}
              >
                Cancel run
              </button>
            )}
          </div>
          {run.value.coverage == null && <p className="panel-muted">Output coverage is unknown.</p>}
        </>
      )}
      {error && <p className="panel-error">{error}</p>}
      <MutationStatus
        mutation={mutation}
        retry={() => {
          void mutation
            .retry()
            .then(run.refresh)
            .catch((error) => setError(failure(error)));
        }}
      />
    </section>
  );
}
