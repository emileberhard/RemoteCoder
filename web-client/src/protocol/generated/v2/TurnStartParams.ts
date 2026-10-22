
import type { AbsolutePathBuf } from "../AbsolutePathBuf";
import type { CollaborationMode } from "../CollaborationMode";
import type { MultiAgentMode } from "../MultiAgentMode";
import type { Personality } from "../Personality";
import type { ReasoningEffort } from "../ReasoningEffort";
import type { ReasoningSummary } from "../ReasoningSummary";
import type { JsonValue } from "../serde_json/JsonValue";
import type { AdditionalContextEntry } from "./AdditionalContextEntry";
import type { ApprovalsReviewer } from "./ApprovalsReviewer";
import type { AskForApproval } from "./AskForApproval";
import type { CyberAccessProgram } from "./CyberAccessProgram";
import type { SandboxPolicy } from "./SandboxPolicy";
import type { TurnEnvironmentParams } from "./TurnEnvironmentParams";
import type { TurnToolOutput } from "./TurnToolOutput";
import type { UserInput } from "./UserInput";

export type TurnStartParams = { threadId: string,

disabledPluginIds?: Array<string> | null, clientUserMessageId?: string | null, input: Array<UserInput>,

turnTrigger?: string | null,

parentTurnId?: string | null,

rootTurnId?: string | null, toolOutput?: TurnToolOutput | null,

responsesapiClientMetadata?: { [key in string]?: string } | null,

additionalContext?: { [key in string]?: AdditionalContextEntry } | null,

environments?: Array<TurnEnvironmentParams> | null,

cwd?: string | null,

runtimeWorkspaceRoots?: Array<AbsolutePathBuf> | null,

approvalPolicy?: AskForApproval | null,

approvalsReviewer?: ApprovalsReviewer | null,

sandboxPolicy?: SandboxPolicy | null,

permissions?: string | null,

model?: string | null,

serviceTier?: string | null | null,

serviceTierForTurn?: string | null,

effort?: ReasoningEffort | null,

summary?: ReasoningSummary | null,

personality?: Personality | null,

outputSchema?: JsonValue | null,

collaborationMode?: CollaborationMode | null,

multiAgentMode?: MultiAgentMode | null,

cyberAccessProgram?: CyberAccessProgram | null, };
