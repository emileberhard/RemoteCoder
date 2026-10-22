import {
  type PointerEvent,
  type ReactNode,
  type RefObject,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";

const holdDelay = 500;
const holdSlop = 8;

type Presentation<Subject> = Readonly<{ subject: Subject; x: number; y: number }>;
type Press<Subject> = {
  x: number;
  y: number;
  timer?: ReturnType<typeof setTimeout>;
  pending?: Presentation<Subject>;
  down: boolean;
  held: boolean;
};

export function useContextMenu<Subject>() {
  const surface = useRef<HTMLDivElement>(null);
  const [presentation, setPresentation] = useState<Presentation<Subject>>();
  const press = useRef<Press<Subject>>(undefined);
  useLayoutEffect(() => {
    const popover = surface.current;
    if (!presentation || !popover) return;
    if (!popover.matches(":popover-open")) popover.showPopover();
    const { offsetWidth: width, offsetHeight: height } = popover;
    popover.style.left = `${Math.max(8, Math.min(presentation.x, innerWidth - width - 8))}px`;
    popover.style.top = `${Math.max(8, Math.min(presentation.y, innerHeight - height - 8))}px`;
  }, [presentation]);
  useEffect(() => {
    const popover = surface.current;
    if (!popover) return;
    const toggled = (event: Event) => {
      if ((event as ToggleEvent).newState === "closed") setPresentation(undefined);
    };
    popover.addEventListener("toggle", toggled);
    return () => popover.removeEventListener("toggle", toggled);
  }, []);
  const release = () => {
    const current = press.current;
    if (!current) return;
    current.down = false;
    clearTimeout(current.timer);
    const pending = current.pending;
    current.pending = undefined;
    if (pending) setTimeout(() => setPresentation(pending));
  };
  const triggerProps = (subject: Subject) => ({
    onContextMenu(event: { preventDefault(): void; clientX: number; clientY: number }) {
      event.preventDefault();
      const presentation = { subject, x: event.clientX, y: event.clientY };
      const current = press.current;
      if (current?.down) {
        clearTimeout(current.timer);
        current.held = true;
        current.pending = presentation;
      } else setPresentation(presentation);
    },
    onPointerDown(event: PointerEvent) {
      const { clientX: x, clientY: y } = event;
      const current: Press<Subject> = { x, y, down: true, held: false };
      if (event.pointerType === "touch")
        current.timer = setTimeout(() => {
          current.held = true;
          current.pending = { subject, x, y };
        }, holdDelay);
      press.current = current;
    },
    onPointerMove(event: PointerEvent) {
      const current = press.current;
      if (
        current?.down &&
        !current.held &&
        Math.hypot(event.clientX - current.x, event.clientY - current.y) > holdSlop
      )
        clearTimeout(current.timer);
    },
    onPointerUp: release,
    onPointerCancel: release,
  });
  const consumeHold = () => {
    const held = press.current?.held === true;
    press.current = undefined;
    return held;
  };
  return { surface, subject: presentation?.subject, triggerProps, consumeHold };
}

export function ContextMenu({
  surface,
  children,
}: {
  surface: RefObject<HTMLDivElement | null>;
  children: ReactNode;
}) {
  return (
    <div ref={surface} popover="auto" role="menu" className="menu-surface">
      {children}
    </div>
  );
}
