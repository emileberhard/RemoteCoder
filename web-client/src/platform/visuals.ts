export type VisualTheme = Readonly<Record<string, string>>;
type Visual = {
  block: HTMLElement;
  root: Element | null;
  url: string;
  title: string;
  height: number;
  near: boolean;
  onscreen: boolean;
  frame?: HTMLIFrameElement;
};
type Watch = { root: Element | null; near: IntersectionObserver; onscreen: IntersectionObserver };

const liveLimit = 8;

export class BrowserVisualFrames {
  private readonly visuals = new Set<Visual>();
  private watch?: Watch;
  private theme: VisualTheme = {};
  private listening = false;
  private reconciling?: ReturnType<typeof setTimeout>;

  mount(block: HTMLElement, url: string, title: string): { dispose(): void } {
    const root = block.closest(".transcript");
    const visual: Visual = { block, root, url, title, height: 160, near: false, onscreen: false };
    this.visuals.add(visual);
    block.style.height = `${visual.height}px`;
    const watch = this.observe(root);
    watch.near.observe(block);
    watch.onscreen.observe(block);
    this.listen();
    return {
      dispose: () => {
        if (!this.visuals.delete(visual)) return;
        watch.near.unobserve(block);
        watch.onscreen.unobserve(block);
        if (!this.visuals.size && this.watch === watch) {
          watch.near.disconnect();
          watch.onscreen.disconnect();
          this.watch = undefined;
        }
        this.release(visual);
        block.style.height = "";
        this.schedule();
      },
    };
  }

  setTheme(theme: VisualTheme): void {
    this.theme = theme;
    for (const visual of this.visuals) {
      if (!visual.frame) continue;
      visual.frame.style.colorScheme = theme["--rc-color-scheme"] ?? "light";
      visual.frame.contentWindow?.postMessage({ rcVisualTheme: theme }, "*");
    }
  }

  private observe(root: Element | null): Watch {
    if (this.watch?.root === root) return this.watch;
    this.watch?.near.disconnect();
    this.watch?.onscreen.disconnect();
    const observer = (key: "near" | "onscreen", rootMargin: string) =>
      new IntersectionObserver(
        (entries) => {
          for (const entry of entries)
            for (const visual of this.visuals)
              if (visual.block === entry.target) visual[key] = entry.isIntersecting;
          this.schedule();
        },
        { root, rootMargin },
      );
    this.watch = { root, near: observer("near", "100% 0px"), onscreen: observer("onscreen", "0px") };
    return this.watch;
  }

  private schedule(): void {
    if (this.reconciling !== undefined) return;
    this.reconciling = setTimeout(() => {
      this.reconciling = undefined;
      this.reconcile();
    });
  }

  private reconcile(): void {
    const all = [...this.visuals];
    const wanted = new Set(
      [
        ...all.filter((visual) => visual.onscreen),
        ...all.filter((visual) => visual.near && !visual.onscreen),
      ].slice(0, liveLimit),
    );
    for (const visual of all) if (!wanted.has(visual)) this.release(visual);
    for (const visual of wanted) if (!visual.frame) this.create(visual);
  }

  private create(visual: Visual): void {
    const frame = document.createElement("iframe");
    frame.className = "html-visual-frame";
    frame.title = visual.title;
    frame.referrerPolicy = "no-referrer";
    frame.style.height = `${visual.height}px`;
    frame.style.colorScheme = this.theme["--rc-color-scheme"] ?? "light";
    frame.setAttribute("sandbox", "allow-scripts allow-popups allow-popups-to-escape-sandbox");
    const source = new URL(visual.url, location.href);
    source.searchParams.set("theme", JSON.stringify(this.theme));
    frame.src = `${source.pathname}${source.search}`;
    visual.frame = frame;
    visual.block.replaceChildren(frame);
    visual.block.style.height = "";
  }

  private release(visual: Visual): void {
    if (!visual.frame) return;
    visual.frame = undefined;
    visual.block.replaceChildren();
    visual.block.style.height = `${visual.height}px`;
  }

  private listen(): void {
    if (this.listening) return;
    this.listening = true;
    addEventListener("message", (event) => {
      const height = Number(event.data?.rcVisualHeight);
      if (!Number.isFinite(height)) return;
      for (const visual of this.visuals) {
        if (!visual.frame || visual.frame.contentWindow !== event.source) continue;
        visual.height = Math.min(Math.max(Math.ceil(height), 24), 20000);
        visual.frame.style.height = `${visual.height}px`;
        return;
      }
    });
  }
}

export const browserVisuals = new BrowserVisualFrames();
