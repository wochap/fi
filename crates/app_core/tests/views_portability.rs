//! Saved views travel with Clone collection and JSON export/import: broken views are left out and
//! named, degraded views carry their effective sort.

use std::collections::BTreeMap;

use app_core::{
    AppCore, CollectionSchemaId, ComparisonOperator, DisplayMetadata, EnumOption, EnumOptionId,
    Expression, FieldDefinition, FieldId, FieldReference, FieldType, FieldValue, GroupPeriod,
    ImportOutcome, NullOrder, SortClause, SortDirection, TypedValue, ValidationMetadata, ViewBody,
    ViewGrouping, ViewId,
};

const NOW: i64 = 1_800_000_000_000;

fn field(name: &str, field_type: FieldType, order: i64) -> FieldDefinition {
    FieldDefinition {
        allow_options_from_records: false,
        id: FieldId::new(),
        name: name.into(),
        field_type,
        required: false,
        default: None,
        default_relative_days: None,
        validation: ValidationMetadata::default(),
        display: DisplayMetadata::default(),
        order,
        enum_options: vec![],
        deleted: false,
    }
}

fn sort(id: FieldId, direction: SortDirection) -> SortClause {
    SortClause {
        expression: Expression::Field {
            field: FieldReference::Source(id),
        },
        direction,
        null_order: NullOrder::Last,
    }
}

/// "pains": Choice `type` (headache, stomach), Integer `level`, DateTime `start at`, two
/// records, and the views "Headaches" (filter + month grouping), "Recent" (sorts by level then
/// start at) and "Old scale" (filters on level).
struct Pains {
    collection: CollectionSchemaId,
    kind: FieldDefinition,
    level: FieldDefinition,
    start: FieldDefinition,
}

async fn pains(app: &AppCore) -> Pains {
    let collection = app
        .create_collection("pains".into(), String::new())
        .await
        .unwrap();
    let mut kind = field("type", FieldType::Enum, 0);
    kind.enum_options = vec![
        EnumOption {
            merged_into: None,
            id: EnumOptionId::new(),
            label: "headache".into(),
            order: 0,
            deleted: false,
        },
        EnumOption {
            merged_into: None,
            id: EnumOptionId::new(),
            label: "stomach".into(),
            order: 1,
            deleted: false,
        },
    ];
    let level = field("level", FieldType::Integer, 1);
    let start = field("start at", FieldType::DateTime, 2);
    for item in [&kind, &level, &start] {
        app.add_field(collection, item.clone()).await.unwrap();
    }
    for (option, at) in [(0, 1_790_000_000_000_i64), (1, 1_791_000_000_000)] {
        app.create_record(
            collection,
            BTreeMap::from([
                (kind.id, FieldValue::Enum(kind.enum_options[option].id)),
                (level.id, FieldValue::Integer(3)),
                (start.id, FieldValue::DateTime(at)),
            ]),
        )
        .await
        .unwrap();
    }
    let headaches = ViewBody {
        filter: Some(Expression::Compare {
            operator: ComparisonOperator::Equal,
            left: Box::new(Expression::Field {
                field: FieldReference::Source(kind.id),
            }),
            right: Box::new(Expression::Constant {
                value: TypedValue::Enum(kind.enum_options[0].id),
            }),
        }),
        sorting: vec![sort(start.id, SortDirection::Descending)],
        grouping: Some(ViewGrouping {
            field: start.id,
            period: Some(GroupPeriod::Month),
        }),
    };
    let recent = ViewBody {
        filter: None,
        sorting: vec![
            sort(level.id, SortDirection::Descending),
            sort(start.id, SortDirection::Descending),
        ],
        grouping: None,
    };
    let old_scale = ViewBody {
        filter: Some(Expression::IsNotNull {
            expression: Box::new(Expression::Field {
                field: FieldReference::Source(level.id),
            }),
        }),
        sorting: vec![],
        grouping: None,
    };
    for (name, body) in [
        ("Headaches", headaches),
        ("Recent", recent),
        ("Old scale", old_scale),
    ] {
        app.create_view(collection, ViewId::new(), name.into(), body)
            .await
            .unwrap();
    }
    Pains {
        collection,
        kind,
        level,
        start,
    }
}

async fn open() -> (tempfile::TempDir, AppCore) {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    (directory, app)
}

fn saved_names(app: &AppCore, collection: CollectionSchemaId) -> Vec<String> {
    app.list_views(collection, NOW)
        .unwrap()
        .into_iter()
        .skip(1)
        .map(|view| view.name)
        .collect()
}

#[tokio::test]
async fn clone_copies_views_and_skips_broken_ones() {
    let (_directory, app) = open().await;
    let source = pains(&app).await;
    // Deleting `level` breaks "Old scale" and degrades "Recent".
    app.remove_field(source.collection, source.level.id)
        .await
        .unwrap();
    let outcome = app
        .clone_collection(source.collection, "Migraine".into())
        .await
        .unwrap();
    assert_eq!(outcome.skipped_views, vec!["Old scale".to_string()]);
    assert_eq!(saved_names(&app, outcome.id), vec!["Headaches", "Recent"]);
    let views = app.list_views(outcome.id, NOW).unwrap();
    let schema = app.collection_schema(outcome.id).unwrap().unwrap();
    let start = schema.fields.iter().find(|f| f.name == "start at").unwrap();
    let kind = schema.fields.iter().find(|f| f.name == "type").unwrap();
    assert_ne!(start.id, source.start.id);
    for view in &views[1..] {
        assert!(view.broken.is_none(), "{:?}", view.broken);
        let result = app.execute_view(outcome.id, view.id, NOW).unwrap();
        assert_eq!(result.count, 0);
    }
    let recent = views[2].body.clone().unwrap();
    assert_eq!(
        recent.sorting,
        vec![sort(start.id, SortDirection::Descending)]
    );
    let headaches = views[1].body.clone().unwrap();
    assert_eq!(headaches.grouping.unwrap().field, start.id);
    let filter = serde_json::to_string(&headaches.filter).unwrap();
    assert!(filter.contains(&kind.enum_options[0].id.to_string()));
    assert!(!filter.contains(&source.kind.id.to_string()));
}

#[tokio::test]
async fn export_omits_broken_views_and_round_trips_degraded_ones() {
    let (_directory, app) = open().await;
    let source = pains(&app).await;
    app.remove_field(source.collection, source.level.id)
        .await
        .unwrap();
    let export = app
        .export_collections_json(vec![source.collection])
        .unwrap();
    assert_eq!(export.records, 2);
    assert_eq!(export.views_written, 2);
    assert_eq!(export.views_omitted, vec!["Old scale".to_string()]);
    let value: serde_json::Value = serde_json::from_str(&export.text).unwrap();
    assert_eq!(value["version"], 1);
    let names: Vec<_> = value["collections"][0]["views"]
        .as_array()
        .unwrap()
        .iter()
        .map(|view| view["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(names, vec!["Headaches", "Recent"]);
    let ImportOutcome::Imported { collections, .. } =
        app.import_collections_json(export.text).await.unwrap()
    else {
        panic!("expected an import");
    };
    let imported = collections[0];
    assert_eq!(saved_names(&app, imported), vec!["Headaches", "Recent"]);
    let views = app.list_views(imported, NOW).unwrap();
    let schema = app.collection_schema(imported).unwrap().unwrap();
    let start = schema.fields.iter().find(|f| f.name == "start at").unwrap();
    assert_eq!(
        views[2].body.clone().unwrap().sorting,
        vec![sort(start.id, SortDirection::Descending)]
    );
    let headaches = app.execute_view(imported, views[1].id, NOW).unwrap();
    assert_eq!(headaches.count, 1);
    assert_eq!(headaches.groups.len(), 1);
}

#[tokio::test]
async fn import_without_views_creates_no_saved_views() {
    let (_directory, app) = open().await;
    let source = pains(&app).await;
    let text = app
        .export_collections_json(vec![source.collection])
        .unwrap()
        .text;
    let mut value: serde_json::Value = serde_json::from_str(&text).unwrap();
    value["collections"][0]
        .as_object_mut()
        .unwrap()
        .remove("views");
    let ImportOutcome::Imported { collections, .. } = app
        .import_collections_json(value.to_string())
        .await
        .unwrap()
    else {
        panic!("expected an import");
    };
    assert!(saved_names(&app, collections[0]).is_empty());
    assert_eq!(
        app.list_views(collections[0], NOW).unwrap()[0].count,
        Some(2)
    );
}

#[tokio::test]
async fn import_with_an_invalid_view_aborts() {
    let (_directory, app) = open().await;
    let source = pains(&app).await;
    let text = app
        .export_collections_json(vec![source.collection])
        .unwrap()
        .text;
    let mut value: serde_json::Value = serde_json::from_str(&text).unwrap();
    // Group by the Integer field: references resolve but the body does not validate.
    value["collections"][0]["views"][0]["body"]["body"]["grouping"] =
        serde_json::json!({ "field": source.level.id.to_string() });
    let before = app.collections().unwrap().len();
    let outcome = app
        .import_collections_json(value.to_string())
        .await
        .unwrap();
    assert!(matches!(outcome, ImportOutcome::Aborted(_)), "{outcome:?}");
    assert_eq!(app.collections().unwrap().len(), before);
}
