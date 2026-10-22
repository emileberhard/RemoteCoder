import { IncrementalMarkdown } from "./markdown";

type Message = {
  id: string;
  revision: number;
  generation: number;
  delta: string;
  reset?: boolean;
  complete?: boolean;
  remove?: boolean;
};
const entries = new Map<
  string,
  {
    parser: IncrementalMarkdown;
    revision: number;
    generation: number;
    timer?: ReturnType<typeof setTimeout>;
    complete: boolean;
  }
>();
self.addEventListener("message", ({ data }: MessageEvent<Message>) => {
  if (data.remove) {
    const entry = entries.get(data.id);
    clearTimeout(entry?.timer);
    entries.delete(data.id);
    return;
  }
  if (data.reset) {
    clearTimeout(entries.get(data.id)?.timer);
    entries.delete(data.id);
  }
  if (!entries.has(data.id)) {
    if (entries.size >= 64) {
      const oldest = entries.keys().next().value;
      if (oldest) {
        clearTimeout(entries.get(oldest)?.timer);
        entries.delete(oldest);
      }
    }
    entries.set(data.id, {
      parser: new IncrementalMarkdown(),
      revision: data.revision,
      generation: data.generation,
      complete: false,
    });
  }
  const entry = entries.get(data.id);
  if (!entry) return;
  try {
    entry.parser.append(data.delta);
    entry.revision = data.revision;
    entry.complete = data.complete === true;
    const flush = () => {
      entry.timer = undefined;
      if (entry.complete)
        self.postMessage({
          id: data.id,
          generation: entry.generation,
          revision: entry.revision,
          final: entry.parser.finish(),
        });
      else
        self.postMessage({
          id: data.id,
          generation: entry.generation,
          revision: entry.revision,
          ...entry.parser.flush(),
        });
    };
    if (entry.complete) {
      clearTimeout(entry.timer);
      flush();
    } else if (!entry.timer) entry.timer = setTimeout(flush, 80);
  } catch (error) {
    self.postMessage({
      id: data.id,
      generation: entry.generation,
      revision: data.revision,
      error: error instanceof Error ? error.message : "Markdown rendering failed",
    });
  }
});
