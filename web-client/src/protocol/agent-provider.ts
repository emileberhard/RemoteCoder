import type { Provider } from "./boundary";
export function providerForThread(threadId: string): Provider {
  return threadId.startsWith("claude_") ? "claude" : "codex";
}
