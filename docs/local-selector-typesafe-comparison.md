# Shared-state Q8 versus TypeSafe Jev: initial diagnosis

Measured 2026-11-25 against PR #63 `36ff655`. This is **not** a representative
production accuracy benchmark or independent held-out model evaluation.

## Providers and method

- Local: the supplied OpenHarmony ARM64 archive from the verification record,
  model `mmbert-shared-state-q8-experimental`, manifest
  `4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5`.
  Actual supplied C ABI ran on the phone, not a reimplementation or host model.
- TypeSafe: `https://api.typesafe.ai/v1/systemone`, request model `jev-latest`.
  The service returned no pinned model revision in the captured answers.
- Each provider received byte-identical bodies. Local ran in a persistent
  standalone phone process with eight Rayon threads. Cloud requests ran from
  the host using the configured phone selector credential, read into memory;
  settings/credential contents were not logged or saved.
- Replayed each corpus twice per provider. No provider fallback. No training,
  tuning, temperature change, or model modification.
- Choice responses validated against offered criteria; transport failures and
  missing/invalid answers were counted rather than silently excluded. All
  requests and decisions below returned valid responses in both passes.

## 1. Captured phone requests: agreement, not ground-truth error

Froze all 30 unique exact selector request bodies in the available phone trace:
222 choice questions. Replayed **every request through the supplied Q8 model**,
including historical requests originally answered by another model. Did not
compare historical Laya answers with current TypeSafe answers.

| Cohort | Questions | Agree | Disagree | Disagreement |
|---|---:|---:|---:|---:|
| Historical phone requests | 200 | 126 | 74 | 37.0% |
| Current Q8 timer/edit/shopping runs | 22 | 13 | 9 | 40.9% |
| **All exact requests** | **222** | **139** | **83** | **37.4%** |

Selected families (first pass):

| Family | Disagree / compared | Rate |
|---|---:|---:|
| Formula (`expr`) | 13/17 | 76.5% |
| Countdown source | 4/5 | 80.0% |
| Units | 5/5 | 100% |
| Ready-made part (`need`) | 5/5 | 100% |
| Structural edit (`edit`) | 1/3 | 33.3% |
| Code/need verification (`does`) | 6/17 | 35.3% |
| Input/output necessity (`asked`) | 8/38 | 21.1% |
| Presentation (`show`) | 3/17 | 17.6% |
| Theme | 4/10 | 40.0% |

Local repeated 222/222 choices. TypeSafe repeated 220/222; the two changes were
`show.packedCount` and `steps.isHighFever`. Overall second-pass disagreement was
still 83/222, not necessarily the same 83 decisions.

Before fetching TypeSafe replies, recorded three obvious expected answers from
the current Q8 cases: duration source `minutes`, unit `minutes`, and added part
`checklist`. Local was wrong on **3/3**; TypeSafe on **0/3**, both passes. This
small set confirms the specific errors, not general accuracy.

### Attribution and sampling limits

- Exact bodies are deduplicated, not semantic questions. Similar countdown
  questions recur in different plans. Questions within a request/task are
  correlated; do not treat 222 as independent random test cases.
- This is an opportunistic sample of developer phone runs, including failures,
  not a sampled production workload. All questions are `choice`; no `noul` error
  estimate is available. Themes/layouts can admit several reasonable answers.
- Bodies reflect paths reached by prior local choices; there is no matched
  TypeSafe-generated-path cohort here. Agreement does not measure end-to-end
  success or the downstream paths TypeSafe would actually reach.
- TypeSafe is not ground truth. For example, on “High fever?” defined as whether
  latest temperature is at/above the high-fever line, TypeSafe selected
  `subtract:latestTemp:dangerTemp`; local selected
  `multiply:feverThreshold:isFever`. Neither implements that boolean predicate.
  The option set included `unavailable`. This is a clear reason not to equate
  all 83 disagreements with local errors.
- The shopping missing-check control is not a clean selector-only failure:
  `list.part` did not offer a checklist. Both providers selected `part`.

## 2. New targeted probes: expected-answer error rates

After inspecting the trace disagreements, constructed and froze **40 new
single-question requests and expected labels before either provider saw them**.
No labels or requests were edited after results. These deliberately target the
failure families; they are diagnostic probes, not a representative or blind
benchmark. Labels were authored by the investigating assistant, not independent
human adjudicators.

| Family | Probes | Local errors | TypeSafe errors |
|---|---:|---:|---:|
| Arithmetic/formula selection | 12 | 10 (83.3%) | 0 |
| Explicit seconds/minutes, balanced 6/6 | 12 | 6 (50.0%) | 0 |
| Countdown duration source | 8 | 1 (12.5%) | 0 |
| Structural added-part kind | 8 | 8 (100%) | 0 |
| **Total, targeted mix only** | **40** | **25 (62.5%)** | **0** |

Both providers repeated **40/40 choices** in a second pass. No missing answers,
invalid choices or transport failures in either pass. Forty TypeSafe successes
do not imply its true error rate is zero.

Probe content:

- Formulas: tip percentage, total bill, per-person split, budget left, quantity
  times price, average, end minus start, total distance, round-up division for
  boxes, remaining seconds, remaining minutes, rectangle area. Each request
  explicitly defines operands and offers one expected expression plus distractors
  and `unavailable`. Local got only tip and quantity-times-price correct.
- Units: six explicitly labelled minutes, six explicitly labelled seconds, with
  different names/ranges. Local selected **seconds for all 12**. Both the state
  and question contain the units; these short texts are not cut off by the
  tokenizer's 48-token limit.
- Duration: eight timer descriptions with an explicit duration input plus
  remaining/elapsed distractors. Local got seven correct, unlike 4/5 disagreements
  in captured questions. This difference cautions against assuming paraphrases
  and changed option IDs are distribution-neutral.
- Edit: checklist, editable note, bar chart, timer, rating slider, real calendar
  event, searchable list, data table. Used the captured app's full edit criteria.
  Local chose **progress_line seven times, none once**; TypeSafe chose the
  expected kind eight times. All eight state texts retain the requested change
  within the tokenizer's first 48 tokens.

Frozen probe file SHA256:

- Requests: `c2e7abc8d35a9d58afbc4e44867bc6b698aaf2a7e0fa3c34f8c8225321c9ec35`.
- Labels: `07fc4646b92d2c95d9270b95462bf94b85ef6791fcfa0c4cea4284fc3b7c4083`.

## Mechanisms to investigate, not yet proven causes

- The trained family vocabulary omits `arg`, `covers`, `detail`, `effect`,
  `itinerary`, `moment`; runtime maps them to family ID 0. Captured disagreement:
  12/25 (48.0%) for those families versus 71/197 (36.0%) for known families.
  Sparse, confounded evidence; missing families do not explain the known-family
  unit/formula/edit failures.
- Tokenizer serialization hard-caps each text at the first 48 tokens, although
  scorer code also names larger outer caps. Some real code-verification requests
  lose most of their source. This may explain some failures, but not short,
  explicit unit probes or the eight short edit requests above.
- Stable output preferences (seconds, progress_line, unavailable) warrant checking
  training family/label distributions, option-key/description serialization,
  tokenizer settings and train/export/runtime parity before more training.
  No training dataset or matching training-time feature vectors were supplied,
  so these mechanisms have not been validated.

## Evidence and next experiment

Private local evidence directory: `/tmp/local-jev-typesafe-comparison/`.
Includes frozen exact requests, predeclared labels, device C replay runner,
credential-safe cloud replay script, both passes, per-decision comparison,
family summaries, constructed probe generator and frozen probe results under
`probes/`. No keys/settings or historical traces are committed to this report.
The comparison did not change phone provider settings or install another HAP.

Next: preserve this set as regression evidence, obtain training/export parity
fixtures, then preregister a broader task-balanced, independently labelled set
with both providers' path provenance. Include option-order/ID paraphrase controls,
code verification and `noul`; report per-task and per-family metrics rather than
one extrapolated “overall model error rate”. Keep tuning and final evaluation
sets separate; do not tune on the fixed needs-plan-25 list.
