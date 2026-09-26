//! CSV record files: one column per active field (schema order) then per active computed field.
//!
//! Formats are exact and locale-free: Date `YYYY-MM-DD`, DateTime RFC 3339 UTC with milliseconds
//! and `Z`, Duration raw milliseconds, FixedDecimal at the field scale, Enum by label, Boolean
//! `true`/`false`, Null as an empty cell. An unchanged export re-imports to the same values.

use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};

use super::ImportAbort;
use crate::{
    error::DomainError,
    query::{
        CalendarPolicy, ComputedFieldDefinition, EvaluationContext, TypedValue, evaluate_expression,
    },
    records::{GenericRecord, RecordId, RecordValidationError, validate_record},
    schema::{CollectionSchema, EnumOptionId, FieldDefinition, FieldType},
    values::{FieldValue, FixedDecimal},
};

/// Largest number of data rows one CSV import accepts. An import is one Automerge change, so it
/// replicates in one sync message (capped at 8 MiB by the repository protocol) and is applied in
/// one owner-loop transaction. Measured with five typed fields per row (release build): the sync
/// message stays near 57 bytes per row (10 000 rows: 0.57 MB), but applying the change grows
/// faster than linearly (5 000 rows: 17 s, 10 000 rows: 91 s) and blocks every other command
/// meanwhile. The cap bounds that pause; frame size is not the limiting factor.
pub const MAX_IMPORT_ROWS: usize = 5_000;

/// Renders the active records of one collection. Fails without output when two columns would
/// share a name, since import maps columns by exact name.
pub fn export_csv(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    now_utc_ms: i64,
) -> Result<String, DomainError> {
    let fields = schema.ordered_fields();
    let mut computed: Vec<ComputedFieldDefinition> = computed
        .iter()
        .filter(|item| item.collection_id == schema.id && !item.deleted)
        .cloned()
        .collect();
    computed.sort_by_key(|item| (item.order, item.id));
    let mut names = HashSet::new();
    let header: Vec<&str> = fields
        .iter()
        .map(|field| field.name.as_str())
        .chain(computed.iter().map(|item| item.name.as_str()))
        .collect();
    for name in &header {
        if !names.insert(*name) {
            return Err(DomainError::Invalid {
                field: "csv",
                message: format!("two columns are named \"{name}\"; rename one to export"),
            });
        }
    }
    let calendar = CalendarPolicy::default();
    let context = EvaluationContext {
        schema,
        computed_definitions: &computed,
        now_utc_ms,
        calendar: &calendar,
    };
    let expressions: Vec<_> = computed
        .iter()
        .map(|item| item.expression.expression().ok())
        .collect();
    let mut writer = ::csv::WriterBuilder::new()
        .terminator(::csv::Terminator::Any(b'\n'))
        .from_writer(Vec::new());
    writer.write_record(&header).map_err(write_error)?;
    for record in records
        .iter()
        .filter(|record| record.collection_id == schema.id && !record.deleted)
    {
        let mut row: Vec<String> = fields
            .iter()
            .map(|field| {
                record
                    .values
                    .get(&field.id)
                    .map_or_else(String::new, |value| format_field_value(field, value))
            })
            .collect();
        for expression in &expressions {
            let value = expression
                .as_ref()
                .and_then(|expression| evaluate_expression(expression, record, &context).ok());
            row.push(value.map_or_else(String::new, |value| format_typed_value(schema, &value)));
        }
        writer.write_record(&row).map_err(write_error)?;
    }
    let bytes = writer
        .into_inner()
        .map_err(|error| write_error(error.into_error()))?;
    String::from_utf8(bytes).map_err(write_error)
}

fn write_error(error: impl std::fmt::Display) -> DomainError {
    DomainError::Invalid {
        field: "csv",
        message: error.to_string(),
    }
}

/// One stored value as a cell. A value that does not match the field type, or an enum value
/// pointing at a removed option, renders empty.
#[must_use]
pub fn format_field_value(field: &FieldDefinition, value: &FieldValue) -> String {
    match (&field.field_type, value) {
        (FieldType::Text, FieldValue::Text(text)) => text.clone(),
        (FieldType::Integer, FieldValue::Integer(number))
        | (FieldType::Duration, FieldValue::Duration(number)) => number.to_string(),
        (FieldType::FixedDecimal { scale }, FieldValue::FixedDecimal(representation)) => {
            FixedDecimal::new(*representation, *scale)
                .map_or_else(|_| String::new(), |decimal| decimal.to_string())
        }
        (FieldType::Boolean, FieldValue::Boolean(flag)) => flag.to_string(),
        (FieldType::Date, FieldValue::Date(days)) => format_date(*days),
        (FieldType::DateTime, FieldValue::DateTime(ms)) => format_date_time(*ms),
        (FieldType::Enum, FieldValue::Enum(id)) => field
            .enum_options
            .iter()
            .find(|option| option.id == *id && !option.deleted)
            .map_or_else(String::new, |option| option.label.clone()),
        _ => String::new(),
    }
}

fn format_typed_value(schema: &CollectionSchema, value: &TypedValue) -> String {
    match value {
        TypedValue::Null => String::new(),
        TypedValue::Text(text) => text.clone(),
        TypedValue::Integer(number) | TypedValue::Duration(number) => number.to_string(),
        TypedValue::FixedDecimal {
            representation,
            scale,
        } => FixedDecimal::new(*representation, *scale)
            .map_or_else(|_| String::new(), |decimal| decimal.to_string()),
        TypedValue::Boolean(flag) => flag.to_string(),
        TypedValue::Date(days) => format_date(*days),
        TypedValue::DateTime(ms) => format_date_time(*ms),
        TypedValue::Enum(id) => enum_label(schema, *id).unwrap_or_default(),
    }
}

fn enum_label(schema: &CollectionSchema, id: EnumOptionId) -> Option<String> {
    schema
        .fields
        .iter()
        .flat_map(|field| &field.enum_options)
        .find(|option| option.id == id && !option.deleted)
        .map(|option| option.label.clone())
}

fn epoch() -> NaiveDate {
    NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid epoch")
}

fn format_date(days: i64) -> String {
    epoch()
        .checked_add_signed(chrono::Duration::days(days))
        .map_or_else(String::new, |date| date.format("%Y-%m-%d").to_string())
}

fn format_date_time(ms: i64) -> String {
    DateTime::<Utc>::from_timestamp_millis(ms).map_or_else(String::new, |value| {
        value.to_rfc3339_opts(SecondsFormat::Millis, true)
    })
}

/// Parses and validates every row of `text` into new records of `schema`, in file order. Nothing
/// is written; the first failure aborts with its row, column and reason.
pub fn parse_csv(
    text: &str,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> Result<Vec<GenericRecord>, ImportAbort> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut reader = ::csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(text.as_bytes());
    let header_abort = |column: &str, reason: String| ImportAbort::Csv {
        row: 0,
        column: column.into(),
        reason,
    };
    let headers = reader
        .headers()
        .map_err(|error| header_abort("", error.to_string()))?
        .iter()
        .map(|name| name.trim().to_owned())
        .collect::<Vec<_>>();
    let fields = schema.ordered_fields();
    let computed_names: HashSet<_> = computed
        .iter()
        .filter(|item| item.collection_id == schema.id && !item.deleted)
        .map(|item| item.name.as_str())
        .collect();
    let mut seen = HashSet::new();
    // Column index to target field; `None` for ignored computed columns.
    let mut columns: Vec<Option<&FieldDefinition>> = Vec::with_capacity(headers.len());
    for name in &headers {
        if !seen.insert(name.as_str()) {
            return Err(header_abort(name, "column appears more than once".into()));
        }
        if let Some(field) = fields.iter().find(|field| field.name == *name) {
            columns.push(Some(field));
        } else if computed_names.contains(name.as_str()) {
            columns.push(None);
        } else {
            return Err(header_abort(name, "no active field has this name".into()));
        }
    }
    let present: HashSet<_> = columns.iter().flatten().map(|field| field.id).collect();
    // A missing optional column stores nothing, which reads as Null (or the field default, as for
    // any new record). Storing explicit Nulls would leave stale values if the field is removed.
    if let Some(required) = fields
        .iter()
        .find(|field| field.required && !present.contains(&field.id))
    {
        return Err(header_abort(
            &required.name,
            "required field has no column".into(),
        ));
    }
    let labels: HashMap<_, _> = fields
        .iter()
        .filter(|field| matches!(field.field_type, FieldType::Enum))
        .map(|field| (field.id, label_index(field)))
        .collect();
    let mut records = Vec::new();
    for (index, row) in reader.records().enumerate() {
        let number = u32::try_from(index + 1).unwrap_or(u32::MAX);
        let row_abort = |column: &str, reason: String| ImportAbort::Csv {
            row: number,
            column: column.into(),
            reason,
        };
        if index >= MAX_IMPORT_ROWS {
            return Err(row_abort(
                "",
                format!("a CSV import holds at most {MAX_IMPORT_ROWS} rows; split the file"),
            ));
        }
        let row = row.map_err(|error| row_abort("", error.to_string()))?;
        if row.len() != headers.len() {
            return Err(row_abort(
                "",
                format!("expected {} cells, found {}", headers.len(), row.len()),
            ));
        }
        let mut values = BTreeMap::new();
        for (cell, column) in row.iter().zip(&columns) {
            let Some(field) = column else { continue };
            let value = parse_cell(field, cell.trim(), labels.get(&field.id))
                .map_err(|reason| row_abort(&field.name, reason))?;
            values.insert(field.id, value);
        }
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id: schema.id,
            values,
            stamps: BTreeMap::new(),
            deleted: false,
        };
        if let Err(error) = validate_record(&mut record, schema, true) {
            let (column, reason) = match error {
                RecordValidationError::Fields(issues) => {
                    let issue = &issues[0];
                    let column = fields
                        .iter()
                        .find(|field| field.id == issue.field)
                        .map_or_else(String::new, |field| field.name.clone());
                    (column, issue.message.clone())
                }
                other => (String::new(), other.to_string()),
            };
            return Err(row_abort(&column, reason));
        }
        records.push(record);
    }
    Ok(records)
}

/// Active option ids by exact label; a label shared by several options maps to all of them.
fn label_index(field: &FieldDefinition) -> HashMap<&str, Vec<EnumOptionId>> {
    let mut index: HashMap<&str, Vec<EnumOptionId>> = HashMap::new();
    for option in field.enum_options.iter().filter(|option| !option.deleted) {
        index
            .entry(option.label.as_str())
            .or_default()
            .push(option.id);
    }
    index
}

fn parse_cell(
    field: &FieldDefinition,
    cell: &str,
    labels: Option<&HashMap<&str, Vec<EnumOptionId>>>,
) -> Result<FieldValue, String> {
    if cell.is_empty() {
        return Ok(FieldValue::Null);
    }
    Ok(match &field.field_type {
        FieldType::Text => FieldValue::Text(cell.into()),
        FieldType::Integer => FieldValue::Integer(parse_integer(cell)?),
        FieldType::Duration => FieldValue::Duration(
            parse_integer(cell)
                .map_err(|_| format!("\"{cell}\" is not a duration in whole milliseconds"))?,
        ),
        FieldType::FixedDecimal { scale } => FieldValue::FixedDecimal(
            FixedDecimal::parse(cell, *scale)
                .map_err(|error| format!("\"{cell}\" is not a decimal: {error}"))?
                .representation(),
        ),
        FieldType::Boolean => match cell {
            "true" => FieldValue::Boolean(true),
            "false" => FieldValue::Boolean(false),
            _ => return Err(format!("\"{cell}\" is not true or false")),
        },
        FieldType::Date => {
            let date = NaiveDate::parse_from_str(cell, "%Y-%m-%d")
                .map_err(|_| format!("\"{cell}\" is not a date (YYYY-MM-DD)"))?;
            FieldValue::Date(date.signed_duration_since(epoch()).num_days())
        }
        FieldType::DateTime => {
            let value = DateTime::parse_from_rfc3339(cell).map_err(|_| {
                format!("\"{cell}\" is not an ISO-8601 date and time with Z or an offset")
            })?;
            if value.timestamp_subsec_nanos() % 1_000_000 != 0 {
                return Err(format!("\"{cell}\" is more precise than milliseconds"));
            }
            FieldValue::DateTime(value.timestamp_millis())
        }
        FieldType::Enum => {
            match labels
                .and_then(|labels| labels.get(cell))
                .map(Vec::as_slice)
            {
                Some([id]) => FieldValue::Enum(*id),
                Some([_, _, ..]) => {
                    return Err(format!("several active options are labeled \"{cell}\""));
                }
                _ => return Err(format!("no active option is labeled \"{cell}\"")),
            }
        }
    })
}

fn parse_integer(cell: &str) -> Result<i64, String> {
    if !cell
        .strip_prefix('-')
        .unwrap_or(cell)
        .bytes()
        .all(|byte| byte.is_ascii_digit())
    {
        return Err(format!("\"{cell}\" is not a whole number"));
    }
    cell.parse()
        .map_err(|_| format!("\"{cell}\" is not a whole number in range"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        query::{ComputedFieldId, Expression, FieldReference, ValueType, VersionedExpression},
        schema::{CollectionSchemaId, DisplayMetadata, EnumOption, FieldId, ValidationMetadata},
    };

    fn field(name: &str, field_type: FieldType, order: i64) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required: false,
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

    /// Integer, FixedDecimal(2), Boolean, Date, DateTime, Duration, Enum, Text in that order.
    fn typed_schema() -> CollectionSchema {
        let mut kind = field("Kind", FieldType::Enum, 6);
        kind.enum_options = vec![option("Mild", 0), option("Severe", 1)];
        CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Headache".into(),
            description: String::new(),
            fields: vec![
                field("Count", FieldType::Integer, 0),
                field("Cost", FieldType::FixedDecimal { scale: 2 }, 1),
                field("Done", FieldType::Boolean, 2),
                field("Day", FieldType::Date, 3),
                field("At", FieldType::DateTime, 4),
                field("Took", FieldType::Duration, 5),
                kind,
                field("Note", FieldType::Text, 7),
            ],
            deleted: false,
        }
    }

    fn record(schema: &CollectionSchema, values: Vec<FieldValue>) -> GenericRecord {
        GenericRecord {
            id: RecordId::new(),
            collection_id: schema.id,
            values: schema
                .ordered_fields()
                .iter()
                .map(|field| field.id)
                .zip(values)
                .collect(),
            stamps: BTreeMap::new(),
            deleted: false,
        }
    }

    fn typed_values(schema: &CollectionSchema) -> Vec<FieldValue> {
        vec![
            FieldValue::Integer(3),
            FieldValue::FixedDecimal(150),
            FieldValue::Boolean(true),
            FieldValue::Date(19_783),
            FieldValue::DateTime(1_709_288_100_000),
            FieldValue::Duration(90_000),
            FieldValue::Enum(schema.fields[6].enum_options[0].id),
            FieldValue::Null,
        ]
    }

    #[test]
    fn every_field_type_renders_exactly() {
        let schema = typed_schema();
        let csv = export_csv(&schema, &[], &[record(&schema, typed_values(&schema))], 0).unwrap();
        assert_eq!(
            csv,
            "Count,Cost,Done,Day,At,Took,Kind,Note\n\
             3,1.50,true,2024-03-01,2024-03-01T10:15:00.000Z,90000,Mild,\n"
        );
    }

    #[test]
    fn text_is_quoted_and_tombstones_are_skipped() {
        let mut schema = typed_schema();
        schema.fields[7].name = "Note, long".into();
        let mut values = typed_values(&schema);
        values[7] = FieldValue::Text("said \"hi\"\nthen left".into());
        let live = record(&schema, values);
        let mut dead = record(&schema, typed_values(&schema));
        dead.deleted = true;
        schema.fields[0].deleted = true;
        let csv = export_csv(&schema, &[], &[live, dead], 0).unwrap();
        assert_eq!(
            csv,
            "Cost,Done,Day,At,Took,Kind,\"Note, long\"\n\
             1.50,true,2024-03-01,2024-03-01T10:15:00.000Z,90000,Mild,\"said \"\"hi\"\"\nthen left\"\n"
        );
    }

    fn computed(
        schema: &CollectionSchema,
        name: &str,
        expression: Expression,
    ) -> ComputedFieldDefinition {
        ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: schema.id,
            name: name.into(),
            declared_type: ValueType::Integer,
            nullable: true,
            expression: VersionedExpression::new(expression),
            order: 0,
            deleted: false,
        }
    }

    #[test]
    fn computed_columns_follow_fields_and_render_null_as_empty() {
        let mut schema = typed_schema();
        schema.fields.truncate(1);
        let absolute = computed(
            &schema,
            "Absolute",
            Expression::Abs {
                expression: Box::new(Expression::Field {
                    field: FieldReference::Source(schema.fields[0].id),
                }),
            },
        );
        let rows = [
            record(&schema, vec![FieldValue::Integer(-4)]),
            record(&schema, vec![FieldValue::Null]),
        ];
        let csv = export_csv(&schema, &[absolute], &rows, 0).unwrap();
        assert_eq!(csv, "Count,Absolute\n-4,4\n,\n");
    }

    #[test]
    fn duplicate_column_names_abort_the_export() {
        let mut schema = typed_schema();
        schema.fields[7].name = "Count".into();
        let error = export_csv(&schema, &[], &[], 0).unwrap_err().to_string();
        assert!(error.contains("\"Count\""), "{error}");
        let schema = typed_schema();
        let clash = computed(
            &schema,
            "Note",
            Expression::Constant {
                value: TypedValue::Null,
            },
        );
        let error = export_csv(&schema, &[clash], &[], 0)
            .unwrap_err()
            .to_string();
        assert!(error.contains("\"Note\""), "{error}");
    }

    #[test]
    fn an_unchanged_export_reimports_to_the_same_values() {
        let schema = typed_schema();
        let mut values = typed_values(&schema);
        values[7] = FieldValue::Text("a, \"b\"".into());
        let original = record(&schema, values);
        let csv = export_csv(&schema, &[], std::slice::from_ref(&original), 0).unwrap();
        let parsed = parse_csv(&csv, &schema, &[]).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].values, original.values);
        assert_ne!(parsed[0].id, original.id);
    }

    #[test]
    fn cells_are_trimmed_offsets_accepted_and_missing_optional_columns_are_null() {
        let schema = typed_schema();
        let parsed = parse_csv(
            "\u{feff} Kind ,At,Count\n Severe , 2024-03-01T12:15:00+02:00 , 7 \n",
            &schema,
            &[],
        )
        .unwrap();
        let values = &parsed[0].values;
        assert_eq!(values[&schema.fields[0].id], FieldValue::Integer(7));
        assert_eq!(
            values[&schema.fields[4].id],
            FieldValue::DateTime(1_709_288_100_000)
        );
        assert_eq!(
            values[&schema.fields[6].id],
            FieldValue::Enum(schema.fields[6].enum_options[1].id)
        );
        assert!(!values.contains_key(&schema.fields[1].id));
        assert!(!values.contains_key(&schema.fields[7].id));
    }

    #[test]
    fn computed_columns_are_ignored_on_import() {
        let mut schema = typed_schema();
        schema.fields.truncate(1);
        let absolute = computed(
            &schema,
            "Absolute",
            Expression::Constant {
                value: TypedValue::Null,
            },
        );
        let parsed = parse_csv("Count,Absolute\n5,999\n", &schema, &[absolute]).unwrap();
        assert_eq!(parsed[0].values.len(), 1);
    }

    fn abort(text: &str, schema: &CollectionSchema) -> (u32, String, String) {
        match parse_csv(text, schema, &[]).unwrap_err() {
            ImportAbort::Csv {
                row,
                column,
                reason,
            } => (row, column, reason),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn every_abort_reason_names_its_row_and_column() {
        let mut schema = typed_schema();
        schema.fields[0].validation.max_integer = Some(10);
        let cases: Vec<(String, u32, &str, &str)> = vec![
            ("Count,Mood\n1,x\n".into(), 0, "Mood", "no active field"),
            ("Count,Count\n1,2\n".into(), 0, "Count", "more than once"),
            (
                "Count\n1\n2\nhigh\n".into(),
                3,
                "Count",
                "not a whole number",
            ),
            ("Count\n1.5\n".into(), 1, "Count", "not a whole number"),
            ("Count\n11\n".into(), 1, "Count", "Must be at most 10"),
            ("Cost\n1.005\n".into(), 1, "Cost", "not a decimal"),
            ("Done\nyes\n".into(), 1, "Done", "not true or false"),
            ("Day\n01/03/2024\n".into(), 1, "Day", "not a date"),
            ("At\n2024-03-01 10:15\n".into(), 1, "At", "ISO-8601"),
            (
                "At\n2024-03-01T10:15:00.0001Z\n".into(),
                1,
                "At",
                "milliseconds",
            ),
            ("Took\n1d\n".into(), 1, "Took", "milliseconds"),
            ("Kind\nMild\nAwful\n".into(), 2, "Kind", "no active option"),
            ("Count,Kind\n1\n".into(), 1, "", "expected 2 cells"),
        ];
        for (text, row, column, reason) in cases {
            let (actual_row, actual_column, actual_reason) = abort(&text, &schema);
            assert_eq!(
                (actual_row, actual_column.as_str()),
                (row, column),
                "{text}"
            );
            assert!(actual_reason.contains(reason), "{text}: {actual_reason}");
        }
    }

    #[test]
    fn ambiguous_labels_and_required_fields_abort() {
        let mut schema = typed_schema();
        schema.fields[6].enum_options[1].label = "Mild".into();
        assert_eq!(
            abort("Kind\nMild\n", &schema),
            (
                1,
                "Kind".into(),
                "several active options are labeled \"Mild\"".into()
            )
        );
        let mut schema = typed_schema();
        schema.fields[7].required = true;
        assert_eq!(
            abort("Count\n1\n", &schema),
            (0, "Note".into(), "required field has no column".into())
        );
        assert_eq!(
            abort("Count,Note\n1,hi\n2,  \n", &schema),
            (2, "Note".into(), "Required".into())
        );
    }

    #[test]
    fn removed_options_and_fields_are_not_import_targets() {
        let mut schema = typed_schema();
        schema.fields[6].enum_options[1].deleted = true;
        schema.fields[7].deleted = true;
        assert_eq!(abort("Kind\nSevere\n", &schema).0, 1);
        assert_eq!(abort("Note\nx\n", &schema).0, 0);
    }

    #[test]
    fn row_cap_is_enforced() {
        let mut schema = typed_schema();
        schema.fields.truncate(1);
        let mut text = String::from("Count\n");
        for index in 0..=MAX_IMPORT_ROWS {
            text.push_str(&format!("{index}\n"));
        }
        let (row, _, reason) = abort(&text, &schema);
        assert_eq!(row as usize, MAX_IMPORT_ROWS + 1);
        assert!(reason.contains("at most"), "{reason}");
        text.truncate(text.trim_end().rfind('\n').unwrap() + 1);
        assert_eq!(
            parse_csv(&text, &schema, &[]).unwrap().len(),
            MAX_IMPORT_ROWS
        );
    }
}
