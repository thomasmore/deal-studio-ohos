# Changelog

## Fix miscellaneous errors

- Fixed warm launches from the widget, shortcuts and the launcher icon no longer navigating: `navigateToProject()` had been moved inside `extractDevParameters`, which returns early for app callers, so the route queued by `extractProjectId` in `onNewWant` was never drained. It is now called explicitly at the end of both `onCreate` and `onNewWant`, after both extracts, and `extractDevParameters` no longer touches navigation — which also stops `hdc shell aa start` launches from queueing their route twice.
- `DeepSeekEngine.stop()` now destroys the in-flight HTTP client itself through a new idempotent `disposeClient()` instead of depending on a callback inside `runOperation`. The callback and `runOperation`'s `finally` still call it, and `cleanup(client)` keeps its identity guard so a stale stream cannot tear down a newer round's client. Behavior is unchanged when the callback is intact, but `stop()` is no longer silently broken if that callback is moved or removed.
- `VeraPreview` drew a standalone `ui.Path` (outside a Canvas) with a fixed `.scale({x: 2.4, y: 2.4})`, which left the shape at 1/density of its band on any screen whose density was not 1. It now scales by `this.getUIContext().vp2px(PATH_BAND_HEIGHT) / 100` - the same density-crossing formula the canvas branch uses - and the band height (240 vp) is a named module constant `PATH_BAND_HEIGHT`, shared by the scale and the band's `height()`.
- Fixed incomplete generation-metric cleanup after **New**: a shared `resetRunMetrics()` now clears attempts, timing, side calls, stages, service health, tool logs, and trouble notes immediately, and is reused by generation and model-refinement entry points. New also clears the status; refinement preserves cumulative and accepted-version metrics. Added three host regression checks for reset completeness, idempotence, and shared entry-point behavior. All 25 Generate checks, metric checks, and the unsigned ArkTS build passed.

## Development launch parameters are accepted only from a native caller

This entry records a security hardening of `EntryAbility`, found while reviewing the code against HarmonyOS 7.0 (API 26.0.0). It is a handoff reference for people and AI agents, not a release certification. It does not change the shortcut, widget, or project-launch behavior.

Behavior was checked on the host and on the device; see "Verification". File paths are repository-relative.

### Summary

- `EntryAbility` is exported and used to apply development launch parameters from `want.parameters` without checking who started it. They are now applied only when no app started the ability; `hdc shell aa start … --ps …` works as before.
- Added `entry/src/main/ets/components/LaunchTrust.ets`, which decides who the caller is from the identity keys the ability manager writes into `want.parameters`.
- Navigation parameters (`projectId`, `launchMode`, `veraRun`) are unchanged and still accepted from any caller.

### 1. What was exposed

`EntryAbility` is `exported: true` (the launcher, shortcuts, and the widget start it), and it read the following parameters from any caller. Comments claimed they were "reachable only from a shell on the device", which does not hold for an exported ability.

- Keys: `deepseekKey`, `typesafeKey`, `exaKey`, `reasoningEffort`.
- The generation server: `veraServer`. It is persisted, and Server mode executes the bytecode the server returns.
- Probes that call adapters with the app's system permissions: `probeTarget`, `probeParams`, `probeMode`, `probeSdkTarget`, `probeSdkParams`, `probeSdkSearch`.
- Benchmark and evaluation triggers: `veraBenchmark`, `veraSdkEval`, `veraUiEval`, `veraUiAb`.
- Behaviour flags: `veraCompose`, `veraComposePlan`, `veraCustom`, `veraAlign`, `veraWhole`, `veraTemplateSelect`.

### 2. The change

- `LaunchTrust.ets` exports `startedByApp`, `presentDevParameters`, `describeCaller`, and `DEV_PARAMETER_NAMES` (21 names). `startedByApp` is true when `ohos.aafwk.param.callerBundleName` or `ohos.aafwk.param.callerAppId` is non-empty, or `ohos.aafwk.param.callerUid` is 10000 or higher. The ability manager writes these keys and replaces what a caller puts there. A native caller such as the shell's `aa` tool carries none of them.
- `EntryAbility` calls `extractProjectId` directly and all development extractors through the new `extractDevParameters`, from both `onCreate` and `onNewWant`. For an app caller no development extractor runs and a warning lists the parameter names (never the values) and the caller. For a native caller the extractors run as before, with an info log when development parameters are present.
- The rule is "an app identity means ignore" rather than an allowlist of bundle names: it cannot lock out the shell workflow if `aa` carries no identity, and bundle-name-only checks are discouraged.
- The comments in `EntryAbility.ets`, `IntentProbe.ets`, `VeraSearchBenchmark.ets`, and `VeraSdkProbe.ets` no longer claim these paths are shell-only by construction.

Main files: `LaunchTrust.ets`, `EntryAbility.ets`.

### 3. Verification performed

- The decision logic was tested on the host with node on 18 cases: shell with and without a native name, root uid, another app with bundle and uid, app id only, app uid only (also as a string), a launcher caller, missing and null parameters, an empty bundle name, the dev names found in a hostile want, and the list contents (21 unique names, none of them navigation names).
- The patched `EntryAbility.ets` parses, and each extractor is still called once.
- ArkTS build; the positive device test (`aa start` with `--ps deepseekKey …` and the expected `native caller` log line).
- Not performed: the negative test from a second app (a start with `veraServer` must log "Ignored development launch parameters" and leave the settings unchanged).

### 4. Known limitations

- Whether `aa` on the target HarmonyOS 7 build arrives without an app identity is not verified. If it carries one, development parameters are ignored and the warning log shows the caller.
- Any other native or root process is still trusted.
- Values persisted before this change are not reset. If an earlier build was exposed, check `veraServer` and the keys in `{filesDir}/vera/settings.json`.
- Unchanged: `veraServer` is still persisted and may be `http://`, and the keys are still stored in plain text in `settings.json`.

### 5. Handoff rules for future changes

1. Add a new development launch parameter only inside `extractDevParameters`, and add its name to `DEV_PARAMETER_NAMES`. Do not read development parameters in `onCreate`, `onNewWant`, or anywhere else.
2. Keep side effects out of the navigation parameters; they are accepted from any caller and may only open a project.
3. Log parameter names, never values.
4. Do not replace the check with a bundle-name allowlist. After changing the check, and after each OS update, repeat the positive and negative tests above.
5. Do not describe an exported entry point as shell-only. Review other entry points (extensions, new exported abilities) the same way.

## Preview lifecycle and stale effect replies

- `VeraPreview.aboutToAppear()` resets `disposed` before registering listeners and loading the program, allowing the same component instance to work when it appears again.
- Each program load and component disappearance advances a separate effect generation and clears queued effects, pending consent, and the old host's pending effects. Loading also releases the old host, including when the bytecode is empty or invalid; UI identity remains independent of effect generation.
- Both successful and failed asynchronous effect replies are delivered only while the component is active and their captured generation is still current. Disposed components no longer dispatch actions, process consent, drain queues, or launch effects.
- Added 34 host regression checks for reappearance, program replacement, empty and invalid bytecode, preview reconciliation, queue cleanup, stale replies, and current-generation replies. Already-sent system actions are not cancelled; their stale replies are ignored. Device lifecycle behavior has not been verified.

## Chat and generation cancellation

- Added request-scoped cancellation: Stop cancels the active chat or generation without interrupting independent requests or a newer run.
- Cancellation aborts supported network requests, stops queued work, closes pending questions, and rejects late results and preview updates. Chat drafts, completed widgets, and the last successful generation remain intact.
- Added host regression tests for cancellation, overlapping requests, and screen disposal.
- Fixed tickers retaining an outdated handler when their ID and interval stayed unchanged: each tick now uses the latest handler without restarting the timer or resetting its phase. Added host regression coverage for handler changes and timer lifecycle cleanup.
- Project deletion now reports filesystem errors instead of silently succeeding, ignores only an already-missing directory, and removes the project directory before updating the index so failed removal remains retryable. Added 25 host regression checks for deletion, error propagation, cache invalidation, and retries.

## Navigation and kit imports

- Replaced app page-router navigation with a single `AppShell`, shared `Navigation`/`NavPathStack`, and `NavDestination` screens. External launches replace the stack while preserving isolated shortcut launches, widget launch behavior, and mini-app Back handling.
- Bound navigation readiness to the active window stage and shared storage; hidden or removed screens ignore stale asynchronous updates.
- Surface frame loops now follow `NavDestination.onShown` / `onHidden` instead of router-page events, pausing covered Generate, Runner, and Chat previews and resuming when shown. Previews created while hidden honor that state before loading, and late frames do no work while hidden. Added 22 host regression checks for visibility propagation, initialization, and pause/resume with both display sync and the interval fallback.
- Migrated application imports from `@ohos.*` to named `@kit` exports, preserving aliases. Updated SDK backend generation and host mocks, added explicit socket result types, and switched remaining Generate animations to scoped UI APIs.

## Shortcut processing

### Desktop shortcuts and launch behavior

- Added one home-screen shortcut per mini-app, identified by `vera_project_<projectId>` and the owning bundle. Shortcuts belong to mini-apps, not individual versions.
- A shortcut launches the newest saved version with compiled bytecode. The project/version IDs remain unchanged, preserving the program's saved-state identity.
- Shortcut launches open an isolated, full-screen Runner without VERA's title bar or navigation into other sections. A mini-app's own BackHandler retains priority; otherwise Back closes the ability.
- Tapping VERA's main icon restores the project list and normal window/navigation mode. Tapping another mini-app shortcut replaces the isolated Runner instead of accumulating navigation history. Ordinary foreground/resume does not reset the current page.
- Missing projects and projects without runnable bytecode show an isolated error screen rather than opening the library. Launch routing rejects stale asynchronous work when another launch or window-stage change supersedes it.
- Added separate 72×72 PNG resources for all ten project icons, including the default phone fallback. `shortcutFor()` sends these resources as base64 PNG in `foregroundIcon`; original UI icons remain unchanged.

### System state, launcher IPC, and operation safety

- Removed persisted `pinned` state. Legacy values are ignored and disappear on the next normal index write; shortcut presence is read from the system using both shortcut ID and owning bundle.
- The project page shows checking, retry, add, and remove states, with `Adding…`/`Removing…` progress labels. Initial display performs a single refresh, and stale responses from hidden pages or older refreshes are ignored.
- Add/remove actions are idempotent against actual system state. `ProjectOperations` owns asynchronous SDK/launcher calls, per-project operation locks, and error handling; `ProjectStore` remains synchronous persistence.
- Desktop creation/removal uses SceneBoard's private launcher service rather than assuming a BMS-only record creates a visible desktop icon. Results are verified against the system shortcut list; launcher updates may change this private interface.
- Launcher requests time out after ten seconds with `launcher did not answer`, releasing operation locks and UI pending state. Completion cancels the timeout, repeated callbacks are harmless, and a late connection does not send a new request after settlement.
- Result verification uses increasing pauses totaling approximately 5.6 seconds, followed by a final state query before reporting failure. Query errors remain errors, not evidence that a shortcut is absent.
- Host context is resolved lazily inside the service error boundary and explicitly checked for `null`/`undefined` before launcher access. The owning bundle name is cached only after a successful lookup; failed lookups remain retryable.
- Native error details are logged by the service; UI callers receive operation statuses and user-facing messages. Missing projects return to the project list rather than leaving an empty project page.

### Deletion and partial success

- Deleting a mini-app, or its last remaining version, attempts to remove the mini-app's shared shortcut. Shortcut-removal failure is best-effort and no longer blocks data deletion.
- A completed deletion with unsuccessful shortcut cleanup returns `ProjectDeletedShortcutRemovalFailed`; both deletion entry points warn that the mini-app was deleted but its home-screen icon could not be removed.
- Deleting an ordinary version does not remove the mini-app's shortcut. Version lists and project existence are rechecked after asynchronous work, including when another version is saved while deletion is pending.
- Explicit **Remove shortcut** remains a verified operation: failure is reported without deleting project data. Storage failures are not converted into shortcut-cleanup warnings.
- Confirmation for last-version deletion explains that the mini-app and its saved data will be deleted and that shortcut cleanup will be attempted. Lists and widgets refresh after deletion attempts, including failures.

Main files: `entry/src/main/ets/vera/ProjectOperations.ets`, `entry/src/main/ets/vera/ProjectStore.ets`, `entry/src/main/ets/vera/ProjectIcons.ets`, `entry/src/main/ets/entryability/EntryAbility.ets`, `entry/src/main/ets/pages/Index.ets`, `entry/src/main/ets/pages/ProjectPage.ets`, `entry/src/main/ets/pages/RunnerPage.ets`, and `entry/src/main/resources/base/media/project_icon_*_72.png`.

Validation included host tests for launch routing, system-state handling, context validation, timeouts, polling, and best-effort deletion. Full-screen launch behavior was confirmed on the device; later hardening changes were checked on the host without another build or installation. These checks do not certify compatibility with future launcher versions or eliminate existing filesystem-cleanup limitations in `ProjectStore`.

## SDK 26 compatibility, version provenance, and saved metrics

This entry records the work covered by the development session: platform and deployment compatibility work, followed by version/refinement tracking and persistent generation metrics. It is a handoff reference for people and AI agents, not a complete history of the application or a release certification.

Some SDK migration work was brought in from upstream and reconciled with this branch; it was not all newly authored during the session. Existing data-preservation safeguards were retained and strengthened rather than introduced from scratch. File paths below are repository-relative. Consult the target branch's current workflow instructions before executing build or device commands; this document intentionally does not replace or modify `README.md` or `CLAUDE.md`.

### Summary

- Consolidated SDK 26 build compatibility, scoped ArkUI APIs, native module typing, and selected SDK adapter fixes.
- Filtered deprecated SDK adapter candidates and preserved native error semantics in targeted handlers.
- Associated saved versions with their full accepted request history and explicitly selected base version.
- Kept the last successful source, bytecode, request, and metadata together after failed or cancelled refinements.
- Added persistent per-version metric snapshots without inheriting the base version's costs.
- Added a dedicated version Metrics window and redesigned version actions as a horizontal row.
- Restyled saved metrics with the same tile-based visual language as Generate's Metrics tab.
- The project's main **Run** button now selects the newest version with compiled bytecode. A note identifies the selected version when newer versions need compilation; if none are compiled, Run is disabled with an explanation.
- Added **Cancel/Delete** confirmation dialogs for mini-app and individual-version deletion, warning that deletion is irreversible. Deleting the only remaining version explicitly warns that the entire mini-app and its saved program data will also be deleted.

### 1. SDK 26 and platform compatibility

#### ArkUI context and native bindings

- Adapted affected screens and the renderer to component/window-scoped UI APIs for navigation, host context, media queries, unit conversion, and dialogs.
- Added explicit handling for unavailable host contexts and rejected navigation promises in affected paths.
- Supplied explicit local storage for the widget entry component.
- Added a local declaration package for `libllama.so`, covering its native generation, embedding, scanning, and build-information interfaces. The ArkTS wrapper uses the typed native import instead of maintaining a separate cast-based interface.

Main files: `entry/src/main/ets/components/VeraPreview.ets`, affected files under `entry/src/main/ets/pages/`, `entry/src/main/ets/entryability/EntryAbility.ets`, `entry/src/main/ets/widget/pages/WidgetCard.ets`, `entry/src/main/cpp/types/libllama/index.d.ts`, `entry/src/main/ets/vera/LlamaEngine.ets`, `entry/oh-package.json5`.

#### Audio, capability checks, and resource cleanup

- Adapted volume, mute, and ringer implementations to the supported audio manager interfaces while keeping existing adapter addresses.
- Reworked PCM output around the renderer's `writeData` callback, with timeout and callback/resource cleanup.
- Added or restored capability checks for affected SDK adapters, audio/media operations, and embedding-model downloads.
- Improved failure handling for unavailable embedding downloads instead of allowing an unhandled failure to escape.
- Hardened chat/settings file writes so opened files are closed in `finally`. A cleanup failure does not replace an earlier write failure.

Main files: `entry/src/main/ets/vera/VeraSdkBackend.ets`, `entry/src/main/ets/vera/VeraCapabilities.ets`, `entry/src/main/ets/vera/ChatStore.ets`, `entry/src/main/ets/vera/SettingsStore.ets`.

### 2. SDK adapter generation and targeted warning fixes

- Updated backend generation to resolve capability requirements from live SDK declarations and exclude matching deprecated-only declarations.
- Kept a compatible live overload when one exists; missing or ambiguous live capability metadata remains an error rather than a guessed mapping.
- Removed the deprecated `PerformanceAnalysisKit.hidebug.dumpJsHeapData` adapter and updated associated selection/index metadata. The distinct `dumpJsRawHeapData` adapter remains; it is not treated as an equivalent replacement.
- Added targeted lexical error handling around calendar selection and camera/permission paths while preserving native error identity.
- Preserved the calendar answer convention: native failures become `error: [code: ]message`; a native void completion reported as `ok` is not independent proof that state was persisted.
- Added regression coverage for deprecation selection and synchronous/asynchronous calendar failures.

Main files: `tools/generate-sdk-backend.py`, `tools/sdk-backend-deprecation-check.py`, `tools/vera-harness/calendar-sdk-check.js`, `entry/src/main/ets/vera/VeraCalendarSdk.ets`, `entry/src/main/ets/vera/VeraSdkBackend.ets`, and the associated SDK selection/index metadata.

These are targeted fixes, not a claim that every SDK warning was eliminated. Terminal warning filtering must not be confused with fixing the underlying API or permission requirement. Do not restore excluded `systemTimer` adapters during unrelated backend regeneration.

### 3. Version request history and refinement provenance

Main files: `entry/src/main/ets/vera/ProjectStore.ets`, `entry/src/main/ets/pages/GeneratePage.ets`, `entry/src/main/ets/pages/ProjectPage.ets`.

#### Saved version fields

| Field | Meaning |
| --- | --- |
| `prompt` | Full readable request history for the accepted result: the base request plus successfully applied refinements on this branch. |
| `lastPrompt` | The most recent request/refinement included in that accepted result. |
| `parentVersionId` | ID of the explicitly selected saved base version; empty when starting without a saved base. |
| `note` | Short version-list label, not a replacement for the full request. |
| `metrics` | Optional saved metric snapshot described below. |

- The store explicitly writes and reads these fields and preserves them when replacing a version's bytecode.
- Existing files remain readable without a migration. A missing `prompt` falls back to the old note; a missing `lastPrompt` falls back to the available prompt; a missing parent ID stays empty.
- Old branch history is not reconstructed or invented from truncated notes.

#### Refinement behavior

- Per-version **Refine** loads the selected version, not whichever version happens to be latest.
- The selected source is supplied as the previous program, and accepted request history is included in the model context for the current change.
- The UI identifies the selected base and the new version that Save will create, displays the accepted request, and uses refinement-specific input labels.
- Missing or unusable selected bases block generation instead of silently switching to another base.
- **New** clears the base relationship, accepted history, result metadata, and saved-metrics snapshot for a new task.
- Server refinements use the server path and send the previous source together with the request history.

#### Accepted-result integrity

- Pending requests are promoted to accepted history only when a usable result is accepted.
- Source and compiled bytecode are kept as a matching successful pair. A failed candidate may still be visible during generation, but Save does not pair that candidate with older successful bytecode.
- Failed or cancelled refinements leave the previous successful code/request pair available for saving.
- Accepted composition/origin metadata is retained with that pair instead of being taken from a later failed candidate.
- Async run guards prevent stopped or superseded requests from accepting stale results in the affected model/server callbacks.
- A server response without both source and bytecode is rejected as a replacement result.
- Saving requires a successful source/bytecode pair; a broken source-only result is not saved through this path.

### 4. Persistent metrics for each saved version

A `VersionMetrics` object is stored inside the version JSON. Opening the saved version later restores this snapshot; this does not resume generation or reconstruct a full execution trace.

| Field | Meaning |
| --- | --- |
| `provider` | Generation mode/provider label captured for the work; `Mixed` when modes differ. |
| `model` | Captured model label where available; `Mixed` when model labels differ. |
| `elapsedMs` | Accumulated wall time within the recorded runs. |
| `runs` | Number of submitted generation/refinement runs in the recorded work. |
| `attempts` | Counted model/server generation attempts, including retries; not a count of every internal compile or selector call. |
| `inputTokens` | Measured input-token total where available. |
| `cacheHitTokens` | Measured cached input tokens, already included in input tokens. |
| `outputTokens` | Measured output-token total where available. |
| `estimatedUsd` | Available estimated cost for the priced, measured portion of the work. |
| `partial` | Conservative indication that the snapshot is not complete usage/billing accounting. |

#### Accounting boundaries

- Metrics describe work in the current generation page/session up to the last accepted result, including measured retries and earlier failed work on the way to that result.
- Costs and counters from a saved base version are **not** added to the new version.
- Several successful refinements before Save can contribute to one snapshot.
- Later failed or stopped changes do not overwrite the snapshot of the previously accepted code. If further work later succeeds, accumulated work can enter that newer accepted snapshot.
- Starting a new task resets the per-version metrics accumulator.
- Available side-call usage is collected without counting the same observed call twice.
- Cancellation and overlapping stale work can leave accounting incomplete; the implementation marks the data conservatively rather than claiming exact billing.

#### Unknown values and cost limitations

- Unknown numeric usage/cost values use `-1`, not a fabricated zero. The UI displays **No data**.
- Old versions without a snapshot retain `metrics: null` and show **Metrics were not saved for this version**.
- Parsing rejects non-finite/negative numeric values as unavailable and preserves a partial-data indication.
- Estimates use the existing `deepseek-flash` rate schedule only for the recognized official DeepSeek endpoint. Other models/endpoints and local/server generation are not assigned guessed prices.
- Multi-round generation currently lacks a complete cache-hit total for pricing. Its generation cost is not calculated from an incomplete cache figure; measured side-call costs may still be available.
- A displayed cost can therefore cover only part of the recorded work. It is an estimate, not a provider invoice.
- Current snapshots are conservatively marked partial; absence of a warning must not be assumed from positive token counts alone.
- Detailed attempt records, stage timings, source deltas, and token-stream timing are **not** persisted in this snapshot. Generate's live Metrics view can show more detail than the saved-version view.

### 5. Version list, source viewer, and Metrics presentation

- Moved per-version actions out of the right-hand column into a full-width bottom row: **Run · Refine · Src · Metrics**.
- Kept the version number, note, and creation time above the actions. Run is disabled when compiled bytecode is unavailable.
- Corrected Src headings to use the displayed version ordinal rather than the internal ID.
- Made the full version request and source scroll together while the heading and Close action remain outside the scrolling content.
- Added a separate Metrics window for each version, independent of the source viewer.
- Replaced the initial plain-text metrics presentation with tiles for time, estimated cost, runs, attempts, and token counts, plus provider/model labels and colored section headings.
- Matched Generate's Metrics visual language: light panel, white tiles, prominent values, short explanatory labels, and an explicit partial-data notice. The saved view uses its own builders; it is not the entire live Generate dashboard embedded in the version list.
- Retained clear empty/unknown states rather than drawing unavailable measurements as zero.

Main file: `entry/src/main/ets/pages/ProjectPage.ets`.

### 6. Handoff rules for future changes

1. Treat accepted source, bytecode, request history, composition/origin, and metrics as one coherent result. Do not replace part of that result with data from a failed candidate.
2. Preserve explicitly selected parent IDs. Displayed version numbers are list ordinals, not durable IDs or a substitute for provenance.
3. Keep version parsing backward-compatible. Preserve the added fields in every manual version-JSON rewrite path.
4. Do not turn unknown metrics into zero, inherit base-version costs, or present measured partial costs as total lifetime spending.
5. Do not synthesize historical stage/attempt details for old snapshots. Add new persisted fields explicitly if richer saved dashboards are required.
6. Do not weaken update/signing safeguards or add machine paths, real device IDs, API keys, or exported personal prompts to the repository.
7. Raw version exports can preserve the JSON snapshot; there is no separate metrics sidecar. Unsaved generations are not exported.
8. Read the target branch's current build instructions before validation. Use unsigned builds when only compilation is requested; do not silently expand the task to device installation.
