import type { Frame } from "../protocol/boundary";
import {
  boundedVoiceHistory,
  canceled,
  errorMessage,
  type FeatureTransport,
  isCanceled,
  record,
  requiredString,
  type VoiceContext,
  type VoiceHistoryItem,
} from "./contracts";

export type VoiceTranscriptEntry = {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt: number;
};
export type VoiceState = {
  status:
    | "idle"
    | "requestingMicrophone"
    | "connecting"
    | "connected"
    | "reconnecting"
    | "stopping"
    | "failed";
  muted: boolean;
  realtimeSessionId?: string;
  realtimeThreadId?: string;
  model?: string;
  effort?: string | null;
  liveUser: string;
  liveAssistant: string;
  transcript: VoiceTranscriptEntry[];
  error?: string;
};

export type VoiceEnvironment = {
  capture: () => Promise<MediaStream>;
  peer: () => RTCPeerConnection;
  audio: () => HTMLAudioElement;
  id: () => string;
};

function browserEnvironment(): VoiceEnvironment {
  return {
    capture: () => {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error("Voice Mode requires HTTPS or localhost");
      return navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
    },
    peer: () => new RTCPeerConnection(),
    audio: () => new Audio(),
    id: () => crypto.randomUUID(),
  };
}

export class BrowserVoiceSession {
  private generation = 0;
  private peer?: RTCPeerConnection;
  private microphone?: MediaStream;
  private audio?: HTMLAudioElement;
  private unsubscribe?: () => void;
  private startup?: Promise<void>;
  private stopping?: Promise<void>;
  private remoteRequested = false;
  private retired = false;
  private context?: VoiceContext;
  private answers = new Map<string, string>();
  private answerSDP?: string;
  private answerTimeout?: ReturnType<typeof setTimeout>;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private reconnectAttempts = 0;
  private reportedConnected = false;
  private readonly environment: VoiceEnvironment;
  state: VoiceState = { status: "idle", muted: false, liveUser: "", liveAssistant: "", transcript: [] };

  constructor(
    readonly transport: FeatureTransport,
    private readonly onState: (state: VoiceState) => void,
    environment?: VoiceEnvironment,
  ) {
    this.environment = environment ?? browserEnvironment();
  }

  private publish(change: Partial<VoiceState>): void {
    this.state = { ...this.state, ...change };
    if (!this.retired) this.onState(this.state);
  }

  async listVoices(): Promise<string[]> {
    const response = record(await this.transport.request("voice/listVoices", {}));
    if (
      !Array.isArray(response.voices) ||
      response.voices.length > 128 ||
      response.voices.some((value) => typeof value !== "string")
    )
      throw new Error("The gateway returned an unreadable voice catalog");
    return response.voices as string[];
  }

  async start(context: VoiceContext): Promise<void> {
    if (this.retired) throw new Error("Voice Mode has been retired");
    requiredString(context.conversationThreadId, "conversation thread");
    requiredString(context.cwd, "conversation working directory");
    requiredString(context.model, "conversation model");
    await this.stop();
    if (this.retired) throw canceled();
    this.context = { ...context, initialItems: boundedVoiceHistory(context.initialItems) };
    this.reconnectAttempts = 0;
    this.state = {
      status: "requestingMicrophone",
      muted: false,
      realtimeSessionId: this.environment.id(),
      model: context.model,
      effort: context.effort,
      liveUser: "",
      liveAssistant: "",
      transcript: [],
    };
    const generation = ++this.generation;
    this.publish({});
    this.unsubscribe = this.transport.subscribe((frame) => this.receive(frame));
    await this.startConnection(generation, true);
  }

  private async startConnection(generation: number, replaceExistingSession: boolean): Promise<void> {
    const operation = this.connectMedia(generation, replaceExistingSession);
    this.startup = operation;
    try {
      await operation;
    } catch (error) {
      if (generation !== this.generation || this.retired || isCanceled(error)) return;
      await this.end(true, errorMessage(error), false);
      throw error;
    } finally {
      if (this.startup === operation) this.startup = undefined;
    }
  }

  private async connectMedia(generation: number, replaceExistingSession: boolean): Promise<void> {
    const stream = await this.environment.capture();
    if (generation !== this.generation || this.retired) {
      for (const track of stream.getTracks()) track.stop();
      throw canceled();
    }
    this.microphone = stream;
    const peer = this.environment.peer();
    this.peer = peer;
    const audio = this.environment.audio();
    audio.autoplay = true;
    this.audio = audio;
    for (const track of stream.getAudioTracks()) {
      track.enabled = !this.state.muted;
      peer.addTrack(track, stream);
    }
    peer.createDataChannel("oai-events");
    peer.ontrack = (event) => {
      if (generation !== this.generation || this.peer !== peer) return;
      audio.srcObject = event.streams[0] ?? new MediaStream([event.track]);
      void audio.play().catch((error) => {
        if (generation === this.generation)
          this.publish({ error: `Audio playback needs a user action: ${errorMessage(error)}` });
      });
    };
    peer.onconnectionstatechange = () => {
      if (generation !== this.generation || this.peer !== peer) return;
      if (peer.connectionState === "connected") this.connected(generation);
      else if (peer.connectionState === "failed" || peer.connectionState === "disconnected")
        this.scheduleReconnect(generation);
    };
    this.publish({ status: replaceExistingSession ? "connecting" : "reconnecting" });
    const offer = await peer.createOffer({ offerToReceiveAudio: true });
    if (generation !== this.generation) throw canceled();
    await peer.setLocalDescription(offer);
    if (generation !== this.generation) throw canceled();
    const context = this.context;
    if (!context || !this.state.realtimeSessionId) throw canceled();
    this.remoteRequested = true;
    const response = record(
      await this.transport.request(
        "voice/session/start",
        {
          conversationThreadId: context.conversationThreadId,
          realtimeSessionId: this.state.realtimeSessionId,
          replaceExistingSession,
          cwd: context.cwd,
          model: context.model,
          effort: context.effort ?? null,
          sdp: requiredString(offer.sdp, "WebRTC offer"),
          voice: context.voice ?? null,
          initialItems: context.initialItems,
        },
        { timeout: 150000 },
      ),
    );
    if (generation !== this.generation || this.retired) throw canceled();
    const realtimeThreadId = requiredString(response.realtimeThreadId, "realtime thread");
    const model = requiredString(response.model, "voice model");
    const effort = typeof response.effort === "string" ? response.effort : null;
    this.context = { ...context, model, effort };
    this.publish({ realtimeThreadId, model, effort });
    this.answerTimeout = setTimeout(() => {
      if (generation === this.generation)
        void this.end(true, "The realtime service did not answer the media connection");
    }, 30000);
    const pending = this.answers.get(realtimeThreadId);
    this.answers.clear();
    if (pending) await this.applyAnswer(pending, generation);
  }

  private connected(generation: number): void {
    this.publish({ status: "connected", error: undefined });
    if (this.reportedConnected || !this.state.realtimeSessionId) return;
    this.reportedConnected = true;
    void this.transport
      .request("voice/session/connected", { realtimeSessionId: this.state.realtimeSessionId })
      .catch((error) => {
        if (generation === this.generation)
          this.publish({
            error: `Connected, but the greeting could not be confirmed: ${errorMessage(error)}`,
          });
      });
  }

  private async applyAnswer(sdp: string, generation: number): Promise<void> {
    const peer = this.peer;
    if (!peer || generation !== this.generation) return;
    if (this.answerSDP === sdp) return;
    if (this.answerSDP) throw new Error("The realtime service sent conflicting media answers");
    this.answerSDP = sdp;
    await peer.setRemoteDescription({ type: "answer", sdp });
    if (generation !== this.generation) return;
    clearTimeout(this.answerTimeout);
    this.answerTimeout = undefined;
  }

  private receive(frame: Frame): void {
    if (
      !frame.method ||
      (!frame.method.startsWith("thread/realtime/") && !frame.method.startsWith("voice/session/"))
    )
      return;
    if (["idle", "stopping", "failed"].includes(this.state.status)) return;
    try {
      const params = record(frame.params);
      const generation = this.generation;
      if (frame.method === "voice/session/preempted" || frame.method === "voice/session/agentEnded") {
        if (params.realtimeSessionId === this.state.realtimeSessionId)
          void this.end(
            false,
            frame.method.endsWith("preempted") ? "Voice Mode was opened in another client" : undefined,
          );
        return;
      }
      if (frame.method === "thread/realtime/sdp") {
        const threadId = requiredString(params.threadId, "realtime thread");
        const sdp = requiredString(params.sdp, "WebRTC answer");
        if (sdp.length > 256 * 1024) throw new Error("WebRTC answer exceeds capacity");
        if (threadId === this.state.realtimeThreadId) {
          void this.applyAnswer(sdp, generation).catch((error) => {
            if (generation === this.generation) void this.end(true, errorMessage(error));
          });
        } else if (!this.state.realtimeThreadId && this.answers.size < 4) this.answers.set(threadId, sdp);
        return;
      }
      if (params.threadId !== this.state.realtimeThreadId) return;
      if (frame.method === "thread/realtime/error") {
        void this.end(true, requiredString(params.message, "voice error"));
      } else if (frame.method === "thread/realtime/closed") this.scheduleReconnect(generation);
      else if (
        frame.method === "thread/realtime/transcript/delta" ||
        frame.method === "thread/realtime/transcript/done"
      ) {
        if (params.role !== "user" && params.role !== "assistant")
          throw new Error("Unknown voice transcript role");
        const key = params.role === "user" ? "liveUser" : "liveAssistant";
        if (frame.method.endsWith("delta")) {
          if (typeof params.delta !== "string") throw new Error("Unreadable voice transcript delta");
          this.publish({ [key]: (this.state[key] + params.delta).slice(-65536) });
        } else {
          if (typeof params.text !== "string") throw new Error("Unreadable voice transcript");
          const text = params.text.trim().slice(-65536);
          const entry: VoiceTranscriptEntry = {
            id: this.environment.id(),
            role: params.role,
            text,
            createdAt: Date.now(),
          };
          const transcript = text ? [...this.state.transcript, entry].slice(-80) : this.state.transcript;
          this.publish({ [key]: "", transcript });
        }
      }
    } catch (error) {
      void this.end(true, errorMessage(error));
    }
  }

  private scheduleReconnect(generation: number): void {
    if (this.reconnectTimer || generation !== this.generation) return;
    if (this.reconnectAttempts >= 1) {
      void this.end(true, "The realtime media connection failed after reconnecting");
      return;
    }
    this.publish({ status: "reconnecting" });
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (generation !== this.generation || this.retired) return;
      this.reconnectAttempts += 1;
      const history: VoiceHistoryItem[] = this.state.transcript.map((item) => ({
        role: item.role,
        text: item.text,
      }));
      if (this.context)
        this.context = {
          ...this.context,
          initialItems: boundedVoiceHistory([...this.context.initialItems, ...history]),
        };
      this.closeMedia();
      this.publish({ realtimeThreadId: undefined });
      void this.startConnection(++this.generation, false).catch(() => undefined);
    }, 2000);
  }

  setMuted(muted: boolean): void {
    for (const track of this.microphone?.getAudioTracks() ?? []) track.enabled = !muted;
    this.publish({ muted });
  }

  async resumePlayback(): Promise<void> {
    if (!this.audio?.srcObject) throw new Error("Voice audio is not connected yet");
    await this.audio.play();
    this.publish({ error: undefined });
  }

  private closeMedia(): void {
    clearTimeout(this.answerTimeout);
    clearTimeout(this.reconnectTimer);
    this.answerTimeout = undefined;
    this.reconnectTimer = undefined;
    this.answers.clear();
    this.answerSDP = undefined;
    this.reportedConnected = false;
    if (this.peer) {
      this.peer.ontrack = null;
      this.peer.onconnectionstatechange = null;
      this.peer.close();
      this.peer = undefined;
    }
    for (const track of this.microphone?.getTracks() ?? []) track.stop();
    this.microphone = undefined;
    if (this.audio) {
      this.audio.pause();
      this.audio.srcObject = null;
      this.audio = undefined;
    }
  }

  private end(stopRemote: boolean, error?: string, waitForStartup = true): Promise<void> {
    if (this.stopping) return this.stopping;
    const generation = ++this.generation;
    const startup = this.startup;
    const requested = this.remoteRequested;
    this.closeMedia();
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.publish({ status: "stopping" });
    const operation = (async () => {
      let failure = error;
      let stopped = !requested || !stopRemote;
      if (waitForStartup && requested) await startup?.catch(() => undefined);
      if (requested && stopRemote) {
        try {
          await this.transport.request("voice/session/stop", {});
          stopped = true;
        } catch (cause) {
          failure = `Audio stopped locally. Gateway cleanup could not be confirmed: ${errorMessage(cause)}`;
        }
      }
      this.remoteRequested = !stopped;
      if (generation === this.generation)
        this.publish({
          status: failure ? "failed" : "idle",
          error: failure,
          realtimeThreadId: undefined,
          liveUser: "",
          liveAssistant: "",
        });
    })();
    this.stopping = operation;
    void operation
      .finally(() => {
        if (this.stopping === operation) this.stopping = undefined;
      })
      .catch(() => undefined);
    return operation;
  }

  stop(): Promise<void> {
    return this.end(true);
  }

  dispose(): Promise<void> {
    this.retired = true;
    return this.stop();
  }
}
