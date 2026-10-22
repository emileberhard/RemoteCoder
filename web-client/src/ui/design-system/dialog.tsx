import { X } from "lucide-react";
import { type ReactNode, useEffect, useRef } from "react";
import { IconButton } from "./icon-button";

export function Dialog({
  title,
  close,
  children,
  wide = false,
}: {
  title: string;
  close(): void;
  children: ReactNode;
  wide?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal();
    return () => dialog?.close();
  }, []);
  return (
    <dialog ref={ref} className={`dialog ${wide ? "wide" : ""}`} onCancel={close}>
      <div className="dialog-header">
        <h2>{title}</h2>
        <IconButton label="Close" onClick={close}>
          <X size={19} />
        </IconButton>
      </div>
      {children}
    </dialog>
  );
}
