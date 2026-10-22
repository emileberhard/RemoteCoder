
import type { TokenUsageBreakdown } from "./TokenUsageBreakdown";

export type ThreadTokenUsage = { total: TokenUsageBreakdown, last: TokenUsageBreakdown, modelContextWindow: number | null, };
