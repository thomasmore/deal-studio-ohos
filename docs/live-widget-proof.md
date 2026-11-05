# Live-widget foundation / counter proof

This is the first slice of `ISSUE-home-screen-widgets.md`, Part 2, **not the complete feature**.

## Try it

1. In **My apps**, use the title-bar menu item **Widget example**. It creates a separate `Widget counter` project; it never replaces an existing program.
2. On its project page, open the "..." menu and tap **Add widget**.
3. On this phone `isRequestPublishFormSupported()` returns false. The fallback opens the system widget manager. Add **VERA live app**.
   The manager does not pass the project on, so Add widget leaves it in `form-offer.json` and the next live card added
   within five minutes takes it, once (`FormBindings.offer` / `takeOffer`). A card added later, or from the launcher's own
   picker, is unbound: tap it and choose a project in **Choose widget app**.
5. On the counter card, +/− run the VERA handler in the form extension. A tap anywhere else on the card opens the full program. A live card has no title strip: the widget has the whole card.

The same Widget action is available for any project. A program without `widget(state)` displays a tile-like fallback and opens the app. An uncompiled project opens its project page.

## Architecture

- `FormBindings.ets`: persistent form-to-project mapping; reloads for every access because app and extension are separate processes.
- `VeraLiveWidget.ets`: platform-independent VM session, rendering projection and event validation.
- `LiveFormService.ets`: load latest version/state, render, validate tap, run handler, render the candidate state, commit only on success.
- `VeraStateStamp.ets`: unchanged state-stamp formula shared with VeraPreview.
- `LiveCard.ets`: launcher-only binding renderer. Fixed depth; no compiler/VM/filesystem imports.
- `FormUpdater.ets`: list/live form routing and coalesced refresh after app state saves.
- `VeraPreview.ets`: reload saved state when the app foreground signal changes.
- State-file writes use a temporary sibling plus rename. Other project/version write semantics are unchanged.

Initial supported kinds are explicitly opted into `ComponentSpec.card`: AppTheme (root only), Column, Row, Text, NumberText, Button, Spacer and Divider. Do not infer that all app components are card-safe.

Limits: 100,000 VM steps per entry call; four layout levels (the theme wrapper does not consume a level); 40 nodes; 256 characters per text; 8,000 UTF-16 code units for the complete frame. This is a conservative application budget, **not a measured platform maximum**. Theme currently resolves light mode only.

Events contain `handler`, numeric `value`, and an exact state/version token. The OS overwrites a message field named `action` with the transport action (`message`), so that name must not be used for the program handler. Only an enabled button in the freshly rendered tree can dispatch. SDK effects are collected but never executed; an effectful handler does not commit state. The card asks the person to open the app; it does not try extension `startAbility`.

The root ForEach key includes the frame token. Without this, nested card builders retain the old displayed number even though updateForm succeeds.

## Verification on this machine

```sh
export VERA_TYPESCRIPT_PATH=/home/mbolshov/agentsdk/panda_sdk/package/driver/build_system/node_modules/typescript
node tools/vera-harness/live-widget-check.js
node tools/vera-harness/live-form-check.js
node tools/vera-harness/widget-launch-check.js
node tools/vera-harness/smoke-check.js
node tools/vera-harness/visual-check.js /tmp/vera-live-proof/visual-host.json
node tools/vera-harness/chat-handoff-check.js . /tmp/vera-live-proof/chat-host.json
```

Native build and in-place system-signed update succeeded with zero reported diagnostics; identity and first-install time were preserved. No uninstall or app-data clearing.

Device evidence in `/tmp/vera-live-proof/`:

- `final-home`: persisted count 3 after app update.
- `final-plus`: card + changes 3 → 4.
- `final-minus`: card − changes 4 → 3.
- `final-app`: opening the program shows 3.
- `app-to-widget`: app-side + was reflected on the card (2).
- `roundtrip`: subsequent widget-side + was reflected in the app (3).
- `hilog.txt`: measured form handler + render + state-save duration 11–13 ms for the counter; frame about 1.2 KB. This is not end-to-end tap latency.

Screenshots and accessibility dumps were captured, but full visual QA is **not signed off**. The configured external image analyzer rejected requests (413 on full PNG, 400 on cropped JPEG). No independent QC/subagent tool was available in this session. This proof must not be represented as full Part 2 acceptance.

## Make widget: a widget the person describes

The project page's "..." menu offers **Make widget** for the latest runnable version. It opens Generate on that version with
the box empty -- "What should the widget show?" -- and the **Widget** tab open. What the person types is the request
("The home-screen widget should show: ..."); the instructions for what a widget is go in the system prompt
(`widgetRefinementPrompt`). Generate, refine and Save work as for any change; the action does not publish a card.

- **What a widget is, to the model:** a second view of the same state -- `widget(state)` draws the very state `view(state)`
  draws -- read at a glance: one to three figures or short lines with labels of a word or two, at most two buttons for the
  actions worth doing without opening the app, nothing else (no lists, history, settings, inputs, explanations, no heading
  with the app's name: the card has no title strip). When the request asks for more, keep what matters most. No button that opens the app.
- **Held to it:** Make widget's validation refuses more than 2 buttons or 8 texts (`WIDGET_MAX_BUTTONS`,
  `WIDGET_MAX_TEXTS`), with a reason the repair loop passes to the next attempt. The card's own budgets are unchanged.
- **Only the widget is written** (DeepSeek mode, `agent/AgentWidget.ets`): the model is shown the program, the request and
  the card's components only (`languageWith`, the full-screen composition advice left out), and answers with the widget's
  declarations alone (`widgetRefinementPrompt(false)`); a failing answer goes back with its reason, three answers at most,
  the last with thinking on. Host, deepseek-flash, the same five requests on three generated apps (150-211 lines), two
  runs each: whole-program refine 10/10, median 6.3 s, about 2,200 output tokens; widget alone 10/10, median 2.0 s, about
  370. Server and local modes still refine the whole program.
- **The app cannot change:** `spliceWidget` (VeraCompiler) builds the program from the saved one as it is plus the reply's
  `widget`, new helpers and new imports; the reply's rewrite of an existing declaration is not taken. A widget that needs
  state the app does not keep fails to compile, and `widgetRepairNote` tells the next attempt that the state cannot grow.
- **Widget tab:** `WidgetPreview` draws the widget with the card's own session (`WidgetSession`) and layout, 2x2, over the
  state the app preview holds -- Make widget starts both from the project's saved data. Taps there run the handlers but are
  not saved.
- The compiler checks an optional synchronous `widget(init-result): ui.View` signature (`E2112`). `smokeRun` validates widget
  trees and enabled buttons without executing phone effects.
- Save rechecks preservation and the widget against the base version's **latest saved state**, refuses a changed
  latest-version ID, and stages that state with the new bytecode stamp before publishing the new version. A refused Save
  stays on the page. There is no cross-process lock: state remains last-writer-wins.
- Foreground restoration redraws the same runner instance. Background signals stop program timers.

- **Kept current:** the live card is updated about every 30 minutes (`updateDuration` 1), so a figure `widget` works out
  from the clock moves by itself. When the state itself goes out of date with the time (the day's figures, a countdown that
  is over), Make widget may add `function widgetRefresh(state): AppState` (signature checked, `E2113`). On each periodic
  update `LiveFormService.liveFormRefresh` runs it as a tap runs a handler -- phone effects refused, render, THEN commit --
  and the project's other cards are redrawn. `RefreshLedger` (`widget-refresh.json`) lets it run once per project per
  `REFRESH_EVERY_MS` (20 minutes), however many cards show it; a failing one waits for the next period. Validation runs it
  twice and refuses one whose second run changes the state again (timestamps may differ by under a minute). The splice
  treats it as the widget's own: replaced with the widget, dropped when a new widget has none.

Host replay (`deepseek-flash`, thinking off, the refine request DeepSeekEngine sends, up to three attempts with the error fed
back): six requests on four apps (a generated water tracker and packing list, the expense and habit examples), including two
that ask for everything ("every drink logged today ... and buttons for 100, 250, 330 and 500 ml", "the whole list with a
checkbox for each item"), three runs each: 18/18 valid. With `widgetRefresh` in the prompt and a seventh request ("start again from zero every morning"): 21/21 valid; the water tracker's widgets added a `widgetRefresh` that empties the day's drinks on a new day and keeps the goal, while the packing list, budget and habit widgets (no state that dates) added none. Before the splice and the repair note, 6/18 passed in one attempt;
most failures were the model also rewriting an existing declaration. Not yet run on the phone.

Host evidence for this follow-up:

- `widget-refine-check.js`: preservation, optional signature, catalogue-derived instructions, smoke diagnostics, saved-state validation, glance limits, the splice and the repair note pass.
- `live-widget-check.js`: repeated rows with distinct item IDs, middle-row removal, shifted rows and stale/removed-item taps pass using Column/Row (no ListGroup/ListItem required).
- `live-form-check.js`: two widgets sharing state, stale tokens across widgets, binding removal/rebind, missing-project fallback and preserved state in a new version pass.
- `capability-check.js`: **10/10 pass**, including executing extracted renderer lifecycle methods with the real VM, restoring the same runner instance and stopping timers on background. Report `/tmp/vera-widget-capability.json`.
- Widget launch, smoke and visual-tree checks pass (**97/97** visual-tree checks; not screenshot QA).
- Chat regression: **39 pass / 18 fail**. An archived clean HEAD has the exact same failing check names and counts; these are baseline failures, not a clean suite. Reports `/tmp/vera-widget-chat{,-baseline}.json`. The earlier summary's chat-success statement should not be used as evidence for this follow-up.

Native build: `./build-hap.sh --unsigned` passes with zero diagnostics on main 6b2f59b plus this branch. The Make widget flow above has not been installed or run on the phone.

Independent QC and device/visual verification remain blocked: tool discovery exposes no independent task/subagent review tool. No merge-ready or full Part 2 claim is made.

## Deferred / known limits

- Habit-list fixture, ListGroup/ListItem and remaining card-safe components.
- End-to-end device test of Make widget, including the Widget tab and saved-state carry-over.
- Actual platform payload maximum, large form sizes, dark mode and full visual/accessibility QA.
- Removal/rebind lifecycle device coverage and foreground resume to an existing runner without a new router push.
- Last-writer-wins state is intentional; binding-map updates currently use read/modify/replace, so truly concurrent bind/remove operations can overwrite each other.
- Background timer pause/resume change has host lifecycle coverage only; device proof remains outstanding. Timer/game programs are not supported widget fits.
- Independent QC gate remains required before treating the slice as ready to merge.
