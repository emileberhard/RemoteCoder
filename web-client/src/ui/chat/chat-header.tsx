import { ChevronDown, ChevronLeft, Menu as MenuLines, PanelLeft, PanelRight } from "lucide-react";
import type { HostState } from "../../workspace/host-services";
import { NewChatButton } from "../conversations/new-chat-button";
import { IconButton } from "../design-system/icon-button";
import { directoryTitle } from "../formatting";
import { useWorkspace } from "../workspace-context";
import type { ChatWindowActions } from "./chat-commands";

export function ChatHeader({
  host,
  compact,
  actions,
}: {
  host?: HostState;
  compact: boolean;
  actions: ChatWindowActions;
}) {
  const workspace = useWorkspace();
  const cwd = workspace.draft.cwd;
  return (
    <header className="chat-header">
      <div className="header-leading">
        {!compact && (
          <IconButton
            label={actions.title("toggleSidebar")}
            className="glass-button"
            onClick={() => actions.run("toggleSidebar")}
          >
            <PanelLeft size={19} />
          </IconButton>
        )}
        {actions.isEnabled("returnToParent") ? (
          <IconButton
            label="Return to parent conversation"
            className="glass-button"
            onClick={() => actions.run("returnToParent")}
          >
            <ChevronLeft size={20} />
          </IconButton>
        ) : (
          compact && (
            <IconButton
              label="Conversations"
              className="glass-button"
              onClick={() => actions.run("toggleSidebar")}
            >
              <MenuLines size={20} />
            </IconButton>
          )
        )}
      </div>
      <button
        type="button"
        className="directory-button"
        onClick={() => actions.run("chooseFolder")}
        disabled={!actions.isEnabled("chooseFolder")}
      >
        <span className="directory-path">
          <strong>
            {cwd ? directoryTitle(cwd, host && workspace.homePath(host.host.id)) : "Choose Folder"}
          </strong>
          <ChevronDown size={14} strokeWidth={2.4} />
        </span>
        <small>{host?.host.name ?? "No host configured"}</small>
      </button>
      <div className="header-actions">
        <NewChatButton onStart={() => undefined} />
        {!compact && (
          <IconButton
            label={actions.title("toggleInspector")}
            onClick={() => actions.run("toggleInspector")}
            disabled={!actions.isEnabled("toggleInspector")}
          >
            <PanelRight size={19} />
          </IconButton>
        )}
      </div>
    </header>
  );
}
