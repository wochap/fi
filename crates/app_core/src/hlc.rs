use std::{
    fmt,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct HlcNodeId(pub [u8; 32]);

impl fmt::Display for HlcNodeId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct HlcStamp {
    pub physical_time_ms: i64,
    pub logical_counter: u32,
    pub node_id: HlcNodeId,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum HlcError {
    #[error("wall time is outside the signed epoch-millisecond range")]
    WallTimeOverflow,
    #[error("HLC logical counter overflow")]
    LogicalCounterOverflow,
}

pub trait WallTime: Send + Sync {
    fn now_ms(&self) -> Result<i64, HlcError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemWallTime;

impl WallTime for SystemWallTime {
    fn now_ms(&self) -> Result<i64, HlcError> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| HlcError::WallTimeOverflow)?;
        i64::try_from(duration.as_millis()).map_err(|_| HlcError::WallTimeOverflow)
    }
}

#[derive(Clone)]
pub struct HybridLogicalClock {
    node_id: HlcNodeId,
    last: Option<HlcStamp>,
    wall_time: Arc<dyn WallTime>,
}

impl fmt::Debug for HybridLogicalClock {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HybridLogicalClock")
            .field("node_id", &self.node_id)
            .field("last", &self.last)
            .finish_non_exhaustive()
    }
}

impl HybridLogicalClock {
    #[must_use]
    pub fn new(node_id: HlcNodeId, wall_time: Arc<dyn WallTime>) -> Self {
        Self {
            node_id,
            last: None,
            wall_time,
        }
    }

    pub fn observe(&mut self, stamp: HlcStamp) {
        if self.last.is_none_or(|last| stamp > last) {
            self.last = Some(stamp);
        }
    }

    pub fn tick(&mut self) -> Result<HlcStamp, HlcError> {
        let now = self.wall_time.now_ms()?;
        let (physical_time_ms, logical_counter) = match self.last {
            Some(last) if now <= last.physical_time_ms => (
                last.physical_time_ms,
                last.logical_counter
                    .checked_add(1)
                    .ok_or(HlcError::LogicalCounterOverflow)?,
            ),
            _ => (now, 0),
        };
        let stamp = HlcStamp {
            physical_time_ms,
            logical_counter,
            node_id: self.node_id,
        };
        self.last = Some(stamp);
        Ok(stamp)
    }

    #[must_use]
    pub const fn last(&self) -> Option<HlcStamp> {
        self.last
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI64, Ordering};

    struct ManualTime(AtomicI64);
    impl WallTime for ManualTime {
        fn now_ms(&self) -> Result<i64, HlcError> {
            Ok(self.0.load(Ordering::SeqCst))
        }
    }

    #[test]
    fn clock_handles_same_time_rollback_and_remote_observation() {
        let time = Arc::new(ManualTime(AtomicI64::new(100)));
        let mut clock = HybridLogicalClock::new(HlcNodeId([1; 32]), time.clone());
        let first = clock.tick().unwrap();
        assert_eq!(clock.tick().unwrap().logical_counter, 1);
        time.0.store(50, Ordering::SeqCst);
        assert_eq!(clock.tick().unwrap().physical_time_ms, 100);
        let remote = HlcStamp {
            physical_time_ms: 500,
            logical_counter: 7,
            node_id: HlcNodeId([2; 32]),
        };
        clock.observe(remote);
        assert!(clock.tick().unwrap() > remote);
        assert_eq!(first.logical_counter, 0);
    }

    #[test]
    fn node_id_breaks_stamp_ties() {
        let left = HlcStamp {
            physical_time_ms: 1,
            logical_counter: 2,
            node_id: HlcNodeId([1; 32]),
        };
        let right = HlcStamp {
            node_id: HlcNodeId([2; 32]),
            ..left
        };
        assert!(right > left);
    }
}
