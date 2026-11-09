import { useState } from "react";
import type { Address } from "../../protocol/boundary";
import { Dialog } from "../design-system/dialog";
import { useRun, useWorkspace } from "../workspace-context";

export type ChatRename = Readonly<{ address: Address; name: string }>;

export function ChatRenameDialog({ rename, close }: { rename: ChatRename; close(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [name, setName] = useState(rename.name);
  const normalized = name.trim();
  return (
    <Dialog title="Rename chat" close={close}>
      <form
        className="settings-form"
        onSubmit={(event) => {
          event.preventDefault();
          if (!normalized) return;
          run(() => workspace.renameConversation(rename.address, normalized));
          close();
        }}
      >
        <input
          aria-label="Conversation name"
          placeholder="Conversation name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          autoFocus
        />
        <button type="submit" className="primary" disabled={!normalized}>
          Rename
        </button>
      </form>
    </Dialog>
  );
}
