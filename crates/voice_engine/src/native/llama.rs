//! The instruction model: loaded once, then one context per turn with greedy, grammar-constrained
//! sampling capped at 256 tokens.

use std::{num::NonZeroU32, path::Path, sync::OnceLock};

use llama_cpp_2::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{AddBos, LlamaModel, params::LlamaModelParams},
    sampling::LlamaSampler,
};

use super::{CancelFlag, THREADS, check_model_file, load_failure, run_failure};
use crate::{Grammar, ModelRunner, VoiceError};

const CONTEXT: u32 = 4096;
const MAX_OUTPUT: usize = 256;

fn backend() -> &'static LlamaBackend {
    static BACKEND: OnceLock<LlamaBackend> = OnceLock::new();
    BACKEND.get_or_init(|| {
        let mut backend = LlamaBackend::init().expect("the llama backend initializes once");
        backend.void_logs();
        backend
    })
}

pub struct LlamaRunner {
    model: LlamaModel,
    cancel: CancelFlag,
}

impl std::fmt::Debug for LlamaRunner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LlamaRunner").finish_non_exhaustive()
    }
}

impl LlamaRunner {
    /// Loads the GGUF model. `ModelLoadFailed` for a missing or unreadable file, `LowMemory` when
    /// the load fails for want of memory.
    pub fn load(path: &Path, cancel: CancelFlag) -> Result<Self, VoiceError> {
        let size = check_model_file(path, &[b"GGUF"])?;
        let model = LlamaModel::load_from_file(backend(), path, &LlamaModelParams::default())
            .map_err(|error| load_failure("llama model", error, size))?;
        Ok(Self { model, cancel })
    }
}

impl ModelRunner for LlamaRunner {
    fn complete(&mut self, prompt: &str, grammar: &Grammar) -> Result<String, VoiceError> {
        let cancelled = || {
            if self.cancel.is_cancelled() {
                Err(VoiceError::Cancelled)
            } else {
                Ok(())
            }
        };
        cancelled()?;
        let params = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(CONTEXT))
            .with_n_batch(CONTEXT)
            .with_n_threads(THREADS)
            .with_n_threads_batch(THREADS);
        let mut context = self
            .model
            .new_context(backend(), params)
            .map_err(|error| run_failure("llama context", error))?;
        let tokens = self
            .model
            .str_to_token(prompt, AddBos::Never)
            .map_err(|error| run_failure("llama tokenize", error))?;
        if tokens.len() + MAX_OUTPUT > CONTEXT as usize {
            return Err(run_failure(
                "llama prompt",
                format!(
                    "prompt of {} tokens leaves no room for output",
                    tokens.len()
                ),
            ));
        }
        let mut batch = LlamaBatch::new(CONTEXT as usize, 1);
        let last = tokens.len() - 1;
        for (index, token) in tokens.iter().enumerate() {
            batch
                .add(*token, index as i32, &[0], index == last)
                .map_err(|error| run_failure("llama batch", error))?;
        }
        context
            .decode(&mut batch)
            .map_err(|error| run_failure("llama decode", error))?;
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::grammar(&self.model, grammar.gbnf(), "root")
                .map_err(|error| run_failure("llama grammar", error))?,
            LlamaSampler::greedy(),
        ]);
        let mut bytes = Vec::new();
        let mut position = tokens.len() as i32;
        for _ in 0..MAX_OUTPUT {
            cancelled()?;
            // `sample` also accepts the token into the grammar.
            let token = sampler.sample(&context, batch.n_tokens() - 1);
            if self.model.is_eog_token(token) {
                break;
            }
            bytes.extend(
                self.model
                    .token_to_piece_bytes(token, 64, false, None)
                    .map_err(|error| run_failure("llama detokenize", error))?,
            );
            batch.clear();
            batch
                .add(token, position, &[0], true)
                .map_err(|error| run_failure("llama batch", error))?;
            position += 1;
            context
                .decode(&mut batch)
                .map_err(|error| run_failure("llama decode", error))?;
        }
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }
}
