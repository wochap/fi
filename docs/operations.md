# MVP operations and platform contract

## Storage layout and recovery

Each application data directory contains:

```text
automerge/documents/   authoritative Automerge snapshots
control.sqlite         bootstrap, public trust/device records, pairing and rotation journals
read-model.sqlite      disposable query projection
```

Deleting `read-model.sqlite`, presenting a stale checkpoint, or leaving a
corrupt projection causes a complete rebuild from the authoritative root before
commands are enabled. A restart retains the root, finance data, identity,
trusted/revoked devices, and discovery epoch. Secret bytes are stored only in
Linux Secret Service or Android Keystore-wrapped private app storage.

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
./android/gradlew connectedDebugAndroidTest
```

## Linux and quality gates

Linux has no application-level X11 API. `scripts/smoke-linux-wayland.sh` starts
a headless Weston compositor, forces `GDK_BACKEND=wayland`, and verifies the
application remains healthy for the smoke window.

From the repository root run the FRB, Flutter, Rust, license, dependency, and
security gates documented in the root README. Structured trace capture tests
scan sentinel identity, discovery, SAS, and provisioning values at every level.
