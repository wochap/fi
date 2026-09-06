use app_core::AppCore;
use automerge_repo::DocumentId;

#[test]
fn app_core_can_use_repo_types() {
    let _app = AppCore;
    let document = DocumentId::new();

    assert!(!document.to_string().is_empty());
}
