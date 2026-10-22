import { useEffect, useId, useRef } from "react";

export function useAnchoredPopover(align: "start" | "center" | "end") {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const surface = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const popover = surface.current;
    const anchor = trigger.current;
    if (!popover || !anchor) return;
    const place = (event: Event) => {
      if ((event as ToggleEvent).newState !== "open") return;
      const bounds = anchor.getBoundingClientRect();
      const width = popover.offsetWidth;
      const left =
        align === "end"
          ? bounds.right - width
          : align === "center"
            ? bounds.left + bounds.width / 2 - width / 2
            : bounds.left;
      const height = popover.offsetHeight;
      const below = bounds.bottom + 6;
      const top = below + height <= innerHeight - 8 ? below : Math.max(8, bounds.top - 6 - height);
      popover.style.left = `${Math.max(8, Math.min(left, innerWidth - width - 8))}px`;
      popover.style.top = `${top}px`;
    };
    popover.addEventListener("toggle", place);
    return () => popover.removeEventListener("toggle", place);
  }, [align]);
  return { id, trigger, surface };
}
