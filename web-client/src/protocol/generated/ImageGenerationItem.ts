
import type { AbsolutePathBuf } from "./AbsolutePathBuf";
import type { ImageGenerationFailure } from "./ImageGenerationFailure";

export type ImageGenerationItem = { id: string, status: string, revisedPrompt: string | null, result: string, transparentBackground?: boolean, failure: ImageGenerationFailure | null, savedPath?: AbsolutePathBuf, };
