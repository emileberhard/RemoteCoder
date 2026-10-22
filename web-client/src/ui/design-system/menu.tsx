import { Check } from "lucide-react";
import { type ReactNode, useRef } from "react";
import { useAnchoredPopover } from "./anchored-popover";

const holdDelay = 450;

export function Menu({
  label,
  icon,
  children,
  className = "",
  align = "end",
  primaryAction,
}: {
  label: string;
  icon: ReactNode;
  children: ReactNode;
  className?: string;
  align?: "start" | "end";
  primaryAction?: () => void;
}) {
  const { id, trigger, surface } = useAnchoredPopover(align);
  const hold = useRef<{ timer: ReturnType<typeof setTimeout>; opened: boolean }>(undefined);
  const open = () => surface.current?.showPopover();
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className={`icon-button ${className}`}
        title={label}
        aria-label={label}
        aria-haspopup="menu"
        popoverTarget={primaryAction ? undefined : id}
        onClick={(event) => {
          if (!primaryAction) return;
          if (hold.current?.opened) event.preventDefault();
          else primaryAction();
          hold.current = undefined;
        }}
        onPointerDown={() => {
          if (!primaryAction) return;
          const state = {
            opened: false,
            timer: setTimeout(() => {
              state.opened = true;
              open();
            }, holdDelay),
          };
          hold.current = state;
        }}
        onPointerUp={() => clearTimeout(hold.current?.timer)}
        onPointerLeave={() => clearTimeout(hold.current?.timer)}
        onContextMenu={(event) => {
          if (!primaryAction) return;
          event.preventDefault();
          clearTimeout(hold.current?.timer);
          open();
        }}
        onKeyDown={(event) => {
          if (primaryAction && event.key === "ArrowDown") {
            event.preventDefault();
            open();
          }
        }}
      >
        {icon}
      </button>
      <div ref={surface} id={id} popover="auto" role="menu" className="menu-surface">
        {children}
      </div>
    </>
  );
}
const closeMenu = (element: HTMLElement) => element.closest<HTMLElement>("[popover]")?.hidePopover();

export function MenuItem({
  icon,
  children,
  onSelect,
  disabled,
}: {
  icon?: ReactNode;
  children: ReactNode;
  onSelect(): void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      disabled={disabled}
      onClick={(event) => {
        closeMenu(event.currentTarget);
        onSelect();
      }}
    >
      {icon}
      <span>{children}</span>
    </button>
  );
}
export function MenuChoice({
  children,
  selected,
  onSelect,
  disabled,
}: {
  children: ReactNode;
  selected: boolean;
  onSelect(): void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="menuitemradio"
      aria-checked={selected}
      disabled={disabled}
      onClick={(event) => {
        closeMenu(event.currentTarget);
        onSelect();
      }}
    >
      <Check size={15} className="menu-check" />
      <span>{children}</span>
    </button>
  );
}
