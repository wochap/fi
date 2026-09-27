//! In-memory retention of recent tracing events for the devices screen.
//!
//! [`RecentEventsLayer`] observes the same events the stdout/logcat sink
//! writes and keeps the most recent [`CAPACITY`] of them in a process-wide
//! buffer. Fields are recorded through `record_str`/`record_debug`, the same
//! entry points the fmt layer formats with, so a value that redacts itself for
//! the sink is retained in its redacted form.
use std::{
    collections::VecDeque,
    fmt::{self, Write as _},
    sync::{Arc, LazyLock, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use tracing::{
    Event, Subscriber,
    field::{Field, Visit},
};
use tracing_subscriber::{Layer, layer::Context};

/// Events retained before the oldest is evicted.
pub const CAPACITY: usize = 1000;

/// One retained tracing event. `device_id` and `event` are lifted out of
/// `fields`; the remaining fields keep their emission order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LogEvent {
    pub at_ms: u64,
    pub level: String,
    pub event: Option<String>,
    pub message: String,
    pub fields: Vec<(String, String)>,
    pub device_id: Option<String>,
}

impl LogEvent {
    /// `at_ms level event message key=value ...`, the form shown in the
    /// details panel and the diagnostic block.
    #[must_use]
    pub fn line(&self) -> String {
        let mut line = format!("{} {}", self.at_ms, self.level);
        if let Some(event) = &self.event {
            let _ = write!(line, " {event}");
        }
        if !self.message.is_empty() {
            let _ = write!(line, " {}", self.message);
        }
        for (name, value) in &self.fields {
            let _ = write!(line, " {name}={value}");
        }
        line
    }
}

/// Bounded buffer of recent events, oldest first.
#[derive(Debug)]
pub struct RecentEvents {
    capacity: usize,
    events: Mutex<VecDeque<LogEvent>>,
}

impl RecentEvents {
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            events: Mutex::new(VecDeque::with_capacity(capacity)),
        }
    }

    pub fn push(&self, event: LogEvent) {
        let Ok(mut events) = self.events.lock() else {
            return;
        };
        while events.len() >= self.capacity {
            events.pop_front();
        }
        events.push_back(event);
    }

    /// Every retained event in emission order.
    #[must_use]
    pub fn all(&self) -> Vec<LogEvent> {
        self.events
            .lock()
            .map(|events| events.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// The most recent `limit` events whose `device_id` equals `device_id`,
    /// in emission order.
    #[must_use]
    pub fn for_device(&self, device_id: &str, limit: usize) -> Vec<LogEvent> {
        self.latest(limit, |event| event.device_id.as_deref() == Some(device_id))
    }

    /// The most recent `limit` events without a `device_id`, in emission
    /// order.
    #[must_use]
    pub fn local(&self, limit: usize) -> Vec<LogEvent> {
        self.latest(limit, |event| event.device_id.is_none())
    }

    fn latest(&self, limit: usize, keep: impl Fn(&LogEvent) -> bool) -> Vec<LogEvent> {
        let Ok(events) = self.events.lock() else {
            return Vec::new();
        };
        let mut matched = events
            .iter()
            .rev()
            .filter(|event| keep(event))
            .take(limit)
            .cloned()
            .collect::<Vec<_>>();
        matched.reverse();
        matched
    }
}

static GLOBAL: LazyLock<Arc<RecentEvents>> =
    LazyLock::new(|| Arc::new(RecentEvents::new(CAPACITY)));

/// The process-wide buffer. It outlives any `AppCore`, so lines leading up to
/// a dataset reset or networking retry stay available.
#[must_use]
pub fn recent_events() -> Arc<RecentEvents> {
    GLOBAL.clone()
}

/// Retained events for one peer from the process-wide buffer.
#[must_use]
pub fn recent_events_for(device_id: &str, limit: usize) -> Vec<LogEvent> {
    GLOBAL.for_device(device_id, limit)
}

/// Retained events that carry no `device_id` from the process-wide buffer.
#[must_use]
pub fn recent_local_events(limit: usize) -> Vec<LogEvent> {
    GLOBAL.local(limit)
}

/// Tracing layer that copies every event it sees into a [`RecentEvents`].
#[derive(Clone, Debug)]
pub struct RecentEventsLayer {
    buffer: Arc<RecentEvents>,
}

impl RecentEventsLayer {
    /// A layer writing to the process-wide buffer.
    #[must_use]
    pub fn new() -> Self {
        Self::with_buffer(recent_events())
    }

    #[must_use]
    pub fn with_buffer(buffer: Arc<RecentEvents>) -> Self {
        Self { buffer }
    }
}

impl Default for RecentEventsLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl<S: Subscriber> Layer<S> for RecentEventsLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);
        self.buffer.push(LogEvent {
            at_ms: now_ms(),
            level: event.metadata().level().to_string(),
            event: visitor.event,
            message: visitor.message,
            fields: visitor.fields,
            device_id: visitor.device_id,
        });
    }
}

#[derive(Default)]
struct FieldVisitor {
    message: String,
    event: Option<String>,
    device_id: Option<String>,
    fields: Vec<(String, String)>,
}

impl FieldVisitor {
    fn record(&mut self, field: &Field, value: String) {
        match field.name() {
            "message" => self.message = value,
            "event" => self.event = Some(value),
            "device_id" => self.device_id = Some(value),
            name => self.fields.push((name.to_owned(), value)),
        }
    }
}

impl Visit for FieldVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.record(field, value.to_owned());
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        self.record(field, format!("{value:?}"));
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            elapsed.as_millis().try_into().unwrap_or(u64::MAX)
        })
}

fn format_utc_ms(at_ms: u64) -> String {
    i64::try_from(at_ms)
        .ok()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map_or_else(
            || format!("{at_ms} ms"),
            |at| at.format("%Y-%m-%d %H:%M:%S%.3f UTC").to_string(),
        )
}

/// Everything the diagnostic block for one peer reports.
#[derive(Clone, Debug, Default)]
pub struct DiagnosticInputs {
    pub version: Option<String>,
    pub local_device_id: Option<String>,
    pub peer_device_id: String,
    pub peer_name: Option<String>,
    pub connection_state: String,
    pub endpoint: Option<String>,
    pub last_attempt_ms: Option<u64>,
    pub failure: Option<String>,
    pub sync_port: Option<u16>,
    pub peer_events: Vec<LogEvent>,
    pub local_events: Vec<LogEvent>,
}

/// Plain-text diagnostic block for one peer. Holds identifiers, connection
/// state, and retained (already redacted) log lines only.
#[must_use]
pub fn diagnostic_block(inputs: &DiagnosticInputs) -> String {
    let mut block = String::new();
    let _ = writeln!(
        block,
        "Version: {}",
        inputs.version.as_deref().unwrap_or("unknown")
    );
    let _ = writeln!(
        block,
        "Local device: {}",
        inputs.local_device_id.as_deref().unwrap_or("not set up")
    );
    let _ = writeln!(block, "Peer device: {}", inputs.peer_device_id);
    let _ = writeln!(
        block,
        "Peer name: {}",
        inputs.peer_name.as_deref().unwrap_or("unknown")
    );
    let _ = writeln!(block, "Connection state: {}", inputs.connection_state);
    let _ = writeln!(
        block,
        "Endpoint: {}",
        inputs.endpoint.as_deref().unwrap_or("none")
    );
    let _ = writeln!(
        block,
        "Last attempt: {}",
        inputs
            .last_attempt_ms
            .map_or_else(|| "never".to_owned(), format_utc_ms),
    );
    let _ = writeln!(
        block,
        "Failure: {}",
        inputs.failure.as_deref().unwrap_or("none")
    );
    let _ = writeln!(
        block,
        "Sync port: {}",
        inputs
            .sync_port
            .map_or_else(|| "not bound".to_owned(), |port| port.to_string()),
    );
    let _ = writeln!(block, "Peer log ({} lines):", inputs.peer_events.len());
    for event in &inputs.peer_events {
        let _ = writeln!(block, "{}", event.line());
    }
    let _ = writeln!(block, "Local log ({} lines):", inputs.local_events.len());
    for event in &inputs.local_events {
        let _ = writeln!(block, "{}", event.line());
    }
    block
}

#[cfg(test)]
mod tests {
    use tracing_subscriber::layer::SubscriberExt;

    use super::*;

    fn capture(buffer: &Arc<RecentEvents>, emit: impl FnOnce()) {
        let subscriber =
            tracing_subscriber::registry().with(RecentEventsLayer::with_buffer(buffer.clone()));
        tracing::subscriber::with_default(subscriber, emit);
    }

    #[test]
    fn buffer_keeps_the_most_recent_events_in_order() {
        let buffer = Arc::new(RecentEvents::new(CAPACITY));
        capture(&buffer, || {
            for index in 0..1200 {
                tracing::info!(event = "tick", index, "tick {index}");
            }
        });
        let events = buffer.all();
        assert_eq!(events.len(), CAPACITY);
        for (offset, event) in events.iter().enumerate() {
            assert_eq!(event.message, format!("tick {}", offset + 200));
            assert_eq!(event.event.as_deref(), Some("tick"));
            assert_eq!(
                event.fields,
                vec![("index".to_owned(), (offset + 200).to_string())]
            );
        }
    }

    #[test]
    fn queries_split_peer_and_local_events() {
        let buffer = Arc::new(RecentEvents::new(CAPACITY));
        capture(&buffer, || {
            tracing::info!(event = "peer_dial_failed", device_id = %"A", "a failed");
            tracing::info!(event = "peer_connection_state", device_id = %"B", "b synced");
            tracing::warn!(event = "discovery_no_route", "no routable address");
            tracing::info!(event = "peer_dial_failed", device_id = %"A", "a failed again");
        });
        let for_a = buffer.for_device("A", 10);
        assert_eq!(
            for_a
                .iter()
                .map(|event| event.message.as_str())
                .collect::<Vec<_>>(),
            vec!["a failed", "a failed again"]
        );
        assert!(buffer.for_device("C", 10).is_empty());
        let local = buffer.local(10);
        assert_eq!(local.len(), 1);
        assert_eq!(local[0].event.as_deref(), Some("discovery_no_route"));
        assert_eq!(local[0].level, "WARN");
        assert_eq!(buffer.for_device("A", 1)[0].message, "a failed again");
    }

    #[test]
    fn block_lists_sections_in_order_and_defaults_the_version() {
        let peer_line = LogEvent {
            at_ms: 5,
            level: "INFO".into(),
            event: Some("peer_dial_failed".into()),
            message: "dial failed".into(),
            fields: vec![("endpoint".into(), "192.168.1.20:47380".into())],
            device_id: Some("peer".into()),
        };
        let local_line = LogEvent {
            at_ms: 6,
            level: "WARN".into(),
            event: None,
            message: "local".into(),
            fields: Vec::new(),
            device_id: None,
        };
        let block = diagnostic_block(&DiagnosticInputs {
            version: None,
            local_device_id: Some("local-id".into()),
            peer_device_id: "peer-id".into(),
            peer_name: Some("Fi peer".into()),
            connection_state: "error".into(),
            endpoint: Some("192.168.1.20:47380".into()),
            last_attempt_ms: Some(4),
            failure: Some("TLS failed: bad".into()),
            sync_port: Some(47380),
            peer_events: vec![peer_line],
            local_events: vec![local_line],
        });
        let lines = block.lines().collect::<Vec<_>>();
        assert_eq!(
            lines,
            vec![
                "Version: unknown",
                "Local device: local-id",
                "Peer device: peer-id",
                "Peer name: Fi peer",
                "Connection state: error",
                "Endpoint: 192.168.1.20:47380",
                "Last attempt: 1970-01-01 00:00:00.004 UTC",
                "Failure: TLS failed: bad",
                "Sync port: 47380",
                "Peer log (1 lines):",
                "5 INFO peer_dial_failed dial failed endpoint=192.168.1.20:47380",
                "Local log (1 lines):",
                "6 WARN local",
            ]
        );
    }
}
