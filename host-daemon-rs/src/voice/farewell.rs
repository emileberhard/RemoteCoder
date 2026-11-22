use std::sync::Arc;
use tokio::time::{Duration, Instant};

pub(crate) const FAREWELL_QUIET: Duration = Duration::from_millis(1500);
pub(crate) const FAREWELL_MAX_WAIT: Duration = Duration::from_secs(10);
const MAX_REPLY_BYTES: usize = 8 * 1024;
const SIGN_OFFS: &[&str] = &[
    "bye",
    "goodbye",
    "bye bye",
    "bye for now",
    "hej då",
    "talk later",
    "talk soon",
    "hanging up",
    "hanging up now",
];

const LEAD_INS: &[&str] = &[
    "okay",
    "ok",
    "alright",
    "all right",
    "sure",
    "got it",
    "sorry",
    "thanks",
];

fn sign_off_for_user(text: &str, user_name: Option<&str>) -> bool {
    let Some(sentence) = text
        .split(['.', '!', '?'])
        .rfind(|sentence| !words(sentence).is_empty())
    else {
        return false;
    };
    let mut clauses = sentence
        .split(',')
        .map(words)
        .filter(|clause| !clause.is_empty())
        .collect::<Vec<_>>();
    if clauses
        .last()
        .is_some_and(|clause| Some(clause.as_str()) == user_name)
    {
        clauses.pop();
    }
    clauses.pop().is_some_and(|sign_off| {
        SIGN_OFFS.contains(&sign_off.as_str())
            && clauses.iter().all(|clause| {
                LEAD_INS.contains(&clause.as_str()) || Some(clause.as_str()) == user_name
            })
    })
}

fn words(text: &str) -> String {
    text.to_lowercase()
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Clone)]
struct PendingClose {
    started: Arc<Instant>,
    agent_requested: bool,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct FarewellWatch {
    user_name: Option<String>,
    reply: Option<String>,
    last_output: Option<Instant>,
    pending: Option<PendingClose>,
}

impl FarewellWatch {
    pub(crate) fn for_user(user_name: Option<&str>) -> Self {
        Self {
            user_name: user_name.map(words),
            ..Self::default()
        }
    }

    pub(crate) fn user_speech(&mut self) {
        self.reply = None;
        self.cancel_sign_off();
    }

    pub(crate) fn user_line(&mut self) {
        self.user_speech();
        self.reply = Some(String::new());
    }

    pub(crate) fn voice_output(&mut self, now: Instant) {
        self.last_output = Some(now);
    }

    pub(crate) fn voice_delta(&mut self, delta: &str, now: Instant) -> Option<Arc<Instant>> {
        self.voice_output(now);
        let Some(reply) = self.reply.as_mut() else {
            self.cancel_sign_off();
            return None;
        };
        if reply.len().saturating_add(delta.len()) > MAX_REPLY_BYTES {
            self.reply = None;
            self.cancel_sign_off();
            return None;
        }
        reply.push_str(delta);
        if sign_off_for_user(reply, self.user_name.as_deref()) {
            self.arm(now, false)
        } else {
            self.cancel_sign_off();
            None
        }
    }

    pub(crate) fn voice_done(&mut self, text: &str) {
        if self.reply.take().is_some() && !sign_off_for_user(text, self.user_name.as_deref()) {
            self.cancel_sign_off();
        }
    }

    pub(crate) fn agent_requested_close(&mut self, now: Instant) -> Option<Arc<Instant>> {
        self.arm(now, true)
    }

    fn arm(&mut self, now: Instant, agent_requested: bool) -> Option<Arc<Instant>> {
        if let Some(pending) = self.pending.as_mut() {
            pending.agent_requested |= agent_requested;
            return None;
        }
        let started = Arc::new(now);
        self.pending = Some(PendingClose {
            started: Arc::clone(&started),
            agent_requested,
        });
        Some(started)
    }

    fn cancel_sign_off(&mut self) {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| !pending.agent_requested)
        {
            self.pending = None;
        }
    }

    pub(crate) fn close_at(&self, started: &Arc<Instant>) -> Option<(Instant, &'static str)> {
        let pending = self.pending.as_ref()?;
        if !Arc::ptr_eq(started, &pending.started) {
            return None;
        }
        let start = **started;
        let quiet = self.last_output.unwrap_or(start).max(start) + FAREWELL_QUIET;
        let reason = if pending.agent_requested {
            "agent tool"
        } else {
            "farewell"
        };
        Some((quiet.min(start + FAREWELL_MAX_WAIT), reason))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_configured_name_can_qualify_a_farewell() {
        for reply in [
            "Bye, Maya Chen!",
            "Maya Chen, bye!",
            "Okay, bye, MAYA CHEN!",
        ] {
            let mut watch = FarewellWatch::for_user(Some("Maya Chen"));
            watch.user_line();
            assert!(
                watch.voice_delta(reply, Instant::now()).is_some(),
                "{reply}"
            );
            let mut neutral = FarewellWatch::for_user(None);
            neutral.user_line();
            assert!(
                neutral.voice_delta(reply, Instant::now()).is_none(),
                "{reply}"
            );
        }
        let mut watch = FarewellWatch::for_user(Some("Maya Chen"));
        watch.user_line();
        assert!(watch.voice_delta("Bye, Taylor!", Instant::now()).is_none());
        watch.user_line();
        assert!(watch.voice_delta("Bye!", Instant::now()).is_some());
    }

    #[test]
    fn recognizes_the_goodbyes_gpt_live_gave_in_recorded_calls() {
        for reply in [
            " It is HiDPI. Bye!",
            " Okay, hanging up.",
            " Got it. Bye.",
            " Alright, talk later.",
            " Sure, bye for now.",
            " Sorry about that. Hanging up now.",
            " Okay, hanging up now.",
            "Bye-bye!",
            "Hej då!",
        ] {
            assert!(sign_off_for_user(reply, None), "{reply}");
        }
    }

    #[test]
    fn ignores_replies_that_only_mention_a_goodbye() {
        for reply in [
            " Sure, I'll take care of that.",
            "Sure, I'll tell her you said bye.",
            "Okay, I'll text her goodbye.",
            "Done, I texted Maya good night.",
            "It means goodbye.",
            "Do not say bye.",
            "She said, “Talk later.”",
            "She wrote: love you, bye!",
            " Hanging up now would cut off the build. Want me to wait?",
            " Hey Taylor, what's up?",
            "",
        ] {
            assert!(!sign_off_for_user(reply, None), "{reply}");
        }
    }

    #[test]
    fn a_goodbye_answering_the_user_closes_after_a_quiet_moment() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        watch.user_line();
        let ticket = watch.voice_delta("Alright, talk later.", start).unwrap();
        assert_eq!(
            watch.close_at(&ticket),
            Some((start + FAREWELL_QUIET, "farewell"))
        );

        let later = start + Duration::from_secs(3);
        watch.voice_output(later);
        watch.voice_done("Alright, talk later.");
        assert_eq!(
            watch.close_at(&ticket),
            Some((later + FAREWELL_QUIET, "farewell"))
        );
        watch.voice_output(start + Duration::from_secs(30));
        assert_eq!(
            watch.close_at(&ticket),
            Some((start + FAREWELL_MAX_WAIT, "farewell"))
        );
    }

    #[test]
    fn speech_after_a_sign_off_cancels_the_goodbye() {
        let start = Instant::now();
        for continuation in [
            (" What else can I help with?", false),
            (" I'll tell her you said that.", true),
        ] {
            let mut watch = FarewellWatch::default();
            watch.user_line();
            assert!(watch.voice_delta(" By", start).is_none());
            let ticket = watch.voice_delta("e.", start).unwrap();
            if continuation.1 {
                watch.voice_done(&format!(" Bye.{}", continuation.0));
            } else {
                watch.voice_delta(continuation.0, start);
            }
            assert_eq!(watch.close_at(&ticket), None);
        }
    }

    #[test]
    fn user_speech_cancels_the_goodbye() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        watch.user_line();
        let ticket = watch.voice_delta("Bye!", start).unwrap();
        watch.user_speech();
        assert_eq!(watch.close_at(&ticket), None);
        assert!(watch.voice_delta("Bye!", start).is_none());
    }

    #[test]
    fn a_goodbye_that_answers_no_user_line_does_not_arm() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        assert!(watch.voice_delta("Bye!", start).is_none());
        watch.user_line();
        assert!(watch.voice_delta("On it.", start).is_none());
        watch.voice_done("On it.");
        assert!(watch.voice_delta("Done. Bye!", start).is_none());
    }
}
