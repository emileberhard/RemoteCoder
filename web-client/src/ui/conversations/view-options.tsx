import {
  CircleCheck,
  Folder,
  FoldVertical,
  ListFilter,
  ListOrdered,
  type LucideIcon,
  MailOpen,
  MailWarning,
  UnfoldVertical,
} from "lucide-react";
import type { ConversationDrawerMode } from "../../workspace/conversation-drawer-preferences";
import { useAnchoredPopover } from "../design-system/anchored-popover";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";

const modes: readonly { mode: ConversationDrawerMode; title: string; Icon: LucideIcon }[] = [
  { mode: "priority", title: "Priority", Icon: ListOrdered },
  { mode: "projects", title: "Projects", Icon: Folder },
];

export function ViewOptionsButton({ select }: { select(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const snapshot = useSnapshot();
  const { id, trigger, surface } = useAnchoredPopover("start");
  const arrangement = workspace.drawerArrangement;
  const foldable = snapshot.sidebar.sections.filter((section) => section.kind !== "chats");
  const allFolded = foldable.length > 0 && foldable.every((section) => section.summary.fold === "folded");
  const close = () => surface.current?.hidePopover();
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className={`icon-button glass-button ${arrangement.unreadOnly ? "selected" : ""}`}
        title="View Options"
        aria-label="View Options"
        aria-description={arrangement.unreadOnly ? "Unread only" : undefined}
        popoverTarget={id}
      >
        <ListFilter size={19} />
      </button>
      <div
        ref={surface}
        id={id}
        popover="auto"
        className="popover-surface view-options"
        role="dialog"
        aria-label="View Options"
      >
        <div className="mode-tiles">
          {modes.map(({ mode, title, Icon }) => (
            <button
              key={mode}
              type="button"
              className={`mode-tile ${arrangement.mode === mode ? "selected" : ""}`}
              aria-pressed={arrangement.mode === mode}
              onClick={() => arrangement.mode !== mode && run(() => workspace.setDrawerMode(mode))}
            >
              <Icon size={22} strokeWidth={2.2} />
              <span>{title}</span>
            </button>
          ))}
        </div>
        <label className="switch-row">
          <MailWarning size={17} />
          <span>Unread Only</span>
          <input
            type="checkbox"
            role="switch"
            className="switch"
            checked={arrangement.unreadOnly}
            aria-checked={arrangement.unreadOnly}
            onChange={(event) => workspace.setDrawerUnreadOnly(event.target.checked)}
          />
        </label>
        <hr />
        <div className="option-rows">
          <button
            type="button"
            onClick={() => {
              close();
              select();
            }}
          >
            <CircleCheck size={17} />
            Select…
          </button>
          <button type="button" onClick={() => run(() => workspace.markAllRead())}>
            <MailOpen size={17} />
            Mark All as Read
          </button>
          {foldable.length > 0 && !arrangement.query.trim() && (
            <button type="button" onClick={() => workspace.setAllSectionsFolded(!allFolded)}>
              {allFolded ? <UnfoldVertical size={17} /> : <FoldVertical size={17} />}
              {allFolded ? "Expand All" : "Collapse All"}
            </button>
          )}
        </div>
      </div>
    </>
  );
}
