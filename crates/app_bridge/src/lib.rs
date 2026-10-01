pub mod api;
mod frb_generated;
mod log_sink;
mod voice_worker;

#[cfg(test)]
#[path = "../build_support/git_identity.rs"]
mod git_identity;

#[cfg(test)]
mod tests {
    #[test]
    fn public_api_contains_no_infrastructure_types() {
        let api = concat!(
            include_str!("api/collections.rs"),
            include_str!("api/diagnostics.rs"),
            include_str!("api/lifecycle.rs"),
            include_str!("api/models.rs"),
            include_str!("api/pairing.rs"),
            include_str!("api/queries.rs")
        );
        for forbidden in [
            "automerge::",
            "rusqlite::Connection",
            "quinn::Connection",
            "DocHandle",
            "Repo<",
        ] {
            assert!(!api.contains(forbidden), "public API leaked {forbidden}");
        }
    }
}
