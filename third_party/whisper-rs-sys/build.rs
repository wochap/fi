#![allow(clippy::uninlined_format_args)]

extern crate bindgen;
extern crate semver;

use cmake::Config;
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;

fn main() {
    let target = env::var("TARGET").unwrap();
    // Link C++ standard library
    if let Some(cpp_stdlib) = get_cpp_link_stdlib(&target) {
        println!("cargo:rustc-link-lib=dylib={}", cpp_stdlib);
    }
    // Link macOS Accelerate framework for matrix calculations
    if target.contains("apple") {
        println!("cargo:rustc-link-lib=framework=Accelerate");
        #[cfg(feature = "coreml")]
        {
            println!("cargo:rustc-link-lib=framework=Foundation");
            println!("cargo:rustc-link-lib=framework=CoreML");
        }
        #[cfg(feature = "metal")]
        {
            println!("cargo:rustc-link-lib=framework=Foundation");
            println!("cargo:rustc-link-lib=framework=Metal");
            println!("cargo:rustc-link-lib=framework=MetalKit");
        }
    }

    #[cfg(feature = "coreml")]
    println!("cargo:rustc-link-lib=static=whisper.coreml");

    #[cfg(feature = "openblas")]
    {
        if let Ok(openblas_path) = env::var("OPENBLAS_PATH") {
            println!(
                "cargo::rustc-link-search={}",
                PathBuf::from(openblas_path).join("lib").display()
            );
        }
        if cfg!(windows) {
            println!("cargo:rustc-link-lib=libopenblas");
        } else {
            println!("cargo:rustc-link-lib=openblas");
        }
    }
    #[cfg(feature = "cuda")]
    {
        println!("cargo:rustc-link-lib=cublas");
        println!("cargo:rustc-link-lib=cudart");
        println!("cargo:rustc-link-lib=cublasLt");
        println!("cargo:rustc-link-lib=cuda");
        cfg_if::cfg_if! {
            if #[cfg(target_os = "windows")] {
                let cuda_path = PathBuf::from(env::var("CUDA_PATH").unwrap()).join("lib/x64");
                println!("cargo:rustc-link-search={}", cuda_path.display());
            } else {
                println!("cargo:rustc-link-lib=culibos");
                println!("cargo:rustc-link-search=/usr/local/cuda/lib64");
                println!("cargo:rustc-link-search=/usr/local/cuda/lib64/stubs");
                println!("cargo:rustc-link-search=/opt/cuda/lib64");
                println!("cargo:rustc-link-search=/opt/cuda/lib64/stubs");
            }
        }
    }
    #[cfg(feature = "hipblas")]
    {
        println!("cargo:rustc-link-lib=hipblas");
        println!("cargo:rustc-link-lib=rocblas");
        println!("cargo:rustc-link-lib=amdhip64");

        cfg_if::cfg_if! {
            if #[cfg(target_os = "windows")] {
                panic!("Due to a problem with the last revision of the ROCm 5.7 library, it is not possible to compile the library for the windows environment.\nSee https://github.com/ggerganov/whisper.cpp/issues/2202 for more details.")
            } else {
                println!("cargo:rerun-if-env-changed=HIP_PATH");

                let hip_path = match env::var("HIP_PATH") {
                    Ok(path) =>PathBuf::from(path),
                    Err(_) => PathBuf::from("/opt/rocm"),
                };
                let hip_lib_path = hip_path.join("lib");

                println!("cargo:rustc-link-search={}",hip_lib_path.display());
            }
        }
    }

    #[cfg(feature = "openmp")]
    {
        if target.contains("gnu") {
            println!("cargo:rustc-link-lib=gomp");
        } else if target.contains("apple") {
            println!("cargo:rustc-link-lib=omp");
            println!("cargo:rustc-link-search=/opt/homebrew/opt/libomp/lib");
        }
    }

    println!("cargo:rerun-if-changed=wrapper.h");

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let whisper_root = out.join("whisper.cpp");

    if !whisper_root.exists() {
        std::fs::create_dir_all(&whisper_root).unwrap();
        fs_extra::dir::copy("./whisper.cpp", &out, &Default::default()).unwrap_or_else(|e| {
            panic!(
                "Failed to copy whisper sources into {}: {}",
                whisper_root.display(),
                e
            )
        });
    }

    if env::var("WHISPER_DONT_GENERATE_BINDINGS").is_ok() {
        let _: u64 = std::fs::copy("src/bindings.rs", out.join("bindings.rs"))
            .expect("Failed to copy bindings.rs");
    } else {
        // https://github.com/rust-lang/rust-bindgen/issues/2691
        // https://github.com/rust-lang/rust-bindgen/issues/3264
        // https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/issues/779
        let package_msrv = match option_env!("CARGO_PKG_RUST_VERSION") {
            Some(v) if !v.is_empty() => {
                let v = semver::Version::parse(v).expect("Invalid CARGO_PKG_RUST_VERSION");
                bindgen::RustTarget::stable(v.minor, v.patch)
            }
            // as_chunks in utilities.rs requires 1.88+
            _ => bindgen::RustTarget::stable(88, 0),
        }
        .map_err(|v| v.to_string())
        .unwrap();

        let mut bindings = bindgen::Builder::default()
            .rust_edition(bindgen::RustEdition::Edition2021)
            .rust_target(package_msrv)
            .header("wrapper.h");

        #[cfg(feature = "metal")]
        {
            bindings = bindings.header("whisper.cpp/ggml/include/ggml-metal.h");
        }
        #[cfg(feature = "vulkan")]
        {
            bindings = bindings
                .header("whisper.cpp/ggml/include/ggml-vulkan.h")
                .clang_arg("-DGGML_USE_VULKAN=1");
        }

        let bindings = bindings
            .clang_arg("-I./whisper.cpp/")
            .clang_arg("-I./whisper.cpp/include")
            .clang_arg("-I./whisper.cpp/ggml/include")
            .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
            .generate();

        match bindings {
            Ok(b) => {
                let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
                b.write_to_file(out_path.join("bindings.rs"))
                    .expect("Couldn't write bindings!");
            }
            Err(e) => {
                println!("cargo:warning=Unable to generate bindings: {}", e);
                println!("cargo:warning=Using bundled bindings.rs, which may be out of date");
                // copy src/bindings.rs to OUT_DIR
                std::fs::copy("src/bindings.rs", out.join("bindings.rs"))
                    .expect("Unable to copy bindings.rs");
            }
        }
    };

    // stop if we're on docs.rs
    if env::var("DOCS_RS").is_ok() {
        return;
    }

    let mut config = Config::new(&whisper_root);

    config
        .profile("Release")
        .define("BUILD_SHARED_LIBS", "OFF")
        .define("WHISPER_ALL_WARNINGS", "OFF")
        .define("WHISPER_ALL_WARNINGS_3RD_PARTY", "OFF")
        .define("WHISPER_BUILD_TESTS", "OFF")
        .define("WHISPER_BUILD_EXAMPLES", "OFF")
        .very_verbose(true)
        .pic(true);

    if cfg!(target_os = "windows") {
        config.cxxflag("/utf-8");
        println!("cargo:rustc-link-lib=advapi32");
    }

    if cfg!(feature = "coreml") {
        config.define("WHISPER_COREML", "ON");
        config.define("WHISPER_COREML_ALLOW_FALLBACK", "1");
    }

    if cfg!(feature = "cuda") {
        config.define("GGML_CUDA", "ON");
        config.define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");
        config.define("CMAKE_CUDA_FLAGS", "-Xcompiler=-fPIC");
    }

    if cfg!(feature = "hipblas") {
        config.define("GGML_HIP", "ON");
        config.define("CMAKE_C_COMPILER", "hipcc");
        config.define("CMAKE_CXX_COMPILER", "hipcc");
        println!("cargo:rerun-if-env-changed=AMDGPU_TARGETS");
        if let Ok(gpu_targets) = env::var("AMDGPU_TARGETS") {
            config.define("AMDGPU_TARGETS", gpu_targets);
        }
    }

    if cfg!(feature = "vulkan") {
        config.define("GGML_VULKAN", "ON");
        if cfg!(windows) {
            println!("cargo:rerun-if-env-changed=VULKAN_SDK");
            println!("cargo:rustc-link-lib=vulkan-1");
            let vulkan_path = match env::var("VULKAN_SDK") {
                Ok(path) => PathBuf::from(path),
                Err(_) => panic!(
                    "Please install Vulkan SDK and ensure that VULKAN_SDK env variable is set"
                ),
            };
            let vulkan_lib_path = vulkan_path.join("Lib");
            println!("cargo:rustc-link-search={}", vulkan_lib_path.display());
        } else if cfg!(target_os = "macos") {
            println!("cargo:rerun-if-env-changed=VULKAN_SDK");
            println!("cargo:rustc-link-lib=vulkan");
            let vulkan_path = match env::var("VULKAN_SDK") {
                Ok(path) => PathBuf::from(path),
                Err(_) => panic!(
                    "Please install Vulkan SDK and ensure that VULKAN_SDK env variable is set"
                ),
            };
            let vulkan_lib_path = vulkan_path.join("lib");
            println!("cargo:rustc-link-search={}", vulkan_lib_path.display());
        } else {
            println!("cargo:rustc-link-lib=vulkan");
        }
    }

    if cfg!(feature = "openblas") {
        config.define("GGML_BLAS", "ON");
        config.define("GGML_BLAS_VENDOR", "OpenBLAS");
        if env::var("BLAS_INCLUDE_DIRS").is_err() {
            panic!("BLAS_INCLUDE_DIRS environment variable must be set when using OpenBLAS");
        }
        config.define("BLAS_INCLUDE_DIRS", env::var("BLAS_INCLUDE_DIRS").unwrap());
        println!("cargo:rerun-if-env-changed=BLAS_INCLUDE_DIRS");
    }

    if cfg!(feature = "metal") {
        config.define("GGML_METAL", "ON");
        config.define("GGML_METAL_NDEBUG", "ON");
        config.define("GGML_METAL_EMBED_LIBRARY", "ON");
    } else {
        // Metal is enabled by default, so we need to explicitly disable it
        config.define("GGML_METAL", "OFF");
    }

    if cfg!(debug_assertions) || cfg!(feature = "force-debug") {
        // debug builds are too slow to even remotely be usable,
        // so we build with optimizations even in debug mode
        config.define("CMAKE_BUILD_TYPE", "RelWithDebInfo");
        config.cxxflag("-DWHISPER_DEBUG");
    } else {
        // we're in release mode, explicitly set to release mode
        // see also https://codeberg.org/tazz4843/whisper-rs/issues/226
        config.define("CMAKE_BUILD_TYPE", "Release");
    }

    // Allow passing any WHISPER or CMAKE compile flags
    for (key, value) in env::vars() {
        let is_whisper_flag =
            key.starts_with("WHISPER_") && key != "WHISPER_DONT_GENERATE_BINDINGS";
        let is_ggml_flag = key.starts_with("GGML_");
        let is_cmake_flag = key.starts_with("CMAKE_");
        if is_whisper_flag || is_ggml_flag || is_cmake_flag {
            config.define(&key, &value);
        }
    }

    // fi patch: cross-compile for Android with the NDK's CMake toolchain, as llama-cpp-sys-2
    // does. `ANDROID_NDK` and `ANDROID_PLATFORM` come from cargokit's Android environment.
    if target.contains("android") {
        let ndk = env::var("ANDROID_NDK")
            .or_else(|_| env::var("ANDROID_NDK_ROOT"))
            .or_else(|_| env::var("ANDROID_NDK_HOME"))
            .expect("set ANDROID_NDK to build whisper.cpp for Android");
        let abi = if target.starts_with("aarch64") {
            "arm64-v8a"
        } else if target.starts_with("armv7") || target.starts_with("arm") {
            "armeabi-v7a"
        } else if target.starts_with("x86_64") {
            "x86_64"
        } else {
            "x86"
        };
        config.define(
            "CMAKE_TOOLCHAIN_FILE",
            format!("{ndk}/build/cmake/android.toolchain.cmake"),
        );
        config.define("ANDROID_ABI", abi);
        config.define(
            "ANDROID_PLATFORM",
            env::var("ANDROID_PLATFORM").unwrap_or_else(|_| "android-24".into()),
        );
        config.define("ANDROID_STL", "c++_static");
        println!("cargo:rerun-if-env-changed=ANDROID_NDK");
        println!("cargo:rerun-if-env-changed=ANDROID_PLATFORM");
    }

    if cfg!(not(feature = "openmp")) {
        config.define("GGML_OPENMP", "OFF");
    }

    if cfg!(feature = "intel-sycl") {
        config.define("BUILD_SHARED_LIBS", "ON");
        config.define("GGML_SYCL", "ON");
        config.define("GGML_SYCL_TARGET", "INTEL");
        config.define("CMAKE_C_COMPILER", "icx");
        config.define("CMAKE_CXX_COMPILER", "icpx");
    }

    let destination = config.build();

    // fi patch: whisper.cpp vendors its own ggml, which clashes with llama.cpp's ggml when both
    // are linked statically into one library. Merge whisper and its ggml into one relocatable
    // object and keep only the `whisper_*` symbols global, so its ggml stays private.
    let isolated = isolate_whisper(&out, &destination);
    println!("cargo:rustc-link-search=native={}", isolated.display());
    println!("cargo:rustc-link-lib=static=whisper_isolated");

    println!(
        "cargo:WHISPER_CPP_VERSION={}",
        get_whisper_cpp_version(&whisper_root)
            .expect("Failed to read whisper.cpp CMake config")
            .expect("Could not find whisper.cpp version declaration"),
    );

    // for whatever reason this file is generated during build and triggers cargo complaining
    _ = std::fs::remove_file("bindings/javascript/package.json");
}

// From https://github.com/alexcrichton/cc-rs/blob/fba7feded71ee4f63cfe885673ead6d7b4f2f454/src/lib.rs#L2462
fn get_cpp_link_stdlib(target: &str) -> Option<&'static str> {
    if target.contains("msvc") {
        None
    } else if target.contains("apple") || target.contains("freebsd") || target.contains("openbsd") {
        Some("c++")
    } else if target.contains("android") {
        // fi patch: the app ships no libc++_shared.so.
        Some("c++_static")
    } else {
        Some("stdc++")
    }
}

fn add_link_search_path(dir: &std::path::Path) -> std::io::Result<()> {
    if dir.is_dir() {
        println!("cargo:rustc-link-search={}", dir.display());
        for entry in std::fs::read_dir(dir)? {
            add_link_search_path(&entry?.path())?;
        }
    }
    Ok(())
}

fn get_whisper_cpp_version(whisper_root: &std::path::Path) -> std::io::Result<Option<String>> {
    let cmake_lists = BufReader::new(File::open(whisper_root.join("CMakeLists.txt"))?);

    for line in cmake_lists.lines() {
        let line = line?;

        if let Some(suffix) = line.strip_prefix(r#"project("whisper.cpp" VERSION "#) {
            let whisper_cpp_version = suffix.trim_end_matches(')');
            return Ok(Some(whisper_cpp_version.into()));
        }
    }

    Ok(None)
}

/// Finds a static library built by CMake under `dir`.
fn find_archive(dir: &std::path::Path, name: &str) -> Option<PathBuf> {
    for sub in ["lib", "lib64"] {
        let path = dir.join(sub).join(name);
        if path.exists() {
            return Some(path);
        }
    }
    None
}

/// A tool next to the C compiler (NDK `llvm-objcopy`), else `llvm-<tool>`, else `<tool>`.
fn binutil(compiler: &std::path::Path, tool: &str) -> PathBuf {
    if let Some(dir) = compiler.parent() {
        for name in [format!("llvm-{tool}"), tool.to_owned()] {
            let path = dir.join(&name);
            if path.exists() {
                return path;
            }
        }
    }
    PathBuf::from(tool)
}

fn run(command: &mut std::process::Command) {
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("failed to run {command:?}: {error}"));
    assert!(status.success(), "{command:?} failed with {status}");
}

fn isolate_whisper(out: &std::path::Path, destination: &std::path::Path) -> PathBuf {
    let archives: Vec<PathBuf> = ["libwhisper.a", "libggml.a", "libggml-base.a", "libggml-cpu.a"]
        .iter()
        .map(|name| {
            find_archive(destination, name).unwrap_or_else(|| panic!("{name} was not built"))
        })
        .collect();
    let dir = out.join("isolated");
    std::fs::create_dir_all(&dir).unwrap();
    let object = dir.join("whisper_isolated.o");
    let compiler = cc::Build::new().get_compiler();
    let mut link = std::process::Command::new(compiler.path());
    link.args(compiler.args())
        .args(["-r", "-nostdlib", "-Wl,--whole-archive"])
        .args(&archives)
        .args(["-Wl,--no-whole-archive", "-o"])
        .arg(&object);
    run(&mut link);
    // Rename every symbol that could meet llama.cpp's copy: all strong definitions except the
    // `whisper_*` C API, and weak ones (C++ inline or template code) that mention ggml or gguf.
    // Local and undefined names are included, so COMDAT group signatures (such as the `D5`
    // name of a constructor group, which is not itself a defined symbol) are renamed with their
    // members and never fold into llama.cpp's groups.
    let listing = std::process::Command::new(binutil(compiler.path(), "nm"))
        .arg("-a")
        .arg(&object)
        .output()
        .expect("failed to run nm");
    assert!(listing.status.success(), "nm failed");
    let mut renames = String::new();
    let mut seen = std::collections::HashSet::new();
    for line in String::from_utf8_lossy(&listing.stdout).lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let [.., kind, name] = fields.as_slice() else {
            continue;
        };
        if name.starts_with("whisper_") {
            continue;
        }
        let strong = matches!(*kind, "T" | "D" | "B" | "R" | "C" | "G" | "S" | "i");
        if strong || name.contains("ggml") || name.contains("gguf") {
            if seen.insert(name.to_string()) {
                renames.push_str(&format!("{name} fi_whisper_{name}\n"));
            }
        }
    }
    let renames_path = dir.join("renames.txt");
    std::fs::write(&renames_path, renames).unwrap();
    run(std::process::Command::new(binutil(compiler.path(), "objcopy"))
        .arg(format!("--redefine-syms={}", renames_path.display()))
        .arg(&object));
    let archive = dir.join("libwhisper_isolated.a");
    let _ = std::fs::remove_file(&archive);
    run(std::process::Command::new(binutil(compiler.path(), "ar"))
        .arg("rcs")
        .arg(&archive)
        .arg(&object));
    dir
}
