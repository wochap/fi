//! Collection views: list, edit and execute saved views and the implicit All view.

use app_core::{ALL_VIEW_ID, ViewBody, ViewId, ViewListing, ViewResult};

use crate::api::{
    lifecycle::core,
    models::{BridgeError, ExpressionDto, NullOrderDto, SortClauseDto, SortDirectionDto},
};

/// A view body: an optional Boolean filter and up to three sort clauses.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewBodyDto {
    pub filter: Option<ExpressionDto>,
    pub sorting: Vec<SortClauseDto>,
}

/// One entry of a collection's view listing. All comes first with id `"all"`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewDto {
    pub id: String,
    pub name: String,
    /// `None` when the stored body cannot be read (unsupported version).
    pub body: Option<ViewBodyDto>,
    pub order: i64,
    /// `None` for a broken view.
    pub count: Option<u32>,
    /// Why the view is broken; `None` when it executes.
    pub broken: Option<String>,
    /// The stored sort minus clauses that no longer resolve; created desc when none is left.
    pub effective_sort: Vec<SortClauseDto>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewResultDto {
    pub ids: Vec<String>,
    pub count: u32,
}

pub async fn list_views(
    collection_id: String,
    now_utc_ms: i64,
) -> Result<Vec<ViewDto>, BridgeError> {
    let views = core()
        .await?
        .list_views(collection_id.parse().map_err(validation)?, now_utc_ms)?;
    Ok(views.into_iter().map(Into::into).collect())
}

/// Creates a saved view after the last one and returns its id.
pub async fn create_view(
    collection_id: String,
    name: String,
    body: ViewBodyDto,
) -> Result<String, BridgeError> {
    let id = ViewId::new();
    core()
        .await?
        .create_view(
            collection_id.parse().map_err(validation)?,
            id,
            name,
            body.try_into()?,
        )
        .await?;
    Ok(id.to_string())
}

pub async fn update_view(
    collection_id: String,
    view_id: String,
    body: ViewBodyDto,
) -> Result<(), BridgeError> {
    core()
        .await?
        .update_view_body(
            collection_id.parse().map_err(validation)?,
            saved_id(&view_id)?,
            body.try_into()?,
        )
        .await
        .map_err(Into::into)
}

pub async fn rename_view(
    collection_id: String,
    view_id: String,
    name: String,
) -> Result<(), BridgeError> {
    core()
        .await?
        .rename_view(
            collection_id.parse().map_err(validation)?,
            saved_id(&view_id)?,
            name,
        )
        .await
        .map_err(Into::into)
}

/// Stores the order of the saved views; `"all"` is always first and is skipped.
pub async fn reorder_views(collection_id: String, ids: Vec<String>) -> Result<(), BridgeError> {
    core()
        .await?
        .reorder_views(collection_id.parse().map_err(validation)?, saved_ids(&ids)?)
        .await
        .map_err(Into::into)
}

pub async fn remove_view(collection_id: String, view_id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .remove_view(
            collection_id.parse().map_err(validation)?,
            saved_id(&view_id)?,
        )
        .await
        .map_err(Into::into)
}

/// Executes a saved view, or All for `"all"`.
pub async fn execute_view(
    collection_id: String,
    view_id: String,
    now_utc_ms: i64,
) -> Result<ViewResultDto, BridgeError> {
    let id = if view_id == ALL_VIEW_ID {
        None
    } else {
        Some(view_id.parse().map_err(validation)?)
    };
    core()
        .await?
        .execute_view(collection_id.parse().map_err(validation)?, id, now_utc_ms)
        .map(Into::into)
        .map_err(Into::into)
}

/// Executes an unsaved body; nothing is written.
pub async fn execute_view_body(
    collection_id: String,
    body: ViewBodyDto,
    now_utc_ms: i64,
) -> Result<ViewResultDto, BridgeError> {
    core()
        .await?
        .execute_view_body(
            collection_id.parse().map_err(validation)?,
            &body.try_into()?,
            now_utc_ms,
        )
        .map(Into::into)
        .map_err(Into::into)
}

fn validation(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::validation("id", error.to_string())
}

/// A stored view id; All is never stored, so it is not a command target.
fn saved_id(id: &str) -> Result<ViewId, BridgeError> {
    if id == ALL_VIEW_ID {
        return Err(BridgeError::validation("id", "All can't be changed."));
    }
    id.parse().map_err(validation)
}

fn saved_ids(ids: &[String]) -> Result<Vec<ViewId>, BridgeError> {
    ids.iter()
        .filter(|id| id.as_str() != ALL_VIEW_ID)
        .map(|id| id.parse().map_err(validation))
        .collect()
}

fn sort_from_dto(value: SortClauseDto) -> Result<app_core::SortClause, BridgeError> {
    Ok(app_core::SortClause {
        expression: value.expression.try_into()?,
        direction: match value.direction {
            SortDirectionDto::Ascending => app_core::SortDirection::Ascending,
            SortDirectionDto::Descending => app_core::SortDirection::Descending,
        },
        // Views always keep empty values last, whatever the DTO carries.
        null_order: app_core::NullOrder::Last,
    })
}

fn sort_to_dto(value: app_core::SortClause) -> SortClauseDto {
    SortClauseDto {
        expression: value.expression.into(),
        direction: match value.direction {
            app_core::SortDirection::Ascending => SortDirectionDto::Ascending,
            app_core::SortDirection::Descending => SortDirectionDto::Descending,
        },
        null_order: match value.null_order {
            app_core::NullOrder::First => NullOrderDto::First,
            app_core::NullOrder::Last => NullOrderDto::Last,
        },
    }
}

impl TryFrom<ViewBodyDto> for ViewBody {
    type Error = BridgeError;
    fn try_from(value: ViewBodyDto) -> Result<Self, Self::Error> {
        Ok(Self {
            filter: value.filter.map(TryInto::try_into).transpose()?,
            sorting: value
                .sorting
                .into_iter()
                .map(sort_from_dto)
                .collect::<Result<_, _>>()?,
            grouping: None,
        })
    }
}

impl From<ViewBody> for ViewBodyDto {
    fn from(value: ViewBody) -> Self {
        Self {
            filter: value.filter.map(Into::into),
            sorting: value.sorting.into_iter().map(sort_to_dto).collect(),
        }
    }
}

impl From<ViewListing> for ViewDto {
    fn from(value: ViewListing) -> Self {
        Self {
            id: value
                .id
                .map_or_else(|| ALL_VIEW_ID.to_owned(), |id| id.to_string()),
            name: value.name,
            body: value.body.map(Into::into),
            order: value.order,
            count: value.count,
            broken: value.broken,
            effective_sort: value.effective_sort.into_iter().map(sort_to_dto).collect(),
        }
    }
}

impl From<ViewResult> for ViewResultDto {
    fn from(value: ViewResult) -> Self {
        Self {
            ids: value.ids.into_iter().map(|id| id.to_string()).collect(),
            count: value.count,
        }
    }
}

#[cfg(test)]
mod tests {
    use app_core::{
        AppError, CollectionSchema, CollectionSchemaId, Expression, NullOrder, SortClause,
        SortDirection, validate_view,
    };

    use super::*;
    use crate::api::models::BridgeErrorKind;

    fn created(direction: SortDirection, null_order: NullOrder) -> SortClause {
        SortClause {
            expression: Expression::RecordCreatedAt,
            direction,
            null_order,
        }
    }

    #[test]
    fn all_comes_first_under_its_reserved_id_and_is_never_a_stored_target() {
        let saved = ViewId::new();
        let listing = vec![
            ViewListing {
                id: None,
                name: "All".into(),
                body: Some(ViewBody::all()),
                order: i64::MIN,
                effective_sort: ViewBody::all().sorting,
                broken: None,
                count: Some(2),
            },
            ViewListing {
                id: Some(saved),
                name: "Strong".into(),
                body: None,
                order: 0,
                effective_sort: ViewBody::all().sorting,
                broken: Some("unsupported view version 9".into()),
                count: None,
            },
        ];
        let dtos: Vec<ViewDto> = listing.into_iter().map(Into::into).collect();
        assert_eq!(dtos[0].id, ALL_VIEW_ID);
        assert_eq!(dtos[0].count, Some(2));
        assert_eq!(dtos[1].id, saved.to_string());
        assert!(dtos[1].broken.is_some() && dtos[1].count.is_none());

        // All is not stored: it is skipped from a reorder and refused as a command target.
        assert_eq!(
            saved_ids(&[ALL_VIEW_ID.into(), saved.to_string()]).unwrap(),
            vec![saved]
        );
        let error = saved_id(ALL_VIEW_ID).unwrap_err();
        assert_eq!(error.kind, BridgeErrorKind::Validation);
    }

    #[test]
    fn null_order_is_normalised_to_last() {
        let dto = ViewBodyDto {
            filter: None,
            sorting: vec![
                sort_to_dto(created(SortDirection::Ascending, NullOrder::First)),
                sort_to_dto(created(SortDirection::Descending, NullOrder::First)),
            ],
        };
        assert!(
            dto.sorting
                .iter()
                .all(|s| s.null_order == NullOrderDto::First)
        );
        let body = ViewBody::try_from(dto).unwrap();
        assert!(body.sorting.iter().all(|s| s.null_order == NullOrder::Last));
        assert_eq!(body.sorting[1].direction, SortDirection::Descending);
    }

    #[test]
    fn validation_errors_carry_the_view_codes() {
        let schema = CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Pains".into(),
            description: String::new(),
            fields: vec![],
            deleted: false,
        };
        let body = ViewBody {
            filter: Some(Expression::RecordCreatedAt),
            sorting: vec![created(SortDirection::Ascending, NullOrder::Last); 4],
            grouping: Some(app_core::ViewGrouping(serde_json::json!({}))),
        };
        let error: BridgeError =
            AppError::Domain(validate_view("", &body, &schema, &[]).unwrap_err()).into();
        assert_eq!(error.kind, BridgeErrorKind::Validation);
        let codes: Vec<_> = error.issues.iter().map(|i| i.code.as_str()).collect();
        for code in [
            "length",
            "view_filter_type",
            "view_sort_limit",
            "view_grouping",
        ] {
            assert!(codes.contains(&code), "{code} missing from {codes:?}");
        }
    }

    #[test]
    fn broken_views_cross_as_a_typed_validation_error() {
        let error: BridgeError = AppError::Domain(app_core::DomainError::BrokenView {
            diagnostic: "Type was deleted".into(),
        })
        .into();
        assert_eq!(error.kind, BridgeErrorKind::Validation);
        assert_eq!(error.issues[0].code, "view_broken");
    }
}
