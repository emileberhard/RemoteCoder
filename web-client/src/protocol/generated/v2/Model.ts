
import type { InputModality } from "../InputModality";
import type { ReasoningEffort } from "../ReasoningEffort";
import type { ModelAccessPrograms } from "./ModelAccessPrograms";
import type { ModelAvailabilityNux } from "./ModelAvailabilityNux";
import type { ModelServiceTier } from "./ModelServiceTier";
import type { ModelUpgradeInfo } from "./ModelUpgradeInfo";
import type { MultiAgentVersion } from "./MultiAgentVersion";
import type { ReasoningEffortOption } from "./ReasoningEffortOption";

export type Model = { id: string, model: string, upgrade: string | null, upgradeInfo: ModelUpgradeInfo | null, availabilityNux: ModelAvailabilityNux | null, displayName: string, description: string, modelSpecialty: string | null, hidden: boolean, supportedReasoningEfforts: Array<ReasoningEffortOption>, defaultReasoningEffort: ReasoningEffort, inputModalities: Array<InputModality>,

supportsPersonality: boolean,

multiAgentVersion: MultiAgentVersion | null,

additionalSpeedTiers: Array<string>, serviceTiers: Array<ModelServiceTier>,

defaultServiceTier: string | null,

availableAccessPrograms: ModelAccessPrograms | null, isDefault: boolean, };
