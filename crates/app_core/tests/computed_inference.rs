use app_core::{
    AppCore, ArithmeticOperator, ComputedFieldDefinition, ComputedFieldId, CurrentBoundary,
    DisplayMetadata, Expression, FieldDefinition, FieldId, FieldReference, FieldType, InferredType,
    RoundingPolicy, TypedValue, ValidationMetadata, ValueType, VersionedExpression,
};

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

fn source(field: &FieldDefinition) -> Box<Expression> {
    Box::new(Expression::Field {
        field: FieldReference::Source(field.id),
    })
}

fn arithmetic(
    operator: ArithmeticOperator,
    left: Box<Expression>,
    right: Box<Expression>,
) -> Expression {
    Expression::Arithmetic {
        operator,
        left,
        right,
    }
}

struct Fixture {
    app: AppCore,
    collection: app_core::CollectionSchemaId,
    amount: FieldDefinition,
    rate: FieldDefinition,
    cents: FieldDefinition,
    count: FieldDefinition,
    started: FieldDefinition,
    ended: FieldDefinition,
    elapsed: FieldDefinition,
    _directory: tempfile::TempDir,
}

async fn fixture() -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Ledger".into(), String::new())
        .await
        .unwrap();
    let amount = field("Amount", FieldType::FixedDecimal { scale: 2 }, true, 0);
    let rate = field("Rate", FieldType::FixedDecimal { scale: 3 }, false, 1);
    let cents = field("Cents", FieldType::FixedDecimal { scale: 2 }, false, 2);
    let count = field("Count", FieldType::Integer, true, 3);
    let started = field("Started", FieldType::Date, true, 4);
    let ended = field("Ended", FieldType::Date, false, 5);
    let elapsed = field("Elapsed", FieldType::Duration, true, 6);
    for definition in [&amount, &rate, &cents, &count, &started, &ended, &elapsed] {
        app.add_field(collection, definition.clone()).await.unwrap();
    }
    Fixture {
        app,
        collection,
        amount,
        rate,
        cents,
        count,
        started,
        ended,
        elapsed,
        _directory: directory,
    }
}

#[tokio::test]
async fn inference_matches_commit_time_typing_rules() {
    let f = fixture().await;
    let infer = |expression: &Expression| f.app.infer_computed_expression(f.collection, expression);

    // FixedDecimal * FixedDecimal adds scales; optional operand makes result nullable.
    assert_eq!(
        infer(&arithmetic(
            ArithmeticOperator::Multiply,
            source(&f.amount),
            source(&f.rate)
        ))
        .unwrap(),
        InferredType {
            value_type: ValueType::FixedDecimal { scale: 5 },
            nullable: true,
        }
    );
    // Equal-scale addition keeps scale.
    assert_eq!(
        infer(&arithmetic(
            ArithmeticOperator::Add,
            source(&f.amount),
            source(&f.cents)
        ))
        .unwrap(),
        InferredType {
            value_type: ValueType::FixedDecimal { scale: 2 },
            nullable: true,
        }
    );
    // Mismatched scales are rejected at the root.
    let error = infer(&arithmetic(
        ArithmeticOperator::Add,
        source(&f.amount),
        source(&f.rate),
    ))
    .unwrap_err();
    assert_eq!(error.path, "$");
    assert_eq!(error.message, "arithmetic operands are incompatible");
    // Integer mixed with FixedDecimal under Arithmetic is rejected.
    let error = infer(&arithmetic(
        ArithmeticOperator::Add,
        source(&f.amount),
        source(&f.count),
    ))
    .unwrap_err();
    assert_eq!(error.path, "$");
    assert_eq!(error.message, "arithmetic operands are incompatible");
    // Divide accepts mixed numerics and yields FixedDecimal at output scale.
    assert_eq!(
        infer(&Expression::Divide {
            left: source(&f.amount),
            right: source(&f.count),
            output_scale: 4,
            rounding: RoundingPolicy::HalfEven,
        })
        .unwrap(),
        InferredType {
            value_type: ValueType::FixedDecimal { scale: 4 },
            nullable: false,
        }
    );
    // Date - Date yields Duration.
    assert_eq!(
        infer(&arithmetic(
            ArithmeticOperator::Subtract,
            source(&f.ended),
            source(&f.started)
        ))
        .unwrap(),
        InferredType {
            value_type: ValueType::Duration,
            nullable: true,
        }
    );
    // Abs over Duration keeps Duration.
    assert_eq!(
        infer(&Expression::Abs {
            expression: source(&f.elapsed),
        })
        .unwrap(),
        InferredType {
            value_type: ValueType::Duration,
            nullable: false,
        }
    );
}

#[tokio::test]
async fn inference_rejects_computed_references_and_contextual_time() {
    let f = fixture().await;
    let computed = ComputedFieldDefinition {
        id: ComputedFieldId::new(),
        collection_id: f.collection,
        name: "Magnitude".into(),
        declared_type: ValueType::FixedDecimal { scale: 2 },
        nullable: false,
        expression: VersionedExpression::new(Expression::Abs {
            expression: source(&f.amount),
        }),
        order: 0,
        deleted: false,
    };
    f.app.create_computed_field(computed.clone()).await.unwrap();

    let error = f
        .app
        .infer_computed_expression(
            f.collection,
            &arithmetic(
                ArithmeticOperator::Add,
                source(&f.amount),
                Box::new(Expression::Field {
                    field: FieldReference::Computed(computed.id),
                }),
            ),
        )
        .unwrap_err();
    assert_eq!(error.path, "$.right");
    assert_eq!(
        error.message,
        "computed fields may reference source fields only"
    );

    let error = f
        .app
        .infer_computed_expression(
            f.collection,
            &Expression::StartOfCurrent {
                boundary: CurrentBoundary::Day,
            },
        )
        .unwrap_err();
    assert_eq!(error.path, "$");
    assert_eq!(
        error.message,
        "contextual time is not allowed in computed fields"
    );
}

#[tokio::test]
async fn inference_reports_nested_error_paths_and_writes_nothing() {
    let f = fixture().await;
    // (amount * (rate + 1)) + amount: FixedDecimal + Integer constant is incompatible.
    let expression = arithmetic(
        ArithmeticOperator::Add,
        Box::new(arithmetic(
            ArithmeticOperator::Multiply,
            source(&f.amount),
            Box::new(arithmetic(
                ArithmeticOperator::Add,
                source(&f.rate),
                Box::new(Expression::Constant {
                    value: TypedValue::Integer(1),
                }),
            )),
        )),
        source(&f.amount),
    );
    let error = f
        .app
        .infer_computed_expression(f.collection, &expression)
        .unwrap_err();
    assert_eq!(error.path, "$.left.right");
    assert!(f.app.computed_fields(f.collection).unwrap().is_empty());
}
