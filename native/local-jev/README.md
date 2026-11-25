# Embed the local selector in the OpenHarmony app

The Rust static library embeds the same mmBERT shared-state Q8 bundle that
`local-jev-shared` reads from the repository. Readiness reports the model ID
and manifest SHA-256. The shared-state and Laya Q4 profiles expose scores
for the app's JSON `state` and `questions` through the experimental C API.
Regular prediction returns an empty answer map for both experimental profiles.

Keep the tokenizer notice, Gemma terms, prohibited-use policy, and mmBERT
license with distributions that include the shared-state bundle.
[Bundle assets and terms](../../tools/vera-playground/models/mmbert-shared-state-q8/README.md)
[Q8 HAP distribution](../../docs/local-selector-integration.md#distribute-a-shared-state-q8-hap)

## Verify on the development machine

Run the commands from the repository root. Build the archive for the model
you want to verify.

### Build the default Q8 host archive

```sh
env -u LAYA_BUNDLE_DIR -u JEV_BUNDLE_DIR cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib
```

### Build a Laya Q4 host archive

Set `BUNDLE` to the absolute directory with the four Laya Q4 bundle files.
The command builds the host runner and the embedded archive.
[Laya Q4 bundle instructions](../../tools/vera-playground/README.md#select-a-laya-q4-bundle)

```sh
BUNDLE=/absolute/path/to/laya-q4
env -u JEV_BUNDLE_DIR LAYA_BUNDLE_DIR="$BUNDLE" cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib --bin local-laya
```

`JEV_BUNDLE_DIR` selects the existing legacy BERT prediction bundle.
Only one bundle variable can be set for each build.

### Verify the host C ABI

Link the probe again after each change of model.

```sh
mkdir -p .local-jev
cc -I native/local-jev/include tools/local-jev/abi-check.c \
  native/local-jev/target/release/liblocal_jev.a -lpthread -ldl -lm \
  -o .local-jev/abi-check
```

Run `.local-jev/abi-check` for shared-state Q8.
Run `.local-jev/abi-check --laya` for Laya Q4.

The check verifies ABI version 1, guarded prediction, finite diagnostic scores,
and experimental decisions. For Q8, it also verifies the pinned manifest.
Readiness and scoring use the same loaded model.

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
```

### Build the default Q8 archive for OpenHarmony

```sh
env -u LAYA_BUNDLE_DIR -u JEV_BUNDLE_DIR cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib \
  --target aarch64-unknown-linux-ohos
```

### Build a Laya Q4 archive for OpenHarmony

Set `BUNDLE` to the absolute directory with the four Laya Q4 bundle files.

```sh
BUNDLE=/absolute/path/to/laya-q4
env -u JEV_BUNDLE_DIR LAYA_BUNDLE_DIR="$BUNDLE" cargo build --locked --release \
  --manifest-path native/local-jev/Cargo.toml --lib \
  --target aarch64-unknown-linux-ohos
```

Both commands write the archive to
`native/local-jev/target/aarch64-unknown-linux-ohos/release/liblocal_jev.a`.
Each app ABI needs its own Rust target and archive.

### Verify the OpenHarmony C ABI

Link the probe with the archive for the selected model.
Transfer it to the phone and set its executable permission.

```sh
mkdir -p .local-jev
"$CC_aarch64_unknown_linux_ohos" -I native/local-jev/include tools/local-jev/abi-check.c \
  native/local-jev/target/aarch64-unknown-linux-ohos/release/liblocal_jev.a \
  -ldl -lm -o .local-jev/abi-check-ohos
hdc file send .local-jev/abi-check-ohos /data/local/tmp/vera-local-jev-abi-check
hdc shell chmod +x /data/local/tmp/vera-local-jev-abi-check
```

Run `hdc shell /data/local/tmp/vera-local-jev-abi-check` for shared-state Q8.
Run `hdc shell /data/local/tmp/vera-local-jev-abi-check --laya` for Laya Q4.

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
The host uses `local-jev-shared` for shared-state Q8 and
`local-laya --experimental-decisions` for Laya. Both use the same Rust policy for
experimental decisions.

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
