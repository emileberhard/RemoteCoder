import {
  CircleCheck,
  Copy,
  Link,
  Mail,
  MailOpen,
  MessageSquareText,
  Pencil,
  Pin,
  PinOff,
  Undo2,
  WandSparkles,
} from "lucide-react";
import { codexDesktopLink } from "../../protocol/boundary";
import type { ConversationSidebarRow } from "../../workspace/conversation-sidebar-projection";
import { chatCommands } from "../chat/chat-commands";
import { MenuItem } from "../design-system/menu";
import { useRun, useWorkspace } from "../workspace-context";
import type { PinNameIntent } from "./pin-name-dialog";

export function ConversationRowMenu({
  row,
  open,
  namePin,
  settle,
}: {
  row: ConversationSidebarRow;
  open(): void;
  namePin(intent: PinNameIntent): void;
  settle(row: ConversationSidebarRow): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const { address } = row;
  const link = codexDesktopLink(address);
  const ForkIcon = chatCommands.fork.Icon;
  return (
    <>
      <MenuItem icon={<MessageSquareText size={16} />} onSelect={open}>
        Open conversation
      </MenuItem>
      {row.isPinned ? (
        <>
          <MenuItem
            icon={<Pencil size={16} />}
            onSelect={() => namePin({ kind: "rename", address, name: row.title })}
          >
            Rename
          </MenuItem>
          <MenuItem
            icon={<PinOff size={16} />}
            onSelect={() => run(() => workspace.unpinConversation(address))}
          >
            Unpin
          </MenuItem>
        </>
      ) : (
        <>
          <MenuItem
            icon={<Pin size={16} />}
            disabled={row.isPinned === null}
            onSelect={() => namePin({ kind: "pin", address, name: "" })}
          >
            Pin
          </MenuItem>
          <MenuItem
            icon={<WandSparkles size={16} />}
            onSelect={() => run(() => workspace.regenerateTitle(address))}
          >
            Regenerate Name
          </MenuItem>
        </>
      )}
      {row.isUnread ? (
        <MenuItem
          icon={<MailOpen size={16} />}
          onSelect={() => run(() => workspace.markConversationRead(address))}
        >
          Mark as Read
        </MenuItem>
      ) : (
        <MenuItem
          icon={<Mail size={16} />}
          disabled={row.isUnread === null}
          onSelect={() => run(() => workspace.markConversationUnread(address))}
        >
          Mark as Unread
        </MenuItem>
      )}
      <MenuItem icon={<ForkIcon size={16} />} onSelect={() => run(() => workspace.fork(address))}>
        Fork
      </MenuItem>
      {row.settlement === "settled" ? (
        <MenuItem
          icon={<Undo2 size={16} />}
          onSelect={() => run(() => workspace.unsettleConversation(address))}
        >
          Unsettle
        </MenuItem>
      ) : (
        row.canSettle && (
          <MenuItem icon={<CircleCheck size={16} />} onSelect={() => settle(row)}>
            Settle
          </MenuItem>
        )
      )}
      {link ? (
        <MenuItem icon={<Link size={16} />} onSelect={() => run(() => navigator.clipboard.writeText(link))}>
          Copy link
        </MenuItem>
      ) : (
        <MenuItem
          icon={<Copy size={16} />}
          onSelect={() => run(() => navigator.clipboard.writeText(address.threadId))}
        >
          Copy thread ID
        </MenuItem>
      )}
    </>
  );
}
