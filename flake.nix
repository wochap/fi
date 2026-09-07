{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?rev=0ad6f47ea4fe188f4bc8f0380f93ae8523337c6c"; # nixos-26.05 (10 jul 2026)
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;

          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        androidComposition = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [
            "35"
            "36"
          ];
          buildToolsVersions = [ "35.0.0" ];

          abiVersions = [
            "arm64-v8a"
            "x86_64"
          ];

          includeNDK = true;
          includeCmake = true;
          cmakeVersions = [ "3.22.1" ];
          includeEmulator = false;
          includeSystemImages = false;
        };

        androidSdk = androidComposition.androidsdk;

      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Flutter / Dart
            flutter

            # Rust
            cargo
            clippy
            rustc
            rustfmt
            rustup

            # flutter_rust_bridge build tooling
            cargo-ndk
            flutter_rust_bridge_codegen

            # Linux desktop Flutter
            clang
            cmake
            ninja
            pkg-config
            llvmPackages.libclang

            gtk3
            pcre2
            libepoxy
            weston

            # Android
            androidSdk
            jdk17
          ];

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";

          ANDROID_NDK_HOME = "${androidSdk}/libexec/android-sdk/ndk-bundle";

          JAVA_HOME = "${pkgs.jdk17}";
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          shellHook = ''
            export PATH="$HOME/.cargo/bin:$PATH"

            echo "Flutter + Rust development shell"
            echo
            flutter --version
            rustc --version 2>/dev/null || true
          '';
        };
      }
    );
}
