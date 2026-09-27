## Purpose

Defines where the application version comes from, how it is raised for a release, and how a running build identifies its version and source commit.

## Requirements

### Requirement: Single version source
The Flutter package manifest version line (`MAJOR.MINOR.PATCH+BUILD`) SHALL be the only place the application version is authored. The Rust workspace package version SHALL equal the `MAJOR.MINOR.PATCH` part, and the version a running build reports SHALL equal that same value. A check that compares the two manifests SHALL fail when they differ.

#### Scenario: Manifests agree
- **WHEN** the version check compares the Flutter manifest version and the Rust workspace version
- **THEN** it passes only when `MAJOR.MINOR.PATCH` is identical in both

#### Scenario: Manifests drift
- **WHEN** the Rust workspace version is edited by hand to a value the Flutter manifest does not carry
- **THEN** the version check fails and names both values

### Requirement: Scripted version bump
A bump script SHALL accept exactly one of `patch`, `minor`, or `major`, raise that component of the Flutter manifest version, reset the lower components to zero, increment the build number by one, rewrite the Rust workspace version to the new `MAJOR.MINOR.PATCH`, refresh the Rust lockfile, create one commit containing only those files, and create an annotated tag `vMAJOR.MINOR.PATCH` on it. It SHALL refuse to run when the working tree has uncommitted changes or when the tag already exists, and SHALL make no change in that case.

#### Scenario: Patch bump
- **WHEN** the manifest reads `0.1.20+41` and the script is run with `patch`
- **THEN** the manifest reads `0.1.21+42`, the Rust workspace version reads `0.1.21`, one new commit exists, and tag `v0.1.21` points at it

#### Scenario: Minor bump resets patch
- **WHEN** the manifest reads `0.1.21+42` and the script is run with `minor`
- **THEN** the manifest reads `0.2.0+43` and the Rust workspace version reads `0.2.0`

#### Scenario: Dirty tree is refused
- **WHEN** the script is run while a tracked file has uncommitted changes
- **THEN** it exits non-zero, states the reason, and neither manifest, the lockfile, the index, nor the tags change

#### Scenario: Unknown argument
- **WHEN** the script is run with no argument or with an argument other than `patch`, `minor`, or `major`
- **THEN** it exits non-zero with a usage message and changes nothing

### Requirement: Build identity available at runtime
Every build SHALL carry the version, the short hash of the commit it was built from, and whether the working tree had uncommitted changes at build time. These values SHALL be captured automatically during the normal Linux and Android build with no extra flag. When the source is not inside a git repository or git is unavailable, the hash SHALL read `unknown` and the build SHALL still succeed. Feature code SHALL obtain these values through one bridge query.

#### Scenario: Clean build from a commit
- **WHEN** the application is built from commit `a1b2c3d` with a clean working tree
- **THEN** the bridge reports version equal to the manifest version, hash `a1b2c3d`, and dirty false

#### Scenario: Dirty build
- **WHEN** the application is built with uncommitted changes to tracked files
- **THEN** the bridge reports dirty true alongside the hash

#### Scenario: Build outside git
- **WHEN** the source tree is built from an export that contains no `.git` directory
- **THEN** the build succeeds and the bridge reports hash `unknown` and dirty false

#### Scenario: Hash follows the checkout
- **WHEN** a new commit is checked out and the application is rebuilt without cleaning
- **THEN** the reported hash is the new commit's hash
