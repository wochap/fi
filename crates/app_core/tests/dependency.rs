use app_core::AppCore;
use automerge_repo::DocumentId;

#[test]
fn app_core_can_use_repo_types() {
    fn accepts_app_core(_: Option<AppCore>) {}
    accepts_app_core(None);
    let document = DocumentId::new();

    assert!(!document.to_string().is_empty());
}
