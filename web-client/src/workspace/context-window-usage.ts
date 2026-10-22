import { object } from "../protocol/boundary";
export type ConversationTokenUsage = Readonly<{
  last: Readonly<{ totalTokens: number }>;
  total: Readonly<{ totalTokens: number }>;
  modelContextWindow: number | null;
}>;

export type ContextWindowUsage = Readonly<{
  usedTokens: number;
  contextWindow: number;
  usedFraction: number;
  usedPercent: number;
  level: "normal" | "amber" | "red";
}>;

export function contextWindowUsage(
  usage: ConversationTokenUsage | undefined,
): ContextWindowUsage | undefined {
  if (!usage || usage.modelContextWindow === null || usage.modelContextWindow <= 0) return undefined;
  const contextWindow = usage.modelContextWindow;
  const usedTokens = Math.min(contextWindow, Math.max(0, usage.last.totalTokens));
  const usedFraction = usedTokens / contextWindow;
  const usedPercent = Math.round(usedFraction * 100);
  return {
    usedTokens,
    contextWindow,
    usedFraction,
    usedPercent,
    level: usedPercent >= 90 ? "red" : usedPercent >= 75 ? "amber" : "normal",
  };
}

export function threadTokenUsage(value: unknown): ConversationTokenUsage {
  const record = object(value);
  const tokens = (value: unknown): ConversationTokenUsage["last"] => {
    const source = object(value);
    const number = (key: string) => {
      const value = source[key];
      if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error("Invalid token usage");
      return value;
    };
    return { totalTokens: number("totalTokens") };
  };
  const window = record.modelContextWindow;
  if (window != null && (typeof window !== "number" || !Number.isSafeInteger(window)))
    throw new Error("Invalid model context window");
  return {
    total: tokens(record.total),
    last: tokens(record.last),
    modelContextWindow: window == null ? null : Number(window),
  };
}
