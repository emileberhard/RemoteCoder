use tokio::time::{Duration, Instant};

pub(crate) const FAREWELL_QUIET: Duration = Duration::from_millis(1500);
pub(crate) const FAREWELL_MAX_WAIT: Duration = Duration::from_secs(10);
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

pub(crate) fn is_sign_off(text: &str) -> bool {
    sign_off_for_user(text, None)
}

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

#[derive(Debug, Clone, Default)]
pub(crate) struct FarewellWatch {
    user_name: Option<String>,
    awaiting_reply: bool,
    last_voice_speech: Option<Instant>,
    armed_at: Option<Instant>,
}

impl FarewellWatch {
    pub(crate) fn for_user(user_name: Option<&str>) -> Self {
        Self {
            user_name: user_name.map(words),
            ..Self::default()
        }
    }

    pub(crate) fn user_speech(&mut self) {
        self.armed_at = None;
        self.awaiting_reply = false;
    }

    pub(crate) fn user_line(&mut self) {
        self.armed_at = None;
        self.awaiting_reply = true;
    }

    pub(crate) fn voice_speech(&mut self, now: Instant) {
        self.last_voice_speech = Some(now);
    }

    pub(crate) fn voice_line(&mut self, text: &str, now: Instant) -> bool {
        self.voice_speech(now);
        let arms = std::mem::take(&mut self.awaiting_reply)
            && self.armed_at.is_none()
            && match self.user_name.as_deref() {
                Some(name) => sign_off_for_user(text, Some(name)),
                None => is_sign_off(text),
            };
        if arms {
            self.armed_at = Some(now);
        }
        arms
    }

    pub(crate) fn close_at(&self) -> Option<Instant> {
        let armed_at = self.armed_at?;
        let quiet = self.last_voice_speech.unwrap_or(armed_at).max(armed_at) + FAREWELL_QUIET;
        Some(quiet.min(armed_at + FAREWELL_MAX_WAIT))
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
            assert!(watch.voice_line(reply, Instant::now()), "{reply}");
            let mut neutral = FarewellWatch::for_user(None);
            neutral.user_line();
            assert!(!neutral.voice_line(reply, Instant::now()), "{reply}");
        }
        let mut watch = FarewellWatch::for_user(Some("Maya Chen"));
        watch.user_line();
        assert!(!watch.voice_line("Bye, Taylor!", Instant::now()));
        watch.user_line();
        assert!(watch.voice_line("Bye!", Instant::now()));
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
            assert!(is_sign_off(reply), "{reply}");
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
            assert!(!is_sign_off(reply), "{reply}");
        }
    }

    #[test]
    fn a_goodbye_answering_the_user_closes_after_a_quiet_moment() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        watch.user_line();
        assert!(watch.voice_line("Alright, talk later.", start));
        assert_eq!(watch.close_at(), Some(start + FAREWELL_QUIET));

        let later = start + Duration::from_secs(3);
        watch.voice_speech(later);
        assert_eq!(watch.close_at(), Some(later + FAREWELL_QUIET));
        watch.voice_speech(start + Duration::from_secs(30));
        assert_eq!(watch.close_at(), Some(start + FAREWELL_MAX_WAIT));
    }

    #[test]
    fn user_speech_cancels_the_goodbye() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        watch.user_line();
        assert!(watch.voice_line("Bye!", start));
        watch.user_speech();
        assert_eq!(watch.close_at(), None);
        assert!(!watch.voice_line("Bye!", start));
    }

    #[test]
    fn a_goodbye_that_answers_no_user_line_does_not_arm() {
        let start = Instant::now();
        let mut watch = FarewellWatch::default();
        assert!(!watch.voice_line("Bye!", start));
        watch.user_line();
        assert!(!watch.voice_line("On it.", start));
        assert!(!watch.voice_line("Done. Bye!", start));
        assert_eq!(watch.close_at(), None);
    }
}
