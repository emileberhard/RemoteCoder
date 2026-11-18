export const maximumRecordingMilliseconds = 30 * 60 * 1000;
export const dictationSampleRate = 16_000;
export const dictationWAVLimit = 44 + (maximumRecordingMilliseconds / 1000) * dictationSampleRate * 2;
