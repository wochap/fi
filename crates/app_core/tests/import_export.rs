use std::{collections::BTreeMap, time::Duration};

use app_core::{
    Aggregation, AppCore, CalendarPolicy, CollectionQuery, CollectionSchemaId, ComparisonOperator,
    ComputedFieldDefinition, ComputedFieldId, DisplayMetadata, DomainKind, EnumOption,
    EnumOptionId, Expression, FieldDefinition, FieldId, FieldReference, FieldType, FieldValue,
    ImportAbort, ImportOutcome, ProjectionState, QueryDefinition, QueryId, QueryShape, TypedValue,
    ValidationMetadata, ValueType, VersionedCollectionQuery, VersionedExpression,
    WidgetConfiguration, WidgetDefinition, WidgetEvaluation, WidgetId, WidgetLayout, WidgetType,
};
use automerge_repo::testing::MemoryTransport;

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

fn option(label: &str, order: i64) -> EnumOption {
    EnumOption {
        id: EnumOptionId::new(),
        label: label.into(),
        order,
        deleted: false,
    }
}

/// "Headache": required Integer `Intensity`, Enum `Severity` (Mild, Severe), Text `Notes`.
struct Diary {
    collection: CollectionSchemaId,
    intensity: FieldDefinition,
    severity: FieldDefinition,
    notes: FieldDefinition,
}

async fn diary(app: &AppCore) -> Diary {
    let collection = app
        .create_collection("Headache".into(), "Symptom diary".into())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, true, 0);
    let mut severity = field("Severity", FieldType::Enum, false, 1);
    severity.enum_options = vec![option("Mild", 0), option("Severe", 1)];
    let notes = field("Notes", FieldType::Text, false, 2);
    for item in [&intensity, &severity, &notes] {
        app.add_field(collection, item.clone()).await.unwrap();
    }
    Diary {
        collection,
        intensity,
        severity,
        notes,
    }
}

fn rows(count: usize, bad_row: Option<usize>) -> String {
    let mut text = String::from("Intensity,Severity,Notes\n");
    for row in 1..=count {
        let intensity = if Some(row) == bad_row {
            "high".to_owned()
        } else {
            row.to_string()
        };
        let severity = if row % 2 == 0 { "Severe" } else { "Mild" };
        text.push_str(&format!("{intensity},{severity},row {row}\n"));
    }
    text
}

async fn no_more_events(events: &mut tokio::sync::broadcast::Receiver<app_core::DataChanged>) {
    assert!(
        tokio::time::timeout(Duration::from_millis(50), events.recv())
            .await
            .is_err(),
        "exactly one DataChanged"
    );
}

#[tokio::test]
async fn csv_import_commits_once_in_file_order_and_a_bad_row_writes_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let diary = diary(&app).await;

    let ProjectionState::Ready { checkpoint: before } = app.projection_state() else {
        panic!("projection not ready");
    };
    let mut events = app.subscribe_data_changed();
    let outcome = app
        .import_collection_csv(diary.collection, rows(200, None))
        .await
        .unwrap();
    assert_eq!(
        outcome,
        ImportOutcome::Imported {
            collections: vec![],
            records: 200
        }
    );
    let event = events.recv().await.unwrap();
    assert_eq!(event.kinds, vec![DomainKind::Records]);
    assert_eq!(event.collection_ids, vec![diary.collection]);
    assert_ne!(event.checkpoint.heads, before.heads);
    no_more_events(&mut events).await;
    let ProjectionState::Ready { checkpoint: after } = app.projection_state() else {
        panic!("projection not ready");
    };
    assert_eq!(after, event.checkpoint, "one projection pass");

    let records = app.records(diary.collection).unwrap();
    assert_eq!(records.len(), 200);
    // Records list in id order; fresh UUIDv7 ids preserve file order.
    for (index, view) in records.iter().enumerate() {
        let values = &view.record.values;
        assert_eq!(
            values[&diary.intensity.id],
            FieldValue::Integer(index as i64 + 1)
        );
        assert_eq!(
            values[&diary.notes.id],
            FieldValue::Text(format!("row {}", index + 1))
        );
        let expected = &diary.severity.enum_options[usize::from((index + 1) % 2 == 0)];
        assert_eq!(values[&diary.severity.id], FieldValue::Enum(expected.id));
        assert!(view.valid);
    }

    let outcome = app
        .import_collection_csv(diary.collection, rows(120, Some(57)))
        .await
        .unwrap();
    let ImportOutcome::Aborted(ImportAbort::Csv {
        row,
        column,
        reason,
    }) = outcome
    else {
        panic!("expected a CSV abort, got {outcome:?}");
    };
    assert_eq!((row, column.as_str()), (57, "Intensity"));
    assert!(reason.contains("high"), "{reason}");
    assert_eq!(app.records(diary.collection).unwrap().len(), 200);
    no_more_events(&mut events).await;
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn csv_export_reimports_to_the_same_values() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let diary = diary(&app).await;
    app.create_record(
        diary.collection,
        BTreeMap::from([
            (diary.intensity.id, FieldValue::Integer(4)),
            (
                diary.severity.id,
                FieldValue::Enum(diary.severity.enum_options[1].id),
            ),
            (
                diary.notes.id,
                FieldValue::Text("after lunch, \"bad\"".into()),
            ),
        ]),
    )
    .await
    .unwrap();
    let csv = app.export_collection_csv(diary.collection).unwrap();
    assert_eq!(
        csv,
        "Intensity,Severity,Notes\n4,Severe,\"after lunch, \"\"bad\"\"\"\n"
    );
    let outcome = app
        .import_collection_csv(diary.collection, csv)
        .await
        .unwrap();
    assert!(matches!(
        outcome,
        ImportOutcome::Imported { records: 1, .. }
    ));
    let records = app.records(diary.collection).unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].record.values, records[1].record.values);
    app.shutdown().await.unwrap();
}

/// Adds a computed field, a query filtering on `Severe` summing it, a widget over the query, a
/// removed field, a removed option, and a removed record.
async fn with_structure(app: &AppCore, diary: &Diary) -> (QueryId, WidgetId) {
    let computed = ComputedFieldDefinition {
        id: ComputedFieldId::new(),
        collection_id: diary.collection,
        name: "Absolute".into(),
        declared_type: ValueType::Integer,
        nullable: false,
        expression: VersionedExpression::new(Expression::Abs {
            expression: Box::new(Expression::Field {
                field: FieldReference::Source(diary.intensity.id),
            }),
        }),
        order: 0,
        deleted: false,
    };
    app.create_computed_field(computed.clone()).await.unwrap();
    let query = QueryDefinition {
        id: QueryId::new(),
        collection_id: diary.collection,
        name: "Severe total".into(),
        query: VersionedCollectionQuery::new(CollectionQuery {
            collection_id: diary.collection,
            filter: Some(Expression::Compare {
                operator: ComparisonOperator::Equal,
                left: Box::new(Expression::Field {
                    field: FieldReference::Source(diary.severity.id),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Enum(diary.severity.enum_options[1].id),
                }),
            }),
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
        }),
        order: 0,
        deleted: false,
    };
    app.create_query_definition(query.clone()).await.unwrap();
    let widget = WidgetDefinition {
        id: WidgetId::new(),
        collection_id: diary.collection,
        widget_type: WidgetType::new("core.aggregate-number").unwrap(),
        query_id: query.id,
        title: "Severe total".into(),
        configuration: WidgetConfiguration::empty(),
        layout: WidgetLayout::default(),
        order: 0,
        deleted: false,
    };
    app.create_widget(widget.clone()).await.unwrap();
    let retired = field("Retired", FieldType::Text, false, 3);
    app.add_field(diary.collection, retired.clone())
        .await
        .unwrap();
    let gone = option("Gone", 2);
    app.upsert_enum_option(diary.collection, diary.severity.id, gone.clone())
        .await
        .unwrap();
    app.remove_enum_option(diary.collection, diary.severity.id, gone.id)
        .await
        .unwrap();
    app.import_collection_csv(diary.collection, rows(6, None))
        .await
        .unwrap();
    let doomed = app
        .create_record(
            diary.collection,
            BTreeMap::from([
                (diary.intensity.id, FieldValue::Integer(9)),
                (retired.id, FieldValue::Text("stale".into())),
            ]),
        )
        .await
        .unwrap();
    app.delete_record(doomed, diary.collection).await.unwrap();
    app.remove_field(diary.collection, retired.id)
        .await
        .unwrap();
    (query.id, widget.id)
}

#[tokio::test]
async fn json_export_omits_tombstones_and_stamps() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let diary = diary(&app).await;
    let (query, widget) = with_structure(&app, &diary).await;
    let schema = app.collection_schema(diary.collection).unwrap().unwrap();
    let retired = schema.fields.iter().find(|item| item.deleted).unwrap();
    let gone = schema.fields[1]
        .enum_options
        .iter()
        .find(|item| item.deleted)
        .unwrap();

    let json = app.export_collections_json(vec![diary.collection]).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(value["format"], "fi-collection");
    assert_eq!(value["version"], 1);
    let entry = &value["collections"][0];
    assert_eq!(entry["schema"]["name"], "Headache");
    assert_eq!(entry["records"].as_array().unwrap().len(), 6);
    assert_eq!(entry["widgets"][0]["query_id"], query.to_string());
    assert_eq!(entry["widgets"][0]["id"], widget.to_string());
    assert!(!json.contains(&retired.id.to_string()));
    assert!(!json.contains(&gone.id.to_string()));
    assert!(!json.contains("stale"));
    assert!(!json.contains("stamps"));
    assert!(!json.contains("physical_time_ms"));

    let other = app
        .create_collection("Sleep".into(), String::new())
        .await
        .unwrap();
    let removed = app
        .create_collection("Removed".into(), String::new())
        .await
        .unwrap();
    app.delete_collection(removed).await.unwrap();
    let all: serde_json::Value = serde_json::from_str(&app.export_all_json().unwrap()).unwrap();
    let names: Vec<_> = all["collections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["schema"]["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, vec!["Headache", "Sleep"]);
    assert_eq!(all["collections"][1]["schema"]["id"], other.to_string());
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn importing_an_export_twice_creates_two_independent_working_copies() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let diary = diary(&app).await;
    let (query, widget) = with_structure(&app, &diary).await;
    let source_schema = app.collection_schema(diary.collection).unwrap().unwrap();
    let source_records = app.records(diary.collection).unwrap();
    let source_result = app
        .execute_query_definition(diary.collection, query, 0)
        .unwrap();
    let json = app.export_collections_json(vec![diary.collection]).unwrap();

    let mut imported = Vec::new();
    for _ in 0..2 {
        let mut events = app.subscribe_data_changed();
        let outcome = app.import_collections_json(json.clone()).await.unwrap();
        let ImportOutcome::Imported {
            collections,
            records,
        } = outcome
        else {
            panic!("expected an import, got {outcome:?}");
        };
        assert_eq!((collections.len(), records), (1, 6));
        let event = events.recv().await.unwrap();
        assert_eq!(event.collection_ids, collections);
        no_more_events(&mut events).await;
        imported.push(collections[0]);
    }
    assert_ne!(imported[0], imported[1]);
    let listed: Vec<_> = app.collections().unwrap();
    assert_eq!(listed.len(), 3);
    assert!(listed.iter().all(|item| item.name == "Headache"));

    let mut seen = std::collections::HashSet::new();
    for collection in &imported {
        let schema = app.collection_schema(*collection).unwrap().unwrap();
        assert_eq!(schema.description, "Symptom diary");
        assert_eq!(
            schema
                .fields
                .iter()
                .map(|item| item.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Intensity", "Severity", "Notes"]
        );
        let queries = app.query_definitions(*collection).unwrap();
        let widgets = app.widget_definitions(*collection).unwrap();
        let records = app.records(*collection).unwrap();
        assert_eq!(records.len(), 6);
        assert_eq!(widgets[0].query_id, queries[0].id);
        assert!(app.widget_diagnostics(widgets[0].id).unwrap().is_empty());
        let ids = std::iter::once(collection.to_string())
            .chain(schema.fields.iter().map(|item| item.id.to_string()))
            .chain(
                schema
                    .fields
                    .iter()
                    .flat_map(|item| &item.enum_options)
                    .map(|item| item.id.to_string()),
            )
            .chain(queries.iter().map(|item| item.id.to_string()))
            .chain(widgets.iter().map(|item| item.id.to_string()))
            .chain(records.iter().map(|item| item.record.id.to_string()));
        for id in ids {
            assert!(!json.contains(&id), "{id} reused from the export");
            assert!(seen.insert(id.clone()), "{id} shared between imports");
        }
        // The widget -> query -> field chain works over the imported records.
        assert_eq!(
            app.execute_query_definition(*collection, queries[0].id, 0)
                .unwrap(),
            source_result
        );
        assert!(matches!(
            app.evaluate_widget(*collection, widgets[0].id, 0).unwrap(),
            WidgetEvaluation::Ready { .. }
        ));
    }
    assert_eq!(
        app.collection_schema(diary.collection).unwrap().unwrap(),
        source_schema
    );
    assert_eq!(app.records(diary.collection).unwrap(), source_records);
    assert_eq!(
        app.widget_definitions(diary.collection).unwrap()[0].id,
        widget
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn rejected_json_imports_create_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let diary = diary(&app).await;
    with_structure(&app, &diary).await;
    let json = app.export_collections_json(vec![diary.collection]).unwrap();
    let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
    let before = app.collections().unwrap();
    let mut events = app.subscribe_data_changed();

    value["version"] = 2.into();
    let outcome = app
        .import_collections_json(value.to_string())
        .await
        .unwrap();
    assert!(
        matches!(&outcome, ImportOutcome::Aborted(ImportAbort::Json { collection_index: None, reason, .. })
            if reason.contains("version 2")),
        "{outcome:?}"
    );

    value["version"] = 1.into();
    let good = value["collections"][0].clone();
    let mut broken = good.clone();
    broken["records"][0]["values"][diary.intensity.id.to_string()] =
        serde_json::json!({"kind": "text", "value": "high"});
    value["collections"] = serde_json::json!([good.clone(), good, broken]);
    let outcome = app
        .import_collections_json(value.to_string())
        .await
        .unwrap();
    assert!(
        matches!(&outcome, ImportOutcome::Aborted(ImportAbort::Json { collection_index: Some(2), item, .. })
            if item == "record 1"),
        "{outcome:?}"
    );
    assert_eq!(app.collections().unwrap(), before);
    no_more_events(&mut events).await;
    app.shutdown().await.unwrap();
}

async fn drive_memory(a: &MemoryTransport, b: &MemoryTransport) {
    for _ in 0..100 {
        tokio::task::yield_now().await;
        a.deliver_all().await;
        b.deliver_all().await;
    }
}

#[tokio::test]
async fn a_peer_sees_an_import_whole() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let (a_network, b_network) = MemoryTransport::pair("import-a", "import-b", 256);
    let a = AppCore::open_with_transport(a_dir.path(), a_network.clone())
        .await
        .unwrap();
    let b = AppCore::open_with_transport(b_dir.path(), b_network.clone())
        .await
        .unwrap();
    let root = a.create_new_dataset().await.unwrap();
    let diary = diary(&a).await;
    a_network.connect().await;
    drive_memory(&a_network, &b_network).await;
    b.join_existing(root).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if matches!(
                b.lifecycle_state(),
                app_core::ApplicationState::Ready { .. }
            ) && b
                .collection_schema(diary.collection)
                .is_ok_and(|s| s.is_some())
            {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();

    let outcome = a
        .import_collection_csv(diary.collection, rows(500, None))
        .await
        .unwrap();
    assert!(matches!(
        outcome,
        ImportOutcome::Imported { records: 500, .. }
    ));
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let seen = b.records(diary.collection).unwrap().len();
            assert!(
                seen == 0 || seen == 500,
                "peer observed part of the import: {seen} of 500"
            );
            if seen == 500 {
                break;
            }
            drive_memory(&a_network, &b_network).await;
        }
    })
    .await
    .unwrap();
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}
