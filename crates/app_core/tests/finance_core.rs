use std::{fs, time::Duration};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, BootstrapError, CategoryId, CreateCategory,
    CreateTransaction, ProjectionState, TransactionFilter, UpdateCategory, UpdateTransaction,
};
use automerge::Automerge;
use rusqlite::{Connection, OptionalExtension};

#[tokio::test]
async fn fresh_start_requires_an_explicit_decision_and_rejects_commands() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(app.lifecycle_state(), ApplicationState::NeedsDecision);
    let error = app
        .create_category(CreateCategory {
            name: "Food".into(),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        app_core::AppError::Bootstrap(BootstrapError::DecisionRequired)
    ));
    assert!(directory.path().join("automerge/documents").is_dir());
    assert!(directory.path().join("control.sqlite").is_file());
    assert!(directory.path().join("read-model.sqlite").is_file());
    assert!(
        fs::read_dir(directory.path().join("automerge/documents"))
            .unwrap()
            .next()
            .is_none()
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn commands_are_durable_and_projected_before_returning() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    let root = app.create_new_dataset().await.unwrap();
    let category = app
        .create_category(CreateCategory {
            name: "Salary".into(),
        })
        .await
        .unwrap();
    let transaction = app
        .create_transaction(CreateTransaction {
            occurred_at_ms: 1_700_000_000_000,
            category_id: category,
            amount_minor: 12_550,
            description: "November salary".into(),
        })
        .await
        .unwrap();

    let categories = app.categories().unwrap();
    assert!(categories.iter().any(|item| item.id == category));
    let transactions = app
        .transactions(&TransactionFilter {
            text: Some("salary".into()),
            ..TransactionFilter::default()
        })
        .unwrap();
    assert_eq!(transactions.len(), 1);
    assert_eq!(transactions[0].id, transaction);
    assert_eq!(app.aggregates().unwrap().balance_minor, 12_550);

    let checkpoint = match app.projection_state() {
        ProjectionState::Ready { checkpoint } => checkpoint,
        state => panic!("unexpected state {state:?}"),
    };
    assert_eq!(checkpoint.root, root);
    let stored: String = Connection::open(directory.path().join("read-model.sqlite"))
        .unwrap()
        .query_row(
            "SELECT heads FROM projection_metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stored, checkpoint.heads);
    let snapshot = fs::read(
        directory
            .path()
            .join("automerge/documents")
            .join(format!("{root}.automerge")),
    )
    .unwrap();
    let doc = Automerge::load(&snapshot).unwrap();
    assert!(!doc.get_heads().is_empty());
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn restart_and_deleted_projection_rebuild_preserve_authority() {
    let directory = tempfile::tempdir().unwrap();
    let first = AppCore::open(directory.path()).await.unwrap();
    let root = first.create_new_dataset().await.unwrap();
    let category = first
        .create_category(CreateCategory {
            name: "Food".into(),
        })
        .await
        .unwrap();
    first
        .create_transaction(CreateTransaction {
            occurred_at_ms: 42,
            category_id: category,
            amount_minor: -725,
            description: "Lunch".into(),
        })
        .await
        .unwrap();
    first.shutdown().await.unwrap();

    fs::remove_file(directory.path().join("read-model.sqlite")).unwrap();
    for suffix in ["-wal", "-shm"] {
        let _ = fs::remove_file(directory.path().join(format!("read-model.sqlite{suffix}")));
    }
    let second = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(second.lifecycle_state(), ApplicationState::Ready { root });
    assert_eq!(
        second
            .transactions(&TransactionFilter::default())
            .unwrap()
            .len(),
        1
    );
    assert_eq!(second.aggregates().unwrap().balance_minor, -725);
    second.shutdown().await.unwrap();
}

#[tokio::test]
async fn stale_valid_checkpoint_is_rebuilt_before_ready() {
    let directory = tempfile::tempdir().unwrap();
    let first = AppCore::open(directory.path()).await.unwrap();
    first.create_new_dataset().await.unwrap();
    first
        .create_category(CreateCategory {
            name: "Travel".into(),
        })
        .await
        .unwrap();
    first.shutdown().await.unwrap();

    let database = Connection::open(directory.path().join("read-model.sqlite")).unwrap();
    database
        .execute(
            "UPDATE projection_metadata SET heads='v1:' WHERE singleton=1",
            [],
        )
        .unwrap();
    drop(database);
    let second = AppCore::open(directory.path()).await.unwrap();
    let checkpoint = match second.projection_state() {
        ProjectionState::Ready { checkpoint } => checkpoint,
        state => panic!("unexpected state {state:?}"),
    };
    assert_ne!(checkpoint.heads, "v1:");
    assert!(
        second
            .categories()
            .unwrap()
            .iter()
            .any(|item| item.name == "Travel")
    );
    second.shutdown().await.unwrap();
}

#[tokio::test]
async fn corrupt_projection_is_replaced_without_touching_authority() {
    let directory = tempfile::tempdir().unwrap();
    let first = AppCore::open(directory.path()).await.unwrap();
    let root = first.create_new_dataset().await.unwrap();
    first
        .create_category(CreateCategory {
            name: "Recovered".into(),
        })
        .await
        .unwrap();
    first.shutdown().await.unwrap();
    fs::write(directory.path().join("read-model.sqlite"), b"not sqlite").unwrap();

    let second = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(second.lifecycle_state(), ApplicationState::Ready { root });
    assert!(
        second
            .categories()
            .unwrap()
            .iter()
            .any(|item| item.name == "Recovered")
    );
    second.shutdown().await.unwrap();
}

#[tokio::test]
async fn lifecycle_is_retained_and_transient_lag_is_explicit() {
    let directory = tempfile::tempdir().unwrap();
    let config = AppCoreConfig {
        transient_event_capacity: 1,
        ..AppCoreConfig::default()
    };
    let app = AppCore::open_with_config(directory.path(), config)
        .await
        .unwrap();
    let mut events = app.subscribe_data_changed();
    let root = app.create_new_dataset().await.unwrap();
    app.create_category(CreateCategory { name: "A".into() })
        .await
        .unwrap();
    app.create_category(CreateCategory { name: "B".into() })
        .await
        .unwrap();
    assert!(matches!(
        events.recv().await,
        Err(tokio::sync::broadcast::error::RecvError::Lagged(_))
    ));
    assert_eq!(
        app.subscribe_lifecycle().borrow().clone(),
        ApplicationState::Ready { root }
    );
    assert!(matches!(
        app.subscribe_projection().borrow().clone(),
        ProjectionState::Ready { .. }
    ));
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn tombstones_are_monotonic_and_category_delete_does_not_cascade() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let category = app
        .create_category(CreateCategory {
            name: "Food".into(),
        })
        .await
        .unwrap();
    let transaction = app
        .create_transaction(CreateTransaction {
            occurred_at_ms: 1,
            category_id: category,
            amount_minor: -100,
            description: "Meal".into(),
        })
        .await
        .unwrap();
    app.delete_category(category).await.unwrap();
    let rows = app.transactions(&TransactionFilter::default()).unwrap();
    assert_eq!(rows.len(), 1);
    assert!(!rows[0].category_available);
    assert_eq!(app.aggregates().unwrap().balance_minor, -100);
    app.delete_transaction(transaction).await.unwrap();
    let error = app
        .update_transaction(UpdateTransaction {
            id: transaction,
            occurred_at_ms: None,
            category_id: None,
            amount_minor: None,
            description: Some("resurrect".into()),
        })
        .await
        .unwrap_err();
    assert!(error.to_string().contains("not found"));
    assert!(
        app.transactions(&TransactionFilter::default())
            .unwrap()
            .is_empty()
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn invalid_command_rolls_back_without_an_event_or_projection_change() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let before = app.projection_state();
    let mut events = app.subscribe_data_changed();
    let error = app
        .create_category(CreateCategory { name: "   ".into() })
        .await
        .unwrap_err();
    assert!(error.to_string().contains("invalid name"));
    assert_eq!(app.projection_state(), before);
    assert!(
        tokio::time::timeout(Duration::from_millis(25), events.recv())
            .await
            .is_err()
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn filters_ordering_and_field_updates_are_deterministic() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let category = app
        .create_category(CreateCategory { name: "One".into() })
        .await
        .unwrap();
    app.update_category(UpdateCategory {
        id: category,
        name: Some("Two".into()),
    })
    .await
    .unwrap();
    let first = app
        .create_transaction(CreateTransaction {
            occurred_at_ms: 2,
            category_id: category,
            amount_minor: 10,
            description: "Alpha".into(),
        })
        .await
        .unwrap();
    app.create_transaction(CreateTransaction {
        occurred_at_ms: 1,
        category_id: category,
        amount_minor: -3,
        description: "Beta".into(),
    })
    .await
    .unwrap();
    app.update_transaction(UpdateTransaction {
        id: first,
        occurred_at_ms: None,
        category_id: None,
        amount_minor: Some(12),
        description: Some("Alpha revised".into()),
    })
    .await
    .unwrap();
    let rows = app
        .transactions(&TransactionFilter {
            text: Some("alpha".into()),
            category_id: Some(category),
            from_ms: Some(2),
            through_ms: Some(2),
        })
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].amount_minor, 12);
    assert_eq!(rows[0].category_name.as_deref(), Some("Two"));
    assert_eq!(app.aggregates().unwrap().balance_minor, 9);
    app.shutdown().await.unwrap();
}

#[test]
fn uuidv7_entity_ids_do_not_use_sqlite_identity() {
    let one = CategoryId::new();
    let two = CategoryId::new();
    assert_ne!(one, two);
    assert_eq!(one.as_uuid().get_version_num(), 7);
}

#[test]
fn projection_schema_has_no_category_foreign_key_or_auto_increment() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("read-model.sqlite");
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let app = runtime.block_on(AppCore::open(directory.path())).unwrap();
    let connection = Connection::open(path).unwrap();
    let sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='transactions'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!sql.to_ascii_uppercase().contains("FOREIGN KEY"));
    assert!(!sql.to_ascii_uppercase().contains("AUTOINCREMENT"));
    let metadata: Option<String> = connection
        .query_row("SELECT root_id FROM projection_metadata", [], |row| {
            row.get(0)
        })
        .optional()
        .unwrap();
    assert!(metadata.is_none());
    drop(connection);
    runtime.block_on(app.shutdown()).unwrap();
}
