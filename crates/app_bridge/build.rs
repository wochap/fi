//! Captures the source commit for the runtime build identity. Any git failure
//! (no repository, no git on PATH) yields `unknown` and never fails the build.

use std::{path::Path, process::Command};

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("set by cargo");
    let dir = Path::new(&manifest_dir);
    let hash = git(dir, &["rev-parse", "--short=7", "HEAD"])
        .filter(|hash| !hash.is_empty())
        .unwrap_or_else(|| "unknown".to_owned());
    let dirty = hash != "unknown"
        && git(dir, &["status", "--porcelain", "--untracked-files=no"])
            .is_some_and(|status| !status.is_empty());
    println!("cargo:rustc-env=FI_GIT_HASH={hash}");
    println!("cargo:rustc-env=FI_GIT_DIRTY={}", u8::from(dirty));
    // A commit or checkout touches one of these; a plain edit does not, so the
    // dirty flag is best-effort.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/index");
    println!("cargo:rerun-if-changed=build.rs");
}
