
import type { MisalignmentSteer } from "./MisalignmentSteer";

export type MisalignmentErrorDetails = {

errorType: string | null,

detailedExplanation: string | null,

steer: MisalignmentSteer | null,

reviewTarget?: string | null, };
