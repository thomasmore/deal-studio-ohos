# The agent: how a new screen is built

A new screen (the Generate screen, or a widget in the chat) is built by the **route** (`agent/VeraBuildRoute.ets`): the **agent**, then
the **whole screen as one hole**. A new screen is never written from scratch: what neither builds is reported as *not built*, with the
reason, on the Generate screen and in the chat alike. A change to an existing program goes to the model (refine), as before.

The idea: planning and building each have a fast path, where Jev picks something ready, and a slow path, where the model writes it. A simple
request is built from Jev's picks alone; the more a request asks that nothing ready does, the more of it the model writes, down to the whole
screen. **The composer's parts and the catalogue's sections are chosen together**, by the same Jev call, so there is no second planner: a
separate pick of sections and a layout from the request alone (`VeraTemplatePipeline.ets`, "the blocks", since deleted) used to follow the agent, and was
removed from the route because it never served -- none of the 121 prompts of the table below, none of 22 more on the merged choice.

## Games, toys, simulations, drawings: the surface route

A request that is something moving on its own or touched anywhere -- an arcade game, a tank battle, bouncing balls, a
drawing pad -- has no word in the plan of needs, and the parts would build it as a screen of buttons pretending to be one.
So the route asks first (`agent/AgentSurface.ets`, before the agent in `buildScreen`):

1. **Gate.** Only a request with a word that may mean such an app is asked about (`looksLikeSurface`, English and Chinese
   word lists); a to-do list never pays for the question.
2. **Brief.** One call to the plan model (`SURFACE_CLASSIFY_PROMPT`, no thinking, JSON): `surface` is `whole`, `part` or
   `none`. For `whole`, a short title and an original design -- goal, controls on a touch screen, objects, collisions,
   score, lives, levels, the look in hex colours. A named game is taken as its genre and mechanics, never its levels,
   names or artwork. For `part` (a roulette wheel beside the bets, dice above a score sheet, a signature pad on a form),
   a sentence of the scene, which goes to the agent with the request: see the next section. A `none`, or no answer,
   goes on to the agent as before.
3. **Write.** The model writes the whole program on one `ui.Surface` (`SURFACE_TOKENS`), shown the generation prompt with its
   catalogue cut to the surface's few components plus `std/gfx`, and its screen-composition advice replaced by
   `rawfile/vera-surface-skill.txt`: the shape of a frame-driven program, controls (drag, tap, a stick on the left half
   with fire on the right), collisions, limits, drawing and glow, and one complete example
   (`tools/vera-harness/examples/surface-catch.vera`, carried verbatim).
4. **Check.** Compiled, run once with every handler tapped (`VeraSmoke.ets`, which also draws every surface), then played
   (`VeraSurfacePlay.ets`): a tap in the middle, drags across it, 240 frames of 16 ms, every frame drawn. A trap, a blank
   surface or a scene that never changes is quoted back for a repair by edits (`repairProgram` with `checkSurfaceProgram`),
   at most twice; still failing, the program is written once more with thinking on.
5. **Served or not built.** A game that could not be written is reported as not built with the reason; the agent is not
   tried for it. `--ps veraSurface 0` sends every request to the agent, for comparison. Chat widgets never take this route.

Measured (deepseek-flash, 2026-10-30, one run each):

| prompt | where | served in | written | repair rounds | lines |
|---|---|---|---|---|---|
| neon arkanoid | host | 23 s | once | 1 (a `.length` without its call) | 531 |
| tank battle | host | 29 s | once | 1 (a missing local) | 650 |
| 帮我做一个小时候红白机风格的坦克大战 | host | 21 s | once | 0 | 512 |
| a drawing pad for kids with a few colours | host | 16 s | once | 1 | 237 |
| neon arkanoid | phone, Generate screen | 32.6 s | once | -- | -- |

"tic-tac-toe game" is not asked about and goes to the agent. On the phone the brick game plays in the preview at 50-56 fps
with 8-9 ms of program and painting per frame. The designs and the text on screen come back in English whatever the
request's language. Frames of the host runs are drawn with `tools/vera-harness/gfx-run.js`. Host check:
`tools/vera-harness/surface-route-check.js`.

### A scene inside a screen

A screen of forms and lists with one drawn, moving or touched picture among them is the agent's, with the picture as a
block of its own:

1. **Plan.** The plan of needs has a type `scene` (`NeedsPlan.ets`): what is drawn, what moves or is touched, what sets
   it moving, what it decides or changes. What a scene decides -- the number it lands on, a balance it pays into, the
   results so far, the records a signature is kept with -- belongs to the scene, not to figures or entries; the inputs
   the person sets for it stay inputs. A drawing is kept as its strokes, never as an image. When the route's classifier
   said `part`, its sentence is added to the request the plan is drawn from (`sceneNote`).
2. **Route.** A scene is carried as an item of `other` marked with `SCENE_MARK` (`VeraCompose.ets`): Jev is not asked
   whether a part covers it or whether it was asked for, Align never offers it a section, and it goes straight to the
   written section with the needs it changes (`comp.custom`).
3. **Write.** The section writer (`AgentCustom.ets`) is shown `SCENE_GUIDE` (`agent/AgentScene.ets`) with a worked
   example in the section's own form, a prize wheel, and has `SCENE_TOKENS` to write in. The guide's rules come from a
   roulette table written by hand and from the generations below: controls are components beside the surface, never
   drawn; the bet is copied into the scene's own fields when it starts and settled from those; the pocket a ball rests
   in is worked out in the wheel's frame, and a ball on a wheel is drawn at the wheel's angle plus its offset.
4. **Check.** The section is played before it is served (`playSurface(compiled, true, true)`): fingers on the surface
   first, and when they move nothing, each button on the screen pressed in turn with two more seconds of frames.

The renderer side, from the hand-written roulette (`tools/vera-harness/examples/surface-roulette.vera`): a surface
whose page is covered stops its loop (the router page observer), one scrolled out of view runs its frame handler but is
not drawn, a surface stands on the page with no card of its own, and a path string is drawn under the screen's density,
since ArkUI reads one in pixels.

Measured on the phone (Generate screen, deepseek, 2026-10-30, one run each):

| request | ready in | what came out |
|---|---|---|
| virtual casino roulette: bids, current bank, etc are forms, but they are accompanied with an animation of the roulette and ball | 29-30 s | three runs as the guide grew. 1: the number paid was worked out from the ball's angle alone, so the ball rested on another pocket. 2: the ball and the wheel snapped to the same angle on landing, the ball over pocket 0. 3: ball, number and bank agree (a $10 red bet on 25 took the bank from 500 to 510); the bet was locked in when the ball was thrown in all three |
| dice roller for board games: choose how many dice, roll them with a tumbling animation, and keep a history of the totals | 28.5 s | the dice tumble and settle, the total matches the faces, a row is added to the history; the total follows the faces while they tumble |
| delivery receipt: recipient name, number of parcels, and a signature pad where the recipient signs with a finger, then save the receipt to a list | 20.7 / not built / 32.1 s | 1: a list part with a "Signature" text field beside the pad; 2: not built, the plan asked for the signature "captured as an image" and Jev read every try as not doing it; 3: name, parcels, the pad, Save receipt and the list of receipts, saved as a row |

Host check: `tools/vera-harness/scene-hole-check.js` (mocked model).

A scene is only for a request that asks for something drawn, animated, moving or touched in its own words. The
classifier says so, and when it was asked and said `none` the plan's scenes are built as ordinary needs
(`sceneAllowed`, `plainScenes`): before that, "coin flip to decide who goes first, with a count of heads and tails" came
back from the classifier as `part` and from the plan as a tumbling coin, and took 48 s. Ordinary requests on the phone
(2026-10-30, one run each):

| request | classifier | scene | served in |
|---|---|---|---|
| a sign-up form for a yoga class with name, email and a level choice | asked ("sign"), none | no | 6.3 s |
| spinning class schedule for the week with times and instructors | asked ("spinning"), none | no | 9.4 s |
| tip calculator: bill amount, tip percent and number of people | not asked | no | 2.8 s |
| water reminder every 2 hours with a log of glasses drunk today | not asked | no | 18.3 s |
| coin flip to decide who goes first, with a count of heads and tails | none (was part) | built as an ordinary need | 22.1 s (was 48.3 s) |
| a breathing exercise timer with an animated circle that grows and shrinks | part | yes, beside the countdown | 13.7-50.6 s |

A gate word costs one classifier call of about 1.6 s. The breathing circle reads the countdown's phase but its label said
"Done" while it ran.

### Changing a game or a scene

A change typed under a program that draws on a `ui.Surface` (the Generate screen's refine, `editSurface` in
`GeneratePage.ets`) does not go to the general refine, which rewrote the whole program from a prompt that knows neither
guide and served it after one run. `agent/AgentSurfaceEdit.ets` shows the model the program, what it was made for and the
change, with the game guide (a surface that fills the screen) or the scene guide (one among sections, told that the
section's `__PASSTHROUGH__` is written out and that a new setting the scene settles from is copied in when it starts); the
model answers with SEARCH/REPLACE edits (a whole program only when most of it changes). The result is played as a new one
is -- fingers, and for a scene each button pressed -- and repaired by edits against that, at most twice; then asked once
more with thinking on. A change that does not pass leaves the program on the screen as it was and says why. A structural
edit of a composed screen (add, remove, move a block) is still tried first; one it hands on comes here. The change is
traced (`surface-edit`).

Measured (deepseek-flash, host, 2026-10-30, one run each):

| program | change | before (general refine, phone) | now |
|---|---|---|---|
| neon arkanoid, 470 lines | make the paddle wider and every tenth brick drops a power-up that splits the ball into three balls | 72 s, rewritten to 571 lines, not played | 29 s: 12 edits, one repair round after the play, 573 lines; played for 90 s on the host: wider paddle, the ball splits into up to four |
| examples/surface-roulette.vera, 377 lines | add a bet on a dozen that pays 2 to 1, and highlight the winning pocket | -- | 9-10 s, 10-12 edits, no repair; the new bet and the highlight work, but both runs settle the dozen wrongly: the first from the form while the ball runs, the second (with the rule about copying it in) from the previous spin's copy. Played, it passes; only a rule of the game itself catches that |

Host check: `tools/vera-harness/surface-edit-check.js` (mocked model).

## Terms

| term | what it is | where |
|---|---|---|
| **plan of needs** | what DeepSeek (no thinking) writes: a JSON object of inputs, constants and a list of *needs*, each of a type that says what the person sees -- `figure` (with its formula over neutral names, `entries.total`, `clock.remaining`; `shown: false` when it only feeds another), `countdown`, `stopwatch`, `entries`, `content` (written for the request), `action` (what the phone does, with its trigger) -- and at most two questions. It is told nothing of the parts or the catalogue. Content and action needs quote the request's own words; one whose quote is not in the request is not built | `NeedsPlan.ets` (`NEEDS_PROMPT`, `parseNeedsPlan`) |
| **sketch** | the plan as the composer reads it, which `sketchFrom` makes from the plan of needs: inputs, constants, values, a countdown or stopwatch, a list, events, *ready* needs (content a section does whole), other items. The composer's internal model; nobody writes it any more | `VeraCompose.ets` (`Sketch`, `parseSketch`) |
| **Jev's choice of a section or a part** | one Jev call, before the composer's own, with one question per need that a part and a section of the catalogue can both do (a countdown, entries the person keeps, content written for the request); the options are cut by the plan's own facts first | `NeedsChoose.ets` (`buildChooseRequest`) |
| **Jev's choices** | one Jev call over the sketch: a formula for each value, a widget for each input, an effect and a moment for each event, a catalogue section for each ready need, what is covered or left out | `buildComposeRequest`, `readComposition` |
| **block** | one piece of a program in the one format (`FragmentSpec`): state fields, handlers, a view, and tokens for content, ports and holes. The catalogue's **sections** (checklist, itinerary, timeline, charts, timer, reminders, ...) and the composer's **parts** (inputs, figures, clock, list, effects) are both blocks | `VeraTemplates.ets`, `compositionParts` |
| **ScreenPlan** | the one plan format both paths give: the screen's *state* (named values), its *slots* (each thing it does, with what it reads and writes, and whether it is a phone action) and the *components* that fill them. A slot is *open* until something fills it; a plan with an open slot is not served | `ScreenPlan.ets` |
| **effect** | one of six phone actions the composer wires itself: vibrate, beep, add to calendar, navigate, clear calendar, open calendar | `EFFECTS` in `VeraCompose.ets` |
| **hole** | what the model writes for slots nothing ready fills. A *catalogue hole* is one function body inside a section; a **section hole** is a whole section for the open slots; the **whole-screen hole** is the screen as one section | `VeraHoles.ets`, `agent/AgentHole.ets`, `agent/AgentCustom.ets` |
| ~~blocks~~ (removed) | Jev's pick of a layout and sections straight from the request, without a sketch; `VeraTemplatePipeline.ets` and the request rewrite it used (`VeraRequestExpand.ets`) are deleted; the alignment harness (`align-lib.js`) asks Jev for the pick itself | |
| **notice** | a warning banner in place of what could not be built: "Not available on this phone" with the writer's own sentence, or "Part of this app could not be built" | `noticeBlock` in `agent/AgentHole.ets` |

## The algorithm

1. **Plan.** DeepSeek writes the plan of needs (`drawPlan` in `NeedsChoose.ets`). One that is missing or does not parse is asked
   for again with what was wrong, then once with thinking on. A content or action need whose quote is not in the request is
   dropped before anything is built (`dropUnasked`; the note says what was not built and why), and a request that names one
   length of time ("a 10 minute timer") starts the one input that holds a length on it (`startOnRequested`).
2. **Questions.** Jev keeps only the sketch's questions a default cannot stand in for; the person answers on a card,
   and an answer other than the default has the plan drawn again.
3. **Choices.** One more Jev call (asked twice if it does not answer) decides how each remaining item is built. What the plan leaves
   open is settled, not refused:
   - a countdown nothing sets the length of, or a figure the parts read that no formula works out, becomes an input
     the person sets, starting from the plan's own number, and the person is told;
   - an event no effect does as asked, the person's own records, a figure nothing works out, an item of "other",
     a ready need with no section: a slot for the written section;
   - an input nothing uses is left out, with a note.
2b. **Part or section, one question per need** (`buildChooseRequest`, `NeedsChoose.ets`; one Jev call, which also asks which section
   each *content* need is, whose data it is, and whether it needs a search). Where a part and a section can both do a need, the
   question puts them side by side (`clock.part`: the part or `timer`; `list.part`: the part, `record_log` or `reminders`). What a
   section cannot stand in for is not offered, from the plan's own facts: `timer` only for a countdown of one fixed time with nothing at its
   end and no figure reading the time left (`timerMayTakeCountdown`); nothing that keeps entries when something happens as an entry is
   added or tapped, and only `record_log` when a figure reads the entries (`listSectionsFor`). A stopwatch is always the part. The
   answers go to the composer under the keys it reads, and its own call does not ask them again. A confident pick (the bar of any
   ready pick) takes the part's place -- the part is gone from the program, the section has a slot of its own (`section.<kind>`)
   and is read against the need by the claims check (`chooseSections`, `canReplaceClock`, `canReplaceList`, `replaceList` in
   `VeraCompose.ets`, which carry the pick out and still refuse it when a countdown's length is set by the person, a value reads the
   time left or the entries, or an event is at the countdown's end or on an entry). Without an answer from Jev the parts stay. A section
   is never added beside the part that does the same: Align's pool leaves out `timer` beside a countdown or a stopwatch and the
   entry-keeping sections beside a list that is wired to something (`alignKindsFor`). Host checks `needs-choose-check.js`, `merge-check.js`.
3a. **Align** (on by default, `--ps veraAlign 0` turns it off; `AgentAlign.ets`). What the choices leave for the model to write -- a ready
   need no section was chosen for, an event no effect does, an item of "other" -- is offered to the catalogue once more:
   one Jev question per such need, whose answers are a ready-made section (the plan's ready kinds, `reminders`,
   `calendar_event`) or none. A section at 0.5 or more is added once, whatever number of needs it does, and takes those
   needs out of what is written; what Jev finds none for is still written. The person's own records and the figures
   worked out by a written formula are never offered, and a section the screen already has does not stand in for a need.
   When nothing is left to write, the inputs the composer kept only for the written section are dropped. Measured so far:
   8 prompts live, one changed (`set an alarm for my medication every day` is a `reminders` section instead of a notice)
   and none given a section wrongly; not yet run on the 121 prompts or on a phone.
   The default pool (`--ps veraAlign 1` gives the plain one: ready kinds, `reminders`, `calendar_event`) offers every section that stands alone, not only the plan's ready kinds (timer, note, rating,
   record_log and progress_goal as well), bar `actions`, `metrics`, `intent_panel` and `filter_box`. What is still left is then
   asked once more among the **readers** (`list_summary`, `number_strip`, ...) a section on the screen can feed: every port the
   reader reads must be published, by name and type, by a section chosen already (`readerKinds`). Host-checked (`align-agent-check.js`) and run on
   the phone on five short prompts: no section was chosen wrongly (`reminders@0.97` for a daily water reminder, `none` for a workout timer
   with notes), the readers' question was never reached (a checklist's "how many are done" is dropped before Align sees it).
   The composer's parts publish ports too (`compositionParts`): the inputs a person sets, the list's `entries` and `count`,
   and, only when a section on the screen reads a port, each value as a function `port_<id>(state)`. A section that reads
   a name a part publishes is bound to it by name; naming is the plan's, so this meets rarely until the plan's values
   are matched to a reader's ports by a question of their own (not built).

4. **Fill.** The catalogue sections' content is written (from a web search when it must be real) and their holes
   filled, by the one fill both the agent and the blocks use (`SectionFill.ets`): a trend chart is always grounded in a
   search whatever the plan said (with the longer results), and with no search the sections are refused. A current figure
   of the real world is not the agent's: Generate writes it on a live source before the route (`docs/live-sources.md`), and
   the `live_facts` block that once did it is removed.
4b. **Slots and claims.** What each chosen section offers (a button for each item, a calendar, a style) is read from the
   request by one Jev call (`buildSlotRequest`); without it the catalogue's defaults leave out what the request asks for.
   What the composer left out because a section is said to do it (`comp.claimed`) is then read against the assembled
   screen (`agent/AgentClaims.ets`); a claim the screen does not meet goes back to the plan as a slot to write, and the
   hole that follows writes it or reports it. The plan's own questions to the person are part of every "did the request
   ask for this" question to Jev (inputs, figures, fields and items of "other" alike).
5. **Section hole.** One section is written for the open slots (`writeHole`, `writeSection`):
   - for every need the app's own lookups run first (in parallel; the plan's `phone` flag no longer decides whether to look) (`find_intent_function`, keyword and embedding rankings
     together; `find_sdk_function`), and the section may call only targets they returned -- every `sdk.call` target is
     checked before serving;
   - it is compiled and run once with every handler tapped; failures are quoted back for a repair, at most twice;
   - Jev reads it against each need; a need it reads as not done is asked for again;
   - after the quick tries, one more with thinking on;
   - still failing: the best try that works and does part of it is served with a notice for what it misses; none, a
     notice in its place; `<cannot>` (nothing on this phone does it) is reported as the writer says and not retried;
   - needs are decided one by one: the writer may decline a need with `<cannot need="...">` and write the section for the
     rest (the declined need gets its own notice, in the writer's words); a bare `<cannot>` for a hole of several needs
     is not taken for the answer to each -- every need is then written on its own with only the functions found for it.
6. **Check.** The assembled program is compiled, started, drawn and run with every handler tapped (`VeraSmoke.ets`); one
   that fails, or draws an empty screen, is repaired with SEARCH/REPLACE edits, at most twice (`settleProgram`). Every
   program served goes through it, whoever assembled it: the agent, the blocks, a written section or the whole screen.
   **Record.** A served screen that rebuilds exactly from its plan gets a record (`VeraComposition.ets`, `AgentResult.record`):
   the plan's components in order, the catalogue's blocks with their values and hole bodies, everything else (the composer's
   parts, a written section, a notice) as it is. A request to add a section, take one away, swap or move one is then
   answered without the model (`tryStructuralEdit`); it may point at the catalogue's blocks and the written section or
   notice, never at a part (the parts hold each other's state). No record when the repair edited the program, and none is
   kept that does not rebuild the served one. A chat widget is not edited this way.
7. **Whole screen**, when the agent did not build it: the sketch as one hole, with the same lookups and checks.
8. **Not built**, with what the agent said.

A request's holes share what they learned: a phone need one hole found nothing can do is reported by the next as it
said, and each lookup is made once. A refusal of several needs together is not remembered for any of them.

## What a screen says about itself

- A notice (something could not be built, or is not available on this phone) removes the screen's subtitle: the plan wrote it
  before anything was built, and a subtitle that promises what the notice denies contradicts it (`quietSubtitle`,
  `AgentHole.ets`).
- The plan may say how many digits a plain number is shown with (`decimals`, 0 to 6; list fields and values), because one digit
  rounds a measurement into nonsense; money, percent and counts keep their own.
- The section writer is told that a need worded as something to do inside the app that the app cannot do (it has no such
  component) is not refused when a function found does the nearest useful thing in the app made for it, and to say on the screen
  what it does instead (`phoneRule`, `AgentCustom.ets`).
- The time the person takes to answer a question of the plan is measured apart (`Asked.waitedMs`) and said apart ("Composed in
  5.6 s (and 6.6 s waiting for your answer)"): it is theirs, not the app's.
- The Metrics tab shows this run only: where the time went stage by stage (`RunStages.ets`), the model calls with their tokens,
  speed and cost, the lookups the app's own tools made (`ToolLog.ets`) and which of Jev, Exa and DeepSeek answered
  (`ServiceHealth.ets`). Nothing is kept for the next session.

## Results

Host runs (`tools/vera-harness/agent-run.js -r`, the 121 prompts of `compose-fresh.tsv`, `compose-prompts.tsv` and
`tools/vera-bench/prompts.tsv`), 2026-10-22. The host has no phone lookups, so a phone action there always ends in
a notice; on the phone the same prompts call the phone.

| how it was built | prompts | median | p90 |
|---|---|---|---|
| agent, composer parts only | 88 | 2.0 s | 2.5 s |
| agent + written section | 17 | 6.7 s | 14.4 s |
| agent + notice (phone actions, live data) | 13 | 5.8 s | 9.5 s |
| agent + catalogue sections | 3 | 5.6 s | 7.1 s |
| blocks, whole screen, not built | 0 | | |

Eight game-like requests (tic-tac-toe, hangman, memory, flashcards, ...): all written by the agent, 5-13 s.

On the phone: Shanghai layover 10-23 s, soft-egg timer 2.5 s, to-do list 14 s, hangman 20 s, contacts 6-9 s,
melody with the flashlight 22.6 s; "set an alarm" and "share my location" 6-7 s with a notice (the phone exposes no
target that does either). Generation from scratch, which these replace, took over 30 s for requests like Shanghai and
the melody.

## The merge, measured (host, 2026-10-26, short prompts)

The six prompts of `docs/prompts/block-composition.md` that the removed blocks stage built without a model, before and after the parts and
the sections were chosen together (same run, same Jev and DeepSeek; the host has no web search):

| prompt | before | after |
|---|---|---|
| shared costs between friends, who owes whom | 8.7 s, one section written by the model | 8.6 s, `record_log` + `number_strip` + `breakdown_table` + `settle_up`, one section written |
| roommates split groceries and rent | 8.6 s, written | 4.9 s, `record_log` + `settle_up`, no model |
| log workout minutes, bar chart | 15.5 s, four sections written | 4.0 s, `record_log` + `series_chart` + `number_strip`, no model |
| budget tracker with category charts | refused (a chart section with invented data) | 10.1 s, `record_log` + `series_chart` + `number_strip` + `progress_goal` |
| hours worked per team member | refused | 7.5 s, `record_log` + `breakdown_table` |
| points per player in a board game | 7.0 s, written | 3.9 s, `data_table` (the entries are the person's: see the known problems) |

Fixed after that table, one by one (host runs of the same prompts, then the phone):
- A section that writes content of its own (a checklist's items, a table's rows) is not given a need about the person's own data -- what they
  entered, what is worked out from it, marks on their own entries (`whose.N` in Align's request, read by the probability of "own", as the
  composer's own `whose` question is; the two cases were `checklist` for "mark a settlement as paid" and `data_table` for the people's scores).
  Readers, the sections that keep entries and the phone ones are not refused.
- A need left to write is read against the screen the chosen sections make (`claimsDone`, `AgentClaims.ets`): a detail the log already
  settles in its own way ("a category picker") is not written again; with no answer from Jev nothing is taken for done.
- A total or the entries' own numbers of minutes or seconds are shown as "150 min", not as 2:30:00 or 0:00 (`showEntryTotalsAsNumbers`,
  `entryAmountText`); a countdown is still a clock.
- The run-to-run differences seen between the host and the phone came from the sketch DeepSeek writes: the same prompt gave the same
  choice 10 times of 10 on the host (`workout` and `budget`, `record_log` at 0.55 to 0.92), and on the phone after the fixes.

Still open: a stopwatch is always the part (the `timer` section only counts down), and what to do with a detail Jev is unsure the log does.

## The plan of needs, measured (phone, 2026-10-27)

The old path (the model writes the sketch, knowing the parts and the catalogue; Jev and the composer choose between a part and a section
afterwards) against the plan of needs, on 25 fixed short prompts (`docs/prompts/needs-plan-25.md`, one run each on the same build, the top
of each screen read): the plan of needs was not worse on any prompt after two fixes, and better on nine. What it found, and what was done:

- A length of time the plan wrote as `"kind": "time", "measure": "seconds"` was read as a time of day, so no formula could use it: an
  interval timer showed a length of five minutes of its own, a study timer 0:00. A `time` input with a measure of seconds or minutes is a
  number now, and a figure a countdown's length is made of does not read the clock it sets (`lengthFeeders`; `length-feeders-check.js`).
- Better than before the switch: a plank timer starts at 1:00 and has no unasked progress bar, "every 2 hours" is 2:00:00 (the old path
  gave 1:00:00), a stopwatch has a list of laps, a shopping list or a workout log has no unasked totals, notes have the search field.
- Not tried: the buttons and formulas after a person types, the ~121 prompts of the table above, a second run (the model's plan varies:
  one run had a "Total minutes" figure for the study timer and the next did not).

`--ps veraNeeds` and `--ps veraUnified` are gone: the plan of needs is the only way to build a screen, and the old sketch prompt, its `ready`
paragraph and `composeWith` with it. What carries out Jev's choice is the composer's, and stays. Recorded sketches stand in for the
model's plan in the host checks (`tools/vera-harness/needs-lib.js`: `needsOf`, `asPlan`).

## Switches and tools

- `--ps veraCustom 0` turns written sections off;
  `--ps veraWhole 0` the whole-screen hole; `--ps veraAlign 0` turns off the offer of what would be written to the catalogue first (`1` for the plain pool).
- Host checks run under node with `VERA_TYPESCRIPT_PATH` naming a `typescript` package (the kit's is under
  `~/agent-kit-sdk/command_line_tools/ohpm/node_modules/typescript`).
- `tools/vera-harness/agent-run.js [-r] [-w]` runs the agent (or the whole route: the agent, then the whole screen) live on the host: DeepSeek
  (`$ARKESTR_API_KEY`), Jev (`$TYPESAFE_API_KEY`), Exa (`$EXA_API_KEY`, optional).
- Every written hole is recorded: a `hole` event in the app's trace, `holes.jsonl` beside each host run.
  `tools/vera-harness/hole-report.py` groups the needs that recur -- the blocks the catalogue lacks.
- Host checks: `tools/vera-harness/{agent,plan,parts,compose,route,pipeline,section-fill,align,align-agent,needs-plan,needs-choose,merge,length-feeders}-check.js`;
  fixtures in `tools/vera-harness/compose/` (recorded sketches, read as plans of needs through `needs-lib.js`) and `tools/vera-harness/needs-plans/`.
  Two checks, `calendar-sdk-check.js` and `chat-handoff-check.js`, fail on a clean tree and are not about this.

## Known limits

- This phone has no target that creates a Clock alarm, texts a phone number (MeeTime's `SendTextMessage` takes a
  MeeTime contact id) or shares the live location; such requests end with a notice.
- `contacts/AddContact` wants a vCard in `contactInfo`; the intent index does not say so, and the call is declined.
- Jev reads code, not behaviour: a melody section whose beats all fired at once was read as doing its job.
- Each live run of the 121 prompts makes several hundred Jev calls.

## Screen shortcomings found in a 20-prompt phone run, and what was done (2026-10-27)

Twenty short prompts were run on the phone before and after; every one was served, none fell to a generation. Fixed:
the notice for a part that could not be built is one plain sentence (`agent/AgentHole.ets`, no plan wording on screen); `checklist` rows no
longer say "not done" and use a list icon, and it is not offered for a deck of cards; the header has no icon unless there is a clock or a list;
the itinerary row has no coordinates; a number field names its unit when the label does not (`labelWithUnit`); choice options "25 minutes"
whose values are 1500 are seconds, not minutes; a fraction shows four digits; a section the model writes is told what the parts already hold
(`partsContract`, `PartsContract` in `VeraCompose.ets`) and is asked again, at most twice, when it makes its own clock or list
(`repeats` in `agent/AgentCustom.ets`); a need for a progress bar is not given to `progress_goal` when a fraction value is already drawn as one
(`alignCandidates`); Align is told what the screen already shows; `claimsDone` also reads screens made of parts alone.

Not fixed: the dice roller gets a log with a Result field (left as it is); two blocks for laps still appear in some runs (a list of laps and a
"Lap splits" view of the same entries) because the writer sometimes keeps its own; "Average mood 0.0" with no entries; a BMI category;
an empty chart plate when a chart has no data yet.
