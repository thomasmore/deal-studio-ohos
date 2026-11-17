# Shared-state multi-screen generation

The first multi-screen agent path is implemented on the existing one-module runtime. This is a bounded first cut, **not a functional-quality sign-off**: generated apps can compile and navigate while still missing a requested action's UI control.

## Current demo-sized follow-up

The follow-up stays generic: a writer rule that requested actions need controls, a small check for declared AppState mutations with no control/caller reference, and shared-app ownership context in the existing verifier. No new pipeline stage, router, per-app template, or validation framework.

Final-build native generation, one measured pass per prompt:

| Case | Active | Result |
| --- | ---: | --- |
| Notes, two screens | 10.99 s | Built, one planning turn and one writer |
| Shopping, related lists | 12.31 s | Built, one planning turn and one writer |
| Medicines, three screens | 26.39 s | Not built after three writer/repair turns; existing semantic verifier rejected editor Cancel/Back behavior |

The medicines failure is preserved, not silently retried. The earlier prompt-only and intermediate follow-ups remain separate under `demo-follow-up/` and `demo-final-check/`; these are not replacements for the original first pass.

Real compiler/VM replay of the two accepted **new** sources verifies actual UI bindings: notes Save, edit, Cancel and Delete; shopping per-list ownership, toggle/count propagation, list deletion preserving the other list, and item removal. Native replay of the exact new notes source verifies create → Save → editor with Delete control → Delete → Back → empty list. **Rough edge:** Delete leaves the editor open; Back is needed to see the updated list. No claim that every generated action or navigation path is correct.

Current checks: **38 app-plan checks**, the same 16 existing suites, and a native in-place build with **0 diagnostics**. Saved-project index unchanged. Evidence: `/home/mbolshov/vera-benchmarks/20261116-175339-multiscreen-agent/demo-check/`, especially `flow-check.json` and `native-check.json`.

This is a demo-scoped review candidate, not a product-quality sign-off. Remaining observed break: heuristic semantic verification can still reject a multi-screen editor. No further machinery was added to chase this result.

## Implementation

- `NeedsPlan.ets` adds stable need IDs, `uses` references, optional `screens`, `startScreen` and `transitions` to the existing planning reply. There is no extra planning round solely to discover screens. IDs, ownership references, starting screen, transitions and reachability are checked locally. A bare declared record owner is normalized to `owner.id`; invalid/non-string references are rejected.
- `NeedsChoose.ets` preserves blocking questions, the effective clarified request and `dropUnasked`. A multi-screen plan is handed off **before** lossy flat `Sketch` projection and flat part selection. `ComposeResult.appPlan` and `ScreenPlan.appPlan` retain the full relationships. Widgets and one-screen requests retain the existing path.
- `VeraAgent.ets`, `AgentHole.ets`, `AgentCustom.ets` and `AgentAppContract.ets` reuse one existing contribution format: classes, fields, functions and active view. One shared `AppState` owns the records; `c_view_<screenId>` functions render them, ordinary handlers navigate, and isolated drafts commit only on domain Save. Stable record IDs, immutable updates and one active native `ui.Screen` are required. The host adds exactly one AppTheme and no duplicate outer header.
- The writer has at most three attempts, with a screen-scaled token limit capped at 16,000. It is one shared writer chain, not a complete pipeline per screen. There is no separate VM/store/router and no compulsory layout or PillPal template.
- `VeraSmoke.ets` and `AgentRepair.ets` validate the declared named views, initial/empty selection, starting identity, one active Screen/AppTheme, content and already-bounded handler taps. Repairs retain the declared plan. `VeraBuildRoute.ets` refuses the whole-hole fallback after a recognized app plan has failed (`appPlanFailed`). These are bounded structural/runtime checks, not exhaustive behavior or semantic coverage.
- `VeraAppRefine.ets`, Generate and Chat carry the **pre-edit generated `c_view_` identities** into refinement checks instead of deriving requirements only from the replacement. Local Generate refinement asks the person before accepting screen removal. Chat and server refinements conservatively preserve these identities. App plans do not get a flat composition record, so structural block refinement cannot silently erase their relationships.

## Independent review and regression fixes

The focused read-only review found two MEDIUM issues: an editor that became empty only when activated could pass; and generic refinement could delete views and thereby disable candidate-only inference. Both reproductions now have regression coverage and fixes. Active content is checked after navigation, and refinement checks retain pre-edit screen identities. The original review remains unchanged at `/tmp/vera-multiscreen-agent-review.md`; this is the implementer's disposition, not a second independent review.

At the initial review-fix stage, `app-plan-check.js` passed 35 checks with the real compiler/VM and mocked model, selector and phone effects (38 in the current demo follow-up). Sixteen other host suites passed: needs-plan, needs-choose, agent, plan, hole, parts, compose, merge, align-agent, smoke, multiscreen, pillpal, state-carry, live-widget, scene-hole and surface-route. The final native build reported Status ok / Diagnostics 0 and installed in place with unchanged app identity and first-install time.

## Measurement method

Eight prompts were frozen before the first pass. Three pilot cases were measured once; resume skipped them and measured the other five. All failures/retries remain in their original traces. The first pass used the initial agent build. A single explicitly labeled notes follow-up used the final parser/review fixes; it does not replace the original result.

Active time excludes recorded clarification waits; there were none in this subset. Token counts include every reported DeepSeek turn and retry. **They are partial**: TypeSafe usage is unavailable. Cached tokens are part of input; the ratio is cached/input, not the fraction of cached requests. Provider caches were not cleared. This small, heterogeneous, one-pass subset does not establish variance, linear scaling or a causal speedup.

## Frozen first pass

All eight reached pipeline acceptance, which is not functional correctness. Four of five multi-screen requests used the intended shared-plan handoff. Medicines exhausted three plans and used the old whole-hole fallback: its source contains three Screen branches, but it lacks the preserved app plan/named-view contract. The final route now blocks that fallback after a recognized failed app plan. The medicines case was not regenerated on the final build.

| Case | Observed route | Active, s | Reported calls |
| --- | --- | --- | --- |
| Notes, inline | Existing single-screen | 2.71 | 1 |
| Notes, 2 screens | Shared app | 22.35 | 4 |
| Notes, 3 screens | Shared app | 14.83 | 3 |
| Books, 3 screens | Shared app | 28.50 | 4 |
| Shopping, related lists | Shared app | 39.43 | 4 |
| Medicines, 3 screens | Legacy whole-hole fallback | 48.10 | 4 |
| BMI calculation | Existing single-screen | 2.61 | 1 |
| Savings calculation | Existing single-screen | 2.83 | 1 |

## Reported tokens per prompt (partial)

| Case | Input | Cached (ratio) | Output |
| --- | --- | --- | --- |
| Notes, inline | 3,302 | 512 (15.5%) | 95 |
| Notes, 2 screens | 31,019 | 6,400 (20.6%) | 4,167 |
| Notes, 3 screens | 32,095 | 22,272 (69.4%) | 2,998 |
| Books, 3 screens | 33,222 | 25,344 (76.3%) | 5,537 |
| Shopping, related lists | 33,119 | 25,344 (76.5%) | 7,602 |
| Medicines, 3 screens | 28,215 | 23,424 (83.0%) | 8,987 |
| BMI calculation | 3,317 | 3,072 (92.6%) | 283 |
| Savings calculation | 3,322 | 3,072 (92.5%) | 401 |

## Separate follow-up: two-screen notes

Same exact prompt, final build: **12.31 s**, one planning turn and one shared code-writing turn; input **24,251**, cached **17,152 (70.7%)**, output **2,333** (partial usage). Original: **22.35 s**, three planning turns and one writer. This confirms the two-call path on this one run, not a controlled latency claim. Offline replay also accepts all three original medicines planning replies with the final record normalization; that is parser evidence, not a native rerun.

## Exact single-screen baseline matches

The two identical upstream-main prompts retained one planning call and no code writer. BMI: **2.217 → 2.611 s**; savings: **2.331 → 2.830 s**. Reported input grew by 239 tokens in each; output remained 283 and 401 tokens respectively. These runs do not show a single-screen speed improvement. Host replay verifies the displayed initial results: BMI 22.2; savings $3,900 remaining and 10 months.

## Initial-run functional evidence and gaps (historical)

- **Native, final notes follow-up source, ephemeral proof:** empty editor, draft entry, Cancel without committing, fresh reopened editor, Save, edit/Cancel, committed edit, system Back and fresh editor after Back. Nine recorded stages. No saved project was created or changed. Delete was not native-tested.
- **Native, original shopping source:** empty state, two lists, first-list item and isolated second-list item. Four stages were captured. The collector timed out later; native checked-state and shared-count confirmation were not completed and are not claimed.
- **Real compiler/VM replay:** all eight original sources plus the follow-up pass bounded smoke. The shopping source preserves list/item ownership; ticking A changes its remaining count to zero while B stays one; direct list-removal handler invocation preserves B and its item. This last check is a direct host function call, not evidence of a working native removal control.
- **Known functional omissions:** the final generated notes source declares `c_delete` but never binds it to a UI control. The original shopping source likewise declares `c_removeList` without a UI binding. Both requests explicitly asked for deletion. Therefore these apps are **not fully functionally complete**, despite pipeline acceptance. The current bounded gate does not prove requested-action coverage or UI reachability. A generic action-to-control coverage check is the next focused quality task; no shopping- or pill-specific framework has been added to hide this gap.
- Initial/empty view checks are not an exhaustive navigation graph proof. Async races, persistence across process restart, all requested behaviors in books/medicines, and calendar/notification effects were not established by this subset. Medicine prompts explicitly excluded calendar reminders/notifications.

## Evidence and safety

Evidence root: `/home/mbolshov/vera-benchmarks/20261116-175339-multiscreen-agent`.

Original `runs/*` and manifests are preserved; `follow-up/` contains its own source/HAP hashes and result. `native/notes/` and `native/shopping/` hold native layouts/screenshots; `replay-check.json` separates host evidence from native checks. The saved-project index hash is unchanged and the USB VPN was verified connected after testing. No uninstall, data clear, saved-project overwrite or benchmark force-stop was used. No credentials or raw traces were published. The existing remote baseline metrics page was not modified.

See [the offline results sheet](multiscreen-agent-results.html), [the agent route](agent.md), [runtime contract](multiscreen-runtime.md), and `tools/vera-harness/app-plan-check.js`.
