# Local selector integration: verification record

Branch: `integrate/local-jev`, based on PR #62 commit
`37369aa41743ca2baafbd625d7af82181f8ff217`.
These are functional checks, not human quality or calibration evidence.

## Model and environment

- Public `convaiinnovations/laya-multilingual`, pinned checkpoint revision
  `1720e3e3357cfe1e281542e223f8273b0890ca34`.
- Public Q4 bundle: 216,489,817 bytes. Manifest SHA256:
  `ba9e8c447454ce42b942948138066a7bc8ebe8f92527e512c7c25010e9148ee0`.
  The manifest records checkpoint, quantizer and asset hashes.
- Rust 1.95.0, Node 26.8.1, OpenHarmony SDK 26, Linux x86_64 host.
- Python export dependencies isolated in ignored `.local-jev/venv`.
- OHOS Rust target: `aarch64-unknown-linux-ohos`.
- No credentials, model weights or absolute machine build paths added to tracked code.

## Passed

- Rust tests: two existing option-budget tests and four new experimental-policy tests;
  one existing real-model test ignored by default.
- Host app-boundary check: generation, structural edits with no TypeSafe key,
  readiness, unavailable model, inference failure, no proxy/TypeSafe fallback,
  pre-call cancellation, discarding a cancelled in-flight result, original cloud default.
- Existing host checks: needs-plan, needs-choose, agent, composition, surface-route.
- Playground HTTP and automatic-prompt checks.
- Full real-model playground pipeline check: shared-plan provenance, matched-request
  replay, persistent worker reuse/restart, token-budget uncertainty, provider failure,
  no-TypeSafe local generation and shutdown cleanup.
- Actual public-model playground check: two requests, shared-plan verification,
  real worker reused, compiler/VM preview path; cloud replies are fixtures.
- Standalone host integration check: local generation uses the app adapter rather
  than comparison IPC, with TypeSafe credentials absent; actual structural-edit
  selection through `VeraComposition.selectEdit` selects removal of the note.
  Cloud writer replies are fixtures, not live calls.
- Host embedded C ABI smoke check: guarded normal prediction, two finite diagnostic
  calls, model readiness, experimental decisions retaining scores and warnings.
- Rust OHOS cross-build, with the public bundle embedded.
- Unsigned HAP builds: unavailable stub and model-bearing variant. Model-bearing
  HAP is approximately 276 MiB; linked `liblocaljev.so` approximately 231 MiB.
- Same model-bearing C ABI smoke executable ran on the connected aarch64 phone,
  transferred to `/data/local/tmp/vera-local-jev-abi-check`; no app installation,
  uninstall, data clearing or bundle identity change was performed.
- `cargo fmt --check`, modified-JS syntax checks and `git diff --check`.

## Local artifacts

These files are development-machine artifacts, not checked into the repository:

- Standalone host integration report: `/tmp/local-jev-integration-c20YAu/report.json`.
- Public-model playground report: `/tmp/vera-laya-e2e-1uTj9F/report.json`.
- HTTP report: `/tmp/vera-playground-check-MbJIbd/report.json`.
- Auto-prompt report: `/tmp/vera-fresh-prompts-fNEpMg/report.json`.
- Full pipeline report: `/tmp/vera-playground-pipeline-gaKemF/report.json`.
- Device ABI output: `/tmp/local-jev-device-abi.log`.
- Host ABI output: `/tmp/local-jev-abi-check.log`.
- Model-bearing unsigned HAP:
  `/tmp/vera-local-jev-embedded-hap/vera-probe-dyn-unsigned.hap`.

## Numerical observation, not a quality endorsement

For the synthetic request “Track expenses by category”, with `chart` and `timer`
options, **both host and phone chose timer**, which is not the sensible selection.
The smoke check tests ABI/scoring, not correctness.

- Host logits: chart -3.3314645290, timer -2.0706362724.
- Phone logits: chart -3.3390727043, timer -2.0665822029.
- Host timer probability: 0.7791686546; phone: 0.7811687826.

Thus the shared policy and bundle produce the same choice here, but quantized
inference is not bit-identical across CPUs. A future acceptance test must define
numerical tolerances and examine near-tie decisions.

## Known unrelated baseline failure

`widget-launch-check.js` expects WidgetCard's launch parameters to contain
`veraRun: '1'`; the PR base's unmodified WidgetCard uses `launchMode: 'runLatest'`.
That check fails independently of this integration. No widget code was changed to
satisfy the stale assertion.

## Subsequent authorized phone update and live generation

At the user's explicit request, installed the model-bearing build using
`update-phone.sh`. Both the initial update and a subsequent bridge fix verified
unchanged app identity/UID/first-install time. No uninstall or data clearing.

Actual NAPI loading, readiness and generation work with live cloud writer calls and
local experimental selection. Four English prompts compiled and rendered:

| App | Total | Local selection | Observed result |
|---|---:|---:|---|
| Tip calculator | 92.7 s | 90.5 s, 22 questions | Incorrect: correct tip/total, but per-person copies tip and people input is dropped. |
| Packing checklist | 118.2 s | 36.6 s + 64.0 s | Rendered a split extra-items log/starter list; three immediate calls failed before bridge fix. |
| Countdown timer | 31.5 s | 29.7 s, 10 questions | Started and decremented 5:00 to 4:56; Stop paused at 4:55. Extra Minutes input dropped, but built-in countdown-length control exists. |
| Empty shopping checklist | 110.0 s | 15.6 + 10.4 + 7.7 + 65.0 s | After bridge fix, four consecutive selector calls succeeded. Added Milk, checked it (count 0 to 1), deleted it (both counts returned to 0). |

Fixed a NAPI continuation race found during live use: release the native busy flag
**before** resolving the deferred promise. ArkTS can resume the awaiter inline and
issue the next selector call before `napi_resolve_deferred` returns. The follow-up
shopping run had no immediate local-inference failures.

Saved explicitly named new test apps `Local Jev test - Countdown` and
`Local Jev test - Shopping`. Existing projects were not used as test targets.
Evidence: `/tmp/local-jev-phone-runs/summary.json`, `runs.jsonl`, UI layout dumps,
screenshots and `update-bridge-fix.log`. Full trace remains on the device and was
copied before filtering; it contains unrelated historical runs and is private.

App RSS sampled during generation: about 1.46 GiB; final sampled RSS 1,517,196 KiB
(about 1.45 GiB). This is not a measured peak. The system emitted a memory-leak debug
signal/report while expanding the token embedding during load; the app remained
alive and completed subsequent inference. This is a significant footprint, not a
claim that the signal proves an actual leak or a crash.

## Cycle 2 phone comparison (standalone C ABI)

Replayed the exact recorded tip-calculator request (22 questions) on the connected
aarch64 phone, using separate OHOS executables linked to each embedded bundle.
Harness: `tools/local-jev/device-bench.c`. Both use the existing serial experimental
policy. Force-stopped the installed app to avoid holding a second model in RAM;
ran public then Cycle 2 sequentially with a 30-second inter-model pause. Relaunched
the installed app afterward; no app install or data changes.

| Metric | Public base Q4 | Cycle 2 Q4 |
|---|---:|---:|
| Model status/load call | 3.978 s | 2.544 s |
| Inference 1 | 104.671 s | 36.850 s |
| Inference 2 | 104.257 s | 39.752 s |
| Inference 3 | 99.245 s | 39.537 s |
| Median inference | 104.257 s | 39.537 s |
| Process peak RSS (`VmHWM`) | 1,315,208 KiB | 373,432 KiB |
| Final process RSS | 1,184,240 KiB | 258,508 KiB |

Cycle 2 is **2.64x faster** by median inference and uses **71.6% less peak RSS**
in this test. These are whole native-runner process numbers, not ArkUI app totals.
Load includes bundle validation/model initialization but is not a guaranteed
filesystem-cold measurement. Inference excludes that load call. Three repetitions,
fixed order, and normal background phone activity are not a controlled thermal
benchmark or a broad workload average.

All calls returned diagnostic decisions; answers were stable across each model's
three repetitions. Cycle 2 still selected `unavailable` for all three expression
questions, matching the host's top choices. Public retained incorrect per-person
`copy:tipAmount:`. This demonstrates performance, not accepted generation quality.

Bundle extracted from the user-supplied `mmbert-small-cycle2-q4.tar.gz`; all three
asset hashes verified against its manifest. Architecture: 13 encoder layers,
width 384, embedding rank 96; two decision-head layers. Bundle 49,259,697 bytes.
It reports application training/compression/fine-tuning provenance but contains no
training scripts/data, evaluation report or license file. Human calibration and
production flags remain false. Public bundle and original phone installation
remained unchanged during benchmarking. The ignored OHOS archive build output now embeds Cycle 2; a
future rebuild must set `LAYA_BUNDLE_DIR` explicitly to select the desired model.

Evidence: `/tmp/local-jev-cycle2-device/{request.json,public-output.txt,cycle2-output.txt,summary.json}`.
Request SHA256: `331a00713c887fd696edee15f66c13fb26f9064cc5af378779add0f87959c8df`.
Cycle 2 manifest SHA256: `cb01cbb7ca3e25f27e71c88e4d644714725b52f054d709b03c0721f102ee6acd`.

## Cycle 2 installed-app update

Subsequently installed Cycle 2 at the user's request via `update-phone.sh` with
the Cycle 2 OHOS archive. Build: zero diagnostics; signed HAP about 117 MiB.
Update completed in 33 seconds and verified unchanged identity and first-install
time. Relaunched with trusted `--ps localJev 1`; Settings confirms
`Local experimental: experimental / uncalibrated` (loaded, not unavailable).
The saved-project list still includes both named test apps and existing projects.
No new full generation was run as part of this installation.
Evidence: `/tmp/local-jev-cycle2-device/update-phone.log`, `settings-layout.json`.
USB network is off after an update and must be re-enabled if needed.

## Three-way demo selector settings

Replaced the Jev proxy switch with Settings > Jev selector radio rows: TypeSafe,
LLM approximation, Local experimental. Explicit choice persists in settings.json;
legacy proxy configuration migrates, TypeSafe remains the fresh-install default.
Provider-specific availability checks require the selected provider's credentials
or actual local readiness. Local preparation runs on selection and saved-local
startup. No automatic selector fallback was introduced.

Host checks passed: `selector-settings-check`, `local-selector-check`,
`needs-choose-check`. ArkTS build: zero diagnostics. Verified in-place phone update
in 31 seconds. Exercised each radio row and force-stopped/relaunched without launch
parameters after every selection: all three persisted and restored correctly.
Left the phone on Local experimental; Cycle 2 loaded successfully after restart.
This UI verification did not make new live TypeSafe/LLM generation requests.
Evidence: `/tmp/local-jev-cycle2-device/update-selector-settings.log`,
`selector-settings-layout.json`, `selector-{typesafe,llm,local}-{selected,restarted}.json`.

## Updated Candle scheduler and batching: phone measurements

Fast-forwarded the integration worktree to `66f0b272ce1f991af6787ad277fba7a6666fe5df`.
Built stock and optionally patched Candle 0.9.2 OHOS archives with the same Cycle 2
bundle and cross-linked the updated `device-bench.c` against each. No app update.
Stopped the installed app during tests and relaunched it afterward.

Protocol: `RAYON_NUM_THREADS=8`; each configuration starts a separate process,
loads the model, performs one excluded warmup and three measured inferences.
Twenty-second pauses between configurations. Fixed order: stock single serial,
single batched, multi serial, multi batched; then the same order for patched.
The multi request is the same saved 22-question tip-calculator request used above;
the single request retains its state and only its first question (`asked.billAmount`,
135 tokens). These are two matched workloads, not a representative quality suite
or a counterbalanced thermal benchmark.

Median measured wall time (excludes model initialization):

| Request | Stock serial | Stock batched | Patched serial | Patched batched |
|---|---:|---:|---:|---:|
| Single question | 1.072 s | 1.061 s | 0.544 s | 0.545 s |
| 22 questions | 31.270 s | 34.194 s | 16.967 s | 17.423 s |

Scheduler speedup in serial mode: **1.97x** single, **1.84x** multi.
Batching is **9.4% slower** than serial with stock scheduling and **2.7% slower**
with patched scheduling on the multi request; it should not be enabled on the
basis of this run. All answers, raw logits and truncation records matched exactly
across configurations, including warmups and repetitions (max logit difference 0).
This preserves the model's existing unsuitable formula choices, not correctness.

Multi-request median preparation: stock serial 10.026 ms; patched serial 10.186 ms.
Median forward phase: stock serial 31,256.885 ms; patched serial 16,954.071 ms.
This confirms model execution dominates; state tokenization is not the remaining
bottleneck. Initialization ranged 2.451–2.562 s. Process peak RSS stayed within
373,292–373,488 KiB (about 365 MiB); multi final RSS was about 251 MiB.
No memory benefit from scheduling is claimed.

The earlier 39.537 s result used a different thread configuration/environment;
31.270 s is the matched stock control here. During this benchmark the patched
archive was not installed into the app; it retained its stock Cycle 2 build until
the subsequent installed-app demonstration below.

Evidence: `/tmp/local-jev-scheduler-device/summary.json`, eight per-configuration
JSONL outputs, stock/patched build logs, and local orchestration script.
Single request SHA256: `39a634a351a305ab5bcb85e38d7239e12b0f11a62e47a74c0d441f775aa0b2e3`.
Multi request and bundle hashes match the earlier Cycle 2 comparison above.
Rust tests passed after the fast-forward. No Qwen source/runtime was added by these
updates; this measurement covers Cycle 2 only.

## Patched Cycle 2 installed-app demonstration

At the user's request, installed the patched Candle OHOS archive with Cycle 2 via
`update-phone.sh`; zero diagnostics, verified in-place identity/first-install time,
32 seconds, no uninstall or clearing. Enabled local selection and generated:

> A countdown timer with adjustable minutes, start, pause and reset buttons, and remaining time.

First-attempt composition compiled with no omitted parts in **21.030 seconds**.
Two local diagnostic selector calls: **11.304 s** (10 questions), **4.576 s**
(1 question), **15.880 s** total. Planning/code writing still used the configured
cloud model; this is not the shared Qwen prototype or all-local generation.
The UI Metrics view attributed only the first selector phase to Jev (11.3 s), so
its model/Jev breakdown understates total local work; the trace is the source for
the 15.880 s total. Do not interpret the remaining 5.150 s as measured cloud CPU
or network time; it is simply wall time outside those two calls.

On-device actions: Start decremented 5:00 to 4:56; Stop held 4:56 across two dumps
three seconds apart; Reset restored 5:00 and 100%. Pause is labeled Stop in the
actual generated UI. Saved a new project **Local demo - Patched Cycle 2**,
verified it in My apps, reopened its project and tapped Run. Left the saved app
open on the phone. Existing projects were not edited.

Evidence: `/tmp/local-jev-patched-demo/` (filtered run trace, paused/still-paused/reset
layout dumps, saved project/library layouts, final screenshot). Private historical
trace was not published. Install log:
`/tmp/local-jev-scheduler-device/update-demo.log`.

## Still not verified

- Phone structural-edit end-to-end UI (host structural selection is tested).
- Guaranteed filesystem-cold load timings, app-level peak memory and extended responsiveness tests.
- Phone cancellation under sustained native load.
- Exhaustive behavior for each generated app, quality calibration or production acceptance.

The installed app now uses this PR-based build; the user's original working tree
and its unrelated uncommitted multi-screen source changes remain untouched.
