import { useState } from "react";
import type { Address } from "../../protocol/boundary";
import { normalizedPinName } from "../../workspace/conversation-marks";
import { Dialog } from "../design-system/dialog";
import { useRun, useWorkspace } from "../workspace-context";

export type PinNameIntent = Readonly<{ kind: "pin" | "rename"; address: Address; name: string }>;

export function PinNameDialog({ intent, close }: { intent: PinNameIntent; close(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [name, setName] = useState(intent.name);
  const normalized = normalizedPinName(name);
  return (
    <Dialog title={intent.kind === "pin" ? "Name this pinned chat" : "Rename pinned chat"} close={close}>
      <form
        className="settings-form"
        onSubmit={(event) => {
          event.preventDefault();
          if (!normalized) return;
          run(() => workspace.pinConversation(intent.address, normalized));
          close();
        }}
      >
        <p className="subtle">
          {intent.kind === "pin" ? "Pinned chats need a name." : "Update the pinned chat name."}
        </p>
        <input
          aria-label="Pinned chat name"
          placeholder="Pinned chat name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          autoFocus
        />
        <button type="submit" className="primary" disabled={!normalized}>
          {intent.kind === "pin" ? "Pin" : "Rename"}
        </button>
      </form>
    </Dialog>
  );
}
