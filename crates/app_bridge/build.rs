//! Captures the source commit for the runtime build identity. Explicit
//! `FI_GIT_HASH`/`FI_GIT_DIRTY` win (Nix sets them from the flake revision);
//! otherwise the hash is read from repository metadata without `git`. Any
//! failure yields `unknown` with a build warning and never fails the build.

use std::process::Command;

include!("build_support/git_identity.rs");

fn dirty(dir: &Path) -> bool {
    // Only a working `git` can tell; without one the flag is reported clean.
    Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=no"])
        .current_dir(dir)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .is_some_and(|output| !output.stdout.is_empty())
}

fn main() {
    println!("cargo:rerun-if-env-changed=FI_GIT_HASH");
    println!("cargo:rerun-if-env-changed=FI_GIT_DIRTY");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=build_support/git_identity.rs");
    let explicit = std::env::var("FI_GIT_HASH")
        .ok()
        .filter(|hash| !hash.trim().is_empty());
    let (hash, dirty) = if let Some(hash) = explicit {
        let dirty = std::env::var("FI_GIT_DIRTY").unwrap_or_else(|_| "0".to_owned());
        (hash.trim().to_owned(), u8::from(dirty.trim() == "1"))
    } else {
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("set by cargo");
        let dir = Path::new(&manifest_dir);
        let resolved = find_git_dirs(dir)
            .ok_or_else(|| "no .git found".to_owned())
            .and_then(|dirs| resolve_head(&dirs));
        match resolved {
            Ok((hash, watched)) => {
                for path in watched {
                    let path = fs::canonicalize(&path).unwrap_or(path);
                    println!("cargo:rerun-if-changed={}", path.display());
                }
                (hash[..7].to_owned(), u8::from(dirty(dir)))
            }
            Err(reason) => {
                println!("cargo:warning=fi build identity unavailable: {reason}");
                ("unknown".to_owned(), 0)
            }
        }
    };
    println!("cargo:rustc-env=FI_GIT_HASH={hash}");
    println!("cargo:rustc-env=FI_GIT_DIRTY={dirty}");
}
