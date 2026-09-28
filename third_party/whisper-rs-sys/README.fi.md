# whisper-rs-sys 0.15.0, patched for fi

Upstream: https://crates.io/crates/whisper-rs-sys (Unlicense; whisper.cpp and ggml are MIT).

Changes from the published crate:

- `build.rs` merges `libwhisper.a` and whisper.cpp's own `libggml*.a` into one relocatable
  object and keeps only `whisper_*` symbols global (`isolate_whisper`). llama.cpp (through
  `llama-cpp-sys-2`) ships a newer, incompatible ggml; without this the two static copies
  clash at link time with duplicate `ggml_*` symbols.
- Android links `c++_static` instead of `c++_shared`, since the APK bundles no
  `libc++_shared.so`.
- Unused ggml backends (CUDA, Metal, Vulkan, SYCL, OpenCL, …) are removed from
  `whisper.cpp/ggml/src` to keep the vendored tree small. Only the CPU backend is built.
