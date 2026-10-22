import { SquarePen } from "lucide-react";
import { IconButton } from "../design-system/icon-button";
import { Menu, MenuChoice } from "../design-system/menu";
import { useSnapshot, useWorkspace } from "../workspace-context";

export function NewChatButton({ onStart, className }: { onStart(): void; className?: string }) {
  const workspace = useWorkspace();
  const { hosts, selectedHostId } = useSnapshot();
  const start = () => {
    workspace.newConversation();
    onStart();
  };
  if (hosts.length < 2)
    return (
      <IconButton label="New chat" className={className} onClick={start}>
        <SquarePen size={19} />
      </IconButton>
    );
  return (
    <Menu
      label="New chat (hold to choose a host)"
      icon={<SquarePen size={19} />}
      className={className}
      primaryAction={start}
    >
      {hosts.map((state) => (
        <MenuChoice
          key={state.host.id}
          selected={state.host.id === selectedHostId}
          onSelect={() => {
            workspace.selectHost(state.host.id);
            onStart();
          }}
        >
          {state.host.name}
        </MenuChoice>
      ))}
    </Menu>
  );
}
