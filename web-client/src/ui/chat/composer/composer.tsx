import {
  AlertCircle,
  ArrowUp,
  AudioLines,
  ChevronDown,
  ChevronRight,
  Clock,
  File,
  MessageCircle,
  Plus,
  Square,
  X,
  Zap,
} from "lucide-react";
import { type Ref, useEffect, useImperativeHandle, useMemo, useRef, useState } from "react";
import { BrowserUploadService } from "../../../platform";
import { string } from "../../../protocol/boundary";
import type { Attachment } from "../../../workspace/composer-draft-store";
import type { Conversation } from "../../../workspace/conversation-session";
import { IconButton } from "../../design-system/icon-button";
import { effortLabel, inputText } from "../../formatting";
import { useRun, useWorkspace } from "../../workspace-context";
import { DictationControl } from "../media";
import { ContextWindowGauge } from "./context-window-gauge";
import { ReasoningGauge } from "./reasoning-gauge";

export type ComposerHandle = Readonly<{ focus(): void; attachFile(): void }>;

export function Composer({
  ref,
  conversation,
  openVoice,
}: {
  ref: Ref<ComposerHandle>;
  conversation?: Conversation;
  openVoice(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const draft = workspace.draft;
  const choices = workspace.choices();
  const provider = conversation?.header.provider;
  const available = useMemo(
    () => choices.filter((choice) => !provider || choice.provider === provider),
    [choices, provider],
  );
  const choice = available.find((choice) => choice.id === draft.model && choice.provider === draft.provider);
  const contextUsage = workspace.contextWindowUsage;
  const fileInput = useRef<HTMLInputElement>(null);
  const textarea = useRef<HTMLTextAreaElement>(null);
  useImperativeHandle(
    ref,
    () => ({ focus: () => textarea.current?.focus(), attachFile: () => fileInput.current?.click() }),
    [],
  );
  const [uploading, setUploading] = useState(false);
  const uploadOwner = useRef<AbortController | undefined>(undefined);
  const [dragging, setDragging] = useState(false);
  useEffect(() => () => uploadOwner.current?.abort(), []);
  const attach = async (files: FileList | File[]) => {
    if (uploadOwner.current) throw new Error("An attachment upload is already in progress");
    const host = workspace.selectedHost;
    if (!host) throw new Error("Choose a host before attaching files");
    const key = workspace.draftKey;
    if (draft.attachments.length + files.length > 8) throw new Error("Attach up to eight files per message");
    const controller = new AbortController();
    uploadOwner.current = controller;
    const uploader = new BrowserUploadService(host.host.id);
    workspace.updateDraft({}, key);
    setUploading(true);
    try {
      const attachments: Attachment[] = [];
      for (const file of Array.from(files)) {
        if (!file.size || file.size > 50 * 1024 * 1024)
          throw new Error("Each attachment must be between 1 byte and 50 MiB");
        const result = await uploader.upload(file, { signal: controller.signal });
        attachments.push({
          id: crypto.randomUUID(),
          name: file.name,
          bytes: file.size,
          type: file.type,
          path: string(result.path),
          sha256: result.sha256,
        });
      }
      const latest = workspace.getSnapshot().drafts.get(key);
      if (!latest) throw new Error("The attachment's original draft is unavailable");
      if (latest.attachments.length + attachments.length > 8)
        throw new Error("Attach up to eight files per message");
      workspace.updateDraft({ attachments: [...latest.attachments, ...attachments] }, key);
    } finally {
      uploader.dispose();
      if (uploadOwner.current === controller) uploadOwner.current = undefined;
      setUploading(false);
      if (fileInput.current) fileInput.current.value = "";
    }
  };
  const send = (mode: "send" | "queue") => run(() => workspace.send(mode));
  const sendDisabledReason = uploading
    ? "Wait for the attachment upload"
    : workspace.isSubmitting
      ? "Waiting for the current submission"
      : !choice
        ? "Choose an available model"
        : !draft.text.trim() && !draft.attachments.length
          ? "Write a message or attach a file"
          : draft.uncertain
            ? "Resolve uncertain delivery before sending again"
            : undefined;
  const editText = (text: string) => {
    if (workspace.draft.text !== text) workspace.updateDraft({ text });
  };
  const pendingQuestions =
    conversation?.questions.status === "ready" && conversation.questions.value.coverage === "ready"
      ? conversation.questions.value.records.filter(
          (record) =>
            conversation.questions.status === "ready" &&
            conversation.questions.value.pendingItemIds?.includes(record.itemId),
        )
      : [];
  return (
    <div className="composer-dock">
      <div className="composer-width">
        {conversation?.queue.status === "ready" && conversation.queue.value.length > 0 && (
          <div className="queued-messages">
            {conversation.queue.value.map((entry) => (
              <div key={entry.id}>
                <Clock size={13} />
                <span>{inputText(entry.input as { type: string; text?: string }[])}</span>
                <IconButton
                  label="Remove queued message"
                  onClick={() => run(() => workspace.deleteQueued(entry.id))}
                >
                  <X size={14} />
                </IconButton>
              </div>
            ))}
          </div>
        )}
        {pendingQuestions.length > 0 && (
          <button
            type="button"
            className="pending-question-bar"
            onClick={() =>
              document
                .querySelector(".question-card")
                ?.scrollIntoView({ block: "center", behavior: "smooth" })
            }
          >
            <MessageCircle size={15} />
            {pendingQuestions.length === 1
              ? "The agent has a question for you"
              : `${pendingQuestions.length} questions for you`}
            <ChevronRight size={15} />
          </button>
        )}
        {draft.uncertain && (
          <div className="uncertain-draft">
            <AlertCircle size={16} />
            <span>Delivery uncertain. Check the transcript before sending again.</span>
            <button
              type="button"
              onClick={() => conversation && run(() => workspace.loadConversation(conversation.address))}
            >
              Refresh
            </button>
            <button
              type="button"
              onClick={() => {
                if (window.confirm("The gateway may have accepted this message. Keep it as a draft anyway?"))
                  workspace.updateDraft({ uncertain: undefined });
              }}
            >
              Keep draft
            </button>
          </div>
        )}
        <div
          role="presentation"
          className={`composer ${dragging ? "dragging" : ""}`}
          onDragOver={(event) => {
            event.preventDefault();
            setDragging(true);
          }}
          onDragLeave={() => setDragging(false)}
          onDrop={(event) => {
            event.preventDefault();
            setDragging(false);
            run(() => attach(event.dataTransfer.files));
          }}
        >
          {draft.attachments.length > 0 && (
            <div className="attachments">
              {draft.attachments.map((attachment) => (
                <div className="attachment-tile" key={attachment.id}>
                  <File size={21} />
                  <span>
                    {attachment.name}
                    <small>{(attachment.bytes / 1024).toFixed(0)} KB</small>
                  </span>
                  <IconButton
                    label={`Remove ${attachment.name}`}
                    onClick={() =>
                      workspace.updateDraft({
                        attachments: draft.attachments.filter((file) => file.id !== attachment.id),
                      })
                    }
                  >
                    <X size={13} />
                  </IconButton>
                </div>
              ))}
            </div>
          )}
          <div className="composer-options">
            <div className="model-control">
              <span aria-hidden="true">
                {choice?.name ??
                  (workspace.selectedHost?.choices.status === "loading" ? "Loading models…" : "Choose model")}
              </span>
              <select
                aria-label="Model"
                value={choice ? `${choice.provider}:${choice.id}` : ""}
                onChange={(event) => {
                  const next = available.find(
                    (choice) => `${choice.provider}:${choice.id}` === event.target.value,
                  );
                  run(() => workspace.chooseModel(next));
                }}
                disabled={!available.length}
              >
                <option value="" disabled>
                  {workspace.selectedHost?.choices.status === "loading" ? "Loading models…" : "Choose model"}
                </option>
                <optgroup label="Codex">
                  {available
                    .filter((choice) => choice.provider === "codex")
                    .map((choice) => (
                      <option key={choice.id} value={`${choice.provider}:${choice.id}`}>
                        {choice.name}
                      </option>
                    ))}
                </optgroup>
                <optgroup label="Claude">
                  {available
                    .filter((choice) => choice.provider === "claude")
                    .map((choice) => (
                      <option key={choice.id} value={`${choice.provider}:${choice.id}`}>
                        {choice.name}
                      </option>
                    ))}
                </optgroup>
              </select>
              <ChevronDown size={14} strokeWidth={2.4} />
            </div>
            <span className="composer-spacer" />
            {contextUsage && <ContextWindowGauge usage={contextUsage} />}
            <div className="reasoning-control" title={`Reasoning: ${effortLabel(draft.effort)}`}>
              <ReasoningGauge efforts={choice?.efforts ?? []} effort={draft.effort} />
              <select
                aria-label="Reasoning effort"
                value={draft.effort}
                disabled={!choice}
                onChange={(event) => run(() => workspace.chooseReasoning(event.target.value))}
              >
                <option value="">Auto</option>
                {choice?.efforts.map((effort) => (
                  <option value={effort} key={effort}>
                    {effortLabel(effort)}
                  </option>
                ))}
              </select>
            </div>
            <button
              type="button"
              className={`fast-toggle ${draft.fast ? "enabled" : ""}`}
              aria-pressed={draft.fast}
              aria-label="Fast mode"
              title="Fast mode"
              disabled={!choice?.fast}
              onClick={() => run(() => workspace.chooseFastMode(!draft.fast))}
            >
              <Zap size={17} />
            </button>
          </div>
          <div className="composer-input">
            <IconButton
              label={uploading ? "Uploading attachment" : "Attach files"}
              onClick={() => fileInput.current?.click()}
              disabled={uploading || !workspace.selectedHost}
            >
              <Plus size={22} />
            </IconButton>
            <input
              ref={fileInput}
              hidden
              type="file"
              multiple
              onChange={(event) => event.target.files && run(() => attach(event.target.files as FileList))}
            />
            <textarea
              ref={textarea}
              aria-label="Message"
              placeholder={
                conversation?.activeTurnId
                  ? "Guide the next steps…"
                  : draft.provider === "claude"
                    ? "Message Claude…"
                    : "Message Codex…"
              }
              value={draft.text}
              maxLength={256000}
              onInput={(event) => editText(event.currentTarget.value)}
              onChange={(event) => editText(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                  event.preventDefault();
                  send("send");
                }
              }}
              onPaste={(event) => {
                if (event.clipboardData.files.length) {
                  event.preventDefault();
                  run(() => attach(event.clipboardData.files));
                }
              }}
              disabled={!workspace.selectedHost}
              rows={1}
            />
            <IconButton
              label="Open Voice Mode"
              onClick={openVoice}
              disabled={
                !workspace.selectedHost ||
                workspace.isSubmitting ||
                (conversation !== undefined && conversation.status !== "ready")
              }
            >
              <AudioLines size={20} />
            </IconButton>
            <DictationControl />
            {conversation?.activeTurnId && conversation.header.provider !== "claude" && (
              <IconButton
                label="Queue message"
                disabled={
                  uploading || workspace.isSubmitting || (!draft.text.trim() && !draft.attachments.length)
                }
                onClick={() => send("queue")}
              >
                <Clock size={18} />
              </IconButton>
            )}
            {conversation?.activeTurnId && !draft.text.trim() && !draft.attachments.length ? (
              <button
                type="button"
                className="send-button stop-button"
                aria-label="Stop turn"
                onClick={() => run(() => workspace.interrupt())}
              >
                <Square size={14} fill="currentColor" />
              </button>
            ) : (
              <button
                type="button"
                className="send-button"
                aria-label={conversation?.activeTurnId ? "Steer turn" : "Send message"}
                title={sendDisabledReason}
                disabled={Boolean(sendDisabledReason)}
                onClick={() => send("send")}
              >
                <ArrowUp size={19} />
              </button>
            )}
          </div>
        </div>
        {uploading && (
          <div className="composer-status">
            <span>Uploading…</span>
          </div>
        )}
      </div>
    </div>
  );
}
