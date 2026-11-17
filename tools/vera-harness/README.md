# vera-harness

The harness runs the current VERA-L compiler, VM, UI host, and decoder under Node.
It requires no device, native build, or installation.
`source-loader.js` transpiles `entry/src/main/ets` directly in each process.
It uses the existing `src/VeraSdkIndex.ts` stub to avoid native SDK dependencies.
The harness does not read the historical `out` JavaScript copies.

Use an available TypeScript installation with Node module resolution.
Alternatively, set `VERA_TYPESCRIPT_PATH` to the TypeScript module entry file before these commands.
No dependency installation is required when that module is available.

Run these commands from the repository root:

```bash
node tools/vera-harness/run.js tools/vera-harness/examples/visual-counter.vera > /tmp/vera-counter.json
node tools/vera-harness/proof-sheet.js --width=360 --preset=clean --label=counter < /tmp/vera-counter.json > /tmp/vera-counter.svg
```

The optional arguments for `run.js` are the entry function and serialized state:

```bash
node tools/vera-harness/run.js path/to/program.vera view '["o","AppState",[["count",["i",7]]]]'
```

Without supplied state, `run.js` calls `init()` before `view()`.
The state argument uses the VM tagged-tuple format, not a plain JSON object.
Compiler failures print diagnostics and exit with status 1.

`proof-sheet.js` accepts these options:

| Option | Behavior |
| --- | --- |
| `--width=320`, `--width=360`, `--width=600` | Set the approximate viewport width. Other positive widths also work. |
| `--preset=clean` | Override the fixture theme and seed. Supports all six presets. |
| `--dark=true` | Resolve the dark palette. |
| `--embedded=true` | Cap display and metric sizes at 32 for widget proofs. |
| `--label=counter` | Set the SVG title and metadata label. |
| `--select-wrap=false` | Reproduce the previous unwrapped Select layout. |

Without `--preset`, the proof uses the root `AppTheme` preset and seed.
The proof uses actual resolved colors, semantic type sizes, generic font families, spacing, and radii.
It supports Hero and ordered adaptive columns with the native inset and gap rules.
It wraps text at its full type size, including inside narrow containers and table cells.
It formats integer prefixes and suffixes and hides Ticker nodes.
`When` is already resolved by the real UI host before the proof receives the tree.
Unsupported kinds appear as labeled boxes.

Text width is an estimate from character counts and rough character classes.
The proof does not use ArkUI measurement or actual font metrics.
Generic fonts can differ between hosts and devices.
Native buttons have a fixed control height.
The proof increases button height when an estimated label wraps, so the complete label remains visible.
This height difference is a proof approximation.
These SVGs help inspect hierarchy, wrapping, grouping, and approximate shape.
They do not verify exact device layout, animation, keyboard behavior, or full accessibility conformance.
No live model generates the proof fixtures.

For a repeatable theme and width comparison:

```bash
node tools/vera-harness/run.js tools/vera-harness/examples/visual-expense.vera > /tmp/vera-expense.json
node tools/vera-harness/proof-sheet.js --width=320 --preset=technical < /tmp/vera-expense.json > /tmp/vera-expense-320.svg
node tools/vera-harness/proof-sheet.js --width=600 --preset=technical --dark=true < /tmp/vera-expense.json > /tmp/vera-expense-600-dark.svg
node tools/vera-harness/proof-sheet.js --width=360 --preset=editorial --embedded=true < /tmp/vera-counter.json > /tmp/vera-widget.svg
node tools/vera-harness/visual-check.js /tmp/vera-visual-verification.json
```

For baseline proofs, set `VERA_SOURCE_ROOT` to a saved pre-change `entry/src/main/ets` directory.
The loader then reads that snapshot instead of current sources.
Use a compatible baseline fixture or a previously saved decoded tree.
When semantic family fields are absent, the proof retains the previous all-role `fontFamily` and uncapped embedded type sizes.
Each new process loads its selected sources again, so a previous build cannot supply stale output.

`examples/*.vera` also contain focused Select, feedback, Sparkline, TextField, and BackHandler workflows.
`compatibility/*.json` stores bytecode and saved state from the current build for the five visual workflows, so a change to the bytecode or saved-state format shows up as a failure. The pre-redesign set from `b3acfcf` stopped loading when `int` was removed (its bytecode calls `IntText`); it is still in git history.
`visual-check.js` records the tested revision, command, decoded trees, and expected-versus-observed checks in JSON.
Native validation still requires the toolchain described in `CLAUDE.md`.

For shared-state screen identity, stale controls, timer/surface teardown and Back:

```bash
node tools/vera-harness/multiscreen-check.js
```

See the [runtime contract](../../docs/multiscreen-runtime.md). Host SVGs are approximate proofs, not native-device evidence.

For the multi-screen planning/shared-writer path and refinement preservation:

```bash
VERA_TYPESCRIPT_PATH=/path/to/typescript/lib/typescript.js node tools/vera-harness/app-plan-check.js
```

Real compiler/VM with mocked model/phone boundaries: planning, Generate/Chat handoff, drafts, refinement preservation and repair feedback. `template-run-check.js` covers existing Chat tabs; `chat-prompt-check.js` covers terminal multi-view failures.

For deterministic screen reachability (no phone or model calls):

```bash
node tools/vera-harness/reachability-check.js                 # regression tests
node tools/vera-harness/reachability-check.js /path/app.vera # check generated c_view_<id> screens
# Or append explicit screen IDs: /path/app.vera list detail editor
```

The same bounded UI-path check runs automatically in `smokeRun` for declared pages and named Chat tabs; failures feed the existing repair loop. Single-view apps skip it. See [multi-view generation](../../docs/multiscreen-agent.md) for search limits and coverage caveats.

A `ui.Surface` is drawn by the program itself, frame by frame, so its proofs come from playing it.
`gfx-run.js` runs `init()`, `view()`, then fixed-step frames with scripted fingers, and draws chosen frames to SVG with `VeraGfx.paintGfx`, the phone's own painter, through the canvas recorder in `gfx-svg.js`:

```bash
node tools/vera-harness/gfx-run.js tools/vera-harness/examples/surface-catch.vera --frames=480 --dt=16 --every=60 \
  --box=360x740 --out=/tmp/catch --events='[[5,"down",0,180,600],[6,"up",0,180,600],[100,"down",1,180,590],[160,"move",1,260,590],[260,"up",1,260,590]]'
```

An event is `[frame, phase, id, x, y]` in the surface's own units, delivered before that frame.
The elapsed time is the step, not the clock, so a run draws the same frames every time.
It writes `frame-NNNN.svg` and a `sheet.svg` of them side by side, and prints what each drawn frame held.
`gfx-check.js` checks std/gfx, the surface's compile-time checks, colours, fitting and finger mapping, the smoke run, and that the sample game plays.
`surface-mixed-check.js` checks a surface as one block of a form screen (`examples/surface-roulette.vera`: the bank, stake, bet and history are components, the wheel is the surface).
The Spin button and a tap on the wheel throw the same ball, and the pocket it is drawn in is the number paid.
The bet is the one the ball was thrown with, even when the form changes while it runs.
The bank adds up over 400 spins.
Given a directory, it also writes `roulette-sheet.svg`.
`surface-edit-check.js` checks a change to a game or a scene with a mocked model: the guide shown, edits applied, a change that crashes mid-game repaired after it is played, one that never passes not served.
`scene-hole-check.js` follows a scene through the agent with a mocked model: the classifier's three answers, the plan's `scene` need, the composer and Align leaving it to the written section, the scene guide's example playing, a scene only a button starts, and the writer repairing a scene that never moves.

## 3D textures, particles and imported models

`ui.World` programs describe their scene on state changes; the host owns physics, motion and particle frames.
The capabilities and play-check limits are described in `docs/agent.md` under **Solid things in 3D**. From the
repository root, with TypeScript available as above:

```bash
python3 tools/model-catalog.py --check
for check in scene world shapes interaction world-play; do
  node "tools/vera-harness/$check-check.js" || exit 1
done
for check in texture texture-renderer texture-cache particles particles-renderer models models-renderer; do
  node "tools/vera-harness/$check-check.js" || exit 1
done
node tools/vera-harness/texture-proofs.js /tmp/opencode/texture-proofs.png
```

The proof output's parent directory must already exist. The PNG is a host raster proof of all 11 patterns on a
cube, cylinder and floor patch using the actual texture pixels and metre-based UV meshes, not an ArkGraphics3D capture.

| Check | What it verifies on the host |
| --- | --- |
| `texture-check.js` | The 11 material patterns' determinism, wrapping/seams, two-colour output and keys; legacy sphere patterns remain separate. |
| `texture-renderer-check.js` | Actual renderer methods with mocked platform boundaries: PNG creation/reuse, materials, UVs, groups, ground, updates and failures. |
| `texture-cache-check.js` | Resource bookkeeping and disk cleanup targeting 256 managed PNGs; active readers/writers are skipped, unmanaged files, directories and symlinks untouched. This is not a hard disk cap while files are active. |
| `particles-check.js` | Five burst kinds, deterministic trajectories, lifetimes, floor clamping and eviction at 256 particles / 16 bursts. |
| `particles-renderer-check.js` | Mocked renderer pool, independent imported no-shadow materials, native alpha versus Canvas spatial fade, live backdrop transitions, trigger-driven/automatic effects, lifecycle and failures; not native compositing proof. |
| `models-check.js` | All 36 catalogue entries against packaged GLBs, hashes, transformed geometry, hull containment, scaling, orientation and catalogue-derived API/prompt. |
| `models-renderer-check.js` | Mocked model loads/imports, shared sources, per-body instances, transforms, picking, updates, failures and cleanup; not native memory or shadow proof. |
| `world-check.js`, `interaction-check.js`, `world-play-check.js` | Scene API validation/diffs, change-edge bursts and automatic effects, scripted play and repair diagnostics, including P0020/P0021. |

`scene.paint`'s material patterns are `wood`, `planks`, `brick`, `tiles`, `stone`, `grass`, `sand`, `metal`,
`marble`, `checker`, `fabric`; primitives, group parts/groups and ground use metre UVs. Sphere-only patterns
remain sphere-only. `scene.burst` supports `sparks`, `smoke`, `dust`, `debris`, `confetti`: initial trigger 0 is
silent, each change (even back to 0) emits, and changing other fields alone does not. Blasts add debris/smoke,
shot contacts add sparks, and hard watched knocks add dust automatically; explicit bursts should not duplicate them.
With no Canvas backdrop, particles retain source-alpha × lifetime-fade material blending. Explicit sky (including
zero stars), stars, trails or stationary glow halos select the phase-2 opaque shrinking-cube fallback for all kinds:
size × `cbrt(clamp(effectiveAlpha, 0, 1))`, alpha 1 when positive, hidden at zero, unchanged RGB. Low source alpha
therefore means smaller opaque cubes. Live particles switch both ways on the next frame without replacing their
independent imported BLEND/unlit no-shadow materials. This is a workaround for the confirmed native-to-Canvas
sRGB/premultiplication boundary, not global alpha support; TEXTURE does not fix it. It remains until a platform fix.

Model names/descriptions are the generated `VeraModels.ets` catalogue and `rawfile/models/models.json`, not a
second handwritten list here. The 36 static CC0 Kenney Racing Kit 2.0 models keep their materials; size is the
largest side, y the support bottom, and the host converts source +z forward to body +x. Motion, mark and rings work;
paint/glow/group-part use/split do not. Collision is a convex hull, so visible openings are not passable.
The asset directory includes `LICENSE.txt` and `SHA256SUMS`. Provenance is the public extracted-file mirror
`Tiddybub/3d-assets`, pinned at `11ff7082e566a6278553bf7623980cb93dd41e27`, **not an official ZIP**.
`python3 tools/model-catalog.py --check --source /path/to/pinned-extracted-inputs` additionally compares reproducible
outputs against supplied source inputs and their manifest; `--check` alone verifies the local packaged set.

Play codes are **P0020** (texture readability) and **P0021** (model grounding), not the plan's provisional numbers.
P0020 estimates initial projected boxes and sampled ground coverage, only for sufficiently dominant paint; it is
not pixel/occlusion/contrast analysis or a guarantee for every view. P0021 checks static models' rotated hull support
when a floor/table exists, excluding from/shot/aim/orbit/path/wander; it does not check loose models, free-space
worlds, stable balance or exact visible-mesh contact. See `docs/agent.md` for thresholds and scope.

Focused fixtures: `examples/world-textures-{table,floor,parts-glow}.vera`,
`examples/world-particles-{static,automatic,combined300}.vera`, and
`examples/world-models-{catalog,forest,player}.vera`. They exercise textured ground/parts, explicit and automatic
bursts (including a 300-body scene), 12 fixed catalogue samples with two swaps, 30 trees and a steered model. Running them on the host
is not evidence that every model renders on-device. All-36 device coverage, native particle alpha blending/model
shadows and native-memory behaviour remain subject to current device verification; no such completion is claimed here.

### Retired phase-0 exploratory probe

The `worldSpike` launch flag/routes, page/controller tail, five packaged synthetic GLBs and obsolete
`world-spike-check.js` were removed on 2026-11-19. Historical measurements and exact pre-removal SHA-256 hashes
remain in `results/world-spike-phase0-2026-11-18.json`. They are not current product acceptance results.
`models-renderer-check.js` now asserts that spike sources, routes and fixtures stay out of product packaging,
while retaining the literal product rawfile descriptor and model recovery tests.

The locally authored fixture generator remains host-only:

```bash
python3 tools/world-spike-fixtures.py
python3 tools/world-spike-fixtures.py --check
python3 tools/world-spike-fixtures.py --output /tmp/opencode
python3 tools/world-spike-fixtures.py --check /tmp/opencode
```

Default and bare `--check` validate deterministic generation entirely in memory, with no file writes.
`--output` requires an explicit existing directory inside the host temporary directory and outside this repository;
`--check HOST_DIR` validates an explicit existing host directory outside the repository without writing.
There is no product rawfile auto-output. These fixtures do not replace the retained phase 1–3 product suites
above or native verification; host resource counts do not measure native memory.

The prompt workflow harness executes application request and repair methods with mocked HTTP responses:

```bash
node tools/vera-harness/prompt-check.js . /tmp/vera-prompt-verification.json
```

For capability preparation and chat handoff workflows:

```bash
node tools/vera-harness/capability-check.js /tmp/vera-capability-verification.json
node tools/vera-harness/chat-handoff-check.js . /tmp/vera-chat-handoff-verification.json
```

The capability workflow mocks native registry reads, downloads, and embedding boundaries.
It runs the current index loaders and shared preparation service.
The 10-second readiness deadline runs at 20 milliseconds in this host fixture.
The chat workflow mocks model transport and storage, then compiles and runs widget fixtures.
Each report records the revision, exact command, inputs, and expected and observed checks.
These checks do not replace a native ArkTS build or a live-model evaluation.

For the bounded home-screen live-counter proof (see `docs/live-widget-proof.md`):

```bash
node tools/vera-harness/live-widget-check.js
node tools/vera-harness/live-form-check.js
node tools/vera-harness/run.js tools/vera-harness/examples/widget-counter.vera widget
```

Both `view` and `widget` entry functions receive `init()` state when no state argument is provided.

`node tools/vera-harness/widget-refine-check.js` checks Make widget's additive preservation contract,
optional entry signature, catalogue-derived instructions, widget smoke diagnostics and saved-state validation.
`live-widget-check.js` also covers dynamic repeated rows and disappearing-item/stale taps without ListGroup/ListItem.
`capability-check.js /tmp/vera-capability.json` executes the renderer's existing-runner resume/background methods
with the real compiler/VM and mocked platform boundaries. These host checks do not replace a native build or device QA.

For the full labeled proof matrix, use an available `sharp` module and a baseline source snapshot:

```bash
VISUAL_BASELINE_DIR=$(mktemp -d)
git archive df66e50276ea66ffa7f29a527e5f847491ea99ff entry/src/main/ets | tar -x -C "$VISUAL_BASELINE_DIR"
node tools/vera-harness/visual-proofs.js /tmp/vera-visual-proofs "$VISUAL_BASELINE_DIR/entry/src/main/ets"
```

Set `NODE_PATH` when an existing `sharp` installation requires an explicit module path.
The matrix includes 96 SVG/PNG proofs, decoded trees, source hashes, and 16 labeled contact sheets.
The baseline renders the bytecode in `compatibility/*.json` with the theme source from the baseline snapshot. Since those fixtures were regenerated after the `int` removal, it no longer shows the pre-redesign composition; check out `b3acfcf` to reproduce the original comparison.
The candidate uses current fixture sources. Compact counter widgets use the same source in both phases.
The matrix changes composition and rendering together, so it does not isolate their individual effects.
