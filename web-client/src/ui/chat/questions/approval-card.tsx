import { ShieldCheck } from "lucide-react";
import { useState } from "react";
import { object } from "../../../protocol/boundary";
import type { RequestCard } from "../../../workspace/conversation-session";
import { useWorkspace } from "../../workspace-context";

export function ApprovalCard({ request }: { request: RequestCard }) {
  const workspace = useWorkspace();
  const [answers, setAnswers] = useState<Record<string, string>>({});
  if (request.method === "item/tool/requestUserInput") {
    const slots = Array.isArray(request.params.questions) ? request.params.questions.map(object) : [];
    return (
      <article className="question-card">
        <h3>Agent needs your input</h3>
        {slots.map((slot) => (
          <label key={String(slot.id)}>
            {String(slot.question)}
            <input
              value={answers[String(slot.id)] ?? ""}
              onChange={(event) =>
                setAnswers((value) => ({ ...value, [String(slot.id)]: event.target.value }))
              }
            />
            {Array.isArray(slot.options) && (
              <div className="question-options">
                {slot.options.map((option) => (
                  <button
                    key={String(object(option).label)}
                    type="button"
                    onClick={() =>
                      setAnswers((value) => ({ ...value, [String(slot.id)]: String(object(option).label) }))
                    }
                  >
                    {String(object(option).label)}
                  </button>
                ))}
              </div>
            )}
          </label>
        ))}
        <button
          type="button"
          className="primary"
          disabled={slots.some((slot) => !answers[String(slot.id)]?.trim())}
          onClick={() =>
            workspace.answerRequest(request, {
              answers: Object.fromEntries(
                slots.map((slot) => [String(slot.id), { answers: [answers[String(slot.id)]] }]),
              ),
            })
          }
        >
          Send answers
        </button>
      </article>
    );
  }
  const permission = request.method === "item/permissions/requestApproval";
  const supported =
    permission ||
    ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].includes(request.method);
  return (
    <article className="approval-card">
      <div>
        <ShieldCheck size={19} />
        <h3>{supported ? "Approval requested" : "Agent request"}</h3>
      </div>
      <p>{String(request.params.reason ?? request.params.command ?? request.method)}</p>
      <pre>
        {JSON.stringify(
          permission ? request.params.permissions : (request.params.command ?? request.params),
          null,
          2,
        )}
      </pre>
      {supported ? (
        <div className="approval-actions">
          <button
            type="button"
            onClick={() =>
              workspace.answerRequest(
                request,
                permission ? { permissions: {}, scope: "turn" } : { decision: "decline" },
              )
            }
          >
            Decline
          </button>
          <button
            type="button"
            className="primary"
            onClick={() =>
              workspace.answerRequest(
                request,
                permission
                  ? { permissions: request.params.permissions, scope: "turn" }
                  : { decision: "accept" },
              )
            }
          >
            Allow for this turn
          </button>
        </div>
      ) : (
        <p className="subtle">
          This browser does not know how to answer this request. Use a client that supports it.
        </p>
      )}
    </article>
  );
}
