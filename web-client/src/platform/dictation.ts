import type { TranscriptionSettings } from "../transcription-settings";
import {
  canceled,
  errorMessage,
  type FeatureTransport,
  isCanceled,
  record,
  requiredString,
} from "./contracts";
import { dictationSampleRate } from "./dictation-limits";
import { BrowserRecordingStore, type RecordingStore, type SavedRecording } from "./recordings";
import {
  decodeMono,
  maximumRecordingMilliseconds,
  pcm16WAV,
  type TranscriptionOptions,
  transcribeRecording,
} from "./transcription";
import { BrowserUploadService } from "./uploads";

export type DictationState = {
  status: "idle" | "starting" | "recording" | "transcribing" | "failed";
  error?: string;
};

export type DictationOptions = TranscriptionOptions & {
  store?: RecordingStore;
  capture?: () => Promise<MediaStream>;
  recorder?: (stream: MediaStream, options: MediaRecorderOptions) => MediaRecorder;
  request?: FeatureTransport["request"];
  uploadDictation?: BrowserUploadService["uploadDictation"];
};

const maximumRecordingBytes = 32 * 1024 * 1024;

type Capture = {
  recorder: MediaRecorder;
  stream: MediaStream;
  result: Promise<Blob>;
  settings: TranscriptionSettings;
  limit: ReturnType<typeof setTimeout>;
};

export class BrowserDictation {
  private generation = 0;
  private capture?: Capture;
  private transcription?: AbortController;
  private finishing?: { capture: Capture; operation: Promise<void> };
  private unsaved?: SavedRecording;
  private retired = false;
  private readonly store: RecordingStore;
  state: DictationState = { status: "idle" };

  constructor(
    readonly hostId: string,
    private readonly onState: (state: DictationState) => void,
    private readonly onTranscript: (text: string) => void,
    private readonly settings: () => TranscriptionSettings,
    private readonly options: DictationOptions = {},
  ) {
    this.store = options.store ?? new BrowserRecordingStore();
  }

  private publish(state: DictationState) {
    this.state = state;
    if (!this.retired) this.onState(state);
  }

  async start(): Promise<void> {
    if (this.retired) throw new Error("Dictation has been retired");
    if (this.state.status !== "idle" && this.state.status !== "failed")
      throw new Error("Dictation is already active");
    this.cancel();
    const generation = this.generation;
    const settings = this.settings();
    this.publish({ status: "starting" });
    let acquiredStream: MediaStream | undefined;
    try {
      const stream = await (
        this.options.capture ??
        (() => {
          if (!navigator.mediaDevices?.getUserMedia)
            throw new Error("Microphone capture requires HTTPS or localhost");
          return navigator.mediaDevices.getUserMedia({
            audio: {
              channelCount: 1,
              echoCancellation: false,
              noiseSuppression: false,
              autoGainControl: false,
            },
          });
        })
      )();
      acquiredStream = stream;
      if (generation !== this.generation || this.retired) {
        for (const track of stream.getTracks()) track.stop();
        throw canceled();
      }
      const mime = ["audio/webm;codecs=opus", "audio/mp4", "audio/ogg;codecs=opus"].find(
        (value) => typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(value),
      );
      const recorder = (this.options.recorder ?? ((source, options) => new MediaRecorder(source, options)))(
        stream,
        { ...(mime ? { mimeType: mime } : {}), audioBitsPerSecond: 64000 },
      );
      const chunks: Blob[] = [];
      let bytes = 0;
      const stopAtLimit = () => void this.finish().catch(() => undefined);
      const result = new Promise<Blob>((resolve, reject) => {
        recorder.ondataavailable = (event) => {
          if (!event.data.size) return;
          chunks.push(event.data);
          bytes += event.data.size;
          if (bytes > maximumRecordingBytes) stopAtLimit();
        };
        recorder.onerror = () => reject(new Error("The browser could not record microphone audio"));
        recorder.onstop = () => {
          for (const track of stream.getTracks()) track.stop();
          resolve(new Blob(chunks, { type: recorder.mimeType || "audio/webm" }));
        };
      });
      void result.catch(() => undefined);
      const limit = setTimeout(stopAtLimit, maximumRecordingMilliseconds);
      this.capture = { recorder, stream, result, settings, limit };
      recorder.start(1000);
      this.publish({ status: "recording" });
    } catch (error) {
      for (const track of acquiredStream?.getTracks() ?? []) track.stop();
      const failed = this.capture;
      if (failed && failed.stream === acquiredStream) {
        clearTimeout(failed.limit);
        this.capture = undefined;
      }
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      this.publish({ status: "failed", error: errorMessage(error) });
      throw error;
    }
  }

  finish(): Promise<void> {
    const capture = this.capture;
    const current = this.finishing;
    if (current && (!capture || current.capture === capture)) return current.operation;
    if (!capture) return Promise.resolve();
    const finishing = { capture, operation: this.finishCapture(capture, this.generation) };
    this.finishing = finishing;
    void finishing.operation
      .finally(() => {
        if (this.finishing === finishing) this.finishing = undefined;
      })
      .catch(() => undefined);
    return finishing.operation;
  }

  private async finishCapture(capture: Capture, generation: number): Promise<void> {
    this.publish({ status: "transcribing" });
    try {
      clearTimeout(capture.limit);
      if (capture.recorder.state !== "inactive") capture.recorder.stop();
      const blob = await capture.result;
      if (this.capture === capture) this.capture = undefined;
      if (generation !== this.generation || this.retired) return;
      if (!blob.size) throw new Error("The microphone recording was empty");
      const recording: SavedRecording = {
        id: crypto.randomUUID(),
        hostId: this.hostId,
        createdAt: Date.now(),
        blob,
      };
      this.unsaved = recording;
      await this.store.save(recording);
      if (this.unsaved === recording) this.unsaved = undefined;
      if (generation !== this.generation || this.retired) return;
      await this.transcribe(recording, capture.settings, generation);
    } catch (error) {
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      this.publish({ status: "failed", error: errorMessage(error) });
      throw error;
    }
  }

  private async transcribe(
    recording: SavedRecording,
    settings: TranscriptionSettings,
    generation: number,
  ): Promise<void> {
    const controller = new AbortController();
    this.transcription = controller;
    this.publish({ status: "transcribing" });
    try {
      let text: string;
      try {
        if (!this.options.request) throw new Error("No host transport");
        const samples = await (this.options.decode ?? decodeMono)(recording.blob, dictationSampleRate);
        controller.signal.throwIfAborted();
        const durationMs = Math.ceil((samples.length * 1000) / dictationSampleRate);
        if (durationMs < 1 || durationMs > maximumRecordingMilliseconds)
          throw new Error("The recording duration is outside the host limit");
        const file = new File([pcm16WAV(samples, dictationSampleRate)], "dictation.wav", {
          type: "audio/wav",
        });
        const uploader = new BrowserUploadService(this.hostId);
        let path: string;
        try {
          const upload = this.options.uploadDictation ?? uploader.uploadDictation.bind(uploader);
          ({ path } = await upload(file, { signal: controller.signal }));
        } finally {
          uploader.dispose();
        }
        const result = await this.options.request(
          "dictation/transcribe",
          { path, durationMs },
          {
            signal: controller.signal,
            timeout: durationMs + 125_000,
          },
        );
        text = requiredString(record(result).text, "dictation transcript");
      } catch (error) {
        if (controller.signal.aborted) throw error;
        text = await transcribeRecording(
          this.hostId,
          recording.blob,
          settings,
          controller.signal,
          this.options,
        );
      }
      if (generation !== this.generation || this.retired) return;
      this.onTranscript(text);
      await this.store.remove(recording.id);
      if (this.unsaved?.id === recording.id) this.unsaved = undefined;
      if (generation === this.generation && !this.retired) this.publish({ status: "idle" });
    } finally {
      if (this.transcription === controller) this.transcription = undefined;
    }
  }

  async recoveries(): Promise<SavedRecording[]> {
    const saved = await this.store.list(this.hostId);
    return this.unsaved && !saved.some((item) => item.id === this.unsaved?.id)
      ? [this.unsaved, ...saved]
      : saved;
  }

  async retry(id: string): Promise<void> {
    if (this.retired || this.capture || this.transcription || this.state.status === "transcribing")
      throw new Error("Finish the active dictation first");
    const requestedGeneration = this.generation;
    const recording = (await this.recoveries()).find((item) => item.id === id);
    if (requestedGeneration !== this.generation || this.retired) return;
    if (!recording) throw new Error("The saved recording is unavailable");
    const generation = ++this.generation;
    try {
      await this.transcribe(recording, this.settings(), generation);
    } catch (error) {
      if (generation === this.generation && !this.retired && !isCanceled(error)) {
        this.publish({ status: "failed", error: errorMessage(error) });
        throw error;
      }
    }
  }

  async discard(id: string): Promise<void> {
    if (this.transcription) throw new Error("Finish the active dictation before discarding a recording");
    await this.store.remove(id);
    if (this.unsaved?.id === id) this.unsaved = undefined;
  }

  cancel(): void {
    this.generation += 1;
    this.transcription?.abort();
    this.transcription = undefined;
    const capture = this.capture;
    this.capture = undefined;
    if (capture) {
      clearTimeout(capture.limit);
      if (capture.recorder.state !== "inactive") capture.recorder.stop();
      for (const track of capture.stream.getTracks()) track.stop();
    }
    this.publish({ status: "idle" });
  }

  dispose(): void {
    this.cancel();
    this.retired = true;
    if (this.store instanceof BrowserRecordingStore) this.store.dispose();
  }
}
