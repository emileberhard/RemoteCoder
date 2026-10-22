import { canceled, errorMessage, isCanceled, requiredString } from "./contracts";
import { BrowserRecordingStore, type RecordingStore, type SavedRecording } from "./recordings";
import { relayJSON, type SpeechFetch, speechURL } from "./relay";

export type DictationState = {
  status: "idle" | "starting" | "recording" | "transcribing" | "failed";
  error?: string;
};

export type DictationOptions = {
  model?: string;
  language?: string;
  store?: RecordingStore;
  capture?: () => Promise<MediaStream>;
  recorder?: (stream: MediaStream, options: MediaRecorderOptions) => MediaRecorder;
  fetch?: SpeechFetch;
};

type Capture = { recorder: MediaRecorder; stream: MediaStream; result: Promise<Blob> };

export class BrowserDictation {
  private generation = 0;
  private capture?: Capture;
  private transcription?: AbortController;
  private finishing?: Promise<void>;
  private unsaved?: SavedRecording;
  private retired = false;
  private readonly store: RecordingStore;
  state: DictationState = { status: "idle" };

  constructor(
    readonly hostId: string,
    private readonly onState: (state: DictationState) => void,
    private readonly onTranscript: (text: string) => void,
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
    this.publish({ status: "starting" });
    let acquiredStream: MediaStream | undefined;
    try {
      const stream = await (
        this.options.capture ??
        (() => {
          if (!navigator.mediaDevices?.getUserMedia)
            throw new Error("Microphone capture requires HTTPS or localhost");
          return navigator.mediaDevices.getUserMedia({
            audio: { echoCancellation: true, noiseSuppression: true },
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
      const result = new Promise<Blob>((resolve, reject) => {
        recorder.ondataavailable = (event) => {
          bytes += event.data.size;
          if (bytes > 24 * 1024 * 1024) {
            reject(new Error("The recording exceeds the 24 MiB transcription limit"));
            this.cancel();
            this.publish({ status: "failed", error: "The recording exceeds the 24 MiB transcription limit" });
          } else if (event.data.size) chunks.push(event.data);
        };
        recorder.onerror = () => reject(new Error("The browser could not record microphone audio"));
        recorder.onstop = () => {
          for (const track of stream.getTracks()) track.stop();
          resolve(new Blob(chunks, { type: recorder.mimeType || "audio/webm" }));
        };
      });
      void result.catch(() => undefined);
      this.capture = { recorder, stream, result };
      recorder.start(1000);
      this.publish({ status: "recording" });
    } catch (error) {
      for (const track of acquiredStream?.getTracks() ?? []) track.stop();
      if (this.capture?.stream === acquiredStream) this.capture = undefined;
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      this.publish({ status: "failed", error: errorMessage(error) });
      throw error;
    }
  }

  finish(): Promise<void> {
    if (this.finishing) return this.finishing;
    const capture = this.capture;
    if (!capture) return Promise.resolve();
    const generation = this.generation;
    const operation = this.finishCapture(capture, generation);
    this.finishing = operation;
    void operation
      .finally(() => {
        if (this.finishing === operation) this.finishing = undefined;
      })
      .catch(() => undefined);
    return operation;
  }

  private async finishCapture(capture: Capture, generation: number): Promise<void> {
    this.publish({ status: "transcribing" });
    try {
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
      await this.transcribe(recording, generation);
    } catch (error) {
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      this.publish({ status: "failed", error: errorMessage(error) });
      throw error;
    }
  }

  private async transcribe(recording: SavedRecording, generation: number): Promise<void> {
    const controller = new AbortController();
    this.transcription = controller;
    this.publish({ status: "transcribing" });
    try {
      const body = new FormData();
      const extension = recording.blob.type.includes("mp4")
        ? "m4a"
        : recording.blob.type.includes("ogg")
          ? "ogg"
          : "webm";
      body.append("file", recording.blob, `dictation.${extension}`);
      body.append("model", this.options.model ?? "gpt-4o-transcribe");
      body.append("response_format", "json");
      if (this.options.language) body.append("language", this.options.language);
      const response = await (this.options.fetch ?? fetch)(
        speechURL(this.hostId, "openai", "v1/audio/transcriptions"),
        {
          method: "POST",
          body,
          signal: controller.signal,
        },
      );
      const result = await relayJSON(response, 2 * 1024 * 1024);
      const text = requiredString(result.text, "transcribed text").trim();
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
      await this.transcribe(recording, generation);
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
