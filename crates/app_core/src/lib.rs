#![forbid(unsafe_code)]

pub mod adapters;
pub mod application;
pub mod domain;
pub mod error;
pub mod events;
pub mod ports;
pub mod projection;
#[doc(hidden)]
pub mod test_support;

pub use application::{AppCore, AppCoreConfig};
pub use domain::{
    Category, CategoryId, CategoryView, CreateCategory, CreateTransaction, FinanceCommand,
    FinanceSnapshot, Transaction, TransactionFilter, TransactionId, TransactionView,
    UpdateCategory, UpdateTransaction,
};
pub use error::{AppError, BootstrapError, DomainError, ProjectionError, Result};
pub use events::{
    ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState, TransientEvent,
};
pub use projection::{AggregateView, ProjectionCheckpoint};
