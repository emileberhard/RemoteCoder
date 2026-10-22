import type { Frame } from "../protocol/boundary";

export type FeatureTransport = {
  hostId: string;
  hostName: string;
  request(
    method: string,
    params?: unknown,
    options?: { signal?: AbortSignal; timeout?: number },
  ): Promise<unknown>;
  subscribe(listener: (frame: Frame) => void): () => void;
};

export type VoiceHistoryItem = { role: "user" | "assistant" | "developer"; text: string };
export type VoiceContext = {
  conversationThreadId: string;
  cwd: string;
  model: string;
  effort?: string | null;
  voice?: string;
  initialItems: VoiceHistoryItem[];
};

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "The browser service failed";
}

export function canceled(): DOMException {
  return new DOMException("Canceled", "AbortError");
}

export function isCanceled(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Unreadable service response");
  return value as Record<string, unknown>;
}

export function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`Missing ${name}`);
  return value;
}

export function boundedVoiceHistory(items: VoiceHistoryItem[]): VoiceHistoryItem[] {
  const result: VoiceHistoryItem[] = [];
  const encoder = new TextEncoder();
  let estimatedTokens = 0;
  for (const item of items.slice(-128).reverse()) {
    const text = item.text.trim();
    if (!text) continue;
    const size = Math.ceil(encoder.encode(text).byteLength / 4);
    if (estimatedTokens + size > 8192) break;
    estimatedTokens += size;
    result.unshift({ role: item.role, text });
  }
  return result;
}
