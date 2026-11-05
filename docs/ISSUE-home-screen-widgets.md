Generated apps on the home screen: a 1×1 app tile, then a live widget

Two features with a shared base. **Part 1** is small and can ship by itself; **Part 2** builds on its per-widget project binding. They can be split into two issues if that suits whoever picks them up.

Read `CLAUDE.md` first. The traps that matter here: update the phone only with `./update-phone.sh` (system-signed, in place); **never `hdc uninstall`**, because it wipes `{filesDir}/vera` (every project, every program's state, the API key); a permission added to `module.json5` is granted or refused at install, so the install output is the answer.

---

## What exists today

| piece | file | what it does |
|---|---|---|
| widget "VERA Projects" | `entry/src/main/resources/base/profile/form_config.json` (form `widget`, 2×2 / 2×4 / 4×4) | lists every saved project |
| card page | `entry/src/main/ets/widget/pages/WidgetCard.ets` | rows of `icon name >`; a tap sends `postCardAction(... 'message', {projectId})` |
| provider | `entry/src/main/ets/formability/VeraFormAbility.ets` | `onAddForm` / `onUpdateForm` return `buildFormBinding()`; `onFormEvent` starts `EntryAbility` with `projectId` |
| binding + refresh | `entry/src/main/ets/vera/FormUpdater.ets` | `buildFormBinding()` (all projects), `refreshForms()` (pushes to every running form) |
| launch with a project | `EntryAbility.extractProjectId` then `loadContent` → `pushUrl('pages/ProjectPage', {projectId})` | opens the project's **version list**, not the running app |
| running a version | `ProjectPage.runLatest()` / `runVersion()` → `pushUrl('pages/RunnerPage', {projectId, versionId, vbc2})` | the app itself |
| storage | `entry/src/main/ets/vera/ProjectStore.ets` | `Project {id, name, icon}`; `Version {source, vbc2, ...}`; state in `<versionId>.state.json`, read and written with `loadState` / `saveState(projectId, versionId, stamp, encoded)` |
| state stamp | `VeraPreview.stamp()` (`components/VeraPreview.ets:463`) | `vbc2.length + ':' + vbc2.substring(0, 64)`, which ties saved state to the exact program |
| signing | `sign-system.sh`, `signing/UnsgnedReleasedProfileTemplate.json` | profile APL `system_basic`, `app-feature: hos_system_app`, `allowed-acls` list |

Checked against SDK 26 (`~/agentsdk/ohos_sdk/26`):
- `form_config.json` accepts `"1*1"` (other sizes: `1*2 2*2 2*3 2*4 3*3 4*4 6*4`).
- `formProvider.requestPublishForm` / `isRequestPublishFormSupported` are `@systemapi` and need `ohos.permission.REQUIRE_FORM`, which is `system_basic` (our level).
- `formProvider.openFormManager(want)` is public since API 18 and opens the system's add-widget page.
- `shortcutManager.addDesktopShortcutInfo` needs `ohos.permission.MANAGE_SHORTCUTS`, which is `system_core`, one level above our profile.
- Card-capable components carry `@form` in `ets/dynamic/component/*.d.ts`. Text, Button, Row, Column, Stack, Divider, Progress, Image, Toggle, Slider, Path and Canvas all have it.

---

## Part 1: a 1×1 tile per generated app

### Goal
Put one generated app on the home screen as an icon-like tile (its icon and name). One tap opens the **running app** (RunnerPage, latest version), not the version list.

### Design
1. **A second form** in `form_config.json`: `name: "project"`, `displayName: "VERA app"`, `src: ./ets/widget/pages/ProjectTile.ets`, `defaultDimension: "1*1"`, `supportDimensions: ["1*1", "1*2"]`, `updateEnabled: false` (it only changes when the project does). Keep the existing `widget` form as it is.
2. **Bind each placed widget to a project.** Persist `formId → projectId` in a new `{filesDir}/vera/forms.json`. Put a small module beside `ProjectStore` with `bind`, `unbind`, `projectFor(formId)` and `formsFor(projectId)`.
   - `VeraFormAbility.onAddForm(want)`: read the form name (`want.parameters['ohos.extra.param.key.form_name']`). For `project`, take `projectId` from `want.parameters` (present when added from inside the app, see 4). Bind it and return the tile binding. If there's no `projectId` (added from the system widget picker), return an **unbound** tile: "Choose app", where a tap opens VERA's project list.
   - `onRemoveForm(formId)`: unbind.
   - `onUpdateForm` / `onCastToNormalForm`: rebuild from the binding.
3. **Tile card** `ProjectTile.ets`: big `icon` (Project.icon is the emoji or icon string picked in `Index.ets`) with the name under it, one line, ellipsis. Tap: `postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { projectId, veraRun: '1' } })`. A router action opens the app directly, with no hop through the extension.
4. **"Add to home screen"** on `ProjectPage`:
   - `formProvider.isRequestPublishFormSupported()`. If true, call `requestPublishForm(want, binding)` with `want = { bundleName, abilityName: 'VeraFormAbility', parameters: { 'ohos.extra.param.key.form_name': 'project', 'ohos.extra.param.key.module_name': 'entry', 'ohos.extra.param.key.form_dimension': <1*1>, projectId } }`, then bind the returned `formId`.
   - Otherwise call `formProvider.openFormManager(want)` and say in the UI that the person picks "VERA app" there.
   - Add `ohos.permission.REQUIRE_FORM` to `module.json5`. If the install refuses it, also add it to `allowed-acls` in the profile template.
5. **Launch straight into the app.** `EntryAbility.extractProjectId` also reads `veraRun`. When set, navigation does what `ProjectPage.runLatest()` does: push `pages/RunnerPage` with the latest version's `projectId`, `versionId` and `vbc2`. Push ProjectPage underneath it, so back lands on the project and not on Index. If the project has no runnable version, open ProjectPage.
6. **Keep tiles current.** Generalise `refreshForms()`: list running forms with `formProvider.getPublishedRunningFormInfos()`, give `widget` forms the list binding and `project` forms their tile binding. Call it after create, rename, icon change and delete. A deleted project's tile shows "App removed" and a tap opens Index.

### Acceptance
- Add to home screen from ProjectPage → a 1×1 tile with the right icon and name; tap → the program running, with its saved state.
- Adding "VERA app" from the system widget picker → unbound tile; tap opens VERA.
- Renaming, changing the icon or deleting the project updates the tile within a few seconds of the change.
- Removing the tile removes its entry from `forms.json`.
- Updated in place with `./update-phone.sh`: identity and first-install time unchanged.

### Optional, only if it's one line
A real desktop shortcut via `shortcutManager.addDesktopShortcutInfo` needs `MANAGE_SHORTCUTS` (`system_core`) in `allowed-acls`. One install shows whether the device accepts it. The icon has to be a resource in our bundle, not the project's emoji. Report the install result either way; don't fight a refusal.

---

## Part 2: a generated app as a live widget

### Goal
A 2×2 / 2×4 / 4×4 widget showing a compact live view of one generated app, with working buttons. Taps change the program's state, and it's the same state the app uses. Example fits: counter, habit tracker, to-do, next-dose reminder, scoreboard. Timers and games are not fits.

### The constraint that shapes the design
Card UI is rendered by the launcher, not in our process. Only `@form` components are available, with no long-running code and no timers beyond built-ins like `TextClock`. **The VERA VM cannot run in the card.** It runs in `VeraFormAbility` (our process, short-lived per callback). The card is a generic renderer for data the extension sends.

### Design
1. **Program contract.** An optional `function widget(state: AppState): ui.View` beside `view`, the compact screen for the card. If a program has no `widget`, the live form shows the Part 1 tile and opens the app.
2. **Card-safe subset, declared in the catalogue.** `VeraUiCatalog.ets` is the one description of `std/ui`, so add a per-component `card` flag there; don't keep a second list. Start with: Column, Row, Text, NumberText, ClockText, Metric/MetricGroup, ListGroup/ListItem, Badge/StatusPill, Progress, Divider, Spacer, Icon, Button, IconButton.
   - Exclude for now: Ticker, the text fields, Select, Slider, Toggle, Image (network images in cards are a separate question), Canvas/Path with spin, BackHandler.
   - The validator rejects a `widget()` whose tree uses a non-card kind. Check the decoded tree, so kinds built in loops are caught too.
3. **Rendering path.**
   - `VeraFormAbility` loads the project's latest version (`vbc2`) and its state (`store.loadState(projectId, versionId, stamp)`). Move `VeraPreview.stamp()` into a shared helper so both sides compute the same stamp.
   - Construct `VirtualMachine(deserializeVbc2(vbc2), new UiHostEnvironment())` with `effectsAllowed = false`, run `widget(state)`, then `decodeVeraUi`.
   - Serialise the tree to plain JSON for `formBindingData`: kind, style, text, value, action, eventValue, children. Cap the depth (e.g. 4) and node count (e.g. 40), and refuse trees beyond them with a clear log line.
   - Resolve theme colours in the extension (`VeraTheme.ets`) and send them in the binding. Don't rely on the card importing app modules.
4. **Generic card page** `widget/pages/LiveCard.ets`: draw the serialised tree with nested `ForEach`, one level per depth up to the cap (cards may not support recursive `@Builder`; check, and use recursion if they do).
5. **Taps.**
   - Buttons send `postCardAction(this, { action: 'message', params: { action, value } })`.
   - `onFormEvent(formId, message)`: look up the project, load state, run the handler `(state, value)` in the VM, save state with the same stamp, re-run `widget()`, then `updateForm(formId, binding)`.
   - Keep it synchronous and short; nothing waits on the network.
6. **Effects from the widget.** If a handler queues a `HostEffect` (sdk, intent, calendar), don't run it in the extension: consent UI and intent calls live in the app. For v1, open the app (router to RunnerPage) and log what was skipped. Note it in the issue thread if you find a better rule.
7. **State shared with the app.** The app (`VeraPreview`) and the widget write the same `<versionId>.state.json`.
   - After the app saves state, call `refreshForms()` for that project's live forms, throttled (at most once a second).
   - When RunnerPage comes back to the foreground, it reloads state from disk, so a change made in the widget shows up. Check how `VeraPreview` loads state today: it may only read it at construction.
   - Last writer wins is acceptable for v1.
8. **Time.** No live ticking. `widget(state)` may read `std/time`; set `updateDuration` (units of 30 min) or use `formProvider.setFormNextRefreshTime`, so time-dependent text (next dose, days left) refreshes.
9. **Generation.**
   - Phase 1, manual: a "Make widget" action on ProjectPage that refines the latest version with a prompt asking for a `widget(state)` view for a 2×2 home-screen card, using only card components. It goes through the existing refine path, compile and repair loop. Prompts in English.
   - Phase 2: the catalogue prompt tells the model to write `widget()` when the request mentions a home-screen widget.
   - Host check: compile, run `widget(init())` under node (`tools/vera-harness/run.js prog.vera widget`), check card-safe kinds and the size caps, and render a proof sheet (`tools/vera-harness/proof-sheet.js`).

### Verify on the device before building on it
- How long `FormExtensionAbility` lives per callback, and whether running the VM inside `onFormEvent` stays inside it (log the timings).
- The binding data size limit; the serialised tree must fit.
- Which `@form` components behave as documented when nested inside `ForEach`.
- Whether `updateForm` from the app process reaches a live form while the app is in the foreground.

### Acceptance
- A hand-written program with `widget()` (a counter with + and −, and a habit list with check buttons) shows on a 2×2 widget, and taps change it within about a second.
- Opening the app shows the state the widget left, and changes made in the app reach the widget.
- A program without `widget()` shows the tile and opens the app.
- A `widget()` using a non-card kind is rejected by the validator, with the kind named in the message.
- "Make widget" on a generated to-do or habit app gives a working widget on the phone.
- No `hdc uninstall`; in-place update verified.

### Out of scope
Animation and tickers in the card, text input in the card, running phone actions from the card, network images, more than one project per widget.
