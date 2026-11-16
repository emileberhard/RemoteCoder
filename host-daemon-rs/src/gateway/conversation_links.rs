use super::Gateway;
use crate::wire::cluster::MemberState;
use anyhow::Result;
use serde_json::{Value, json};

const CONTEXT_KEY: &str = "remote_coder_conversation_links";

fn conversation_url(host: &str, thread: &str) -> String {
    let mut url = reqwest::Url::parse("remotecoder://chat/conversation")
        .expect("the conversation link base is a valid URL");
    url.query_pairs_mut()
        .append_pair("host", host)
        .append_pair("thread", thread);
    url.into()
}

fn render(this_host: &str, hosts: &[(String, String)], thread: &str) -> String {
    let hosts = hosts
        .iter()
        .map(|(name, id)| {
            if id == this_host {
                format!("{name} (this host) {id}")
            } else {
                format!("{name} {id}")
            }
        })
        .collect::<Vec<_>>()
        .join("; ");
    format!(
        "RemoteCoder conversation links: whenever you mention another conversation or session, such as one you found, started or delegated to, link it unless the user asks otherwise. \
A link is remotecoder://chat/conversation?host=<host id>&thread=<thread id>. The thread id is a Codex session's id, claude_ followed by a Claude session's id, or exactly the thread id a RemoteCoder tool returned. \
Host ids: {hosts}.\nThis conversation: {}",
        conversation_url(this_host, thread)
    )
}

fn insert_context(params: &mut Value, context: String) -> bool {
    let Some(fields) = params.as_object_mut() else {
        return false;
    };
    let entries = fields.entry("additionalContext").or_insert(Value::Null);
    if entries.is_null() {
        *entries = json!({});
    }
    let Some(entries) = entries.as_object_mut() else {
        return false;
    };
    entries.insert(
        CONTEXT_KEY.into(),
        json!({"kind": "application", "value": context}),
    );
    true
}

impl Gateway {
    pub(crate) async fn conversation_links(&self, thread: &str) -> Result<String> {
        let identity = self.host_identity().await?;
        let mut members = self
            .cluster_link()
            .await?
            .store
            .all()
            .await?
            .into_iter()
            .filter(|member| member.state == MemberState::Active)
            .map(|member| (member.name, member.host))
            .collect::<Vec<_>>();
        members.sort();
        let mut hosts = vec![(self.job_host_name()?, identity.host_id.clone())];
        hosts.extend(members);
        Ok(render(&identity.host_id, &hosts, thread))
    }

    pub(super) async fn add_conversation_links(&self, method: &str, params: &mut Value) -> bool {
        if !matches!(method, "turn/start" | "turn/steer") {
            return false;
        }
        let Some(thread) = params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_owned)
        else {
            return false;
        };
        match self.conversation_links(&thread).await {
            Ok(context) => insert_context(params, context),
            Err(error) => {
                self.journal.runtime(
                    "conversation_links_unavailable",
                    json!({"threadId": thread, "error": format!("{error:#}")}),
                );
                false
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_context_names_every_host_and_links_this_conversation() {
        let hosts = [
            (
                "emils-mac-mini".to_owned(),
                "fd14af47-366b-4f45-8daf-727c5c63dc44".to_owned(),
            ),
            (
                "emils-linux".to_owned(),
                "3de6e02c-3956-44d5-adc5-dbab4de7b8ab".to_owned(),
            ),
        ];
        let context = render(
            "fd14af47-366b-4f45-8daf-727c5c63dc44",
            &hosts,
            "claude_90844658-0988-4192-9b49-2ab519893480",
        );
        assert!(context.contains(
            "Host ids: emils-mac-mini (this host) fd14af47-366b-4f45-8daf-727c5c63dc44; emils-linux 3de6e02c-3956-44d5-adc5-dbab4de7b8ab."
        ));
        assert!(context.ends_with(
            "\nThis conversation: remotecoder://chat/conversation?host=fd14af47-366b-4f45-8daf-727c5c63dc44&thread=claude_90844658-0988-4192-9b49-2ab519893480"
        ));
    }

    #[test]
    fn a_thread_id_is_query_encoded() {
        assert_eq!(
            conversation_url("host", "claude:parent:agent&x"),
            "remotecoder://chat/conversation?host=host&thread=claude%3Aparent%3Aagent%26x"
        );
    }

    #[test]
    fn the_context_joins_the_client_entries_without_replacing_them() {
        let mut params = json!({"threadId": "t", "additionalContext": {
            "remote_coder_interaction_mode": {"kind": "application", "value": "text"}
        }});
        assert!(insert_context(&mut params, "links".into()));
        assert_eq!(
            params["additionalContext"]["remote_coder_interaction_mode"]["value"],
            "text"
        );
        assert_eq!(
            params["additionalContext"][CONTEXT_KEY],
            json!({"kind": "application", "value": "links"})
        );

        for mut params in [
            json!({"threadId": "t"}),
            json!({"threadId": "t", "additionalContext": null}),
        ] {
            assert!(insert_context(&mut params, "links".into()));
            assert_eq!(params["additionalContext"][CONTEXT_KEY]["value"], "links");
        }

        let mut malformed = json!({"threadId": "t", "additionalContext": "text"});
        assert!(!insert_context(&mut malformed, "links".into()));
        assert_eq!(malformed["additionalContext"], "text");
    }
}
