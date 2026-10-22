
import type { ThreadItem } from "./ThreadItem";

export type ThreadItemEntry = {

startedAtOrdinal?: number, isComplete?: boolean,

turnId: string, item: ThreadItem,

startedAtMs: number | null,

completedAtMs: number | null, };
