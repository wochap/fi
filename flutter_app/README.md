# fi

Native Android/Linux presentation for the local-first finance core. The Dart UI
uses the generated API in `lib/src/rust`; authoritative data and validation stay
in Rust.

The Devices screen starts bounded pairing, presents Rust-supplied candidates and
six-digit SAS confirmation, retains trusted/revoked records, and delegates
rename/revoke commands to Rust. Its Offline, Searching, Connected, Syncing,
Synced, and Error labels are direct mappings of typed Rust state.

Android networking is foreground-only. The activity provides a scoped multicast
lock and Android-Keystore AES-GCM wrapping adapter; it declares socket,
network-state, Wi-Fi-state, and multicast permissions, with no location or
background-service permission. Linux uses Secret Service and is smoke-tested
with a headless Wayland compositor.

From the repository root, enter `nix develop`, then use `flutter run` from this
directory. Run `scripts/check-frb-generated.sh` at the repository root to verify
that committed FRB bindings reproduce cleanly.

The UI never derives trust, SAS, convergence, or authorization locally. Stream
events invalidate retained presentation and command completion is followed by a
complete Rust query refresh.
