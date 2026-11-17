# Multi-screen programs: one module, one state

This is runtime support, not a new generation pipeline. There is no router VM,
per-screen store, fixed screen count or compulsory application structure.
The agent's planning, selection and writing stages have not been changed.

## Contract

- Define one named view function per screen. Each takes the same `AppState`.
- `view(state)` calls **only the active** function, with ordinary `if/else`.
  `ui.When(condition, expensiveView(state))` does not defer argument evaluation.
- Return `ui.Screen(id, children)` from the screen function, inside the app's
  single `ui.AppTheme`. The string identifies the native control subtree;
  it is not a new program, state owner or navigation destination.
- Switch screens by returning state with a different navigation field from an
  ordinary handler. Domain records and outstanding SDK effects stay in the same
  running program. Background answers must update domain state without replacing
  the current navigation or draft.
- Keep the screen ID stable during typing and ordinary state updates. Include a
  stable record ID for an editor/detail screen, e.g. `"edit-" + ui.numberToString(id)`.
  Do not use a changing title, timestamp or array position as the screen ID.
- Changing the ID replaces native controls rather than reconciling an outgoing
  field into an unrelated field at the same tree position. Pending edits and
  queued node actions belonging to removed controls are invalidated. Same-screen
  updates retain native field identity. Screen-local tickers are stopped and
  restarted across screen identities; tickers outside the boundary can remain
  application-wide. Already-queued screen ticker actions recheck their interval's
  lifetime after pending edits flush, so an edit that navigates cannot deliver
  the outgoing screen's tick into the new one. SDK effects are **not** cancelled
  by screen navigation.
- Native screen entry starts at the top, without automatic focus transfer to a
  new field. There is no per-screen scroll cache, focus-restoration stack or
  navigation animation API. Secondary screens use the existing `ui.BackHandler`;
  the first screen can omit it to keep the host's normal back behavior.
- Draft isolation, validation and commit/cancel are application logic. A Screen
  does not create a transaction. Shared arrays/records must be copied before
  mutation, just as in a single-screen program.

Minimal shape (ordinary VERA functions, no extra module entry points):

```ts
@jsonable
class AppState { screen: string; count: number; }
function init(): AppState { return {screen: "home", count: 0}; }
function openDetails(state: AppState, value: number): AppState {
  return {screen: "details", count: state.count};
}
function goHome(state: AppState, value: number): AppState {
  return {screen: "home", count: state.count};
}
function homeView(state: AppState): ui.View {
  return ui.Screen("home", [
    ui.NumberText("heading", state.count, "Count: ", "", 0),
    ui.Button("primary", "Details", "openDetails", 0, true)
  ]);
}
function detailsView(state: AppState): ui.View {
  return ui.Screen("details", [
    ui.NumberText("body", state.count, "The same count: ", "", 0),
    ui.Button("secondary", "Back", "goHome", 0, true),
    ui.BackHandler("goHome")
  ]);
}
function view(state: AppState): ui.View {
  let active: ui.View = ui.Spacer("none");
  if (state.screen === "details") { active = detailsView(state); }
  else { active = homeView(state); }
  return ui.AppTheme("clean", "", [active]);
}
```

Existing single-screen programs need no wrapper or state migration. Screen
identity is UI metadata, not a bytecode-format or saved-state-format change.

## PillPal port

Runnable source: [`tools/vera-harness/examples/pillpal.vera`](../tools/vera-harness/examples/pillpal.vera).
This is a hand-written behavioral port of the recovered web competitor to native
VERA components, not its web bundle and not a built-in pill-tracker framework.

Four named screen functions share medicines, dose records, calendar event IDs
and the synchronization queue:

- Today: ordered doses, Take / Skip / Undo, a seven-day adherence display.
- Medicines: the authoritative shared collection, addressed by stable IDs.
- Editor: name, dosage, notes, multiple times, weekdays and course dates;
  copied draft arrays, validation, save and cancel.
- Deletion confirmation: removal of local records and queued cleanup of the
  exact calendar event IDs created for that medicine. Failed deletions retain
  their IDs so that the user can retry.

Calendar operations use the real existing `CalendarKit.Calendar.addEvent` and
`deleteEvent` adapters. `time.atLocalTime(day, minutes)` converts the local day
number plus minute-of-day into a Unix timestamp with that date's timezone/DST
rules, instead of assuming every local day is 24 hours.

### Deliberate limits

- Reminders are individual calendar events over a rolling **14-day horizon,
  capped at 48 occurrences per medicine**, not indefinite native recurring
  events. Coverage extends when the running app refreshes after seven days or
  the person presses Update reminders. It is not a background scheduler.
- The serialized queue/event IDs support ordinary retries, not exactly-once
  delivery across process failure. An interrupted request has an unknown
  outcome; automatic reissue is suppressed and the UI warns the person to
  inspect the phone calendar. Manual retry after an ambiguous request can still
  duplicate an event; an unusually late answer during a manual retry is not
  correlated to its original request. This is not a production crash-recovery
  guarantee.
- The seven-day denominator is derived from the **current** medicine schedule,
  not historical schedule revisions. Editing a course can change that summary.
- The existing saved-project mechanism can serialize this AppState. The
  `proofSource` launch below is deliberately an **ephemeral runner**, not a saved
  project: closing it does not save its medicines or calendar event IDs. Remove
  test medicines through the app and wait for calendar cleanup **before closing
  a proof that created events**. Do not use this proof route for real medication
  tracking.

## Reproduce the checks

Use an available TypeScript module via `VERA_TYPESCRIPT_PATH` as described in
[`tools/vera-harness/README.md`](../tools/vera-harness/README.md).

```bash
node tools/vera-harness/multiscreen-check.js
node tools/vera-harness/pillpal-check.js /tmp/vera-pillpal
```

The first executes current compiler/VM/decoder and live-tree reconciliation,
plus extracted non-ArkUI renderer methods. It checks shared state, stable
same-screen inputs, replacement of identical-looking cross-screen fields,
stale input/action rejection, surface-input teardown, ticker scope and queued
lifetime checks, application-wide callback/ticker survival, back handlers and
local dates across DST transitions. It does not execute native ArkUI layout.

The second has seven interaction scenarios with a deterministic clock and a
**mocked calendar boundary**, including pending callbacks while editing, saved
state serialization, multiple times/days, horizon limits, failures, retry and
delete recovery. It writes decoded trees, SVG proof sheets and `report.json`.
Serialization is not an on-device process-restart persistence test.

For a native proof after `./update-phone.sh`:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
  --ps proofSource "$(base64 -w0 tools/vera-harness/examples/pillpal.vera)"
```

### Device evidence from this change

The in-place build/update succeeded with zero diagnostics and preserved app
identity and first install time. API 26 required SDK version strings `26.0.0`
in `build-profile.json5` rather than `26`.

The phone run verified Today / Medicines / Editor / Delete, native typing,
Cancel with the keyboard visible (keyboard disappears), a fresh empty editor
on reopening, system Back, a shared saved medicine in both main views, the Take
transition, and scroll reset from the bottom of the editor into confirmation.
After a final rebuild, an empty Save also verified that validation is visible
beside Save, before the long form. An independent review found a queued-ticker
lifetime edge case; the runtime now rejects that outgoing action after a field
commit navigates. Its regression was confirmed to fail when the lifetime guard
is removed, while ordinary SDK callbacks and application-wide tickers still run.

One explicitly named `VERA test` medicine exercised native calendar creation
and cleanup. The UI reported completion; system calendar logs confirmed the
13 cleanup deletions, one each for returned event IDs 319–331. The test medicine
was removed and the proof was left empty. Actual future alert delivery was not
observed. Native Undo/Skip, failure/permission-denial flows and process-restart
persistence were not established by this phone run; the applicable transitions
are covered on the host.

Local evidence (not checked in): `/tmp/vera-pillpal-device/` contains screenshots,
layout dumps and `calendar-lifecycle.log`; `/tmp/vera-multiscreen-update-final.log`
contains the final successful update. The initial independent review is
`/tmp/vera-multiscreen-independent-qc.md`; the focused follow-up in
`/tmp/vera-multiscreen-qc-followup.md` independently confirms the ticker fix,
its negative-control regression and the current native validation UI.
Host regression logs are under
`/tmp/vera-multiscreen-checks/`; the visual regression reported 379/379 passing
checks. `calendar-sdk-check.js` separately passed 26 checks but its public-backend
mock test failed on an existing, unmocked `./VeraNotifySdk` import in the unchanged
backend. This is a harness failure, not a passing calendar-integration test.
