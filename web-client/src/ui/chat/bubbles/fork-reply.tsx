import { GitBranch } from "lucide-react";
import { useState } from "react";
import type { Address } from "../../../protocol/boundary";
import { IconButton } from "../../design-system/icon-button";
import { useRun, useWorkspace } from "../../workspace-context";

export function ForkReply({ address, turnId }: { address: Address; turnId: string }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [pending, setPending] = useState(false);
  return (
    <IconButton
      label="Fork from here"
      disabled={pending}
      onClick={() => {
        if (pending) return;
        setPending(true);
        run(async () => {
          try {
            await workspace.forkFrom(address, turnId);
          } finally {
            setPending(false);
          }
        });
      }}
    >
      <GitBranch size={15} />
    </IconButton>
  );
}
