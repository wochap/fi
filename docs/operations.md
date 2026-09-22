# MVP operations and platform contract

## Storage layout and recovery

Each application data directory contains:

```text
automerge/documents/   authoritative Automerge snapshots
control.sqlite         bootstrap, public trust/device records, pairing and rotation journals
read-model.sqlite      disposable query projection
quarantine/            snapshots set aside by bootstrap recovery (created on first use)
```

Authoritative stores are `automerge/documents`, `control.sqlite`, and the
platform secure key store. `read-model.sqlite` is disposable: deleting it,
presenting a stale checkpoint, or leaving a corrupt projection causes a complete
rebuild from the authoritative root before commands are enabled. A restart
retains the root, schemas and records, identity, trusted/revoked devices, and
discovery epoch. Secret bytes are stored only in Linux Secret Service or Android
Keystore-wrapped private app storage.

### Partial-state recovery

Opening classifies every inconsistency between the authoritative stores as
recoverable or fatal. A state is recoverable only when the recorded root ID is
still known and another trusted device can re-supply its content; recovery
never mints a new root, never falls back to onboarding while a root is known,
and never deletes bytes.

| Condition | Outcome |
| --- | --- |
| `Ready` record, root snapshot missing | Demoted to `Joining` for the same root; re-synchronized from a trusted device with no pairing ceremony. |
| `Ready`/`Joining` record, root snapshot unreadable | Bytes moved to `quarantine/<root>.corrupt-root.automerge`, then as above. |
| Snapshots present, no bootstrap record | Moved to `quarantine/<id>.orphaned.automerge`; app opens in onboarding. Joining a dataset whose root matches a quarantined snapshot adopts it offline. |
| `control.sqlite` unreadable | Fatal, but snapshots are moved to `quarantine/<id>.control-store-unreadable.automerge` first. |
| `Creating`/`Joining` record beside foreign documents, malformed record, non-root snapshot unreadable | Fatal, no mutation. Reset resolves the first two. |

While recovering, the UI reports "Recovering your dataset from your other
devices". If no device able to supply the root is reachable for
`recovery_no_peer_after` (30 s), it reports that another device is required and
keeps waiting; a device appearing later completes recovery. Each demotion of a
root counts against `recovery_attempt_limit` (3, durable in `control.sqlite`);
beyond it, opening fails with a reset-resolvable error naming the root.
Quarantined files are never pruned automatically. An outstanding deliberate
reset always takes precedence over recovery.

The authoritative root format is versioned. This alpha release intentionally
does not migrate the former finance-v1 root: opening an unsupported root returns
an explicit reset-required error. Remove the application data directory only
when discarding that development dataset is acceptable. Deleting only
`read-model.sqlite` is safe because it is rebuilt from Automerge.

## Pairing and revocation

Pairing mode is explicitly started for a bounded duration. Both devices derive
the SAS from the authenticated transcript and TLS exporter; users must confirm
matching six-digit codes. Rejection and timeout remove transient sessions and do
not create trust or provisioning state. A joining device remains command-gated
until the existing root and complete projection are ready.

Revocation is local authorization, not global document ACL consensus. It is
durable before disconnect and route removal. Rotation excludes the revoked key;
offline trusted peers can migrate through the retained old browse selector or a
last-known pinned endpoint until retention expires.

## Android

Target SDK 35 declares `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
and `CHANGE_WIFI_MULTICAST_STATE`. It does not request location, background
location, WorkManager, a foreground service, or persistent daemon permissions.
Flutter reports resume/pause, Rust owns start/stop policy, and the Android
adapter holds a non-reference-counted multicast lock only during foreground
operation. Pause, startup failure, and activity destruction release it.

Android generates a non-exportable AES-GCM wrapping key in Android Keystore.
Identity/discovery records use fresh random nonces and kind/version associated
data. Modified ciphertext, nonce, metadata, or alias binding fails
authentication and never silently creates a replacement identity.

Run connected instrumentation with:

```sh
cd flutter_app
flutter build apk --debug
flutter test integration_test/android_foreground_smoke_test.dart -d <device-id>

# Nix Flutter's SDK is read-only, so keep Gradle and Kotlin project state in a
# writable temporary directory when running native instrumentation directly:
cd android
./gradlew --project-cache-dir=/tmp/fi-android-gradle-cache \
  -Pkotlin.project.persistent.dir=/tmp/fi-android-kotlin \
  connectedDebugAndroidTest
```

The Flutter smoke initializes the production Android secure store and Rust
networked core, starts normal and pairing discovery, observes Quinn-backed sync
status, stops foreground networking, and reopens the same identity/root. Native
instrumentation separately verifies authenticated-storage tamper rejection and
multicast-lock acquisition/release. A physical device must allow USB installs;
MIUI devices may require Developer options -> Install via USB.

## Linux and quality gates

Linux has no application-level X11 API. `scripts/smoke-linux-wayland.sh` starts
a headless Weston compositor, forces `GDK_BACKEND=wayland`, and verifies the
application remains healthy for the smoke window.

From the repository root run the FRB, Flutter, Rust, license, dependency, and
security gates documented in the root README. Structured trace capture tests
scan sentinel identity, discovery, SAS, and provisioning values at every level.
