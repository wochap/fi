# Fi Flutter application

Flutter presentation for Linux Wayland and Android. Dart owns widgets and view
state; Rust remains authoritative for data, validation, trust, and sync. Other
platforms are not supported.

See the [root README](../README.md) for the project architecture, repository
map, and screenshot placeholders.

## Software stack

| Component | Purpose |
| --- | --- |
| Flutter, Dart, Material 3 | Responsive UI and lifecycle observation |
| `flutter_rust_bridge` | Typed Dart/Rust FFI |
| Cargokit and `app_bridge` | Build and bundle Rust with Flutter |
| GTK 3 and Wayland | Linux desktop runtime |
| Android SDK/NDK, JDK 17, Keystore | Android build and secure storage |

Versions are locked by [`pubspec.lock`](pubspec.lock), the Rust workspace, and
[`../flake.nix`](../flake.nix).

## Setup

From the repository root:

```sh
nix develop
cd flutter_app
flutter pub get
```

The flake supplies Flutter, Rust, Android tooling, CMake, Ninja, GTK, and bridge
code generation. It does not include an Android emulator.

## Development builds

### Linux Wayland

```sh
GDK_BACKEND=wayland flutter run -d linux
```

Build without launching:

```sh
flutter build linux --debug
./build/linux/x64/debug/bundle/fi
```

### Android

Connect a device with USB debugging enabled, then run:

```sh
flutter devices
flutter run -d <device-id>
```

Build-only output:

```sh
flutter build apk --debug
# build/app/outputs/flutter-apk/app-debug.apk
```

## Release builds and installation

### Linux Wayland

```sh
flutter build linux --release
./build/linux/x64/release/bundle/fi
```

Keep the complete `build/linux/x64/release/bundle/` directory together. To
archive and install it for the current user:

```sh
tar -C build/linux/x64/release -czf fi-linux-x64.tar.gz bundle
install -d "$HOME/.local/opt/fi" "$HOME/.local/bin"
cp -a build/linux/x64/release/bundle/. "$HOME/.local/opt/fi/"
ln -sfn "$HOME/.local/opt/fi/fi" "$HOME/.local/bin/fi"
```

The bundle requires compatible GTK, Wayland, and Secret Service libraries. It
is not yet distributed as a flake package, AppImage, Flatpak, or distro package.

### Android

```sh
flutter run --release -d <device-id>
flutter build apk --release
flutter build appbundle --release
```

Outputs:

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`

Install the APK with:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release artifacts currently use the debug signing key for alpha testing. Add a
protected release keystore and update `android/app/build.gradle.kts` before
distribution. An AAB cannot be installed directly.

## Platform behavior

Android discovery and sync run only in the foreground; no background service or
location permission is used. Linux requires Wayland and a Secret Service
provider. Both platforms require multicast DNS and direct peer traffic on the
LAN for discovery and synchronization.

## Tests and generated code

From the repository root:

```sh
scripts/check-flutter.sh
scripts/check-frb-generated.sh
```

Linux Wayland smoke test:

```sh
cd flutter_app
flutter build linux --debug
cd ..
scripts/smoke-linux-wayland.sh
```

Connected Android smoke test:

```sh
cd flutter_app
flutter build apk --debug
flutter test integration_test/android_foreground_smoke_test.dart -d <device-id>
```

Generated bridge files live under `lib/src/rust/`; Cargokit glue lives under
`rust_builder/`. Do not edit either by hand.
