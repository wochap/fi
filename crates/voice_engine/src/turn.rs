//! Per-turn cancellation. Every turn gets fresh flags, so cancelling or skipping one turn never
//! leaks into the next, and starting a turn never clears an earlier turn's flags.

use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

use crate::{Dictation, Grammar, ModelRunner, VoiceError};

/// A one-way flag shared with the whisper abort callback and the decode loop.
#[derive(Clone, Debug, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// The flag itself, for C callbacks. Valid while this `CancelFlag` (or a clone) is alive.
    pub fn as_ptr(&self) -> *const AtomicBool {
        Arc::as_ptr(&self.0)
    }
}

/// One turn's flags. `cancel` discards the turn; `skip` ends a dictation turn's cleanup and keeps
/// the transcript. Fill turns have no skip flag.
#[derive(Clone, Debug, Default)]
pub struct TurnControl {
    pub cancel: CancelFlag,
    pub skip: Option<CancelFlag>,
}

impl TurnControl {
    pub fn fill() -> Self {
        Self::default()
    }

    pub fn dictation() -> Self {
        Self {
            cancel: CancelFlag::default(),
            skip: Some(CancelFlag::default()),
        }
    }

    pub fn is_skipped(&self) -> bool {
        self.skip.as_ref().is_some_and(CancelFlag::is_cancelled)
    }

    /// `Cancelled` once the turn is cancelled or its cleanup skipped; generation stops there.
    pub fn check(&self) -> Result<(), VoiceError> {
        if self.cancel.is_cancelled() || self.is_skipped() {
            Err(VoiceError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// A dictation cleanup's result: a stop caused only by skip becomes the unchanged transcript.
    pub fn settle_dictation(
        &self,
        result: Result<Dictation, VoiceError>,
        transcript: &str,
    ) -> Result<Dictation, VoiceError> {
        match result {
            Err(VoiceError::Cancelled) if self.is_skipped() && !self.cancel.is_cancelled() => {
                Ok(Dictation::unchanged(transcript))
            }
            other => other,
        }
    }
}

/// The turn the app's cancel and skip calls target.
#[derive(Debug, Default)]
pub struct CurrentTurn(Mutex<Option<TurnControl>>);

impl CurrentTurn {
    /// Makes `turn` the current one. The previous turn keeps its own flags.
    pub fn begin(&self, turn: TurnControl) -> TurnControl {
        *self.lock() = Some(turn.clone());
        turn
    }

    pub fn cancel(&self) {
        if let Some(turn) = &*self.lock() {
            turn.cancel.cancel();
        }
    }

    pub fn skip_cleanup(&self) {
        if let Some(skip) = self.lock().as_ref().and_then(|turn| turn.skip.as_ref()) {
            skip.cancel();
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<TurnControl>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// A runner that generates under one turn's flags.
pub trait TurnRunner {
    fn generate(
        &mut self,
        prompt: &str,
        grammar: &Grammar,
        turn: &TurnControl,
    ) -> Result<String, VoiceError>;
}

/// Binds a [`TurnRunner`] to one turn, as a [`ModelRunner`].
pub struct ForTurn<'a, R: ?Sized> {
    pub runner: &'a mut R,
    pub turn: &'a TurnControl,
}

impl<R: TurnRunner + ?Sized> ModelRunner for ForTurn<'_, R> {
    fn complete(&mut self, prompt: &str, grammar: &Grammar) -> Result<String, VoiceError> {
        self.runner.generate(prompt, grammar, self.turn)
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;
    use crate::{VoiceEngine, VoiceLanguage};

    /// Generates one token per millisecond until stopped or `tokens` run out, then echoes the
    /// cleaned text.
    struct SlowRunner {
        tokens: usize,
        output: String,
    }

    impl TurnRunner for SlowRunner {
        fn generate(
            &mut self,
            _: &str,
            _: &Grammar,
            turn: &TurnControl,
        ) -> Result<String, VoiceError> {
            for _ in 0..self.tokens {
                turn.check()?;
                std::thread::sleep(Duration::from_millis(1));
            }
            Ok(self.output.clone())
        }
    }

    const TRANSCRIPT: &str = "Pick up oat milk, no wait, almond milk";

    fn clean(runner: &mut SlowRunner, turn: &TurnControl) -> Result<Dictation, VoiceError> {
        let result =
            VoiceEngine::new().clean(&mut ForTurn { runner, turn }, TRANSCRIPT, VoiceLanguage::En);
        turn.settle_dictation(result, TRANSCRIPT)
    }

    fn endless() -> SlowRunner {
        SlowRunner {
            tokens: usize::MAX,
            output: String::new(),
        }
    }

    #[test]
    fn skip_during_cleanup_returns_the_transcript_promptly() {
        let current = Arc::new(CurrentTurn::default());
        let turn = current.begin(TurnControl::dictation());
        let started = Instant::now();
        let worker = std::thread::spawn(move || clean(&mut endless(), &turn));
        std::thread::sleep(Duration::from_millis(20));
        current.skip_cleanup();
        let dictation = worker.join().unwrap().unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert_eq!(dictation.cleaned, TRANSCRIPT);
        assert!(dictation.removed.is_empty());
    }

    #[test]
    fn cancel_then_a_new_turn_stops_only_the_old_turn() {
        let current = Arc::new(CurrentTurn::default());
        let old = current.begin(TurnControl::dictation());
        let old_worker = std::thread::spawn(move || clean(&mut endless(), &old));
        std::thread::sleep(Duration::from_millis(10));
        current.cancel();
        let new = current.begin(TurnControl::dictation());
        let started = Instant::now();
        assert_eq!(
            old_worker.join().unwrap().err(),
            Some(VoiceError::Cancelled)
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!new.cancel.is_cancelled() && !new.is_skipped());
        let mut runner = SlowRunner {
            tokens: 5,
            output: "\"Pick up almond milk\"".into(),
        };
        assert_eq!(
            clean(&mut runner, &new).unwrap().cleaned,
            "Pick up almond milk"
        );
    }

    #[test]
    fn skip_after_the_result_is_a_no_op() {
        let current = CurrentTurn::default();
        let turn = current.begin(TurnControl::dictation());
        let mut runner = SlowRunner {
            tokens: 1,
            output: "\"Pick up almond milk\"".into(),
        };
        let dictation = clean(&mut runner, &turn).unwrap();
        current.skip_cleanup();
        assert_eq!(dictation.cleaned, "Pick up almond milk");
        assert!(!dictation.removed.is_empty());
    }

    #[test]
    fn skip_does_not_touch_fill_turns_and_cancel_wins_over_skip() {
        let current = CurrentTurn::default();
        let fill = current.begin(TurnControl::fill());
        current.skip_cleanup();
        assert!(fill.check().is_ok());
        let turn = current.begin(TurnControl::dictation());
        current.skip_cleanup();
        current.cancel();
        assert_eq!(
            turn.settle_dictation(Err(VoiceError::Cancelled), TRANSCRIPT)
                .err(),
            Some(VoiceError::Cancelled)
        );
    }
}
