import type { Rpc } from "../gateway";
import { array, object, string } from "../protocol/boundary";
import { failure } from "./load-state";

export type ProjectIdentity = Readonly<{
  cwd: string;
  kind: "remote" | "repository" | "directory";
  key: string;
  name: string;
  root: string;
}>;

export class ConversationProjects {
  private values: ReadonlyMap<string, ProjectIdentity> = new Map();
  private readonly controller = new AbortController();
  private read = 0;
  private errorValue?: string;
  constructor(
    private readonly rpc: Rpc,
    private readonly publish: () => void,
  ) {}
  get snapshot() {
    return this.values;
  }
  get error() {
    return this.errorValue;
  }
  async refresh(directories: readonly string[]) {
    const read = ++this.read;
    const requested = new Set(directories);
    if (requested.size > 500) throw new Error("Project resolution is limited to 500 directories");
    if (!requested.size) {
      if (this.values.size) {
        this.values = new Map();
        this.publish();
      }
      return;
    }
    try {
      const response = object(
        await this.rpc.call(
          "conversation/projects/resolve",
          { directories: [...requested] },
          { signal: this.controller.signal },
        ),
      );
      const values = new Map<string, ProjectIdentity>();
      for (const raw of array(response.projects, 500)) {
        const project = object(raw);
        const cwd = string(project.cwd);
        const kind = project.kind;
        if (
          !requested.has(cwd) ||
          values.has(cwd) ||
          !["remote", "repository", "directory"].includes(String(kind))
        )
          throw new Error("Invalid project resolution");
        values.set(cwd, {
          cwd,
          kind: kind as ProjectIdentity["kind"],
          key: string(project.key),
          name: string(project.name),
          root: string(project.root),
        });
      }
      if (this.controller.signal.aborted || this.read !== read) return;
      this.values = values;
      this.errorValue = undefined;
    } catch (error) {
      if (this.controller.signal.aborted || this.read !== read) return;
      this.values = new Map([...this.values].filter(([cwd]) => requested.has(cwd)));
      this.errorValue = failure(error);
    }
    this.publish();
  }
  dispose() {
    this.controller.abort();
  }
}
