#!/usr/bin/env bash
set -euo pipefail

# Raises the application version in flutter_app/pubspec.yaml (the source of
# truth), mirrors it into the Cargo workspace version, refreshes Cargo.lock,
# commits, and creates an annotated tag vX.Y.Z. Does not push.
usage() {
  echo "usage: scripts/bump-version.sh <patch|minor|major>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
part="$1"
case "$part" in
  patch | minor | major) ;;
  *) usage ;;
esac

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "refusing to bump: working tree has uncommitted changes" >&2
  exit 1
fi

current="$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*+[0-9]*\)[[:space:]]*$/\1/p' flutter_app/pubspec.yaml)"
if [[ -z "$current" ]]; then
  echo "cannot parse version: line in flutter_app/pubspec.yaml" >&2
  exit 1
fi
IFS='.+' read -r major minor patch build <<<"$current"
case "$part" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
build=$((build + 1))
next="$major.$minor.$patch"
tag="v$next"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "refusing to bump: tag $tag already exists" >&2
  exit 1
fi

sed -i "s/^version:.*/version: $next+$build/" flutter_app/pubspec.yaml
sed -i "/^\[workspace\.package\]/,/^\[/ s/^version[[:space:]]*=.*/version = \"$next\"/" Cargo.toml
cargo update --workspace --offline
scripts/check-version.sh

git add flutter_app/pubspec.yaml Cargo.toml Cargo.lock
git commit -m "chore: release $tag"
git tag -a "$tag" -m "$tag"
echo "created $tag ($next+$build); push with: git push --follow-tags"
