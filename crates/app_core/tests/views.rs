//! Collection views: two-device synchronization, concurrent edits and projection rebuild.

use std::{collections::BTreeMap, sync::Arc, time::Duration};

use app_core::{
    AppCore, CollectionSchemaId, DisplayMetadata, Expression, FieldDefinition, FieldId,
    FieldReference, FieldType, FieldValue, NullOrder, SortClause, SortDirection,
    ValidationMetadata, ViewBody, ViewId, ViewListing,
};
use automerge_repo::testing::MemoryTransport;

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

async fn drive_memory(a: &MemoryTransport, b: &MemoryTransport) {
    for _ in 0..100 {
        tokio::task::yield_now().await;
        a.deliver_all().await;
        b.deliver_all().await;
    }
}

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

type Pair = (
    tempfile::TempDir,
    tempfile::TempDir,
    Arc<MemoryTransport>,
    Arc<MemoryTransport>,
    AppCore,
    AppCore,
);

async fn joined_pair(a_name: &str, b_name: &str) -> Pair {
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

fn by_field(id: FieldId, direction: SortDirection) -> ViewBody {
    ViewBody {
        filter: None,
        sorting: vec![SortClause {
            expression: Expression::Field {
                field: FieldReference::Source(id),
            },
            direction,
            null_order: NullOrder::Last,
        }],
        grouping: None,
    }
}

/// Collection with an integer field and three records, synchronized to B.
async fn shared_collection(
    a: &AppCore,
    b: &AppCore,
    a_network: &MemoryTransport,
    b_network: &MemoryTransport,
) -> (CollectionSchemaId, FieldId) {
    let collection = a
        .create_collection("Pains".into(), String::new())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, 0);
    a.add_field(collection, intensity.clone()).await.unwrap();
    for value in [3, 7, 5] {
        a.create_record(
            collection,
            BTreeMap::from([(intensity.id, FieldValue::Integer(value))]),
        )
        .await
        .unwrap();
    }
    wait_for(a_network, b_network, || {
        b.list_views(collection, NOW)
            .is_ok_and(|views| views.first().and_then(|all| all.count) == Some(3))
    })
    .await;
    (collection, intensity.id)
}

fn saved(app: &AppCore, collection: CollectionSchemaId) -> Vec<ViewListing> {
    app.list_views(collection, NOW)
        .unwrap()
        .into_iter()
        .skip(1)
        .collect()
}

fn names(app: &AppCore, collection: CollectionSchemaId) -> Vec<(Option<ViewId>, String)> {
    saved(app, collection)
        .into_iter()
        .map(|view| (view.id, view.name))
        .collect()
}

#[tokio::test]
async fn create_rename_reorder_and_delete_synchronize_across_devices() {
    let (_ad, _bd, an, bn, a, b) = joined_pair("views-a", "views-b").await;
    let (collection, intensity) = shared_collection(&a, &b, &an, &bn).await;

    let first = ViewId::new();
    let second = ViewId::new();
    a.create_view(
        collection,
        first,
        "Strong".into(),
        by_field(intensity, SortDirection::Descending),
    )
    .await
    .unwrap();
    a.create_view(
        collection,
        second,
        "Mild".into(),
        by_field(intensity, SortDirection::Ascending),
    )
    .await
    .unwrap();
    wait_for(&an, &bn, || saved(&b, collection).len() == 2).await;
    assert_eq!(saved(&a, collection), saved(&b, collection));
    assert_eq!(saved(&b, collection)[0].count, Some(3));

    b.rename_view(collection, first, "Worst".into())
        .await
        .unwrap();
    wait_for(&an, &bn, || {
        saved(&a, collection)
            .first()
            .is_some_and(|view| view.name == "Worst")
    })
    .await;

    a.reorder_views(collection, vec![second, first])
        .await
        .unwrap();
    wait_for(&an, &bn, || {
        saved(&b, collection).first().and_then(|view| view.id) == Some(second)
    })
    .await;
    assert_eq!(names(&a, collection), names(&b, collection));

    b.remove_view(collection, second).await.unwrap();
    wait_for(&an, &bn, || saved(&a, collection).len() == 1).await;
    assert_eq!(saved(&a, collection), saved(&b, collection));
    assert_eq!(saved(&a, collection)[0].id, Some(first));
    // Records are never touched by view commands.
    assert_eq!(a.list_views(collection, NOW).unwrap()[0].count, Some(3));

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn concurrent_rename_and_body_edit_both_survive() {
    let (_ad, _bd, an, bn, a, b) = joined_pair("rename-a", "rename-b").await;
    let (collection, intensity) = shared_collection(&a, &b, &an, &bn).await;
    let id = ViewId::new();
    a.create_view(collection, id, "Strong".into(), ViewBody::all())
        .await
        .unwrap();
    wait_for(&an, &bn, || saved(&b, collection).len() == 1).await;

    // Neither device sees the other's change until the transports are driven again.
    a.rename_view(collection, id, "Worst".into()).await.unwrap();
    let body = by_field(intensity, SortDirection::Descending);
    b.update_view_body(collection, id, body.clone())
        .await
        .unwrap();
    wait_for(&an, &bn, || {
        [&a, &b].iter().all(|app| {
            saved(app, collection)
                .first()
                .is_some_and(|view| view.name == "Worst" && view.body.as_ref() == Some(&body))
        })
    })
    .await;
    assert_eq!(saved(&a, collection), saved(&b, collection));

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn concurrent_delete_and_edit_stays_deleted() {
    let (_ad, _bd, an, bn, a, b) = joined_pair("delete-a", "delete-b").await;
    let (collection, intensity) = shared_collection(&a, &b, &an, &bn).await;
    let id = ViewId::new();
    a.create_view(collection, id, "Strong".into(), ViewBody::all())
        .await
        .unwrap();
    wait_for(&an, &bn, || saved(&b, collection).len() == 1).await;

    a.remove_view(collection, id).await.unwrap();
    b.rename_view(collection, id, "Worst".into()).await.unwrap();
    b.update_view_body(
        collection,
        id,
        by_field(intensity, SortDirection::Ascending),
    )
    .await
    .unwrap();
    wait_for(&an, &bn, || {
        saved(&a, collection).is_empty() && saved(&b, collection).is_empty()
    })
    .await;
    drive_memory(&an, &bn).await;
    assert!(saved(&a, collection).is_empty());
    assert!(saved(&b, collection).is_empty());

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn same_name_created_offline_on_both_devices_yields_two_views() {
    let (_ad, _bd, an, bn, a, b) = joined_pair("dup-a", "dup-b").await;
    let (collection, intensity) = shared_collection(&a, &b, &an, &bn).await;

    let on_a = ViewId::new();
    let on_b = ViewId::new();
    a.create_view(collection, on_a, "Headaches".into(), ViewBody::all())
        .await
        .unwrap();
    b.create_view(
        collection,
        on_b,
        "Headaches".into(),
        by_field(intensity, SortDirection::Ascending),
    )
    .await
    .unwrap();
    wait_for(&an, &bn, || {
        saved(&a, collection).len() == 2 && saved(&b, collection).len() == 2
    })
    .await;
    let merged = names(&a, collection);
    assert_eq!(merged, names(&b, collection));
    assert!(merged.iter().all(|(_, name)| name == "Headaches"));
    let ids: Vec<_> = merged.iter().filter_map(|(id, _)| *id).collect();
    assert!(ids.contains(&on_a) && ids.contains(&on_b));

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn projection_rebuild_reproduces_the_view_listing() {
    let directory = tempfile::tempdir().unwrap();
    let app = AppCore::open(directory.path()).await.unwrap();
    app.create_new_dataset().await.unwrap();
    let collection = app
        .create_collection("Pains".into(), String::new())
        .await
        .unwrap();
    let intensity = field("Intensity", FieldType::Integer, 0);
    app.add_field(collection, intensity.clone()).await.unwrap();
    for value in [3, 7] {
        app.create_record(
            collection,
            BTreeMap::from([(intensity.id, FieldValue::Integer(value))]),
        )
        .await
        .unwrap();
    }
    let kept = ViewId::new();
    let removed = ViewId::new();
    app.create_view(
        collection,
        kept,
        "Strong".into(),
        by_field(intensity.id, SortDirection::Descending),
    )
    .await
    .unwrap();
    app.create_view(collection, removed, "Gone".into(), ViewBody::all())
        .await
        .unwrap();
    app.rename_view(collection, kept, "Worst".into())
        .await
        .unwrap();
    app.remove_view(collection, removed).await.unwrap();
    let before = app.list_views(collection, NOW).unwrap();
    let result = app.execute_view(collection, Some(kept), NOW).unwrap();
    app.shutdown().await.unwrap();

    std::fs::remove_file(directory.path().join("read-model.sqlite")).unwrap();
    let reopened = AppCore::open(directory.path()).await.unwrap();
    assert_eq!(reopened.list_views(collection, NOW).unwrap(), before);
    assert_eq!(
        reopened.execute_view(collection, Some(kept), NOW).unwrap(),
        result
    );
    reopened.shutdown().await.unwrap();
}
