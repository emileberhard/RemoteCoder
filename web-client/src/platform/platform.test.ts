import { describe, expect, test } from "bun:test";
import type { Frame } from "../protocol/boundary";
import type { FeatureTransport, VoiceContext } from "./contracts";
import { BrowserDictation } from "./dictation";
import type { RecordingStore, SavedRecording } from "./recordings";
import { decodePCM16 } from "./speech";
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

  test("canceling a pending transcription fences late text and retains the saved recording", async () => {
    const store = new MemoryRecordings();
    const response = deferred<Response>();
    const texts: string[] = [];
    const service = new BrowserDictation(
      "host-1",
      () => undefined,
      (text) => texts.push(text),
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

  test("PCM speech playback interprets signed little endian samples", () => {
    const samples = new Float32Array(4);
    const context = { createBuffer: () => ({ getChannelData: () => samples }) } as unknown as AudioContext;
    decodePCM16(new Uint8Array([0, 128, 0, 0, 0, 64, 255, 127]), 24000, context);
    expect([...samples]).toEqual([-1, 0, 0.5, 32767 / 32768]);
    expect(() => decodePCM16(new Uint8Array([1]), 24000, context)).toThrow("incomplete PCM");
  });
});
