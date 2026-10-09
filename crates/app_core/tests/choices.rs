//! Choices (EnumSet) fields end to end: schema rules, record values, conversions, projection,
//! queries, CSV and JSON.

use std::collections::BTreeMap;

use app_core::{
    Aggregation, AppCore, AppError, CalendarPolicy, CategoryPoint, CollectionQuery,
    CollectionSchemaId, ComparisonOperator, DisplayMetadata, DomainError, EnumOption, EnumOptionId,
    Expression, FieldDefinition, FieldId, FieldReference, FieldType, FieldValue, ImportAbort,
    ImportOutcome, QueryDefinition, QueryId, QueryResult, QueryShape, SetOperator, TypedValue,
    ValidationMetadata, VersionedCollectionQuery, execute_query,
};

fn field(name: &str, field_type: FieldType, required: bool, order: i64) -> FieldDefinition {
    FieldDefinition {
        allow_options_from_records: false,
        id: FieldId::new(),
        name: name.into(),
        field_type,
        required,
        default: None,
        default_relative_days: None,
        validation: ValidationMetadata::default(),
        display: DisplayMetadata::default(),
        order,
        deleted: false,
        enum_options: vec![],
    }
}

fn option(label: &str, order: i64) -> EnumOption {
    EnumOption {
        merged_into: None,
        id: EnumOptionId::new(),
        label: label.into(),
        order,
        deleted: false,
    }
}

/// "Tasks": FixedDecimal `amount` and Choices `tags` with options urgent, work, food (in that
/// order).
struct Tasks {
    collection: CollectionSchemaId,
    amount: FieldDefinition,
    tags: FieldDefinition,
    urgent: EnumOptionId,
    work: EnumOptionId,
    food: EnumOptionId,
}

async fn tasks(app: &AppCore) -> Tasks {
    let collection = app
        .create_collection("Tasks".into(), String::new())
        .await
        .unwrap();
    let amount = field("amount", FieldType::FixedDecimal { scale: 2 }, false, 0);
    let mut tags = field("tags", FieldType::EnumSet, false, 1);
    tags.enum_options = vec![option("urgent", 0), option("work", 1), option("food", 2)];
    tags.default = Some(FieldValue::EnumSet(vec![tags.enum_options[1].id]));
    app.add_field(collection, amount.clone()).await.unwrap();
    app.add_field(collection, tags.clone()).await.unwrap();
    Tasks {
        collection,
        urgent: tags.enum_options[0].id,
        work: tags.enum_options[1].id,
        food: tags.enum_options[2].id,
        amount,
        tags,
    }
}

async fn record(app: &AppCore, tasks: &Tasks, amount: i64, tags: FieldValue) -> app_core::RecordId {
    app.create_record(
        tasks.collection,
        BTreeMap::from([
            (tasks.amount.id, FieldValue::FixedDecimal(amount)),
            (tasks.tags.id, tags),
        ]),
    )
    .await
    .unwrap()
}

fn value(app: &AppCore, id: app_core::RecordId, field: FieldId) -> Option<FieldValue> {
    app.record(id)
        .unwrap()
        .unwrap()
        .record
        .values
        .get(&field)
        .cloned()
}

fn invalid_field(error: AppError) -> &'static str {
    match error {
        AppError::Domain(DomainError::Invalid { field, .. }) => field,
        other => panic!("expected a validation error, got {other:?}"),
    }
}

#[tokio::test]
async fn a_choices_field_round_trips_and_rejects_semicolons_and_bad_defaults() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let schema = app.collection_schema(tasks.collection).unwrap().unwrap();
    assert_eq!(schema.fields[1], tasks.tags);

    let mut semicolon = option("food; drinks", 3);
    let error = app
        .upsert_enum_option(tasks.collection, tasks.tags.id, semicolon.clone())
        .await
        .unwrap_err();
    assert_eq!(invalid_field(error), "enum_option_label");
    semicolon.id = tasks.food;
    let error = app
        .upsert_enum_option(tasks.collection, tasks.tags.id, semicolon)
        .await
        .unwrap_err();
    assert_eq!(invalid_field(error), "enum_option_label");

    let mut other = field("other", FieldType::EnumSet, false, 2);
    other.enum_options = vec![option("a", 0)];
    for default in [
        FieldValue::EnumSet(vec![]),
        FieldValue::EnumSet(vec![tasks.work]),
    ] {
        other.default = Some(default);
        let error = app
            .add_field(tasks.collection, other.clone())
            .await
            .unwrap_err();
        assert_eq!(invalid_field(error), "default");
    }
    app.remove_enum_option(tasks.collection, tasks.tags.id, tasks.urgent)
        .await
        .unwrap();
    let mut updated = app
        .collection_schema(tasks.collection)
        .unwrap()
        .unwrap()
        .fields[1]
        .clone();
    updated.default = Some(FieldValue::EnumSet(vec![tasks.urgent]));
    let error = app
        .update_field(tasks.collection, updated)
        .await
        .unwrap_err();
    assert_eq!(invalid_field(error), "default");
    // The unchanged schema still reads the same.
    assert_eq!(
        app.collection_schema(tasks.collection)
            .unwrap()
            .unwrap()
            .fields[1]
            .default,
        Some(FieldValue::EnumSet(vec![tasks.work]))
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn record_sets_read_in_option_order_and_empty_reads_as_null() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let id = record(
        &app,
        &tasks,
        100,
        FieldValue::EnumSet(vec![tasks.work, tasks.urgent, tasks.work]),
    )
    .await;
    assert_eq!(
        value(&app, id, tasks.tags.id),
        Some(FieldValue::EnumSet(vec![tasks.urgent, tasks.work]))
    );
    // The default applies to a new record without the field.
    let defaulted = app
        .create_record(tasks.collection, BTreeMap::new())
        .await
        .unwrap();
    assert_eq!(
        value(&app, defaulted, tasks.tags.id),
        Some(FieldValue::EnumSet(vec![tasks.work]))
    );

    app.update_record_field(
        id,
        tasks.collection,
        tasks.tags.id,
        FieldValue::EnumSet(vec![]),
    )
    .await
    .unwrap();
    assert_eq!(value(&app, id, tasks.tags.id), Some(FieldValue::Null));
    assert!(app.record(id).unwrap().unwrap().valid);

    // Required: an empty set is a missing-required issue.
    let mut required = app
        .collection_schema(tasks.collection)
        .unwrap()
        .unwrap()
        .fields[1]
        .clone();
    required.required = true;
    app.update_field(tasks.collection, required).await.unwrap();
    let error = app
        .update_record_field(
            id,
            tasks.collection,
            tasks.tags.id,
            FieldValue::EnumSet(vec![]),
        )
        .await
        .unwrap_err();
    let AppError::Domain(DomainError::InvalidMany(issues)) = error else {
        panic!("expected record issues, got {error:?}");
    };
    assert_eq!(issues[0].code, app_core::IssueCode::Required);

    // Survives a restart.
    let before = app.records(tasks.collection).unwrap();
    app.shutdown().await.unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(app.records(tasks.collection).unwrap(), before);
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn a_removed_member_is_kept_but_never_newly_picked() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let held = record(
        &app,
        &tasks,
        1,
        FieldValue::EnumSet(vec![tasks.work, tasks.urgent]),
    )
    .await;
    let other = record(&app, &tasks, 2, FieldValue::EnumSet(vec![tasks.work])).await;
    app.remove_enum_option(tasks.collection, tasks.tags.id, tasks.urgent)
        .await
        .unwrap();
    let view = app.record(held).unwrap().unwrap();
    assert!(view.valid, "{:?}", view.diagnostics);
    assert_eq!(
        view.record.values[&tasks.tags.id],
        FieldValue::EnumSet(vec![tasks.urgent, tasks.work])
    );
    // Keeping it while adding an active option is fine; adding it elsewhere is not.
    app.update_record_field(
        held,
        tasks.collection,
        tasks.tags.id,
        FieldValue::EnumSet(vec![tasks.urgent, tasks.work, tasks.food]),
    )
    .await
    .unwrap();
    assert!(
        app.update_record_field(
            other,
            tasks.collection,
            tasks.tags.id,
            FieldValue::EnumSet(vec![tasks.urgent, tasks.work]),
        )
        .await
        .is_err()
    );
    assert!(
        app.create_record(
            tasks.collection,
            BTreeMap::from([(tasks.tags.id, FieldValue::EnumSet(vec![tasks.urgent]))]),
        )
        .await
        .is_err()
    );
    // Unpicking it removes it for good.
    app.update_record_field(
        held,
        tasks.collection,
        tasks.tags.id,
        FieldValue::EnumSet(vec![tasks.work]),
    )
    .await
    .unwrap();
    assert!(
        app.update_record_field(
            held,
            tasks.collection,
            tasks.tags.id,
            FieldValue::EnumSet(vec![tasks.urgent, tasks.work]),
        )
        .await
        .is_err()
    );
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn choice_and_choices_convert_both_ways() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Spending".into(), String::new())
        .await
        .unwrap();
    let mut category = field("category", FieldType::Enum, false, 0);
    category.enum_options = vec![option("food", 0), option("transport", 1)];
    let (food, transport) = (category.enum_options[0].id, category.enum_options[1].id);
    category.default = Some(FieldValue::Enum(food));
    app.add_field(collection, category.clone()).await.unwrap();
    let mut ids = Vec::new();
    for held in [
        FieldValue::Enum(food),
        FieldValue::Enum(transport),
        FieldValue::Null,
    ] {
        ids.push(
            app.create_record(collection, BTreeMap::from([(category.id, held)]))
                .await
                .unwrap(),
        );
    }

    // A `;` in an active label blocks Choice → Choices.
    let mut semicolon = category.clone();
    semicolon.field_type = FieldType::EnumSet;
    semicolon.enum_options[1].label = "bus; train".into();
    app.update_field(collection, category.clone())
        .await
        .unwrap();
    app.upsert_enum_option(collection, category.id, semicolon.enum_options[1].clone())
        .await
        .unwrap();
    let error = app.update_field(collection, semicolon).await.unwrap_err();
    assert_eq!(invalid_field(error), "enum_option_label");
    app.upsert_enum_option(collection, category.id, category.enum_options[1].clone())
        .await
        .unwrap();

    // Choice → Choices: schema only, values and the default read as sets of one.
    let mut choices = category.clone();
    choices.field_type = FieldType::EnumSet;
    app.update_field(collection, choices.clone()).await.unwrap();
    let schema = app.collection_schema(collection).unwrap().unwrap();
    assert_eq!(
        schema.fields[0].default,
        Some(FieldValue::EnumSet(vec![food]))
    );
    assert_eq!(
        ids.iter()
            .map(|id| value(&app, *id, category.id))
            .collect::<Vec<_>>(),
        vec![
            Some(FieldValue::EnumSet(vec![food])),
            Some(FieldValue::EnumSet(vec![transport])),
            Some(FieldValue::Null),
        ]
    );
    // A later write adds to the converted value.
    app.update_record_field(
        ids[0],
        collection,
        category.id,
        FieldValue::EnumSet(vec![food, transport]),
    )
    .await
    .unwrap();
    app.update_record_field(
        ids[1],
        collection,
        category.id,
        FieldValue::EnumSet(vec![food, transport]),
    )
    .await
    .unwrap();

    // Choices → Choice is blocked while records hold two or more options.
    let mut back = schema.fields[0].clone();
    back.field_type = FieldType::Enum;
    let error = app
        .update_field(collection, back.clone())
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        AppError::Domain(DomainError::ChoicesConversionBlocked { field, records: 2 })
            if field == category.id
    ));
    assert_eq!(
        app.collection_schema(collection).unwrap().unwrap().fields[0].field_type,
        FieldType::EnumSet
    );

    // Allowed once every record holds at most one option.
    app.update_record_field(
        ids[0],
        collection,
        category.id,
        FieldValue::EnumSet(vec![transport]),
    )
    .await
    .unwrap();
    app.update_record_field(ids[1], collection, category.id, FieldValue::Null)
        .await
        .unwrap();
    app.update_field(collection, back).await.unwrap();
    let schema = app.collection_schema(collection).unwrap().unwrap();
    assert_eq!(schema.fields[0].field_type, FieldType::Enum);
    assert_eq!(schema.fields[0].default, Some(FieldValue::Enum(food)));
    assert_eq!(
        ids.iter()
            .map(|id| value(&app, *id, category.id))
            .collect::<Vec<_>>(),
        vec![
            Some(FieldValue::Enum(transport)),
            Some(FieldValue::Null),
            Some(FieldValue::Null),
        ]
    );
    for id in &ids {
        assert!(app.record(*id).unwrap().unwrap().valid);
    }
    // Other type changes of a populated field stay refused.
    let mut text = schema.fields[0].clone();
    text.field_type = FieldType::Text;
    text.enum_options.clear();
    text.default = None;
    assert_eq!(
        invalid_field(app.update_field(collection, text).await.unwrap_err()),
        "field_type"
    );
    app.shutdown().await.unwrap();
}

fn tasks_query(tasks: &Tasks, filter: Option<Expression>, shape: QueryShape) -> CollectionQuery {
    CollectionQuery {
        collection_id: tasks.collection,
        filter,
        grouping: None,
        shape,
        sorting: vec![],
        limit: None,
        calendar: CalendarPolicy::default(),
    }
}

fn tags_field(tasks: &Tasks) -> Expression {
    Expression::Field {
        field: FieldReference::Source(tasks.tags.id),
    }
}

fn has(tasks: &Tasks, operator: SetOperator, options: Vec<EnumOptionId>) -> Expression {
    Expression::SetCompare {
        operator,
        left: Box::new(tags_field(tasks)),
        right: Box::new(Expression::Constant {
            value: TypedValue::EnumOptionSet {
                field: tasks.tags.id,
                options,
            },
        }),
    }
}

#[tokio::test]
async fn set_filters_and_grouping_agree_between_pure_and_projected_evaluation() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let both = record(
        &app,
        &tasks,
        1250,
        FieldValue::EnumSet(vec![tasks.work, tasks.urgent]),
    )
    .await;
    let work = record(&app, &tasks, 500, FieldValue::EnumSet(vec![tasks.work])).await;
    let empty = record(&app, &tasks, 100, FieldValue::Null).await;
    let schema = app.collection_schema(tasks.collection).unwrap().unwrap();
    let records: Vec<_> = app
        .records(tasks.collection)
        .unwrap()
        .into_iter()
        .map(|view| view.record)
        .collect();
    let ids = |result: QueryResult| -> Vec<app_core::RecordId> {
        let QueryResult::RecordSet { records } = result else {
            panic!("expected records");
        };
        let mut ids: Vec<_> = records.into_iter().map(|record| record.id).collect();
        ids.sort();
        ids
    };
    let sorted = |mut ids: Vec<app_core::RecordId>| {
        ids.sort();
        ids
    };
    let record_set = QueryShape::RecordSet {
        fields: vec![FieldReference::Source(tasks.tags.id)],
    };
    for (filter, expected) in [
        (
            has(&tasks, SetOperator::HasAnyOf, vec![tasks.work, tasks.food]),
            vec![both, work],
        ),
        (
            has(
                &tasks,
                SetOperator::HasAllOf,
                vec![tasks.work, tasks.urgent],
            ),
            vec![both],
        ),
        (
            has(&tasks, SetOperator::HasNoneOf, vec![tasks.urgent]),
            vec![work, empty],
        ),
        (
            Expression::IsNull {
                expression: Box::new(tags_field(&tasks)),
            },
            vec![empty],
        ),
        (
            Expression::IsNotNull {
                expression: Box::new(tags_field(&tasks)),
            },
            vec![both, work],
        ),
    ] {
        let query = tasks_query(&tasks, Some(filter), record_set.clone());
        let pure = execute_query(&query, &schema, &[], &records, 0).unwrap();
        assert_eq!(app.execute_collection_query(&query, 0).unwrap(), pure);
        assert_eq!(ids(pure), sorted(expected));
    }
    // Record values come back as option sets in option order.
    let query = tasks_query(
        &tasks,
        Some(has(&tasks, SetOperator::HasAllOf, vec![tasks.urgent])),
        record_set,
    );
    let QueryResult::RecordSet { records: rows } = app.execute_collection_query(&query, 0).unwrap()
    else {
        panic!("expected records");
    };
    assert_eq!(
        rows[0].values[0].1,
        TypedValue::EnumOptionSet {
            field: tasks.tags.id,
            options: vec![tasks.urgent, tasks.work],
        }
    );

    // Grouping fans each record out to every member; the empty set counts in the Null group.
    let grouped = tasks_query(
        &tasks,
        None,
        QueryShape::CategorySeries {
            category: tags_field(&tasks),
            aggregation: Aggregation::Sum {
                expression: Expression::Field {
                    field: FieldReference::Source(tasks.amount.id),
                },
            },
        },
    );
    let pure = execute_query(&grouped, &schema, &[], &records, 0).unwrap();
    assert_eq!(app.execute_collection_query(&grouped, 0).unwrap(), pure);
    let QueryResult::CategorySeries {
        points,
        category_type,
        ..
    } = pure
    else {
        panic!("expected a category series");
    };
    assert_eq!(category_type, app_core::ValueType::Enum);
    let decimal = |representation| TypedValue::FixedDecimal {
        representation,
        scale: 2,
    };
    assert_eq!(
        points,
        vec![
            CategoryPoint {
                category: TypedValue::Enum(tasks.urgent),
                value: decimal(1250),
            },
            CategoryPoint {
                category: TypedValue::Enum(tasks.work),
                value: decimal(1750),
            },
            CategoryPoint {
                category: TypedValue::Null,
                value: decimal(100),
            },
        ]
    );

    // Equality on a set, a constant of another field and sorting by a set are rejected.
    let rejected = [
        tasks_query(
            &tasks,
            Some(Expression::Compare {
                operator: ComparisonOperator::Equal,
                left: Box::new(tags_field(&tasks)),
                right: Box::new(Expression::Constant {
                    value: TypedValue::EnumOptionSet {
                        field: tasks.tags.id,
                        options: vec![tasks.work],
                    },
                }),
            }),
            QueryShape::RecordSet { fields: vec![] },
        ),
        tasks_query(
            &tasks,
            Some(Expression::SetCompare {
                operator: SetOperator::HasAnyOf,
                left: Box::new(tags_field(&tasks)),
                right: Box::new(Expression::Constant {
                    value: TypedValue::EnumOptionSet {
                        field: tasks.amount.id,
                        options: vec![tasks.work],
                    },
                }),
            }),
            QueryShape::RecordSet { fields: vec![] },
        ),
        tasks_query(
            &tasks,
            Some(has(&tasks, SetOperator::HasAnyOf, vec![])),
            QueryShape::RecordSet { fields: vec![] },
        ),
        CollectionQuery {
            sorting: vec![app_core::SortClause {
                expression: tags_field(&tasks),
                direction: app_core::SortDirection::Ascending,
                null_order: app_core::NullOrder::Last,
            }],
            ..tasks_query(&tasks, None, QueryShape::RecordSet { fields: vec![] })
        },
    ];
    for query in rejected {
        assert!(app_core::validate_query(&query, &schema, &[]).is_err());
        assert!(
            app.create_query_definition(QueryDefinition {
                id: QueryId::new(),
                collection_id: tasks.collection,
                name: "bad".into(),
                query: VersionedCollectionQuery::new(query),
                order: 0,
                deleted: false,
            })
            .await
            .is_err()
        );
    }
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn clone_and_json_round_trip_remap_sets() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let query_id = QueryId::new();
    app.create_query_definition(QueryDefinition {
        id: query_id,
        collection_id: tasks.collection,
        name: "urgent".into(),
        query: VersionedCollectionQuery::new(tasks_query(
            &tasks,
            Some(has(&tasks, SetOperator::HasAnyOf, vec![tasks.urgent])),
            QueryShape::RecordSet {
                fields: vec![FieldReference::Source(tasks.tags.id)],
            },
        )),
        order: 0,
        deleted: false,
    })
    .await
    .unwrap();
    record(
        &app,
        &tasks,
        1,
        FieldValue::EnumSet(vec![tasks.work, tasks.urgent]),
    )
    .await;

    // Structure clone: default and constant name only the cloned options.
    let clone = app
        .clone_collection(tasks.collection, "Tasks copy".into())
        .await
        .unwrap();
    let schema = app.collection_schema(clone).unwrap().unwrap();
    let cloned = schema
        .fields
        .iter()
        .find(|item| item.name == "tags")
        .unwrap();
    let option = |label: &str| {
        cloned
            .enum_options
            .iter()
            .find(|item| item.label == label)
            .unwrap()
            .id
    };
    assert_eq!(
        cloned.default,
        Some(FieldValue::EnumSet(vec![option("work")]))
    );
    let definition = app
        .query_definitions(clone)
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    let filter = definition.query.query().unwrap().filter.unwrap();
    let Expression::SetCompare { right, .. } = filter else {
        panic!("expected a set filter");
    };
    assert_eq!(
        *right,
        Expression::Constant {
            value: TypedValue::EnumOptionSet {
                field: cloned.id,
                options: vec![option("urgent")],
            },
        }
    );
    app.execute_query_definition(clone, definition.id, 0)
        .unwrap();

    // JSON: the record's set is remapped to the imported options.
    let json = app.export_collections_json(vec![tasks.collection]).unwrap();
    let ImportOutcome::Imported { collections, .. } =
        app.import_collections_json(json.clone()).await.unwrap()
    else {
        panic!("expected an import");
    };
    let schema = app.collection_schema(collections[0]).unwrap().unwrap();
    let imported = schema
        .fields
        .iter()
        .find(|item| item.name == "tags")
        .unwrap();
    let labels = |ids: &[EnumOptionId]| {
        ids.iter()
            .map(|id| {
                imported
                    .enum_options
                    .iter()
                    .find(|item| item.id == *id)
                    .unwrap()
                    .label
                    .clone()
            })
            .collect::<Vec<_>>()
    };
    let records = app.records(collections[0]).unwrap();
    let Some(FieldValue::EnumSet(ids)) = records[0].record.values.get(&imported.id) else {
        panic!("expected a set");
    };
    assert_eq!(labels(ids), vec!["urgent", "work"]);

    // An unknown option id aborts and writes nothing.
    let count = app.collections().unwrap().len();
    let mut bogus: serde_json::Value = serde_json::from_str(&json).unwrap();
    bogus["collections"][0]["records"][0]["values"][tasks.tags.id.to_string()]["value"][0] =
        serde_json::Value::String(EnumOptionId::new().to_string());
    let outcome = app
        .import_collections_json(bogus.to_string())
        .await
        .unwrap();
    assert!(matches!(
        outcome,
        ImportOutcome::Aborted(ImportAbort::Json { .. })
    ));
    assert_eq!(app.collections().unwrap().len(), count);
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn csv_writes_labels_in_option_order_and_parses_them_back() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    record(
        &app,
        &tasks,
        150,
        FieldValue::EnumSet(vec![tasks.work, tasks.urgent]),
    )
    .await;
    let csv = app.export_collection_csv(tasks.collection).unwrap();
    assert_eq!(csv, "amount,tags\n1.50,urgent; work\n");

    let outcome = app
        .import_collection_csv(
            tasks.collection,
            "amount,tags\n2.00,work;  urgent ;work\n3.00,\n".into(),
        )
        .await
        .unwrap();
    assert!(matches!(
        outcome,
        ImportOutcome::Imported { records: 2, .. }
    ));
    let values: Vec<_> = app
        .records(tasks.collection)
        .unwrap()
        .into_iter()
        .map(|view| view.record.values.get(&tasks.tags.id).cloned())
        .collect();
    assert!(values.contains(&Some(FieldValue::Null)));
    assert_eq!(
        values
            .iter()
            .filter(|value| **value == Some(FieldValue::EnumSet(vec![tasks.urgent, tasks.work])))
            .count(),
        2
    );

    let outcome = app
        .import_collection_csv(tasks.collection, "amount,tags\n1.00,work; travel\n".into())
        .await
        .unwrap();
    let ImportOutcome::Aborted(ImportAbort::Csv { row, column, .. }) = outcome else {
        panic!("expected an abort, got {outcome:?}");
    };
    assert_eq!((row, column.as_str()), (1, "tags"));
    app.shutdown().await.unwrap();
}

#[tokio::test]
async fn record_form_options_validate_save_and_merge_through_the_app() {
    use app_core::{DraftValue, PendingOption};
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let tasks = tasks(&app).await;
    let mut tags = tasks.tags.clone();
    tags.allow_options_from_records = true;
    app.update_field(tasks.collection, tags.clone())
        .await
        .unwrap();
    let values = BTreeMap::from([(
        tags.id,
        DraftValue::Choices {
            options: vec![tasks.food],
            pending: vec!["pending:1".into()],
        },
    )]);
    let pending = |label: &str| {
        vec![PendingOption {
            key: "pending:1".into(),
            field_id: tags.id,
            label: label.into(),
        }]
    };
    assert!(
        app.validate_record_draft_with_options(
            tasks.collection,
            None,
            values.clone(),
            pending("coffee")
        )
        .unwrap()
        .is_empty()
    );
    let issues = app
        .validate_record_draft_with_options(tasks.collection, None, values.clone(), pending(""))
        .unwrap();
    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0].fields, vec![tags.id.to_string()]);
    let schema_before = app.collection_schema(tasks.collection).unwrap().unwrap();
    assert_eq!(
        schema_before,
        app.collection_schema(tasks.collection).unwrap().unwrap()
    );

    let id = app
        .save_record_draft(tasks.collection, None, values, pending("coffee"))
        .await
        .unwrap();
    let schema = app.collection_schema(tasks.collection).unwrap().unwrap();
    let coffee = schema.fields[1]
        .enum_options
        .iter()
        .find(|option| option.label == "coffee")
        .unwrap()
        .id;
    assert_eq!(
        value(&app, id, tags.id),
        Some(FieldValue::enum_set([tasks.food, coffee]))
    );

    app.merge_enum_options(tasks.collection, tags.id, tasks.food, vec![coffee])
        .await
        .unwrap();
    assert_eq!(
        value(&app, id, tags.id),
        Some(FieldValue::EnumSet(vec![tasks.food]))
    );
    let schema = app.collection_schema(tasks.collection).unwrap().unwrap();
    let merged = schema.fields[1]
        .enum_options
        .iter()
        .find(|option| option.id == coffee)
        .unwrap();
    assert_eq!(merged.merged_into, Some(tasks.food));
}
