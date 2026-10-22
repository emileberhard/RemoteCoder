export type MarkdownBlocks = Readonly<{ revision: number; blocks: readonly string[]; error?: string }>;
export class MarkdownRendering {
  private readonly worker = new Worker(new URL("/markdown.worker.js", location.href), { type: "module" });
  private readonly entries = new Map<
    string,
    { revision: number; generation: number; settled: string[]; result: MarkdownBlocks }
  >();
  private generation = 0;
  constructor(private readonly changed: (id: string, result: MarkdownBlocks) => void) {
    this.worker.addEventListener("message", ({ data }) => {
      const entry = this.entries.get(data.id);
      if (!entry || data.generation !== entry.generation) return;
      if (data.error)
        entry.result = { revision: data.revision, blocks: entry.result.blocks, error: data.error };
      else if (data.final) {
        entry.settled = data.final;
        entry.result = { revision: data.revision, blocks: data.final };
      } else {
        entry.settled = [...entry.settled.slice(0, data.offset), ...data.added];
        entry.result = { revision: data.revision, blocks: [...entry.settled, ...data.tail] };
      }
      if (data.revision === entry.revision) this.changed(data.id, entry.result);
    });
  }
  append(id: string, delta: string, revision: number, source?: string) {
    const entry = this.entries.get(id);
    if (!entry) {
      if (source !== undefined) this.update(id, source, revision, false);
      return;
    }
    entry.revision = revision;
    this.worker.postMessage({ id, generation: entry.generation, revision, delta });
  }
  update(id: string, source: string, revision: number, complete: boolean) {
    const previous = this.entries.get(id);
    if (previous?.revision === revision) return;
    if (!previous && this.entries.size >= 64) {
      const oldest = this.entries.keys().next().value;
      if (oldest) this.remove(oldest);
    }
    const generation = ++this.generation;
    this.entries.set(id, {
      revision,
      generation,
      settled: [],
      result: previous?.result ?? { revision, blocks: [] },
    });
    this.worker.postMessage({ id, generation, revision, delta: source, reset: true, complete });
  }
  remove(id: string) {
    this.entries.delete(id);
    this.worker.postMessage({ id, remove: true });
  }
  dispose() {
    this.worker.terminate();
    this.entries.clear();
  }
}
