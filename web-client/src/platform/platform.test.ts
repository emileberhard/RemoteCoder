import { describe, expect, test } from "bun:test";
import type { Frame } from "../protocol/boundary";
import type { TranscriptionSettings } from "../transcription-settings";
import type { FeatureTransport, VoiceContext } from "./contracts";
import { BrowserDictation } from "./dictation";
import type { RecordingStore, SavedRecording } from "./recordings";
import { decodePCM16 } from "./speech";
import { transcribeRecording } from "./transcription";
import { BrowserVoiceSession, type VoiceEnvironment } from "./voice";

function deferred<T>() {
  let resolve: (value: T) => void = () => undefined;
  const promise = new Promise<T>((accept) => {
    resolve = accept;
  });
  return { promise, resolve };
}

async function settle() {
  for (let index = 0; index < 12; index += 1) await Promise.resolve();
}

function mediaStream() {
  let stops = 0;
  const track = {
    enabled: true,
    stop: () => {
      stops += 1;
    },
  };
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] } as unknown as MediaStream;
  return { stream, stops: () => stops };
}

function voiceHarness(capture: () => Promise<MediaStream>, request: FeatureTransport["request"]) {
  let listener: (frame: Frame) => void = () => undefined;
  let peers = 0;
  let closed = false;
  let answer: RTCSessionDescriptionInit | undefined;
  const peer = {
    ontrack: null,
    onconnectionstatechange: null,
    connectionState: "new",
    addTrack: () => undefined,
    createDataChannel: () => ({}),
    createOffer: async () => ({ type: "offer", sdp: "v=0\r\no=browser-offer\r\n" }),
    setLocalDescription: async () => undefined,
    setRemoteDescription: async (description: RTCSessionDescriptionInit) => {
      answer = description;
    },
    close: () => {
      closed = true;
    },
  };
  const environment: VoiceEnvironment = {
    capture,
    peer: () => {
      peers += 1;
      return peer as unknown as RTCPeerConnection;
    },
    audio: () =>
      ({
        pause: () => undefined,
        play: async () => undefined,
        srcObject: null,
        autoplay: false,
      }) as unknown as HTMLAudioElement,
    id: () => "call-1",
  };
  const transport: FeatureTransport = {
    hostId: "host-1",
    hostName: "Mac mini",
    request,
    subscribe: (receive) => {
      listener = receive;
      return () => {
        listener = () => undefined;
      };
    },
  };
  const service = new BrowserVoiceSession(transport, () => undefined, environment);
  return {
    service,
    emit: (frame: Frame) => listener(frame),
    peers: () => peers,
    closed: () => closed,
    answer: () => answer,
  };
}

const voiceContext: VoiceContext = {
  conversationThreadId: "conversation-1",
  cwd: "/tmp",
  model: "gpt-6.1-sol",
  initialItems: [{ role: "user", text: "Continue this exact conversation" }],
};

const scribe = (): TranscriptionSettings => ({ model: "elevenLabsScribeV2", language: "automatic" });

class MemoryRecordings implements RecordingStore {
  readonly saved = new Map<string, SavedRecording>();
  async save(recording: SavedRecording) {
    this.saved.set(recording.id, recording);
  }
  async list(hostId: string) {
    return [...this.saved.values()].filter((recording) => recording.hostId === hostId);
  }
  async remove(id: string) {
    this.saved.delete(id);
  }
}

function recorder(): MediaRecorder {
  const value = {
    state: "inactive",
    mimeType: "audio/webm",
    ondataavailable: undefined as ((event: { data: Blob }) => void) | undefined,
    onstop: undefined as (() => void) | undefined,
    onerror: undefined,
    start: () => {
      value.state = "recording";
    },
    stop: () => {
      value.state = "inactive";
      queueMicrotask(() => {
        value.ondataavailable?.({ data: new Blob(["recorded microphone audio"], { type: "audio/webm" }) });
        value.onstop?.();
      });
    },
  };
  return value as unknown as MediaRecorder;
}

describe("browser speech service ownership", () => {
  test("ending during microphone permission closes a late stream without starting remote work", async () => {
    const capture = deferred<MediaStream>();
    const media = mediaStream();
    const methods: string[] = [];
    const harness = voiceHarness(
      () => capture.promise,
      async (method) => {
        methods.push(method);
        return {};
      },
    );
    const startup = harness.service.start(voiceContext);
    await settle();
    expect(harness.service.state.status).toBe("requestingMicrophone");
    await harness.service.stop();
    expect(harness.service.state.status).toBe("idle");
    capture.resolve(media.stream);
    await startup;
    expect(media.stops()).toBe(1);
    expect(harness.peers()).toBe(0);
    expect(methods).toEqual([]);
  });

  test("accepts SDP before the start acknowledgement and keeps transcripts on the exact realtime thread", async () => {
    const media = mediaStream();
    const harness = voiceHarness(
      async () => media.stream,
      async (method) => {
        if (method === "voice/session/start") {
          harness.emit({
            method: "thread/realtime/sdp",
            params: { threadId: "realtime-1", sdp: "v=0\r\no=remote-answer\r\n" },
          });
          return { realtimeThreadId: "realtime-1", model: "gpt-6.1-sol", effort: "high" };
        }
        return {};
      },
    );
    await harness.service.start(voiceContext);
    expect(harness.answer()).toEqual({ type: "answer", sdp: "v=0\r\no=remote-answer\r\n" });
    harness.emit({
      method: "thread/realtime/transcript/done",
      params: { threadId: "other-thread", role: "user", text: "Wrong conversation" },
    });
    harness.emit({
      method: "thread/realtime/transcript/done",
      params: { threadId: "realtime-1", role: "assistant", text: "Ready to continue" },
    });
    expect(harness.service.state.transcript.map((entry) => entry.text)).toEqual(["Ready to continue"]);
    await harness.service.stop();
    expect(harness.closed()).toBe(true);
    expect(media.stops()).toBe(1);
  });

  test("hangup during remote start cleans up an accepted late session without reactivating audio", async () => {
    const media = mediaStream();
    const accepted = deferred<unknown>();
    const methods: string[] = [];
    const harness = voiceHarness(
      async () => media.stream,
      async (method) => {
        methods.push(method);
        return method === "voice/session/start" ? accepted.promise : {};
      },
    );
    const startup = harness.service.start(voiceContext);
    await settle();
    expect(methods).toEqual(["voice/session/start"]);
    const stopping = harness.service.stop();
    expect(harness.closed()).toBe(true);
    expect(media.stops()).toBe(1);
    accepted.resolve({ realtimeThreadId: "late-realtime", model: "gpt-6.1-sol", effort: null });
    await Promise.all([startup, stopping]);
    expect(methods).toEqual(["voice/session/start", "voice/session/stop"]);
    expect(harness.service.state.status).toBe("idle");
    expect(harness.service.state.realtimeThreadId).toBeUndefined();
  });

  test("a failed transcription retains the audio and a successful retry delivers it once", async () => {
    const store = new MemoryRecordings();
    const media = mediaStream();
    const texts: string[] = [];
    let attempts = 0;
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store,
        capture: async () => media.stream,
        recorder,
        fetch: async () => {
          attempts += 1;
          return attempts === 1
            ? new Response(JSON.stringify({ error: { message: "Provider unavailable" } }), { status: 502 })
            : new Response(JSON.stringify({ text: "Recovered dictation" }));
        },
      },
    );
    await service.start();
    await expect(service.finish()).rejects.toThrow("Provider unavailable");
    const saved = await service.recoveries();
    expect(saved).toHaveLength(1);
    expect(await saved[0]?.blob.text()).toBe("recorded microphone audio");
    const id = saved[0]?.id;
    if (!id) throw new Error("Missing saved recording");
    await service.retry(id);
    expect(texts).toEqual(["Recovered dictation"]);
    expect(await service.recoveries()).toEqual([]);
    expect(media.stops()).toBe(1);
    service.dispose();
  });

  test("host dictation uploads PCM audio and requests the selected host with its duration", async () => {
    const texts: string[] = [];
    const requests: unknown[] = [];
    let uploaded: File | undefined;
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder,
        decode: async () => new Float32Array(32_000),
        uploadDictation: async (file) => {
          uploaded = file;
          return { path: "/uploads/recording.wav", bytes: file.size, sha256: "digest" };
        },
        request: async (method, params, options) => {
          requests.push({ method, params, timeout: options?.timeout });
          return { text: "Filtered words", model: "model" };
        },
      },
    );
    await service.start();
    await service.finish();
    expect(uploaded?.type).toBe("audio/wav");
    expect(uploaded?.size).toBe(64_044);
    expect(requests).toEqual([
      {
        method: "dictation/transcribe",
        params: { path: "/uploads/recording.wav", durationMs: 2000 },
        timeout: 127_000,
      },
    ]);
    expect(texts).toEqual(["Filtered words"]);
    expect(await service.recoveries()).toEqual([]);
    service.dispose();
  });

  test("an empty filtered host result completes without relay or draft insertion", async () => {
    const texts: string[] = [];
    let relayCalls = 0;
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder,
        decode: async () => new Float32Array(16_000),
        uploadDictation: async (file) => ({ path: "/upload.wav", bytes: file.size, sha256: "digest" }),
        request: async () => ({ text: "", model: "batch" }),
        fetch: async () => {
          relayCalls += 1;
          return new Response(JSON.stringify({ text: "Everyone's speech" }));
        },
      },
    );
    await service.start();
    await service.finish();
    expect(relayCalls).toBe(0);
    expect(texts).toEqual([]);
    expect(await service.recoveries()).toEqual([]);
    expect(service.state.status).toBe("idle");
    service.dispose();
  });

  test.each([
    "decode",
    "upload",
    "noHost",
    "busy",
    "hostLost",
    "failed",
    "unknown",
    "methodNotFound",
    "malformed",
  ])("host failure %s falls back with the original recording", async (failure) => {
    const texts: string[] = [];
    let relayBody: FormData | undefined;
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder,
        decode: async () => {
          if (failure === "decode") throw new Error("decode failed");
          return new Float32Array(16_000);
        },
        uploadDictation: async (file) => {
          if (failure === "upload") throw new Error("upload failed");
          return { path: "/upload.wav", bytes: file.size, sha256: "digest" };
        },
        request: async () => {
          if (failure === "malformed") return {};
          throw new Error(failure);
        },
        fetch: async (_input, init) => {
          if (!(init?.body instanceof FormData)) throw new Error("Expected relay multipart body");
          relayBody = init.body;
          return new Response(JSON.stringify({ text: "Relay words" }));
        },
      },
    );
    await service.start();
    await service.finish();
    const original = relayBody?.get("file");
    if (!(original instanceof Blob)) throw new Error("Missing relay recording");
    expect(await original.text()).toBe("recorded microphone audio");
    expect(texts).toEqual(["Relay words"]);
    service.dispose();
  });

  test("canceling a pending transcription fences late text and retains the saved recording", async () => {
    const store = new MemoryRecordings();
    const response = deferred<Response>();
    const texts: string[] = [];
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store,
        capture: async () => mediaStream().stream,
        recorder,
        fetch: () => response.promise,
      },
    );
    await service.start();
    const finishing = service.finish();
    await settle();
    expect(store.saved.size).toBe(1);
    service.cancel();
    response.resolve(new Response(JSON.stringify({ text: "Late text from the previous draft" })));
    await finishing;
    expect(texts).toEqual([]);
    expect((await service.recoveries()).length).toBe(1);
    expect(service.state.status).toBe("idle");
    service.dispose();
  });

  test("stopping a new recording is not swallowed by a canceled recording's pending finish", async () => {
    const decoding = deferred<Float32Array>();
    const recorders: MediaRecorder[] = [];
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      () => undefined,
      () => ({ model: "azureMAITranscribe2", language: "automatic" }),
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder: () => {
          const created = recorder();
          recorders.push(created);
          return created;
        },
        decode: () => decoding.promise,
        fetch: async () => new Response(JSON.stringify({ combinedPhrases: [{ text: "Hej" }] })),
      },
    );
    await service.start();
    const first = service.finish();
    await settle();
    service.cancel();
    await service.start();
    const second = service.finish();
    expect(recorders[1]?.state).toBe("inactive");
    decoding.resolve(new Float32Array([0]));
    await Promise.all([first, second]);
    service.dispose();
  });

  test("a recording that outgrows the byte ceiling stops and is transcribed", async () => {
    const texts: string[] = [];
    let active: MediaRecorder | undefined;
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
      scribe,
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder: () => {
          const created = recorder();
          active = created;
          return created;
        },
        fetch: async () => new Response(JSON.stringify({ text: "Long dictation" })),
      },
    );
    await service.start();
    const oversized = { data: new Blob([new Uint8Array(32 * 1024 * 1024 + 1)]) } as BlobEvent;
    if (active) active.ondataavailable?.call(active, oversized);
    expect(active?.state).toBe("inactive");
    await service.finish();
    expect(texts).toEqual(["Long dictation"]);
    service.dispose();
  });

  test("a recording keeps the settings it started with", async () => {
    const sent: string[] = [];
    let settings: TranscriptionSettings = { model: "elevenLabsScribeV2", language: "english" };
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      () => undefined,
      () => settings,
      {
        store: new MemoryRecordings(),
        capture: async () => mediaStream().stream,
        recorder,
        fetch: async (input, init) => {
          const body = init?.body;
          if (!(body instanceof FormData)) throw new Error("Expected a multipart request");
          sent.push(`${String(input)} ${body.get("language_code")}`);
          return new Response(JSON.stringify({ text: "Hello" }));
        },
      },
    );
    await service.start();
    settings = { model: "azureMAITranscribe2", language: "swedish" };
    await service.finish();
    expect(sent).toEqual(["/api/hosts/host-1/speech/elevenlabs/v1/speech-to-text en"]);
    service.dispose();
  });

  test("PCM speech playback interprets signed little endian samples", () => {
    const samples = new Float32Array(4);
    const context = { createBuffer: () => ({ getChannelData: () => samples }) } as unknown as AudioContext;
    decodePCM16(new Uint8Array([0, 128, 0, 0, 0, 64, 255, 127]), 24000, context);
    expect([...samples]).toEqual([-1, 0, 0.5, 32767 / 32768]);
    expect(() => decodePCM16(new Uint8Array([1]), 24000, context)).toThrow("incomplete PCM");
  });
});

describe("dictation transcription follows the native batch engines", () => {
  type Sent = { url: string; init?: RequestInit };
  function relay(responses: unknown[]) {
    const sent: Sent[] = [];
    const fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      sent.push({ url: String(input), init });
      return new Response(JSON.stringify(responses.shift()));
    };
    return { sent, fetch };
  }
  function formOf(request?: Sent) {
    const body = request?.init?.body;
    if (!(body instanceof FormData)) throw new Error("Expected a multipart request");
    return body;
  }
  const audio = new Blob(["recorded microphone audio"], { type: "audio/webm" });
  const signal = new AbortController().signal;

  test("Azure MAI-Transcribe-2 receives native's clean definition and 16 kHz PCM WAV", async () => {
    const { sent, fetch } = relay([{ combinedPhrases: [{ text: "Hej" }, { text: "and hello" }] }]);
    const text = await transcribeRecording(
      "host-1",
      audio,
      { model: "azureMAITranscribe2", language: "englishAndSwedish" },
      signal,
      {
        fetch,
        decode: async (_, rate) => (rate === 16_000 ? new Float32Array([0, 1, -1]) : new Float32Array()),
      },
    );
    expect(text).toBe("Hej\nand hello");
    expect(sent[0]?.url).toBe(
      "/api/hosts/host-1/speech/azure/speechtotext/transcriptions:transcribe?api-version=2025-10-15",
    );
    const form = formOf(sent[0]);
    expect([...form.keys()]).toEqual(["definition", "audio"]);
    expect(JSON.parse(String(form.get("definition")))).toEqual({
      enhancedMode: { enabled: true, model: "MAI-Transcribe-2", modelOptions: { transcribeStyle: "clean" } },
    });
    const wav = new DataView(await (form.get("audio") as File).arrayBuffer());
    expect(wav.byteLength).toBe(50);
    expect(wav.getUint32(24, true)).toBe(16_000);
    expect([wav.getInt16(44, true), wav.getInt16(46, true), wav.getInt16(48, true)]).toEqual([
      0, 32767, -32768,
    ]);
  });

  test("a single language becomes the provider's language and streaming models use their batch model", async () => {
    const azure = relay([{ combinedPhrases: [{ text: "Hej" }] }]);
    await transcribeRecording(
      "host-1",
      audio,
      { model: "azureMAITranscribe2", language: "swedish" },
      signal,
      {
        fetch: azure.fetch,
        decode: async () => new Float32Array([0]),
      },
    );
    expect(JSON.parse(String(formOf(azure.sent[0]).get("definition"))).locales).toEqual(["sv"]);
    const eleven = relay([{ text: "Hello" }]);
    await transcribeRecording(
      "host-1",
      audio,
      { model: "elevenLabsScribeV2Realtime", language: "english" },
      signal,
      { fetch: eleven.fetch },
    );
    const form = formOf(eleven.sent[0]);
    expect(eleven.sent[0]?.url).toBe("/api/hosts/host-1/speech/elevenlabs/v1/speech-to-text");
    expect([...form.keys()]).toEqual(["file", "model_id", "language_code"]);
    expect([form.get("model_id"), form.get("language_code")]).toEqual(["scribe_v2", "en"]);
  });

  test("AssemblyAI uploads, submits language detection for several languages and polls to completion", async () => {
    const { sent, fetch } = relay([
      { upload_url: "https://cdn.assemblyai.com/upload/1" },
      { id: "transcript-1" },
      { status: "processing" },
      { status: "completed", text: "Klart" },
    ]);
    const pauses: number[] = [];
    const text = await transcribeRecording(
      "host-1",
      audio,
      { model: "assemblyAIUniversal35Pro", language: "englishAndSwedish" },
      signal,
      { fetch, wait: async (milliseconds) => void pauses.push(milliseconds) },
    );
    expect(text).toBe("Klart");
    expect(sent.map((request) => request.url.replace("/api/hosts/host-1/speech/assemblyai/", ""))).toEqual([
      "v2/upload",
      "v2/transcript",
      "v2/transcript/transcript-1",
      "v2/transcript/transcript-1",
    ]);
    expect(JSON.parse(String(sent[1]?.init?.body))).toEqual({
      audio_url: "https://cdn.assemblyai.com/upload/1",
      speech_models: ["universal-3-5-pro", "universal-2"],
      language_detection: true,
      language_detection_options: { expected_languages: ["en", "sv"] },
    });
    expect(pauses).toEqual([1000]);
  });

  test("an unreadable AssemblyAI status fails instead of polling forever", async () => {
    const { fetch } = relay([
      { upload_url: "https://cdn.assemblyai.com/upload/1" },
      { id: "transcript-1" },
      {},
    ]);
    await expect(
      transcribeRecording(
        "host-1",
        audio,
        { model: "assemblyAIUniversal35Pro", language: "automatic" },
        signal,
        { fetch, wait: async () => undefined },
      ),
    ).rejects.toThrow("AssemblyAI returned an unreadable transcript status");
  });

  test("an empty transcript is a failure rather than an empty insertion", async () => {
    const { fetch } = relay([{ text: "  " }]);
    await expect(transcribeRecording("host-1", audio, scribe(), signal, { fetch })).rejects.toThrow(
      "Transcription returned no text.",
    );
  });
});
