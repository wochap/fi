# Fi Flutter application

This directory contains Fi's native presentation layer for Linux Wayland and
Android. Dart owns widgets and short-lived view state; authoritative finance
data, validation, device trust, pairing, and synchronization remain in Rust.

Only Linux Wayland and Android are supported. The generated iOS, macOS, Windows,
and web paths in build tooling are not product targets.

## Screenshots

The application screenshots have not been captured yet.

| Compact Android layout | Wide Linux layout | Pairing confirmation |
| --- | --- | --- |
| _Screenshot placeholder_ | _Screenshot placeholder_ | _Screenshot placeholder_ |

Future image files should live under `../docs/screenshots/` so the root and app
READMEs can share them.

## Software stack and dependencies

| Component | Role |
| --- | --- |
| Flutter and Dart | Material 3 screens, navigation, lifecycle observation, and controllers |
| `flutter_rust_bridge` 2.12 | Generated Dart/Rust FFI boundary |
| `app_bridge` path plugin | Builds and bundles the Rust `cdylib` through Cargokit |
| `path_provider` | Selects the platform application-support directory |
| `intl` | Locale-aware amount and date presentation |
| GTK 3 and Wayland | Linux desktop window and rendering backend |
| Android SDK/NDK and JDK 17 | Android runner, Kotlin adapter, and Rust cross-compilation |
| Android Keystore | Non-exportable key used to wrap identity and discovery secrets |
| Linux Secret Service | Desktop private identity and discovery-secret storage |

All supported versions and native build dependencies come from the repository's
[`../flake.nix`](../flake.nix). Dart package versions are locked in
[`pubspec.lock`](pubspec.lock).

## Application structure

```text
flutter_app/
├── lib/
│   ├── main.dart                 Runtime initialization and data directory
│   ├── app.dart                  Bootstrap, navigation, and application lifecycle
│   ├── controllers.dart          Retained UI state and Rust-event subscriptions
│   ├── transactions_page.dart   Finance screens and dialogs
│   ├── bridge/                   Testable Dart abstraction over generated FFI
│   └── src/rust/                 Generated flutter_rust_bridge bindings
├── android/                      Android runner, Keystore, and multicast lock
├── linux/                        GTK desktop runner and bundle rules
├── rust_builder/                 Generated Cargokit integration for app_bridge
├── test/                         Unit and widget tests
└── integration_test/             Connected Android foreground-networking smoke
```

Commands go from widgets through controllers and `FinanceBridge` into the
generated bridge. Rust returns complete query results plus typed streams used to
invalidate or replace retained presentation state. The UI never calculates a
pairing code, infers convergence from elapsed time, or mutates device trust
locally.

## Enter the development environment

From the repository root:

```sh
nix develop
cd flutter_app
flutter pub get
```

The Nix shell configures Flutter, Rust, Cargo, the Android SDK/NDK, JDK,
`flutter_rust_bridge_codegen`, CMake, Ninja, GTK, and libclang. It does not
include an Android emulator; use a physical device or provide your own emulator.

## Development builds

### Linux Wayland

Run with hot reload in the current Wayland session:

```sh
GDK_BACKEND=wayland flutter run -d linux
```

Build a reusable debug bundle without launching it:

```sh
flutter build linux --debug
./build/linux/x64/debug/bundle/fi
```

From the repository root, the headless compositor smoke test verifies that this
debug bundle starts with Wayland forced:

```sh
scripts/smoke-linux-wayland.sh
```

### Android

Enable Developer options and USB debugging on the phone, connect it, and accept
the authorization prompt. Then use the device identifier printed by Flutter:

```sh
flutter devices
flutter run -d <device-id>
```

To build the debug APK without launching it:

```sh
flutter build apk --debug
```

The result is `build/app/outputs/flutter-apk/app-debug.apk`.

## Production-mode builds

### Linux Wayland

```sh
flutter build linux --release
./build/linux/x64/release/bundle/fi
```

The entire `build/linux/x64/release/bundle/` directory is the application. Do
not move only the executable: it loads assets and native libraries from sibling
directories. See the root [packaging and local installation
guide](../README.md#packaging-and-local-installation) for archiving and a
per-user installation.

### Android

Run an optimized build directly on a connected phone:

```sh
flutter run --release -d <device-id>
```

Build installable and store-style artifacts:

```sh
flutter build apk --release
flutter build appbundle --release
```

Outputs:

- `build/app/outputs/flutter-apk/app-release.apk` for direct installation.
- `build/app/outputs/bundle/release/app-release.aab` for a store pipeline.

The current release build type deliberately uses the debug signing key for
alpha testing. It is not suitable for publication. Configure a protected
release keystore and replace the debug signing configuration in
`android/app/build.gradle.kts` before distributing an APK or AAB.

Install the local APK on a connected device with:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Platform behavior

Android declares internet, network-state, Wi-Fi-state, and multicast-state
permissions, but no location or background-service permissions. The activity
holds a scoped multicast lock only while the app is in the foreground. The app
notifies Rust on resume and pause, and Rust starts or stops discovery and sync.

Linux has no application-level X11 API. Use a working Secret Service provider
such as GNOME Keyring or KWallet's Secret Service implementation so Rust can
store private device material.

The Devices screen presents Rust-supplied pairing candidates and six-digit SAS
confirmation. Offline, Searching, Connected, Syncing, Synced, and Error are
direct mappings from typed Rust states.

## Tests and generated code

From the repository root, run Dart formatting, static analysis, and widget/unit
tests together:

```sh
scripts/check-flutter.sh
```

Run the connected Android integration smoke against a selected device:

```sh
cd flutter_app
flutter build apk --debug
flutter test integration_test/android_foreground_smoke_test.dart -d <device-id>
```

The Rust and Dart bindings under `lib/src/rust/` are generated and committed.
After changing the public Rust bridge API, verify regeneration from the root:

```sh
scripts/check-frb-generated.sh
```

Do not hand-edit generated bridge files or the Cargokit contents under
`rust_builder/`.
