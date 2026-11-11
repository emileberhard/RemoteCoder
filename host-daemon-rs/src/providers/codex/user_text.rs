use serde_json::Value;

const SUMMARY_PREFIX: &str = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:";

pub(crate) fn is_typed(text: &str) -> bool {
    let text = text.trim();
    !crate::agents::envelope::is_message(text)
        && !text.starts_with(SUMMARY_PREFIX)
        && !crate::providers::claude::timeline::is_injected_user_text(text)
        && ![
            ("# AGENTS.md instructions", "</INSTRUCTIONS>"),
            ("<environment_context>", "</environment_context>"),
            ("<skill>", "</skill>"),
            ("<user_shell_command>", "</user_shell_command>"),
            ("<turn_aborted>", "</turn_aborted>"),
            ("<subagent_notification>", "</subagent_notification>"),
            ("<recommended_plugins>", "</recommended_plugins>"),
            ("<goal_context>", "</goal_context>"),
            ("<codex_internal_context", "</codex_internal_context>"),
            ("<hook_prompt", "</hook_prompt>"),
        ]
        .iter()
        .any(|(start, end)| text.starts_with(start) && text.ends_with(end))
        && !(text.starts_with("<external_")
            && text
                .split_once('>')
                .and_then(|(start, _)| start.strip_prefix("<external_"))
                .is_some_and(|kind| text.ends_with(&format!("</external_{kind}>"))))
        && !text.starts_with(
            "Warning: The maximum number of unified exec processes you can keep open is",
        )
        && !(text.starts_with("Warning: apply_patch was requested via ")
            && text.ends_with("Use the apply_patch tool instead of exec_command."))
        && !text.starts_with(
            "Warning: Your account was flagged for potentially high-risk cyber activity",
        )
}

pub(crate) fn legacy_message(content: &Value) -> Option<String> {
    let parts = content.as_array()?;
    let texts: Vec<_> = parts
        .iter()
        .filter(|p| p["type"] == "input_text")
        .filter_map(|p| p["text"].as_str())
        .collect();
    texts
        .iter()
        .all(|text| is_typed(text))
        .then(|| texts.join("\n"))
}
