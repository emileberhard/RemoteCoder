
import type { FunctionCallOutputBody } from "../FunctionCallOutputBody";
import type { ImageGenerationItem } from "../ImageGenerationItem";
import type { LegacyAppPathString } from "../LegacyAppPathString";
import type { MessagePhase } from "../MessagePhase";
import type { ReasoningEffort } from "../ReasoningEffort";
import type { SleepItem } from "../SleepItem";
import type { WebSearchItem } from "../WebSearchItem";
import type { JsonValue } from "../serde_json/JsonValue";
import type { AgentMessageDelivery } from "./AgentMessageDelivery";
import type { AsyncUserInputQuestion } from "./AsyncUserInputQuestion";
import type { CollabAgentState } from "./CollabAgentState";
import type { CollabAgentTool } from "./CollabAgentTool";
import type { CollabAgentToolCallStatus } from "./CollabAgentToolCallStatus";
import type { CommandAction } from "./CommandAction";
import type { CommandExecutionSource } from "./CommandExecutionSource";
import type { CommandExecutionStatus } from "./CommandExecutionStatus";
import type { DynamicToolCallOutputContentItem } from "./DynamicToolCallOutputContentItem";
import type { DynamicToolCallStatus } from "./DynamicToolCallStatus";
import type { FileUpdateChange } from "./FileUpdateChange";
import type { HookPromptFragment } from "./HookPromptFragment";
import type { McpAppUi } from "./McpAppUi";
import type { McpToolCallAppContext } from "./McpToolCallAppContext";
import type { McpToolCallError } from "./McpToolCallError";
import type { McpToolCallResult } from "./McpToolCallResult";
import type { McpToolCallStatus } from "./McpToolCallStatus";
import type { MemoryCitation } from "./MemoryCitation";
import type { PatchApplyStatus } from "./PatchApplyStatus";
import type { SubAgentActivityKind } from "./SubAgentActivityKind";
import type { UserInput } from "./UserInput";

export type ThreadItem = { "type": "userMessage", id: string, clientId: string | null, content: Array<UserInput>, } | { "type": "hookPrompt", id: string, fragments: Array<HookPromptFragment>, } | { "type": "agentMessage", id: string, text: string, phase: MessagePhase | null, memoryCitation: MemoryCitation | null, delivery: AgentMessageDelivery | null, questions: Array<AsyncUserInputQuestion> | null, } | { "type": "functionCallOutput", id: string, name: string, namespace: string | null, output: FunctionCallOutputBody, } | { "type": "plan", id: string, text: string, } | { "type": "reasoning", id: string, summary: Array<string>, content: Array<string>, } | { "type": "commandExecution", id: string,

pluginId: string | null,

scriptPath: string | null,

command: string,

cwd: LegacyAppPathString,

processId: string | null, source: CommandExecutionSource, status: CommandExecutionStatus,

commandActions: Array<CommandAction>,

aggregatedOutput: string | null,

exitCode: number | null,

durationMs: number | null, } | { "type": "fileChange", id: string, changes: Array<FileUpdateChange>, status: PatchApplyStatus, } | { "type": "mcpToolCall", id: string, server: string, tool: string, status: McpToolCallStatus, arguments: JsonValue, appContext: McpToolCallAppContext | null,

mcpAppResourceUri?: string,

mcpAppUi: McpAppUi | null, pluginId: string | null, readOnlyHint: boolean | null, result: McpToolCallResult | null, error: McpToolCallError | null,

durationMs: number | null, } | { "type": "dynamicToolCall", id: string, namespace: string | null, tool: string, arguments: JsonValue, status: DynamicToolCallStatus, contentItems: Array<DynamicToolCallOutputContentItem> | null, success: boolean | null,

durationMs: number | null, } | { "type": "collabAgentToolCall",

id: string,

tool: CollabAgentTool,

status: CollabAgentToolCallStatus,

senderThreadId: string,

receiverThreadIds: Array<string>,

prompt: string | null,

model: string | null,

reasoningEffort: ReasoningEffort | null,

agentsStates: { [key in string]?: CollabAgentState }, } | { "type": "subAgentActivity",

model: string | null,

reasoningEffort: ReasoningEffort | null, id: string, kind: SubAgentActivityKind, agentThreadId: string, agentPath: string, } | { "type": "webSearch" } & WebSearchItem | { "type": "imageView", id: string, path: LegacyAppPathString, } | { "type": "sleep" } & SleepItem | { "type": "imageGeneration" } & ImageGenerationItem | { "type": "enteredReviewMode", id: string, review: string, } | { "type": "exitedReviewMode", id: string, review: string, } | { "type": "contextCompaction", id: string, };
