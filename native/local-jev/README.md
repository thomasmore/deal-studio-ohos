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

## Integrated experimental adapter

The developer-only bridge is implemented in `entry/src/main/cpp/napi_local_jev.cpp`,
with `liblocaljev.so` types, async readiness and experimental decision calls.
`VeraSelector.ets` routes both generation and structural edits through it when
Settings > Jev selector is Local experimental (or a trusted native launch supplies
`--ps localJev 1`). The demo choice persists across restarts. Cloud defaults and guarded regular
prediction remain unchanged. See [integration and verification](../../docs/local-selector-integration.md)
for the actual build, host usage, cancellation limits and remaining device checks.

The C ABI also exposes `local_jev_status` (loads the model off-thread) and
`local_jev_experimental_decisions` (uncalibrated temperature-1 answers plus raw scores).
The host CLI's matching flag is `--experimental-decisions`. The Rust implementation
owns this policy on both platforms; neither adapter calibrates or enables production.

## NAPI wiring reference

The integrated test module is linked in
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

The bridge copies UTF-8 input before queuing work, calls the experimental Rust API
on a worker, copies and frees the returned string, and resolves its promise on the
completion thread. `LocalJev.ets` discards cancelled results. Native work is bounded
to one operation; cancellation does not interrupt an already-running inference.
The type package and dependency are included:

```typescript
export const status: () => Promise<string>
export const experimentalDecisions: (request: string) => Promise<string>
```

Both entry points feed the application's common selector boundary:

- Generation and component selection use `host.askJev` in
  [AgentAppHost.ets](../../entry/src/main/ets/vera/agent/AgentAppHost.ets)
  and `askJev` in
  [VeraCompose.ets](../../entry/src/main/ets/vera/VeraCompose.ets).
- Structural edits send the body built by `buildEditRequest` in
  [VeraComposition.ets](../../entry/src/main/ets/vera/VeraComposition.ets).
  It now uses the same `VeraSelector.askSelector` transport as generation.
- [GeneratePage.ets](../../entry/src/main/ets/pages/GeneratePage.ets)
  checks `settings.hasSelector()` before these paths; in experimental local mode
  that checks the loaded model's readiness rather than cloud credentials.

Experimental replies are explicitly uncalibrated and not production-approved.
Existing option filters and empty-answer behavior remain. DeepSeek still handles
plans, section content and custom code. Unavailable local decisions remain local:
there is no cloud selector fallback.

Verify HAP loading, cancellation and warm inference on the target phone before
relying on the integrated experimental route. Production remains separately gated
on human evaluation, calibration and release acceptance.
