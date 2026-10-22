import { AudioLines, Mic, MicOff, Play, Square, Trash2, Volume2, X } from "lucide-react";
import { createContext, type ReactNode, useCallback, useContext, useEffect, useRef, useState } from "react";
import {
  BrowserDictation,
  BrowserSpeechOutput,
  BrowserVoiceSession,
  boundedVoiceHistory,
  type DictationState,
  type SavedRecording,
  type SpeechOutputState,
  type VoiceHistoryItem,
  type VoiceState,
} from "../../platform";
import { addressKey } from "../../protocol/boundary";
import type { Conversation } from "../../workspace/conversation-session";
import { useWorkspace } from "../workspace-context";

const SpeechContext = createContext<{
  state: SpeechOutputState;
  active?: string;
  speak(id: string, text: string): void;
}>({ state: { status: "idle" }, speak: () => undefined });

export function MediaProvider({ hostId, children }: { hostId?: string; children: ReactNode }) {
  const workspace = useWorkspace();
  const service = useRef<BrowserSpeechOutput | undefined>(undefined);
  const [state, setState] = useState<SpeechOutputState>({ status: "idle" });
  const [active, setActive] = useState<string>();
  useEffect(() => {
    setState({ status: "idle" });
    setActive(undefined);
    if (!hostId) return;
    const output = new BrowserSpeechOutput(hostId, setState);
    service.current = output;
    return () => {
      output.dispose();
      if (service.current === output) service.current = undefined;
    };
  }, [hostId]);
  const speak = (id: string, text: string) => {
    if (active === id && (state.status === "speaking" || state.status === "preparing")) {
      service.current?.cancel();
      setActive(undefined);
      return;
    }
    setActive(id);
    void service.current?.speak(text).catch((error) => workspace.report(error));
  };
  return <SpeechContext.Provider value={{ state, active, speak }}>{children}</SpeechContext.Provider>;
}

export function SpeakButton({ id, text }: { id: string; text: string }) {
  const speech = useContext(SpeechContext);
  const active = speech.active === id && ["speaking", "preparing"].includes(speech.state.status);
  return (
    <button
      type="button"
      className={`icon-button speak-button ${active ? "active" : ""}`}
      aria-label={active ? "Stop spoken reply" : "Read reply aloud"}
      title={active ? "Stop spoken reply" : "Read reply aloud"}
      onClick={() => speech.speak(id, text)}
    >
      {active ? <Square size={13} /> : <Volume2 size={15} />}
    </button>
  );
}

export function DictationControl() {
  const workspace = useWorkspace();
  const hostId = workspace.selectedHost?.host.id;
  const service = useRef<BrowserDictation | undefined>(undefined);
  const owner = useRef<{ key?: string }>({});
  const [state, setState] = useState<DictationState>({ status: "idle" });
  const [saved, setSaved] = useState<SavedRecording[]>([]);
  const [expanded, setExpanded] = useState(false);
  const refresh = useCallback(async (dictation: BrowserDictation) => {
    const recordings = await dictation.recoveries();
    if (service.current === dictation) setSaved(recordings);
  }, []);
  useEffect(() => {
    setState({ status: "idle" });
    setSaved([]);
    if (!hostId) return;
    const capturedOwner: { key?: string } = {};
    owner.current = capturedOwner;
    const dictation = new BrowserDictation(
      hostId,
      (next) => {
        if (service.current === dictation) setState(next);
      },
      (text) => {
        const key = capturedOwner.key;
        if (workspace.isRetired)
          throw new Error("The workspace closed; the recording was retained for recovery.");
        if (!key) throw new Error("The original dictation draft is unavailable; the recording was retained.");
        const draft = workspace.getSnapshot().drafts.get(key);
        if (!draft)
          throw new Error("The original dictation draft is unavailable; the recording was retained.");
        workspace.updateDraft({ text: [draft.text.trimEnd(), text].filter(Boolean).join("\n") }, key);
      },
    );
    service.current = dictation;
    void refresh(dictation).catch((error) => workspace.report(error));
    return () => {
      if (service.current === dictation) service.current = undefined;
      if (dictation.state.status === "recording" || dictation.state.status === "transcribing")
        void dictation
          .finish()
          .catch((error) => workspace.report(error))
          .finally(() => dictation.dispose());
      else dictation.dispose();
    };
  }, [hostId, workspace, refresh]);
  const execute = (operation: (dictation: BrowserDictation) => Promise<void>) => {
    const dictation = service.current;
    if (!dictation) return;
    void operation(dictation)
      .catch((error) => workspace.report(error))
      .finally(() => void refresh(dictation).catch((error) => workspace.report(error)));
  };
  const captureOwner = () => {
    owner.current.key = workspace.draftKey;
    workspace.updateDraft({}, owner.current.key);
  };
  const busy = state.status === "starting" || state.status === "transcribing";
  return (
    <div className="dictation-control">
      <button
        type="button"
        className={`icon-button ${state.status === "recording" ? "recording" : ""}`}
        aria-label={
          state.status === "recording"
            ? "Finish dictation"
            : busy
              ? "Transcribing dictation"
              : "Dictate message"
        }
        title={state.error ?? (state.status === "recording" ? "Finish dictation" : "Dictate message")}
        disabled={!hostId || busy}
        onClick={() => {
          if (state.status === "recording") execute((dictation) => dictation.finish());
          else {
            captureOwner();
            execute((dictation) => dictation.start());
          }
        }}
      >
        {state.status === "recording" ? <Square size={16} /> : <Mic size={18} />}
      </button>
      {(state.status === "recording" || busy) && (
        <button
          type="button"
          className="icon-button"
          aria-label="Cancel dictation"
          onClick={() => service.current?.cancel()}
        >
          <X size={14} />
        </button>
      )}
      {saved.length > 0 && (
        <button
          type="button"
          className="text-button recovery-toggle"
          onClick={() => setExpanded((value) => !value)}
        >
          {saved.length} saved recording{saved.length === 1 ? "" : "s"}
        </button>
      )}
      {expanded && saved.length > 0 && (
        <div className="recording-recovery menu-surface">
          <strong>Saved dictation</strong>
          <p>Retry into the selected draft or download the recording.</p>
          {saved.map((recording) => (
            <div key={recording.id}>
              <span>{new Date(recording.createdAt).toLocaleString()}</span>
              <button
                type="button"
                disabled={busy || state.status === "recording"}
                onClick={() => {
                  captureOwner();
                  execute((dictation) => dictation.retry(recording.id));
                }}
              >
                Retry
              </button>
              <button
                type="button"
                onClick={() => {
                  const url = URL.createObjectURL(recording.blob);
                  const link = document.createElement("a");
                  link.href = url;
                  link.download = `dictation-${recording.id}.${recording.blob.type.includes("mp4") ? "m4a" : "webm"}`;
                  link.click();
                  setTimeout(() => URL.revokeObjectURL(url), 1000);
                }}
              >
                Download
              </button>
              <button
                type="button"
                aria-label="Discard saved recording"
                onClick={() => execute((dictation) => dictation.discard(recording.id))}
              >
                <Trash2 size={14} />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function VoiceDialog({ conversation, close }: { conversation: Conversation; close(): void }) {
  const workspace = useWorkspace();
  const dialog = useRef<HTMLDialogElement>(null);
  const service = useRef<BrowserVoiceSession | undefined>(undefined);
  const [state, setState] = useState<VoiceState>({
    status: "idle",
    muted: false,
    liveUser: "",
    liveAssistant: "",
    transcript: [],
  });
  const [voices, setVoices] = useState<string[]>([]);
  const [voice, setVoice] = useState("");
  const identity = addressKey(conversation.address);
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    const session = new BrowserVoiceSession(workspace.featureTransport(conversation.address), setState);
    service.current = session;
    void session
      .listVoices()
      .then((catalog) => {
        if (service.current === session) setVoices(catalog);
      })
      .catch((error) => workspace.report(error));
    return () => {
      element?.close();
      if (service.current === session) service.current = undefined;
      void session.dispose().catch((error) => workspace.report(error));
    };
  }, [workspace, conversation.address]);
  const start = () => {
    const draft = workspace.getSnapshot().drafts.get(identity);
    const history: VoiceHistoryItem[] = [];
    for (const row of conversation.rows) {
      const item = row.entry.item;
      if (item.type === "userMessage")
        history.push({
          role: "user",
          text: item.content
            .filter((part) => part.type === "text")
            .map((part) => part.text)
            .join("\n"),
        });
      else if (item.type === "agentMessage") history.push({ role: "assistant", text: item.text });
    }
    void service.current
      ?.start({
        conversationThreadId: conversation.address.threadId,
        cwd: draft?.cwd ?? conversation.header.cwd,
        model: draft?.model || conversation.header.model || "",
        effort: draft?.effort ?? conversation.header.reasoningEffort,
        ...(voice ? { voice } : {}),
        initialItems: boundedVoiceHistory(history),
      })
      .catch((error) => workspace.report(error));
  };
  const active = !["idle", "failed"].includes(state.status);
  return (
    <dialog ref={dialog} className="dialog voice-dialog" onCancel={close}>
      <div className="dialog-header">
        <h2>Voice Mode</h2>
        <button type="button" className="icon-button" aria-label="Close Voice Mode" onClick={close}>
          <X size={19} />
        </button>
      </div>
      <div className={`voice-orb ${active ? "active" : ""}`}>
        <AudioLines size={42} />
      </div>
      <p className="voice-status" role="status">
        {state.status === "requestingMicrophone"
          ? "Requesting microphone"
          : state.status.charAt(0).toUpperCase() + state.status.slice(1)}
      </p>
      <p className="subtle">
        {conversation.header.name || conversation.header.preview.slice(0, 80) || "Current conversation"}
      </p>
      {state.error && <p className="error">{state.error}</p>}
      <label className="voice-picker">
        Voice
        <select value={voice} disabled={active} onChange={(event) => setVoice(event.target.value)}>
          <option value="">Host default</option>
          {voices.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
      </label>
      <div className="voice-controls">
        {active ? (
          <>
            <button
              type="button"
              aria-pressed={state.muted}
              onClick={() => service.current?.setMuted(!state.muted)}
            >
              {state.muted ? <MicOff size={18} /> : <Mic size={18} />}
              {state.muted ? "Unmute" : "Mute"}
            </button>
            <button
              type="button"
              onClick={() => void service.current?.resumePlayback().catch((error) => workspace.report(error))}
            >
              <Play size={17} />
              Play audio
            </button>
            <button
              type="button"
              className="primary"
              onClick={() => void service.current?.stop().catch((error) => workspace.report(error))}
            >
              <Square size={16} />
              End voice
            </button>
          </>
        ) : (
          <button type="button" className="primary" onClick={start}>
            <Mic size={18} />
            Start voice
          </button>
        )}
      </div>
      <div className="voice-transcript" aria-live="polite">
        {state.transcript.map((entry) => (
          <p key={entry.id} className={entry.role}>
            <strong>{entry.role === "user" ? "You" : "Assistant"}</strong>
            {entry.text}
          </p>
        ))}
        {state.liveUser && (
          <p className="user">
            <strong>You</strong>
            {state.liveUser}
          </p>
        )}
        {state.liveAssistant && (
          <p className="assistant">
            <strong>Assistant</strong>
            {state.liveAssistant}
          </p>
        )}
      </div>
    </dialog>
  );
}
