import { useState } from "react";
import type { Address } from "../../protocol/boundary";
import { normalizedPinName } from "../../workspace/conversation-marks";
import { Dialog } from "../design-system/dialog";
import { useRun, useWorkspace } from "../workspace-context";

export type PinnedChatRename = Readonly<{ address: Address; name: string }>;

export function PinnedChatRenameDialog({ rename, close }: { rename: PinnedChatRename; close(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [name, setName] = useState(rename.name);
  const normalized = normalizedPinName(name);
  return (
    <Dialog title="Rename pinned chat" close={close}>
      <form
        className="settings-form"
        onSubmit={(event) => {
          event.preventDefault();
          if (!normalized) return;
          run(() => workspace.pinConversation(rename.address, normalized));
          close();
        }}
      >
        <p className="subtle">Update the pinned chat name.</p>
        <input
          aria-label="Pinned chat name"
          placeholder="Pinned chat name"
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
