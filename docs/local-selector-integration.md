# Experimental local selector integration

The experimental local selector supplies generation and structural-edit decisions on the host and phone.
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
- `local_jev_predict` refuses the shared-state Q8 and Laya Q4 profiles. Use the
  `local_jev_experimental_decisions` C API for experimental answers.
- Replies retain raw logits. Laya replies also retain token truncation records. Decisions are marked
  diagnostic, uncalibrated and `productionAllowed:false`. Choice confidence is not
  claimed to be calibrated; existing caller option filters still apply.

## Model baseline

The host and the default embedded archive use the checked-in mmBERT shared-state
Q8 bundle. Readiness reports model ID `mmbert-shared-state-q8-experimental`
and manifest SHA-256 `4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5`.
[Bundle assets and terms](../tools/vera-playground/models/mmbert-shared-state-q8/README.md)

[Rebuild and benchmark the shared-state Q8 selector from public mmBERT-small](local-jev-shared-q8-reproduction.md)

Follow the playground guide to select the public Laya Q4 bundle or the
separately supplied Cycle 2 bundle. Keep all four assets together.
Use an explicit Laya bundle for the serial and batched phone benchmark.
[Laya Q4 bundle instructions](../tools/vera-playground/README.md#select-a-laya-q4-bundle)

## Host generation

Set `VERA_TYPESCRIPT_PATH` if TypeScript is not installed in this checkout.
For shared-state Q8, unset `VERA_LAYA_CLI` and `VERA_LAYA_MANIFEST`.
Build the default release CLI first.

```sh
cargo build --locked --release --manifest-path native/local-jev/Cargo.toml \
  --bin local-jev-shared
# requests.tsv contains label<TAB>English request
ARKESTR_API_KEY="$DEEPSEEK_API_KEY" node tools/vera-harness/agent-run.js \
  -s local -p requests.tsv -o /tmp/local-generation -j 1
```

No `TYPESAFE_API_KEY` is required. The standalone harness installs the application
adapter (`tools/local-jev/host-selector.js`), keeping the Rust model warm. Other host
entry points can install the same adapter, then call `VeraSelector.askSelector` or
`VeraComposition.selectEdit`; close it when finished. The playground retains its
persistent-worker IPC for comparisons. Both transports use Rust's same policy.

For Laya on the host, build the Laya runner and archive first.
Export `VERA_LAYA_MANIFEST="$BUNDLE/laya-manifest.json"` to select that bundle.
Run the same standalone generation command.
[Laya host build and verification](../native/local-jev/README.md#build-a-laya-q4-host-archive)

## Phone build and opt-in

Configure the SDK and run the build command for the selected model.
[SDK setup](../native/local-jev/README.md#build-for-arm64-openharmony)
[Default Q8 archive](../native/local-jev/README.md#build-the-default-q8-archive-for-openharmony)
[Laya Q4 archive](../native/local-jev/README.md#build-a-laya-q4-archive-for-openharmony)

Set the explicit archive path and build the HAP. CMake also accepts
`VERA_LOCAL_JEV_ARCHIVE` through its `-D` arguments.

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

## Distribute a shared-state Q8 HAP

Distribute the Q8 HAP and model notices together. Run these commands from the repository root.
Set `HAP` to the absolute path of the existing Q8 HAP.

```sh
HAP=/absolute/path/to/vera-probe-dyn-signed.hap
BUNDLE="$PWD/tools/vera-playground/models/mmbert-shared-state-q8"
ARCHIVE="$PWD/.local-jev/vera-shared-state-q8-hap.tar.gz"
mkdir -p .local-jev
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$(dirname "$HAP")" "$(basename "$HAP")" \
  -C "$BUNDLE" NOTICE GEMMA-TERMS.md prohibited-use.md LICENSE-MMBERT-MIT
tar -tzf "$ARCHIVE"
```

The archive listing includes the HAP and all four notice and license files.

## Selector metrics

`SelectorMetrics.ets` records every `askSelector` invocation under its operation owner,
including initial choice, later verification, structural edits, surface edits and
widget generation. It stores no prompts, answers or credentials. Finished UI/log
records are snapshots: a cancelled operation's late native/HTTP completion cannot
rewrite another run. The local model's eager preparation outside a run is not
charged as inference time; preparation awaited inside a selector call is included.

The Metrics tab separates **Writer model calls** from **Selector calls**. Selector
rows name Local Jev (experimental), TypeSafe Jev or Cloud LLM Jev approximation,
show batch wall time, answered/requested question counts and actual HTTP attempts
(including proxy retries). Local calls show **$0 API cost** and zero HTTP requests;
this does not mean cloud planning/writing is free. Sub-50ms and even zero-rounded
selector calls are retained. Coarse agent Jev stages are replaced, not added to,
with the measured boundary totals. `compose.jevMs` now sums all selector phases;
`initialJevMs` preserves the earlier initial-selection-only diagnostic.

Run-log records retain `modelCalls` as the total invocation count and add
`writerCalls`, `selectorCalls`, `selectorMs`, `selectorHttpRequests` and
`localSelectorCalls`. Selector usage/cost is added once to run/version totals with
its own tariff, never priced as writer tokens. TypeSafe estimates use $0.042/M
input and free output; the approximation uses reported chat-completions usage and
the existing official DeepSeek Flash peak/off-peak tariff. Other endpoints, missing
usage and incomplete attempts remain **unknown/partial**, not free. These are
published-rate estimates, not invoices. Writer cost is hidden for unpriced models.
A failed proxy noul request is no longer counted as a confident negative answer.

## Verification

Run these checks without downloading a model or setting API keys.

```sh
node tools/vera-harness/selector-metrics-check.js
node tools/vera-harness/metrics-check.js
```

The selector-metrics check uses fake native/HTTP transports for all three providers,
fast/later phases, retries, missing usage, tariffs, uncertainty, cancellation and
operation isolation. `prompt-check.js` executes the real controller's finalization
and run logging, including repeated finish and unknown-cost regression cases.

```sh
cargo test --locked --manifest-path native/local-jev/Cargo.toml
node tools/vera-harness/local-selector-check.js
node tools/vera-harness/selector-settings-check.js
node tools/vera-harness/composition-check.js
node tools/vera-harness/needs-choose-check.js
node tools/vera-playground/check.js
node tools/vera-playground/prompt-check.js
```

Run these checks with the release runner and checked-in bundle. The checks use
fixtures for cloud replies.

```sh
node tools/local-jev/integration-check.js
node tools/vera-playground/laya-check.js
node tools/vera-playground/pipeline-check.js
```

The integration check runs standalone generation without TypeSafe credentials, then
sends a structural-edit request through the real application boundary and model.
The C ABI probe checks readiness, guarded prediction, diagnostic logits, and
experimental decisions. Use the ABI commands for the selected model.
[Host C ABI probe](../native/local-jev/README.md#verify-the-host-c-abi)
[OpenHarmony C ABI probe](../native/local-jev/README.md#verify-the-openharmony-c-abi)

## Compare serial and batched inference

Cross-link `tools/local-jev/device-bench.c` with an arm64 archive that embeds Laya.
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

Omit the mode to call the app's experimental C entry point. With a Laya archive,
this calls the serial scorer. With the default archive, it calls the shared-state scorer.

## Qualification still required

Prior phone runs used Laya Q4. They covered generation, NAPI loading, repeated
requests, and Settings persistence. The verification report records the public
Laya and Cycle 2 results.
[Laya verification report](local-selector-verification.md)

The shared-state Q8 host CLI and embedded C ABI matched the saved reference
reply for a request with 22 questions. The OpenHarmony Rust archive cross-build
succeeded and contains the exact pinned assets. Q8 HAP loading and phone
inference still require verification.

Phone structural-edit UI, cancellation under native load, app-level peak memory,
and extended responsiveness still require verification. Record the exact bundle
and input policy for each run.

Before production: independently human-label representative requests, split by task
family/run to prevent leakage, evaluate raw accuracy, fit calibration and abstention
on a separate set, and freeze/test the policy on held-out examples. Do not tune on
`needs-plan-25`. Poor ranking requires better inputs or training, not just thresholds.
Only a separately accepted release may change the production prediction guard.
