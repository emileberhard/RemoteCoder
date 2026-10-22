import { ArrowUp, Check, MessageCircle } from "lucide-react";
import { useState } from "react";
import type { QuestionRecord } from "../../../protocol/boundary";
import { useRun, useWorkspace } from "../../workspace-context";

export function QuestionCard({ record, ready }: { record: QuestionRecord; ready: boolean }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState(false);
  const pending = record.questions.filter((slot) => slot.resolution === "pending");
  return (
    <article className="question-card">
      <div className="question-card-header">
        <MessageCircle size={17} />
        <span>{pending.length ? "A question for you" : "Question resolved"}</span>
        {pending.length > 0 && (
          <button
            type="button"
            className="text-button"
            disabled={busy || !ready}
            onClick={() => run(() => workspace.dismissQuestion(record))}
          >
            Dismiss
          </button>
        )}
      </div>
      {record.questions.map((slot) => (
        <div className="question-slot" key={slot.index}>
          <h3>{slot.title}</h3>
          {slot.resolution === "pending" ? (
            <>
              <div className="question-options">
                {slot.options.map((option) => (
                  <button
                    type="button"
                    key={option}
                    className={answers[slot.index] === option ? "chosen" : ""}
                    disabled={!ready || busy}
                    onClick={() => setAnswers((previous) => ({ ...previous, [slot.index]: option }))}
                  >
                    <span className="option-radio">
                      {answers[slot.index] === option && <Check size={13} />}
                    </span>
                    {option}
                  </button>
                ))}
              </div>
              <input
                aria-label={`Answer: ${slot.title}`}
                placeholder={slot.options.length ? "Or write your answer…" : "Your answer…"}
                disabled={!ready || busy}
                value={slot.options.includes(answers[slot.index] ?? "") ? "" : (answers[slot.index] ?? "")}
                onChange={(event) =>
                  setAnswers((previous) => ({ ...previous, [slot.index]: event.target.value }))
                }
              />
            </>
          ) : (
            <p className="question-resolution">{slot.answer?.text ?? slot.resolution}</p>
          )}
        </div>
      ))}
      {pending.length > 0 && (
        <div className="question-actions">
          {!ready && (
            <button
              type="button"
              className="text-button"
              onClick={() => run(() => workspace.refreshQuestions())}
            >
              Refresh status
            </button>
          )}
          <button
            type="button"
            className="primary"
            disabled={busy || !ready || !Object.values(answers).some((answer) => answer.trim())}
            onClick={() => {
              setBusy(true);
              void workspace
                .answerQuestion(record, answers)
                .catch((error) => workspace.report(error))
                .finally(() => setBusy(false));
            }}
          >
            {busy ? "Sending…" : "Send answer"}
            <ArrowUp size={15} />
          </button>
        </div>
      )}
    </article>
  );
}
