
import type { AbsolutePathBuf } from "../AbsolutePathBuf";
import type { ReasoningEffort } from "../ReasoningEffort";
import type { GitInfo } from "./GitInfo";
import type { SessionSource } from "./SessionSource";
import type { ThreadEnvironment } from "./ThreadEnvironment";
import type { ThreadExtra } from "./ThreadExtra";
import type { ThreadHistoryMode } from "./ThreadHistoryMode";
import type { ThreadSection } from "./ThreadSection";
import type { ThreadSource } from "./ThreadSource";
import type { ThreadStatus } from "./ThreadStatus";
import type { Turn } from "./Turn";

export type Thread = {

id: string,

environments: Array<ThreadEnvironment> | null,

extra: ThreadExtra | null,

sessionId: string,

forkedFromId: string | null,

parentThreadId: string | null,

preview: string,

ephemeral: boolean,

section: ThreadSection | null,

sectionEnteredAt: number | null,

projectId: string | null,

historyMode: ThreadHistoryMode,

modelProvider: string,

model: string | null,

reasoningEffort: ReasoningEffort | null,

createdAt: number,

updatedAt: number,

recencyAt: number | null,

status: ThreadStatus,

path: string | null,

cwd: AbsolutePathBuf,

cliVersion: string,

originator: string | null,

source: SessionSource,

canAcceptDirectInput: boolean | null,

threadSource: ThreadSource | null,

agentNickname: string | null,

agentRole: string | null,

gitInfo: GitInfo | null,

name: string | null,

daybreakEnabled: boolean | null,

turns: Array<Turn>, };
