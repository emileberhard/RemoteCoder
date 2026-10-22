
import type { CodexErrorInfo } from "./CodexErrorInfo";
import type { MisalignmentErrorDetails } from "./MisalignmentErrorDetails";

export type TurnError = { message: string, codexErrorInfo: CodexErrorInfo | null, additionalDetails: string | null,

misalignment: MisalignmentErrorDetails | null, };
