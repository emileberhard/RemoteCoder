import { Check, Copy } from "lucide-react";
import { useEffect, useState } from "react";
import { IconButton } from "../../design-system/icon-button";
import { useRun } from "../../workspace-context";

export function CopyButton({ text }: { text: string }) {
  const run = useRun();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <IconButton
      label={copied ? "Copied" : "Copy message"}
      onClick={() => run(() => navigator.clipboard.writeText(text).then(() => setCopied(true)))}
    >
      {copied ? <Check size={15} /> : <Copy size={15} />}
    </IconButton>
  );
}
