
import type { LegacyAppPathString } from "../LegacyAppPathString";

export type TurnEnvironmentParams = { environmentId: string, cwd: LegacyAppPathString,

runtimeWorkspaceRoots?: Array<LegacyAppPathString> | null, };
