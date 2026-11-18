export const transcriptionModels = [
  "elevenLabsScribeV2Realtime",
  "elevenLabsScribeV2",
  "assemblyAIUniversal35ProRealtime",
  "assemblyAIUniversal35Pro",
  "azureMAITranscribe2",
] as const;
export type TranscriptionModel = (typeof transcriptionModels)[number];
export const defaultTranscriptionModel: TranscriptionModel = "elevenLabsScribeV2Realtime";

export const languageHints = {
  automatic: [],
  english: ["en"],
  swedish: ["sv"],
  englishAndSwedish: ["en", "sv"],
} as const satisfies Record<string, readonly string[]>;
export type TranscriptionLanguage = keyof typeof languageHints;
export const transcriptionLanguages = Object.keys(languageHints) as TranscriptionLanguage[];

export type TranscriptionSettings = { model: TranscriptionModel; language: TranscriptionLanguage };
