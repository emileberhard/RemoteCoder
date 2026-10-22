
import type { Turn } from "./Turn";

export type ThreadTurnsListResponse = { data: Array<Turn>,

nextCursor: string | null,

backwardsCursor: string | null, };
