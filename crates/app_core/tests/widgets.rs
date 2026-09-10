//! Widget authority, evaluation isolation, and two-device preservation.

use std::{collections::BTreeMap, sync::Arc, time::Duration};

use app_core::{
    Aggregation, AppCore, CalendarPolicy, CollectionQuery, DisplayMetadata, DomainKind, Expression,
    FieldDefinition, FieldId, FieldReference, FieldType, FieldValue, ProjectionState,
    QueryDefinition, QueryId, QueryResult, QueryShape, RoundingPolicy, StructuredValue, TypedValue,
    ValidationMetadata, ValueType, VersionedCollectionQuery, WidgetConfiguration, WidgetDefinition,
    WidgetError, WidgetEvaluation, WidgetId, WidgetLayout, WidgetType, WidgetUpdate, execute_query,
};
use automerge_repo::testing::MemoryTransport;
use rusqlite::Connection;

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
        enum_options: vec![],
        deleted: false,
    }
}

async fn drive_memory(a: &MemoryTransport, b: &MemoryTransport) {
    for _ in 0..100 {
        tokio::task::yield_now().await;
        a.deliver_all().await;
        b.deliver_all().await;
    }
}

/// Drives both transports until the predicate holds, failing the test on timeout.
async fn wait_for(a: &MemoryTransport, b: &MemoryTransport, mut ready: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if ready() {
                break;
            }
            drive_memory(a, b).await;
        }
    })
    .await
    .unwrap();
}

/// Two paired devices: device A created the dataset root and device B has joined it and is Ready.
async fn joined_pair(
    a_name: &str,
    b_name: &str,
) -> (
    tempfile::TempDir,
    tempfile::TempDir,
    Arc<MemoryTransport>,
    Arc<MemoryTransport>,
    AppCore,
    AppCore,
) {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let (a_network, b_network) = MemoryTransport::pair(a_name, b_name, 256);
    let a = AppCore::open_with_transport(a_dir.path(), a_network.clone())
        .await
        .unwrap();
    let b = AppCore::open_with_transport(b_dir.path(), b_network.clone())
        .await
        .unwrap();
    let root = a.create_new_dataset().await.unwrap();
    a_network.connect().await;
    drive_memory(&a_network, &b_network).await;
    b.join_existing(root).await.unwrap();
    drive_memory(&a_network, &b_network).await;
    wait_for(&a_network, &b_network, || {
        matches!(
            b.lifecycle_state(),
            app_core::ApplicationState::Ready { .. }
        )
    })
    .await;
    (a_dir, b_dir, a_network, b_network, a, b)
}

fn collection_query(
    collection_id: app_core::CollectionSchemaId,
    shape: QueryShape,
) -> CollectionQuery {
    CollectionQuery {
        collection_id,
        filter: None,
        grouping: None,
        shape,
        sorting: vec![],
        limit: None,
        calendar: CalendarPolicy::default(),
    }
}

fn source(field_id: FieldId) -> Expression {
    Expression::Field {
        field: FieldReference::Source(field_id),
    }
}

fn count_query(collection_id: app_core::CollectionSchemaId, id: QueryId) -> QueryDefinition {
    QueryDefinition {
        id,
        collection_id,
        name: "Record count".into(),
        query: VersionedCollectionQuery::new(CollectionQuery {
            collection_id,
            filter: None,
            grouping: None,
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Count,
            },
            sorting: vec![],
            limit: None,
            calendar: CalendarPolicy::default(),
        }),
        order: 0,
        deleted: false,
    }
}

fn series_query(collection_id: app_core::CollectionSchemaId, id: QueryId) -> QueryDefinition {
    let constant = Expression::Constant {
        value: TypedValue::Integer(0),
    };
    QueryDefinition {
        name: "Series".into(),
        query: VersionedCollectionQuery::new(CollectionQuery {
            collection_id,
            filter: None,
            grouping: None,
            shape: QueryShape::Series {
                x: constant.clone(),
                y: constant,
            },
            sorting: vec![],
            limit: None,
            calendar: CalendarPolicy::default(),
        }),
        ..count_query(collection_id, id)
    }
}

fn widget(
    collection_id: app_core::CollectionSchemaId,
    query_id: QueryId,
    widget_type: &str,
    order: i64,
) -> WidgetDefinition {
    WidgetDefinition {
        id: WidgetId::new(),
        collection_id,
        widget_type: WidgetType::new(widget_type).unwrap(),
        query_id,
        title: "Widget".into(),
        configuration: WidgetConfiguration::empty(),
        layout: WidgetLayout::default(),
        order,
        deleted: false,
    }
}

/// A collection with one record, a scalar count query, and an ordered Series query.
async fn seeded() -> (
    tempfile::TempDir,
    AppCore,
    app_core::CollectionSchemaId,
    QueryId,
    QueryId,
) {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Headaches".into(), "Symptom diary".into())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, true, 0);
    app.add_field(collection, intensity.clone()).await.unwrap();
    app.create_record(
        collection,
        BTreeMap::from([(intensity.id, FieldValue::Integer(7))]),
    )
    .await
    .unwrap();
    let scalar_id = QueryId::new();
    app.create_query_definition(count_query(collection, scalar_id))
        .await
        .unwrap();
    let series_id = QueryId::new();
    app.create_query_definition(series_query(collection, series_id))
        .await
        .unwrap();
    (directory, app, collection, scalar_id, series_id)
}

#[tokio::test]
async fn widget_crud_projects_and_emits_a_widgets_domain_event() {
    let (_directory, app, collection, scalar_id, _series_id) = seeded().await;
    let mut events = app.subscribe_data_changed();

    let definition = widget(collection, scalar_id, "core.aggregate-number", 0);
    app.create_widget(definition.clone()).await.unwrap();
    let event = tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(event.kinds, vec![DomainKind::Widgets]);
    assert_eq!(event.collection_ids, vec![collection]);

    assert_eq!(
        app.widget_definitions(collection).unwrap(),
        vec![definition.clone()]
    );
    assert_eq!(
        app.widget_definition(collection, definition.id).unwrap(),
        Some(definition.clone())
    );

    // A granular metadata edit touches only the requested registers.
    app.update_widget(WidgetUpdate {
        id: definition.id,
        collection_id: collection,
        title: Some("Renamed".into()),
        order: Some(3),
        ..WidgetUpdate::default()
    })
    .await
    .unwrap();
    let updated = app
        .widget_definition(collection, definition.id)
        .unwrap()
        .unwrap();
    assert_eq!(updated.title, "Renamed");
    assert_eq!(updated.order, 3);
    assert_eq!(updated.widget_type, definition.widget_type);
    assert_eq!(updated.configuration, definition.configuration);

    // Removal tombstones the definition: the active list drops it, the definition stays readable.
    app.remove_widget(collection, definition.id).await.unwrap();
    assert!(app.widget_definitions(collection).unwrap().is_empty());
    let tombstoned = app
        .widget_definition(collection, definition.id)
        .unwrap()
        .unwrap();
    assert!(tombstoned.deleted);
    assert!(
        app.remove_widget(collection, definition.id).await.is_err(),
        "a tombstone is not a valid command target again"
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn widget_definitions_survive_restart_and_projection_rebuild() {
    let (directory, app, collection, scalar_id, _series_id) = seeded().await;
    let preserved = WidgetDefinition {
        widget_type: WidgetType::new("com.example.future-widget").unwrap(),
        configuration: WidgetConfiguration {
            version: 9,
            body: StructuredValue::Map(BTreeMap::from([(
                "opaque".into(),
                StructuredValue::List(vec![
                    StructuredValue::Integer(-2350),
                    StructuredValue::Text("2576.50".into()),
                    StructuredValue::Null,
                ]),
            )])),
        },
        ..widget(collection, scalar_id, "core.aggregate-number", 1)
    };
    app.create_widget(preserved.clone()).await.unwrap();
    app.shutdown().await.unwrap();

    // Deleting the read model forces a full rebuild from authoritative Automerge.
    std::fs::remove_file(directory.path().join("read-model.sqlite")).unwrap();
    let reopened = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(
        reopened.widget_definitions(collection).unwrap(),
        vec![preserved]
    );
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn one_invalid_widget_does_not_stop_the_others_or_the_record_list() {
    let (_directory, app, collection, scalar_id, series_id) = seeded().await;
    let good = widget(collection, scalar_id, "core.aggregate-number", 0);
    // An aggregate number cannot render an ordered Series result.
    let mismatched = widget(collection, series_id, "core.aggregate-number", 1);
    let unknown = widget(collection, scalar_id, "com.example.future-widget", 2);
    app.create_widget(good.clone()).await.unwrap();
    app.create_widget(unknown.clone()).await.unwrap();

    // The shape contract is enforced locally, so the mismatched widget cannot be created here,
    // and an existing widget cannot be repointed at an incompatible query either.
    assert!(app.create_widget(mismatched.clone()).await.is_err());
    assert!(
        app.update_widget(WidgetUpdate {
            id: good.id,
            collection_id: collection,
            query_id: Some(series_id),
            ..WidgetUpdate::default()
        })
        .await
        .is_err()
    );

    let evaluations = app.evaluate_widgets(collection, 1_700_000_000_000).unwrap();
    assert_eq!(evaluations.len(), 2);
    match &evaluations[0] {
        WidgetEvaluation::Ready {
            widget_id,
            widget_type,
            result,
        } => {
            assert_eq!(*widget_id, good.id);
            assert_eq!(widget_type, "core.aggregate-number");
            assert!(matches!(result, app_core::QueryResult::Scalar { .. }));
        }
        failure => panic!("the valid widget must render: {failure:?}"),
    }
    match &evaluations[1] {
        WidgetEvaluation::Failed {
            widget_id,
            widget_type,
            error,
        } => {
            assert_eq!(*widget_id, unknown.id);
            assert_eq!(widget_type, "com.example.future-widget");
            assert!(matches!(error, WidgetError::UnsupportedType { .. }));
        }
        ready => panic!("the unknown widget must stay unsupported: {ready:?}"),
    }

    // The record list, schema, and single-widget evaluation all keep working.
    assert_eq!(app.records(collection).unwrap().len(), 1);
    assert!(app.collection_schema(collection).unwrap().is_some());
    assert!(
        app.evaluate_widget(collection, good.id, 1_700_000_000_000)
            .unwrap()
            .is_ready()
    );
    assert!(
        app.widget_diagnostics(unknown.id).unwrap().is_empty(),
        "an unimplemented widget type is not a validation error"
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn unsupported_widgets_sync_intact_and_evaluate_to_a_typed_error_on_both_devices() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let (a_network, b_network) = MemoryTransport::pair("widget-a", "widget-b", 256);
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
    let amount = field("Amount", FieldType::FixedDecimal { scale: 2 }, true, 0);
    a.add_field(collection, amount.clone()).await.unwrap();
    a.create_record(
        collection,
        BTreeMap::from([(amount.id, FieldValue::FixedDecimal(-2350))]),
    )
    .await
    .unwrap();
    let scalar_id = QueryId::new();
    a.create_query_definition(count_query(collection, scalar_id))
        .await
        .unwrap();

    let future = WidgetDefinition {
        widget_type: WidgetType::new("com.example.calendar-heatmap").unwrap(),
        title: "Calendar heatmap".into(),
        configuration: WidgetConfiguration {
            version: 12,
            body: StructuredValue::Map(BTreeMap::from([(
                "palette".into(),
                StructuredValue::Map(BTreeMap::from([(
                    "shader".into(),
                    StructuredValue::Text("heat".into()),
                )])),
            )])),
        },
        ..widget(collection, scalar_id, "core.aggregate-number", 0)
    };
    a.create_widget(future.clone()).await.unwrap();

    a_network.connect().await;
    drive_memory(&a_network, &b_network).await;
    b.join_existing(root).await.unwrap();
    drive_memory(&a_network, &b_network).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if matches!(
                b.lifecycle_state(),
                app_core::ApplicationState::Ready { .. }
            ) && b
                .widget_definitions(collection)
                .is_ok_and(|widgets| !widgets.is_empty())
            {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();

    // Device B never requested the widget and has no renderer for it, yet the definition is intact.
    assert_eq!(
        a.widget_definitions(collection).unwrap(),
        b.widget_definitions(collection).unwrap()
    );
    assert_eq!(
        b.widget_definitions(collection).unwrap(),
        vec![future.clone()]
    );
    assert!(b.widget_diagnostics(future.id).unwrap().is_empty());

    let evaluations = b.evaluate_widgets(collection, 1_700_000_000_000).unwrap();
    assert_eq!(evaluations.len(), 1);
    match &evaluations[0] {
        WidgetEvaluation::Failed {
            widget_id,
            widget_type,
            error,
        } => {
            assert_eq!(*widget_id, future.id);
            assert_eq!(widget_type, "com.example.calendar-heatmap");
            assert!(matches!(error, WidgetError::UnsupportedType { .. }));
        }
        ready => panic!("device B must not fake a render: {ready:?}"),
    }

    // Device B can still rename it without learning anything about its presentation.
    b.update_widget(WidgetUpdate {
        id: future.id,
        collection_id: collection,
        title: Some("Renamed on B".into()),
        ..WidgetUpdate::default()
    })
    .await
    .unwrap();
    drive_memory(&a_network, &b_network).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if a.widget_definition(collection, future.id)
                .is_ok_and(|widget| widget.is_some_and(|item| item.title == "Renamed on B"))
            {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();
    let on_a = a.widget_definition(collection, future.id).unwrap().unwrap();
    assert_eq!(on_a.title, "Renamed on B");
    assert_eq!(on_a.widget_type, future.widget_type);
    assert_eq!(on_a.configuration, future.configuration);
    assert_eq!(on_a.query_id, future.query_id);

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

/// 7.1: widget order and tombstones synchronize intact across devices, and a tombstoned widget
/// cannot be resurrected on the receiving device.
#[tokio::test]
async fn widget_order_and_tombstones_synchronize_intact_across_devices() {
    let (_a_dir, _b_dir, a_network, b_network, a, b) = joined_pair("order-a", "order-b").await;
    let collection = a
        .create_collection("Shared".into(), String::new())
        .await
        .unwrap();
    let amount = field("Amount", FieldType::Integer, true, 0);
    a.add_field(collection, amount.clone()).await.unwrap();
    a.create_record(
        collection,
        BTreeMap::from([(amount.id, FieldValue::Integer(3))]),
    )
    .await
    .unwrap();
    let scalar_id = QueryId::new();
    a.create_query_definition(count_query(collection, scalar_id))
        .await
        .unwrap();
    let series_id = QueryId::new();
    a.create_query_definition(series_query(collection, series_id))
        .await
        .unwrap();

    let first = widget(collection, scalar_id, "core.aggregate-number", 0);
    let second = widget(collection, series_id, "core.line-chart", 1);
    let third = widget(collection, scalar_id, "core.aggregate-number", 2);
    for definition in [&first, &second, &third] {
        a.create_widget(definition.clone()).await.unwrap();
    }

    wait_for(&a_network, &b_network, || {
        b.widget_definitions(collection).is_ok_and(|w| w.len() == 3)
    })
    .await;
    let order_on = |app: &AppCore| {
        app.widget_definitions(collection)
            .unwrap()
            .into_iter()
            .map(|item| item.id)
            .collect::<Vec<_>>()
    };
    assert_eq!(order_on(&a), vec![first.id, second.id, third.id]);
    assert_eq!(order_on(&a), order_on(&b));

    // A reorders; the new order becomes visible on B without B doing anything.
    a.reorder_widgets(collection, vec![third.id, first.id, second.id])
        .await
        .unwrap();
    wait_for(&a_network, &b_network, || {
        order_on(&b) == vec![third.id, first.id, second.id]
    })
    .await;
    assert_eq!(order_on(&a), order_on(&b));

    // A tombstones the middle widget; B drops it from the active list but keeps it readable.
    a.remove_widget(collection, first.id).await.unwrap();
    wait_for(&a_network, &b_network, || {
        b.widget_definitions(collection).is_ok_and(|w| w.len() == 2)
    })
    .await;
    assert_eq!(order_on(&a), vec![third.id, second.id]);
    assert_eq!(order_on(&a), order_on(&b));
    let tombstoned_on_b = b.widget_definition(collection, first.id).unwrap().unwrap();
    assert!(tombstoned_on_b.deleted);

    // B cannot resurrect the tombstone: creating the same id fails, and there is no writable path
    // back to an active definition.
    assert!(b.create_widget(tombstoned_on_b.clone()).await.is_err());
    assert!(
        b.update_widget(WidgetUpdate {
            id: first.id,
            collection_id: collection,
            title: Some("Back".into()),
            ..WidgetUpdate::default()
        })
        .await
        .is_err()
    );
    assert!(b.remove_widget(collection, first.id).await.is_err());
    assert_eq!(order_on(&b), vec![third.id, second.id]);

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

/// 7.2: the full Device A/Device B Headache scenario — schema, widgets, and generic records created
/// on one device drive CRUD and both dashboards on the other, and a record added on B returns to A.
#[tokio::test]
async fn headache_schema_widgets_and_records_synchronize_and_drive_both_dashboards() {
    let (_a_dir, _b_dir, a_network, b_network, a, b) =
        joined_pair("headache-a", "headache-b").await;
    let collection = a
        .create_collection("Headache".into(), "Symptom diary".into())
        .await
        .unwrap();
    let started_at = field("Started at", FieldType::DateTime, true, 0);
    let ended_at = field("Ended at", FieldType::DateTime, false, 1);
    let mut intensity = field("Intensity", FieldType::Integer, true, 2);
    intensity.validation = ValidationMetadata {
        min_integer: Some(1),
        max_integer: Some(10),
        ..ValidationMetadata::default()
    };
    let notes = field("Notes", FieldType::Text, false, 3);
    for definition in [&started_at, &ended_at, &intensity, &notes] {
        a.add_field(collection, definition.clone()).await.unwrap();
    }

    // Average Intensity: scalar average of intensity at scale two.
    let average_id = QueryId::new();
    a.create_query_definition(QueryDefinition {
        id: average_id,
        collection_id: collection,
        name: "Average Intensity".into(),
        query: VersionedCollectionQuery::new(collection_query(
            collection,
            QueryShape::Scalar {
                aggregation: Aggregation::Average {
                    expression: source(intensity.id),
                    output_scale: 2,
                    rounding: RoundingPolicy::HalfEven,
                },
            },
        )),
        order: 0,
        deleted: false,
    })
    .await
    .unwrap();
    // Intensity History: series of intensity over started_at.
    let history_id = QueryId::new();
    a.create_query_definition(QueryDefinition {
        id: history_id,
        collection_id: collection,
        name: "Intensity History".into(),
        query: VersionedCollectionQuery::new(collection_query(
            collection,
            QueryShape::Series {
                x: source(started_at.id),
                y: source(intensity.id),
            },
        )),
        order: 1,
        deleted: false,
    })
    .await
    .unwrap();

    let average_widget = WidgetDefinition {
        title: "Average Intensity".into(),
        ..widget(collection, average_id, "core.aggregate-number", 0)
    };
    let history_widget = WidgetDefinition {
        title: "Intensity History".into(),
        ..widget(collection, history_id, "core.line-chart", 1)
    };
    a.create_widget(average_widget.clone()).await.unwrap();
    a.create_widget(history_widget.clone()).await.unwrap();

    let first = a
        .create_record(
            collection,
            BTreeMap::from([
                (started_at.id, FieldValue::DateTime(1_700_000_000_000)),
                (intensity.id, FieldValue::Integer(7)),
            ]),
        )
        .await
        .unwrap();

    // Device B receives everything and renders generic CRUD plus both widgets without any
    // Headache-specific code.
    wait_for(&a_network, &b_network, || {
        b.record(first).is_ok_and(|value| value.is_some())
            && b.widget_definitions(collection).is_ok_and(|w| w.len() == 2)
    })
    .await;
    assert_eq!(
        a.collection_schema(collection).unwrap(),
        b.collection_schema(collection).unwrap()
    );
    assert_eq!(a.record(first).unwrap(), b.record(first).unwrap());
    assert_eq!(
        b.widget_definitions(collection).unwrap(),
        vec![average_widget.clone(), history_widget.clone()]
    );

    let dashboard = |app: &AppCore| -> (QueryResult, QueryResult) {
        let evaluations = app.evaluate_widgets(collection, 1_700_000_000_000).unwrap();
        assert_eq!(evaluations.len(), 2);
        let mut results = Vec::new();
        for evaluation in &evaluations {
            match evaluation {
                WidgetEvaluation::Ready { result, .. } => results.push(result.clone()),
                failure => panic!("both widgets must render: {failure:?}"),
            }
        }
        (results.remove(0), results.remove(0))
    };
    let (average, history) = dashboard(&b);
    assert_eq!(
        average,
        QueryResult::Scalar {
            value: TypedValue::FixedDecimal {
                representation: 700,
                scale: 2
            },
            value_type: ValueType::FixedDecimal { scale: 2 }
        }
    );
    match history {
        QueryResult::Series { ref points, .. } => assert_eq!(points.len(), 1),
        ref other => panic!("expected a series: {other:?}"),
    }

    // Device B adds a valid record; it returns to A and both dashboards update on both devices.
    let second = b
        .create_record(
            collection,
            BTreeMap::from([
                (started_at.id, FieldValue::DateTime(1_700_086_400_000)),
                (intensity.id, FieldValue::Integer(5)),
                (notes.id, FieldValue::Text("after lunch".into())),
            ]),
        )
        .await
        .unwrap();
    wait_for(&a_network, &b_network, || {
        a.record(second).is_ok_and(|value| value.is_some())
    })
    .await;
    assert_eq!(a.records(collection).unwrap().len(), 2);
    assert_eq!(a.record(second).unwrap(), b.record(second).unwrap());

    for app in [&a, &b] {
        let (average, history) = dashboard(app);
        assert_eq!(
            average,
            QueryResult::Scalar {
                value: TypedValue::FixedDecimal {
                    representation: 600,
                    scale: 2
                },
                value_type: ValueType::FixedDecimal { scale: 2 }
            },
            "average of 7 and 5 is exactly 6.00 at scale two"
        );
        match history {
            QueryResult::Series { ref points, .. } => assert_eq!(points.len(), 2),
            ref other => panic!("expected a two-point series: {other:?}"),
        }
    }

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

/// 7.3: the full Money Movement scenario — signed scale-two records aggregate to the exact integer
/// representation `257650` (display `2576.50`) with no binary floating point in the authority.
#[tokio::test]
async fn money_movement_balance_is_an_exact_integer_across_devices() {
    let (_a_dir, _b_dir, a_network, b_network, a, b) = joined_pair("money-a", "money-b").await;
    let collection = a
        .create_collection("Money Movement".into(), String::new())
        .await
        .unwrap();
    let amount = field("Amount", FieldType::FixedDecimal { scale: 2 }, true, 0);
    a.add_field(collection, amount.clone()).await.unwrap();
    for representation in [350_000_i64, -90_000, -2_350] {
        a.create_record(
            collection,
            BTreeMap::from([(amount.id, FieldValue::FixedDecimal(representation))]),
        )
        .await
        .unwrap();
    }

    let balance_id = QueryId::new();
    a.create_query_definition(QueryDefinition {
        id: balance_id,
        collection_id: collection,
        name: "Balance".into(),
        query: VersionedCollectionQuery::new(collection_query(
            collection,
            QueryShape::Scalar {
                aggregation: Aggregation::Sum {
                    expression: source(amount.id),
                },
            },
        )),
        order: 0,
        deleted: false,
    })
    .await
    .unwrap();
    let average_id = QueryId::new();
    a.create_query_definition(QueryDefinition {
        id: average_id,
        collection_id: collection,
        name: "Average movement".into(),
        query: VersionedCollectionQuery::new(collection_query(
            collection,
            QueryShape::Scalar {
                aggregation: Aggregation::Average {
                    expression: source(amount.id),
                    output_scale: 2,
                    rounding: RoundingPolicy::HalfEven,
                },
            },
        )),
        order: 1,
        deleted: false,
    })
    .await
    .unwrap();
    let balance_widget = WidgetDefinition {
        title: "Balance".into(),
        ..widget(collection, balance_id, "core.aggregate-number", 0)
    };
    a.create_widget(balance_widget.clone()).await.unwrap();

    wait_for(&a_network, &b_network, || {
        b.widget_definitions(collection).is_ok_and(|w| w.len() == 1)
    })
    .await;
    assert_eq!(
        b.widget_definitions(collection).unwrap(),
        vec![balance_widget.clone()]
    );

    for app in [&a, &b] {
        // The Balance widget renders the exact integer representation 257650 at scale two.
        let evaluations = app.evaluate_widgets(collection, 1_700_000_000_000).unwrap();
        match &evaluations[0] {
            WidgetEvaluation::Ready { result, .. } => assert_eq!(
                *result,
                QueryResult::Scalar {
                    value: TypedValue::FixedDecimal {
                        representation: 257_650,
                        scale: 2
                    },
                    value_type: ValueType::FixedDecimal { scale: 2 }
                }
            ),
            failure => panic!("balance must render exactly: {failure:?}"),
        }
        // The scale-two average stays an exact integer representation (85883 => 858.83), never f64.
        let average = app
            .execute_query_definition(collection, average_id, 1_700_000_000_000)
            .unwrap();
        assert_eq!(
            average,
            QueryResult::Scalar {
                value: TypedValue::FixedDecimal {
                    representation: 85_883,
                    scale: 2
                },
                value_type: ValueType::FixedDecimal { scale: 2 }
            }
        );
    }

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

/// 7.4a: a stale projection checkpoint rebuilds widget and query definitions from Automerge and
/// reproduces the exact pre-corruption evaluation results.
#[tokio::test]
async fn stale_checkpoint_rebuild_reproduces_widget_definitions_and_results() {
    let (directory, app, collection, scalar_id, series_id) = seeded().await;
    let number = widget(collection, scalar_id, "core.aggregate-number", 0);
    let chart = widget(collection, series_id, "core.line-chart", 1);
    let preserved = WidgetDefinition {
        widget_type: WidgetType::new("com.example.future-widget").unwrap(),
        configuration: WidgetConfiguration {
            version: 4,
            body: StructuredValue::Map(BTreeMap::from([(
                "opaque".into(),
                StructuredValue::Integer(-2_350),
            )])),
        },
        ..widget(collection, scalar_id, "core.aggregate-number", 2)
    };
    for definition in [&number, &chart, &preserved] {
        app.create_widget(definition.clone()).await.unwrap();
    }
    let definitions = app.widget_definitions(collection).unwrap();
    let results = app.evaluate_widgets(collection, 1_700_000_000_000).unwrap();
    app.shutdown().await.unwrap();

    // Marking the checkpoint stale forces a full rebuild from authority on reopen.
    let path = directory.path().join("read-model.sqlite");
    let database = Connection::open(&path).unwrap();
    database
        .execute(
            "UPDATE projection_metadata SET heads='v2:' WHERE singleton=1",
            [],
        )
        .unwrap();
    drop(database);

    let rebuilt = AppCore::open(directory.path()).await.unwrap();
    let ProjectionState::Ready { checkpoint } = rebuilt.projection_state() else {
        panic!("projection did not recover");
    };
    assert_ne!(checkpoint.heads, "v2:");
    assert_eq!(rebuilt.widget_definitions(collection).unwrap(), definitions);
    assert_eq!(
        rebuilt
            .evaluate_widgets(collection, 1_700_000_000_000)
            .unwrap(),
        results
    );
    rebuilt.shutdown().await.unwrap();
}

/// 7.4b: widget query evaluation is result-equivalent whether executed against the SQLite
/// projection or purely from the decoded schema, computed fields, and records.
#[tokio::test]
async fn pure_and_projected_execution_agree_for_widget_queries() {
    let (_directory, app, collection, scalar_id, series_id) = seeded().await;
    app.create_widget(widget(collection, scalar_id, "core.aggregate-number", 0))
        .await
        .unwrap();
    app.create_widget(widget(collection, series_id, "core.line-chart", 1))
        .await
        .unwrap();

    let schema = app.collection_schema(collection).unwrap().unwrap();
    let computed = app.computed_fields(collection).unwrap();
    let records = app
        .records(collection)
        .unwrap()
        .into_iter()
        .filter(|view| view.valid)
        .map(|view| view.record)
        .collect::<Vec<_>>();
    for definition in app.query_definitions(collection).unwrap() {
        let query = definition.query.query().unwrap();
        let projected = app
            .execute_collection_query(&query, 1_700_000_000_000)
            .unwrap();
        let pure = execute_query(&query, &schema, &computed, &records, 1_700_000_000_000).unwrap();
        assert_eq!(projected, pure);
    }
    app.shutdown().await.unwrap();
}
