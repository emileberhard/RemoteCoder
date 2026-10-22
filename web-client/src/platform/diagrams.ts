export type DiagramResult = Readonly<{
  svg: string;
  width: number;
  height: number;
  title?: string;
  description?: string;
}>;
export type DiagramState = Readonly<{
  status: "waiting" | "rendering" | "ready" | "failed";
  result?: DiagramResult;
  error?: string;
}>;
export type DiagramOptions = { dark?: boolean; signal?: AbortSignal };
type Subscriber = { resolve(value: DiagramResult): void; reject(error: unknown): void; detach(): void };
type Job = { key: string; source: string; dark: boolean; subscribers: Set<Subscriber> };
const encoder = new TextEncoder();
const canceled = () => new DOMException("Diagram rendering was canceled", "AbortError");
const svgNamespace = "http://www.w3.org/2000/svg";
const allowedElements = new Set(
  "svg g defs style title desc path line polyline polygon rect circle ellipse text tspan marker clipPath mask pattern linearGradient radialGradient stop use filter feBlend feColorMatrix feComponentTransfer feComposite feFlood feGaussianBlur feMerge feMergeNode feOffset feFuncA feFuncB feFuncG feFuncR".split(
    " ",
  ),
);
export function validateDiagramSource(source: string): void {
  if (!source.trim()) throw new Error("The diagram is empty");
  if (encoder.encode(source).byteLength > 32 * 1024) throw new Error("Diagram source exceeds 32 KiB");
  if (/\bimg\s*:|<\s*(?:img|image|script|iframe|object|embed)\b/i.test(source))
    throw new Error("Embedded media is unavailable in conversation diagrams");
}
function safeCss(value: string): boolean {
  if (/[@\\]|\/\*|(?:animation|transition)\s*:|expression\s*\(|javascript\s*:/i.test(value)) return false;
  for (const match of value.matchAll(/url\s*\(([^)]*)\)/gi))
    if (!/^\s*["']?#[\w:.-]+["']?\s*$/.test(match[1] ?? "")) return false;
  return true;
}
function staticCss(value: string): string {
  const result = value
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/@(?:-webkit-)?keyframes[^{}]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/gi, "")
    .replace(/(?:animation|transition)(?:-[\w-]+)?\s*:[^;}]+;?/gi, "");
  if (!safeCss(result)) throw new Error("Diagram styling contains an unsupported resource");
  return result;
}
export function sanitizeDiagram(svg: string): DiagramResult {
  if (encoder.encode(svg).byteLength > 2 * 1024 * 1024) throw new Error("Diagram output exceeds 2 MiB");
  if (/<!DOCTYPE|<!ENTITY/i.test(svg)) throw new Error("Diagram output contains an unsupported document");
  const parsed = new DOMParser().parseFromString(svg, "image/svg+xml");
  const root = parsed.documentElement;
  if (parsed.querySelector("parsererror") || root.localName !== "svg" || root.namespaceURI !== svgNamespace)
    throw new Error("Diagram output is unreadable");
  for (const element of [root, ...Array.from(root.querySelectorAll("*"))]) {
    if (element.namespaceURI !== svgNamespace || !allowedElements.has(element.localName)) {
      if (["image", "foreignObject"].includes(element.localName))
        throw new Error("Embedded media is unavailable in conversation diagrams");
      if (element.localName === "a") element.replaceWith(...Array.from(element.childNodes));
      else element.remove();
      continue;
    }
    if (element.localName === "style") element.textContent = staticCss(element.textContent ?? "");
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (
        name.startsWith("on") ||
        ((name === "href" || name === "xlink:href") && !/^#[\w:.-]+$/.test(attribute.value)) ||
        (name === "style" && !attribute.value)
      )
        element.removeAttribute(attribute.name);
      else if (name === "style") element.setAttribute(attribute.name, staticCss(attribute.value));
      else if (/url\s*\(/i.test(attribute.value) && !safeCss(attribute.value))
        throw new Error("Diagram output contains an external resource");
    }
  }
  const bounds = root
    .getAttribute("viewBox")
    ?.trim()
    .split(/[\s,]+/)
    .map(Number);
  const width = bounds?.[2] ?? Number.parseFloat(root.getAttribute("width") ?? "");
  const height = bounds?.[3] ?? Number.parseFloat(root.getAttribute("height") ?? "");
  if (![width, height].every((value) => Number.isFinite(value) && value > 0 && value <= 20000))
    throw new Error("Diagram dimensions are unavailable or exceed capacity");
  const title = root.querySelector("title")?.textContent?.slice(0, 512) || undefined;
  const description = root.querySelector("desc")?.textContent?.slice(0, 2048) || undefined;
  root.setAttribute("width", String(width));
  root.setAttribute("height", String(height));
  root.setAttribute("role", "img");
  if (!root.hasAttribute("aria-label") && !root.hasAttribute("aria-labelledby"))
    root.setAttribute("aria-label", title ?? "Conversation diagram");
  return Object.freeze({
    svg: new XMLSerializer().serializeToString(root),
    width,
    height,
    title,
    description,
  });
}
let runtime: Promise<typeof import("mermaid")> | undefined;
let renderId = 0;
let rendering: Promise<unknown> = Promise.resolve();
function renderDiagram(source: string, dark: boolean): Promise<DiagramResult> {
  const operation = rendering.then(() => drawDiagram(source, dark));
  rendering = operation.catch(() => undefined);
  return operation;
}
async function drawDiagram(source: string, dark: boolean): Promise<DiagramResult> {
  runtime ??= import("mermaid");
  const { default: mermaid } = await runtime;
  const configuration = {
    startOnLoad: false,
    securityLevel: "strict" as const,
    suppressErrorRendering: true,
    logLevel: 5 as const,
    maxTextSize: 32 * 1024,
    maxEdges: 250,
    htmlLabels: false,
    theme: dark ? ("dark" as const) : ("neutral" as const),
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif",
    layout: "dagre",
    flowchart: { htmlLabels: false, defaultRenderer: "dagre-wrapper", useMaxWidth: false },
  };
  mermaid.initialize({
    ...configuration,
    secure: [...Object.keys(configuration), "secure", "themeCSS", "themeVariables", "dompurifyConfig"],
  });
  const container = document.createElement("div");
  container.className = "diagram-render-owner";
  container.style.cssText =
    "position:absolute;left:-30000px;top:0;width:1200px;pointer-events:none;visibility:hidden";
  container.inert = true;
  container.setAttribute("aria-hidden", "true");
  document.body.append(container);
  try {
    const { svg } = await mermaid.render(`rc-diagram-${++renderId}`, source, container);
    return sanitizeDiagram(svg);
  } finally {
    container.remove();
  }
}
export class BrowserDiagramService {
  private readonly jobs = new Map<string, Job>();
  private readonly queue: Job[] = [];
  private readonly cache = new Map<string, { result: DiagramResult; bytes: number }>();
  private cacheBytes = 0;
  private subscribers = 0;
  private active = false;
  private retired = false;
  private mounts = 0;
  private readonly mounted = new Set<() => void>();
  constructor(private readonly renderer = renderDiagram) {}
  render(source: string, options: DiagramOptions = {}): Promise<DiagramResult> {
    try {
      validateDiagramSource(source);
      if (this.retired || options.signal?.aborted) throw canceled();
      const key = JSON.stringify([source, options.dark === true]);
      const cached = this.cache.get(key);
      if (cached) {
        this.cache.delete(key);
        this.cache.set(key, cached);
        return Promise.resolve(cached.result);
      }
      if (this.subscribers >= 64) throw new Error("Diagram rendering is busy. Try again.");
      let job = this.jobs.get(key);
      if (!job) {
        if (this.queue.length >= 16) throw new Error("Diagram rendering is busy. Try again.");
        job = { key, source, dark: options.dark === true, subscribers: new Set() };
        this.jobs.set(key, job);
        this.queue.push(job);
      }
      const captured = job;
      return new Promise((resolve, reject) => {
        const abort = () => {
          if (!captured.subscribers.delete(subscriber)) return;
          subscriber.detach();
          reject(canceled());
          if (!captured.subscribers.size) {
            const index = this.queue.indexOf(captured);
            if (index >= 0) {
              this.queue.splice(index, 1);
              this.jobs.delete(key);
            }
          }
        };
        const subscriber: Subscriber = {
          resolve,
          reject,
          detach: () => {
            this.subscribers -= 1;
            options.signal?.removeEventListener("abort", abort);
          },
        };
        this.subscribers += 1;
        captured.subscribers.add(subscriber);
        options.signal?.addEventListener("abort", abort, { once: true });
        void this.drain();
      });
    } catch (error) {
      return Promise.reject(error);
    }
  }
  private async drain(): Promise<void> {
    if (this.active || this.retired) return;
    this.active = true;
    try {
      while (this.queue.length && !this.retired) {
        const job = this.queue.shift();
        if (!job) break;
        try {
          const result = await this.renderer(job.source, job.dark);
          if (!this.retired && job.subscribers.size) {
            const bytes = encoder.encode(result.svg).byteLength + encoder.encode(job.key).byteLength;
            if (bytes <= 8 * 1024 * 1024) {
              this.cache.set(job.key, { result, bytes });
              this.cacheBytes += bytes;
              while (this.cache.size > 32 || this.cacheBytes > 8 * 1024 * 1024) {
                const oldest = this.cache.keys().next().value;
                if (oldest === undefined) break;
                this.cacheBytes -= this.cache.get(oldest)?.bytes ?? 0;
                this.cache.delete(oldest);
              }
            }
            for (const subscriber of job.subscribers) {
              subscriber.detach();
              subscriber.resolve(result);
            }
          }
        } catch {
          for (const subscriber of job.subscribers) {
            subscriber.detach();
            subscriber.reject(new Error("Diagram could not be rendered. View its source or try again."));
          }
        } finally {
          job.subscribers.clear();
          this.jobs.delete(job.key);
        }
      }
    } finally {
      this.active = false;
    }
  }
  mount(
    element: HTMLElement,
    source: string,
    options: { dark?: boolean; complete?: boolean; onState?(state: DiagramState): void } = {},
  ): { dispose(): void } {
    if (this.mounts >= 64 || this.retired) {
      options.onState?.({ status: "failed", error: "Too many visible diagrams. Open another conversation." });
      return { dispose() {} };
    }
    this.mounts += 1;
    let controller: AbortController | undefined;
    let disposed = false;
    let isVisible: boolean | undefined;
    const canvas = document.createElement("div");
    canvas.className = "browser-diagram-canvas";
    canvas.style.width = "100%";
    element.replaceChildren(canvas);
    const change = (state: DiagramState) => {
      if (!disposed) options.onState?.(state);
    };
    const visible = (value: boolean) => {
      if (isVisible === value) return;
      isVisible = value;
      controller?.abort();
      controller = undefined;
      canvas.replaceChildren();
      if (!value || options.complete === false || disposed) {
        change({ status: "waiting" });
        return;
      }
      const owner = new AbortController();
      controller = owner;
      change({ status: "rendering" });
      void this.render(source, { dark: options.dark, signal: owner.signal }).then(
        (result) => {
          if (disposed || owner.signal.aborted || controller !== owner) return;
          const parsed = new DOMParser().parseFromString(result.svg, "image/svg+xml");
          const illustration = document.importNode(parsed.documentElement, true) as unknown as SVGSVGElement;
          illustration.style.maxWidth = "100%";
          illustration.style.width = "100%";
          illustration.style.height = "auto";
          canvas.append(illustration);
          canvas.style.aspectRatio = `${result.width} / ${result.height}`;
          change({ status: "ready", result });
        },
        (error) => {
          if (disposed || owner.signal.aborted || controller !== owner) return;
          change({ status: "failed", error: error instanceof Error ? error.message : "Diagram failed" });
        },
      );
    };
    const observer = new IntersectionObserver((entries) => {
      const entry = entries.at(-1);
      if (entry) visible(entry.isIntersecting);
    });
    observer.observe(element);
    change({ status: "waiting" });
    const dispose = () => {
      if (disposed) return;
      disposed = true;
      this.mounts -= 1;
      this.mounted.delete(dispose);
      observer.disconnect();
      controller?.abort();
      element.replaceChildren();
    };
    this.mounted.add(dispose);
    return { dispose };
  }
  dispose(): void {
    if (this.retired) return;
    this.retired = true;
    for (const dispose of this.mounted) dispose();
    for (const job of this.jobs.values()) {
      for (const subscriber of job.subscribers) {
        subscriber.detach();
        subscriber.reject(canceled());
      }
      job.subscribers.clear();
    }
    this.jobs.clear();
    this.queue.length = 0;
    this.cache.clear();
    this.cacheBytes = 0;
  }
}
export const browserDiagrams = new BrowserDiagramService();
