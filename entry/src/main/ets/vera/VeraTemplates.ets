/**
 * The catalogue of blocks and the closed sets Jev answers from.
 *
 * SlotSpec and VetoSpec are the closed-set questions (VeraSectionCompose.ets asks them in one request): a
 * cosmetic choice per slot, and a yes/no gate on the whole request. ContentFieldSpec holds the title and
 * item/label text instead. These are NOT answered by Jev -- they are filled, best-effort, by
 * VeraTemplateContent.ets's separate narrow generative call, with a literal fallback on any failure. This is
 * the one place in the pipeline that renders text from the user's own request rather than a fixed closed-set
 * identifier.
 *
 * FragmentSpec is the one block format: the catalogue's sections (fragments()) and the composer's parts
 * (VeraCompose.ets) are both FragmentSpecs.
 *
 * Shape follows docs/examples/shanghai-layover.vera: import, @jsonable state, init(), pure updaters, view().
 * Only `//` comments are legal in this language -- a /* block *\/ will not parse.
 *
 * Every style token substituted into a block is one already registered in VeraUiCatalog.ets's STYLE_SETS
 * (apptheme, header, listgroup, metricgroup, intstat) -- checked there, not invented here.
 */

export class SlotSpec {
  /** Token text in the template source, e.g. "__THEME__". */
  token: string
  /** Allowed values, in the order offered to Jev. First is the safe default. */
  values: string[]
  /** 'choice' or 'noul' -- which Jev question shape asks for this slot. */
  kind: string
  /** Question text sent to Jev for this slot. */
  instructions: string
  /** criteria text per value, only used for 'choice' slots (key = value). */
  criteria: Map<string, string>
  /**
   * Probability a 'noul' slot must exceed to take its second value; -1 uses the cosmetic default. A slot that
   * changes what a block shows, not just how it looks, needs a higher bar than a cosmetic one: Jev said yes at
   * 0.3 to "show the balances instead of the totals" for a request that only mentioned both.
   */
  above: number
  /**
   * The phone actions (the composer's effect ids) the block does itself once this slot takes its second value: a screen that
   * also keeps a part for one of them would show the same button twice.
   */
  provides: string[]
  constructor(token: string, values: string[], kind: string, instructions: string, criteria: Map<string, string>, above: number = -1,
      provides: string[] = []) {
    this.token = token
    this.values = values
    this.kind = kind
    this.instructions = instructions
    this.criteria = criteria
    this.above = above
    this.provides = provides
  }
}

/**
 * A shared yes/no gate asked once per request, independent of which template
 * matches -- unlike SlotSpec there is no token to substitute and no `values`
 * list, just a probability that can kill the whole pick. See readPick's veto
 * loop in VeraSectionCompose.ets.
 */
export class VetoSpec {
  /** Stable key in the request/response, prefixed "veto." there. */
  key: string
  instructions: string
  /** criteria text for 'true'/'false', same shape as a SlotSpec noul's. */
  criteria: Map<string, string>
  /**
   * Above this probability, this question alone kills the pick. Each veto
   * gets its own bar rather than one shared constant: the gold-set sweep in
   * tools/template-select-eval.py found that a single shared threshold
   * cannot separate every question's true-accept distribution from its
   * true-reject distribution at once -- e.g. a music player's "needs a phone
   * API" answer (~0.45, must stay rejected) sits well below a grocery list's
   * "needs search" answer (~0.59, must stay accepted), so no single cutoff
   * works for both dimensions simultaneously; each question's own bar does.
   */
  above: number
  constructor(key: string, instructions: string, criteria: Map<string, string>, above: number) {
    this.key = key
    this.instructions = instructions
    this.criteria = criteria
    this.above = above
  }
}

/**
 * One free-text display field inside an already-picked template: a title or
 * an item/stat label. Unlike SlotSpec/VetoSpec this is never asked of Jev --
 * it is filled by VeraTemplateContent.ets's separate narrow generative call,
 * with `fallback` used verbatim whenever that call fails for this field.
 */
export class ContentFieldSpec {
  /** Token text in the template source, e.g. "__TITLE__". */
  token: string
  /** JSON key asked of the content-fill model, e.g. "title". */
  key: string
  /** Literal fallback -- exactly today's hardcoded copy. */
  fallback: string
  /** One-line instruction fragment used to build the content-fill prompt. */
  hint: string
  /** Hard cap on visible characters, enforced before substitution. */
  maxLength: number
  /** True for a bare number literal spliced unquoted into an array (e.g. a chart value), not a quoted string. */
  numeric: boolean
  constructor(token: string, key: string, fallback: string, hint: string, maxLength: number, numeric: boolean = false) {
    this.token = token
    this.key = key
    this.fallback = fallback
    this.hint = hint
    this.maxLength = maxLength
    this.numeric = numeric
  }
}

/**
 * The standing info banner as a bare view expression, for VeraSectionCompose.ets's composer -- which
 * builds `view()` as a sequence of `sections.push(...)` calls rather than one array literal.
 */
export function bannerSectionView(): string {
  return `ui.Section("supporting", "", "", [
      ui.InsetBanner("default", "Demo banner", "This screen comes from a canned template; nothing here is personalized.", "", "", "info")
    ])`
}

/**
 * One field in a FragmentSpec's merged AppState contribution. `name` contains the literal
 * substring "IDX", substituted by the composer with the fragment's 1-based slot instance number
 * so two instances of the same kind never collide (e.g. "itemsIDX" -> "items1"/"items2").
 */
export class StateFieldSpec {
  name: string
  type: string
  constructor(name: string, type: string) {
    this.name = name
    this.type = type
  }
}

/**
 * A list-valued parameter of a fragment: a run of rows whose count the model chooses, between
 * `minRows` and `maxRows`, where a ContentFieldSpec is always exactly one string. The expanded rows
 * are spliced into the fragment text at `token` the same way a content field's value is, so the
 * composer needs no special case -- see VeraTemplateContent.ets's expandListRows for the checks
 * every row goes through (shape, count, length, escaping) and the fallback when the answer is not
 * usable.
 */
export class ListFieldSpec {
  /** Token in the fragment text, containing "IDX", e.g. "__ITEMS_IDX__". */
  token: string
  /** JSON key asked of the content-fill model, e.g. "items". */
  key: string
  /** What the rows are, one line, for the model. */
  hint: string
  /** One entry per column: what the column holds, for the model. A one-column list is an array of strings. */
  columnHints: string[]
  /** Character cap per column, enforced before substitution. */
  columnMax: number[]
  /** Text of one row; "{0}", "{1}", ... stand for the (already escaped) column values. */
  rowTemplate: string
  /** Text placed between rows. */
  separator: string
  minRows: number
  maxRows: number
  /** The rows used when the answer is missing or unusable; one string[] per row, one string per column. */
  fallbackRows: string[][]
  /** Indices of columns that are whole numbers, spliced unquoted (as a bare number literal) instead of as escaped text. */
  numericColumns: number[]
  /**
   * Per column, a value check applied before splicing: '' none, 'lat' and 'lon' (a decimal within the range of a
   * latitude / longitude, else the cell becomes empty), 'number' (a number with an optional fraction, else 0), 'minutes' (a whole number 5 to 600, else 60), 'seconds' (a whole number 5 to 86400, else 60).
   */
  columnChecks: string[]
  constructor(token: string, key: string, hint: string, columnHints: string[], columnMax: number[], rowTemplate: string,
      separator: string, minRows: number, maxRows: number, fallbackRows: string[][], numericColumns: number[] = [],
      columnChecks: string[] = []) {
    this.token = token
    this.key = key
    this.hint = hint
    this.columnHints = columnHints
    this.columnMax = columnMax
    this.rowTemplate = rowTemplate
    this.separator = separator
    this.minRows = minRows
    this.maxRows = maxRows
    this.fallbackRows = fallbackRows
    this.numericColumns = numericColumns
    this.columnChecks = columnChecks
  }
}

/**
 * A typed gap in a fragment that the model fills with the body of one function. The fragment text
 * carries `token` inside `function <name>IDX(<params>): <returns> { token }`; the composer splices in
 * either the model's body or `defaultBody`, wrapped in //@hole markers so a compile error can be
 * traced back to this hole (VeraHoles.ets). `defaultBody` must always compile and behave sensibly:
 * a hole the model cannot fill costs nothing but the customisation.
 */
export class HoleSpec {
  /** Stable key without the instance number, e.g. "rowMatches"; the model's answer key is key + slot number. */
  key: string
  /** Token in the fragment text, containing "IDX". */
  token: string
  /** What the model is told the function is: name, parameters and return type. */
  signature: string
  /** What the function decides, one or two sentences for the model. */
  purpose: string
  /** Body used when the model gives none or a body that does not compile. */
  defaultBody: string
  /** A kind that must also be on the screen for the model to be asked; '' asks whenever the fragment is. The default body applies either way. */
  when: string
  /** false for a hole the host fills from data it checked (the intent panel's rows): the model is never asked for it. */
  byModel: boolean
  /** True when the body may call the phone through sdk.call: the model is then shown the SDK functions found for the request. */
  usesSdk: boolean
  /** A slot token of this fragment that must have come out 'true' for the model to be asked ('' asks whatever the slots say). */
  slot: string
  constructor(key: string, token: string, signature: string, purpose: string, defaultBody: string, when: string = '',
      byModel: boolean = true, usesSdk: boolean = false, slot: string = '') {
    this.key = key
    this.token = token
    this.signature = signature
    this.purpose = purpose
    this.defaultBody = defaultBody
    this.when = when
    this.byModel = byModel
    this.usesSdk = usesSdk
    this.slot = slot
  }
}

/**
 * A connection point of a fragment to state another fragment owns or provides. A `writes` port
 * publishes one of the fragment's own state fields under a shared `name`; a `reads` port asks for
 * a value of that `name` and `type`. The composer (VeraSectionCompose.ets's bindPorts) replaces a
 * reads port's `token` in the fragment text with `state.<field>` of a chosen publisher, or with
 * `fallback` when no chosen fragment publishes that name and type -- so a fragment never needs to
 * know which other fragments are on the screen.
 */
export class PortSpec {
  /** 'writes' (publishes a field) or 'reads' (consumes a value). */
  dir: string
  /** Shared key, e.g. "selected". A reads port binds only to a writes port of the same name and type. */
  name: string
  /** Vera type of the value, e.g. "number" or "Entry[]". */
  type: string
  /** writes: the state field published, containing "IDX". reads: the token in the fragment text, e.g. "__PORT_selected__". */
  ref: string
  /** reads only: a Vera expression of `type` used when nothing publishes this name. */
  fallback: string
  /**
   * writes only: `ref` is a Vera expression over `state` (containing "IDX"), not a state field name --
   * a value derived from the fragment's state, such as how many rows are done.
   */
  computed: boolean
  /**
   * reads only: the fragment makes sense without it (its fallback stands in), so it still stands alone and is not a reader of
   * another block; a value the screen's own figures may give it, such as the time by which a list of stops must be over.
   */
  optional: boolean
  constructor(dir: string, name: string, type: string, ref: string, fallback: string = '', computed: boolean = false,
      optional: boolean = false) {
    this.dir = dir
    this.name = name
    this.type = type
    this.ref = ref
    this.fallback = fallback
    this.computed = computed
    this.optional = optional
  }
}

/**
 * A pre-authored, parameterized building block for VeraSectionCompose.ets's composer, picked per
 * section slot. See VeraSectionCompose.ets's header comment for the full composition
 * design (instance indexing, the __PASSTHROUGH__ token, why local view() variables need no
 * indexing but AppState fields and function names do).
 */
export class FragmentSpec {
  /** Stable id, e.g. "checklist", "metrics". */
  kind: string
  /** Shown to Jev as this kind's criteria text for a section slot's `choice` question. */
  criteria: string
  /** A @jsonable support class this kind needs (e.g. "Item"), or '' if none. Deduped by the composer when the same kind is chosen more than once. */
  supportClass: string
  /** This kind's contribution to the merged AppState, names containing "IDX". */
  stateFields: StateFieldSpec[]
  /** Statements run inside init() before the return, containing "IDX"; '' if none needed. */
  initStatements: string
  /** This kind's piece of init()'s returned object literal (no surrounding braces), containing "IDX". */
  initEntries: string
  /** This kind's handler function(s), full text, containing "IDX" and exactly one "__PASSTHROUGH__". */
  functions: string
  /** A `{ ... sections.push(...) ... }` block appended inside view(), containing "IDX" and this kind's own slot/content tokens (which also contain "IDX"). */
  viewBlock: string
  /** Per-instance cosmetic slots; tokens contain "IDX". */
  slots: SlotSpec[]
  /** Per-instance content fields; tokens contain "IDX". */
  contentFields: ContentFieldSpec[]
  /**
   * Full `import * as x from "std/y"` lines this kind needs beyond the always-present
   * `import * as ui from "std/ui"` (e.g. `std/sdk`, `std/strings` for a capability-bound kind).
   * Deduped by the composer when more than one chosen kind needs the same module.
   */
  imports: string[]
  /** List-valued parameters, filled the same way as contentFields but with a model-chosen number of rows. */
  listFields: ListFieldSpec[]
  /** Connection points to other fragments' state; empty for a self-contained fragment. */
  ports: PortSpec[]
  /** Typed gaps the model fills with function bodies; empty for a fragment with nothing to customise that way. */
  holes: HoleSpec[]
  /**
   * Veto keys (VeraTemplates.vetoes) whose concern this block already handles: a form with several
   * fields, per-person running totals, a calculation. When any chosen block covers a veto, that veto no
   * longer sends the request to the model to add what the block already has.
   */
  covers: string[]
  /**
   * Vetoes covered only in some configurations: "needs_integration=__NAVIGATE_IDX__|__CALENDAR_IDX__" covers that veto when
   * any of the named noul slots came out 'true' -- a block whose phone actions are switched off does not cover a request that
   * wanted them.
   */
  coversIf: string[]
  /**
   * False for a block made for one request (VeraCompose.ets's parts): its names are already unique and its text
   * holds the person's words, so "IDX" in it is not renamed.
   */
  indexed: boolean = true
  /**
   * What the block already holds or lets the person set, in words for whoever decides what else the screen needs (Jev's choice of what a
   * section covers): "the start time of the day", so that no separate input for it is put on the screen. '' when it says nothing beyond criteria.
   */
  owns: string = ''
  /** The name of the block's tab in a widget in a chat reply (one or two words); '' for its kind in words. */
  tab: string = ''
  constructor(kind: string, criteria: string, supportClass: string, stateFields: StateFieldSpec[],
      initStatements: string, initEntries: string, functions: string, viewBlock: string,
      slots: SlotSpec[], contentFields: ContentFieldSpec[], imports: string[] = [], listFields: ListFieldSpec[] = [],
      ports: PortSpec[] = [], holes: HoleSpec[] = [], covers: string[] = [], coversIf: string[] = []) {
    this.kind = kind
    this.criteria = criteria
    this.supportClass = supportClass
    this.stateFields = stateFields
    this.initStatements = initStatements
    this.initEntries = initEntries
    this.functions = functions
    this.viewBlock = viewBlock
    this.slots = slots
    this.contentFields = contentFields
    this.imports = imports
    this.listFields = listFields
    this.ports = ports
    this.holes = holes
    this.covers = covers
    this.coversIf = coversIf
  }
}

function checklistFragment(): FragmentSpec {
  let listStyle: Map<string, string> = new Map<string, string>()
  listStyle.set('default', 'normal spacing')
  listStyle.set('compact', 'tighter spacing')
  listStyle.set('comfortable', 'looser spacing')
  return new FragmentSpec(
    'checklist',
    'A browsable list of items the person can check off or mark one at a time; it is not a deck of cards to flip, a quiz or a game',
    `@jsonable
class Item {
  label: string;
  detail: string;
  done: boolean;
}`,
    [new StateFieldSpec('itemsIDX', 'Item[]')],
    `  let itemsIDX: Item[] = [
    __ITEMS_IDX__
  ];`,
    `itemsIDX: itemsIDX`,
    `function toggleIDX(state: AppState, index: number): AppState {
  let out: Item[] = [];
  let i: number = 0;
  while (i < state.itemsIDX.length()) {
    let it: Item = state.itemsIDX[i];
    if (i === index) {
      out.push({label: it.label, detail: it.detail, done: !it.done});
    } else {
      out.push(it);
    }
    i = i + 1;
  }
  return {itemsIDX: out__PASSTHROUGH__};
}

function doneCountIDX(state: AppState): number {
  let n: number = 0;
  let i: number = 0;
  while (i < state.itemsIDX.length()) {
    let it: Item = state.itemsIDX[i];
    if (it.done) { n = n + 1; }
    i = i + 1;
  }
  return n;
}`,
    `{
    let count: number = state.itemsIDX.length();
    let rows: ui.View[] = [];
    let j: number = 0;
    while (j < count) {
      let it: Item = state.itemsIDX[j];
      let icon: string = "list";
      let subtitle: string = it.detail;
      if (it.done) { icon = "check"; subtitle = "done"; if (it.detail.length() > 0) { subtitle = it.detail + " - done"; } }
      rows.push(ui.ListItem("default", it.label, subtitle, "", "toggleIDX", j, true, icon));
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(count === 0, ui.EmptyState("default", "Nothing here", "Add an item to get started.", "", "", "pin")),
      ui.When(count > 0, ui.ListGroup("__LIST_STYLE_IDX__", "", rows))
    ]));
  }`,
    [new SlotSpec('__LIST_STYLE_IDX__', ['default', 'compact', 'comfortable'], 'choice',
      'How dense should the list rows be?', listStyle)],
    [],
    [],
    [new ListFieldSpec('__ITEMS_IDX__', 'items',
      'The things on the list, as many as the request needs (3 to 8); each with an optional short detail such as a quantity',
      ['name of the item', 'short detail such as a quantity or a note, or an empty string'], [28, 20],
      '{label: "{0}", detail: "{1}", done: false}', ',\n    ', 3, 8,
      [['First item', ''], ['Second item', ''], ['Third item', '']])],
    [new PortSpec('writes', 'done', 'number', 'doneCountIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'state.itemsIDX.length()', '', true)]
  )
}

function metricsFragment(): FragmentSpec {
  let metricStyle: Map<string, string> = new Map<string, string>()
  metricStyle.set('default', 'normal spacing')
  metricStyle.set('compact', 'tighter spacing')
  metricStyle.set('spacious', 'looser spacing')
  let accent: Map<string, string> = new Map<string, string>()
  accent.set('default', 'no, same tone as the rest')
  accent.set('accent', 'yes, highlighted')
  return new FragmentSpec(
    'metrics',
    'A small dashboard of a few summary numbers with a couple of actions',
    '',
    [new StateFieldSpec('countIDX', 'number'), new StateFieldSpec('totalIDX', 'number')],
    '',
    `countIDX: 0, totalIDX: 100`,
    `function incrementIDX(state: AppState, ignored: number): AppState {
  return {countIDX: state.countIDX + 1, totalIDX: state.totalIDX__PASSTHROUGH__};
}

function resetIDX(state: AppState, ignored: number): AppState {
  return {countIDX: 0, totalIDX: state.totalIDX__PASSTHROUGH__};
}`,
    `{
    let remaining: number = state.totalIDX - state.countIDX;
    sections.push(ui.Section("summary", "", "", [
      ui.MetricGroup("__METRIC_STYLE_IDX__", 3, [
        ui.NumberStat("default", "__STAT1_LABEL_IDX__", state.countIDX, "", "", 1, "", "pin"),
        ui.NumberStat("__ACCENT_STAT_IDX__", "__STAT2_LABEL_IDX__", state.totalIDX, "", "", 1, "", "check"),
        ui.NumberStat("default", "__STAT3_LABEL_IDX__", remaining, "", "", 1, "", "clock")
      ])
    ]));
    sections.push(ui.Section("content", "", "", [
      ui.ActionBar("spread", [
        ui.Button("primary", "Add one", "incrementIDX", 0, true),
        ui.Button("secondary", "Reset", "resetIDX", 0, true)
      ])
    ]));
  }`,
    [
      new SlotSpec('__METRIC_STYLE_IDX__', ['default', 'compact', 'spacious'], 'choice',
        'How dense should the summary numbers be?', metricStyle),
      new SlotSpec('__ACCENT_STAT_IDX__', ['default', 'accent'], 'choice',
        'Should the middle number stand out with an accent tone?', accent)
    ],
    [
      new ContentFieldSpec('__STAT1_LABEL_IDX__', 'stat1_label', 'Count', 'Label for the first number shown (1-2 words)', 16),
      new ContentFieldSpec('__STAT2_LABEL_IDX__', 'stat2_label', 'Total', 'Label for the second number shown (1-2 words)', 16),
      new ContentFieldSpec('__STAT3_LABEL_IDX__', 'stat3_label', 'Remaining', 'Label for the third number shown (1-2 words)', 16)
    ]
  )
}

/**
 * A countdown. ui.Ticker/onTick is a pure in-app clock (VeraPreview.ets drives it with a real setInterval). The duration is one
 * fixed time or a short list of named presets (soft / medium / hard, tea strengths, work and rest); with several presets a chooser
 * appears and picking one resets the clock. When the countdown reaches zero the `whenFinished` hole runs once: the default does
 * nothing, and when the request asks for the phone to do something then (vibrate, notify, make a sound) the model writes the
 * body, which may call a phone function through sdk.call. The SDK functions it may use are the ones found for the request, and
 * the compiler rejects a target that does not exist. Answers follow docs/intent-call-contract.md: only "declined..." and
 * "error..." are failures.
 */
function timerFragment(): FragmentSpec {
  return new FragmentSpec(
    'timer',
    'A countdown or stopwatch that ticks by itself, with a start/pause toggle and a reset; the duration is one fixed time or a short list of named presets, and the phone can vibrate or notify when it ends',
    `@jsonable
class TimerPreset {
  name: string;
  seconds: number;
}`,
    [new StateFieldSpec('presetsIDX', 'TimerPreset[]'), new StateFieldSpec('pickIDX', 'number'),
     new StateFieldSpec('elapsedMsIDX', 'number'), new StateFieldSpec('runningIDX', 'boolean'), new StateFieldSpec('timerNoteIDX', 'string')],
    `  let presetsIDX: TimerPreset[] = [__PRESETS_IDX__];`,
    `presetsIDX: presetsIDX, pickIDX: 0, elapsedMsIDX: 0, runningIDX: false, timerNoteIDX: ""`,
    `function rebuildTimerIDX(state: AppState, pick: number, elapsedMs: number, running: boolean, note: string): AppState {
  return {presetsIDX: state.presetsIDX, pickIDX: pick, elapsedMsIDX: elapsedMs, runningIDX: running, timerNoteIDX: note__PASSTHROUGH__};
}

function limitMsIDX(state: AppState): number {
  let at: number = state.pickIDX;
  if (at < 0 || at >= state.presetsIDX.length()) { at = 0; }
  return state.presetsIDX[at].seconds * 1000;
}

function whenFinishedIDX(pick: number): number {
__HOLE_WHENFINISHED_IDX__
}

function onTickIDX(state: AppState, elapsedMs: number): AppState {
  if (!state.runningIDX) { return state; }
  let limit: number = limitMsIDX(state);
  let next: number = state.elapsedMsIDX + elapsedMs;
  if (next >= limit) {
    let ignored: number = whenFinishedIDX(state.pickIDX);
    return rebuildTimerIDX(state, state.pickIDX, limit, false, state.timerNoteIDX);
  }
  return rebuildTimerIDX(state, state.pickIDX, next, true, state.timerNoteIDX);
}

function toggleRunningIDX(state: AppState, value: boolean): AppState {
  if (value && state.elapsedMsIDX >= limitMsIDX(state)) { return rebuildTimerIDX(state, state.pickIDX, 0, true, ""); }
  return rebuildTimerIDX(state, state.pickIDX, state.elapsedMsIDX, value, state.timerNoteIDX);
}

function resetTimerIDX(state: AppState, ignored: number): AppState {
  return rebuildTimerIDX(state, state.pickIDX, 0, false, "");
}

function choosePresetIDX(state: AppState, index: number): AppState {
  return rebuildTimerIDX(state, index, 0, false, "");
}

function onFinishedAnswerIDX(state: AppState, value: string): AppState {
  let note: string = "";
  if (strings.startsWith(value, "declined") || strings.startsWith(value, "error")) { note = value; }
  return rebuildTimerIDX(state, state.pickIDX, state.elapsedMsIDX, state.runningIDX, note);
}`,
    `{
    let limitSec: number = limitMsIDX(state) / 1000;
    let elapsedSec: number = state.elapsedMsIDX / 1000;
    let remainingSec: number = limitSec - elapsedSec;
    if (remainingSec < 0) { remainingSec = 0; }
    let presetNames: string[] = [];
    for (let p: TimerPreset of state.presetsIDX) { presetNames.push(p.name); }
    let chosen: string = "";
    if (state.pickIDX >= 0 && state.pickIDX < presetNames.length()) { chosen = presetNames[state.pickIDX]; }
    let clock: ui.View[] = [];
    clock.push(ui.Ticker("default", "timerIDX", 1000, state.runningIDX, "onTickIDX"));
    clock.push(ui.NumberText("display", remainingSec, "", "s left", 1));
    clock.push(ui.Progress("accent", chosen, elapsedSec, limitSec));
    clock.push(ui.When(remainingSec <= 0, ui.InsetBanner("success", "Time is up", "The countdown has finished.", "", "", "check")));
    sections.push(ui.Section("content", "", "", clock));
    let controls: ui.View[] = [];
    if (presetNames.length() > 1) {
      controls.push(ui.Select("default", "__PRESET_LABEL_IDX__", presetNames, state.pickIDX, "choosePresetIDX"));
    }
    controls.push(ui.Toggle("default", "__TIMER_LABEL_IDX__", state.runningIDX, "toggleRunningIDX"));
    controls.push(ui.ActionBar("spread", [
      ui.Button("secondary", "Reset", "resetTimerIDX", 0, true)
    ]));
    sections.push(ui.Section("content", "", "", controls));
    sections.push(ui.Section("supporting", "", "", [
      ui.When(state.timerNoteIDX !== "", ui.InsetBanner("danger", "The phone said no", state.timerNoteIDX, "", "", "info"))
    ]));
  }`,
    [new SlotSpec('__FINISH_ACTION_IDX__', ['false', 'true'], 'noul',
      'Does the request ask for the phone to do something when the countdown ends, such as vibrate, play a sound or show a notification?',
      timerFinishCriteria(), 0.6)],
    [
      new ContentFieldSpec('__TIMER_LABEL_IDX__', 'timer_label', 'Running', 'Label of the start/pause switch (1-3 words, such as Running or Start the timer)', 24),
      new ContentFieldSpec('__PRESET_LABEL_IDX__', 'preset_label', 'Preset', 'Label of the choice of preset (1-3 words, e.g. Doneness)', 20)
    ],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"'],
    [new ListFieldSpec('__PRESETS_IDX__', 'presets',
      'The durations to choose from (1 to 6): a short name and its length in seconds. One row when the request names one duration or none (use 1500 seconds then).',
      ['name of the preset (1-3 words)', 'length in seconds, a whole number'], [20, 6],
      '{name: "{0}", seconds: {1}}', ',\n    ', 1, 6,
      [['Timer', '1500']], [1], ['', 'seconds'])],
    [],
    [new HoleSpec('whenFinished', '__HOLE_WHENFINISHED_IDX__',
      'whenFinished(pick: number): number',
      'Runs once when the countdown reaches zero; pick is the index of the chosen preset (0 for the first). Do what the request asks to happen ' +
      'at that moment by calling the phone: sdk.call("<target>", ["<name>", "<value>", ...], "onFinishedAnswerIDX"), where <target> is one of the ' +
      'SDK functions listed below and the parameter names and values come from its description. Then return 0. Do nothing else.',
      '  return 0;', '', true, true, '__FINISH_ACTION_IDX__')],
    [],
    ['needs_integration=__FINISH_ACTION_IDX__']
  )
}

function timerFinishCriteria(): Map<string, string> {
  let m: Map<string, string> = new Map<string, string>()
  m.set('true', 'yes, something happens on the phone when it ends')
  m.set('false', 'no, the countdown only shows that time is up')
  return m
}

/**
 * A list the person builds one entry at a time: a title, a time of day (hour and minute) and whether it repeats every day. With the
 * calendar slot on, every new entry goes into the phone calendar through the one verified call
 * ("CalendarKit.Calendar.addEvent", with a reminder at the start time and a daily repeat when asked), each row shows what the
 * calendar answered, and removing a row removes its event. Answers follow docs/intent-call-contract.md: the answer to addEvent is
 * the event id, only "declined..." and "error..." are failures. The block is the multi-field form, so it covers
 * needs_search_or_form, and with the calendar on it covers needs_integration. Publishes how many entries are scheduled (done) and
 * how many there are (total) for the readers that take those ports.
 */
function remindersFragment(): FragmentSpec {
  let calendar: Map<string, string> = new Map<string, string>()
  calendar.set('true', 'yes, each entry goes into the phone calendar with a reminder')
  calendar.set('false', 'no, the entries are only a list in the app')
  return new FragmentSpec(
    'reminders',
    'A list the person builds one entry at a time, each with a title, a time of day (hour and minute) and whether it repeats every day; ' +
    'entries can be put into the phone calendar with a reminder and removed, and the list shows what is scheduled and what the ' +
    'calendar answered. For medicines, habits, appointments, daily reminders; not a day plan made of places',
    `@jsonable
class Reminder {
  title: string;
  hour: number;
  minute: number;
  daily: boolean;
  eventId: string;
  status: string;
}`,
    [new StateFieldSpec('remindersIDX', 'Reminder[]'), new StateFieldSpec('draftTitleIDX', 'string'),
     new StateFieldSpec('draftHourIDX', 'number'), new StateFieldSpec('draftMinuteIDX', 'number'),
     new StateFieldSpec('draftDailyIDX', 'boolean'), new StateFieldSpec('pendingIDX', 'number'), new StateFieldSpec('reminderNoteIDX', 'string')],
    `  let remindersIDX: Reminder[] = [];`,
    `remindersIDX: remindersIDX, draftTitleIDX: "", draftHourIDX: 8, draftMinuteIDX: 0, draftDailyIDX: true, pendingIDX: -1, reminderNoteIDX: ""`,
    `function withDraftIDX(state: AppState, title: string, hour: number, minute: number, daily: boolean): AppState {
  return {remindersIDX: state.remindersIDX, draftTitleIDX: title, draftHourIDX: hour, draftMinuteIDX: minute, draftDailyIDX: daily, pendingIDX: state.pendingIDX, reminderNoteIDX: state.reminderNoteIDX__PASSTHROUGH__};
}

function withListIDX(state: AppState, list: Reminder[], pending: number, note: string, title: string): AppState {
  return {remindersIDX: list, draftTitleIDX: title, draftHourIDX: state.draftHourIDX, draftMinuteIDX: state.draftMinuteIDX, draftDailyIDX: state.draftDailyIDX, pendingIDX: pending, reminderNoteIDX: note__PASSTHROUGH__};
}

function failedIDX(value: string): boolean {
  return strings.startsWith(value, "declined") || strings.startsWith(value, "error");
}

function scheduledCountIDX(state: AppState): number {
  let n: number = 0;
  for (let r: Reminder of state.remindersIDX) { if (r.status === "ok") { n = n + 1; } }
  return n;
}

function setTitleIDX(state: AppState, value: string): AppState {
  return withDraftIDX(state, value, state.draftHourIDX, state.draftMinuteIDX, state.draftDailyIDX);
}

function setHourIDX(state: AppState, value: number): AppState {
  let hour: number = math.floor(value);
  if (hour < 0) { hour = 0; }
  if (hour > 23) { hour = 23; }
  return withDraftIDX(state, state.draftTitleIDX, hour, state.draftMinuteIDX, state.draftDailyIDX);
}

function setMinuteIDX(state: AppState, value: number): AppState {
  let minute: number = math.floor(value);
  if (minute < 0) { minute = 0; }
  if (minute > 59) { minute = 59; }
  return withDraftIDX(state, state.draftTitleIDX, state.draftHourIDX, minute, state.draftDailyIDX);
}

function setDailyIDX(state: AppState, value: boolean): AppState {
  return withDraftIDX(state, state.draftTitleIDX, state.draftHourIDX, state.draftMinuteIDX, value);
}

function addReminderIDX(state: AppState, ignored: number): AppState {
  let title: string = strings.trim(state.draftTitleIDX);
  if (title.length() === 0) { return state; }
  let useCalendar: boolean = __CALENDAR_IDX__;
  let status: string = "";
  let pending: number = -1;
  if (useCalendar) {
    status = "pending";
    pending = state.remindersIDX.length();
  }
  let out: Reminder[] = [];
  for (let r: Reminder of state.remindersIDX) { out.push(r); }
  out.push({title: title, hour: state.draftHourIDX, minute: state.draftMinuteIDX, daily: state.draftDailyIDX, eventId: "", status: status});
  if (useCalendar) {
    let repeat: string = "once";
    if (state.draftDailyIDX) { repeat = "daily"; }
    sdk.call("CalendarKit.Calendar.addEvent",
      ["title", "__EVENT_PREFIX_IDX__" + title, "hour", ui.numberToString(state.draftHourIDX), "minute", ui.numberToString(state.draftMinuteIDX),
       "durationMinutes", "15", "remindBefore", "0", "repeat", repeat, "description", "__EVENT_NOTE_IDX__"], "onAddedIDX");
  }
  return withListIDX(state, out, pending, "", "");
}

function onAddedIDX(state: AppState, value: string): AppState {
  if (state.pendingIDX < 0 || state.pendingIDX >= state.remindersIDX.length()) { return state; }
  let out: Reminder[] = [];
  let i: number = 0;
  while (i < state.remindersIDX.length()) {
    let r: Reminder = state.remindersIDX[i];
    if (i === state.pendingIDX) {
      if (failedIDX(value)) {
        out.push({title: r.title, hour: r.hour, minute: r.minute, daily: r.daily, eventId: "", status: value});
      } else {
        out.push({title: r.title, hour: r.hour, minute: r.minute, daily: r.daily, eventId: value, status: "ok"});
      }
    } else {
      out.push(r);
    }
    i = i + 1;
  }
  let note: string = "";
  if (failedIDX(value)) { note = value; }
  return withListIDX(state, out, -1, note, state.draftTitleIDX);
}

function removeReminderIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.remindersIDX.length()) { return state; }
  let gone: Reminder = state.remindersIDX[index];
  let out: Reminder[] = [];
  let i: number = 0;
  while (i < state.remindersIDX.length()) {
    if (i !== index) { out.push(state.remindersIDX[i]); }
    i = i + 1;
  }
  let pending: number = state.pendingIDX;
  if (pending === index) { pending = -1; }
  if (pending > index) { pending = pending - 1; }
  if (gone.eventId !== "") { sdk.call("CalendarKit.Calendar.deleteEvents", ["ids", gone.eventId], "onRemovedIDX"); }
  return withListIDX(state, out, pending, "", state.draftTitleIDX);
}

function onRemovedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return withListIDX(state, state.remindersIDX, state.pendingIDX, value, state.draftTitleIDX); }
  return state;
}

function openCalendarIDX(state: AppState, ignored: number): AppState {
  sdk.call("com.huawei.hmos.calendar/phone/MainAbility", [], "onOpenedIDX");
  return state;
}

function onOpenedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return withListIDX(state, state.remindersIDX, state.pendingIDX, value, state.draftTitleIDX); }
  return state;
}`,
    `{
    let useCalendar: boolean = __CALENDAR_IDX__;
    let count: number = state.remindersIDX.length();
    let canAdd: boolean = strings.trim(state.draftTitleIDX).length() > 0;
    sections.push(ui.Section("content", "__FORM_TITLE_IDX__", "", [
      ui.TextField("default", "__TITLE_LABEL_IDX__", state.draftTitleIDX, "setTitleIDX"),
      ui.NumberField("default", "Hour (0-23)", state.draftHourIDX, 0, 23, "setHourIDX"),
      ui.NumberField("default", "Minute (0-59)", state.draftMinuteIDX, 0, 59, "setMinuteIDX"),
      ui.Toggle("default", "__REPEAT_LABEL_IDX__", state.draftDailyIDX, "setDailyIDX"),
      ui.ActionBar("end", [
        ui.Button("primary", "Add", "addReminderIDX", 0, canAdd)
      ])
    ]));
    let rows: ui.View[] = [];
    let j: number = 0;
    while (j < count) {
      let r: Reminder = state.remindersIDX[j];
      let when: string = ui.clockToString(r.hour * 60 + r.minute);
      if (r.daily) { when = when + " - every day"; }
      let shown: string = "";
      let icon: string = "list";
      if (useCalendar) {
        if (r.status === "pending") { shown = "sending..."; icon = "clock"; }
        else if (r.status === "ok") { shown = "in calendar"; icon = "check"; }
        else if (r.status !== "") { shown = "not added"; icon = "info"; }
      }
      rows.push(ui.ListItem("default", r.title, when, shown, "", 0, false, icon));
      if (useCalendar && r.status !== "ok" && r.status !== "pending" && r.status !== "") {
        rows.push(ui.InsetBanner("warning", "The calendar said no", r.status, "", "", "info"));
      }
      rows.push(ui.ActionBar("end", [ui.Button("secondary", "Remove", "removeReminderIDX", j, true)]));
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(count === 0, ui.EmptyState("default", "Nothing yet", "Add the first one above.", "", "", "list")),
      ui.When(count > 0, ui.ListGroup("default", "", rows))
    ]));
    let notes: ui.View[] = [];
    if (state.reminderNoteIDX !== "") {
      notes.push(ui.InsetBanner("warning", "Last action", state.reminderNoteIDX, "", "", "info"));
    }
    if (useCalendar) {
      notes.push(ui.ActionBar("spread", [ui.Button("secondary", "Open calendar", "openCalendarIDX", 0, true)]));
    }
    if (notes.length() > 0) { sections.push(ui.Section("supporting", "", "", notes)); }
  }`,
    [new SlotSpec('__CALENDAR_IDX__', ['false', 'true'], 'noul',
      'Should each entry be put into the phone calendar with a reminder, with a button to open the calendar?', calendar, 0.6,
      ['calendar_add', 'calendar_open'])],
    [
      new ContentFieldSpec('__FORM_TITLE_IDX__', 'form_title', 'Add a reminder', 'Heading of the form (2-4 words)', 24),
      new ContentFieldSpec('__TITLE_LABEL_IDX__', 'title_label', 'Name', 'Label of the title field (1-3 words, such as Medicine or Habit)', 20),
      new ContentFieldSpec('__REPEAT_LABEL_IDX__', 'repeat_label', 'Repeats every day', 'Label of the switch for a daily repeat (2-4 words)', 28),
      new ContentFieldSpec('__EVENT_PREFIX_IDX__', 'event_prefix', '', 'Words put before the title in the calendar event, such as "Take " for medicines, or an empty string', 12),
      new ContentFieldSpec('__EVENT_NOTE_IDX__', 'event_note', 'Reminder', 'A short note for the calendar event (2-6 words, no quotes)', 40)
    ],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"'],
    [],
    [new PortSpec('writes', 'done', 'number', 'scheduledCountIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'state.remindersIDX.length()', '', true)],
    [],
    ['needs_search_or_form'],
    ['needs_integration=__CALENDAR_IDX__']
  )
}

/**
 * Real device capability, hardcoded to one compile-time-verified sdk.call target
 * ("CalendarKit.Calendar.addEvent" -- checked against VeraSdkIndex's static 16,511-entry index,
 * same guarantee a wrong/outdated target would fail to compile rather than fail silently on the
 * phone). Calendar permission is already requested at startup (VeraCalendar
 * .requestCalendarPermissions); nothing new is needed there. hour is a closed-set slot, not
 * content-fill, because VeraCalendarSdk.ets's localStart requires a valid 0-23 integer and an
 * unvalidated model string is exactly the kind of value that should not reach a real write.
 * onAnswer follows docs/intent-call-contract.md's documented rule exactly (declined/error are the
 * only failure shapes; anything else, including "ok" and a target's own JSON, is success) --
 * written once here instead of risking the same mistake two confirmed DeepSeek-generated programs
 * made on this exact device.
 */
function calendarEventFragment(): FragmentSpec {
  let hour: Map<string, string> = new Map<string, string>()
  hour.set('9', 'in the morning, around 9 AM')
  hour.set('12', 'around midday')
  hour.set('15', 'in the afternoon, around 3 PM')
  hour.set('18', 'in the evening, around 6 PM')
  return new FragmentSpec(
    'calendar_event',
    'A single real calendar event the person can add with one button, with a live result',
    '',
    [new StateFieldSpec('lastResultIDX', 'string')],
    '',
    `lastResultIDX: ""`,
    `function addToCalendarIDX(state: AppState, ignored: number): AppState {
  sdk.call("CalendarKit.Calendar.addEvent",
    ["title", "__EVENT_TITLE_IDX__", "hour", "__EVENT_HOUR_IDX__", "minute", "0",
     "durationMinutes", "60", "repeat", "once"], "onAnswerIDX");
  return {lastResultIDX: "pending"__PASSTHROUGH__};
}

function onAnswerIDX(state: AppState, value: string): AppState {
  return {lastResultIDX: value__PASSTHROUGH__};
}`,
    `{
    let failed: boolean = strings.startsWith(state.lastResultIDX, "declined") || strings.startsWith(state.lastResultIDX, "error");
    let statusText: string = "Not added yet";
    let bannerStyle: string = "default";
    if (state.lastResultIDX !== "" && failed) { statusText = state.lastResultIDX; bannerStyle = "warning"; }
    if (state.lastResultIDX !== "" && !failed) { statusText = "Added to calendar"; }
    sections.push(ui.Section("content", "", "", [
      ui.ActionBar("spread", [
        ui.Button("primary", "Add to calendar", "addToCalendarIDX", 0, true)
      ]),
      ui.InsetBanner(bannerStyle, "Calendar", statusText, "", "", "info")
    ]));
  }`,
    [new SlotSpec('__EVENT_HOUR_IDX__', ['9', '12', '15', '18'], 'choice',
      'What time of day does this event happen?', hour)],
    [new ContentFieldSpec('__EVENT_TITLE_IDX__', 'event_title', 'Reminder', 'Short calendar event title (2-5 words)', 40)],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"']
  )
}

/** A quick-actions row: 3 generic buttons, each records itself as "last tapped" -- no counters, just a record of which action was last chosen. */
function actionsFragment(): FragmentSpec {
  return new FragmentSpec(
    'actions',
    'A row of a few quick buttons that only note which one was last tapped, for a choice made on this screen (a mood, a ' +
    'category); they make nothing happen on the phone or in another app',
    '',
    [new StateFieldSpec('lastActionIDX', 'string')],
    '',
    `lastActionIDX: ""`,
    `function tapAction1IDX(state: AppState, ignored: number): AppState {
  return {lastActionIDX: "__ACTION1_IDX__"__PASSTHROUGH__};
}

function tapAction2IDX(state: AppState, ignored: number): AppState {
  return {lastActionIDX: "__ACTION2_IDX__"__PASSTHROUGH__};
}

function tapAction3IDX(state: AppState, ignored: number): AppState {
  return {lastActionIDX: "__ACTION3_IDX__"__PASSTHROUGH__};
}`,
    `{
    let resultText: string = "Nothing tapped yet";
    if (state.lastActionIDX !== "") { resultText = "Last: " + state.lastActionIDX; }
    sections.push(ui.Section("content", "", "", [
      ui.ActionBar("spread", [
        ui.Button("primary", "__ACTION1_IDX__", "tapAction1IDX", 0, true),
        ui.Button("secondary", "__ACTION2_IDX__", "tapAction2IDX", 0, true),
        ui.Button("secondary", "__ACTION3_IDX__", "tapAction3IDX", 0, true)
      ]),
      ui.Badge("default", resultText, "")
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__ACTION1_IDX__', 'action1', 'Mark done', 'Label for the first quick action button', 20),
      new ContentFieldSpec('__ACTION2_IDX__', 'action2', 'Snooze', 'Label for the second quick action button', 20),
      new ContentFieldSpec('__ACTION3_IDX__', 'action3', 'Skip', 'Label for the third quick action button', 20)
    ]
  )
}

/** Same shape as metrics (a single adjustable count against a target) but as a visual bar -- ui.Progress has no action prop of its own, so add/reset live in their own ActionBar below it. */
function progressGoalFragment(): FragmentSpec {
  let progressStyle: Map<string, string> = new Map<string, string>()
  progressStyle.set('default', 'no, same tone as the rest')
  progressStyle.set('accent', 'yes, highlighted')
  return new FragmentSpec(
    'progress_goal',
    'A single visual progress bar toward a goal, with a button to add progress and one to reset',
    '',
    [new StateFieldSpec('progressIDX', 'number'), new StateFieldSpec('goalIDX', 'number')],
    '',
    `progressIDX: 0, goalIDX: 10`,
    `function addProgressIDX(state: AppState, ignored: number): AppState {
  return {progressIDX: state.progressIDX + 1, goalIDX: state.goalIDX__PASSTHROUGH__};
}

function resetProgressIDX(state: AppState, ignored: number): AppState {
  return {progressIDX: 0, goalIDX: state.goalIDX__PASSTHROUGH__};
}`,
    `{
    sections.push(ui.Section("summary", "", "", [
      ui.ProgressRing("__PROGRESS_STYLE_IDX__", "__PROGRESS_LABEL_IDX__", state.progressIDX, state.goalIDX, ui.numberToString(state.progressIDX) + " of " + ui.numberToString(state.goalIDX))
    ]));
    sections.push(ui.Section("content", "", "", [
      ui.ActionBar("spread", [
        ui.Button("primary", "Add one", "addProgressIDX", 0, true),
        ui.Button("secondary", "Reset", "resetProgressIDX", 0, true)
      ])
    ]));
  }`,
    [new SlotSpec('__PROGRESS_STYLE_IDX__', ['default', 'accent'], 'choice',
      'Should the progress bar stand out with an accent tone?', progressStyle)],
    [new ContentFieldSpec('__PROGRESS_LABEL_IDX__', 'progress_label', 'Progress', 'Short label for what is being tracked (1-3 words)', 20)]
  )
}

/**
 * Small read-only labelled facts, no interactivity at all -- the simplest possible fragment: no
 * state fields, no init entries, no functions. Proves the composer tolerates a fragment that
 * contributes nothing but content-filled display text (see VeraSectionCompose.ets's
 * composeProgram, which now skips an empty initEntries contribution rather than joining a blank
 * string into the return object literal).
 */
function keyFactsFragment(): FragmentSpec {
  return new FragmentSpec(
    'key_facts',
    'A small block of a couple of read-only labelled facts, with no taps or inputs',
    '',
    [],
    '',
    '',
    '',
    `{
    sections.push(ui.Section("content", "", "", [
      ui.KeyValueGroup("default", 2, [
        ui.KeyValueItem("default", "__FACT1_LABEL_IDX__", "__FACT1_VALUE_IDX__", ""),
        ui.KeyValueItem("default", "__FACT2_LABEL_IDX__", "__FACT2_VALUE_IDX__", "")
      ])
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__FACT1_LABEL_IDX__', 'fact1_label', 'Status', 'Label for the first fact (1-2 words)', 16),
      new ContentFieldSpec('__FACT1_VALUE_IDX__', 'fact1_value', 'Unknown', 'Short value for the first fact (1-4 words)', 24),
      new ContentFieldSpec('__FACT2_LABEL_IDX__', 'fact2_label', 'Detail', 'Label for the second fact (1-2 words)', 16),
      new ContentFieldSpec('__FACT2_VALUE_IDX__', 'fact2_value', 'Unknown', 'Short value for the second fact (1-4 words)', 24)
    ]
  )
}

/**
 * A single-series line chart of a handful of real data points, display-only. Min/max are computed
 * from the actual plotted values at render time (a plain while loop over the array), not asked of
 * the content-fill model as a separate field -- VeraPreview.ets's Sparkline renderer never
 * auto-scales from the data, so a wrong hand-written bound would clip or flatten the chart, while
 * a value the renderer never sees can't be wrong. Same no-state, content-baked-at-compose-time
 * shape as key_facts/spotlight.
 */
function trendChartFragment(): FragmentSpec {
  let chartStyle: Map<string, string> = new Map<string, string>()
  chartStyle.set('default', 'no, same tone as the rest')
  chartStyle.set('accent', 'yes, highlighted')
  return new FragmentSpec(
    'trend_chart',
    'A simple line chart of ONE series of a handful of data points trending over a sequence (a measurement ' +
    'by year, a reading over months); it cannot compare several groups -- not interactive, no taps, no editable inputs',
    '',
    [],
    '',
    '',
    '',
    `{
    let series: number[] = [];
    let categories: string[] = [];
    __POINTS_IDX__
    if (series.length() < 1) { series.push(0); categories.push(""); }
    let maxV: number = series[0];
    let minV: number = series[0];
    let i: number = 1;
    while (i < series.length()) {
      if (series[i] > maxV) { maxV = series[i]; }
      if (series[i] < minV) { minV = series[i]; }
      i = i + 1;
    }
    let span: number = maxV - minV;
    if (span < 1) { span = 1; }
    let top: number = maxV + span / 5;
    let bottom: number = minV - span / 5;
    if (bottom < 0) { if (minV > -1) { bottom = 0; } }
    sections.push(ui.Section("content", "", "", [
      ui.Sparkline("__CHART_STYLE_IDX__", series, top, "__CHART_LABEL_IDX__", false, [], "default", "", "", categories, bottom)
    ]));
  }`,
    [new SlotSpec('__CHART_STYLE_IDX__', ['default', 'accent'], 'choice', 'Should the chart line stand out?', chartStyle)],
    [
      new ContentFieldSpec('__CHART_LABEL_IDX__', 'chart_label', 'Value', 'Short label for what the chart plots (2-4 words, e.g. "Average height (cm)")', 24)
    ],
    [],
    [new ListFieldSpec('__POINTS_IDX__', 'points',
      'The data points of the line, in order along the x axis (2 to 12), each with its label and a number. Take the points the ' +
      'request names; when it names none, take 6 to 10 evenly spaced ones from the search results\' table (every 10 years, every month). ' +
      'Never invent a point, never pad with zeros or with derived values such as a change',
      ['x-axis label (a year or a month, 1-2 words)', 'its value, a plain number, no units'], [12, 12],
      'categories.push("{0}"); series.push({1});', '\n    ', 2, 12,
      [['A', '1'], ['B', '2']], [], ['', 'number'])]
  )
}

/** A single editable text field, stored in state. One field is not the "multi-field form" needs_search_or_form vetoes against. */
function noteFragment(): FragmentSpec {
  return new FragmentSpec(
    'note',
    'A single note the person can type and edit, with no other fields',
    '',
    [new StateFieldSpec('noteIDX', 'string')],
    '',
    `noteIDX: ""`,
    `function updateNoteIDX(state: AppState, value: string): AppState {
  return {noteIDX: value__PASSTHROUGH__};
}`,
    `{
    sections.push(ui.Section("content", "", "", [
      ui.TextField("default", "__NOTE_LABEL_IDX__", state.noteIDX, "updateNoteIDX")
    ]));
  }`,
    [],
    [new ContentFieldSpec('__NOTE_LABEL_IDX__', 'note_label', 'Note', 'Short label for what this note is for (1-3 words)', 20)]
  )
}

/** A 1-10 slider with a live readout. */
function ratingFragment(): FragmentSpec {
  let ratingStyle: Map<string, string> = new Map<string, string>()
  ratingStyle.set('default', 'no, same tone as the rest')
  ratingStyle.set('accent', 'yes, highlighted')
  return new FragmentSpec(
    'rating',
    'A single slider from 1 to 10 the person can set, with a live readout',
    '',
    [new StateFieldSpec('ratingIDX', 'number')],
    '',
    `ratingIDX: 5`,
    `function setRatingIDX(state: AppState, value: number): AppState {
  return {ratingIDX: value__PASSTHROUGH__};
}`,
    `{
    sections.push(ui.Section("content", "", "", [
      ui.Slider("__RATING_STYLE_IDX__", "__RATING_LABEL_IDX__", state.ratingIDX, 1, 10, "setRatingIDX")
    ]));
  }`,
    [new SlotSpec('__RATING_STYLE_IDX__', ['default', 'accent'], 'choice',
      'Should the slider stand out with an accent tone?', ratingStyle)],
    [new ContentFieldSpec('__RATING_LABEL_IDX__', 'rating_label', 'Rating', 'Short label for what is being rated (1-3 words)', 20)]
  )
}

/** A static featured highlight, no interactivity at all -- same empty-fields shape as key_facts, already proven live on-device (including composed with itself). */
function spotlightFragment(): FragmentSpec {
  let spotlightStyle: Map<string, string> = new Map<string, string>()
  spotlightStyle.set('plain', 'restrained and neutral')
  spotlightStyle.set('accent', 'bold and highlighted')
  return new FragmentSpec(
    'spotlight',
    'A single featured highlight or callout, display-only, with no taps or inputs',
    '',
    [],
    '',
    '',
    '',
    `{
    sections.push(ui.Section("hero", "", "", [
      ui.Hero("__SPOTLIGHT_STYLE_IDX__", "__SPOTLIGHT_EYEBROW_IDX__", "__SPOTLIGHT_TITLE_IDX__", "__SPOTLIGHT_BODY_IDX__", [])
    ]));
  }`,
    [new SlotSpec('__SPOTLIGHT_STYLE_IDX__', ['plain', 'accent'], 'choice',
      'Should the highlight be plain or bold/accented?', spotlightStyle)],
    [
      new ContentFieldSpec('__SPOTLIGHT_EYEBROW_IDX__', 'spotlight_eyebrow', 'Highlight', 'Short eyebrow label above the title (1-2 words)', 16),
      new ContentFieldSpec('__SPOTLIGHT_TITLE_IDX__', 'spotlight_title', 'Featured', 'Short title for the highlight (2-4 words)', 24),
      new ContentFieldSpec('__SPOTLIGHT_BODY_IDX__', 'spotlight_body', 'Something worth noticing.', 'One short supporting sentence', 60)
    ]
  )
}

/**
 * A short list the person narrows by typing part of a name. Matching is strings.contains on the
 * typed text as it is -- std/strings has no case folding, so the sample names are asked for in
 * lower case and a query typed with a capital first letter will not match them. The rows are fixed
 * sample text baked in at compose time; the model replaces them when the request needs real data.
 */
function searchListFragment(): FragmentSpec {
  return new FragmentSpec(
    'search_list',
    'A short list of named items with a box where the person types part of a name to narrow the list',
    '',
    [new StateFieldSpec('queryIDX', 'string')],
    '',
    `queryIDX: ""`,
    `function setQueryIDX(state: AppState, value: string): AppState {
  return {queryIDX: value__PASSTHROUGH__};
}`,
    `{
    let q: string = state.queryIDX;
    let names: string[] = [__NAMES_IDX__];
    let rows: ui.View[] = [];
    let j: number = 0;
    while (j < names.length()) {
      let name: string = names[j];
      if (q.length() === 0 || strings.contains(name, q)) {
        rows.push(ui.ListItem("default", name, "", "", "", j, false, "list"));
      }
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.TextField("default", "__SEARCH_LABEL_IDX__", q, "setQueryIDX"),
      ui.When(rows.length() === 0, ui.EmptyState("default", "No matches", "Try a different word.", "", "", "list")),
      ui.When(rows.length() > 0, ui.ListGroup("default", "", rows))
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__SEARCH_LABEL_IDX__', 'search_label', 'Search', 'Short label for the search box (1-2 words)', 16)
    ],
    ['import * as strings from "std/strings"'],
    [new ListFieldSpec('__NAMES_IDX__', 'names',
      'The entries the person can search, as many as the request needs (3 to 8), each name all lower case',
      ['name of the entry, all lower case'], [24], '"{0}"', ', ', 3, 8,
      [['first item'], ['second item'], ['third item'], ['fourth item']])],
    [],
    [],
    ['needs_search_or_form']
  )
}

/** Shared by master_list and detail_view; the composer dedupes identical support classes. */
const ENTRY_CLASS: string = `@jsonable
class Entry {
  label: string;
  detail: string;
}`

/**
 * A list whose rows can be selected, publishing the entries and the selected index for a
 * detail_view elsewhere on the screen. Unlike checklist (private state, rows are toggled) this
 * one exists to drive another block.
 */
function masterListFragment(): FragmentSpec {
  return new FragmentSpec(
    'master_list',
    'A list of named items where tapping one selects it so its details can be shown in another part of the screen',
    ENTRY_CLASS,
    [new StateFieldSpec('itemsIDX', 'Entry[]'), new StateFieldSpec('selectedIDX', 'number')],
    `  let itemsIDX: Entry[] = [
    __ITEMS_IDX__
  ];`,
    `itemsIDX: itemsIDX, selectedIDX: -1`,
    `function selectIDX(state: AppState, index: number): AppState {
  return {itemsIDX: state.itemsIDX, selectedIDX: index__PASSTHROUGH__};
}

function rowMatchesIDX(query: string, label: string, detail: string): boolean {
__HOLE_ROWMATCHES_IDX__
}`,
    `{
    let q: string = __PORT_query__;
    let rows: ui.View[] = [];
    let j: number = 0;
    while (j < state.itemsIDX.length()) {
      let it: Entry = state.itemsIDX[j];
      if (rowMatchesIDX(q, it.label, it.detail)) {
        let icon: string = "list";
        if (j === state.selectedIDX) { icon = "check"; }
        rows.push(ui.ListItem("default", it.label, "", "", "selectIDX", j, true, icon));
      }
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(rows.length() === 0, ui.EmptyState("default", "No matches", "Try a different word.", "", "", "list")),
      ui.When(rows.length() > 0, ui.ListGroup("default", "", rows))
    ]));
  }`,
    [],
    [],
    ['import * as strings from "std/strings"'],
    [new ListFieldSpec('__ITEMS_IDX__', 'items',
      'The things to choose from, as many as the request needs (3 to 8); each has a short name and a one or two sentence description shown when it is selected',
      ['name of the item', 'one or two sentence description of the item'], [28, 90],
      '{label: "{0}", detail: "{1}"}', ',\n    ', 3, 8,
      [['First item', 'Tap an item to see its details.'], ['Second item', 'Tap an item to see its details.'], ['Third item', 'Tap an item to see its details.']])],
    [new PortSpec('writes', 'items', 'Entry[]', 'itemsIDX'), new PortSpec('writes', 'selected', 'number', 'selectedIDX'),
     new PortSpec('reads', 'query', 'string', '__PORT_query__', '""')],
    [new HoleSpec('rowMatches', '__HOLE_ROWMATCHES_IDX__',
      'rowMatches(query: string, label: string, detail: string): boolean',
      'Decides whether one row of the list stays visible for the text typed into the filter box. query is what the person typed (empty when nothing is typed: every row must stay visible then); label is the row title, detail is its description.',
      '  return query.length() === 0 || strings.contains(label, query) || strings.contains(detail, query);', 'filter_box')]
  )
}

/** A text box whose text a list elsewhere on the screen reads to narrow its rows. */
function filterBoxFragment(): FragmentSpec {
  return new FragmentSpec(
    'filter_box',
    'A text box the person types into to narrow a list on the same screen; only useful together with such a list',
    '',
    [new StateFieldSpec('queryIDX', 'string')],
    '',
    `queryIDX: ""`,
    `function setFilterIDX(state: AppState, value: string): AppState {
  return {queryIDX: value__PASSTHROUGH__};
}`,
    `{
    sections.push(ui.Section("content", "", "", [
      ui.TextField("default", "__FILTER_LABEL_IDX__", state.queryIDX, "setFilterIDX")
    ]));
  }`,
    [],
    [new ContentFieldSpec('__FILTER_LABEL_IDX__', 'filter_label', 'Filter', 'Short label for the filter box (1-2 words)', 16)],
    [],
    [],
    [new PortSpec('writes', 'query', 'string', 'queryIDX')],
    [],
    ['needs_search_or_form']
  )
}

/** Shows the entry that a list elsewhere on the screen has selected; reads, owns no state. */
function detailViewFragment(): FragmentSpec {
  return new FragmentSpec(
    'detail_view',
    'The details of whichever item is selected in a list on the same screen; only useful together with such a list',
    ENTRY_CLASS,
    [],
    '',
    '',
    '',
    `{
    let all: Entry[] = __PORT_items__;
    let sel: number = __PORT_selected__;
    let shownTitle: string = "Nothing selected";
    let shownBody: string = "Tap an item in the list to see its details here.";
    if (sel >= 0 && sel < all.length()) {
      let e: Entry = all[sel];
      shownTitle = e.label;
      shownBody = e.detail;
    }
    sections.push(ui.Section("content", "", "", [
      ui.KeyValueGroup("default", 1, [ui.KeyValueItem("default", shownTitle, shownBody, "")])
    ]));
  }`,
    [],
    [],
    [],
    [],
    [new PortSpec('reads', 'items', 'Entry[]', '__PORT_items__', '[]'), new PortSpec('reads', 'selected', 'number', '__PORT_selected__', '-1')]
  )
}

/** Read-only numbers about a checklist elsewhere on the screen: how many are done, how many in all, how many left. */
function listSummaryFragment(): FragmentSpec {
  return new FragmentSpec(
    'list_summary',
    'Summary numbers about a checklist on the same screen: how many items are done, how many there are and how many are left; only useful together with a checklist',
    '',
    [],
    '',
    '',
    '',
    `{
    let doneN: number = __PORT_done__;
    let totalN: number = __PORT_total__;
    sections.push(ui.Section("summary", "", "", [
      ui.MetricGroup("default", 3, [
        ui.NumberStat("default", "__DONE_LABEL_IDX__", doneN, "", "", 1, "", "check"),
        ui.NumberStat("default", "__TOTAL_LABEL_IDX__", totalN, "", "", 1, "", "list"),
        ui.NumberStat("default", "__LEFT_LABEL_IDX__", totalN - doneN, "", "", 1, "", "clock")
      ])
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__DONE_LABEL_IDX__', 'done_label', 'Done', 'Label for the number of finished items (1-2 words)', 16),
      new ContentFieldSpec('__TOTAL_LABEL_IDX__', 'total_label', 'Total', 'Label for the number of all items (1-2 words)', 16),
      new ContentFieldSpec('__LEFT_LABEL_IDX__', 'left_label', 'Left', 'Label for the number of items still to do (1-2 words)', 16)
    ],
    [],
    [],
    [new PortSpec('reads', 'done', 'number', '__PORT_done__', '0'), new PortSpec('reads', 'total', 'number', '__PORT_total__', '0')]
  )
}

/** Shared by record_log only: one entry of the log, tagged with the index of one of its named labels. */
const TALLY_CLASS: string = `@jsonable
class Tally {
  who: number;
  amount: number;
  note: string;
}`

/**
 * The source of a "records tagged with one of N named things" screen: the person picks who (or which
 * category, player, day...), types an amount with cents and a note, adds it, removes the last one or starts
 * over. It publishes everything other blocks can show or work out from the records, so readers need no state
 * of their own: the labels, the total per label, the overall total, the average per label, how far each label
 * is from that average (signed, sums to zero) and the number of entries. Nothing here says "expenses": the
 * labels, the captions and the currency come from the request.
 */
function recordLogFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'record_log',
    'A form where the person adds records one at a time, each tagged with one of several named people or categories ' +
    'and an amount (with cents), plus a note; the records are listed newest first and can be removed or cleared. ' +
    'The source of figures worked out per person or category: totals, an average, who is above or below it. ' +
    'Also fits one plain running list with a single total and no named people or categories (a note and an amount per entry)',
    TALLY_CLASS,
    [new StateFieldSpec('labelsIDX', 'string[]'), new StateFieldSpec('recordsIDX', 'Tally[]'),
     new StateFieldSpec('draftWhoIDX', 'number'), new StateFieldSpec('draftAmountIDX', 'string'),
     new StateFieldSpec('draftNoteIDX', 'string'), new StateFieldSpec('currencyIDX', 'string')],
    `  let labelsIDX: string[] = [__LABELS_IDX__];
  let recordsIDX: Tally[] = [];
  let currencyIDX: string = "__CURRENCY_IDX__";`,
    `labelsIDX: labelsIDX, recordsIDX: recordsIDX, draftWhoIDX: 0, draftAmountIDX: "", draftNoteIDX: "", currencyIDX: currencyIDX`,
    `function setWhoIDX(state: AppState, index: number): AppState {
  return {labelsIDX: state.labelsIDX, recordsIDX: state.recordsIDX, draftWhoIDX: index, draftAmountIDX: state.draftAmountIDX, draftNoteIDX: state.draftNoteIDX, currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function setAmountIDX(state: AppState, value: string): AppState {
  return {labelsIDX: state.labelsIDX, recordsIDX: state.recordsIDX, draftWhoIDX: state.draftWhoIDX, draftAmountIDX: value, draftNoteIDX: state.draftNoteIDX, currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function setNoteIDX(state: AppState, value: string): AppState {
  return {labelsIDX: state.labelsIDX, recordsIDX: state.recordsIDX, draftWhoIDX: state.draftWhoIDX, draftAmountIDX: state.draftAmountIDX, draftNoteIDX: value, currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function addRecordIDX(state: AppState, ignored: number): AppState {
  let amount: number = math.round(strings.toNumber(state.draftAmountIDX, 0) * 100) / 100;
  if (amount <= 0) { return state; }
  let out: Tally[] = [];
  let i: number = 0;
  while (i < state.recordsIDX.length()) {
    out.push(state.recordsIDX[i]);
    i = i + 1;
  }
  out.push({who: state.draftWhoIDX, amount: amount, note: state.draftNoteIDX});
  return {labelsIDX: state.labelsIDX, recordsIDX: out, draftWhoIDX: state.draftWhoIDX, draftAmountIDX: "", draftNoteIDX: "", currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function removeLastRecordIDX(state: AppState, ignored: number): AppState {
  let out: Tally[] = [];
  let i: number = 0;
  while (i < state.recordsIDX.length() - 1) {
    out.push(state.recordsIDX[i]);
    i = i + 1;
  }
  return {labelsIDX: state.labelsIDX, recordsIDX: out, draftWhoIDX: state.draftWhoIDX, draftAmountIDX: state.draftAmountIDX, draftNoteIDX: state.draftNoteIDX, currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function clearRecordsIDX(state: AppState, ignored: number): AppState {
  let out: Tally[] = [];
  return {labelsIDX: state.labelsIDX, recordsIDX: out, draftWhoIDX: 0, draftAmountIDX: "", draftNoteIDX: "", currencyIDX: state.currencyIDX__PASSTHROUGH__};
}

function totalsIDX(state: AppState): number[] {
  let out: number[] = [];
  let i: number = 0;
  while (i < state.labelsIDX.length()) {
    out.push(0);
    i = i + 1;
  }
  for (let r: Tally of state.recordsIDX) {
    if (r.who >= 0 && r.who < out.length()) { out[r.who] = math.round((out[r.who] + r.amount) * 100) / 100; }
  }
  return out;
}

function totalSumIDX(state: AppState): number {
  let sum: number = 0;
  for (let r: Tally of state.recordsIDX) { sum = sum + r.amount; }
  return math.round(sum * 100) / 100;
}

function averageIDX(state: AppState): number {
  let n: number = state.labelsIDX.length();
  if (n === 0) { return 0; }
  return math.round(totalSumIDX(state) / n * 100) / 100;
}

function balancesIDX(state: AppState): number[] {
  let totals: number[] = totalsIDX(state);
  let n: number = state.labelsIDX.length();
  let totalCents: number = math.round(totalSumIDX(state) * 100);
  let shareCents: number = 0;
  let extra: number = 0;
  if (n > 0) {
    shareCents = math.floor(totalCents / n);
    extra = totalCents - shareCents * n;
  }
  let out: number[] = [];
  let i: number = 0;
  while (i < totals.length()) {
    let owed: number = shareCents;
    if (i < extra) { owed = owed + 1; }
    out.push((math.round(totals[i] * 100) - owed) / 100);
    i = i + 1;
  }
  return out;
}`,
    `{
    let n: number = state.recordsIDX.length();
    let plain: boolean = state.labelsIDX.length() <= 1;
    let rows: ui.View[] = [];
    let k: number = n - 1;
    while (k >= 0) {
      let r: Tally = state.recordsIDX[k];
      let who: string = "?";
      if (r.who >= 0 && r.who < state.labelsIDX.length()) { who = state.labelsIDX[r.who]; }
      let shown: string = state.currencyIDX + ui.formatNumber(r.amount, 2);
      if (state.currencyIDX.length() === 0) { shown = ui.numberToString(r.amount); }
      if (plain) {
        let title: string = r.note;
        if (title.length() === 0) { title = "Entry"; }
        rows.push(ui.ListItem("default", title, "", shown, "", k, false, "list"));
      } else {
        rows.push(ui.ListItem("default", who, r.note, shown, "", k, false, "list"));
      }
      k = k - 1;
    }
    let typed: number = strings.toNumber(state.draftAmountIDX, 0);
    if (plain) {
      let sumText: string = state.currencyIDX + ui.formatNumber(totalSumIDX(state), 2);
      if (state.currencyIDX.length() === 0) { sumText = ui.numberToString(totalSumIDX(state)); }
      let avgText: string = "-";
      if (n > 0) {
        avgText = state.currencyIDX + ui.formatNumber(totalSumIDX(state) / n, 2);
        if (state.currencyIDX.length() === 0) { avgText = ui.formatNumber(totalSumIDX(state) / n, 2); }
      }
      sections.push(ui.Section("summary", "", "", [
        ui.TileGrid("default", [
          ui.Tile("accent", 2, "Total", sumText, "all entries", "chart"),
          ui.Tile("default", 1, "Entries", ui.numberToString(n), "logged", "list"),
          ui.Tile("default", 1, "Average", avgText, "per entry", "chart")
        ])
      ]));
    }
    let compactIDX: boolean = __WIDGET__;
    let formRows: ui.View[] = [];
    if (!plain) { formRows.push(ui.Select("default", "__WHO_LABEL_IDX__", state.labelsIDX, state.draftWhoIDX, "setWhoIDX")); }
    formRows.push(ui.TextField("default", "__AMOUNT_LABEL_IDX__", state.draftAmountIDX, "setAmountIDX", "number"));
    sections.push(ui.Section("content", "__FORM_TITLE_IDX__", "", [
      ui.Column("default", formRows),
      ui.When(!compactIDX, ui.TextField("default", "Note", state.draftNoteIDX, "setNoteIDX")),
      ui.ActionBar("end", [
        ui.When(!compactIDX, ui.Button("danger", "Start over", "clearRecordsIDX", 0, n > 0)),
        ui.Button("secondary", "Remove last", "removeLastRecordIDX", 0, n > 0),
        ui.Button("primary", "Add", "addRecordIDX", 0, typed > 0)
      ])
    ]));
    sections.push(ui.Section("content", "", "", [
      ui.When(n === 0, ui.EmptyState("default", "Nothing yet", "Add the first record above.", "", "", "list")),
      ui.When(n > 0, ui.ListGroup("default", "", rows))
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__FORM_TITLE_IDX__', 'form_title', 'Add a record', 'Heading of the form (2-4 words)', 24),
      new ContentFieldSpec('__WHO_LABEL_IDX__', 'who_label', 'Who', 'Label of the choice of person or category (1-2 words, e.g. Paid by)', 16),
      new ContentFieldSpec('__AMOUNT_LABEL_IDX__', 'amount_label', 'Amount', 'Label of the amount field (1-3 words)', 20),
      new ContentFieldSpec('__CURRENCY_IDX__', 'currency', '', 'Currency symbol shown before amounts, only when the amounts are money; leave it blank for counts, minutes, quantities or scores', 3)
    ],
    ['import * as strings from "std/strings"'],
    [new ListFieldSpec('__LABELS_IDX__', 'labels',
      'The named people or categories a record can be tagged with, taken from the request (2 to 8); exactly one entry when the ' +
      'records are one plain running list not tied to people or categories. When the request has people share or settle costs ' +
      '(roommates, friends, a team, players), they are the people: the names the request gives, else numbered stand-ins such as ' +
      'Roommate 1, Roommate 2 -- never the kinds of cost or points that are being shared. When it asks for a breakdown by ' +
      'category (a budget, exercises, expense types), they are those categories',
      ['name of the person or category (1-2 words)'], [16], '"{0}"', ', ', 1, 8,
      [['Person 1'], ['Person 2'], ['Person 3']])],
    [new PortSpec('writes', 'labels', 'string[]', 'labelsIDX'),
     new PortSpec('writes', 'totals', 'number[]', 'totalsIDX(state)', '', true),
     new PortSpec('writes', 'balances', 'number[]', 'balancesIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'totalSumIDX(state)', '', true),
     new PortSpec('writes', 'average', 'number', 'averageIDX(state)', '', true),
     new PortSpec('writes', 'count', 'number', 'state.recordsIDX.length()', '', true),
     new PortSpec('writes', 'currency', 'string', 'currencyIDX')],
    [],
    ['needs_search_or_form', 'needs_multiple_counters', 'needs_logic']
  )
  return spec
}

/** Headline numbers worked out from a record_log elsewhere on the screen: the total, the average per person or category, the count. */
function numberStripFragment(): FragmentSpec {
  let count: Map<string, string> = new Map<string, string>()
  count.set('true', 'yes, also show how many records there are')
  count.set('false', 'no, the total and the average are enough')
  return new FragmentSpec(
    'number_strip',
    'A strip of headline numbers worked out from records entered on the same screen: the total, the average (equal share) per person or category and optionally how many records; only useful together with such records',
    '',
    [],
    '',
    '',
    '',
    `{
    let showCount: boolean = __SHOW_COUNT_IDX__;
    let cur: string = __PORT_currency__;
    let stats: ui.View[] = [];
    stats.push(ui.NumberStat("accent", "__TOTAL_LABEL_IDX__", __PORT_total__, cur, "", 1, "", "chart", 2));
    stats.push(ui.NumberStat("default", "__AVERAGE_LABEL_IDX__", __PORT_average__, cur, "", 1, "", "user", 2));
    if (showCount) {
      stats.push(ui.NumberStat("default", "__COUNT_LABEL_IDX__", __PORT_count__, "", "", 1, "", "list"));
    }
    sections.push(ui.Section("summary", "", "", [ui.MetricGroup("default", stats.length(), stats)]));
  }`,
    [new SlotSpec('__SHOW_COUNT_IDX__', ['false', 'true'], 'noul', 'Should the strip also show how many records there are?', count, 0.6)],
    [
      new ContentFieldSpec('__TOTAL_LABEL_IDX__', 'total_label', 'Total', 'Label for the total of all records (1-3 words)', 20),
      new ContentFieldSpec('__AVERAGE_LABEL_IDX__', 'average_label', 'Average', 'Label for the average per person or category, such as Each share (1-3 words)', 20),
      new ContentFieldSpec('__COUNT_LABEL_IDX__', 'count_label', 'Records', 'Label for the number of records (1-2 words)', 16)
    ],
    [],
    [],
    [new PortSpec('reads', 'total', 'number', '__PORT_total__', '0'), new PortSpec('reads', 'average', 'number', '__PORT_average__', '0'),
     new PortSpec('reads', 'count', 'number', '__PORT_count__', '0'), new PortSpec('reads', 'currency', 'string', '__PORT_currency__', '""')],
    [],
    ['needs_logic']
  )
}

/** One row per person or category with the total and how far from the average, from a record_log elsewhere on the screen. */
function breakdownTableFragment(): FragmentSpec {
  return new FragmentSpec(
    'breakdown_table',
    'A table with one row per person or category showing figures worked out from records entered on the same screen: the total of each and how far each is above or below the average; only useful together with such records',
    '',
    [],
    '',
    '',
    '',
    `{
    let names: string[] = __PORT_labels__;
    let totals: number[] = __PORT_totals__;
    let bals: number[] = __PORT_balances__;
    let cur: string = __PORT_currency__;
    let rows: ui.View[] = [];
    let i: number = 0;
    while (i < names.length()) {
      let totalText: string = "-";
      if (i < totals.length()) { totalText = cur + ui.formatNumber(totals[i], 2); }
      let balText: string = "-";
      let tone: string = "default";
      if (i < bals.length()) {
        let b: number = bals[i];
        if (b > 0.004) {
          balText = "+" + cur + ui.formatNumber(b, 2);
          tone = "success";
        } else {
          if (b < -0.004) {
            balText = "-" + cur + ui.formatNumber(0 - b, 2);
            tone = "danger";
          } else {
            balText = cur + "0.00";
          }
        }
      }
      rows.push(ui.TableRow(tone, [names[i], totalText, balText]));
      i = i + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.Table("default", ["__H1_IDX__", "__H2_IDX__", "__H3_IDX__"], 3, rows)
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__H1_IDX__', 'h1', 'Name', 'Header of the first column: the person or category (1-2 words)', 14),
      new ContentFieldSpec('__H2_IDX__', 'h2', 'Total', 'Header of the second column: what each has recorded in all (1-2 words)', 14),
      new ContentFieldSpec('__H3_IDX__', 'h3', 'Balance', 'Header of the third column: how far above or below the average, such as Balance (1-2 words)', 14)
    ],
    [],
    [],
    [new PortSpec('reads', 'labels', 'string[]', '__PORT_labels__', '[]'), new PortSpec('reads', 'totals', 'number[]', '__PORT_totals__', '[]'),
     new PortSpec('reads', 'balances', 'number[]', '__PORT_balances__', '[]'), new PortSpec('reads', 'currency', 'string', '__PORT_currency__', '""')],
    [],
    ['needs_logic']
  )
}

/** A bar chart with one bar per person or category, from a record_log elsewhere on the screen: the totals, or the balances. */
function seriesChartFragment(): FragmentSpec {
  let useBalances: Map<string, string> = new Map<string, string>()
  useBalances.set('true', 'yes, show how far each is above or below the average')
  useBalances.set('false', 'no, show the total of each')
  return new FragmentSpec(
    'series_chart',
    'A bar chart with one bar per person or category, drawn from records entered on the same screen (the total of each, or how far each is from the average); only useful together with such records',
    '',
    [],
    '',
    '',
    '',
    `{
    let names: string[] = __PORT_labels__;
    let totals: number[] = __PORT_totals__;
    let bals: number[] = __PORT_balances__;
    let useBalances: boolean = __USE_BALANCES_IDX__;
    let vals: number[] = totals;
    if (useBalances) { vals = bals; }
    let top: number = 1;
    let low: number = 0;
    for (let v: number of vals) {
      if (v > top) { top = v; }
      if (v < low) { low = v; }
    }
    let none: number[] = [];
    sections.push(ui.Section("content", "", "", [
      ui.Sparkline("default", vals, top, "__CHART_LABEL_IDX__", true, none, "accent", "", "", names, low)
    ]));
  }`,
    [new SlotSpec('__USE_BALANCES_IDX__', ['false', 'true'], 'noul', 'Should the bars show how far each is above or below the average instead of each total?', useBalances, 0.6)],
    [new ContentFieldSpec('__CHART_LABEL_IDX__', 'chart_label', 'Per person', 'Short caption for the chart (2-5 words)', 32)],
    [],
    [],
    [new PortSpec('reads', 'labels', 'string[]', '__PORT_labels__', '[]'), new PortSpec('reads', 'totals', 'number[]', '__PORT_totals__', '[]'),
     new PortSpec('reads', 'balances', 'number[]', '__PORT_balances__', '[]')]
  )
}

/**
 * Nets signed balances (positive: is owed, negative: owes; they sum to zero) into the few transfers that
 * settle them. Greedy: the largest creditor is paid by the largest debtor until nobody owes anything, so at
 * most n-1 transfers; that is the minimum in the common cases but not always (the true minimum is NP-hard).
 * Written once here on purpose: a loop the model writes for this is where a runaway loop came from.
 */
function settleUpFragment(): FragmentSpec {
  return new FragmentSpec(
    'settle_up',
    'Works out from the balances of records entered on the same screen who should pay whom so that everyone ends up even, in few payments; only useful together with such records',
    '',
    [],
    '',
    '',
    '',
    `{
    let names: string[] = __PORT_labels__;
    let bals: number[] = __PORT_balances__;
    let cur: string = __PORT_currency__;
    let work: number[] = [];
    for (let b: number of bals) { work.push(b); }
    let rows: ui.View[] = [];
    let guard: number = 0;
    let finished: boolean = false;
    while (!finished && guard < 16) {
      guard = guard + 1;
      let hi: number = -1;
      let lo: number = -1;
      let k: number = 0;
      while (k < work.length()) {
        if (work[k] > 0.004 && (hi === -1 || work[k] > work[hi])) { hi = k; }
        if (work[k] < -0.004 && (lo === -1 || work[k] < work[lo])) { lo = k; }
        k = k + 1;
      }
      if (hi === -1 || lo === -1 || hi >= names.length() || lo >= names.length()) {
        finished = true;
      } else {
        let amt: number = work[hi];
        if (0 - work[lo] < amt) { amt = 0 - work[lo]; }
        amt = math.round(amt * 100) / 100;
        if (amt <= 0) {
          finished = true;
        } else {
          rows.push(ui.ListItem("default", names[lo] + " __PAYS_IDX__ " + names[hi], "", cur + ui.formatNumber(amt, 2), "", 0, false, "navigate"));
          work[hi] = math.round((work[hi] - amt) * 100) / 100;
          work[lo] = math.round((work[lo] + amt) * 100) / 100;
        }
      }
    }
    sections.push(ui.Section("content", "__SETTLE_TITLE_IDX__", "", [
      ui.When(rows.length() === 0, ui.EmptyState("default", "All settled up", "Nobody owes anyone.", "", "", "check")),
      ui.When(rows.length() > 0, ui.ListGroup("default", "", rows))
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__SETTLE_TITLE_IDX__', 'settle_title', 'Settle up', 'Heading of the list of payments that even everyone out (2-3 words)', 20),
      new ContentFieldSpec('__PAYS_IDX__', 'pays_word', 'pays', 'The word between who pays and who is paid, as in "Ben pays Anna" (1 word)', 10)
    ],
    [],
    [],
    [new PortSpec('reads', 'labels', 'string[]', '__PORT_labels__', '[]'), new PortSpec('reads', 'balances', 'number[]', '__PORT_balances__', '[]'),
     new PortSpec('reads', 'currency', 'string', '__PORT_currency__', '""')],
    [],
    ['needs_logic']
  )
}

/** One stop of an itinerary. Coordinates are text on purpose: they go to the maps intent as strings and an empty one means "by name only". */
const STOP_CLASS: string = `@jsonable
class Stop {
  name: string;
  minutes: number;
  latitude: string;
  longitude: string;
  done: boolean;
  eventId: string;
}`

/**
 * An ordered day of places: each with a duration and (checked) coordinates, a window computed from the start time,
 * and a "reached" mark. Two phone actions are switched on by Jev's slot answers, not by the block: a Navigate button per
 * stop (Petal Maps' StartNavigate through sdk.call) and calendar tools (add each stop to the phone calendar, open the
 * calendar, remove what this app added). The answers follow docs/intent-call-contract.md: only "declined..." and
 * "error..." are failures, anything else is success, and a failure is shown, never swallowed.
 *
 * Petal Maps accepts srcLocation, answers 0 and routes from where the phone is (VeraIntentCatalog.ets); the origin is sent
 * anyway, so every leg after the first is right as soon as the person stands where it starts.
 * Calendar events are today, in the phone's own time zone (hour and minute, no epoch): CalendarKit's flat fields.
 * Publishes done and total, the names checklist publishes, so list_summary and progress_line read either.
 */
function itineraryFragment(): FragmentSpec {
  let navigate: Map<string, string> = new Map<string, string>()
  navigate.set('true', 'yes, each stop has a button that opens it in the maps app for directions')
  navigate.set('false', 'no navigation is asked for')
  let calendar: Map<string, string> = new Map<string, string>()
  calendar.set('true', 'yes, each stop can be added to the phone calendar, with buttons to open the calendar and remove the added events')
  calendar.set('false', 'no calendar is asked for')
  let spec = new FragmentSpec(
    'itinerary',
    'An ordered list of places or steps with a time window and duration each, which the person marks as reached one by one; ' +
    'it can also open a stop in the maps app and add stops to the phone calendar. A day plan, a tour, a route of stops',
    STOP_CLASS,
    [new StateFieldSpec('stopsIDX', 'Stop[]'), new StateFieldSpec('startMinIDX', 'number'), new StateFieldSpec('gapIDX', 'number'),
     new StateFieldSpec('startPlaceIDX', 'string'), new StateFieldSpec('startLatIDX', 'string'), new StateFieldSpec('startLonIDX', 'string'),
     new StateFieldSpec('lastIDX', 'number'), new StateFieldSpec('pendingIDX', 'number'), new StateFieldSpec('resultIDX', 'string')],
    `  let stopsIDX: Stop[] = [
    __STOPS_IDX__
  ];
  let startMinIDX: number = __START_TIME_IDX__;
  if (startMinIDX < 0 || startMinIDX > 1439) { startMinIDX = 540; }
  let gapIDX: number = __GAP_IDX__;
  if (gapIDX < 0 || gapIDX > 180) { gapIDX = 15; }
  let startPlaceIDX: string = "__START_PLACE_IDX__";
  let startLatIDX: string = "__START_LAT_IDX__";
  let startLonIDX: string = "__START_LON_IDX__";
  let latCheckIDX: number = strings.toNumber(startLatIDX, 1000);
  let lonCheckIDX: number = strings.toNumber(startLonIDX, 1000);
  if (latCheckIDX < -90 || latCheckIDX > 90 || lonCheckIDX < -180 || lonCheckIDX > 180) { startLatIDX = ""; startLonIDX = ""; }`,
    `stopsIDX: stopsIDX, startMinIDX: startMinIDX, gapIDX: gapIDX, startPlaceIDX: startPlaceIDX, startLatIDX: startLatIDX, startLonIDX: startLonIDX, lastIDX: -1, pendingIDX: -1, resultIDX: ""`,
    `function rebuildIDX(state: AppState, stops: Stop[], last: number, pending: number, result: string): AppState {
  return {stopsIDX: stops, startMinIDX: state.startMinIDX, gapIDX: state.gapIDX, startPlaceIDX: state.startPlaceIDX, startLatIDX: state.startLatIDX, startLonIDX: state.startLonIDX, lastIDX: last, pendingIDX: pending, resultIDX: result__PASSTHROUGH__};
}

function failedIDX(value: string): boolean {
  return strings.startsWith(value, "declined") || strings.startsWith(value, "error");
}

function reachedCountIDX(state: AppState): number {
  let n: number = 0;
  for (let s: Stop of state.stopsIDX) { if (s.done) { n = n + 1; } }
  return n;
}

function visibleStopsIDX(state: AppState): number {
  let limit: number = __PORT_deadline__;
  if (limit < 0) { return state.stopsIDX.length(); }
  let at: number = state.startMinIDX;
  let n: number = 0;
  let i: number = 0;
  while (i < state.stopsIDX.length()) {
    if (at + state.stopsIDX[i].minutes <= limit) { n = n + 1; }
    at = at + state.stopsIDX[i].minutes + state.gapIDX;
    i = i + 1;
  }
  return n;
}

function toggleStopIDX(state: AppState, index: number): AppState {
  let out: Stop[] = [];
  let last: number = state.lastIDX;
  let highest: number = -1;
  let i: number = 0;
  while (i < state.stopsIDX.length()) {
    let s: Stop = state.stopsIDX[i];
    let done: boolean = s.done;
    if (i === index) {
      done = !s.done;
      if (done) { last = index; } else { if (last === index) { last = -2; } }
    }
    if (done) { highest = i; }
    out.push({name: s.name, minutes: s.minutes, latitude: s.latitude, longitude: s.longitude, done: done, eventId: s.eventId});
    i = i + 1;
  }
  if (last === -2) { last = highest; }
  return rebuildIDX(state, out, last, state.pendingIDX, state.resultIDX);
}

function navigateIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.stopsIDX.length()) { return state; }
  let target: Stop = state.stopsIDX[index];
  let fromName: string = state.startPlaceIDX;
  let fromLat: string = state.startLatIDX;
  let fromLon: string = state.startLonIDX;
  if (state.lastIDX >= 0 && state.lastIDX < state.stopsIDX.length()) {
    let prev: Stop = state.stopsIDX[state.lastIDX];
    fromName = prev.name;
    fromLat = prev.latitude;
    fromLon = prev.longitude;
  }
  let params: string[] = ["dstLocation.locationName", target.name];
  if (target.latitude !== "" && target.longitude !== "") {
    params.push("dstLocation.latitude");
    params.push(target.latitude);
    params.push("dstLocation.longitude");
    params.push(target.longitude);
  }
  if (fromName !== "") {
    params.push("srcLocation.locationName");
    params.push(fromName);
  }
  if (fromLat !== "" && fromLon !== "") {
    params.push("srcLocation.latitude");
    params.push(fromLat);
    params.push("srcLocation.longitude");
    params.push(fromLon);
  }
  params.push("trafficType");
  params.push("Drive");
  sdk.call("com.huawei.hmos.maps.app/entry/EntryAbility/StartNavigate", params, "onNavigatedIDX", "foreground");
  return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, "Opening maps...");
}

function onNavigatedIDX(state: AppState, value: string): AppState {
  let result: string = "";
  if (failedIDX(value)) { result = value; }
  return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, result);
}

function addEventIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.stopsIDX.length()) { return state; }
  let s: Stop = state.stopsIDX[index];
  let start: number = state.startMinIDX;
  let i: number = 0;
  while (i < index) {
    start = start + state.stopsIDX[i].minutes + state.gapIDX;
    i = i + 1;
  }
  let minute: number = start % 60;
  let hour: number = ((start - minute) / 60) % 24;
  let where: string = s.name;
  if (s.latitude !== "" && s.longitude !== "") { where = s.name + ", " + s.latitude + ", " + s.longitude; }
  sdk.call("CalendarKit.Calendar.addEvent",
    ["title", s.name, "hour", ui.numberToString(hour), "minute", ui.numberToString(minute),
     "durationMinutes", ui.numberToString(s.minutes), "location", where, "remindBefore", "15", "repeat", "once"], "onAddedIDX");
  return rebuildIDX(state, state.stopsIDX, state.lastIDX, index, "Adding to the calendar...");
}

function onAddedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return rebuildIDX(state, state.stopsIDX, state.lastIDX, -1, value); }
  let out: Stop[] = [];
  let i: number = 0;
  while (i < state.stopsIDX.length()) {
    let s: Stop = state.stopsIDX[i];
    let id: string = s.eventId;
    if (i === state.pendingIDX) { id = value; }
    out.push({name: s.name, minutes: s.minutes, latitude: s.latitude, longitude: s.longitude, done: s.done, eventId: id});
    i = i + 1;
  }
  return rebuildIDX(state, out, state.lastIDX, -1, "Added to the calendar");
}

function wipeEventsIDX(state: AppState, ignored: number): AppState {
  let ids: string = "";
  for (let s: Stop of state.stopsIDX) {
    if (s.eventId !== "") {
      if (ids !== "") { ids = ids + ","; }
      ids = ids + s.eventId;
    }
  }
  if (ids === "") { return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, "No events added by this app"); }
  sdk.call("CalendarKit.Calendar.deleteEvents", ["ids", ids], "onWipedIDX");
  return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, "Removing events...");
}

function setStartIDX(state: AppState, value: number): AppState {
  return {stopsIDX: state.stopsIDX, startMinIDX: value, gapIDX: state.gapIDX, startPlaceIDX: state.startPlaceIDX, startLatIDX: state.startLatIDX, startLonIDX: state.startLonIDX, lastIDX: state.lastIDX, pendingIDX: state.pendingIDX, resultIDX: state.resultIDX__PASSTHROUGH__};
}

function setGapIDX(state: AppState, value: number): AppState {
  return {stopsIDX: state.stopsIDX, startMinIDX: state.startMinIDX, gapIDX: value, startPlaceIDX: state.startPlaceIDX, startLatIDX: state.startLatIDX, startLonIDX: state.startLonIDX, lastIDX: state.lastIDX, pendingIDX: state.pendingIDX, resultIDX: state.resultIDX__PASSTHROUGH__};
}

function onWipedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, value); }
  let out: Stop[] = [];
  for (let s: Stop of state.stopsIDX) {
    out.push({name: s.name, minutes: s.minutes, latitude: s.latitude, longitude: s.longitude, done: s.done, eventId: ""});
  }
  return rebuildIDX(state, out, state.lastIDX, state.pendingIDX, "Events removed");
}

function openCalendarIDX(state: AppState, ignored: number): AppState {
  sdk.call("com.huawei.hmos.calendar/phone/MainAbility", [], "onOpenedIDX");
  return state;
}

function onOpenedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return rebuildIDX(state, state.stopsIDX, state.lastIDX, state.pendingIDX, value); }
  return state;
}`,
    `{
    let count: number = state.stopsIDX.length();
    let showNav: boolean = __NAVIGATE_IDX__;
    let showCal: boolean = __CALENDAR_IDX__;
    let limit: number = __PORT_deadline__;
    let rows: ui.View[] = [];
    let at: number = state.startMinIDX;
    let shown: number = 0;
    let j: number = 0;
    while (j < count) {
      let s: Stop = state.stopsIDX[j];
      if (limit < 0 || at + s.minutes <= limit) {
        let icon: string = "pin";
        if (s.done) { icon = "check"; }
        let subtitle: string = ui.clockToString(at) + " - " + ui.clockToString(at + s.minutes) + " | " + ui.numberToString(s.minutes) + " min";
        rows.push(ui.ListItem("default", s.name, subtitle, "", "toggleStopIDX", j, true, icon));
        let buttons: ui.View[] = [];
        if (showCal) {
          let calText: string = "Add to calendar";
          if (s.eventId !== "") { calText = "In calendar"; }
          buttons.push(ui.Button("secondary", calText, "addEventIDX", j, s.eventId === ""));
        }
        if (showNav) { buttons.push(ui.Button("primary", "Navigate", "navigateIDX", j, true)); }
        if (buttons.length() > 0) { rows.push(ui.ActionBar("end", buttons)); }
        shown = shown + 1;
      }
      at = at + s.minutes + state.gapIDX;
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.TimeField("default", "Day starts", state.startMinIDX, "setStartIDX"),
      ui.NumberField("default", "Minutes between stops", state.gapIDX, 0, 180, "setGapIDX")
    ]));
    let emptyText: string = "Nothing is planned yet.";
    if (limit >= 0 && count > 0) { emptyText = "Nothing fits before " + ui.clockToString(limit) + "."; }
    sections.push(ui.Section("content", "", "", [
      ui.When(shown === 0, ui.EmptyState("default", "No stops", emptyText, "", "", "pin")),
      ui.When(shown > 0, ui.ListGroup("default", "", rows))
    ]));
    let notes: ui.View[] = [];
    if (limit >= 0 && shown < count) {
      notes.push(ui.InsetBanner("default", "Left out", ui.numberToString(count - shown) + " more would run past " + ui.clockToString(limit), "", "", "info"));
    }
    if (state.resultIDX !== "") {
      let tone: string = "default";
      if (failedIDX(state.resultIDX)) { tone = "warning"; }
      notes.push(ui.InsetBanner(tone, "Last action", state.resultIDX, "", "", "info"));
    }
    if (showCal) {
      notes.push(ui.ActionBar("spread", [
        ui.Button("secondary", "Open calendar", "openCalendarIDX", 0, true),
        ui.Button("danger", "Wipe added events", "wipeEventsIDX", 0, true)
      ]));
    }
    if (notes.length() > 0) { sections.push(ui.Section("supporting", "", "", notes)); }
  }`,
    [new SlotSpec('__NAVIGATE_IDX__', ['false', 'true'], 'noul', 'Should each stop have a button that opens it in the maps app for directions?', navigate, 0.6,
      ['navigate']),
     new SlotSpec('__CALENDAR_IDX__', ['false', 'true'], 'noul', 'Should each stop be addable to the phone calendar, with buttons to open the calendar and to remove the events this app added?', calendar, 0.6,
      ['calendar_add', 'calendar_open', 'calendar_clear'])],
    [
      new ContentFieldSpec('__START_TIME_IDX__', 'start_time', '540', 'When the first stop starts, as minutes after midnight (09:00 is 540)', 6, true),
      new ContentFieldSpec('__GAP_IDX__', 'gap_minutes', '15', 'Minutes of travel or slack between two stops (0 to 180)', 4, true),
      new ContentFieldSpec('__START_PLACE_IDX__', 'start_place', '', 'Where the day starts (an airport, a hotel), or an empty string if the request does not say', 40),
      new ContentFieldSpec('__START_LAT_IDX__', 'start_latitude', '', 'Latitude of the starting place as a decimal, or an empty string if unknown', 12),
      new ContentFieldSpec('__START_LON_IDX__', 'start_longitude', '', 'Longitude of the starting place as a decimal, or an empty string if unknown', 12)
    ],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"'],
    [new ListFieldSpec('__STOPS_IDX__', 'stops',
      'The stops of the day in order, as many as the request needs (5 to 12): each with a name, how long it takes in minutes, and its latitude and longitude as decimals (an empty string when not known with confidence)',
      ['name of the place (1-4 words)', 'minutes spent there, a whole number', 'latitude as a decimal such as 31.2397, or an empty string', 'longitude as a decimal such as 121.4900, or an empty string'],
      [28, 4, 12, 12],
      '{name: "{0}", minutes: {1}, latitude: "{2}", longitude: "{3}", done: false, eventId: ""}', ',\n    ', 5, 12,
      [['Stop 1', '60', '', ''], ['Stop 2', '60', '', ''], ['Stop 3', '60', '', ''], ['Stop 4', '60', '', ''], ['Stop 5', '60', '', '']],
      [1], ['', 'minutes', 'lat', 'lon'])],
    [new PortSpec('writes', 'done', 'number', 'reachedCountIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'visibleStopsIDX(state)', '', true),
     // The time of day by which the stops must be over (a flight to catch); -1: no such time, every stop is shown.
     new PortSpec('reads', 'deadline', 'number', '__PORT_deadline__', '-1', false, true)],
    [],
    ['needs_logic', 'needs_search_or_form'],
    ['needs_integration=__NAVIGATE_IDX__|__CALENDAR_IDX__']
  )
  spec.owns = 'the start time of the day (the person sets it), the minutes between stops (the person sets them), the time each stop starts and ends, and how long each stop takes'
  spec.tab = 'Itinerary'
  return spec
}

/**
 * Phone actions as a list: each row is one sdk.call whose target, parameters and mode the host took from the phone's
 * intent registry (VeraIntentPanel.ets) -- the rows hole is never written by the model. params is "name\nvalue\n..."
 * because a @jsonable field cannot hold a list of text; "{input}" in a value is replaced by the text box's value.
 */
function intentPanelFragment(): FragmentSpec {
  return new FragmentSpec(
    'intent_panel',
    'Controls that make the phone, its settings or one of its apps do something, one action per tap: switch a setting on or ' +
    'off (torch, Wi-Fi, do not disturb, one-handed mode), open a page of an app, create a note or an event, start navigation ' +
    'or music, set an alarm, read a value the phone keeps. Each shows what the phone answered',
    `@jsonable
class IntentRow {
  label: string;
  target: string;
  params: string;
  mode: string;
  input: boolean;
}`,
    [new StateFieldSpec('actionsIDX', 'IntentRow[]'), new StateFieldSpec('answersIDX', 'string[]'),
     new StateFieldSpec('pendingIDX', 'number'), new StateFieldSpec('inputIDX', 'string')],
    `  let actionsIDX: IntentRow[] = intentRowsIDX();
  let answersIDX: string[] = [];
  for (let a: IntentRow of actionsIDX) { answersIDX.push(""); }`,
    `actionsIDX: actionsIDX, answersIDX: answersIDX, pendingIDX: -1, inputIDX: ""`,
    `function intentRowsIDX(): IntentRow[] {
__HOLE_INTENTROWS_IDX__
}

function failedIDX(value: string): boolean {
  return strings.startsWith(value, "declined") || strings.startsWith(value, "error");
}

function setInputIDX(state: AppState, value: string): AppState {
  return {actionsIDX: state.actionsIDX, answersIDX: state.answersIDX, pendingIDX: state.pendingIDX, inputIDX: value__PASSTHROUGH__};
}

function runActionIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.actionsIDX.length()) { return state; }
  let a: IntentRow = state.actionsIDX[index];
  let params: string[] = [];
  if (a.params !== "") {
    for (let p: string of strings.split(a.params, "\\n")) { params.push(strings.replace(p, "{input}", state.inputIDX)); }
  }
  sdk.call(a.target, params, "onAnsweredIDX", a.mode);
  let answers: string[] = [];
  let i: number = 0;
  while (i < state.answersIDX.length()) {
    if (i === index) { answers.push("Working..."); } else { answers.push(state.answersIDX[i]); }
    i = i + 1;
  }
  return {actionsIDX: state.actionsIDX, answersIDX: answers, pendingIDX: index, inputIDX: state.inputIDX__PASSTHROUGH__};
}

function onAnsweredIDX(state: AppState, value: string): AppState {
  let shown: string = value;
  if (value === "ok") { shown = "Done"; }
  if (strings.length(shown) > 120) { shown = strings.substring(shown, 0, 117) + "..."; }
  let answers: string[] = [];
  let i: number = 0;
  while (i < state.answersIDX.length()) {
    if (i === state.pendingIDX) { answers.push(shown); } else { answers.push(state.answersIDX[i]); }
    i = i + 1;
  }
  return {actionsIDX: state.actionsIDX, answersIDX: answers, pendingIDX: -1, inputIDX: state.inputIDX__PASSTHROUGH__};
}`,
    `{
    let count: number = state.actionsIDX.length();
    let rows: ui.View[] = [];
    let wantsInput: boolean = false;
    let j: number = 0;
    while (j < count) {
      let a: IntentRow = state.actionsIDX[j];
      if (a.input) { wantsInput = true; }
      let answer: string = state.answersIDX[j];
      let icon: string = "navigate";
      if (answer === "Done") { icon = "check"; }
      if (failedIDX(answer)) { icon = "warning"; }
      rows.push(ui.ListItem("default", a.label, answer, "", "runActionIDX", j, true, icon));
      j = j + 1;
    }
    let body: ui.View[] = [];
    if (wantsInput) { body.push(ui.TextField("default", "__INPUT_LABEL_IDX__", state.inputIDX, "setInputIDX")); }
    body.push(ui.When(count === 0, ui.EmptyState("default", "No actions", "This phone has no app for that.", "", "", "info")));
    body.push(ui.When(count > 0, ui.ListGroup("default", "", rows)));
    sections.push(ui.Section("content", "", "", body));
  }`,
    [],
    [new ContentFieldSpec('__INPUT_LABEL_IDX__', 'input_label', 'Text',
      'Label of the text box whose value the actions use (a note text, a contact name), 1-3 words', 24)],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"'],
    [],
    [],
    [new HoleSpec('intentRows', '__HOLE_INTENTROWS_IDX__', 'intentRows(): IntentRow[]',
      'The phone actions, chosen and checked by the host.', '  return [];', '', false)],
    ['needs_integration']
  )
}

/** "N of M" with a bar, from the done and total of a checklist, itinerary or any block that publishes them. */
function progressLineFragment(): FragmentSpec {
  return new FragmentSpec(
    'progress_line',
    'A single progress line, such as "3 of 9 reached", with a bar, for the items marked done in a list on the same screen; only useful together with such a list',
    '',
    [],
    '',
    '',
    '',
    `{
    let doneN: number = __PORT_done__;
    let totalN: number = __PORT_total__;
    let maxN: number = totalN;
    if (maxN < 1) { maxN = 1; }
    sections.push(ui.Section("summary", "", "", [
      ui.SectionHeader("default", "__PROGRESS_LABEL_IDX__", "", ui.numberToString(doneN) + " of " + ui.numberToString(totalN)),
      ui.Progress("default", "", doneN, maxN)
    ]));
  }`,
    [],
    [new ContentFieldSpec('__PROGRESS_LABEL_IDX__', 'progress_label', 'Progress', 'What is being counted, such as Stops reached (1-3 words)', 24)],
    [],
    [],
    [new PortSpec('reads', 'done', 'number', '__PORT_done__', '0'), new PortSpec('reads', 'total', 'number', '__PORT_total__', '0')]
  )
}

/** Three columns, three rows of sample records, display-only. Same no-state shape as key_facts. */
function dataTableFragment(): FragmentSpec {
  return new FragmentSpec(
    'data_table',
    'A small table of records with three labelled columns that are read down and across, such as items with a quantity and a price',
    '',
    [],
    '',
    '',
    '',
    `{
    sections.push(ui.Section("content", "", "", [
      ui.Table("default", ["__H1_IDX__", "__H2_IDX__", "__H3_IDX__"], 3, [
        __ROWS_IDX__
      ])
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__H1_IDX__', 'h1', 'Name', 'Header of the first column (1-2 words)', 14),
      new ContentFieldSpec('__H2_IDX__', 'h2', 'Detail', 'Header of the second column (1-2 words)', 14),
      new ContentFieldSpec('__H3_IDX__', 'h3', 'Value', 'Header of the third column (1-2 words)', 14)
    ],
    [],
    [new ListFieldSpec('__ROWS_IDX__', 'rows',
      'The records of the table, as many as the request needs (3 to 8), one value per column',
      ['first column value', 'second column value', 'third column value'], [14, 14, 14],
      'ui.TableRow("default", ["{0}", "{1}", "{2}"])', ',\n        ', 3, 8,
      [['Item 1', '-', '-'], ['Item 2', '-', '-'], ['Item 3', '-', '-']])]
  )
}

/** Four steps in time order with a time on the right edge, display-only. */
function timelineFragment(): FragmentSpec {
  let timelineStyle: Map<string, string> = new Map<string, string>()
  timelineStyle.set('default', 'normal spacing')
  timelineStyle.set('compact', 'tighter spacing')
  timelineStyle.set('comfortable', 'looser spacing')
  return new FragmentSpec(
    'timeline',
    'Steps or events in time order, such as an itinerary, a daily schedule or a history, each with a time',
    '',
    [],
    '',
    '',
    '',
    `{
    sections.push(ui.Section("content", "", "", [
      ui.Timeline("__TIMELINE_STYLE_IDX__", "__TL_TITLE_IDX__", [
        __STEPS_IDX__
      ])
    ]));
  }`,
    [new SlotSpec('__TIMELINE_STYLE_IDX__', ['default', 'compact', 'comfortable'], 'choice',
      'How much room should the timeline steps have?', timelineStyle)],
    [new ContentFieldSpec('__TL_TITLE_IDX__', 'tl_title', 'Schedule', 'Short title for the timeline (1-3 words)', 20)],
    [],
    [new ListFieldSpec('__STEPS_IDX__', 'steps',
      'The steps in time order, as many as the request needs (3 to 8), each with the time it happens',
      ['what happens (2-5 words)', 'when it happens (a time, or a short day label)'], [28, 10],
      'ui.TimelineItem("default", "{0}", "", "{1}", "", 0, false, "clock")', ',\n        ', 3, 8,
      [['First step', '09:00'], ['Second step', '12:00'], ['Third step', '15:00']])]
  )
}

/**
 * Display-only bar chart of a few named categories, each with one whole number. The rows are pushed
 * into two arrays by the row template (names, values), the scale is the largest value, and the chart
 * is a ui.Sparkline with bars -- the same component the model reaches for when it writes a bar chart
 * itself. Numbers are the model's answer for the request; they are sample figures unless the request
 * gave real ones.
 */
function barChartFragment(): FragmentSpec {
  let barStyle: Map<string, string> = new Map<string, string>()
  barStyle.set('default', 'no, same tone as the rest')
  barStyle.set('accent', 'yes, highlighted')
  return new FragmentSpec(
    'bar_chart',
    'A bar chart comparing a handful of named categories by one number each, display-only, such as spending per category or votes per option',
    '',
    [],
    '',
    '',
    '',
    `{
    let names: string[] = [];
    let vals: number[] = [];
    let none: number[] = [];
    __BARS_IDX__
    let top: number = 1;
    for (let v: number of vals) {
      if (v > top) { top = v; }
    }
    sections.push(ui.Section("content", "", "", [
      ui.Sparkline("__BAR_STYLE_IDX__", vals, top, "__BAR_LABEL_IDX__", true, none, "accent", "", "", names, 0)
    ]));
  }`,
    [new SlotSpec('__BAR_STYLE_IDX__', ['default', 'accent'], 'choice',
      'Should the bars stand out with an accent tone?', barStyle)],
    [new ContentFieldSpec('__BAR_LABEL_IDX__', 'bar_label', 'Comparison', 'Short caption for the chart (2-5 words)', 32)],
    [],
    [new ListFieldSpec('__BARS_IDX__', 'bars',
      'The categories to compare, as many as the request needs (3 to 8), each with one whole number',
      ['name of the category (1-2 words)', 'its value as a whole number, no units, in full (8500000, not 8.5M)'], [14, 15],
      'names.push("{0}"); vals.push({1});', '\n    ', 3, 8,
      [['A', '3'], ['B', '5'], ['C', '2']], [1])]
  )
}

/**
 * A form that adds entries one at a time -- a short note and a whole-number amount -- and lists them
 * newest first under a running total. The one fragment with a growing list the person fills in, so
 * it covers expense logs, habit and score logs, anything shaped "add a line, see the total".
 * Amounts are whole units on purpose: money with cents is a request for the model to write the
 * program (needs_logic), not something a fixed fragment can promise.
 */
/**
 * The palette VeraSectionCompose.ets picks from, one per section slot. `checklist`/`metrics`
 * reproduce today's two flat templates exactly (as single-fragment compositions); `timer` and
 * `calendar_event` are the first capability-bound kinds, see the plan's rationale for why these
 * two specifically are safe to hardcode and navigation is not. `actions`/`progress_goal`/
 * `key_facts`/`note`/`rating`/`spotlight` round out the generic, SDK-free side of the palette.
 */
export function fragments(): FragmentSpec[] {
  return [
    checklistFragment(), metricsFragment(), timerFragment(), calendarEventFragment(),
    actionsFragment(), progressGoalFragment(), keyFactsFragment(), trendChartFragment(),
    noteFragment(), ratingFragment(), spotlightFragment(),
    searchListFragment(), dataTableFragment(), timelineFragment(),
    barChartFragment(),
    masterListFragment(), detailViewFragment(), listSummaryFragment(), filterBoxFragment(),
    recordLogFragment(), numberStripFragment(), breakdownTableFragment(), seriesChartFragment(), settleUpFragment(),
    itineraryFragment(), progressLineFragment(), intentPanelFragment(), remindersFragment()
  ]
}

/**
 * Both templates are generic, SDK-free placeholders: they cannot call a
 * phone API, cannot show real/named data, and cannot do anything beyond a
 * short fixed list or a couple of numbers. Jev's top-level `template` choice
 * is a shape match against a one-line description, which does not by itself
 * check for any of that -- a request can look "list-shaped" or "number-
 * shaped" while also demanding capability neither template has (confirmed
 * live: a detailed itinerary brief asking for real navigation/calendar SDK
 * calls still matched `list_detail` at 0.95 confidence). These questions are
 * asked once, regardless of which template matched, and clearing its own
 * `above` bar on any one of them vetoes the pick outright -- see readPick in
 * VeraSectionCompose.ets.
 */
export function vetoes(): VetoSpec[] {
  let yn = (yes: string, no: string): Map<string, string> => {
    let m: Map<string, string> = new Map<string, string>()
    m.set('true', yes)
    m.set('false', no)
    return m
  }
  return [
    new VetoSpec('needs_integration',
      'Does fulfilling this request need calling any phone API, SDK function, or app intent, or ' +
      'integrating with another app (navigation, messaging, camera, contacts, etc.) to read or act ' +
      'on real device/world state -- rather than only showing or manually updating numbers or ' +
      'items the app keeps for itself (even if a complete, faithful version of this app would ' +
      'eventually read one of these from a sensor or a real API)? Answer no if the only such need ' +
      'is adding one real event to the phone calendar with a button, which this app can already do ' +
      '-- that specific capability does not count here. Any other phone API, SDK, or app ' +
      'integration (navigation, messaging, camera, contacts, reading or searching the calendar, ' +
      'anything beyond adding a single new event) still counts as yes.',
      yn('yes', 'no, everything stays inside the app, or is only adding one calendar event'), 0.3),
    new VetoSpec('needs_real_data',
      'Does this request need particular real, named, or externally-sourced information (real ' +
      'places, real contacts, real recipes, real prices, etc.) rather than generic interchangeable ' +
      'placeholder content?',
      yn('yes', 'no, generic placeholder content is fine'), 0.35),
    new VetoSpec('needs_search_or_form',
      'Does this request need the person to search, filter, or sort a list, or fill in a multi-' +
      'field form (several distinct labeled fields in one entry), rather than just tapping a plain ' +
      'row or a plain number? A plain list of items or a few plain numbers do not count on their ' +
      'own just because a complete, faithful version of the app would eventually let someone add, ' +
      'remove or log an arbitrary number of them.',
      yn('yes', 'no, tapping a plain row or a plain number is enough'), 0.6),
    new VetoSpec('needs_live_ticking',
      'Does this request need a display that visibly ticks, counts down, or updates continuously ' +
      'on screen in real time by itself, like a running stopwatch or a live clock face -- rather ' +
      'than a number that only changes when the person taps something? A number that in real life ' +
      'would be measured or accumulated automatically over time (step count, water intake, ' +
      'calories, distance) still counts as a plain tap-to-change number here if it is simply shown ' +
      'as a static daily or periodic total, not a continuously ticking display. Answer no if all ' +
      'that is needed is a single simple countdown or stopwatch with a start/pause control and a ' +
      'reset, since this app already has exactly that. Still answer yes for anything beyond one ' +
      'plain timer -- several independent timers at once, a timer tied to a real alarm/notification, ' +
      'or a countdown driven by a real scheduled event rather than the person starting it.',
      yn('yes', 'no continuously updating display is needed, or only a single simple timer is'), 0.3),
    new VetoSpec('needs_multiple_counters',
      'Does this request need two or more separate NUMERIC counters or running totals that each ' +
      'independently go up or down, one per distinct person or thing -- for example one score per ' +
      'player in a multiplayer game -- rather than a single adjustable number shown alongside other ' +
      'read-only derived numbers like a total or a remaining amount? A list of items that are each ' +
      'just marked done/not done, present/absent, or on/off is one list, not multiple counters, and ' +
      'does not count -- only answer yes for genuinely separate running numeric tallies.',
      yn('yes', 'no, one adjustable number (plus derived read-only numbers) is enough'), 0.65),
    new VetoSpec('needs_multiple_series',
      'Does this request need a chart that compares two or more separate data series on the same ' +
      'axes -- for example men and women, two cities, this year and last year -- rather than a ' +
      'single line of values over one sequence (one measurement by year or by month)? One series ' +
      'with several points is not multiple series; only answer yes when each group needs its own line.',
      yn('yes', 'no, one line of values over one sequence is enough'), 0.65),
    new VetoSpec('needs_logic',
      'Does this request ask the app to calculate, convert, scale, split, total, compare or decide ' +
      'something from values -- for example amounts for a number of people, a tip split, a unit ' +
      'conversion, a score from rules, or anything that depends on an input the person gives -- ' +
      'rather than only listing, showing, or tapping fixed items and plain numbers?',
      yn('yes', 'no, showing or tapping fixed items and numbers is enough'), 0.8)
  ]
}
