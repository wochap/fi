# fi

Native Android/Linux presentation for the local-first finance core. The Dart UI
uses the generated API in `lib/src/rust`; authoritative data and validation stay
in Rust.

From the repository root, enter `nix develop`, then use `flutter run` from this
directory. Run `scripts/check-frb-generated.sh` at the repository root to verify
that committed FRB bindings reproduce cleanly.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
