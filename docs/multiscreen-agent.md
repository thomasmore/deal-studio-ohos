# Shared-state multi-view generation

Generate and Chat share one optional view plan, one writer chain and one VM/AppState. This extends existing state-driven navigation and Chat tabs; it does not introduce a router or per-view store.

## Planning and presentation

`NeedsPlan.ets` retains stable need IDs, `uses` ownership references, `screens`, `startScreen` and `transitions`. Each collection has one owner; several views can present or edit the same records. `NeedsChoose.ets` hands multi-view plans to the writer before the lossy one-list/one-clock projection, preserving clarification answers and filtering unasked needs.

- `presentation: "pages"` (default): list/detail/editor navigation.
- `presentation: "tabs"`: peer views; Chat adds compact presentation instructions.
- Ordinary single-view plans retain the existing parts/catalogue route.

A conservative English-pattern guard detects explicit detail/editor navigation described in needs without screen metadata. It returns a diagnostic through the existing bounded planning retries. External phone-action needs are excluded. It is not a universal intent classifier. The heuristic alone never disables the ordinary whole-screen fallback; only an explicit malformed/failed multi-screen plan does so in either entry point.

## Writing and runtime

The existing classes/fields/functions/view contribution format produces shared `c_` state and handlers, `C_` record classes, and `c_view_<id>` functions returning `ui.Screen`. One host AppTheme wraps only the active screen. Navigation, stable record selection and isolated editor drafts are ordinary state transitions; Save commits, Cancel/Back discard drafts.

The writer has at most three attempts and a screen-scaled output budget capped at 16,000 tokens. Requested actions require actual controls. A small bytecode-reference check catches unreferenced AppState-mutating handlers; it is not full action coverage.

Existing Chat block-to-tabs composition retains its view-local fragment scope and ordinary smoke contract, including panes that start empty. Only the selected pane is wrapped in a named Screen; fragment blocks are not extracted into `c_view_` functions or opted into the planned-screen validation/reachability contract. Labels, selected state and callbacks stay unchanged. These compositions retain their composition records; declared shared apps do not have flat records.

See [runtime contract](multiscreen-runtime.md) for native identity and teardown behavior.

## Validation and repairs

`smokeRun` checks named views with empty/missing selections, one active Screen/AppTheme, content and bounded handler taps. `VeraReachability.ets` additionally starts from disposable `init()` state, fills visible inputs and explores enabled rendered callbacks with their actual payloads. A view passes only after `view()` displays it; direct view-function calls or injected navigation state do not count.

The search freezes time, deep-clones branches, respects inactive tabs and never executes external effects. Bounds: 192 queued states, 768 actions, depth 16, 64 KiB state keys, and 2M aggregate VM steps checked between calls (100K per call). Missing paths return observations and witness paths to the existing repair loop. Exhaustion means **no witness found**, not proof of impossibility; unusual input or external prerequisites can fail the gate.

Refinement validation extracts pre-edit top-level function identities with the compiler parser (not line-based matching), preventing accidental flattening. Local Generate asks once per request before intentional view removal and remembers only the exact approved ids across repairs; a later candidate cannot widen that approval. Chat/server refinements preserve views conservatively. Source introspection is best-effort: a saved/server source the current parser cannot read does not block the refinement request.

Date-generation instructions initialize/reset new date drafts to `time.daysSinceEpoch()`, not `0` (1 January 1970). Editing preserves stored dates. This is prompt guidance, not renderer coercion or a migration.

## Host checks

With `VERA_TYPESCRIPT_PATH` set to the SDK TypeScript module:

```bash
node tools/vera-harness/app-plan-check.js
node tools/vera-harness/reachability-check.js
node tools/vera-harness/multiscreen-check.js
node tools/vera-harness/template-run-check.js
node tools/vera-harness/chat-prompt-check.js
node tools/vera-harness/reachability-check.js /path/app.vera
```

The last command prints JSON and exits 1 when a path is missing. Tests use the real compiler/VM with mocked model/phone boundaries. They include payload mismatch, planning/repair feedback, compact planned pages/tabs, legacy tab scope/empty panes, clarification defaults and refinement preservation. Native runtime checks are separate from generated-app functional correctness.

The PR's earlier 180-prompt benchmark measured commit `c33174b`, before reachability/date/unification changes. It is not a benchmark of the current head, nor functional validation. Known limitations include planner omissions outside the structural guard, bounded search, and imperfect semantic verification. See [agent route](agent.md) for the surrounding pipeline.
