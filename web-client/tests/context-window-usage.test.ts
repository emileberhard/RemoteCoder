import { expect, test } from "bun:test";
import { contextWindowUsage, threadTokenUsage } from "../src/workspace/context-window-usage";

const usage = (last: number, window: number | null = 1000) => ({
  total: { totalTokens: 900000 },
  last: { totalTokens: last },
  modelContextWindow: window,
});
test("context usage uses the last request, rounds native thresholds and clamps", () => {
  expect(contextWindowUsage(usage(744))?.level).toBe("normal");
  expect(contextWindowUsage(usage(745))?.level).toBe("amber");
  expect(contextWindowUsage(usage(895))?.level).toBe("red");
  expect(contextWindowUsage(usage(2000))?.usedFraction).toBe(1);
  expect(contextWindowUsage(usage(-2))?.usedTokens).toBe(0);
  expect(contextWindowUsage(usage(0))?.usedPercent).toBe(0);
  expect(contextWindowUsage(usage(100, null))).toBeUndefined();
  expect(contextWindowUsage(usage(100, 0))).toBeUndefined();
  expect(threadTokenUsage(usage(100))).toEqual(usage(100));
  expect(() => threadTokenUsage(usage(Number.NaN))).toThrow("token usage");
});
