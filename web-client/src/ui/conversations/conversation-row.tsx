import {
  Check,
  CircleCheck,
  CircleHelp,
  Ellipsis,
  Hand,
  History,
  MessageCircleQuestion,
  Pin,
} from "lucide-react";
import { providerForThread } from "../../protocol/agent-provider";
import type { ConversationActivityState } from "../../workspace/conversation-activity";
import type { ConversationSidebarRow } from "../../workspace/conversation-sidebar-projection";
import { ProviderMark } from "../design-system/provider-mark";
import { age } from "../formatting";

const activityPresentation = {
  working: { title: "Working", Icon: Ellipsis },
  waiting: { title: "Needs input", Icon: Hand },
  idle: { title: "Ready", Icon: Check },
  unknown: { title: "Checking status", Icon: CircleHelp },
} satisfies Record<ConversationActivityState, unknown>;

export function ActivityIndicator({
  state,
  labeled,
}: {
  state: ConversationActivityState;
  labeled: boolean;
}) {
  const { title, Icon } = activityPresentation[state];
  return (
    <span className={`activity-indicator ${state} ${labeled ? "labeled" : ""}`} role="img" aria-label={title}>
      <Icon size={labeled ? 13 : 11} strokeWidth={3} />
      {labeled && <span>{title}</span>}
    </span>
  );
}

export function ConversationRow({
  row,
  chosen,
  onActivate,
  menuTrigger,
}: {
  row: ConversationSidebarRow;
  chosen?: boolean;
  onActivate(): void;
  menuTrigger: object;
}) {
  const highlighted = chosen ?? row.isSelected;
  const questions = row.questionCount ?? 0;
  return (
    <button
      type="button"
      className={`history-row ${highlighted ? "selected" : ""} ${row.isUnread ? "unread" : ""} ${row.activity === "working" ? "working" : ""}`}
      aria-pressed={chosen}
      aria-current={chosen === undefined && row.isSelected ? "page" : undefined}
      onClick={onActivate}
      {...menuTrigger}
    >
      {chosen !== undefined && (
        <span className={`selection-glyph ${chosen ? "chosen" : ""}`} aria-hidden="true">
          {chosen && <Check size={13} strokeWidth={3} />}
        </span>
      )}
      <span className="history-row-content">
        <span className="history-meta">
          {row.showsHostLabel && (
            <>
              <strong className="history-host">{row.hostName}</strong>
              <span aria-hidden="true">·</span>
            </>
          )}
          <span className="history-path">{row.workingDirectory}</span>
          <span className="history-status">
            {row.isAutomation && <History size={11} aria-label="Automation" />}
            {row.isPinned && <Pin size={11} className="pin-mark" aria-label="Pinned" />}
            {questions > 0 && (
              <span
                className="question-badge"
                role="img"
                aria-label={questions === 1 ? "Has a question" : `${questions} questions`}
              >
                <MessageCircleQuestion size={12} strokeWidth={2.4} />
                {questions > 1 && questions}
              </span>
            )}
            {row.activity !== "idle" && <ActivityIndicator state={row.activity} labeled={false} />}
            {row.isUnread && <span className="unread-dot" role="img" aria-label="Unread" />}
            {row.isProbablyDone && (
              <CircleCheck size={12} className="probably-done" aria-label="Probably done" />
            )}
            <ProviderMark provider={providerForThread(row.address.threadId)} />
          </span>
        </span>
        <span className="history-row-top">
          <span className="history-title">{row.title}</span>
          {row.isLoading && <span className="row-spinner" role="progressbar" aria-label="Loading" />}
          {row.timestamp !== null && <small className="history-age">{age(row.timestamp)}</small>}
        </span>
      </span>
    </button>
  );
}
