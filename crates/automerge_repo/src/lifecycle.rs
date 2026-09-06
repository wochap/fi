use std::sync::{
    Arc,
    atomic::{AtomicU8, Ordering},
};

use tokio::sync::RwLock;

use crate::error::LifecycleError;

const OPEN: u8 = 0;
const CLOSING: u8 = 1;
const CLOSED: u8 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LifecycleState {
    Open,
    Closing,
    Closed,
}

#[derive(Clone)]
pub(crate) struct Lifecycle(Arc<AtomicU8>);

impl Lifecycle {
    pub(crate) fn new() -> Self {
        Self(Arc::new(AtomicU8::new(OPEN)))
    }

    pub(crate) fn state(&self) -> LifecycleState {
        match self.0.load(Ordering::Acquire) {
            OPEN => LifecycleState::Open,
            CLOSING => LifecycleState::Closing,
            _ => LifecycleState::Closed,
        }
    }

    pub(crate) fn ensure_open(&self) -> Result<(), LifecycleError> {
        match self.state() {
            LifecycleState::Open => Ok(()),
            LifecycleState::Closing => Err(LifecycleError::RepositoryClosing),
            LifecycleState::Closed => Err(LifecycleError::RepositoryClosed),
        }
    }

    pub(crate) fn begin_shutdown(&self) -> Result<(), LifecycleError> {
        self.0
            .compare_exchange(OPEN, CLOSING, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| ())
            .map_err(|value| {
                if value == CLOSING {
                    LifecycleError::RepositoryClosing
                } else {
                    LifecycleError::RepositoryClosed
                }
            })
    }

    pub(crate) fn close(&self) {
        self.0.store(CLOSED, Ordering::Release);
    }
}

pub(crate) type CaptureGate = Arc<RwLock<()>>;
