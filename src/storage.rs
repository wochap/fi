//! Complete-snapshot and bootstrap-control persistence ports.
use async_trait::async_trait;

use crate::{BootstrapRecord, DocumentId, error::StorageError};

#[async_trait]
/// Atomic complete-snapshot storage. Stage 1 uses explicit barriers; automatic
/// persistence scheduling and crash recovery are deferred to Stage 2.
pub trait StorageAdapter: Send + Sync + 'static {
    async fn list(&self) -> Result<Vec<DocumentId>, StorageError>;
    async fn load(&self, id: DocumentId) -> Result<Option<Vec<u8>>, StorageError>;
    async fn store(&self, id: DocumentId, snapshot: Vec<u8>) -> Result<(), StorageError>;
    async fn remove(&self, id: DocumentId) -> Result<(), StorageError>;
    async fn flush(&self) -> Result<(), StorageError>;
    async fn close(&self) -> Result<(), StorageError>;
}

#[async_trait]
/// Storage for bootstrap records, deliberately independent of document bytes.
pub trait ControlStore: Send + Sync + 'static {
    async fn load(&self) -> Result<Option<BootstrapRecord>, StorageError>;
    async fn store(&self, record: BootstrapRecord) -> Result<(), StorageError>;
    async fn flush(&self) -> Result<(), StorageError>;
    async fn close(&self) -> Result<(), StorageError>;
}
