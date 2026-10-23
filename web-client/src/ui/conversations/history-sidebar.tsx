import {
  AlertCircle,
  ChevronDown,
  CircleCheck,
  History,
  MessageSquareText,
  Pin,
  Search,
  Settings,
  Trash2,
} from "lucide-react";
import { useEffect, useState } from "react";
import { targetKey } from "../../execution-context";
import type {
  ConversationSidebarRow,
  ConversationSidebarSection,
  UnsentDraftRow,
} from "../../workspace/conversation-sidebar-projection";
import { UsageRingsControl } from "../accounts/usage-rings";
import { ContextMenu, useContextMenu } from "../design-system/context-menu";
import { IconButton } from "../design-system/icon-button";
import { MenuItem } from "../design-system/menu";
import { ProviderMark } from "../design-system/provider-mark";
import type { SettingsTab } from "../settings/settings-dialog";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";
import { ActivityIndicator, ConversationRow } from "./conversation-row";
import { ConversationRowMenu } from "./conversation-row-menu";
import { NewChatButton } from "./new-chat-button";
import type { PinNameIntent } from "./pin-name-dialog";
import { ViewOptionsButton } from "./view-options";

const visibleDraftLimit = 3;

type Undo = Readonly<{ message: string; expiresAt: number; undo(): void }>;

export function HistorySidebar({
  hidden,
  onNavigate,
  openSettings,
  namePin,
}: {
  hidden: boolean;
  onNavigate(): void;
  openSettings(tab: SettingsTab): void;
  namePin(intent: PinNameIntent): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const snapshot = useSnapshot();
  const sidebar = snapshot.sidebar;
  const arrangement = workspace.drawerArrangement;
  const rowMenu = useContextMenu<ConversationSidebarRow>();
  const draftMenu = useContextMenu<UnsentDraftRow>();
  const [selection, setSelection] = useState<ReadonlySet<string>>();
  const [undo, setUndo] = useState<Undo>();
  const [draftsRevealed, setDraftsRevealed] = useState(false);
  useEffect(() => {
    if (hidden) return;
    workspace.openDrawer();
    const recapture = () => {
      if (document.visibilityState === "visible") workspace.openDrawer();
    };
    addEventListener("focus", recapture);
    document.addEventListener("visibilitychange", recapture);
    return () => {
      removeEventListener("focus", recapture);
      document.removeEventListener("visibilitychange", recapture);
      workspace.closeDrawer();
      setDraftsRevealed(false);
      setSelection(undefined);
    };
  }, [hidden, workspace]);
  useEffect(() => {
    if (!undo) return;
    const timer = setTimeout(() => setUndo(undefined), Math.max(0, undo.expiresAt - Date.now()));
    return () => clearTimeout(timer);
  }, [undo]);
  const rows = sidebar.sections.flatMap((section) => section.rows);
  const menuSubject = rowMenu.subject;
  const menuRow = menuSubject && rows.find((row) => row.id === menuSubject.id);
  useEffect(() => {
    if (menuSubject && !menuRow) rowMenu.surface.current?.hidePopover();
  }, [menuSubject, menuRow, rowMenu.surface]);
  const chosen = rows.filter((row) => selection?.has(row.id));
  const open = (row: ConversationSidebarRow) => {
    onNavigate();
    run(() => workspace.selectConversation(row.address));
  };
  const settle = (targets: readonly ConversationSidebarRow[]) =>
    run(() => {
      const undo = workspace.settleConversations(targets.map((row) => row.address));
      if (undo.count)
        setUndo({ ...undo, message: undo.count === 1 ? "Settled" : `Settled ${undo.count} chats` });
    });
  const activate = (row: ConversationSidebarRow) => {
    if (rowMenu.consumeHold()) return;
    if (!selection) return open(row);
    const next = new Set(selection);
    if (next.has(row.id)) next.delete(row.id);
    else next.add(row.id);
    setSelection(next);
  };
  const query = arrangement.query.trim();
  const drafts = query || draftsRevealed ? sidebar.drafts : sidebar.drafts.slice(0, visibleDraftLimit);
  const loading = sidebar.hostStates.some(
    (host) =>
      host.isLoading ||
      host.history === "unread" ||
      host.history === "loading" ||
      (arrangement.unreadOnly && (host.marksStatus === "unread" || host.marksStatus === "loading")),
  );
  const unloaded = sidebar.hostStates.some((host) => host.canLoadMore);
  const historyFailed = sidebar.hostStates.some((host) => host.history === "failed");
  const unreadUnknown = sidebar.hostStates.some((host) => host.marksStatus === "failed");
  const errors = sidebar.hostStates.filter((host) => host.errors.length);
  const showsHost = snapshot.hosts.length > 1;
  return (
    <aside className="sidebar" aria-label="Conversations" aria-hidden={hidden} inert={hidden}>
      <div className="sidebar-toolbar">
        <IconButton label="Settings" className="glass-button" onClick={() => openSettings("chat")}>
          <Settings size={19} />
        </IconButton>
        <ViewOptionsButton select={() => setSelection(new Set())} />
        <span className="toolbar-spacer" />
        <UsageRingsControl showAccounts={() => openSettings("accounts")} />
        <span className="toolbar-spacer" />
        {selection ? (
          <button type="button" className="glass-capsule" onClick={() => setSelection(undefined)}>
            Done
          </button>
        ) : (
          <NewChatButton className="glass-button" onStart={onNavigate} />
        )}
      </div>
      <label className="search">
        <Search size={15} />
        <input
          type="search"
          aria-label="Filter conversations"
          placeholder="Filter"
          value={arrangement.query}
          onChange={(event) => workspace.setDrawerQuery(event.target.value)}
        />
      </label>
      <nav className="history-list" aria-label="Conversation list">
        {!selection && drafts.length > 0 && (
          <>
            <h3 className="section-header">Drafts</h3>
            {drafts.map((draft) => (
              <DraftRow
                key={draft.key}
                draft={draft}
                selected={workspace.draftKey === draft.key}
                menuTrigger={draftMenu.triggerProps(draft)}
                onActivate={() => {
                  if (draftMenu.consumeHold()) return;
                  onNavigate();
                  run(() => workspace.selectDraft(draft.key));
                }}
              />
            ))}
            {drafts.length < sidebar.drafts.length && (
              <button type="button" className="show-more" onClick={() => setDraftsRevealed(true)}>
                Show {sidebar.drafts.length - drafts.length} more
              </button>
            )}
          </>
        )}
        {sidebar.sections.flatMap((section, index) => [
          <SectionHeader
            key={`header:${section.id}`}
            section={section}
            labelled={index > 0 || (!selection && drafts.length > 0)}
          />,
          ...section.rows.map((row) => (
            <ConversationRow
              key={row.id}
              row={row}
              chosen={selection ? selection.has(row.id) : undefined}
              onActivate={() => activate(row)}
              menuTrigger={selection ? {} : rowMenu.triggerProps(row)}
            />
          )),
          section.hiddenCount > 0 && <ShowMoreInSection key={`more:${section.id}`} section={section} />,
        ])}
        {!sidebar.sections.length && (
          <div className="empty-card">
            {loading ? (
              "Loading history…"
            ) : unloaded ? (
              "More history not loaded"
            ) : historyFailed ? (
              "History unavailable"
            ) : query ? (
              "No matching conversations"
            ) : arrangement.unreadOnly ? (
              <>
                {unreadUnknown ? <AlertCircle size={22} /> : <CircleCheck size={22} />}
                <strong>{unreadUnknown ? "Unread status unavailable" : "All caught up"}</strong>
              </>
            ) : (
              <>
                <MessageSquareText size={22} />
                <strong>No conversations yet</strong>
              </>
            )}
            {arrangement.unreadOnly && !loading && (
              <button
                type="button"
                className="show-more"
                onClick={() => workspace.setDrawerUnreadOnly(false)}
              >
                Show All Chats
              </button>
            )}
          </div>
        )}
        {errors.map((host) => (
          <div className="inline-error" key={targetKey(host.target)}>
            <AlertCircle size={16} />
            <span>
              {showsHost && <strong>{host.hostName}: </strong>}
              {host.errors.join(" ")}
            </span>
          </div>
        ))}
        {unloaded && (
          <button
            type="button"
            className="show-more load-history"
            onClick={() => {
              for (const host of sidebar.hostStates)
                if (host.canLoadMore) run(() => workspace.refreshHost(host.target, true));
            }}
          >
            Load older conversations
          </button>
        )}
      </nav>
      {selection ? (
        <SelectionBar
          rows={chosen}
          markRead={() =>
            run(() => {
              for (const row of chosen) workspace.markConversationRead(row.address);
              setSelection(undefined);
            })
          }
          settle={() => {
            settle(chosen.filter((row) => row.canSettle));
            setSelection(undefined);
          }}
          unsettle={() =>
            run(() => {
              for (const row of chosen) workspace.unsettleConversation(row.address);
              setSelection(undefined);
            })
          }
        />
      ) : (
        undo && (
          <div className="sidebar-status" role="status">
            <span>{undo.message}</span>
            <button
              type="button"
              className="show-more"
              onClick={() =>
                run(() => {
                  undo.undo();
                  setUndo(undefined);
                })
              }
            >
              Undo
            </button>
          </div>
        )
      )}
      <ContextMenu surface={rowMenu.surface}>
        {menuRow && (
          <ConversationRowMenu
            row={menuRow}
            open={() => open(menuRow)}
            namePin={namePin}
            settle={(row) => settle([row])}
          />
        )}
      </ContextMenu>
      <ContextMenu surface={draftMenu.surface}>
        {draftMenu.subject && (
          <MenuItem
            icon={<Trash2 size={16} />}
            onSelect={() => {
              const key = draftMenu.subject?.key;
              if (!key) return;
              run(() => {
                const undo = workspace.discardDraft(key);
                if (undo.count) setUndo({ ...undo, message: "Draft discarded" });
              });
            }}
          >
            Discard
          </MenuItem>
        )}
      </ContextMenu>
    </aside>
  );
}

function SectionHeader({ section, labelled }: { section: ConversationSidebarSection; labelled: boolean }) {
  const workspace = useWorkspace();
  const { summary } = section;
  const toggle = () => {
    const folded = summary.fold === "expanded";
    if (section.kind === "pinned") workspace.setPinnedFolded(folded);
    else if (section.kind === "automations") workspace.setAutomationsFolded(folded);
    else if (section.kind === "settled") workspace.setSettledFolded(folded);
    else workspace.setProjectFolded(section.id, folded);
  };
  const title = (
    <span className="section-title">
      {section.kind === "pinned" && <Pin size={14} />}
      {section.kind === "automations" && <History size={14} />}
      {section.kind === "settled" && <CircleCheck size={14} />}
      <span>{section.title}</span>
      {section.hostName && <small className="section-host">{section.hostName}</small>}
    </span>
  );
  const folded = summary.fold === "folded";
  if (section.kind === "chats") return labelled && <h3 className="section-header">Chats</h3>;
  if (summary.fold === "searching") return <h3 className="section-header">{title}</h3>;
  return (
    <button
      type="button"
      className={`section-header foldable ${folded ? "folded" : ""}`}
      aria-expanded={!folded}
      onClick={toggle}
    >
      {title}
      {folded && summary.liveActivity && summary.liveActivity !== "idle" && (
        <ActivityIndicator state={summary.liveActivity} labeled />
      )}
      {folded && (summary.unreadCount ?? 0) > 0 && (
        <span className="unread-dot" role="img" aria-label="Unread" />
      )}
      {folded && <span className="section-count">{summary.rowCount}</span>}
      <ChevronDown size={14} strokeWidth={3} className="section-chevron" />
    </button>
  );
}
function ShowMoreInSection({ section }: { section: ConversationSidebarSection }) {
  const workspace = useWorkspace();
  return (
    <button
      type="button"
      className="show-more"
      onClick={() =>
        section.kind === "settled"
          ? workspace.revealMoreSettled()
          : section.kind === "automations"
            ? workspace.revealAllAutomations()
            : workspace.revealProject(section.id)
      }
    >
      Show {section.hiddenCount} more
    </button>
  );
}

function DraftRow({
  draft,
  selected,
  menuTrigger,
  onActivate,
}: {
  draft: UnsentDraftRow;
  selected: boolean;
  menuTrigger: object;
  onActivate(): void;
}) {
  const snapshot = useSnapshot();
  const provider = snapshot.drafts.get(draft.key)?.provider;
  return (
    <button
      type="button"
      className={`history-row ${selected ? "selected" : ""}`}
      onClick={onActivate}
      {...menuTrigger}
    >
      <span className="history-row-content">
        <span className="history-meta">
          <span className="history-path">{draft.workingDirectory}</span>
          <span className="history-status">{provider && <ProviderMark provider={provider} />}</span>
        </span>
        <span className="history-row-top">
          <span className="history-title">{draft.text.trim().slice(0, 160) || "Attachments"}</span>
          <small className="history-age">Draft</small>
        </span>
      </span>
    </button>
  );
}

function SelectionBar({
  rows,
  markRead,
  settle,
  unsettle,
}: {
  rows: readonly ConversationSidebarRow[];
  markRead(): void;
  settle(): void;
  unsettle(): void;
}) {
  const unsettles = rows.length > 0 && rows.every((row) => row.settlement === "settled");
  const settleable = rows.filter((row) => row.canSettle).length;
  return (
    <div className="sidebar-status selection-bar">
      <span>{rows.length ? `${rows.length} selected` : "Select chats"}</span>
      <button type="button" className="show-more" disabled={!rows.length} onClick={markRead}>
        Mark Read
      </button>
      {unsettles ? (
        <button type="button" className="show-more" onClick={unsettle}>
          Unsettle {rows.length}
        </button>
      ) : (
        <button type="button" className="show-more" disabled={!settleable} onClick={settle}>
          {settleable ? `Settle ${settleable}` : "Settle"}
        </button>
      )}
    </div>
  );
}
