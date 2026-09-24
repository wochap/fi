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

        # Rust side of the app (flutter_rust_bridge). Built on its own so the
        # Flutter build does not have to run cargokit inside the Nix sandbox.
        appBridge = pkgs.rustPlatform.buildRustPackage {
          pname = "app_bridge";
          version = "0.1.0";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./crates
            ];
          };

          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = [
            "-p"
            "app_bridge"
          ];
          doCheck = false;

          # Only the cdylib is needed by the Flutter bundle.
          installPhase = ''
            runHook preInstall
            install -Dm644 target/*/release/libapp_bridge.so -t $out/lib
            runHook postInstall
          '';
        };

        fi = pkgs.flutter.buildFlutterApplication {
          pname = "fi";
          version = "1.0.0";

          src = ./flutter_app;

          # pubspec.lock is YAML; convert it to JSON at eval time (IFD).
          pubspecLock = pkgs.lib.importJSON (
            pkgs.runCommand "fi-pubspec.lock.json" { nativeBuildInputs = [ pkgs.yq ]; } ''
              yq . ${./flutter_app/pubspec.lock} > $out
            ''
          );

          # Replace the cargokit build of the app_bridge plugin with the
          # prebuilt library; it is bundled into lib/ next to the binary.
          # The path dependency is copied to its own store path, so it has
          # to be patched here rather than in postPatch.
          customSourceBuilders.app_bridge =
            { version, src, ... }:
            pkgs.stdenvNoCC.mkDerivation {
              pname = "app_bridge";
              inherit version src;
              inherit (src) passthru;
              dontBuild = true;
              installPhase = ''
                runHook preInstall
                cp -r . $out
                cat > $out/rust_builder/linux/CMakeLists.txt <<EOF
                cmake_minimum_required(VERSION 3.10)
                project(app_bridge LANGUAGES CXX)
                set(app_bridge_bundled_libraries "${appBridge}/lib/libapp_bridge.so" PARENT_SCOPE)
                EOF
                runHook postInstall
              '';
            };

          postInstall = ''
            install -Dm644 linux/com.wochap.fi.desktop -t $out/share/applications
            install -Dm644 assets/icon/icon.svg $out/share/icons/hicolor/scalable/apps/com.wochap.fi.svg
            install -Dm644 assets/icon/icon.png $out/share/icons/hicolor/1024x1024/apps/com.wochap.fi.png
          '';

          meta = {
            description = "Local-first schema-driven collections application";
            license = pkgs.lib.licenses.mit;
            mainProgram = "fi";
            platforms = pkgs.lib.platforms.linux;
          };
        };

      in
      {
        packages = {
          inherit fi;
          app-bridge = appBridge;
          default = fi;
        };

        apps.default = {
          type = "app";
          program = pkgs.lib.getExe fi;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Flutter / Dart
            flutter

            # Rust
            cargo
            cargo-audit
            cargo-deny
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
