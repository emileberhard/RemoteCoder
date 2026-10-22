
import type { AbsolutePathBuf } from "../AbsolutePathBuf";
import type { MultiAgentMode } from "../MultiAgentMode";
import type { Personality } from "../Personality";
import type { JsonValue } from "../serde_json/JsonValue";
import type { ApprovalsReviewer } from "./ApprovalsReviewer";
import type { AskForApproval } from "./AskForApproval";
import type { DynamicToolSpec } from "./DynamicToolSpec";
import type { SandboxMode } from "./SandboxMode";
import type { SelectedCapabilityRoot } from "./SelectedCapabilityRoot";
import type { ThreadHistoryMode } from "./ThreadHistoryMode";
import type { ThreadSource } from "./ThreadSource";
import type { ThreadStartSource } from "./ThreadStartSource";
import type { TurnEnvironmentParams } from "./TurnEnvironmentParams";

export type ThreadStartParams = { model?: string | null, modelProvider?: string | null,

allowProviderModelFallback?: boolean, serviceTier?: string | null | null, cwd?: string | null,

runtimeWorkspaceRoots?: Array<AbsolutePathBuf> | null, approvalPolicy?: AskForApproval | null,

approvalsReviewer?: ApprovalsReviewer | null, sandbox?: SandboxMode | null,

permissions?: string | null, config?: { [key in string]?: JsonValue } | null, serviceName?: string | null, baseInstructions?: string | null, developerInstructions?: string | null,

personality?: Personality | null,

multiAgentMode?: MultiAgentMode | null, ephemeral?: boolean | null,

historyMode?: ThreadHistoryMode | null, sessionStartSource?: ThreadStartSource | null,

threadSource?: ThreadSource | null,

projectId?: string | null,

daybreakEnabled?: boolean | null,

environments?: Array<TurnEnvironmentParams> | null, dynamicTools?: Array<DynamicToolSpec> | null,

selectedCapabilityRoots?: Array<SelectedCapabilityRoot> | null,

mockExperimentalField?: string | null,

experimentalRawEvents?: boolean, };
