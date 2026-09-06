//! Small deterministic configuration helpers for downstream integration tests.

use std::time::Duration;

use crate::AppCoreConfig;

#[must_use]
pub fn fast_config() -> AppCoreConfig {
    let mut config = AppCoreConfig::default();
    config.repo.persistence_debounce = Duration::ZERO;
    config.repo.persistence_retry_min = Duration::from_millis(1);
    config.repo.persistence_retry_max = Duration::from_millis(5);
    config
}
