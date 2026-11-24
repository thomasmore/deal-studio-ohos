# Experimental local selector integration

Local Laya can supply generation and structural-edit decisions on the host and phone.
This is developer-only, uncalibrated selection, **not offline generation**. Planning,
section fill, custom code and model refinement still use the configured cloud writer.
Cloud defaults are unchanged. No local selector failure triggers TypeSafe or the
cloud proxy, even when their credentials are present. Existing generation holes and
model-refinement routes can still run after an unsupported decision; those are writer
fallbacks, not a cloud selector fallback.

## Boundaries

- `VeraSelector.ets` is the application's transport boundary. `VeraCompose.askJev`
  delegates to it; `VeraComposition.selectEdit` uses it directly.
- Local takes precedence over both existing selector backends. `SettingsStore.hasSelector`
  checks actual loaded-model readiness in this mode, not presence of a TypeSafe key.
- `LocalJev.ets` loads asynchronously, reports readiness and discards cancelled results.
  A failed initial load stays unavailable for that process; restart after fixing the build.
- `napi_local_jev.cpp` copies input before queueing async work, bounds native work to
  one operation, and frees Rust-owned replies. In-flight model execution is not
  interrupted on cancellation: its result is discarded, and another native call can
  report busy until the current call completes.
- Rust owns the experimental temperature-1 softmax, finite-score/type/option validation,
  deterministic ties, and warnings. No separate ArkTS/JS probability conversion exists.
- `local_jev_predict` remains guarded for Laya. Experimental answers require the explicit
  `local_jev_experimental_decisions` C API or `--experimental-decisions` CLI flag.
- Replies retain raw logits and token truncation records. They are always marked
  diagnostic, uncalibrated and `productionAllowed:false`. Choice confidence is not
  claimed to be calibrated; existing caller option filters still apply.

## Model baseline

Follow `tools/vera-playground/README.md` to export the public pinned Q4 bundle.
Keep all four assets together. Cycle 2 remains an optional, separately supplied bundle.
The public bundle is 216,489,817 bytes; its token embeddings expand in memory, so
bundle size is **not** a runtime-memory estimate.

The [shared Qwen archive and Mac example](../tools/vera-playground/README.md#run-the-shared-qwen-prototype-on-a-mac)
use a separate CLI for UI selection and formula generation. Use the Laya-compatible
manifest for the NAPI build and phone benchmark below.

## Host generation

Set `VERA_TYPESCRIPT_PATH` if TypeScript is not installed in this checkout.
Set `VERA_LAYA_MANIFEST` to an absolute manifest path if not using
`.local-jev/bundle-q4/laya-manifest.json`. Build the release CLI first.

```sh
cargo build --locked --release --manifest-path native/local-jev/Cargo.toml \
  --bin local-laya --bin laya-quantize
# requests.tsv contains label<TAB>English request
ARKESTR_API_KEY="$DEEPSEEK_API_KEY" node tools/vera-harness/agent-run.js \
  -s local -p requests.tsv -o /tmp/local-generation -j 1
```

No `TYPESAFE_API_KEY` is required. The standalone harness installs the application
adapter (`tools/local-jev/host-selector.js`), keeping the Rust model warm. Other host
entry points can install the same adapter, then call `VeraSelector.askSelector` or
`VeraComposition.selectEdit`; close it when finished. The playground retains its
persistent-worker IPC for comparisons. Both transports use Rust's same policy.

## Phone build and opt-in

Cross-build the embedded Rust archive using the SDK commands in
`native/local-jev/README.md`, setting `LAYA_BUNDLE_DIR` explicitly to the selected
public or separately supplied Cycle 2 bundle directory.
Then build with an explicit archive (or set `VERA_LOCAL_JEV_ARCHIVE` through CMake's
`-D` arguments):

```sh
export VERA_LOCAL_JEV_ARCHIVE="$PWD/native/local-jev/target/aarch64-unknown-linux-ohos/release/liblocal_jev.a"
./build-hap.sh --unsigned
```

The path must exist and must match the app ABI. Without an archive the NAPI module
is still packaged but reports `archive_not_linked`. For an incremental switch from
an embedded build to the stub, set `VERA_LOCAL_JEV_ARCHIVE=''` explicitly; the explicit
environment value overrides a stale CMake cache. Some build wrappers sanitize their
environment; if so use the module's `externalNativeOptions.arguments` CMake `-D` option
locally rather than committing an absolute machine path.

Use the repository's system signing and **in-place update** workflow. Never uninstall,
clear data or change bundle identity. Do not replace an app containing newer unrelated
work merely to test this PR base.

```sh
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps localJev 1
# Disable local through a trusted launch parameter:
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps localJev 0
```

The phone's **Settings > Jev selector** now offers **TypeSafe**, **LLM approximation**
(configured cloud model through JevProxy), and **Local experimental** (embedded model).
This explicit choice persists across restarts and applies to generation and structural
edits. The page shows missing credentials and local loading/readiness; the local option
is labeled uncalibrated. Generation-provider settings are separate. There is no automatic
selector-provider fallback. Older saved `jevProxy` settings migrate to LLM approximation;
otherwise TypeSafe remains the default. Existing launch parameters still work, but only
from trusted native callers; another app cannot change the selection through them.
The selected local model is prepared asynchronously at startup or when chosen.
Generate and Settings show the experimental status. Local unavailability blocks
generation rather than silently bypassing selection.
Requests and raw replies are captured as `selector` events
in the existing `vera/trace.jsonl`, including the bundle-manifest hash. Logs may contain
personal prompt/context data; do not publish them without review.

## Verification

No model or keys needed:

```sh
cargo test --locked --manifest-path native/local-jev/Cargo.toml
node tools/vera-harness/local-selector-check.js
node tools/vera-harness/selector-settings-check.js
node tools/vera-harness/composition-check.js
node tools/vera-harness/needs-choose-check.js
node tools/vera-playground/check.js
node tools/vera-playground/prompt-check.js
```

With the release runner and public bundle (cloud replies are fixtures):

```sh
node tools/local-jev/integration-check.js
node tools/vera-playground/laya-check.js
node tools/vera-playground/pipeline-check.js
```

The integration check runs standalone generation without TypeSafe credentials, then
sends a structural-edit request through the real application boundary and model.
The existing C ABI check now verifies readiness and experimental decisions as well
as guarded prediction and diagnostic logits. Cross-compile it with the OHOS archive
to run the same probe via `hdc` without replacing the installed app.

## Compare serial and batched inference

Cross-link `tools/local-jev/device-bench.c` with the embedded arm64 archive.
Send the executable and a saved request to the phone with `hdc file send`.
Use the same executable, request bytes, and thread count for both modes.

```sh
hdc shell 'chmod +x /data/local/tmp/device-bench'
hdc shell 'RAYON_NUM_THREADS=8 /data/local/tmp/device-bench /data/local/tmp/request.json 5 serial' > serial.jsonl
hdc shell 'RAYON_NUM_THREADS=8 /data/local/tmp/device-bench /data/local/tmp/request.json 5 batched' > batched.jsonl
```

Each explicit mode starts a fresh process, reports model load, and warms up once
before the measured calls. Include one single-question request and a saved
multi-question request. The benchmark response retains choices, logits, and
truncation metadata under `response.response`. The benchmark fields under
`response.benchmark` report unpadded sequence lengths per group and two
timings. Preparation covers parsing, tokenization, validation, and sorting.
Forward covers model input tensor creation, model execution, and marker scores.
Compare winners and logits by question and option ID. Use the highest
`peak_rss_kib` in each run for process peak memory. On macOS this field comes
from `getrusage`. On OpenHarmony it comes from `VmHWM`.

Omit the mode to use the original serial C export and its existing output.
The app uses its existing serial export.

## Qualification still required

See `docs/local-selector-verification.md` for actual host, installed-app and device
measurements, including known incorrect selections. Phone generation, NAPI loading,
repeated requests and Settings persistence have been exercised. Phone structural-edit
UI, cancellation under native load, app-level peak memory and extended responsiveness
still require verification. Record the exact bundle and input policy for each run.

Before production: independently human-label representative requests, split by task
family/run to prevent leakage, evaluate raw accuracy, fit calibration and abstention
on a separate set, and freeze/test the policy on held-out examples. Do not tune on
`needs-plan-25`. Poor ranking requires better inputs or training, not just thresholds.
Only a separately accepted release may change the production prediction guard.
