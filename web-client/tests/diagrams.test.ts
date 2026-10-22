import { afterEach, beforeEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import {
  BrowserDiagramService,
  type DiagramResult,
  sanitizeDiagram,
  validateDiagramSource,
} from "../src/platform/diagrams";

const svg =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 80"><title>Flow</title><path d="M0 0L20 20"/></svg>';
const result: DiagramResult = { svg, width: 160, height: 80, title: "Flow" };
const owners: BrowserDiagramService[] = [];
let window: Window;
const globals = new Map<string, PropertyDescriptor | undefined>();
function install(name: string, value: unknown) {
  globals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
beforeEach(() => {
  window = new Window({ settings: { disableJavaScriptEvaluation: true } });
  install("DOMParser", window.DOMParser);
  install("XMLSerializer", window.XMLSerializer);
  install("document", window.document);
});
afterEach(async () => {
  for (const owner of owners.splice(0)) owner.dispose();
  for (const [name, descriptor] of globals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
  globals.clear();
  await window.happyDOM.close();
});
test("static SVG keeps labels and geometry while removing navigation, executable content and events", () => {
  const sanitized = sanitizeDiagram(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 80" onload="evil()"><title>Flow</title><desc>Two hosts</desc><script>evil()</script><a href="https://example.com"><text onclick="evil()">Label</text></a><animate attributeName="x"/><path d="M0 0L20 20"/></svg>',
  );
  expect(sanitized).toMatchObject({ width: 160, height: 80, title: "Flow", description: "Two hosts" });
  expect(sanitized.svg).toContain("Label");
  expect(sanitized.svg).not.toMatch(/script|onload|onclick|https:\/\/example|animate/);
  const stationary = sanitizeDiagram(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 80"><style>/* Mermaid default */@keyframes dash {to {stroke-dashoffset:0;}}.edge {animation:dash 20s linear infinite;fill:red;}</style><path style="animation:dash 20s linear infinite;stroke:blue" d="M0 0L20 20"/></svg>',
  );
  expect(stationary.svg).not.toMatch(/keyframes|animation/);
  expect(stationary.svg).toContain("fill:red");
});
test("diagram resources, active styling, dimensions and source allocation have explicit boundaries", () => {
  expect(() => validateDiagramSource(`flowchart LR\n${"x".repeat(32768)}`)).toThrow("32 KiB");
  expect(() => validateDiagramSource('flowchart LR\nA@{img:"https://example.com/image"}')).toThrow(
    "Embedded media",
  );
  for (const child of [
    '<image href="https://example.com/image"/>',
    "<foreignObject><div>HTML</div></foreignObject>",
    '<style>@import "https://example.com/style";</style>',
    '<path fill="url(https://example.com/paint)"/>',
  ])
    expect(() =>
      sanitizeDiagram(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 80">${child}</svg>`),
    ).toThrow();
  expect(() => sanitizeDiagram(svg.replace("160 80", "40000 80"))).toThrow("dimensions");
  expect(() => sanitizeDiagram(`<!DOCTYPE svg>${svg}`)).toThrow("document");
});
test("equal requests share serial work and one canceled subscriber cannot cancel another", async () => {
  const pending = deferred<DiagramResult>();
  const calls: string[] = [];
  const owner = new BrowserDiagramService(async (source) => {
    calls.push(source);
    return source === "first" ? pending.promise : result;
  });
  owners.push(owner);
  const controller = new AbortController();
  const abandoned = owner.render("first", { signal: controller.signal });
  const surviving = owner.render("first");
  const next = owner.render("second");
  controller.abort();
  await expect(abandoned).rejects.toMatchObject({ name: "AbortError" });
  expect(calls).toEqual(["first"]);
  pending.resolve(result);
  expect(await surviving).toBe(result);
  await next;
  expect(calls).toEqual(["first", "second"]);
  await owner.render("first");
  expect(calls).toHaveLength(2);
});
test("queued work is bounded and abandonment removes it before execution", async () => {
  const pending = deferred<DiagramResult>();
  const calls: string[] = [];
  const owner = new BrowserDiagramService(async (source) => {
    calls.push(source);
    return source === "active" ? pending.promise : result;
  });
  owners.push(owner);
  const active = owner.render("active");
  const controller = new AbortController();
  const canceledRead = owner.render("abandoned", { signal: controller.signal });
  controller.abort();
  await expect(canceledRead).rejects.toMatchObject({ name: "AbortError" });
  const queued = Array.from({ length: 16 }, (_, index) => owner.render(`queued-${index}`));
  await expect(owner.render("overflow")).rejects.toThrow("busy");
  pending.resolve(result);
  await Promise.all([active, ...queued]);
  expect(calls).not.toContain("abandoned");
  expect(calls).not.toContain("overflow");
  expect(calls).toHaveLength(17);
});
test("cache eviction retains recent diagrams and distinguishes appearance", async () => {
  const calls: string[] = [];
  const owner = new BrowserDiagramService(async (source, dark) => {
    calls.push(`${source}:${dark}`);
    return result;
  });
  owners.push(owner);
  for (let index = 0; index < 33; index++) await owner.render(`source-${index}`);
  await owner.render("source-32");
  expect(calls).toHaveLength(33);
  await owner.render("source-0");
  await owner.render("source-32", { dark: true });
  expect(calls.slice(-2)).toEqual(["source-0:false", "source-32:true"]);
});
test("visibility and retirement own mounted SVG and fence a late render", async () => {
  let observed: ((visible: boolean) => void) | undefined;
  install(
    "IntersectionObserver",
    class {
      constructor(callback: IntersectionObserverCallback) {
        observed = (isIntersecting) =>
          callback(
            [{ isIntersecting } as IntersectionObserverEntry],
            this as unknown as IntersectionObserver,
          );
      }
      observe() {}
      disconnect() {}
    },
  );
  const pending = deferred<DiagramResult>();
  let count = 0;
  const owner = new BrowserDiagramService(async () => {
    count += 1;
    return pending.promise;
  });
  owners.push(owner);
  const element = window.document.createElement("div") as unknown as HTMLElement;
  const unfinished = owner.mount(element, "flowchart LR\nA-->", { complete: false });
  observed?.(true);
  expect(count).toBe(0);
  unfinished.dispose();
  const lifetime = owner.mount(element, "flowchart LR\nA-->B", { complete: true });
  expect(count).toBe(0);
  observed?.(true);
  expect(count).toBe(1);
  lifetime.dispose();
  pending.resolve(result);
  await Promise.resolve();
  await Promise.resolve();
  expect(element.children).toHaveLength(0);
  const visible = owner.mount(element, "flowchart LR\nA-->B", { complete: true });
  observed?.(true);
  for (let index = 0; index < 5; index++) await Promise.resolve();
  expect(element.querySelector("svg")).not.toBeNull();
  expect(element.style.aspectRatio).toBe("");
  expect((element.firstElementChild as HTMLElement).style.aspectRatio).toBe(
    `${result.width} / ${result.height}`,
  );
  element.style.padding = "18px";
  expect(element.firstElementChild?.className).toBe("browser-diagram-canvas");
  observed?.(false);
  expect(element.querySelector("svg")).toBeNull();
  expect((element.firstElementChild as HTMLElement).style.aspectRatio).toBe(
    `${result.width} / ${result.height}`,
  );
  observed?.(true);
  for (let index = 0; index < 5; index++) await Promise.resolve();
  expect(element.querySelector("svg")).not.toBeNull();
  owner.dispose();
  expect(element.children).toHaveLength(0);
  visible.dispose();
});
