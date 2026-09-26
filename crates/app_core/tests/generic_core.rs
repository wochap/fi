use std::{collections::BTreeMap, sync::Arc, time::Duration};

use app_core::{
    Aggregation, AppCore, AppCoreConfig, BootstrapError, CalendarPolicy, CollectionQuery,
    ComparisonOperator, ComputedFieldDefinition, ComputedFieldId, DisplayMetadata, EnumOption,
    EnumOptionId, Expression, FieldDefinition, FieldId, FieldReference, FieldType, FieldValue,
    HlcError, HlcNodeId, NullOrder, ProjectionState, QueryDefinition, QueryId, QueryResult,
    QueryShape, SortClause, SortDirection, TypedValue, ValidationMetadata, ValueType,
    VersionedCollectionQuery, VersionedExpression, WallTime, execute_query,
};
use automerge_repo::testing::MemoryTransport;
use rusqlite::Connection;

struct FixedTime(i64);
impl WallTime for FixedTime {
    fn now_ms(&self) -> Result<i64, HlcError> {
        Ok(self.0)
    }
}

fn field(name: &str, field_type: FieldType, required: bool, order: i64) -> FieldDefinition {
    FieldDefinition {
        id: FieldId::new(),
        name: name.into(),
        field_type,
        required,
        default: None,
        validation: ValidationMetadata::default(),
        display: DisplayMetadata::default(),
        order,
        deleted: false,
        enum_options: vec![],
    }
}

async fn drive_memory(a: &MemoryTransport, b: &MemoryTransport) {
    for _ in 0..100 {
        tokio::task::yield_now().await;
        a.deliver_all().await;
        b.deliver_all().await;
    }
}

#[tokio::test]
async fn commands_require_a_root_and_generic_crud_survives_restart_and_projection_rebuild() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    assert!(matches!(
        app.create_collection("Nope".into(), String::new()).await,
        Err(app_core::AppError::Bootstrap(
            BootstrapError::DecisionRequired
        ))
    ));
    let root = app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Headaches".into(), "Symptom diary".into())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, true, 0);
    let notes = field("Notes", FieldType::Text, false, 1);
    app.add_field(collection, intensity.clone()).await.unwrap();
    app.add_field(collection, notes.clone()).await.unwrap();
    let record = app
        .create_record(
            collection,
            BTreeMap::from([
                (intensity.id, FieldValue::Integer(7)),
                (notes.id, FieldValue::Text("after lunch".into())),
            ]),
        )
        .await
        .unwrap();
    app.update_record_field(record, collection, intensity.id, FieldValue::Integer(8))
        .await
        .unwrap();
    assert_eq!(
        app.record(record).unwrap().unwrap().record.values[&intensity.id],
        FieldValue::Integer(8)
    );
    app.shutdown().await.unwrap();

    let read_model = directory.path().join("read-model.sqlite");
    std::fs::remove_file(&read_model).unwrap();
    let reopened = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(
        reopened.lifecycle_state(),
        app_core::ApplicationState::Ready { root }
    );
    assert_eq!(reopened.collections().unwrap()[0].name, "Headaches");
    assert_eq!(reopened.records(collection).unwrap().len(), 1);
    reopened.delete_record(record, collection).await.unwrap();
    assert!(reopened.records(collection).unwrap().is_empty());
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn signed_fixed_decimal_round_trips_through_authority_and_sqlite() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Money Movement".into(), String::new())
        .await
        .unwrap();
    let amount = field("Amount", FieldType::FixedDecimal { scale: 2 }, true, 0);
    app.add_field(collection, amount.clone()).await.unwrap();
    let record = app
        .create_record(
            collection,
            BTreeMap::from([(amount.id, FieldValue::FixedDecimal(-2350))]),
        )
        .await
        .unwrap();
    assert_eq!(
        app.record(record).unwrap().unwrap().record.values[&amount.id],
        FieldValue::FixedDecimal(-2350)
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn query_and_computed_definitions_and_results_survive_projection_rebuild() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Values".into(), String::new())
        .await
        .unwrap();
    let value = field("Value", FieldType::Integer, true, 0);
    app.add_field(collection, value.clone()).await.unwrap();
    app.create_record(
        collection,
        BTreeMap::from([(value.id, FieldValue::Integer(-7))]),
    )
    .await
    .unwrap();
    let computed = ComputedFieldDefinition {
        id: ComputedFieldId::new(),
        collection_id: collection,
        name: "Absolute".into(),
        declared_type: ValueType::Integer,
        nullable: false,
        expression: VersionedExpression::new(Expression::Abs {
            expression: Box::new(Expression::Field {
                field: FieldReference::Source(value.id),
            }),
        }),
        order: 0,
        deleted: false,
    };
    app.create_computed_field(computed.clone()).await.unwrap();
    let query = CollectionQuery {
        collection_id: collection,
        filter: None,
        grouping: None,
        shape: QueryShape::Scalar {
            aggregation: Aggregation::Sum {
                expression: Expression::Field {
                    field: FieldReference::Computed(computed.id),
                },
            },
        },
        sorting: vec![],
        limit: None,
        calendar: CalendarPolicy::default(),
    };
    let definition = QueryDefinition {
        id: QueryId::new(),
        collection_id: collection,
        name: "Absolute sum".into(),
        query: VersionedCollectionQuery::new(query.clone()),
        order: 0,
        deleted: false,
    };
    app.create_query_definition(definition.clone())
        .await
        .unwrap();
    let before = app.execute_collection_query(&query, 0).unwrap();
    assert_eq!(
        before,
        QueryResult::Scalar {
            value: TypedValue::Integer(7),
            value_type: ValueType::Integer
        }
    );
    app.shutdown().await.unwrap();
    std::fs::remove_file(directory.path().join("read-model.sqlite")).unwrap();
    let reopened = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(
        reopened.computed_fields(collection).unwrap(),
        vec![computed]
    );
    assert_eq!(
        reopened.query_definitions(collection).unwrap(),
        vec![definition]
    );
    assert_eq!(
        reopened.execute_collection_query(&query, 0).unwrap(),
        before
    );
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn pure_and_projected_execution_agree_for_supported_plans() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Differential".into(), String::new())
        .await
        .unwrap();
    let value = field("Value", FieldType::Integer, true, 0);
    let label = field("Label", FieldType::Text, false, 1);
    app.add_field(collection, value.clone()).await.unwrap();
    app.add_field(collection, label.clone()).await.unwrap();
    for (index, score) in [5_i64, -3, 9, 5, 0, -7].into_iter().enumerate() {
        let mut values = BTreeMap::from([(value.id, FieldValue::Integer(score))]);
        if index % 2 == 0 {
            values.insert(label.id, FieldValue::Text(format!("row {index}")));
        }
        app.create_record(collection, values).await.unwrap();
    }
    let computed = ComputedFieldDefinition {
        id: ComputedFieldId::new(),
        collection_id: collection,
        name: "Absolute".into(),
        declared_type: ValueType::Integer,
        nullable: false,
        expression: VersionedExpression::new(Expression::Abs {
            expression: Box::new(Expression::Field {
                field: FieldReference::Source(value.id),
            }),
        }),
        order: 0,
        deleted: false,
    };
    app.create_computed_field(computed.clone()).await.unwrap();

    let field_expr = Expression::Field {
        field: FieldReference::Source(value.id),
    };
    let pushed_down = CollectionQuery {
        collection_id: collection,
        filter: Some(Expression::Compare {
            operator: ComparisonOperator::GreaterThanOrEqual,
            left: Box::new(field_expr.clone()),
            right: Box::new(Expression::Constant {
                value: TypedValue::Integer(-3),
            }),
        }),
        grouping: None,
        shape: QueryShape::RecordSet {
            fields: vec![
                FieldReference::Source(value.id),
                FieldReference::Source(label.id),
            ],
        },
        sorting: vec![SortClause {
            expression: field_expr.clone(),
            direction: SortDirection::Descending,
            null_order: NullOrder::Last,
        }],
        limit: Some(3),
        calendar: CalendarPolicy::default(),
    };
    let computed_aggregate = CollectionQuery {
        collection_id: collection,
        filter: None,
        grouping: None,
        shape: QueryShape::Scalar {
            aggregation: Aggregation::Sum {
                expression: Expression::Field {
                    field: FieldReference::Computed(computed.id),
                },
            },
        },
        sorting: vec![],
        limit: None,
        calendar: CalendarPolicy::default(),
    };

    let schema = app.collection_schema(collection).unwrap().unwrap();
    let computed_fields = app.computed_fields(collection).unwrap();
    let all_records = app
        .records(collection)
        .unwrap()
        .into_iter()
        .filter(|view| view.valid)
        .map(|view| view.record)
        .collect::<Vec<_>>();
    for query in [pushed_down, computed_aggregate] {
        let projected = app.execute_collection_query(&query, 0).unwrap();
        let pure = execute_query(&query, &schema, &computed_fields, &all_records, 0).unwrap();
        assert_eq!(projected, pure);
    }
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn every_field_kind_defaults_null_diagnostics_and_enum_operations_project() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Typed values".into(), String::new())
        .await
        .unwrap();
    let option = EnumOption {
        id: EnumOptionId::new(),
        label: "Active".into(),
        order: 0,
        deleted: false,
    };
    let fields = [
        field("Text", FieldType::Text, false, 0),
        field("Integer", FieldType::Integer, true, 1),
        field("Decimal", FieldType::FixedDecimal { scale: 3 }, true, 2),
        field("Boolean", FieldType::Boolean, true, 3),
        field("Date", FieldType::Date, true, 4),
        field("DateTime", FieldType::DateTime, true, 5),
        field("Duration", FieldType::Duration, true, 6),
        field("Enum", FieldType::Enum, true, 7),
    ];
    for definition in &fields {
        app.add_field(collection, definition.clone()).await.unwrap();
    }
    app.upsert_enum_option(collection, fields[7].id, option.clone())
        .await
        .unwrap();
    let expected = BTreeMap::from([
        (fields[0].id, FieldValue::Null),
        (fields[1].id, FieldValue::Integer(i64::MIN)),
        (fields[2].id, FieldValue::FixedDecimal(-12_345)),
        (fields[3].id, FieldValue::Boolean(true)),
        (fields[4].id, FieldValue::Date(20_000)),
        (fields[5].id, FieldValue::DateTime(1_700_000_000_000)),
        (fields[6].id, FieldValue::Duration(90_000)),
        (fields[7].id, FieldValue::Enum(option.id)),
    ]);
    let record = app
        .create_record(collection, expected.clone())
        .await
        .unwrap();
    assert_eq!(app.record(record).unwrap().unwrap().record.values, expected);

    let failure = app
        .update_record_field(
            record,
            collection,
            fields[1].id,
            FieldValue::Text("wrong".into()),
        )
        .await
        .unwrap_err();
    assert!(matches!(failure, app_core::AppError::Domain(_)));
    assert_eq!(
        app.record(record).unwrap().unwrap().record.values[&fields[1].id],
        FieldValue::Integer(i64::MIN)
    );

    let unused = EnumOption {
        id: EnumOptionId::new(),
        label: "Archived".into(),
        order: 1,
        deleted: false,
    };
    app.upsert_enum_option(collection, fields[7].id, unused.clone())
        .await
        .unwrap();
    app.remove_enum_option(collection, fields[7].id, unused.id)
        .await
        .unwrap();
    app.remove_field(collection, fields[7].id).await.unwrap();
    let projected = app.record(record).unwrap().unwrap();
    assert!(!projected.valid);
    assert!(!projected.diagnostics.is_empty());
    assert_eq!(
        projected.record.values[&fields[7].id],
        FieldValue::Enum(option.id)
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn injected_clock_advances_across_restart_and_local_node_identity_is_durable() {
    let directory = tempfile::tempdir().unwrap();
    let config = AppCoreConfig {
        hlc_node_id: Some(HlcNodeId([9; 32])),
        wall_time: Arc::new(FixedTime(100)),
        ..AppCoreConfig::default()
    };
    let app = AppCore::open_with_config(directory.path(), config.clone())
        .await
        .unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Clock".into(), String::new())
        .await
        .unwrap();
    let value = field("Value", FieldType::Integer, true, 0);
    app.add_field(collection, value.clone()).await.unwrap();
    let record = app
        .create_record(
            collection,
            BTreeMap::from([(value.id, FieldValue::Integer(1))]),
        )
        .await
        .unwrap();
    let before = app.record(record).unwrap().unwrap().record.stamps[&value.id];
    app.shutdown().await.unwrap();

    let reopened = AppCore::open_with_config(directory.path(), config)
        .await
        .unwrap();
    reopened
        .update_record_field(record, collection, value.id, FieldValue::Integer(2))
        .await
        .unwrap();
    let after = reopened.record(record).unwrap().unwrap().record.stamps[&value.id];
    assert!(after > before);
    assert_eq!(after.node_id, HlcNodeId([9; 32]));
    reopened.shutdown().await.unwrap();

    let identity_dir = tempfile::tempdir().unwrap();
    let first = AppCore::open(identity_dir.path()).await.unwrap();
    first.shutdown().await.unwrap();
    let stored = std::fs::read_to_string(identity_dir.path().join("hlc-node-id")).unwrap();
    let second = AppCore::open(identity_dir.path()).await.unwrap();
    second.shutdown().await.unwrap();
    assert_eq!(
        std::fs::read_to_string(identity_dir.path().join("hlc-node-id")).unwrap(),
        stored
    );
}

#[tokio::test]
async fn stale_and_corrupt_projections_rebuild_without_touching_authority() {
    let directory = tempfile::tempdir().unwrap();
    let first = AppCore::open(directory.path()).await.unwrap();
    let root = first.create_new_dataset().await.unwrap();
    first
        .create_collection("Recovered".into(), String::new())
        .await
        .unwrap();
    first.shutdown().await.unwrap();

    let path = directory.path().join("read-model.sqlite");
    let database = Connection::open(&path).unwrap();
    database
        .execute(
            "UPDATE projection_metadata SET heads='v2:' WHERE singleton=1",
            [],
        )
        .unwrap();
    drop(database);
    let stale = AppCore::open(directory.path()).await.unwrap();
    let ProjectionState::Ready { checkpoint } = stale.projection_state() else {
        panic!("projection did not recover");
    };
    assert_ne!(checkpoint.heads, "v2:");
    assert_eq!(stale.collections().unwrap()[0].name, "Recovered");
    stale.shutdown().await.unwrap();

    std::fs::write(&path, b"not sqlite").unwrap();
    let corrupt = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(
        corrupt.lifecycle_state(),
        app_core::ApplicationState::Ready { root }
    );
    assert_eq!(corrupt.collections().unwrap()[0].name, "Recovered");
    corrupt.shutdown().await.unwrap();
}

#[tokio::test]
async fn invalid_command_has_no_write_projection_or_event() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let before = app.projection_state();
    let mut events = app.subscribe_data_changed();
    let failure = app
        .create_collection("   ".into(), String::new())
        .await
        .unwrap_err();
    assert!(matches!(failure, app_core::AppError::Domain(_)));
    assert_eq!(app.projection_state(), before);
    assert!(
        tokio::time::timeout(Duration::from_millis(25), events.recv())
            .await
            .is_err()
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn slider_flag_round_trips_and_invalid_slider_commits_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Pain".into(), String::new())
        .await
        .unwrap();
    let mut intensity = field("Intensity", FieldType::Integer, false, 0);
    intensity.validation.min_integer = Some(1);
    intensity.validation.max_integer = Some(5);
    intensity.display.slider = true;
    app.add_field(collection, intensity.clone()).await.unwrap();

    let mut unbounded = field("Unbounded", FieldType::Integer, false, 1);
    unbounded.validation.min_integer = Some(1);
    unbounded.display.slider = true;
    let before = app.projection_state();
    let failure = app.add_field(collection, unbounded).await.unwrap_err();
    assert!(matches!(
        failure,
        app_core::AppError::Domain(app_core::DomainError::Invalid {
            field: "slider",
            ..
        })
    ));
    assert_eq!(app.projection_state(), before);
    app.shutdown().await.unwrap();

    std::fs::remove_file(directory.path().join("read-model.sqlite")).unwrap();
    let reopened = AppCore::open(directory.path()).await.unwrap();
    let schema = reopened.collection_schema(collection).unwrap().unwrap();
    assert_eq!(schema.fields, vec![intensity]);
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn in_memory_two_device_schema_and_record_sync() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let (a_network, b_network) = MemoryTransport::pair("generic-a", "generic-b", 256);
    let a = AppCore::open_with_transport(a_dir.path(), a_network.clone())
        .await
        .unwrap();
    let b = AppCore::open_with_transport(b_dir.path(), b_network.clone())
        .await
        .unwrap();
    let root = a.create_new_dataset().await.unwrap();
    let collection = a
        .create_collection("Shared".into(), String::new())
        .await
        .unwrap();
    let title = field("Title", FieldType::Text, true, 0);
    a.add_field(collection, title.clone()).await.unwrap();
    let record = a
        .create_record(
            collection,
            BTreeMap::from([(title.id, FieldValue::Text("hello".into()))]),
        )
        .await
        .unwrap();
    a_network.connect().await;
    drive_memory(&a_network, &b_network).await;
    b.join_existing(root).await.unwrap();
    drive_memory(&a_network, &b_network).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                b.lifecycle_state(),
                app_core::ApplicationState::Ready { .. }
            ) && b.record(record).is_ok_and(|value| value.is_some())
            {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        a.collection_schema(collection).unwrap(),
        b.collection_schema(collection).unwrap()
    );
    assert_eq!(a.record(record).unwrap(), b.record(record).unwrap());
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn required_may_be_introduced_over_records_that_lack_the_field() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Headaches".into(), String::new())
        .await
        .unwrap();
    let other = app
        .create_collection("Meals".into(), String::new())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, false, 0);
    app.add_field(collection, intensity.clone()).await.unwrap();
    let sparse = app
        .create_record(collection, BTreeMap::new())
        .await
        .unwrap();
    let filled = app
        .create_record(
            collection,
            BTreeMap::from([(intensity.id, FieldValue::Integer(7))]),
        )
        .await
        .unwrap();

    // Making it required with no default is accepted; the sparse record becomes invalid instead.
    let mut required = intensity.clone();
    required.required = true;
    app.update_field(collection, required.clone())
        .await
        .unwrap();

    let projected = app.record(sparse).unwrap().unwrap();
    assert!(!projected.valid);
    let diagnostic = projected
        .diagnostics
        .iter()
        .find(|item| item.kind == "record_validation")
        .expect("missing-required diagnostic");
    assert_eq!(diagnostic.field_id, Some(intensity.id));
    assert!(app.record(filled).unwrap().unwrap().valid);

    // Neither this collection nor any other is blocked by the invalid record.
    let repaired = app
        .create_record(
            collection,
            BTreeMap::from([(intensity.id, FieldValue::Integer(3))]),
        )
        .await
        .unwrap();
    assert!(app.record(repaired).unwrap().unwrap().valid);
    let elsewhere = app.create_record(other, BTreeMap::new()).await.unwrap();
    assert!(app.record(elsewhere).unwrap().unwrap().valid);

    // Supplying the value repairs the record through ordinary typed editing.
    app.update_record_field(sparse, collection, intensity.id, FieldValue::Integer(5))
        .await
        .unwrap();
    let repaired_view = app.record(sparse).unwrap().unwrap();
    assert!(repaired_view.valid);
    assert!(repaired_view.diagnostics.is_empty());

    // A required field carrying a default leaves records lacking it valid, because the default
    // satisfies the constraint on read.
    let mut notes = field("Notes", FieldType::Text, true, 1);
    notes.default = Some(FieldValue::Text("none".into()));
    app.add_field(collection, notes.clone()).await.unwrap();
    for id in [sparse, filled, repaired] {
        let view = app.record(id).unwrap().unwrap();
        assert!(view.valid, "record {id:?} should stay valid");
    }

    // Adding a required field with no default over existing records is accepted too.
    let mood = field("Mood", FieldType::Text, true, 2);
    app.add_field(collection, mood.clone()).await.unwrap();
    let view = app.record(filled).unwrap().unwrap();
    assert!(!view.valid);
    assert!(
        view.diagnostics
            .iter()
            .any(|item| item.field_id == Some(mood.id))
    );

    app.shutdown().await.unwrap();
}

/// Seeds `count` records carrying `Text` values in `category`, returning their IDs.
async fn seed_batch_records(
    app: &AppCore,
    collection: app_core::CollectionSchemaId,
    title: &FieldDefinition,
    count: usize,
) -> Vec<app_core::RecordId> {
    let mut ids = Vec::with_capacity(count);
    for index in 0..count {
        ids.push(
            app.create_record(
                collection,
                BTreeMap::from([(title.id, FieldValue::Text(format!("row {index}")))]),
            )
            .await
            .unwrap(),
        );
    }
    ids
}

#[tokio::test]
async fn a_batch_commits_once_and_emits_one_records_event() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Inbox".into(), String::new())
        .await
        .unwrap();
    let title = field("Title", FieldType::Text, true, 0);
    let category = field("Category", FieldType::Text, false, 1);
    app.add_field(collection, title.clone()).await.unwrap();
    app.add_field(collection, category.clone()).await.unwrap();
    let ids = seed_batch_records(&app, collection, &title, 4).await;

    let ProjectionState::Ready { checkpoint: before } = app.projection_state() else {
        panic!("projection not ready");
    };
    let mut events = app.subscribe_data_changed();
    app.set_records_field(
        ids.clone(),
        collection,
        category.id,
        FieldValue::Text("triage".into()),
    )
    .await
    .unwrap();

    let event = tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(event.kinds, vec![app_core::DomainKind::Records]);
    assert_eq!(event.collection_ids, vec![collection]);
    assert_ne!(event.checkpoint.heads, before.heads);
    assert!(
        tokio::time::timeout(Duration::from_millis(50), events.recv())
            .await
            .is_err(),
        "a batch emits exactly one DataChanged"
    );
    let ProjectionState::Ready { checkpoint: after } = app.projection_state() else {
        panic!("projection not ready");
    };
    assert_eq!(after, event.checkpoint, "one checkpoint advance per batch");

    let records = app.records(collection).unwrap();
    assert_eq!(records.len(), 4);
    assert!(
        records
            .iter()
            .all(|view| view.record.values[&category.id] == FieldValue::Text("triage".into()))
    );

    app.delete_records(ids, collection).await.unwrap();
    let event = tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(event.collection_ids, vec![collection]);
    assert!(
        tokio::time::timeout(Duration::from_millis(50), events.recv())
            .await
            .is_err(),
        "a batch delete emits exactly one DataChanged"
    );
    assert!(app.records(collection).unwrap().is_empty());
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn a_peer_never_observes_a_partially_applied_batch() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let (a_network, b_network) = MemoryTransport::pair("batch-a", "batch-b", 256);
    let a = AppCore::open_with_transport(a_dir.path(), a_network.clone())
        .await
        .unwrap();
    let b = AppCore::open_with_transport(b_dir.path(), b_network.clone())
        .await
        .unwrap();
    let root = a.create_new_dataset().await.unwrap();
    let collection = a
        .create_collection("Shared".into(), String::new())
        .await
        .unwrap();
    let title = field("Title", FieldType::Text, true, 0);
    a.add_field(collection, title.clone()).await.unwrap();
    let ids = seed_batch_records(&a, collection, &title, 6).await;

    a_network.connect().await;
    drive_memory(&a_network, &b_network).await;
    b.join_existing(root).await.unwrap();
    drive_memory(&a_network, &b_network).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                b.lifecycle_state(),
                app_core::ApplicationState::Ready { .. }
            ) && b.records(collection).map(|rows| rows.len()).unwrap_or(0) == 6
            {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();

    a.delete_records(ids, collection).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let remaining = b.records(collection).unwrap().len();
            assert!(
                remaining == 6 || remaining == 0,
                "peer observed a strict subset of the batch: {remaining} of 6"
            );
            if remaining == 0 {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();

    assert_eq!(a.records(collection).unwrap().len(), 0);
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn record_draft_validation_reports_every_issue_and_commits_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Headaches".into(), String::new())
        .await
        .unwrap();
    let title = field("Title", FieldType::Text, true, 0);
    let intensity = FieldDefinition {
        validation: ValidationMetadata {
            min_integer: Some(1),
            max_integer: Some(10),
            ..ValidationMetadata::default()
        },
        ..field("Intensity", FieldType::Integer, false, 1)
    };
    app.add_field(collection, title.clone()).await.unwrap();
    app.add_field(collection, intensity.clone()).await.unwrap();
    let before = app.projection_state();
    let mut events = app.subscribe_data_changed();

    let issues = app
        .validate_record_draft(
            collection,
            None,
            BTreeMap::from([(intensity.id, FieldValue::Integer(11))]),
        )
        .unwrap();
    assert_eq!(
        issues
            .iter()
            .map(|issue| (issue.fields.clone(), issue.code.as_str()))
            .collect::<Vec<_>>(),
        vec![
            (vec![title.id.to_string()], "required"),
            (vec![intensity.id.to_string()], "out_of_range"),
        ]
    );
    assert!(
        app.validate_record_draft(
            collection,
            None,
            BTreeMap::from([(title.id, FieldValue::Text("Aura".into()))]),
        )
        .unwrap()
        .is_empty()
    );
    assert!(app.records(collection).unwrap().is_empty());
    assert_eq!(app.projection_state(), before);
    assert!(
        tokio::time::timeout(Duration::from_millis(25), events.recv())
            .await
            .is_err()
    );

    // Update semantics: the draft is merged over the stored values.
    let record = app
        .create_record(
            collection,
            BTreeMap::from([(title.id, FieldValue::Text("Aura".into()))]),
        )
        .await
        .unwrap();
    assert!(
        app.validate_record_draft(
            collection,
            Some(record),
            BTreeMap::from([(intensity.id, FieldValue::Integer(4))]),
        )
        .unwrap()
        .is_empty()
    );
    let issues = app
        .validate_record_draft(
            collection,
            Some(record),
            BTreeMap::from([(title.id, FieldValue::Null)]),
        )
        .unwrap();
    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0].message, "Required");
    app.shutdown().await.unwrap();
}
