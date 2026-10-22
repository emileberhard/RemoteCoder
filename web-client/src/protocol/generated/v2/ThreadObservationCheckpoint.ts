
import type { ThreadItemEntry } from "./ThreadItemEntry";
import type { Turn } from "./Turn";

export type ThreadObservationCheckpoint = {

turnsBackwardsCursor: string | null, itemsBackwardsCursor: string | null,

activeTurn: Turn | null,

liveItems: Array<ThreadItemEntry>,

historyUnavailable: boolean, };
