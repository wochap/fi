#![doc = include_str!("../README.md")]
#![forbid(unsafe_code)]

pub mod bootstrap;
pub mod document;
pub mod error;
pub mod ids;
mod lifecycle;
pub mod network;
pub mod protocol;
pub mod repo;
pub mod storage;
mod sync;
#[doc(hidden)]
pub mod testing;

pub use bootstrap::{BootstrapOffer, BootstrapRecord, BootstrapStatus};
pub use document::{ChangeOrigin, ChangeResult, DocHandle, DocumentEvent, DocumentStatus};
pub use error::{Error, Failure, FailurePhase, Result};
pub use ids::{DocumentId, PeerId};
pub use repo::{Repo, RepoConfig};
pub use storage::FilesystemStorage;
