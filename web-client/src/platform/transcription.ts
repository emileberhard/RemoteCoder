import {
  languageHints,
  type TranscriptionModel,
  type TranscriptionSettings,
} from "../transcription-settings";
import { canceled, record, requiredString } from "./contracts";
import { relayJSON, type SpeechFetch, type SpeechProvider, speechURL } from "./relay";

export type DecodeAudio = (audio: Blob, sampleRate: number) => Promise<Float32Array>;

export type TranscriptionOptions = {
  fetch?: SpeechFetch;
  decode?: DecodeAudio;
  wait?: (milliseconds: number, signal: AbortSignal) => Promise<void>;
};

const azureSampleRate = 16_000;
const relayBodyLimit = 64 * 1024 * 1024;
const responseLimit = 2 * 1024 * 1024;
const azureSampleBudget = Math.floor((relayBodyLimit - 64 * 1024 - 44) / 2);
export const maximumRecordingMilliseconds = 30 * 60 * 1000;

const batchEngine = {
  elevenLabsScribeV2Realtime: "elevenLabs",
  elevenLabsScribeV2: "elevenLabs",
  assemblyAIUniversal35ProRealtime: "assemblyAI",
  assemblyAIUniversal35Pro: "assemblyAI",
  azureMAITranscribe2: "azure",
} as const satisfies Record<TranscriptionModel, "azure" | "elevenLabs" | "assemblyAI">;

export async function transcribeRecording(
  hostId: string,
  audio: Blob,
  settings: TranscriptionSettings,
  signal: AbortSignal,
  options: TranscriptionOptions = {},
): Promise<string> {
  const request = (provider: SpeechProvider, path: string, init: RequestInit = {}) =>
    (options.fetch ?? fetch)(speechURL(hostId, provider, path), { ...init, signal }).then((response) =>
      relayJSON(response, responseLimit),
    );
  const languages = languageHints[settings.language];
  const engine = batchEngine[settings.model];
  const text = await (engine === "azure"
    ? azure(audio, languages, request, options.decode ?? decodeMono, signal)
    : engine === "elevenLabs"
      ? elevenLabs(audio, languages, request)
      : assemblyAI(audio, languages, request, options.wait ?? wait, signal));
  if (!text.trim()) throw new Error("Transcription returned no text.");
  return text.trim();
}

type RelayRequest = (
  provider: SpeechProvider,
  path: string,
  init?: RequestInit,
) => Promise<Record<string, unknown>>;

async function azure(
  audio: Blob,
  languages: readonly string[],
  request: RelayRequest,
  decode: DecodeAudio,
  signal: AbortSignal,
) {
  const samples = await decode(audio, azureSampleRate);
  if (signal.aborted) throw canceled();
  if (samples.length > azureSampleBudget)
    throw new Error("The recording is too long for MAI-Transcribe-2 dictation");
  const body = new FormData();
  body.append(
    "definition",
    JSON.stringify({
      enhancedMode: { enabled: true, model: "MAI-Transcribe-2", modelOptions: { transcribeStyle: "clean" } },
      ...(languages.length === 1 ? { locales: languages } : {}),
    }),
  );
  body.append("audio", pcm16WAV(samples, azureSampleRate), "recording.wav");
  const result = await request("azure", "speechtotext/transcriptions:transcribe?api-version=2025-10-15", {
    method: "POST",
    body,
  });
  if (!Array.isArray(result.combinedPhrases)) throw new Error("Azure Speech returned no phrases");
  return result.combinedPhrases.map(textOf).join("\n");
}

async function elevenLabs(audio: Blob, languages: readonly string[], request: RelayRequest) {
  const body = new FormData();
  body.append("file", audio, `dictation.${fileExtension(audio)}`);
  body.append("model_id", "scribe_v2");
  if (languages.length === 1 && languages[0]) body.append("language_code", languages[0]);
  const result = await request("elevenlabs", "v1/speech-to-text", { method: "POST", body });
  if (typeof result.text === "string") return result.text;
  if (Array.isArray(result.transcripts)) return result.transcripts.map(textOf).join(" ");
  throw new Error("ElevenLabs returned no transcript");
}

async function assemblyAI(
  audio: Blob,
  languages: readonly string[],
  request: RelayRequest,
  pause: NonNullable<TranscriptionOptions["wait"]>,
  signal: AbortSignal,
) {
  const upload = await request("assemblyai", "v2/upload", {
    method: "POST",
    body: audio,
    headers: { "Content-Type": "application/octet-stream" },
  });
  const single = languages.length === 1 ? languages[0] : undefined;
  const transcript = await request("assemblyai", "v2/transcript", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      audio_url: requiredString(upload.upload_url, "AssemblyAI upload URL"),
      speech_models: ["universal-3-5-pro", "universal-2"],
      ...(single
        ? { language_code: single }
        : {
            language_detection: true,
            ...(languages.length ? { language_detection_options: { expected_languages: languages } } : {}),
          }),
    }),
  });
  const path = `v2/transcript/${encodeURIComponent(requiredString(transcript.id, "AssemblyAI transcript"))}`;
  while (true) {
    const status = await request("assemblyai", path);
    if (status.status === "completed") return typeof status.text === "string" ? status.text : "";
    if (status.status === "error")
      throw new Error(typeof status.error === "string" ? status.error : "AssemblyAI transcription failed");
    if (status.status !== "queued" && status.status !== "processing")
      throw new Error("AssemblyAI returned an unreadable transcript status");
    await pause(1000, signal);
  }
}

function textOf(value: unknown) {
  const text = record(value).text;
  if (typeof text !== "string") throw new Error("The transcription provider returned unreadable text");
  return text;
}

function fileExtension(audio: Blob) {
  return audio.type.includes("mp4") ? "m4a" : audio.type.includes("ogg") ? "ogg" : "webm";
}

function wait(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    if (signal.aborted) return reject(canceled());
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, milliseconds);
    const abort = () => {
      clearTimeout(timer);
      reject(canceled());
    };
    signal.addEventListener("abort", abort, { once: true });
  });
}

async function decodeMono(audio: Blob, sampleRate: number): Promise<Float32Array> {
  const decoded = await new OfflineAudioContext(1, 1, sampleRate).decodeAudioData(await audio.arrayBuffer());
  if (decoded.length > azureSampleBudget)
    throw new Error("The recording is too long for MAI-Transcribe-2 dictation");
  if (decoded.numberOfChannels === 1) return decoded.getChannelData(0);
  const mono = new Float32Array(decoded.length);
  for (let channel = 0; channel < decoded.numberOfChannels; channel++) {
    const samples = decoded.getChannelData(channel);
    for (let index = 0; index < mono.length; index++)
      mono[index] = (mono[index] ?? 0) + (samples[index] ?? 0) / decoded.numberOfChannels;
  }
  return mono;
}

export function pcm16WAV(samples: Float32Array, sampleRate: number): Blob {
  const view = new DataView(new ArrayBuffer(44 + samples.length * 2));
  const ascii = (offset: number, text: string) => {
    for (let index = 0; index < text.length; index++) view.setUint8(offset + index, text.charCodeAt(index));
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, samples.length * 2, true);
  samples.forEach((sample, index) => {
    const clamped = Math.max(-1, Math.min(1, sample));
    view.setInt16(44 + index * 2, Math.round(clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff), true);
  });
  return new Blob([view.buffer], { type: "audio/wav" });
}
