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
node tools/vera-harness/run.js entry/src/main/resources/rawfile/widget-counter.vera widget
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
