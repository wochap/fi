pub mod api;
mod frb_generated;

#[cfg(test)]
mod tests {
    #[test]
    fn public_api_contains_no_infrastructure_types() {
        let api = concat!(
            include_str!("api/finance.rs"),
            include_str!("api/lifecycle.rs"),
            include_str!("api/models.rs")
        );
        for forbidden in ["Automerge", "rusqlite", "Connection", "DocHandle", "Repo<"] {
            assert!(!api.contains(forbidden), "public API leaked {forbidden}");
        }
    }
}
