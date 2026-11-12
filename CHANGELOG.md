# Changelog

## Worker Thread backend: Stage 1

### Step 1

- Establishes baselines before runtime extraction: temporary, opt-in `StageTrace` instrumentation records the existing preview's VM execution, input, snapshots, frames, saves, effects, field queues, tickers, surfaces and lifecycle decisions. Tracing is off by default, enabled only by trusted native launch parameters; state, tree and effect payloads are represented by digests.
- Deterministic headless capture/compare (`runtime-baseline.js`) uses fixed time and seeded randomness for state restoration, decoded UI trees, GfxOps, representative handlers and queued effects. Coverage now includes retained documentation examples, ten-tap and ten-tick sequences, text/slider/toggle inputs and selected bytecode from an existing local export. The captured corpus has 49 cases: 48 successful and one recorded compile failure in the stale `docs/examples/shanghai-layover.vera`; the failure remains an explicit coverage gap.
- Comparable full-sequence traces cover 16 mocked orchestration scenarios (`stage-trace-check.js`) and 9 real-VM input scenarios with 191 events (`visual-check.js`), including debounce, synthetic IME completion, slider drafts, ticker gates, surface gestures and stale dependency cancellation. The latter execute the current compiler, VM, UI decoder and reconciliation through extracted renderer methods and callbacks, with platform APIs and storage mocked; neither artifact establishes native orchestration equivalence.
- Added 13 host timing workloads (`runtime-performance.js`), diagnostic only, and an external private artifact package (`offline-baseline.js`) with source provenance, SHA-256 integrity, coverage gaps and read-only comparison. Capture and comparison passed with the selected local corpus, as did the tooling self-tests, eight relevant VM/renderer regression suites, JavaScript syntax checks and `git diff --check`. This baseline run did not perform ArkTS/SDK validation.
- Execution remains on the UI thread; no worker or actor extraction yet. Coverage is explicitly incomplete: demo prompts are inventoried, not generated or mapped to executable fixtures, and selected local bytecode does not prove a complete device catalogue. Native orchestration, lifecycle/IME/consent checks, surface work timings and tap-to-render latency remain pending on a device; host timings do not establish the device regression budget.

## The moving part, learnt from the app's own animation

- Make widget runs the app's own frames (as they are, else after a touch or a button), compares its drawing frame by frame, and finds the shapes that turn and the point they turn about (`VeraMovingPart`).
- A widget that turns the whole picture in a `ui.Motion`, or moves nothing, is refused with those shapes and the pivot in the widget's own units, and asked for `gfx.moving`.
- On the phone, five of six widgets made for pendulums, wheels, a windmill and a ferris wheel moved only their part. See `docs/live-widget-proof.md`.
- `examples/widget-wheel.vera` now draws its card picture with a `gfx.moving` wheel. Host checks in `widget-refine-check.js`; `examples/widget-pendulum-frames.vera`.

## Many of the same: gfx.repeat

- `gfx.repeat(columns, rows, dx, dy, shapes)` draws shapes in a grid (bubble wrap, bricks, a grid of stars). It is written once: a card picture counts its shapes once, while the app's frame limit counts every copy. At most 400 copies in one repeat, and at most 400 shapes painted in a card picture.
- The card's 60-shape refusal names gfx.repeat, and so does the prompt. On the phone, bubble wrap reached the card as a 10 x 10 sheet whose bubbles pop.
- Make widget tries a touch at several points of a picture before it calls a touch unseen: the middle of a grid can fall between two bubbles. It also logs an attempt that got no answer from the model.
- Host checks in `gfx-check.js`, `live-widget-check.js`, `widget-refine-check.js`; `examples/widget-bubbles.vera`.

## Wheels of slices: gfx.sector

- `gfx.sector(x, y, radius, start, sweep, colour)` draws a filled pie slice (angles as `gfx.arc`): a wheel of fortune, a pie chart or a pizza is sectors, not stroked arcs or polygons.
- The Make widget prompt shows the pattern of moving parts in eight lines (a pendulum's rod and bob swinging from the top, a wheel of sectors spinning under a pointer that stays); the game prompt says a wheel is sectors.
- On the phone, 1 of 5 toy widgets used sectors (a pizza, drawn right on the card) and none used `gfx.moving`; see `docs/live-widget-proof.md`. Host checks in `gfx-check.js` and `widget-refine-check.js`.

## Always moving: gfx.drift

- `gfx.drift(direction, speed, shapes)` is a tile the size of the picture that slides on and on and comes back in from the other side: clouds, fish, rain, snow, stars. On a home-screen card it is the one thing that moves without a touch, played by the platform's Swiper in slices (a card's own script stops a couple of seconds after a redraw); in the app it moves frame by frame.
- Measured on the phone first: the Swiper kept going (see `docs/live-widget-proof.md`), about 4 % of a core while on screen, nothing off screen.
- Host checks in `gfx-check.js` and `live-widget-check.js`; `examples/widget-sky.vera`.

## A widget tap finishes what it started

- After a tap on a card, the app's own clock (frame handlers and running tickers) runs for up to 20 s until the state comes to rest, so a wheel stops on its prize and its Spin button comes back (what a frame asks of the phone, such as a vibration on each tick, is dropped); a state that does not come to rest (a game playing on) stays as the tap left it.
- Make widget refuses a button a tap leaves off for good, a picture that does nothing on the card although the app's does, and a picture whose touch shows nothing (no movement, the same card after it), with the reason for the model.
- The prompt says a scene on a 2x4 card is drawn wide.
- Host checks in `live-widget-check.js` and `widget-refine-check.js`; `examples/widget-wheel.vera`.

## Moving parts: gfx.moving, about the part's own pivot

- `gfx.moving(style, trigger, pivotX, pivotY, shapes)` marks the part of a drawing that moves (a pendulum's bob, a wheel, a frog): it plays a ui.Motion preset about its own pivot while the rest of the picture stays. A touch on the picture plays every part.
- On a card the picture is split at its parts into layers of the same box, each part in a Motion that turns and scales about its pivot; in the app the parts are posed frame by frame from the same preset table.
- New presets `launch` (out of sight and back from below) and `roll` (away and back).
- Make widget refuses a ui.Motion around a scene with a background and asks for the moving thing as a part; a ui.Motion around a picture with parts is dropped.
- Host checks in `gfx-check.js`, `live-widget-check.js`, `widget-refine-check.js`, `motion-check.js`; `examples/widget-pendulum.vera`.

## Light and depth in pictures: gradients, glow, shadow, blur, blend; a cover picture on the card

- `std/gfx` draws more than flat fills: `gfx.linear` and `gfx.radial` are colours any shape takes (a lit ball, a sky), and `gfx.glow`, `gfx.shadow`, `gfx.blur` and `gfx.blend` hold shapes like a group. One painter draws them in the app, on the home-screen card and in the host's SVG proofs; their sizes follow the picture's scale. The compiler checks a gradient's literal colours and the blend modes.
- `ui.Surface("cover", ...)` on a card is its background, edge to edge, with the rest of the widget over its bottom on a veil of the card's colour; in the app it draws as `fill`. One per widget, not in a row or a ui.Layers.
- Make widget's prompt and the game prompt say how to give a picture depth and light, and when to use a cover picture.
- Measured on the phone first (what a card draws, what it may use, what keeps moving after its script stops): `docs/live-widget-proof.md`. Host checks in `gfx-check.js` and `live-widget-check.js`; `tools/vera-harness/examples/widget-rich.vera`.

## Remove widget

- The project page's widget block has Remove behind a swipe to the left, as a version's Delete (the block is the first row of the versions list, its buttons in one row like a version's Run / Refine / Code): the latest version is saved again without its widget, its refresh and what only they use (`WidgetRemove.ets`, on `withoutWidget`), with the app's state carried over and the widget's requests left out of its history. Earlier versions keep theirs.
- Preview, the block's first button (blue, as a version's Run), and a tap on the thumbnail open the card at its own size with the 2×2 / 2×4 / 4×4 chips, over the app's saved data; taps there are not saved.
- Cards already on the home screen stay (only the launcher removes them) and show "Open app"; the confirmation says so.

## Make widget: Redo

- A widget that is there could only be changed: the model was shown the program with it, so every request was an edit of it. The project page's widget block now has Redo beside Refine (it said Change; Refine is what a version's own button says). It opens the widget screen as New widget: the next widget is written from nothing, on the program without the old one (`withoutWidget`: widget, widgetRefresh and the helpers, classes and imports only they used) and without what it was asked to show in the history the model is told the app was made for (`withoutWidgetRequests`; with it, the model made the old widget again), with the first widget's requests. Measured on the phone: Redo on Roulette, whose widget is a spinning wheel, with Winning number gave a figure card on the first answer. The screen starts from an empty card; the old widget stays on the home screen until a new one is made and kept.
- Host check in `widget-status-check.js`.

## Settings from every screen

- The gear is on every screen that has a title bar (the home screen, My apps, a project, Generate and the widget screen, Chats, a chat, the app list for a card) and opens one Settings page (`SettingsPage.ets`, `components/SettingsEntry.ets`). It used to be on Generate only, as a panel over the page, with the USB network under Advanced.
- The page: how apps are generated (the cloud provider with its model and key, Server, On the phone), what is missing for the one chosen and the command that supplies it, the dashscope model picker, Jev proxy and USB network as switches.
- The generation mode is kept (`settings.json`, `mode`); it used to start as the cloud provider on every Generate page. Generate reads it again when it is shown.

## The widget from the app: a widget block on the project page, ready-made requests, the offer after Save

- The project page has a Home-screen widget block: a thumbnail of the card, what it is now (`WidgetStatus.ets`: not made, not on the home screen, on it, the card shows "Open app" because the latest version has no widget, cannot be made) and the one next thing to do (Make widget, Add, Refine).
- A new app, just saved, offers Make widget; Widget from the app on screen saves it first and opens the widget screen, one tap where Save and Make widget were two.
- The widget screen offers ready-made requests made from the app itself (`agent/WidgetSuggest.ets`: its state's figures and lists, the actions its buttons take, Let VERA choose), says whether the last request made, changed or left the card as it was (`sameCard`), and has one button: Add to home screen, Update widget or Show on this card.
- A card placed from the launcher with no app yet opens a list of apps; one with no widget opens Make widget for that card.
- Host check `widget-status-check.js`.

## ui.Layers: scenes of parts that move on their own

- New `ui.Layers(style, width, height, children)`: children one over another, each in the middle. Surface style `clear` has no background so layers show through. A touch on any part plays every Motion in the Layers; a touch on a Motion with no handler plays it (`#touch`). Up to 5 pictures and 5 Motions on a card. Make widget's prompt says how to build a scene from layers.
- The Widget tab redraws at once when the card size chip changes (the picture size was stale).

## ui.Motion: 25 presets by meaning, played in stages on the card

- New presets: pulse, jelly, press, flash, breathe, nod, wobble, swing, recoil, hop, jump, fall, spin, turn, rise, zoom, slide, float, drift (with pop, shake, bounce, tumble, flip, fade: 25). Each is a table of stages (`VeraMotion.motionStages`); the app and the card play the same table, the card as a chain of platform animations. All 25 play on a card; up to five Motions at once.
- Make widget's prompt names every preset by what the movement means and asks that a touchable picture move.
- Host check: `motion-check.js` verifies every table.

## Widget card: sizes 2x2, 2x4, 4x4 and switches

- The live card is offered at 2x2, 2x4 and 4x4; `onAddForm` records the size (`form-sizes.json`), the frame is fitted to it and the limits grow with it (`cardSize`). A widget may declare `widget(state, size: number)` to draw differently; Make widget checks it at every size. The Widget tab has size chips.
- The frame goes into the binding compact (only non-default fields), so the 8000-character budget goes about twice as far.
- `ui.Toggle` and `ui.Checkbox` are card kinds: a tap that says on or off, handler `(state, value: boolean)`.

## ui.Timer: a time that moves, in the app and on the card

- New component `ui.Timer(style, millis, down)`: counts up from a moment or down to one with the platform's own `TextTimer`, which keeps going on a home-screen card where our code does not (no refresh, no ticker). The theme's text styles apply; the Make widget prompt says to use it for "since" and "left until".

## Widget card: icons, badges, progress, stats and a sparkline

- `ui.Icon`, `ui.IconButton`, `ui.Badge`, `ui.Progress`, `ui.ProgressRing`, `ui.Stat`, `ui.NumberStat`, `ui.MetricGroup` and `ui.Sparkline` are card kinds: icons in the theme's colours, the platform's own bar and ring, labelled figures, and a small trend. An icon button counts as one of the two buttons. The Make widget prompt describes them.

## Widget card: the theme's styles, one layout, up to three pictures and Motions

- The card draws the catalogue's styles as the app does: text roles (display, title, heading, caption, eyebrow, metric, muted, success, warning, danger) with the theme's weight, font and ink, column and row alignment and density, panels (`surface`, `accent`), all four button styles, the divider in the theme's colour (`CardStyle.ets`). Sizes a widget already had are unchanged. Make widget refuses a widget clearly taller than the card.
- `CardView.ets` is the one layout the launcher's card and the Widget tab share (it was two copies kept in step by hand); `GfxPaint.ets` holds the painter without the interpreter. A widget may have three pictures and three Motions, each touch playing the Motion its node sits under.
- Spike results on what else a card can draw (live `TextTimer`, `Progress`, `Gauge`, `SymbolGlyph`, gradients, shadows; not `DataPanel`; `Image('memory://')` blanked the card) and the card sizes are in `docs/live-widget-proof.md`.

## Make widget: a drawing of several colours that reacts to a touch, found by a real generation

- A generated panda used to come out as a one-colour blob that never moved. The prompt now says a drawing of more than one colour is a `ui.Surface`, never a `ui.Path` (the catalogue's Path text said "use it whenever the user asks to draw something"); a card's `ui.Motion` plays on every touch on its picture by itself, with no counter in the state (`touches`, and `seq` in the tap's frame, so a touch that changes nothing still plays); the picture is sized to the room the rest of the card leaves, and a widget that leaves it under 40 vp is refused with a reason.
- Make widget now logs each attempt and what the model wrote (`VERA-WIDGET attempt N answer ...`, `served`/`failed: ...`).
- The Widget tab draws the card at 150 vp, as measured (it was 172, which hid clipping).

## A picture of several colours on the home-screen card: ui.Surface

- A card can show a still picture made of `std/gfx` shapes (a panda, an animal, a gauge), which one `ui.Path` (one colour) could not. `ui.Surface` is a card kind in a static form: its draw function runs once for the state in the form extension, the shapes ride in the frame (`encodeGfxOps`), and `LiveCard` / `WidgetPreview` draw them with the app's own `paintGfx` on a `Canvas`, in the widget's theme. At most one picture of 60 shapes, no frame handler.
- A tap on the picture goes to the program's pointer handler as a finger down and up at that point (`WidgetSession.tapSurface`, `liveFormTap`); with `ui.Motion` around it the picture jumps when touched.
- Make widget's prompt describes it; a picture that takes a tap counts as one of the two buttons and is checked like one.
- Host checks in `live-widget-check.js` and `widget-refine-check.js`; example `tools/vera-harness/examples/widget-panda.vera`.

## A drum that moves when it is hit: ui.Motion on the home-screen card

- `ui.Motion` is a card kind with the presets a card can play (pop, shake, bounce, fade), one per widget. The card frame carries `style` and `trigger`; `LiveCard` and `WidgetPreview` start the Motion in its hit pose when the trigger changes and settle it in `onAppear` (a card cannot loop: `iterations` is not allowed there and a card is frozen about two seconds after a redraw; measured on a phone, see `docs/live-widget-proof.md`).
- The Make widget prompt describes it (a count in the state as the trigger) and says what a card cannot do; `ui.Motion` styles a card cannot play, and a second Motion, are refused with a reason for the repair loop.
- A shape on the card (and in the Widget tab) is no longer outlined in black: `Path` is given a transparent stroke in `LiveCard` and `WidgetPreview`.
- Host checks added to `live-widget-check.js` and `widget-refine-check.js`; example `tools/vera-harness/examples/widget-drum-motion.vera`.

## TextField input buffering and commit lifecycle

This change moves `ui.TextField` from per-keystroke VM execution to field-local buffering with deferred commits. Its purpose is to keep ordinary text editing responsive while avoiding repeated VM execution, state persistence, and view reconciliation for every character.

### 1. Per-field input buffer

- Each `ui.TextField` maintains its own pending edit state. Typing in one field does not reset or overwrite the debounce timer or buffered value of another field.
- Every text change updates the local field buffer and restarts a **400 ms debounce timer**.
- If no further input arrives for 400 ms, the latest buffered value is committed. Intermediate values from the same uninterrupted typing burst are not individually dispatched to the VM.
- Submit and blur request an immediate commit rather than waiting for the debounce interval. Submit uses `SubmitEvent.text`; editing end reads the generation-bound `TextInputController`, so completion does not depend on a final `onChange`. A commit request without authoritative final text waits for active IME composition to finish, without an additional debounce delay or duplicate dispatch.
- Validation reflects the buffered draft without executing the VM or rebinding native text on every keystroke; validation issues are suppressed during composition.

### 2. Ordering with form actions

- A field's own debounced/submit commit is intentionally independent: it commits only that field and does not flush a sibling's pending draft, so each field keeps its own debounce deadline. A field handler therefore observes other fields' last-committed values, not in-progress drafts; cross-field consistency is established when a control action, surface gesture, or slow ticker flushes all ready edits.
- If a field is in IME composition, the action remains pending until composition finishes and the final text value can be committed. The action is then resumed in the established order.
- Deferred control actions capture their source node, relevant control state, and form-field dependencies, and are revalidated after flushing. Cancelling a composing field discards dependent or unknown-scope actions while preserving known-independent actions. Form scope is a conservative ordering policy, not analysis of handler dependencies.
- Picker and menu actions retain their opening-time identity. Adjacent queued slider moves coalesce with a following End while retaining its final persistence request. Deferred work resumes outside view reconciliation.
- Surface Move flushes ready edits and revalidates the accepted gesture before executing. Up/Cancel use the deferred-action queue during composition and are delivered at most once after final text, subject to gesture, node, and program-generation checks. Moves during composition are skipped; rejected Downs never create partial gestures. Per-finger state preserves multitouch independence and prevents a reused touch ID from discarding a queued terminal event.
- Tickers with intervals of **500 ms or longer** flush ready edits before dispatch. Faster tickers wait while drafts are pending; all tickers skip during composition and retain elapsed time for the next delivered tick. Effect success/error replies and consent refusals use the deferred-action path while retaining lifecycle guards.
- Surface frames pause during composition but otherwise intentionally use committed VM state without forcing a text commit every frame. Their periodic saves and snapshots wait while drafts remain pending.
- Preview disappearance flushes ready edits and detaches its controller. Generate refinement/fullscreen handoffs and Chat reference capture flush and snapshot before proceeding; active composition blocks those handoffs until completion and retry. Project rename and question inputs also use authoritative native completion and stale-callback guards.

### 3. Stale edit and callback invalidation

Pending timers, commit requests, and deferred actions are invalidated when their target is no longer valid. The invalidation cases include:

- an external program update changes the field value;
- the field is replaced or its relevant identity/configuration changes;
- the preview program is loaded/replaced, or the component enters a lifecycle state in which pending work must no longer execute.

Callbacks validate that they still refer to the current field/edit generation before committing. This prevents a delayed callback from an older edit or program instance from overwriting newer state. Reload cancels old edits rather than committing them into the replacement program.

Renderer-only live-tree membership epochs replace repeated recursive membership queries with constant-time comparisons, with one linear stamping pass per render. The epoch advances before reconciliation and reachable nodes are stamped afterward, so removed nodes and partially reconciled trees cannot pass stale membership checks. Form-scope discovery, path lookup, and dependency collection still traverse the tree.

### 4. Preserve input identity during accepted commits

An accepted text commit that the handler stores unchanged retains the live input node and its field generation. This avoids unnecessary component replacement during ordinary typing and gives ArkUI the opportunity to preserve focus and cursor state.

**Postponed limitation:** a handler that normalizes text, for example by trimming a trailing space, can still advance `fieldGeneration` and recreate the native `TextInput`, potentially losing focus, keyboard, or caret position. Programmatic value changes can do the same. Separating edit/callback invalidation from native input identity remains unfinished; this change does not claim to fix that behavior.

A genuine field replacement or incompatible field change invalidates the previous edit generation. Presentation-only updates should not increment the generation unless the implementation explicitly treats them as a replacement; unnecessary generation changes can recreate the input and disturb focus or cursor position.

### 5. Expected performance impact

The principal expected gain is a reduction in the number of expensive downstream operations, not the elimination of per-keystroke UI events. Each keystroke still updates the local buffer and debounce timer, but a burst of typing is consolidated into one VM commit after the pause.

For a continuous typing burst of **N** characters where every inter-character gap is shorter than 400 ms, the previous per-keystroke path could trigger N VM dispatches, N state saves, and N reconciliations. The debounced path triggers one of each after the final pause. The theoretical reduction in each of those operation counts is `(N - 1) / N`:

| Characters in one burst (N) | Downstream commits before | Downstream commits after | Theoretical reduction |
| ---: | ---: | ---: | ---: |
| 5 | 5 | 1 | 80% |
| 10 | 10 | 1 | 90% |
| 20 | 20 | 1 | 95% |
| 40 | 40 | 1 | 97.5% |

These are operation-count estimates for an uninterrupted burst in a single field, not measured CPU, energy, latency, or frame-rate improvements. Pauses of 400 ms or longer can produce separate commits; separate fields maintain independent debounce windows; explicit form actions can force an earlier flush. Actual end-to-end gains depend on VM cost, persistence cost, reconciliation cost, and the user's typing pattern.

### 6. Verification and remaining device checks

- The latest visual regression run passed all **379 checks**, including updated existing fixtures for scoped actions, membership epochs, surface continuation/deferred terminals, and ticker/effect ordering. No new test cases were added for the latest gesture fixes.
- Validation (**14 checks**), graphics, mixed surface/form state, date-field checks, JavaScript syntax checks, `git diff --check`, and the unsigned ArkTS build passed.

## Fix miscellaneous errors

- Fixed warm launches from the widget, shortcuts and the launcher icon no longer navigating: `navigateToProject()` had been moved inside `extractDevParameters`, which returns early for app callers, so the route queued by `extractProjectId` in `onNewWant` was never drained. It is now called explicitly at the end of both `onCreate` and `onNewWant`, after both extracts, and `extractDevParameters` no longer touches navigation — which also stops `hdc shell aa start` launches from queueing their route twice.
- `DeepSeekEngine.stop()` now destroys the in-flight HTTP client itself through a new idempotent `disposeClient()` instead of depending on a callback inside `runOperation`. The callback and `runOperation`'s `finally` still call it, and `cleanup(client)` keeps its identity guard so a stale stream cannot tear down a newer round's client. Behavior is unchanged when the callback is intact, but `stop()` is no longer silently broken if that callback is moved or removed.
- `VeraPreview` drew a standalone `ui.Path` (outside a Canvas) with a fixed `.scale({x: 2.4, y: 2.4})`, which left the shape at 1/density of its band on any screen whose density was not 1. It now scales by `this.getUIContext().vp2px(PATH_BAND_HEIGHT) / 100` - the same density-crossing formula the canvas branch uses - and the band height (240 vp) is a named module constant `PATH_BAND_HEIGHT`, shared by the scale and the band's `height()`.
- Fixed incomplete generation-metric cleanup after **New**: a shared `resetRunMetrics()` now clears attempts, timing, side calls, stages, service health, tool logs, and trouble notes immediately, and is reused by generation and model-refinement entry points. New also clears the status; refinement preserves cumulative and accepted-version metrics. Added three host regression checks for reset completeness, idempotence, and shared entry-point behavior. All 25 Generate checks, metric checks, and the unsigned ArkTS build passed.
- **Deep captures (2+ levels) through a non-capturing lambda.** `VeraCompiler.loadName` encoded a variable found in a grandparent with the owner's slot, but `make-closure` reads only the immediate frame's local/captures, so a lambda two or more levels deep referencing a variable that the lambda in between does not use grabbed the wrong slot (or `R0016 invalid slot`). `loadName` now threads the capture through every level between the lambda and the owner: each intermediate function is made to physically carry the variable (registered in its `capturedBindings` and `bindings`), so the existing depth-1 encoding composes level by level. Depth-1 behavior is unchanged, the interpreter and the bytecode format are untouched.

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
