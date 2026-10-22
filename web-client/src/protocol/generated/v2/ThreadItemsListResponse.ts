
import type { ThreadItemEntry } from "./ThreadItemEntry";

export type ThreadItemsListResponse = { data: Array<ThreadItemEntry>,

nextCursor: string | null,

backwardsCursor: string | null, };
