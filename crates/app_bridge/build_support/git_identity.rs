// Reads the source commit straight from repository metadata, so build identity
// does not depend on a `git` executable. Shared by `build.rs` (via `include!`)
// and the crate's unit tests; std only.

use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitDirs {
    /// Per-worktree directory holding `HEAD` and `index`.
    pub git_dir: PathBuf,
    /// Shared directory holding `refs/` and `packed-refs`.
    pub common_dir: PathBuf,
}

/// Walks up from `start` to the first `.git`, either a directory or a
/// worktree/submodule file pointing at one with `gitdir:`.
pub fn find_git_dirs(start: &Path) -> Option<GitDirs> {
    start.ancestors().find_map(|dir| {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return Some(GitDirs {
                git_dir: dot_git.clone(),
                common_dir: dot_git,
            });
        }
        let pointer = fs::read_to_string(&dot_git).ok()?;
        let target = pointer.trim().strip_prefix("gitdir:")?.trim();
        let git_dir = dir.join(target);
        let common_dir = fs::read_to_string(git_dir.join("commondir"))
            .map(|common| git_dir.join(common.trim()))
            .unwrap_or_else(|_| git_dir.clone());
        Some(GitDirs {
            git_dir,
            common_dir,
        })
    })
}

fn is_hash(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Resolves `HEAD` to its full commit hash. Also returns every file whose
/// change means a new commit or checkout, including the loose ref path even
/// when it does not exist yet.
pub fn resolve_head(dirs: &GitDirs) -> Result<(String, Vec<PathBuf>), String> {
    let head_path = dirs.git_dir.join("HEAD");
    let packed_path = dirs.common_dir.join("packed-refs");
    let index_path = dirs.git_dir.join("index");
    let head = fs::read_to_string(&head_path)
        .map_err(|error| format!("cannot read {}: {error}", head_path.display()))?;
    let head = head.trim();
    if is_hash(head) {
        return Ok((head.to_owned(), vec![head_path, packed_path, index_path]));
    }
    let name = head
        .strip_prefix("ref:")
        .map(str::trim)
        .ok_or_else(|| format!("unrecognised HEAD: {head}"))?;
    let loose_path = dirs.common_dir.join(name);
    let watched = vec![
        head_path,
        loose_path.clone(),
        packed_path.clone(),
        index_path,
    ];
    if let Ok(loose) = fs::read_to_string(&loose_path) {
        let loose = loose.trim();
        if is_hash(loose) {
            return Ok((loose.to_owned(), watched));
        }
    }
    let packed = fs::read_to_string(&packed_path).unwrap_or_default();
    packed
        .lines()
        .filter(|line| !line.starts_with('#') && !line.starts_with('^'))
        .find_map(|line| {
            let (hash, reference) = line.split_once(' ')?;
            (reference.trim() == name && is_hash(hash)).then(|| hash.to_owned())
        })
        .map(|hash| (hash, watched))
        .ok_or_else(|| format!("ref {name} not found"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";

    fn write(path: &Path, contents: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn plain_repository_resolves_a_loose_branch() {
        let root = tempfile::tempdir().unwrap();
        write(&root.path().join(".git/HEAD"), "ref: refs/heads/main\n");
        write(
            &root.path().join(".git/refs/heads/main"),
            &format!("{HASH}\n"),
        );
        let nested = root.path().join("crates/app_bridge");
        fs::create_dir_all(&nested).unwrap();
        let dirs = find_git_dirs(&nested).unwrap();
        assert_eq!(dirs.git_dir, root.path().join(".git"));
        assert_eq!(dirs.common_dir, dirs.git_dir);
        let (hash, watched) = resolve_head(&dirs).unwrap();
        assert_eq!(hash, HASH);
        assert!(watched.contains(&root.path().join(".git/refs/heads/main")));
        assert!(watched.contains(&root.path().join(".git/packed-refs")));
        assert!(watched.contains(&root.path().join(".git/index")));
    }

    #[test]
    fn worktree_file_uses_its_common_dir_for_refs() {
        let root = tempfile::tempdir().unwrap();
        let main = root.path().join("main/.git");
        let worktree_git = main.join("worktrees/feature");
        write(&worktree_git.join("HEAD"), "ref: refs/heads/feature\n");
        write(&worktree_git.join("commondir"), "../..\n");
        write(&main.join("refs/heads/feature"), HASH);
        let checkout = root.path().join("feature");
        write(
            &checkout.join(".git"),
            &format!("gitdir: {}\n", worktree_git.display()),
        );
        let dirs = find_git_dirs(&checkout).unwrap();
        assert_eq!(dirs.git_dir, worktree_git);
        assert_eq!(
            fs::canonicalize(&dirs.common_dir).unwrap(),
            fs::canonicalize(&main).unwrap()
        );
        assert_eq!(resolve_head(&dirs).unwrap().0, HASH);
    }

    #[test]
    fn packed_only_ref_resolves_and_watches_the_missing_loose_path() {
        let root = tempfile::tempdir().unwrap();
        write(&root.path().join(".git/HEAD"), "ref: refs/heads/main\n");
        write(
            &root.path().join(".git/packed-refs"),
            &format!(
                "# pack-refs with: peeled fully-peeled sorted\n{HASH} refs/heads/main\n^{HASH}\n"
            ),
        );
        let dirs = find_git_dirs(root.path()).unwrap();
        let (hash, watched) = resolve_head(&dirs).unwrap();
        assert_eq!(hash, HASH);
        assert!(watched.contains(&root.path().join(".git/refs/heads/main")));
    }

    #[test]
    fn detached_head_is_the_hash() {
        let root = tempfile::tempdir().unwrap();
        write(&root.path().join(".git/HEAD"), &format!("{HASH}\n"));
        let dirs = find_git_dirs(root.path()).unwrap();
        assert_eq!(resolve_head(&dirs).unwrap().0, HASH);
    }

    #[test]
    fn missing_ref_is_an_error() {
        let root = tempfile::tempdir().unwrap();
        write(&root.path().join(".git/HEAD"), "ref: refs/heads/gone\n");
        let dirs = find_git_dirs(root.path()).unwrap();
        assert!(resolve_head(&dirs).unwrap_err().contains("refs/heads/gone"));
    }
}
