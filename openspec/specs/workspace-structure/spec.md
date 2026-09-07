## Purpose

TBD: Define the Rust workspace layout, crate dependency boundary, documentation ownership, reserved Flutter application location, and workspace-wide verification expectations.

## Requirements

### Requirement: Virtual Rust workspace
The repository root SHALL be a virtual Cargo workspace using resolver version 2 with `crates/automerge_repo`, `crates/app_core`, and `crates/app_bridge` as explicit members, and workspace commands SHALL operate on all members from the repository root.

#### Scenario: Cargo discovers all members
- **WHEN** Cargo metadata is requested from the repository root
- **THEN** the workspace contains the `automerge-repo`, `app-core`, and FRB adapter packages and the root is not an application package

### Requirement: Independent generic Repo crate
The existing Automerge Repo implementation SHALL reside in `crates/automerge_repo` as package `automerge-repo` and library `automerge_repo`, and SHALL retain ownership of generic document lifecycle, persistence ports, synchronization, peer and document state, wire protocol, network transport abstraction, bootstrap primitives, and generic testing support.

#### Scenario: Repo implementation is moved intact
- **WHEN** the workspace structure is inspected after migration
- **THEN** the existing source modules and integration-test suites are located beneath `crates/automerge_repo` with only path, package metadata, documentation ownership, and crate-name references changed as required by the move

#### Scenario: Infrastructure remains reusable
- **WHEN** the `automerge-repo` manifest and source are inspected
- **THEN** they contain no dependency on `app_core`, Flutter, FRB, finance domain concepts, SQLite read models, mDNS, Quinn, Android, Wayland, pairing UI, authentication, or Tailscale

### Requirement: One-way application dependency
The `app-core` package SHALL declare a normal local workspace dependency on `automerge-repo`, while `automerge-repo` MUST NOT depend on `app-core` directly or transitively through a workspace member.

#### Scenario: Application smoke test uses Repo dependency
- **WHEN** the `app-core` smoke test is compiled and executed
- **THEN** it constructs the minimal `AppCore` scaffold and uses a public `automerge_repo` type through the declared local dependency

#### Scenario: Dependency graph has no reverse edge
- **WHEN** the workspace manifests and Cargo metadata are inspected
- **THEN** the dependency direction is `app_core` to `automerge_repo` to `automerge`, with no edge from `automerge_repo` to `app_core`

### Requirement: Minimal application scaffold
The `app_core` crate SHALL own application/domain behavior independently of Flutter, while the dedicated bridge crate SHALL own only FRB-facing DTOs, error translation, event forwarding, native-library initialization, and generated glue integration. Neither crate MUST move application-specific concerns into `automerge_repo`.

#### Scenario: Application boundary remains independent
- **WHEN** the Rust sources are inspected
- **THEN** finance commands, queries, projections, and application state live in `app_core`; FRB integration lives in the bridge crate; and generic Repo behavior remains in `automerge_repo`

#### Scenario: Dependency graph has no reverse UI edge
- **WHEN** Cargo metadata is inspected
- **THEN** the bridge depends on `app_core`, `app_core` depends on `automerge_repo`, and neither lower layer depends on the bridge or Flutter

#### Scenario: Application scope is implemented
- **WHEN** the `app_core` source is inspected
- **THEN** it contains the finance domain, CQRS-lite command/query paths, SQLite projection/rebuild, application bootstrap storage, and typed event implementation while identity, trust, pairing, discovery, Quinn, mDNS, and platform UI remain deferred

#### Scenario: Generic Repo remains independent
- **WHEN** the workspace dependency graph and `automerge_repo` sources are inspected
- **THEN** dependency direction remains `app_core` to `automerge_repo` to `automerge` with no finance or SQLite read-model concern in `automerge_repo`

### Requirement: Preserved Repo behavior and tests
All existing Repo tests SHALL remain present as tests of `automerge_repo` and SHALL pass unchanged in behavioral intent, including coverage for persistence, synchronization, concurrent offline edits, multiple-document synchronization, root bootstrap, change notifications, reconnect behavior, lifecycle, ports, and crash-safe Stage 2 semantics.

#### Scenario: Complete workspace suite passes
- **WHEN** `cargo test --workspace` is run from the repository root
- **THEN** every moved Repo test, crate documentation test, and the new application dependency smoke test passes

#### Scenario: Existing suites remain identifiable
- **WHEN** `crates/automerge_repo/tests` is inspected
- **THEN** the existing `acceptance.rs`, `ports.rs`, `repository.rs`, and `stage2.rs` suites are present

### Requirement: Repository-level artifacts and documentation
Repository-wide OpenSpec artifacts, development instructions, workspace lockfile, and workspace overview SHALL remain at the repository root, while Repo-specific documentation SHALL live with `automerge_repo` and all live commands and path references SHALL match the new layout.

#### Scenario: Documentation ownership is clear
- **WHEN** the root and member documentation are inspected
- **THEN** the root README explains the workspace and root commands, the Repo crate README documents its API, and neither contains stale live references to the old root package layout or `fi_repo` import name

#### Scenario: Historical artifacts remain historical
- **WHEN** archived OpenSpec changes are inspected
- **THEN** their references to the layout and package identity used when those changes were completed remain unmodified

### Requirement: Reserved Flutter application location
The repository SHALL contain a generated Flutter application in `flutter_app` targeting Android and Linux desktop, with presentation and generated FRB-facing Dart code located there and no web target or JavaScript runtime required by the application.

#### Scenario: Native Flutter scaffolding exists
- **WHEN** `flutter_app` is inspected after generation
- **THEN** it contains Dart application sources, tests, Android runner configuration, Linux runner configuration, and bridge integration for the supported native targets

#### Scenario: Supported native builds
- **WHEN** supported build commands run in the project development shell
- **THEN** the Flutter application analyzes and builds for Linux and Android using the Rust native library

### Requirement: Workspace quality verification
The restructured workspace SHALL satisfy Rust formatting, testing, and linting checks, and final verification SHALL expose the resulting tree and dependency boundary for review.

#### Scenario: Formatting and linting succeed
- **WHEN** `cargo fmt --all --check` and `cargo clippy --workspace --all-targets` are run with the installed Rust toolchain
- **THEN** both commands complete successfully without formatting differences or Clippy diagnostics

#### Scenario: Final structure is reviewed
- **WHEN** implementation verification is completed
- **THEN** the reported directory tree shows both Rust crates, the preserved root artifacts, and the reserved Flutter location, and the report confirms that no application-specific concern leaked into `automerge_repo`
