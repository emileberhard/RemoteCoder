import { errorMessage, isCanceled, record, requiredString } from "./contracts";
import { relayJSON, type SpeechFetch, speechURL } from "./relay";

export type SpeechOutputState = { status: "idle" | "preparing" | "speaking" | "failed"; error?: string };
export type SpeechOutputOptions = { fetch?: SpeechFetch; audioContext?: () => AudioContext };

export function decodePCM16(bytes: Uint8Array, sampleRate: number, context: AudioContext): AudioBuffer {
  if (bytes.length % 2 !== 0 || !bytes.length)
    throw new Error("Speech provider returned incomplete PCM audio");
  if (!Number.isInteger(sampleRate) || sampleRate < 8000 || sampleRate > 96000)
    throw new Error("Speech sample rate is unsupported");
  const buffer = context.createBuffer(1, bytes.length / 2, sampleRate);
  const output = buffer.getChannelData(0);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let index = 0; index < output.length; index += 1)
    output[index] = view.getInt16(index * 2, true) / 32768;
  return buffer;
}

export class BrowserSpeechOutput {
  private generation = 0;
  private request?: AbortController;
  private context?: AudioContext;
  private source?: AudioBufferSourceNode;
  private sourceStarted = false;
  private playbackDone?: () => void;
  private retired = false;
  state: SpeechOutputState = { status: "idle" };

  constructor(
    readonly hostId: string,
    private readonly onState: (state: SpeechOutputState) => void,
    private readonly options: SpeechOutputOptions = {},
  ) {}

  private publish(state: SpeechOutputState): void {
    this.state = state;
    if (!this.retired) this.onState(state);
  }

  async speak(text: string): Promise<void> {
    if (this.retired) throw new Error("Spoken replies have been retired");
    const trimmed = text.trim();
    if (!trimmed) return;
    if (new TextEncoder().encode(trimmed).byteLength > 24000)
      throw new Error("The reply exceeds spoken-audio capacity");
    this.cancel();
    const generation = this.generation;
    const controller = new AbortController();
    this.request = controller;
    this.publish({ status: "preparing" });
    try {
      const context = (this.options.audioContext ?? (() => new AudioContext()))();
      this.context = context;
      await context.resume();
      if (generation !== this.generation || this.retired) return;
      const response = await (this.options.fetch ?? fetch)(
        speechURL(this.hostId, "gemini", "v1beta/models/gemini-3.1-flash-tts-preview:generateContent"),
        {
          method: "POST",
          signal: controller.signal,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            contents: [
              {
                role: "user",
                parts: [
                  {
                    text:
                      "Sound friendly, casual, and natural. Adapt the response into flowing spoken language. Do not read Markdown syntax, raw URLs, code, diffs, or terminal output aloud. Briefly summarize technical details and say they are available in the chat.\n\n" +
                      trimmed,
                  },
                ],
              },
            ],
            generationConfig: {
              responseModalities: ["AUDIO"],
              speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Achird" } } },
            },
          }),
        },
      );
      const result = await relayJSON(response, 32 * 1024 * 1024);
      if (generation !== this.generation || this.retired) return;
      if (!Array.isArray(result.candidates) || !result.candidates.length)
        throw new Error("Speech provider returned no audio candidate");
      const parts = record(record(result.candidates[0]).content).parts;
      if (!Array.isArray(parts)) throw new Error("Speech provider returned no audio parts");
      const audio = parts
        .map(record)
        .map((part) => part.inlineData)
        .find((value) => value !== undefined);
      const inline = record(audio);
      const encoded = requiredString(inline.data, "speech audio");
      const mime = requiredString(inline.mimeType, "speech audio format");
      const decoded = atob(encoded);
      const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
      let buffer: AudioBuffer;
      if (/audio\/(l16|pcm)(;|$)/i.test(mime)) {
        const rate = Number(mime.match(/rate=(\d+)/i)?.[1] ?? 24000);
        buffer = decodePCM16(bytes, rate, context);
      } else if (/^audio\/(wav|x-wav|mpeg|mp3|ogg)/i.test(mime)) {
        buffer = await context.decodeAudioData(bytes.buffer);
      } else throw new Error(`Speech audio format is unsupported: ${mime}`);
      if (generation !== this.generation || this.retired) return;
      const source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(context.destination);
      this.source = source;
      this.publish({ status: "speaking" });
      await new Promise<void>((resolve) => {
        this.playbackDone = resolve;
        source.onended = () => resolve();
        source.start();
        this.sourceStarted = true;
      });
      if (generation === this.generation && !this.retired) {
        this.releaseAudio();
        this.publish({ status: "idle" });
      }
    } catch (error) {
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      this.releaseAudio();
      this.publish({ status: "failed", error: errorMessage(error) });
      throw error;
    } finally {
      if (this.request === controller) this.request = undefined;
    }
  }

  private releaseAudio(): void {
    if (this.source) {
      this.source.onended = null;
      if (this.sourceStarted) this.source.stop();
      this.source.disconnect();
      this.source = undefined;
      this.sourceStarted = false;
    }
    this.playbackDone?.();
    this.playbackDone = undefined;
    const context = this.context;
    this.context = undefined;
    if (context && context.state !== "closed") void context.close().catch(() => undefined);
  }

  cancel(): void {
    this.generation += 1;
    this.request?.abort();
    this.request = undefined;
    this.releaseAudio();
    this.publish({ status: "idle" });
  }

  dispose(): void {
    this.cancel();
    this.retired = true;
  }
}
