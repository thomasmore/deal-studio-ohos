# Embed the local selector in the OpenHarmony app

The selector is a Rust static library with embedded weights and tokenizer.
The experimental C entry point returns scores for the app's existing JSON
`state` and `questions`. The regular prediction entry point returns an empty
answer map with `laya_not_human_calibrated` for embedded Laya bundles.

## Verify on the development machine

Build or obtain a Q4 bundle by following the
[playground guide](../../tools/vera-playground/README.md). Run from the repository
root. Set `BUNDLE` to the absolute directory with all four bundle files.
For Cycle 2, use the directory extracted from `mmbert-small-cycle2-q4.tar.gz`.
For the public export, use `$PWD/.local-jev/bundle-q4`.

```sh
BUNDLE="$PWD/.local-jev/mmbert-small-cycle2-q4"
LAYA_BUNDLE_DIR="$BUNDLE" cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib
cc -I native/local-jev/include tools/local-jev/abi-check.c \
  native/local-jev/target/release/liblocal_jev.a -lpthread -ldl -lm \
  -o .local-jev/abi-check
.local-jev/abi-check
```

The check expects ABI version 1, an empty answer map from
`local_jev_predict`, and finite diagnostic logits from
`local_jev_diagnostic_scores`. Both diagnostic calls use the same loaded model.

## Build for arm64 OpenHarmony

Install the native OpenHarmony SDK and configure its Clang wrapper and sysroot
as described in the [Rust OpenHarmony target guide](https://doc.rust-lang.org/rustc/platform-support/openharmony.html).
Set the environment variables below to absolute paths. The `CC`, `CXX`, and
`AR` values enable Cargo build scripts to use the same SDK.

```sh
rustup target add aarch64-unknown-linux-ohos
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=/path/to/aarch64-unknown-linux-ohos-clang.sh
export CC_aarch64_unknown_linux_ohos="$CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER"
export CXX_aarch64_unknown_linux_ohos=/path/to/aarch64-unknown-linux-ohos-clang++.sh
export AR_aarch64_unknown_linux_ohos=/path/to/native/llvm/bin/llvm-ar
LAYA_BUNDLE_DIR="$BUNDLE" cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib \
  --target aarch64-unknown-linux-ohos
```

The archive path is
`native/local-jev/target/aarch64-unknown-linux-ohos/release/liblocal_jev.a`.
Each app ABI needs its own Rust target and archive.

## Add an opt-in NAPI bridge

For a test build, add a `liblocaljev.so` NAPI module in
[entry/src/main/cpp/CMakeLists.txt](../../entry/src/main/cpp/CMakeLists.txt).
Use the archive built for that app ABI and the [C header](include/local_jev.h).
Pass `-DVERA_LOCAL_JEV_ARCHIVE=/absolute/path/to/liblocal_jev.a` in the
module's [native build arguments](../../entry/build-profile.json5).

```cmake
add_library(localjev SHARED napi_local_jev.cpp)
target_include_directories(localjev PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/local-jev/include")
target_link_libraries(localjev PRIVATE "${VERA_LOCAL_JEV_ARCHIVE}" libace_napi.z.so)
```

Use the async-work and module registration pattern in
[napi_llama.cpp](../../entry/src/main/cpp/napi_llama.cpp). Name the new
registration `localjev`. Copy the ArkTS input to a UTF-8 string before queuing
the work. In the worker, call `local_jev_diagnostic_scores` with the buffer and
its byte length. Copy the returned NUL-terminated JSON string and call
`local_jev_free` once. Resolve the promise with the copied string on the
completion thread. Reject it if the input, ABI version, or native call fails.
Discard the result if its app operation was cancelled.

Follow the [existing native type package](../../entry/src/main/cpp/types/libllama)
and add a `liblocaljev.so` file dependency to
[entry/oh-package.json5](../../entry/oh-package.json5). Declare the diagnostic
method in the new package:

```typescript
export const diagnosticScores: (request: string) => Promise<string>
```

Wire the experimental call into a developer-only action. Use a synthetic
request first, then inspect scores from the app's existing decision bodies:

- Generation and component selection use `host.askJev` in
  [AgentAppHost.ets](../../entry/src/main/ets/vera/agent/AgentAppHost.ets)
  and `askJev` in
  [VeraCompose.ets](../../entry/src/main/ets/vera/VeraCompose.ets).
- Structural edits send the body built by `buildEditRequest` in
  [VeraComposition.ets](../../entry/src/main/ets/vera/VeraComposition.ets).
  This path has its own transport call.
- [GeneratePage.ets](../../entry/src/main/ets/pages/GeneratePage.ets)
  checks `settings.hasSelector()` before these paths. A future offline mode
  needs a separate local availability check at both gates.

Use the diagnostic reply only for inspection. Keep the existing option filters
and empty-answer behavior. DeepSeek still handles plans, section content, and
custom code. For a future offline selector, keep unavailable decisions local
and return uncertainty to the caller.

The commands in this guide cover the host C ABI and describe the phone wiring.
Verify the OpenHarmony build, HAP loading, cancellation, and warm inference on
the target phone before enabling any local decision route.

## Build the experimental Candle scheduler

The optional scheduler distributes token rows across Rayon workers. It uses the
same Q4 dot product for each output element. Build the patched host CLI from the
repository root. It takes the same bundle and arguments as the stock CLI.

```sh
tools/local-jev/build-candle-patched.sh
native/local-jev/target/candle-scheduling/release/local-laya \
  --bundle "$BUNDLE" --diagnostic-scores --framed
```

To use this build in the playground, set `VERA_LAYA_CLI` to the absolute
path of the patched CLI before starting the server.

For an embedded OpenHarmony archive, use the linker configuration from the
OpenHarmony build above and an absolute path for `BUNDLE`.

```sh
LAYA_BUNDLE_DIR="$BUNDLE" tools/local-jev/build-candle-patched.sh \
  --target aarch64-unknown-linux-ohos --lib
```

The patched archive is in
`native/local-jev/target/candle-scheduling/aarch64-unknown-linux-ohos/release/liblocal_jev.a`.
Use an ordinary release build for the stock control.

In a matched M4 Pro replay of seven Cycle 2 requests, the warm total fell from
19.59 s to 7.28 s. All 45 choices, logits, and truncation records matched.
The median for one 64-token choice fell from 116 ms to 39 ms.
The patched phone run is pending.
