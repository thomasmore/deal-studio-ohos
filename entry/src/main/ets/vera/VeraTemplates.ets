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
  /**
   * The rows are the person's own things (their medicines, their pantry): a row is kept only when the request names it, and none named
   * is an empty list, never the fallback. The fill wrote "Vitamin D" and "Blood pressure pill" for "remind me to take my pills", and
   * six foods for an empty pantry, whatever the hint said.
   */
  ownRows: boolean = false
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
  /** Marks the rows as the person's own (ownRows), for chaining after the constructor. */
  owned(): ListFieldSpec {
    this.ownRows = true
    return this
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
   * Drawn before the other blocks while keeping its own place in the order, and so in the numbering: a notice that part of the
   * screen is missing shows under the title, yet put first it took position 1 and renumbered every block after it, so a written
   * section that read state.items1 found items2 (review of #46). Set only on a block with no names of its own.
   */
  viewFirst: boolean = false
  /**
   * What the block already holds or lets the person set, in words for whoever decides what else the screen needs (Jev's choice of what a
   * section covers): "the start time of the day", so that no separate input for it is put on the screen. '' when it says nothing beyond criteria.
   */
  owns: string = ''
  /** The name of the block's tab in a widget in a chat reply (one or two words); '' for its kind in words. */
  tab: string = ''
  /**
   * Tokens the host fills from what it checked itself, never the content model: the live_figure section's call, found and fetched at
   * generation (LiveBlock.ets). Each fallback compiles, so the block draws before the host has filled it.
   */
  hostFields: ContentFieldSpec[] = []
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

/**
 * A list the person ticks off. A row not yet ticked has no icon and a ticked one a check: the same "list" icon on every row
 * said nothing and did not show which were done (Wind down, Chore stars, Baby fever). The group's header says how many are
 * done and that a row is tapped to tick it.
 */
function checklistFragment(): FragmentSpec {
  let listStyle: Map<string, string> = new Map<string, string>()
  listStyle.set('default', 'normal spacing')
  listStyle.set('compact', 'tighter spacing')
  listStyle.set('comfortable', 'looser spacing')
  return new FragmentSpec(
    'checklist',
    'A browsable list of items the person can check off or mark one at a time, with no time of day for each; it is not a deck of ' +
    'cards to flip, a quiz or a game, nor ideas or suggestions to pick one from (that is idea_deck), nor care tips to read, and ' +
    'places to visit on a day out or a trip are an itinerary, not this',
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
      let icon: string = "";
      let subtitle: string = it.detail;
      if (it.done) { icon = "check"; subtitle = "done"; if (it.detail.length() > 0) { subtitle = it.detail + " - done"; } }
      rows.push(ui.ListItem("default", it.label, subtitle, "", "toggleIDX", j, true, icon));
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(count === 0, ui.EmptyState("default", "Nothing here", "Add an item to get started.", "", "", "pin")),
      ui.When(count > 0, ui.ListGroup("__LIST_STYLE_IDX__", ui.numberToString(doneCountIDX(state)) + " of " + ui.numberToString(count) + " done - tap one to tick it", rows))
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
  let spec = new FragmentSpec(
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

function setTimeIDX(state: AppState, value: number): AppState {
  let minute: number = value % 60;
  let hour: number = (value - minute) / 60;
  if (hour < 0 || hour > 23) { hour = 8; minute = 0; }
  return withDraftIDX(state, state.draftTitleIDX, hour, minute, state.draftDailyIDX);
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
      ui.TimeField("default", "Time", state.draftHourIDX * 60 + state.draftMinuteIDX, "setTimeIDX"),
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
  // A section beside it that lists the same things (a medicine card) reads this list rather than keeping its own: Pills had
  // a form and list of reminders and, beside it, "My medicines" with a second form and list of the same medicines.
  spec.owns = 'the person\'s reminders (a list of records, each with a title such as a medicine, an hour, a minute and whether it ' +
    'repeats every day), the form that adds one with its time picker, and each one put into the phone calendar'
  return spec
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
        rows.push(ui.ListItem("default", name, "", "", "", j, false, ""));
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
        rows.push(ui.ListItem("default", title, "", shown, "", k, false, ""));
      } else {
        rows.push(ui.ListItem("default", who, r.note, shown, "", k, false, ""));
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

/**
 * A bar chart with one bar per person or category, from a record_log elsewhere on the screen: the totals, or the balances.
 * Before anything is recorded it is one line, not a chart of zeros: on Shared costs that was a tall empty card at the top.
 */
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
    let any: boolean = false;
    for (let v: number of vals) {
      if (v !== 0) { any = true; }
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(any, ui.Sparkline("default", vals, top, "__CHART_LABEL_IDX__", true, none, "accent", "", "", names, low)),
      ui.When(!any, ui.Text("caption", "__CHART_LABEL_IDX__: the bars appear once something is added"))
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
 *
 * When the day ends and how long it takes are shown under the stops, worked out from the stops themselves: a figure of the plan's
 * own beside the list worked the same out another way and said 11:30 under a last stop that ends at 17:15 (West Lake). The start
 * comes from the screen's own form when it sets one (port "start", VeraCompose.ets's dayStart), and then the block draws no start
 * field of its own: beside the form's it was a second start time, only one of which did anything.
 */
function itineraryFragment(): FragmentSpec {
  let navigate: Map<string, string> = new Map<string, string>()
  // Asked as what the stops are, not whether the request says "navigation": a day out or a trip seldom does (West Lake, a family
  // day, had no button). Off when unsure: a button that opens the maps app on a hall of a museum is worse than none.
  navigate.set('true', 'yes, the stops are separate places on a map that the person travels between (a trip, a tour, a day out in a city, a layover), or the request asks for directions')
  navigate.set('false', 'no, the stops are in one venue (rooms of a museum, rides of a park, a conference or a wedding), or steps of a routine or a schedule rather than places')
  let calendar: Map<string, string> = new Map<string, string>()
  calendar.set('true', 'yes, each stop can be added to the phone calendar, with buttons to open the calendar and remove the added events')
  calendar.set('false', 'no calendar is asked for')
  let spec = new FragmentSpec(
    'itinerary',
    'An ordered list of places or steps with a time window and duration each, which the person marks as reached one by one; ' +
    'it can also open a stop in the maps app and add stops to the phone calendar. A day plan, a day out, a trip itinerary, a tour, ' +
    'a route of stops: the sights to visit, each at its time',
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

function firstIDX(state: AppState): number {
  let given: number = __PORT_start__;
  if (given >= 0 && given <= 1439) { return given; }
  return state.startMinIDX;
}

// " +1 day" after a time that is past midnight (a long day, or long gaps between stops), so 00:34 is not read as this night's
// start; "" on the first day.
function dayMarkIDX(at: number): string {
  let days: number = 0;
  let rest: number = at;
  while (rest >= 1440) { days = days + 1; rest = rest - 1440; }
  if (days === 0) { return ""; }
  if (days === 1) { return " +1 day"; }
  return " +" + ui.numberToString(days) + " days";
}

// Whether a stop has somewhere for the maps app to go. The stops' writer gives coordinates for a place it knows and leaves them empty
// for one it does not, or for a meal or a break that is not a place (West Lake: every sight had them, "Lunch" had none); by name
// alone the maps app opens whatever it finds for "Lunch".
function navigableIDX(s: Stop): boolean {
  return s.latitude !== "" && s.longitude !== "";
}

function visibleStopsIDX(state: AppState): number {
  let limit: number = __PORT_deadline__;
  if (limit < 0) { return state.stopsIDX.length(); }
  let at: number = firstIDX(state);
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
  let start: number = firstIDX(state);
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
    let at: number = firstIDX(state);
    let shown: number = 0;
    let endsAt: number = at;
    let j: number = 0;
    while (j < count) {
      let s: Stop = state.stopsIDX[j];
      if (limit < 0 || at + s.minutes <= limit) {
        endsAt = at + s.minutes;
        let icon: string = "pin";
        let rowStyle: string = "default";
        // A reached stop keeps its pin and says so with the row's tone and its green check at the end: a "Reached" text made the
        // row jump on a tap, and a second check in place of the pin was one too many (Hangzhou).
        if (s.done) { rowStyle = "success"; }
        let subtitle: string = ui.clockToString(at) + " - " + ui.clockToString(at + s.minutes) + dayMarkIDX(at + s.minutes) + " | " + ui.numberToString(s.minutes) + " min";
        rows.push(ui.ListItem(rowStyle, s.name, subtitle, "", "toggleStopIDX", j, true, icon));
        // A tap on the row marks the stop reached, and the whole row turns green. Where the stops are places to travel between, the
        // row's one button opens the stop in the maps app, from the last stop reached; elsewhere it is a check that does what the
        // tap does, since without it nothing said the row could be tapped (Istanbul layover). A stop with no coordinates has no
        // button (navigableIDX).
        let buttons: ui.View[] = [];
        if (showNav && navigableIDX(s)) {
          buttons.push(ui.IconButton("secondary", "navigate", "Navigate to " + s.name, "navigateIDX", j, true));
        } else if (!showNav) {
          let reachStyle: string = "secondary";
          if (s.done) { reachStyle = "success"; }
          buttons.push(ui.IconButton(reachStyle, "check", "Mark reached", "toggleStopIDX", j, true));
        }
        if (showCal) {
          let calText: string = "Add to calendar";
          if (s.eventId !== "") { calText = "In calendar"; }
          buttons.push(ui.Button("secondary", calText, "addEventIDX", j, s.eventId === ""));
        }
        if (buttons.length() > 0) { rows.push(ui.ActionBar("end", buttons)); }
        shown = shown + 1;
      }
      at = at + s.minutes + state.gapIDX;
      j = j + 1;
    }
    let ownStartIDX: boolean = __PORT_start__ < 0;
    // The day's start is what the person sets first; the minutes between stops are a setting, right under the stops and above the
    // day's end and length they change (Istanbul layover: they stood above the plan itself; Hangzhou: at the very bottom, under
    // the summary, they were out of reach of what they move).
    if (ownStartIDX) { sections.push(ui.Section("content", "", "", [ui.TimeField("default", "Day starts", state.startMinIDX, "setStartIDX")])); }
    let emptyText: string = "Nothing is planned yet.";
    if (limit >= 0 && count > 0) { emptyText = "Nothing fits before " + ui.clockToString(limit) + "."; }
    // With no check on the rows, the section says what a tap on one does.
    let tapHintIDX: string = "";
    if (showNav && shown > 0) { tapHintIDX = "Tap a stop when you reach it"; }
    sections.push(ui.Section("content", "", tapHintIDX, [
      ui.When(shown === 0, ui.EmptyState("default", "No stops", emptyText, "", "", "pin")),
      ui.When(shown > 0, ui.ListGroup("default", "", rows)),
      ui.NumberField("default", "Minutes between stops", state.gapIDX, 0, 180, "setGapIDX", 5)
    ]));
    if (shown > 0) {
      let hoursIDX: number = 0;
      let restIDX: number = endsAt - firstIDX(state);
      while (restIDX >= 60) { hoursIDX = hoursIDX + 1; restIDX = restIDX - 60; }
      let lengthIDX: string = ui.numberToString(restIDX) + " min";
      if (hoursIDX > 0) { lengthIDX = ui.numberToString(hoursIDX) + " h " + lengthIDX; }
      if (hoursIDX > 0 && restIDX === 0) { lengthIDX = ui.numberToString(hoursIDX) + " h"; }
      // Past midnight the caption says only that, so it fits on one line (a "+1 day" after it wrapped on the phone).
      let endsCaptionIDX: string = "after the last stop";
      if (dayMarkIDX(endsAt) !== "") { endsCaptionIDX = "the next day"; }
      sections.push(ui.Section("content", "", "", [ui.MetricGroup("default", 2, [
        ui.Stat("default", "Day ends", ui.clockToString(endsAt), endsCaptionIDX, "clock"),
        ui.Stat("default", "Day length", lengthIDX, ui.numberToString(shown) + " stops", "clock")
      ])]));
    }
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
    [new SlotSpec('__NAVIGATE_IDX__', ['false', 'true'], 'noul', 'Are the stops separate places on a map that the person travels between, so that each can be opened in the maps app for directions?', navigate, 0.6,
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
      'The stops of the day in order, as many as the request needs (5 to 12): each with a name, how long it takes in minutes, and its latitude and longitude as decimals (an empty string when not known with confidence). A meal or a break the request mentions is a stop of its own at its place in the day, named for it (Lunch, 60 minutes), with the coordinates of where it is eaten or empty strings',
      ['name of the place (1-4 words)', 'minutes spent there, a whole number', 'latitude as a decimal such as 31.2397, or an empty string', 'longitude as a decimal such as 121.4900, or an empty string'],
      [28, 4, 12, 12],
      '{name: "{0}", minutes: {1}, latitude: "{2}", longitude: "{3}", done: false, eventId: ""}', ',\n    ', 5, 12,
      [['Stop 1', '60', '', ''], ['Stop 2', '60', '', ''], ['Stop 3', '60', '', ''], ['Stop 4', '60', '', ''], ['Stop 5', '60', '', '']],
      [1], ['', 'minutes', 'lat', 'lon'])],
    [new PortSpec('writes', 'done', 'number', 'reachedCountIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'visibleStopsIDX(state)', '', true),
     // The time of day by which the stops must be over (a flight to catch); -1: no such time, every stop is shown.
     new PortSpec('reads', 'deadline', 'number', '__PORT_deadline__', '-1', false, true),
     // The time of day the first stop starts, when the screen's form sets it (VeraCompose.ets's inputsPart); -1: the day's own.
     new PortSpec('reads', 'start', 'number', '__PORT_start__', '-1', false, true)],
    [],
    ['needs_logic', 'needs_search_or_form'],
    ['needs_integration=__NAVIGATE_IDX__|__CALENDAR_IDX__']
  )
  spec.owns = 'the start time of the day (the person sets it), the minutes between stops (the person sets them), the time each stop starts and ends, ' +
    'how long each stop takes, the time the day ends after the last stop (when they are back) and how long the whole day takes'
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
    'Steps or events in time order, each with a time, only to read: a daily schedule or a history. Places to visit on a day out ' +
    'or a trip, which the person goes to one after another, are an itinerary, not this',
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
/**
 * Something logged with one tap -- a glass of water, a feed, a nappy, a coffee: one big button adds the amount set for a tap,
 * stamped with the day and the minute. Today's total against a goal (a ring), today's count and how long since the last one;
 * today's entries newest first, an Undo of the last. Earlier days are kept but not counted as today. The amount per tap and the
 * goal are settings at the foot of the section. Water reminder had a form with an Amount field and an Add button for "one tap".
 */
function quickLogFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'quick_log',
    'One big button that logs the same thing with a single tap (a glass of water, a feed, a nappy change, a coffee, a cigarette), ' +
    'with today\'s total toward a daily goal, today\'s count, how long since the last one, and today\'s entries with an undo. ' +
    'Not for records where the person types an amount and a note each time, or tags each with a person or category: that is record_log',
    `@jsonable
class Tap {
  amount: number;
  day: number;
  minute: number;
}

@jsonable
class TapPreset {
  label: string;
  amount: number;
}`,
    [new StateFieldSpec('tapsIDX', 'Tap[]'), new StateFieldSpec('presetsIDX', 'TapPreset[]'),
     new StateFieldSpec('amountTextIDX', 'string'), new StateFieldSpec('goalTextIDX', 'string')],
    `  let presetsIDX: TapPreset[] = [
    __PRESETS_IDX__
  ];
  let firstAmountIDX: number = __AMOUNT_IDX__;
  if (firstAmountIDX <= 0) { firstAmountIDX = 1; }
  let firstGoalIDX: number = __GOAL_IDX__;
  if (firstGoalIDX < 0) { firstGoalIDX = 0; }
  let noTapsIDX: Tap[] = [];`,
    `tapsIDX: noTapsIDX, presetsIDX: presetsIDX, amountTextIDX: ui.numberToString(firstAmountIDX), goalTextIDX: ui.numberToString(firstGoalIDX)`,
    `function tapAmountIDX(state: AppState): number {
  let n: number = strings.toNumber(state.amountTextIDX, 1);
  if (n <= 0) { n = 1; }
  return n;
}

function tapGoalIDX(state: AppState): number {
  let n: number = strings.toNumber(state.goalTextIDX, 0);
  if (n < 0) { n = 0; }
  return n;
}

function logTapIDX(state: AppState, amount: number): AppState {
  let out: Tap[] = [];
  for (let t: Tap of state.tapsIDX) { out.push(t); }
  out.push({amount: amount, day: time.daysSinceEpoch(), minute: time.hourOfDay() * 60 + time.minuteOfHour()});
  return {tapsIDX: out__PASSTHROUGH__};
}

function addTapIDX(state: AppState, ignored: number): AppState {
  return logTapIDX(state, tapAmountIDX(state));
}

function addPresetIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.presetsIDX.length()) { return state; }
  return logTapIDX(state, state.presetsIDX[index].amount);
}

function removeTapIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.tapsIDX.length()) { return state; }
  let out: Tap[] = [];
  let i: number = 0;
  while (i < state.tapsIDX.length()) {
    if (i !== index) { out.push(state.tapsIDX[i]); }
    i = i + 1;
  }
  return {tapsIDX: out__PASSTHROUGH__};
}

function undoTapIDX(state: AppState, ignored: number): AppState {
  let today: number = time.daysSinceEpoch();
  let last: number = -1;
  let i: number = 0;
  while (i < state.tapsIDX.length()) {
    if (state.tapsIDX[i].day === today) { last = i; }
    i = i + 1;
  }
  return removeTapIDX(state, last);
}

function setTapAmountIDX(state: AppState, value: string): AppState {
  return {amountTextIDX: value__PASSTHROUGH__};
}

function setTapGoalIDX(state: AppState, value: string): AppState {
  return {goalTextIDX: value__PASSTHROUGH__};
}

function totalOnIDX(state: AppState, day: number): number {
  let n: number = 0;
  for (let t: Tap of state.tapsIDX) { if (t.day === day) { n = n + t.amount; } }
  return n;
}

function countOnIDX(state: AppState, day: number): number {
  let n: number = 0;
  for (let t: Tap of state.tapsIDX) { if (t.day === day) { n = n + 1; } }
  return n;
}

function todayTotalIDX(state: AppState): number { return totalOnIDX(state, time.daysSinceEpoch()); }

function todayCountIDX(state: AppState): number { return countOnIDX(state, time.daysSinceEpoch()); }

function tapAgoIDX(minutes: number): string {
  if (minutes < 1) { return "just now"; }
  let hours: number = math.floor(minutes / 60);
  let rest: number = minutes - hours * 60;
  if (hours === 0) { return ui.numberToString(rest) + " min ago"; }
  if (rest === 0) { return ui.numberToString(hours) + " h ago"; }
  return ui.numberToString(hours) + " h " + ui.numberToString(rest) + " min ago";
}`,
    `{
    let today: number = time.daysSinceEpoch();
    let nowMinute: number = time.hourOfDay() * 60 + time.minuteOfHour();
    let unit: string = "__UNIT_IDX__";
    let unitText: string = "";
    if (unit !== "") { unitText = " " + unit; }
    let goal: number = tapGoalIDX(state);
    let total: number = totalOnIDX(state, today);
    let count: number = countOnIDX(state, today);
    let lastMinute: number = -1;
    for (let t: Tap of state.tapsIDX) { if (t.day === today) { lastMinute = t.minute; } }
    let lastText: string = "nothing yet today";
    if (lastMinute >= 0) { lastText = tapAgoIDX(nowMinute - lastMinute); }
    let summary: ui.View[] = [];
    if (goal > 0) {
      let ringStyle: string = "accent";
      if (total >= goal) { ringStyle = "success"; }
      summary.push(ui.ProgressRing(ringStyle, "__TODAY_LABEL_IDX__", total, goal, ui.formatNumber(total, 0) + " of " + ui.formatNumber(goal, 0) + unitText));
    }
    let countText: string = ui.numberToString(count);
    summary.push(ui.MetricGroup("default", 2, [
      ui.Stat("default", "__COUNT_LABEL_IDX__", countText, "today", "chart"),
      ui.Stat("default", "Last", lastText, "", "clock")
    ]));
    sections.push(ui.Section("summary", "__SECTION_TITLE_IDX__", "", summary));
    let buttons: ui.View[] = [ui.Button("primary", "__BUTTON_IDX__", "addTapIDX", 0, true)];
    let p: number = 0;
    while (p < state.presetsIDX.length()) {
      buttons.push(ui.Button("secondary", state.presetsIDX[p].label, "addPresetIDX", p, true));
      p = p + 1;
    }
    sections.push(ui.Section("content", "", "", [ui.ActionBar("center", buttons)]));
    let rows: ui.View[] = [];
    let i: number = state.tapsIDX.length() - 1;
    while (i >= 0) {
      let t: Tap = state.tapsIDX[i];
      if (t.day === today) {
        let what: string = "__ENTRY_WORD_IDX__";
        if (unit !== "") { what = ui.formatNumber(t.amount, 0) + unitText; }
        rows.push(ui.ListItem("default", what, ui.clockToString(t.minute), "", "", 0, true, "check"));
        rows.push(ui.ActionBar("end", [ui.IconButton("quiet", "trash", "Remove", "removeTapIDX", i, true)]));
      }
      i = i - 1;
    }
    let yesterday: number = countOnIDX(state, today - 1);
    let notes: ui.View[] = [];
    if (count > 0) {
      notes.push(ui.ListGroup("default", "Today", rows));
      notes.push(ui.ActionBar("end", [ui.Button("secondary", "Undo", "undoTapIDX", 0, true)]));
    }
    if (yesterday > 0) {
      let yText: string = "Yesterday: " + ui.numberToString(yesterday);
      if (unit !== "") { yText = yText + ", " + ui.formatNumber(totalOnIDX(state, today - 1), 0) + unitText; }
      notes.push(ui.Text("muted", yText));
    }
    if (notes.length() > 0) { sections.push(ui.Section("content", "", "", notes)); }
    let settings: ui.View[] = [];
    if (unit !== "") { settings.push(ui.TextField("default", "Amount per tap (" + unit + ")", state.amountTextIDX, "setTapAmountIDX", "number")); }
    let goalLabel: string = "Daily goal (0 for none)";
    if (unit !== "") { goalLabel = "Daily goal (" + unit + ", 0 for none)"; }
    settings.push(ui.TextField("default", goalLabel, state.goalTextIDX, "setTapGoalIDX", "number"));
    sections.push(ui.Section("supporting", "", "", settings));
  }`,
    [],
    [
      new ContentFieldSpec('__SECTION_TITLE_IDX__', 'section_title', 'Today', 'Heading of the section (1-3 words, such as Water today)', 24),
      new ContentFieldSpec('__BUTTON_IDX__', 'button', 'Add one', 'Label of the one-tap button (2-3 words, such as Add a glass, Log a feed)', 20),
      new ContentFieldSpec('__AMOUNT_IDX__', 'amount', '1', 'How much one tap adds, a whole number in the unit (250 for a glass of water in ml); 1 when each tap is simply one more', 6, true),
      new ContentFieldSpec('__UNIT_IDX__', 'unit', '', 'The unit of the amount, such as ml or g; an empty string when each tap is simply one more (a nappy, a coffee)', 8),
      new ContentFieldSpec('__GOAL_IDX__', 'goal', '0', 'The daily goal in the same unit as a whole number (2000 for water in ml), or 0 for no goal', 6, true),
      new ContentFieldSpec('__TODAY_LABEL_IDX__', 'today_label', 'Today', 'Label of the ring toward the goal (1-2 words)', 16),
      new ContentFieldSpec('__COUNT_LABEL_IDX__', 'count_label', 'Count', 'Label of today\'s count, the thing counted (1-2 words, such as Glasses or Feeds)', 16),
      new ContentFieldSpec('__ENTRY_WORD_IDX__', 'entry_word', 'One logged', 'What one entry is called on its row when there is no unit (1-3 words, such as Nappy change)', 20)
    ],
    ['import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [new ListFieldSpec('__PRESETS_IDX__', 'presets',
      'Other amounts as extra buttons, only when the request names different sizes (a small and a large glass); usually none',
      ['button label (1-3 words)', 'the amount it adds, a whole number in the unit'], [16, 6],
      '{label: "{0}", amount: {1}}', ',\n    ', 0, 3, [], [1])],
    [new PortSpec('writes', 'today_total', 'number', 'todayTotalIDX(state)', '', true),
     new PortSpec('writes', 'today_count', 'number', 'todayCountIDX(state)', '', true),
     new PortSpec('writes', 'goal', 'number', 'tapGoalIDX(state)', '', true)],
    [],
    ['needs_search_or_form']
  )
  spec.owns = 'the one-tap button that logs an entry (with any preset amounts), today\'s total toward the daily goal as a ring, today\'s count, ' +
    'how long since the last one, today\'s entries with Remove on each and an Undo button, yesterday\'s count, and the amount per tap and ' +
    'the daily goal as settings at its foot'
  return spec
}

/**
 * Doses to take at set times each day, each ticked off when taken: the doses the request names, a form to add one, a Take button
 * per dose that becomes an Undo, "2 of 3 taken today" and a streak of days on which every dose was taken. The marks are per day
 * (the day number a dose was last taken), so a new day starts untaken without anything running at midnight. A dose past its time
 * and not taken says it is late. Optionally each dose goes into the phone calendar with a daily reminder, as `reminders` does.
 * Medicine card had only a list of reminders and nowhere to say a pill was taken.
 */
function doseScheduleFragment(): FragmentSpec {
  let calendar: Map<string, string> = new Map<string, string>()
  calendar.set('true', 'yes, each dose goes into the phone calendar with a daily reminder')
  calendar.set('false', 'no, the doses are only ticked off in the app')
  let spec = new FragmentSpec(
    'dose_schedule',
    'Medicines, vitamins or other doses to take at set times every day, each ticked off when taken today, with how many are taken ' +
    'today, which are late, and a streak of days with every dose taken; the person can add and remove doses, and each can go into the ' +
    'phone calendar with a daily reminder. Not for one-off reminders or appointments (that is reminders), nor a log of amounts (record_log)',
    `@jsonable
class Dose {
  name: string;
  minute: number;
  note: string;
  takenDay: number;
  takenAt: number;
  eventId: string;
  status: string;
}

@jsonable
class DoseSeed {
  name: string;
  time: string;
  note: string;
}`,
    [new StateFieldSpec('dosesIDX', 'Dose[]'), new StateFieldSpec('streakIDX', 'number'), new StateFieldSpec('streakDayIDX', 'number'),
     new StateFieldSpec('draftNameIDX', 'string'), new StateFieldSpec('draftMinuteIDX', 'number'),
     new StateFieldSpec('pendingIDX', 'number'), new StateFieldSpec('doseNoteIDX', 'string')],
    `  let seedsIDX: DoseSeed[] = [
    __DOSES_IDX__
  ];
  let dosesIDX: Dose[] = [];
  for (let s: DoseSeed of seedsIDX) {
    let parts: string[] = strings.split(strings.trim(s.time), ":");
    let hour: number = 8;
    let minute: number = 0;
    if (parts.length() >= 1) { hour = strings.toNumber(parts[0], 8); }
    if (parts.length() >= 2) { minute = strings.toNumber(parts[1], 0); }
    if (hour < 0 || hour > 23) { hour = 8; }
    if (minute < 0 || minute > 59) { minute = 0; }
    dosesIDX.push({name: s.name, minute: hour * 60 + minute, note: s.note, takenDay: -1, takenAt: -1, eventId: "", status: ""});
  }`,
    `dosesIDX: dosesIDX, streakIDX: 0, streakDayIDX: -1, draftNameIDX: "", draftMinuteIDX: 480, pendingIDX: -1, doseNoteIDX: ""`,
    `function failedIDX(value: string): boolean {
  return strings.startsWith(value, "declined") || strings.startsWith(value, "error");
}

function takenOnIDX(state: AppState, day: number): number {
  let n: number = 0;
  for (let d: Dose of state.dosesIDX) { if (d.takenDay === day) { n = n + 1; } }
  return n;
}

function takenTodayIDX(state: AppState): number { return takenOnIDX(state, time.daysSinceEpoch()); }

function shownStreakIDX(state: AppState): number {
  if (state.streakDayIDX < time.daysSinceEpoch() - 1) { return 0; }
  return state.streakIDX;
}

function withDoseIDX(list: Dose[], index: number, changed: Dose): Dose[] {
  let out: Dose[] = [];
  let i: number = 0;
  while (i < list.length()) {
    if (i === index) { out.push(changed); } else { out.push(list[i]); }
    i = i + 1;
  }
  return out;
}

function takeDoseIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.dosesIDX.length()) { return state; }
  let today: number = time.daysSinceEpoch();
  let d: Dose = state.dosesIDX[index];
  let allBefore: boolean = state.dosesIDX.length() > 0 && takenOnIDX(state, today) === state.dosesIDX.length();
  let takenDay: number = today;
  let takenAt: number = time.hourOfDay() * 60 + time.minuteOfHour();
  if (d.takenDay === today) { takenDay = -1; takenAt = -1; }
  let out: Dose[] = withDoseIDX(state.dosesIDX, index, {name: d.name, minute: d.minute, note: d.note, takenDay: takenDay, takenAt: takenAt, eventId: d.eventId, status: d.status});
  let allNow: boolean = true;
  for (let x: Dose of out) { if (x.takenDay !== today) { allNow = false; } }
  let streak: number = shownStreakIDX(state);
  let streakDay: number = state.streakDayIDX;
  if (allNow && !allBefore) {
    if (streakDay === today - 1) { streak = streak + 1; } else if (streakDay !== today) { streak = 1; }
    streakDay = today;
  }
  if (!allNow && allBefore && streakDay === today) {
    streak = streak - 1;
    streakDay = today - 1;
    if (streak <= 0) { streak = 0; streakDay = -1; }
  }
  return {dosesIDX: out, streakIDX: streak, streakDayIDX: streakDay__PASSTHROUGH__};
}

function setDoseNameIDX(state: AppState, value: string): AppState {
  return {draftNameIDX: value__PASSTHROUGH__};
}

function setDoseTimeIDX(state: AppState, value: number): AppState {
  let minute: number = value;
  if (minute < 0 || minute > 1439) { minute = 480; }
  return {draftMinuteIDX: minute__PASSTHROUGH__};
}

function calendarCallIDX(name: string, minute: number): number {
  let m: number = minute % 60;
  let h: number = (minute - m) / 60;
  sdk.call("CalendarKit.Calendar.addEvent",
    ["title", "__EVENT_PREFIX_IDX__" + name, "hour", ui.numberToString(h), "minute", ui.numberToString(m),
     "durationMinutes", "15", "remindBefore", "0", "repeat", "daily", "description", "__EVENT_NOTE_IDX__"], "onDoseAddedIDX");
  return 0;
}

function addDoseIDX(state: AppState, ignored: number): AppState {
  let name: string = strings.trim(state.draftNameIDX);
  if (name.length() === 0) { return state; }
  let useCalendar: boolean = __CALENDAR_IDX__;
  let status: string = "";
  let pending: number = state.pendingIDX;
  if (useCalendar && pending < 0) {
    status = "pending";
    pending = state.dosesIDX.length();
    calendarCallIDX(name, state.draftMinuteIDX);
  }
  let out: Dose[] = [];
  for (let d: Dose of state.dosesIDX) { out.push(d); }
  out.push({name: name, minute: state.draftMinuteIDX, note: "", takenDay: -1, takenAt: -1, eventId: "", status: status});
  return {dosesIDX: out, draftNameIDX: "", pendingIDX: pending, doseNoteIDX: ""__PASSTHROUGH__};
}

function calendarDoseIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.dosesIDX.length() || state.pendingIDX >= 0) { return state; }
  let d: Dose = state.dosesIDX[index];
  if (d.eventId !== "") { return state; }
  calendarCallIDX(d.name, d.minute);
  let out: Dose[] = withDoseIDX(state.dosesIDX, index, {name: d.name, minute: d.minute, note: d.note, takenDay: d.takenDay, takenAt: d.takenAt, eventId: "", status: "pending"});
  return {dosesIDX: out, pendingIDX: index__PASSTHROUGH__};
}

function onDoseAddedIDX(state: AppState, value: string): AppState {
  let at: number = state.pendingIDX;
  if (at < 0 || at >= state.dosesIDX.length()) { return state; }
  let d: Dose = state.dosesIDX[at];
  let changed: Dose = {name: d.name, minute: d.minute, note: d.note, takenDay: d.takenDay, takenAt: d.takenAt, eventId: value, status: "ok"};
  let note: string = "";
  if (failedIDX(value)) {
    changed = {name: d.name, minute: d.minute, note: d.note, takenDay: d.takenDay, takenAt: d.takenAt, eventId: "", status: value};
    note = value;
  }
  return {dosesIDX: withDoseIDX(state.dosesIDX, at, changed), pendingIDX: -1, doseNoteIDX: note__PASSTHROUGH__};
}

function removeDoseIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.dosesIDX.length()) { return state; }
  let gone: Dose = state.dosesIDX[index];
  let out: Dose[] = [];
  let i: number = 0;
  while (i < state.dosesIDX.length()) {
    if (i !== index) { out.push(state.dosesIDX[i]); }
    i = i + 1;
  }
  let pending: number = state.pendingIDX;
  if (pending === index) { pending = -1; }
  if (pending > index) { pending = pending - 1; }
  if (gone.eventId !== "") { sdk.call("CalendarKit.Calendar.deleteEvents", ["ids", gone.eventId], "onDoseRemovedIDX"); }
  return {dosesIDX: out, pendingIDX: pending__PASSTHROUGH__};
}

function onDoseRemovedIDX(state: AppState, value: string): AppState {
  if (failedIDX(value)) { return {doseNoteIDX: value__PASSTHROUGH__}; }
  return state;
}`,
    `{
    let useCalendar: boolean = __CALENDAR_IDX__;
    let today: number = time.daysSinceEpoch();
    let nowMinute: number = time.hourOfDay() * 60 + time.minuteOfHour();
    let count: number = state.dosesIDX.length();
    let taken: number = takenOnIDX(state, today);
    let streak: number = shownStreakIDX(state);
    let progressStyle: string = "accent";
    if (count > 0 && taken === count) { progressStyle = "success"; }
    let streakText: string = ui.numberToString(streak) + " days";
    if (streak === 1) { streakText = "1 day"; }
    sections.push(ui.Section("summary", "__SECTION_TITLE_IDX__", "", [
      ui.Progress(progressStyle, ui.numberToString(taken) + " of " + ui.numberToString(count) + " taken today", taken, math.max(count, 1)),
      ui.MetricGroup("default", 2, [
        ui.Stat("default", "Taken today", ui.numberToString(taken) + " of " + ui.numberToString(count), "", "check"),
        ui.Stat("default", "Streak", streakText, "every dose taken", "star")
      ])
    ]));
    let rows: ui.View[] = [];
    let j: number = 0;
    while (j < count) {
      let d: Dose = state.dosesIDX[j];
      let isTaken: boolean = d.takenDay === today;
      let rowStyle: string = "default";
      let icon: string = "clock";
      let when: string = ui.clockToString(d.minute);
      if (d.note !== "") { when = when + " - " + d.note; }
      let trailing: string = "";
      if (isTaken) {
        rowStyle = "success"; icon = "check";
        trailing = "Taken " + ui.clockToString(d.takenAt);
      } else if (nowMinute > d.minute) {
        rowStyle = "warning"; icon = "warning";
        when = "Due " + ui.clockToString(d.minute) + " - late";
      }
      if (useCalendar) {
        if (d.status === "pending") { when = when + " - sending to calendar"; }
        else if (d.status === "ok") { when = when + " - in calendar"; }
        else if (d.status !== "") { when = when + " - not in calendar"; }
      }
      rows.push(ui.ListItem(rowStyle, d.name, when, trailing, "", 0, true, icon));
      let takeText: string = "Take";
      let takeStyle: string = "primary";
      if (isTaken) { takeText = "Undo"; takeStyle = "secondary"; }
      let buttons: ui.View[] = [ui.Button(takeStyle, takeText, "takeDoseIDX", j, true)];
      if (useCalendar && d.eventId === "" && d.status !== "pending") {
        buttons.push(ui.IconButton("secondary", "calendar", "Add to calendar", "calendarDoseIDX", j, state.pendingIDX < 0));
      }
      buttons.push(ui.IconButton("quiet", "trash", "Remove", "removeDoseIDX", j, true));
      rows.push(ui.ActionBar("end", buttons));
      j = j + 1;
    }
    sections.push(ui.Section("content", "", "", [
      ui.When(count === 0, ui.Text("muted", "No doses yet: add one below.")),
      ui.When(count > 0, ui.ListGroup("default", "", rows))
    ]));
    let notes: ui.View[] = [];
    if (state.doseNoteIDX !== "") { notes.push(ui.InsetBanner("warning", "The calendar said no", state.doseNoteIDX, "", "", "info")); }
    notes.push(ui.TextField("default", "__NAME_LABEL_IDX__", state.draftNameIDX, "setDoseNameIDX"));
    notes.push(ui.TimeField("default", "Time", state.draftMinuteIDX, "setDoseTimeIDX"));
    notes.push(ui.ActionBar("end", [ui.Button("secondary", "Add dose", "addDoseIDX", 0, strings.trim(state.draftNameIDX).length() > 0)]));
    sections.push(ui.Section("supporting", "__FORM_TITLE_IDX__", "", notes));
  }`,
    [new SlotSpec('__CALENDAR_IDX__', ['false', 'true'], 'noul',
      'Should each dose be put into the phone calendar with a daily reminder?', calendar, 0.6, ['calendar_add'])],
    [
      new ContentFieldSpec('__SECTION_TITLE_IDX__', 'section_title', 'Today\'s doses', 'Heading of the section (1-3 words, such as Today\'s pills)', 24),
      new ContentFieldSpec('__FORM_TITLE_IDX__', 'form_title', 'Add a dose', 'Heading of the form that adds one (2-4 words)', 24),
      new ContentFieldSpec('__NAME_LABEL_IDX__', 'name_label', 'Name', 'Label of the name field (1-2 words, such as Medicine)', 20),
      new ContentFieldSpec('__EVENT_PREFIX_IDX__', 'event_prefix', 'Take ', 'Words put before the name in the calendar event, such as "Take ", or an empty string', 12),
      new ContentFieldSpec('__EVENT_NOTE_IDX__', 'event_note', 'Daily dose', 'A short note for the calendar event (2-6 words, no quotes)', 40)
    ],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [new ListFieldSpec('__DOSES_IDX__', 'doses',
      'The doses of medicines the request names by name, one per time of day it is taken (a pill taken morning and evening is two rows). ' +
      '"My pills" or "my medicine" names none: then an empty list, and the person adds their own. Never a made-up medicine',
      ['name exactly as the request gives it (1-4 words)', 'time of day as HH:MM in 24 hours, such as 08:00', 'a short note such as with food, or an empty string'],
      [28, 5, 24],
      '{name: "{0}", time: "{1}", note: "{2}"}', ',\n    ', 0, 8, []).owned()],
    [new PortSpec('writes', 'taken_today', 'number', 'takenTodayIDX(state)', '', true),
     new PortSpec('writes', 'doses', 'number', 'state.dosesIDX.length()', '', true),
     new PortSpec('writes', 'streak', 'number', 'shownStreakIDX(state)', '', true)],
    [],
    ['needs_search_or_form'],
    ['needs_integration=__CALENDAR_IDX__']
  )
  spec.owns = 'the doses with their times, a Take button on each that becomes Undo once taken, which doses are late, how many are taken ' +
    'today as a bar, the streak of days with every dose taken, a form to add a dose with its time, Remove on each, and each dose put into ' +
    'the phone calendar with a daily reminder'
  return spec
}

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
const DUE_CLASS: string = `@jsonable
class DueItem {
  name: string;
  dueDay: number;
  lifeDays: number;
}

@jsonable
class DueSeed {
  name: string;
  inDays: number;
  lifeDays: number;
}`

/**
 * Things that run out or fall due: food that expires, a filter to change, a car service, a passport. Each has the day it is due
 * (the day number time.daysSinceEpoch() counts) and, when it comes round again, a life in days: Done starts it over from today.
 * The list is always soonest first, each row saying how far off it is in words and in a tone (expired and today in red, within
 * the soon window in amber). A plain list of food with dates was a form and a list newest first, with nothing that said what
 * was about to go off (Pantry expiry, Filter tracker, Service log).
 */
function dueItemsFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'due_items',
    'Things that run out or fall due, each with a date: food that expires, filters or batteries to change, a car service, a ' +
    'passport or a subscription to renew. Always sorted by the soonest due, each saying how many days are left or how long ago it ' +
    'expired, with what is due soon counted at the top; something that comes round again (every 90 days) is started over with Done. ' +
    'Not a to-do list without dates (that is checklist), not a daily schedule of times (that is reminders)',
    DUE_CLASS,
    [new StateFieldSpec('itemsIDX', 'DueItem[]'), new StateFieldSpec('todayIDX', 'number'), new StateFieldSpec('soonIDX', 'number'),
     new StateFieldSpec('draftNameIDX', 'string'), new StateFieldSpec('draftDueIDX', 'number'), new StateFieldSpec('draftLifeIDX', 'string')],
    `  let todayIDX: number = time.daysSinceEpoch();
  let seedsIDX: DueSeed[] = [
    __ITEMS_IDX__
  ];
  let itemsIDX: DueItem[] = [];
  for (let s: DueSeed of seedsIDX) {
    let lifeIDX: number = s.lifeDays;
    if (lifeIDX < 0) { lifeIDX = 0; }
    itemsIDX.push({name: s.name, dueDay: todayIDX + s.inDays, lifeDays: lifeIDX});
  }
  let soonIDX: number = __SOON_DAYS_IDX__;
  if (soonIDX < 0 || soonIDX > 60) { soonIDX = 3; }`,
    `itemsIDX: itemsIDX, todayIDX: todayIDX, soonIDX: soonIDX, draftNameIDX: "", draftDueIDX: todayIDX, draftLifeIDX: ""`,
    `function withItemsIDX(state: AppState, items: DueItem[]): AppState {
  return {itemsIDX: items, todayIDX: time.daysSinceEpoch(), soonIDX: state.soonIDX, draftNameIDX: state.draftNameIDX, draftDueIDX: state.draftDueIDX, draftLifeIDX: state.draftLifeIDX__PASSTHROUGH__};
}

function setNameIDX(state: AppState, value: string): AppState {
  return {itemsIDX: state.itemsIDX, todayIDX: state.todayIDX, soonIDX: state.soonIDX, draftNameIDX: value, draftDueIDX: state.draftDueIDX, draftLifeIDX: state.draftLifeIDX__PASSTHROUGH__};
}

function setDueIDX(state: AppState, value: number): AppState {
  return {itemsIDX: state.itemsIDX, todayIDX: state.todayIDX, soonIDX: state.soonIDX, draftNameIDX: state.draftNameIDX, draftDueIDX: value, draftLifeIDX: state.draftLifeIDX__PASSTHROUGH__};
}

function setLifeIDX(state: AppState, value: string): AppState {
  return {itemsIDX: state.itemsIDX, todayIDX: state.todayIDX, soonIDX: state.soonIDX, draftNameIDX: state.draftNameIDX, draftDueIDX: state.draftDueIDX, draftLifeIDX: value__PASSTHROUGH__};
}

function setSoonIDX(state: AppState, value: number): AppState {
  return {itemsIDX: state.itemsIDX, todayIDX: state.todayIDX, soonIDX: value, draftNameIDX: state.draftNameIDX, draftDueIDX: state.draftDueIDX, draftLifeIDX: state.draftLifeIDX__PASSTHROUGH__};
}

function addItemIDX(state: AppState, ignored: number): AppState {
  let name: string = strings.trim(state.draftNameIDX);
  if (name === "") { return state; }
  let life: number = math.round(strings.toNumber(state.draftLifeIDX, 0));
  if (life < 0) { life = 0; }
  let out: DueItem[] = [];
  for (let it: DueItem of state.itemsIDX) { out.push(it); }
  out.push({name: name, dueDay: state.draftDueIDX, lifeDays: life});
  let today: number = time.daysSinceEpoch();
  return {itemsIDX: out, todayIDX: today, soonIDX: state.soonIDX, draftNameIDX: "", draftDueIDX: today, draftLifeIDX: ""__PASSTHROUGH__};
}

function renewIDX(state: AppState, index: number): AppState {
  let today: number = time.daysSinceEpoch();
  let out: DueItem[] = [];
  let i: number = 0;
  while (i < state.itemsIDX.length()) {
    let it: DueItem = state.itemsIDX[i];
    if (i === index && it.lifeDays > 0) { out.push({name: it.name, dueDay: today + it.lifeDays, lifeDays: it.lifeDays}); }
    else { out.push(it); }
    i = i + 1;
  }
  return withItemsIDX(state, out);
}

function removeItemIDX(state: AppState, index: number): AppState {
  let out: DueItem[] = [];
  let i: number = 0;
  while (i < state.itemsIDX.length()) {
    if (i !== index) { out.push(state.itemsIDX[i]); }
    i = i + 1;
  }
  return withItemsIDX(state, out);
}

function refreshTodayIDX(state: AppState, elapsedMs: number): AppState {
  let today: number = time.daysSinceEpoch();
  if (today === state.todayIDX) { return state; }
  return {itemsIDX: state.itemsIDX, todayIDX: today, soonIDX: state.soonIDX, draftNameIDX: state.draftNameIDX, draftDueIDX: state.draftDueIDX, draftLifeIDX: state.draftLifeIDX__PASSTHROUGH__};
}

function sortedIDX(state: AppState): number[] {
  let order: number[] = [];
  let i: number = 0;
  while (i < state.itemsIDX.length()) {
    let at: number = order.length();
    let j: number = 0;
    while (j < order.length()) {
      if (state.itemsIDX[i].dueDay < state.itemsIDX[order[j]].dueDay) { at = j; break; }
      j = j + 1;
    }
    let next: number[] = [];
    let k: number = 0;
    while (k < order.length()) {
      if (k === at) { next.push(i); }
      next.push(order[k]);
      k = k + 1;
    }
    if (at === order.length()) { next.push(i); }
    order = next;
    i = i + 1;
  }
  return order;
}

function expiredCountIDX(state: AppState): number {
  let n: number = 0;
  for (let it: DueItem of state.itemsIDX) { if (it.dueDay < state.todayIDX) { n = n + 1; } }
  return n;
}

function soonCountIDX(state: AppState): number {
  let n: number = 0;
  for (let it: DueItem of state.itemsIDX) {
    let left: number = it.dueDay - state.todayIDX;
    if (left >= 0 && left <= state.soonIDX) { n = n + 1; }
  }
  return n;
}

function soonNamesIDX(state: AppState): string {
  let out: string = "";
  for (let i: number of sortedIDX(state)) {
    let it: DueItem = state.itemsIDX[i];
    let left: number = it.dueDay - state.todayIDX;
    if (left >= 0 && left <= state.soonIDX) {
      if (out.length() > 0) { out = out + ", "; }
      out = out + it.name;
    }
  }
  return out;
}

function daysWordIDX(n: number): string {
  if (n === 1) { return "1 day"; }
  return ui.numberToString(n) + " days";
}`,
    `{
    let n: number = state.itemsIDX.length();
    let expired: number = expiredCountIDX(state);
    let soon: number = soonCountIDX(state);
    let rows: ui.View[] = [];
    for (let i: number of sortedIDX(state)) {
      let it: DueItem = state.itemsIDX[i];
      let left: number = it.dueDay - state.todayIDX;
      let badge: string = "In " + daysWordIDX(left);
      let tone: string = "default";
      let icon: string = "calendar";
      if (left < 0) { badge = "Expired " + daysWordIDX(0 - left) + " ago"; tone = "danger"; icon = "warning"; }
      else if (left === 0) { badge = "Today"; tone = "danger"; icon = "warning"; }
      else if (left === 1) { badge = "Tomorrow"; tone = "warning"; icon = "clock"; }
      else if (left <= state.soonIDX) { tone = "warning"; icon = "clock"; }
      let detail: string = ui.dateToString(it.dueDay);
      if (it.lifeDays > 0) {
        let rest: number = left;
        if (rest < 0) { rest = 0; }
        if (rest > it.lifeDays) { rest = it.lifeDays; }
        detail = detail + " · every " + daysWordIDX(it.lifeDays) + " · " + ui.numberToString(math.round(rest * 100 / it.lifeDays)) + "% left";
      }
      rows.push(ui.ListItem(tone, it.name, detail, badge, "", i, true, icon));
      let buttons: ui.View[] = [];
      if (it.lifeDays > 0) { buttons.push(ui.Button("secondary", "Done", "renewIDX", i, true)); }
      buttons.push(ui.IconButton("quiet", "trash", "Remove", "removeItemIDX", i, true));
      rows.push(ui.ActionBar("end", buttons));
    }
    if (n > 0) {
      let expiredTone: string = "default";
      if (expired > 0) { expiredTone = "danger"; }
      let soonTone: string = "default";
      if (soon > 0) { soonTone = "warning"; }
      sections.push(ui.Section("summary", "", "", [ui.MetricGroup("default", 2, [
        ui.NumberStat(expiredTone, "Expired", expired, "", "", 1, "past their date", "warning", 0),
        ui.NumberStat(soonTone, "Due soon", soon, "", "", 1, "within " + daysWordIDX(state.soonIDX), "clock", 0)
      ])]));
    }
    let typed: boolean = strings.trim(state.draftNameIDX) !== "";
    let compactIDX: boolean = __WIDGET__;
    sections.push(ui.Section("content", "__FORM_TITLE_IDX__", "", [
      ui.TextField("default", "__NAME_LABEL_IDX__", state.draftNameIDX, "setNameIDX"),
      ui.DateField("default", "__DATE_LABEL_IDX__", state.draftDueIDX, "setDueIDX"),
      ui.When(!compactIDX, ui.TextField("default", "Comes round every (days, blank for once)", state.draftLifeIDX, "setLifeIDX", "number")),
      ui.ActionBar("end", [ui.Button("primary", "Add", "addItemIDX", 0, typed)])
    ]));
    sections.push(ui.Section("content", "", "", [
      ui.When(n === 0, ui.EmptyState("default", "Nothing tracked yet", "Add something with its date above.", "", "", "calendar")),
      ui.When(n > 0, ui.ListGroup("default", "", rows))
    ]));
    sections.push(ui.Section("supporting", "", "", [
      ui.NumberField("default", "Due soon means within (days)", state.soonIDX, 0, 60, "setSoonIDX"),
      ui.Ticker("default", "dueDayIDX", 3600000, true, "refreshTodayIDX")
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__FORM_TITLE_IDX__', 'form_title', 'Add an item', 'Heading of the form (2-4 words, e.g. Add food)', 24),
      new ContentFieldSpec('__NAME_LABEL_IDX__', 'name_label', 'Item', 'Label of the name field (1-2 words, e.g. Food, Filter)', 16),
      new ContentFieldSpec('__DATE_LABEL_IDX__', 'date_label', 'Due', 'Label of the date field (1-2 words, e.g. Expires, Due)', 16),
      new ContentFieldSpec('__SOON_DAYS_IDX__', 'soon_days', '3', 'How many days ahead count as due soon, as a whole number (1 to 30)', 2, true)
    ],
    ['import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [new ListFieldSpec('__ITEMS_IDX__', 'items',
      'The things the request itself names, each with when it is due (0 to 12 rows); none when the person adds their own (a pantry, ' +
      'documents they will enter). Only things the request states: never made-up food or dates',
      ['name of the thing (1-4 words)', 'days from today until it is due, a whole number (0 today, negative when already past)',
       'its life in days when it comes round again (90 for every 90 days), 0 when it happens once'],
      [28, 5, 5], '{name: "{0}", inDays: {1}, lifeDays: {2}}', ',\n    ', 0, 12, [], [1, 2]).owned()],
    [new PortSpec('writes', 'soon_count', 'number', 'soonCountIDX(state)', '', true),
     new PortSpec('writes', 'expired_count', 'number', 'expiredCountIDX(state)', '', true),
     new PortSpec('writes', 'soon_names', 'string', 'soonNamesIDX(state)', '', true),
     new PortSpec('writes', 'count', 'number', 'state.itemsIDX.length()', '', true)],
    [],
    ['needs_search_or_form', 'needs_logic']
  )
  spec.tab = 'Due'
  return spec
}

const POINTS_CLASS: string = `@jsonable
class PointsTask {
  name: string;
  points: number;
}

@jsonable
class PointsEntry {
  who: number;
  what: string;
  points: number;
  day: number;
  minute: number;
}`

/**
 * Points a few people earn for tasks and spend on rewards: a chore chart for two kids, stars for practice. Each task and each reward
 * is one tap for the person picked; a reward that costs more than the balance is dimmed and says what it still needs. Not money:
 * shared costs are record_log. Publishes the people and each one's balance under the names record_log uses (labels, totals), so a
 * bar chart that reads them (series_chart) shows the points.
 */
function pointsLedgerFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'points_ledger',
    'Points or stars that one to four named people (kids, a team, players) earn by doing tasks and spend on rewards: each task and ' +
    'each reward is one tap, each person\'s balance is shown big, a reward costing more than the balance says what it still needs, ' +
    'and the history of points earned and spent can be undone. A chore chart, a reward chart, a habit score for kids. Not money ' +
    'shared between people (that is record_log), not a single goal bar (that is progress_goal)',
    POINTS_CLASS,
    [new StateFieldSpec('peopleIDX', 'string[]'), new StateFieldSpec('tasksIDX', 'PointsTask[]'), new StateFieldSpec('rewardsIDX', 'PointsTask[]'),
     new StateFieldSpec('historyIDX', 'PointsEntry[]'), new StateFieldSpec('whoIDX', 'number'),
     new StateFieldSpec('draftNameIDX', 'string'), new StateFieldSpec('draftPointsIDX', 'number')],
    `  let peopleIDX: string[] = [__PEOPLE_IDX__];
  let tasksIDX: PointsTask[] = [
    __TASKS_IDX__
  ];
  let rewardsIDX: PointsTask[] = [
    __REWARDS_IDX__
  ];
  let historyIDX: PointsEntry[] = [];`,
    `peopleIDX: peopleIDX, tasksIDX: tasksIDX, rewardsIDX: rewardsIDX, historyIDX: historyIDX, whoIDX: 0, draftNameIDX: "", draftPointsIDX: 5`,
    `function withHistoryIDX(state: AppState, history: PointsEntry[]): AppState {
  return {peopleIDX: state.peopleIDX, tasksIDX: state.tasksIDX, rewardsIDX: state.rewardsIDX, historyIDX: history, whoIDX: state.whoIDX, draftNameIDX: state.draftNameIDX, draftPointsIDX: state.draftPointsIDX__PASSTHROUGH__};
}

function balanceOfIDX(state: AppState, who: number): number {
  let sum: number = 0;
  for (let e: PointsEntry of state.historyIDX) { if (e.who === who) { sum = sum + e.points; } }
  return sum;
}

function pointsIDX(state: AppState): number[] {
  let out: number[] = [];
  let i: number = 0;
  while (i < state.peopleIDX.length()) {
    out.push(balanceOfIDX(state, i));
    i = i + 1;
  }
  return out;
}

function pointsTotalIDX(state: AppState): number {
  let sum: number = 0;
  for (let e: PointsEntry of state.historyIDX) { sum = sum + e.points; }
  return sum;
}

function addEntryIDX(state: AppState, what: string, points: number): AppState {
  let out: PointsEntry[] = [];
  for (let e: PointsEntry of state.historyIDX) { out.push(e); }
  out.push({who: state.whoIDX, what: what, points: points, day: time.daysSinceEpoch(), minute: time.hourOfDay() * 60 + time.minuteOfHour()});
  return withHistoryIDX(state, out);
}

function setWhoIDX(state: AppState, index: number): AppState {
  return {peopleIDX: state.peopleIDX, tasksIDX: state.tasksIDX, rewardsIDX: state.rewardsIDX, historyIDX: state.historyIDX, whoIDX: index, draftNameIDX: state.draftNameIDX, draftPointsIDX: state.draftPointsIDX__PASSTHROUGH__};
}

function awardIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.tasksIDX.length()) { return state; }
  let t: PointsTask = state.tasksIDX[index];
  return addEntryIDX(state, t.name, t.points);
}

function redeemIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.rewardsIDX.length()) { return state; }
  let r: PointsTask = state.rewardsIDX[index];
  if (balanceOfIDX(state, state.whoIDX) < r.points) { return state; }
  return addEntryIDX(state, r.name, 0 - r.points);
}

function undoLastIDX(state: AppState, ignored: number): AppState {
  let out: PointsEntry[] = [];
  let i: number = 0;
  while (i < state.historyIDX.length() - 1) {
    out.push(state.historyIDX[i]);
    i = i + 1;
  }
  return withHistoryIDX(state, out);
}

function setNameIDX(state: AppState, value: string): AppState {
  return {peopleIDX: state.peopleIDX, tasksIDX: state.tasksIDX, rewardsIDX: state.rewardsIDX, historyIDX: state.historyIDX, whoIDX: state.whoIDX, draftNameIDX: value, draftPointsIDX: state.draftPointsIDX__PASSTHROUGH__};
}

function setPointsIDX(state: AppState, value: number): AppState {
  return {peopleIDX: state.peopleIDX, tasksIDX: state.tasksIDX, rewardsIDX: state.rewardsIDX, historyIDX: state.historyIDX, whoIDX: state.whoIDX, draftNameIDX: state.draftNameIDX, draftPointsIDX: value__PASSTHROUGH__};
}

function withAddedIDX(list: PointsTask[], name: string, points: number): PointsTask[] {
  let out: PointsTask[] = [];
  for (let t: PointsTask of list) { out.push(t); }
  out.push({name: name, points: points});
  return out;
}

function addTaskIDX(state: AppState, ignored: number): AppState {
  let name: string = strings.trim(state.draftNameIDX);
  if (name === "" || state.draftPointsIDX <= 0) { return state; }
  return {peopleIDX: state.peopleIDX, tasksIDX: withAddedIDX(state.tasksIDX, name, state.draftPointsIDX), rewardsIDX: state.rewardsIDX, historyIDX: state.historyIDX, whoIDX: state.whoIDX, draftNameIDX: "", draftPointsIDX: state.draftPointsIDX__PASSTHROUGH__};
}

function addRewardIDX(state: AppState, ignored: number): AppState {
  let name: string = strings.trim(state.draftNameIDX);
  if (name === "" || state.draftPointsIDX <= 0) { return state; }
  return {peopleIDX: state.peopleIDX, tasksIDX: state.tasksIDX, rewardsIDX: withAddedIDX(state.rewardsIDX, name, state.draftPointsIDX), historyIDX: state.historyIDX, whoIDX: state.whoIDX, draftNameIDX: "", draftPointsIDX: state.draftPointsIDX__PASSTHROUGH__};
}

function signedIDX(points: number): string {
  if (points > 0) { return "+" + ui.numberToString(points); }
  return ui.numberToString(points);
}`,
    `{
    let people: number = state.peopleIDX.length();
    let who: number = state.whoIDX;
    if (who < 0 || who >= people) { who = 0; }
    let whoName: string = "";
    if (people > 0) { whoName = state.peopleIDX[who]; }
    let balance: number = balanceOfIDX(state, who);
    let stats: ui.View[] = [];
    let i: number = 0;
    while (i < people && i < 4) {
      let tone: string = "default";
      if (i === who && people > 1) { tone = "accent"; }
      stats.push(ui.NumberStat(tone, state.peopleIDX[i], balanceOfIDX(state, i), "", " __UNIT_IDX__", 1, "", "star", 0));
      i = i + 1;
    }
    sections.push(ui.Section("summary", "", "", [ui.MetricGroup("default", 2, stats)]));
    let earn: ui.View[] = [];
    let t: number = 0;
    while (t < state.tasksIDX.length()) {
      let task: PointsTask = state.tasksIDX[t];
      earn.push(ui.ListItem("default", task.name, "", signedIDX(task.points), "awardIDX", t, true, "plus"));
      t = t + 1;
    }
    let spend: ui.View[] = [];
    let r: number = 0;
    while (r < state.rewardsIDX.length()) {
      let reward: PointsTask = state.rewardsIDX[r];
      let enough: boolean = balance >= reward.points;
      let note: string = "";
      if (!enough) { note = "needs " + ui.numberToString(reward.points - balance) + " more"; }
      let tone: string = "default";
      if (enough) { tone = "success"; }
      spend.push(ui.ListItem(tone, reward.name, note, ui.numberToString(reward.points), "redeemIDX", r, enough, "star"));
      r = r + 1;
    }
    let pickWho: boolean = people > 1;
    sections.push(ui.Section("content", "", "", [
      ui.When(pickWho, ui.Select("default", "Who", state.peopleIDX, who, "setWhoIDX")),
      ui.ListGroup("default", "__EARN_TITLE_IDX__", earn),
      ui.When(state.rewardsIDX.length() > 0, ui.ListGroup("default", "__SPEND_TITLE_IDX__", spend))
    ]));
    let n: number = state.historyIDX.length();
    let rows: ui.View[] = [];
    let k: number = n - 1;
    let shown: number = 0;
    while (k >= 0 && shown < 20) {
      let e: PointsEntry = state.historyIDX[k];
      let name: string = "?";
      if (e.who >= 0 && e.who < people) { name = state.peopleIDX[e.who]; }
      let tone: string = "default";
      if (e.points > 0) { tone = "success"; }
      let title: string = e.what;
      if (people > 1) { title = name + " · " + e.what; }
      rows.push(ui.ListItem(tone, title, ui.dateToString(e.day) + " " + ui.clockToString(e.minute), signedIDX(e.points), "", k, true, ""));
      k = k - 1;
      shown = shown + 1;
    }
    sections.push(ui.Section("content", "History", "", [
      ui.When(n === 0, ui.EmptyState("default", "No points yet", "Tap a task above when it is done.", "", "", "star")),
      ui.When(n > 0, ui.ListGroup("default", "", rows)),
      ui.ActionBar("end", [ui.Button("secondary", "Undo last", "undoLastIDX", 0, n > 0)])
    ]));
    let compactIDX: boolean = __WIDGET__;
    let typed: boolean = strings.trim(state.draftNameIDX) !== "";
    sections.push(ui.Section("supporting", "", "", [
      ui.When(!compactIDX, ui.TextField("default", "New task or reward", state.draftNameIDX, "setNameIDX")),
      ui.When(!compactIDX, ui.NumberField("default", "Points", state.draftPointsIDX, 1, 100, "setPointsIDX")),
      ui.When(!compactIDX, ui.ActionBar("end", [
        ui.Button("secondary", "Add reward", "addRewardIDX", 0, typed),
        ui.Button("primary", "Add task", "addTaskIDX", 0, typed)
      ]))
    ]));
  }`,
    [],
    [
      new ContentFieldSpec('__UNIT_IDX__', 'unit', 'pts', 'What the points are called, short and plural (stars, pts, coins)', 8),
      new ContentFieldSpec('__EARN_TITLE_IDX__', 'earn_title', 'Earn', 'Heading over the tasks that earn points (1-3 words)', 20),
      new ContentFieldSpec('__SPEND_TITLE_IDX__', 'spend_title', 'Spend', 'Heading over the rewards that cost points (1-3 words)', 20)
    ],
    ['import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [new ListFieldSpec('__PEOPLE_IDX__', 'people',
      'The people who earn points, by the names the request gives, else numbered stand-ins such as Kid 1, Kid 2 (1 to 4)',
      ['name (1-2 words)'], [16], '"{0}"', ', ', 1, 4, [['Kid 1'], ['Kid 2']]),
     new ListFieldSpec('__TASKS_IDX__', 'tasks',
      'Tasks that earn points, from the request or the usual ones for it (3 to 8), each with the points it earns',
      ['task (1-4 words)', 'points it earns, a whole number (1 to 20)'], [28, 3], '{name: "{0}", points: {1}}', ',\n    ', 1, 8,
      [['Make the bed', '1'], ['Tidy up toys', '2'], ['Homework done', '3']], [1]),
     new ListFieldSpec('__REWARDS_IDX__', 'rewards',
      'Rewards the points are spent on, from the request or the usual ones for it (2 to 6), each with what it costs; none when ' +
      'the request says the family agrees on them later',
      ['reward (1-4 words)', 'points it costs, a whole number (2 to 100)'], [28, 3], '{name: "{0}", points: {1}}', ',\n    ', 0, 6,
      [['Extra story', '5'], ['Ice cream', '10'], ['Movie night', '20']], [1])],
    [new PortSpec('writes', 'labels', 'string[]', 'peopleIDX'),
     new PortSpec('writes', 'totals', 'number[]', 'pointsIDX(state)', '', true),
     new PortSpec('writes', 'total', 'number', 'pointsTotalIDX(state)', '', true),
     new PortSpec('writes', 'count', 'number', 'state.historyIDX.length()', '', true)],
    [],
    ['needs_search_or_form', 'needs_multiple_counters', 'needs_logic']
  )
  spec.tab = 'Points'
  return spec
}

/**
 * The palette VeraSectionCompose.ets picks from, one per section slot. `checklist`/`metrics`
 * reproduce today's two flat templates exactly (as single-fragment compositions); `timer` and
 * `calendar_event` are the first capability-bound kinds, see the plan's rationale for why these
 * two specifically are safe to hardcode and navigation is not. `actions`/`progress_goal`/
 * `key_facts`/`note`/`rating`/`spotlight` round out the generic, SDK-free side of the palette.
 */
/**
 * Ideas to pick one from right now: one featured at a time with Another and Done, filtered by how long it takes and by its level,
 * the rest of the matching ideas under it. Written for the request, like a checklist's items, but nothing is ticked off a list:
 * the person wants one thing to do (Wind down: a checklist of eight ideas read "0 of 8 done - tap one to tick it").
 */
function ideaDeckFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'idea_deck',
    'Ideas or suggestions to pick ONE from right now -- something to do in bed, a dinner to cook, a game for the kids, a date idea, ' +
    'a break activity -- shown one at a time with Another and Done, filtered by how long each takes and by its level (energy, effort). ' +
    'Not a to-do list or shopping list to tick off (that is checklist), not facts to read (key_facts), not a plan of the day in time order. ' +
    'The ideas are written once, when the app is made: not for suggestions worked out from what the person enters later (dinners from ' +
    'the food in their pantry, questions from their notes)',
    `@jsonable
class Idea {
  title: string;
  minutes: number;
  level: string;
  how: string;
  doneDay: number;
}`,
    [new StateFieldSpec('ideasIDX', 'Idea[]'), new StateFieldSpec('atIDX', 'number'), new StateFieldSpec('timeIDX', 'number'),
     new StateFieldSpec('levelIDX', 'number')],
    `  let ideasIDX: Idea[] = [
    __IDEAS_IDX__
  ];`,
    `ideasIDX: ideasIDX, atIDX: 0, timeIDX: 0, levelIDX: 0`,
    `function rebuildIdeasIDX(state: AppState, ideas: Idea[], at: number, timePick: number, levelPick: number): AppState {
  return {ideasIDX: ideas, atIDX: at, timeIDX: timePick, levelIDX: levelPick__PASSTHROUGH__};
}

function levelsIDX(state: AppState): string[] {
  let out: string[] = [];
  for (let it: Idea of state.ideasIDX) {
    let seen: boolean = false;
    for (let l: string of out) { if (l === it.level) { seen = true; } }
    if (!seen && it.level.length() > 0) { out.push(it.level); }
  }
  return out;
}

function timeLimitIDX(pick: number): number {
  if (pick === 1) { return 5; }
  if (pick === 2) { return 15; }
  if (pick === 3) { return 30; }
  return 100000;
}

function fitsIDX(state: AppState, timePick: number, levelPick: number, index: number): boolean {
  if (index < 0 || index >= state.ideasIDX.length()) { return false; }
  let it: Idea = state.ideasIDX[index];
  if (it.minutes > timeLimitIDX(timePick)) { return false; }
  let levels: string[] = levelsIDX(state);
  if (levelPick > 0 && levelPick <= levels.length()) {
    if (it.level !== levels[levelPick - 1]) { return false; }
  }
  return true;
}

function nextFitIDX(state: AppState, timePick: number, levelPick: number, startAt: number): number {
  let n: number = state.ideasIDX.length();
  if (n === 0) { return -1; }
  let start: number = startAt;
  if (start < 0) { start = 0; }
  let k: number = 0;
  while (k < n) {
    let i: number = (start + k) % n;
    if (fitsIDX(state, timePick, levelPick, i)) { return i; }
    k = k + 1;
  }
  return -1;
}

function doneTodayIDX(state: AppState): number {
  let today: number = time.daysSinceEpoch();
  let n: number = 0;
  for (let it: Idea of state.ideasIDX) { if (it.doneDay === today) { n = n + 1; } }
  return n;
}

function anotherIdeaIDX(state: AppState, ignored: number): AppState {
  let next: number = nextFitIDX(state, state.timeIDX, state.levelIDX, state.atIDX + 1);
  return rebuildIdeasIDX(state, state.ideasIDX, next, state.timeIDX, state.levelIDX);
}

function doneIdeaIDX(state: AppState, ignored: number): AppState {
  if (!fitsIDX(state, state.timeIDX, state.levelIDX, state.atIDX)) { return state; }
  let today: number = time.daysSinceEpoch();
  let out: Idea[] = [];
  let i: number = 0;
  while (i < state.ideasIDX.length()) {
    let it: Idea = state.ideasIDX[i];
    if (i === state.atIDX) {
      out.push({title: it.title, minutes: it.minutes, level: it.level, how: it.how, doneDay: today});
    } else {
      out.push(it);
    }
    i = i + 1;
  }
  let marked: AppState = rebuildIdeasIDX(state, out, state.atIDX, state.timeIDX, state.levelIDX);
  let n: number = out.length();
  let k: number = 1;
  while (k < n) {
    let j: number = (state.atIDX + k) % n;
    if (fitsIDX(marked, state.timeIDX, state.levelIDX, j) && out[j].doneDay !== today) {
      return rebuildIdeasIDX(state, out, j, state.timeIDX, state.levelIDX);
    }
    k = k + 1;
  }
  return rebuildIdeasIDX(state, out, nextFitIDX(marked, state.timeIDX, state.levelIDX, state.atIDX + 1), state.timeIDX, state.levelIDX);
}

function pickIdeaIDX(state: AppState, index: number): AppState {
  if (index < 0 || index >= state.ideasIDX.length()) { return state; }
  return rebuildIdeasIDX(state, state.ideasIDX, index, state.timeIDX, state.levelIDX);
}

function setIdeaTimeIDX(state: AppState, index: number): AppState {
  let at: number = state.atIDX;
  if (!fitsIDX(state, index, state.levelIDX, at)) { at = nextFitIDX(state, index, state.levelIDX, 0); }
  return rebuildIdeasIDX(state, state.ideasIDX, at, index, state.levelIDX);
}

function setIdeaLevelIDX(state: AppState, index: number): AppState {
  let at: number = state.atIDX;
  if (!fitsIDX(state, state.timeIDX, index, at)) { at = nextFitIDX(state, state.timeIDX, index, 0); }
  return rebuildIdeasIDX(state, state.ideasIDX, at, state.timeIDX, index);
}`,
    `{
    let today: number = time.daysSinceEpoch();
    let levels: string[] = levelsIDX(state);
    let levelNames: string[] = ["Any"];
    for (let l: string of levels) { levelNames.push(l); }
    let at: number = state.atIDX;
    if (!fitsIDX(state, state.timeIDX, state.levelIDX, at)) { at = nextFitIDX(state, state.timeIDX, state.levelIDX, 0); }
    if (at >= 0) {
      let it: Idea = state.ideasIDX[at];
      let meta: string = ui.numberToString(it.minutes) + " min";
      if (it.level.length() > 0) { meta = meta + " · " + it.level; }
      if (it.doneDay === today) { meta = meta + " · done today"; }
      let featured: ui.View[] = [];
      featured.push(ui.Text("caption", "__DECK_LABEL_IDX__"));
      featured.push(ui.Text("title", it.title));
      featured.push(ui.Text("muted", meta));
      if (it.how.length() > 0) { featured.push(ui.Text("body", it.how)); }
      featured.push(ui.ActionBar("end", [
        ui.Button("secondary", "Another", "anotherIdeaIDX", 0, true),
        ui.Button("primary", "Done", "doneIdeaIDX", 0, it.doneDay !== today)
      ]));
      sections.push(ui.Section("hero", "", "", [ui.Card("accent", featured)]));
    } else {
      sections.push(ui.Section("content", "", "", [
        ui.EmptyState("default", "Nothing fits", "Try any time or any level.", "", "", "info")
      ]));
    }
    let filters: ui.View[] = [
      ui.Select("default", "Time", ["Any time", "Up to 5 min", "Up to 15 min", "Up to 30 min"], state.timeIDX, "setIdeaTimeIDX")
    ];
    if (levels.length() > 1) {
      filters.push(ui.Select("default", "__LEVEL_LABEL_IDX__", levelNames, state.levelIDX, "setIdeaLevelIDX"));
    }
    sections.push(ui.Section("content", "", "", filters));
    let rows: ui.View[] = [];
    let i: number = 0;
    while (i < state.ideasIDX.length()) {
      if (i !== at && fitsIDX(state, state.timeIDX, state.levelIDX, i)) {
        let it2: Idea = state.ideasIDX[i];
        let sub: string = ui.numberToString(it2.minutes) + " min";
        if (it2.level.length() > 0) { sub = sub + " · " + it2.level; }
        let icon: string = "";
        if (it2.doneDay === today) { icon = "check"; }
        rows.push(ui.ListItem("default", it2.title, sub, "", "pickIdeaIDX", i, true, icon));
      }
      i = i + 1;
    }
    let done: number = doneTodayIDX(state);
    let doneLine: string = "";
    if (done > 0) { doneLine = ui.numberToString(done) + " done today"; }
    if (rows.length() > 0) {
      sections.push(ui.Section("content", "More ideas", doneLine, [ui.ListGroup("default", "", rows)]));
    } else {
      if (done > 0) { sections.push(ui.Section("supporting", "", "", [ui.Text("muted", doneLine)])); }
    }
  }`,
    [],
    [new ContentFieldSpec('__DECK_LABEL_IDX__', 'deck_label', 'Try this', 'Short line over the featured idea (1-3 words, such as Try this now)', 24),
     new ContentFieldSpec('__LEVEL_LABEL_IDX__', 'level_label', 'Level', 'What the level of an idea measures (1-2 words, such as Energy or Effort)', 16)],
    ['import * as time from "std/time"'],
    [new ListFieldSpec('__IDEAS_IDX__', 'ideas',
      'The ideas to pick from (6 to 12), fitting the request: each with a short title, how many minutes it takes, its level in one ' +
      'lower-case word used the same way across the ideas (low, medium, high energy; or easy, medium, hard), and one line on how to do it',
      ['title of the idea (2-5 words)', 'minutes it takes, a whole number', 'level, one lower-case word', 'how to do it, one short line'],
      [32, 4, 12, 90],
      '{title: "{0}", minutes: {1}, level: "{2}", how: "{3}", doneDay: -1}', ',\n    ', 6, 12,
      [['Read a few pages', '10', 'low', 'Pick a light book and stop at the end of a chapter.'],
       ['Slow breathing', '3', 'low', 'Breathe in for four, out for six, ten times.'],
       ['Stretch your neck', '5', 'low', 'Roll your shoulders, then tilt your head side to side.'],
       ['Tidy one drawer', '15', 'medium', 'Empty it, keep what you use, put the rest away.'],
       ['Write a short list', '5', 'low', 'Three things to do tomorrow, nothing more.'],
       ['Short walk', '20', 'high', 'Round the block at an easy pace.']],
      [1])],
    [new PortSpec('writes', 'done_today', 'number', 'doneTodayIDX(state)', '', true)]
  )
  spec.tab = 'Ideas'
  return spec
}

/**
 * Work and rest in cycles: a focus block, a break, the next round, until the rounds are done. Ticks the way `timer` does (a
 * ui.Ticker of one second handing the elapsed milliseconds to onTick), moves on from one phase to the next by itself and
 * vibrates at each change when the slot says so. The lengths and the number of rounds come from the request and stay settable
 * at the foot of the section. Not a single countdown: that is `timer`.
 */
function intervalTimerFragment(): FragmentSpec {
  let signal: Map<string, string> = new Map<string, string>()
  signal.set('true', 'yes, the phone vibrates briefly when a block or a break ends')
  signal.set('false', 'no, the change only shows on the screen')
  let spec = new FragmentSpec(
    'interval_timer',
    'Work and rest in cycles that run on by themselves: pomodoro, homework split into focus blocks with breaks between, interval ' +
    'training (work 30 seconds, rest 10, eight rounds); shows the time left in the block, which block it is and the round, and moves ' +
    'from focus to break to the next round on its own. Not a single countdown or stopwatch (that is timer)',
    '',
    [new StateFieldSpec('workSecIDX', 'number'), new StateFieldSpec('restSecIDX', 'number'), new StateFieldSpec('roundsIDX', 'number'),
     new StateFieldSpec('roundIDX', 'number'), new StateFieldSpec('phaseIDX', 'number'), new StateFieldSpec('phaseMsIDX', 'number'),
     new StateFieldSpec('runningIDX', 'boolean'), new StateFieldSpec('focusMsIDX', 'number'), new StateFieldSpec('inSecondsIDX', 'boolean')],
    `  let workSecIDX: number = __WORK_SECONDS_IDX__;
  if (workSecIDX < 5 || workSecIDX > 14400) { workSecIDX = 1500; }
  let restSecIDX: number = __REST_SECONDS_IDX__;
  if (restSecIDX < 0 || restSecIDX > 7200) { restSecIDX = 300; }
  let roundsIDX: number = __ROUNDS_IDX__;
  if (roundsIDX < 1 || roundsIDX > 50) { roundsIDX = 4; }
  let inSecondsIDX: boolean = workSecIDX < 120;`,
    `workSecIDX: workSecIDX, restSecIDX: restSecIDX, roundsIDX: roundsIDX, roundIDX: 1, phaseIDX: 0, phaseMsIDX: 0, runningIDX: false, focusMsIDX: 0, inSecondsIDX: inSecondsIDX`,
    `function rebuildCycleIDX(state: AppState, round: number, phase: number, phaseMs: number, running: boolean, focusMs: number): AppState {
  return {workSecIDX: state.workSecIDX, restSecIDX: state.restSecIDX, roundsIDX: state.roundsIDX, roundIDX: round, phaseIDX: phase, phaseMsIDX: phaseMs, runningIDX: running, focusMsIDX: focusMs, inSecondsIDX: state.inSecondsIDX__PASSTHROUGH__};
}

function phaseLimitMsIDX(state: AppState, phase: number): number {
  if (phase === 0) { return state.workSecIDX * 1000; }
  if (phase === 1) { return state.restSecIDX * 1000; }
  return 0;
}

function signalIDX(): number {
  if (__SIGNAL_IDX__) { sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "800"], "onSignalAnsweredIDX"); }
  return 0;
}

function onSignalAnsweredIDX(state: AppState, value: string): AppState {
  return state;
}

function nextPhaseIDX(state: AppState, focusMs: number, running: boolean): AppState {
  if (state.phaseIDX === 0) {
    if (state.roundIDX >= state.roundsIDX) { return rebuildCycleIDX(state, state.roundIDX, 2, 0, false, focusMs); }
    if (state.restSecIDX <= 0) { return rebuildCycleIDX(state, state.roundIDX + 1, 0, 0, running, focusMs); }
    return rebuildCycleIDX(state, state.roundIDX, 1, 0, running, focusMs);
  }
  if (state.phaseIDX === 1) { return rebuildCycleIDX(state, state.roundIDX + 1, 0, 0, running, focusMs); }
  return state;
}

function onCycleTickIDX(state: AppState, elapsedMs: number): AppState {
  if (!state.runningIDX || state.phaseIDX === 2) { return state; }
  let limit: number = phaseLimitMsIDX(state, state.phaseIDX);
  let next: number = state.phaseMsIDX + elapsedMs;
  let focus: number = state.focusMsIDX;
  if (next >= limit) {
    if (state.phaseIDX === 0) { focus = focus + (limit - state.phaseMsIDX); }
    let ignored: number = signalIDX();
    return nextPhaseIDX(state, focus, true);
  }
  if (state.phaseIDX === 0) { focus = focus + elapsedMs; }
  return rebuildCycleIDX(state, state.roundIDX, state.phaseIDX, next, true, focus);
}

function toggleCycleIDX(state: AppState, ignored: number): AppState {
  if (state.phaseIDX === 2) { return rebuildCycleIDX(state, 1, 0, 0, true, 0); }
  return rebuildCycleIDX(state, state.roundIDX, state.phaseIDX, state.phaseMsIDX, !state.runningIDX, state.focusMsIDX);
}

function skipPhaseIDX(state: AppState, ignored: number): AppState {
  if (state.phaseIDX === 2) { return state; }
  return nextPhaseIDX(state, state.focusMsIDX, state.runningIDX);
}

function resetCycleIDX(state: AppState, ignored: number): AppState {
  return rebuildCycleIDX(state, 1, 0, 0, false, 0);
}

function setWorkIDX(state: AppState, value: number): AppState {
  let seconds: number = value * 60;
  if (state.inSecondsIDX) { seconds = value; }
  if (seconds < 5) { seconds = 5; }
  return {workSecIDX: seconds, phaseMsIDX: 0__PASSTHROUGH__};
}

function setRestIDX(state: AppState, value: number): AppState {
  let seconds: number = value * 60;
  if (state.inSecondsIDX) { seconds = value; }
  if (seconds < 0) { seconds = 0; }
  return {restSecIDX: seconds, phaseMsIDX: 0__PASSTHROUGH__};
}

function setRoundsIDX(state: AppState, value: number): AppState {
  let rounds: number = value;
  if (rounds < 1) { rounds = 1; }
  let round: number = state.roundIDX;
  if (round > rounds) { round = rounds; }
  return {roundsIDX: rounds, roundIDX: round__PASSTHROUGH__};
}

function focusSecondsIDX(state: AppState): number {
  return math.floor(state.focusMsIDX / 1000);
}`,
    `{
    let phase: number = state.phaseIDX;
    let limitSec: number = phaseLimitMsIDX(state, phase) / 1000;
    let leftSec: number = math.ceil(limitSec - state.phaseMsIDX / 1000);
    if (leftSec < 0) { leftSec = 0; }
    let clock: ui.View[] = [];
    clock.push(ui.Ticker("default", "cycleIDX", 1000, state.runningIDX && phase !== 2, "onCycleTickIDX"));
    if (phase === 2) {
      clock.push(ui.Badge("success", "All rounds done", "check"));
      clock.push(ui.Text("display", ui.durationToString(focusSecondsIDX(state))));
      clock.push(ui.Text("muted", "__WORK_LABEL_IDX__ time over " + ui.numberToString(state.roundsIDX) + " rounds"));
    } else {
      let label: string = "__WORK_LABEL_IDX__";
      let tone: string = "accent";
      if (phase === 1) { label = "__REST_LABEL_IDX__"; tone = "success"; }
      clock.push(ui.Badge(tone, label, "clock"));
      clock.push(ui.Text("display", ui.durationToString(leftSec)));
      clock.push(ui.Progress(tone, "Round " + ui.numberToString(state.roundIDX) + " of " + ui.numberToString(state.roundsIDX), state.phaseMsIDX / 1000, limitSec));
    }
    sections.push(ui.Section("hero", "", "", clock));
    let startText: string = "Start";
    if (state.runningIDX) { startText = "Pause"; }
    if (!state.runningIDX && phase !== 2 && (state.phaseMsIDX > 0 || state.roundIDX > 1 || phase === 1)) { startText = "Resume"; }
    if (phase === 2) { startText = "Start again"; }
    sections.push(ui.Section("content", "", "", [ui.ActionBar("spread", [
      ui.Button("secondary", "Reset", "resetCycleIDX", 0, state.phaseMsIDX > 0 || state.roundIDX > 1 || phase !== 0),
      ui.Button("secondary", "Skip", "skipPhaseIDX", 0, phase !== 2),
      ui.Button("primary", startText, "toggleCycleIDX", 0, true)
    ])]));
    let unit: string = "minutes";
    let workShown: number = math.round(state.workSecIDX / 60);
    let restShown: number = math.round(state.restSecIDX / 60);
    if (state.inSecondsIDX) { unit = "seconds"; workShown = state.workSecIDX; restShown = state.restSecIDX; }
    sections.push(ui.Section("supporting", "", "", [
      ui.NumberField("default", "__WORK_LABEL_IDX__ (" + unit + ")", workShown, 1, 240, "setWorkIDX"),
      ui.NumberField("default", "__REST_LABEL_IDX__ (" + unit + ")", restShown, 0, 120, "setRestIDX"),
      ui.NumberField("default", "Rounds", state.roundsIDX, 1, 50, "setRoundsIDX")
    ]));
  }`,
    [new SlotSpec('__SIGNAL_IDX__', ['true', 'false'], 'choice',
      'Should the phone vibrate when a focus block or a break ends?', signal)],
    [new ContentFieldSpec('__WORK_SECONDS_IDX__', 'work_seconds', '1500', 'Length of one focus or work block in seconds, a whole number (15 minutes is 900)', 6, true),
     new ContentFieldSpec('__REST_SECONDS_IDX__', 'rest_seconds', '300', 'Length of one break or rest in seconds, a whole number (5 minutes is 300; 0 for none)', 6, true),
     new ContentFieldSpec('__ROUNDS_IDX__', 'rounds', '4', 'How many rounds of work and rest, a whole number (1 to 50)', 3, true),
     new ContentFieldSpec('__WORK_LABEL_IDX__', 'work_label', 'Focus', 'Name of the work block (one word, such as Focus, Work or Run)', 12),
     new ContentFieldSpec('__REST_LABEL_IDX__', 'rest_label', 'Break', 'Name of the rest block (one word, such as Break or Rest)', 12)],
    ['import * as sdk from "std/sdk"', 'import * as math from "std/math"'],
    [],
    [new PortSpec('writes', 'round', 'number', 'state.roundIDX', '', true),
     new PortSpec('writes', 'focus_seconds_done', 'number', 'focusSecondsIDX(state)', '', true)]
  )
  spec.tab = 'Timer'
  return spec
}

/**
 * Readings taken now and again, each read against bands written for the request: the latest is shown large with what it means and
 * what to do, the readings make a line, and the list keeps them newest first. A reading the request itself gives ("a fever of
 * 37.5") is the first one, so the status shows at once (Baby fever: "No reading yet" under a request that gave it).
 */
function readingStatusFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    'reading_status',
    'A measurement the person takes now and again -- a baby\'s temperature, blood pressure, blood sugar, weight, a pulse -- each ' +
    'added with its time, the latest shown large with what it means (normal, watch, see a doctor) and what to do, from bands written ' +
    'for the request, and a line of the readings over time. Not money or expenses (record_log), not counting taps or glasses, not a ' +
    'reminder list',
    `@jsonable
class Reading {
  value: number;
  minute: number;
  day: number;
  note: string;
}

@jsonable
class Band {
  upTo: number;
  label: string;
  tone: string;
  advice: string;
}`,
    [new StateFieldSpec('readingsIDX', 'Reading[]'), new StateFieldSpec('bandsIDX', 'Band[]'),
     new StateFieldSpec('draftIDX', 'string'), new StateFieldSpec('draftNoteIDX', 'string')],
    `  let bandsIDX: Band[] = [
    __BANDS_IDX__
  ];
  let readingsIDX: Reading[] = [];
  let firstIDX: number = strings.toNumber("__FIRST_READING_IDX__", -999999);
  if (firstIDX > -999999) {
    readingsIDX.push({value: firstIDX, minute: time.hourOfDay() * 60 + time.minuteOfHour(), day: time.daysSinceEpoch(), note: ""});
  }`,
    `readingsIDX: readingsIDX, bandsIDX: bandsIDX, draftIDX: "", draftNoteIDX: ""`,
    `function setReadingDraftIDX(state: AppState, value: string): AppState {
  return {draftIDX: value__PASSTHROUGH__};
}

function setReadingNoteIDX(state: AppState, value: string): AppState {
  return {draftNoteIDX: value__PASSTHROUGH__};
}

function addReadingIDX(state: AppState, ignored: number): AppState {
  let value: number = strings.toNumber(strings.trim(state.draftIDX), -999999);
  if (value <= -999999) { return state; }
  let out: Reading[] = [];
  for (let r: Reading of state.readingsIDX) { out.push(r); }
  out.push({value: value, minute: time.hourOfDay() * 60 + time.minuteOfHour(), day: time.daysSinceEpoch(), note: strings.trim(state.draftNoteIDX)});
  return {readingsIDX: out, draftIDX: "", draftNoteIDX: ""__PASSTHROUGH__};
}

function removeReadingIDX(state: AppState, index: number): AppState {
  let out: Reading[] = [];
  let i: number = 0;
  while (i < state.readingsIDX.length()) {
    if (i !== index) { out.push(state.readingsIDX[i]); }
    i = i + 1;
  }
  return {readingsIDX: out__PASSTHROUGH__};
}

function bandAtIDX(state: AppState, value: number): number {
  let n: number = state.bandsIDX.length();
  if (n === 0) { return -1; }
  let i: number = 0;
  while (i < n - 1) {
    if (value < state.bandsIDX[i].upTo) { return i; }
    i = i + 1;
  }
  return n - 1;
}

function toneOfIDX(tone: string): string {
  if (tone === "success" || tone === "warning" || tone === "danger") { return tone; }
  return "default";
}

function latestIDX(state: AppState): number {
  let n: number = state.readingsIDX.length();
  if (n === 0) { return 0; }
  return state.readingsIDX[n - 1].value;
}

function statusLevelIDX(state: AppState): number {
  let n: number = state.readingsIDX.length();
  if (n === 0) { return 0; }
  let b: number = bandAtIDX(state, state.readingsIDX[n - 1].value);
  if (b < 0) { return 0; }
  let tone: string = state.bandsIDX[b].tone;
  if (tone === "danger") { return 2; }
  if (tone === "warning") { return 1; }
  return 0;
}

function readingTextIDX(value: number): string {
  return ui.formatNumber(value, __DECIMALS_IDX__) + "__UNIT_SUFFIX_IDX__";
}`,
    `{
    let n: number = state.readingsIDX.length();
    let today: number = time.daysSinceEpoch();
    if (n > 0) {
      let last: Reading = state.readingsIDX[n - 1];
      let b: number = bandAtIDX(state, last.value);
      let card: ui.View[] = [ui.Text("caption", "__READING_LABEL_IDX__ at " + ui.clockToString(last.minute))];
      card.push(ui.Text("display", readingTextIDX(last.value)));
      let cardTone: string = "surface";
      if (b >= 0) {
        let band: Band = state.bandsIDX[b];
        let tone: string = toneOfIDX(band.tone);
        if (tone !== "default") { cardTone = tone; }
        card.push(ui.Badge(tone, band.label, ""));
        if (band.advice.length() > 0) { card.push(ui.Text("body", band.advice)); }
      }
      sections.push(ui.Section("hero", "", "", [ui.Card(cardTone, card)]));
    }
    let typed: number = strings.toNumber(strings.trim(state.draftIDX), -999999);
    sections.push(ui.Section("content", "Add a reading", "", [
      ui.TextField("default", "__READING_LABEL_IDX__ (__UNIT_IDX__)", state.draftIDX, "setReadingDraftIDX", "number"),
      ui.TextField("default", "Note", state.draftNoteIDX, "setReadingNoteIDX"),
      ui.ActionBar("end", [ui.Button("primary", "Add", "addReadingIDX", 0, typed > -999999)])
    ]));
    if (n >= 2) {
      let series: number[] = [];
      let times: string[] = [];
      let start: number = 0;
      if (n > 24) { start = n - 24; }
      let i: number = start;
      let top: number = state.readingsIDX[start].value;
      let bottom: number = top;
      while (i < n) {
        let r: Reading = state.readingsIDX[i];
        series.push(r.value);
        times.push(ui.clockToString(r.minute));
        if (r.value > top) { top = r.value; }
        if (r.value < bottom) { bottom = r.value; }
        i = i + 1;
      }
      let span: number = top - bottom;
      if (span < 1) { span = 1; }
      sections.push(ui.Section("content", "", "", [
        ui.Sparkline("accent", series, top + span / 4, "__READING_LABEL_IDX__", false, [], "default", "", "", times, bottom - span / 4)
      ]));
    }
    let rows: ui.View[] = [];
    let k: number = n - 1;
    while (k >= 0) {
      let r2: Reading = state.readingsIDX[k];
      let b2: number = bandAtIDX(state, r2.value);
      let label: string = "";
      let tone2: string = "default";
      if (b2 >= 0) { label = state.bandsIDX[b2].label; tone2 = toneOfIDX(state.bandsIDX[b2].tone); }
      let when: string = ui.clockToString(r2.minute);
      if (r2.day !== today) { when = ui.dateToString(r2.day) + " " + when; }
      if (r2.note.length() > 0) { when = when + " · " + r2.note; }
      rows.push(ui.ListItem(tone2, readingTextIDX(r2.value), when, label, "", k, true, ""));
      rows.push(ui.ActionBar("end", [ui.IconButton("quiet", "trash", "Remove this reading", "removeReadingIDX", k, true)]));
      k = k - 1;
    }
    let guide: ui.View[] = [];
    let j: number = 0;
    let nb: number = state.bandsIDX.length();
    while (j < nb) {
      let band2: Band = state.bandsIDX[j];
      let range: string = "Under " + readingTextIDX(band2.upTo);
      if (j === nb - 1) {
        range = "Any";
        if (j > 0) { range = readingTextIDX(state.bandsIDX[j - 1].upTo) + " or more"; }
      } else {
        if (j > 0) { range = readingTextIDX(state.bandsIDX[j - 1].upTo) + " to " + readingTextIDX(band2.upTo); }
      }
      guide.push(ui.ListItem(toneOfIDX(band2.tone), band2.label, band2.advice, range, "", j, true, ""));
      j = j + 1;
    }
    if (n > 0) {
      sections.push(ui.Section("content", "Readings", "Newest first", [ui.ListGroup("default", "", rows)]));
    } else {
      sections.push(ui.Section("content", "", "", [ui.Text("muted", "Add a reading to see what it means.")]));
    }
    if (nb > 0) { sections.push(ui.Section("supporting", "What the numbers mean", "", [ui.ListGroup("compact", "", guide)])); }
  }`,
    [],
    [new ContentFieldSpec('__READING_LABEL_IDX__', 'reading_label', 'Reading', 'What is measured (1-2 words, such as Temperature or Weight)', 20),
     new ContentFieldSpec('__UNIT_IDX__', 'unit', 'units', 'Its unit as the request writes it (such as °C, kg, mmol/L, bpm)', 10),
     new ContentFieldSpec('__UNIT_SUFFIX_IDX__', 'unit_suffix', '', 'The same unit as it follows a number, starting with a space (" °C", " kg", " bpm")', 10),
     new ContentFieldSpec('__DECIMALS_IDX__', 'decimals', '1', 'Digits after the point a reading is shown with, 0 to 2 (a temperature 1, a weight 1, a pulse 0)', 1, true),
     new ContentFieldSpec('__FIRST_READING_IDX__', 'first_reading', '', 'The reading the request itself states (such as 37.5), as a plain number, or an empty string when it states none', 10)],
    ['import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [new ListFieldSpec('__BANDS_IDX__', 'bands',
      'What a reading means, as 2 to 4 bands from low to high: for each, the number it stays under (the last band has no upper bound: give 0), ' +
      'a short label, a tone (success for fine, warning for watch it, danger for act now) and one line on what to do. Use the thresholds ' +
      'a doctor or the request would give; include a band for low values only when low values matter',
      ['upper bound, a plain number (0 for the last band)', 'label (1-3 words)', 'tone: success, warning or danger', 'what to do, one short line'],
      [8, 24, 8, 90],
      '{upTo: {0}, label: "{1}", tone: "{2}", advice: "{3}"}', ',\n    ', 2, 4,
      [['38', 'Normal', 'success', 'Keep an eye on it.'], ['39', 'Fever', 'warning', 'Fluids, light clothes, check again in an hour.'],
       ['0', 'High fever', 'danger', 'Call a doctor.']],
      [], ['number', '', '', ''])],
    [new PortSpec('writes', 'latest', 'number', 'latestIDX(state)', '', true),
     new PortSpec('writes', 'status_level', 'number', 'statusLevelIDX(state)', '', true),
     new PortSpec('writes', 'count', 'number', 'state.readingsIDX.length()', '', true)]
  )
  spec.tab = 'Readings'
  return spec
}

/**
 * What each section already shows and the buttons it already has, for a section the model writes beside it (VeraCompose.ets's
 * partsContract) and for the question whether something left to write is already on the screen. Without it a written section
 * drew a second "Start over" and "Remove last" under record_log's, a second list of the same ideas under a checklist, and a
 * second "paid so far" beside the breakdown table (Shared costs, Wind down).
 */
const SECTION_OWNS: Map<string, string> = new Map<string, string>([
  ['checklist', 'its list of items with how many are done, each ticked by a tap'],
  ['metrics', 'a few summary numbers and its two buttons'],
  ['timer', 'the countdown or stopwatch with its time left, its Start/Pause and Reset buttons, its presets and what happens when it ends'],
  ['calendar_event', 'one event with its Add to calendar button and the calendar\'s answer'],
  ['actions', 'its row of quick buttons and which was tapped last'],
  ['progress_goal', 'the progress bar toward the goal, the goal itself, its Add progress and Reset buttons'],
  ['key_facts', 'its labelled facts'],
  ['trend_chart', 'the line chart of the series'],
  ['note', 'the note the person types'],
  ['rating', 'the 1 to 10 slider and its readout'],
  ['spotlight', 'its highlighted callout'],
  ['search_list', 'its list of items and the box that narrows it'],
  ['record_log', 'the form that adds a record (who or what category, the amount, a note) with its Add button, the list of records newest ' +
    'first with Remove on each, a Remove last button and a Start over button that clears them all, and an empty state while there are none'],
  ['number_strip', 'the total of the records, the average or equal share and how many records there are'],
  ['breakdown_table', 'one row per person or category with the total each has put in and how far each is above or below the average (the balance)'],
  ['series_chart', 'the bar chart of each person\'s or category\'s total'],
  ['settle_up', 'who pays whom how much to settle up, or that everyone is even'],
  ['progress_line', 'how many of the list\'s items are done, as a line and a bar'],
  ['list_summary', 'how many items are done, how many there are and how many are left'],
  ['data_table', 'its table of rows and three columns'],
  ['timeline', 'its steps in time order, each with its time'],
  ['bar_chart', 'its bar chart of the categories'],
  ['quick_log', 'the one-tap button, today\'s total toward the goal, today\'s count, how long since the last one, today\'s entries with an Undo'],
  ['dose_schedule', 'the doses with a Take button on each, how many are taken today, which are late and the streak of days with every dose taken'],
  ['due_items', 'its things each with the day it is due, soonest first, each saying how many days are left or how long ago it expired, ' +
    'how many are expired and how many are due soon, its form to add one (name, date, how often it comes round), a Done button on ' +
    'those that come round again, Remove on each, and the setting for how many days count as soon'],
  ['points_ledger', 'each person\'s points balance, the tasks that earn points and the rewards that cost them (each a tap), what a ' +
    'reward still needs, the history of points earned and spent with an Undo last button, and its form to add a task or a reward'],
  ['idea_deck', 'one idea featured at a time with its Another and Done buttons, filters by time and level, the other matching ideas ' +
    'and how many were done today'],
  ['interval_timer', 'the time left in the focus block or break, which block it is, the round of how many, its Start/Pause, Skip and ' +
    'Reset buttons, the lengths and number of rounds as settings, and the focus time when all rounds are done'],
  ['reading_status', 'the form that adds a reading with its Add button, the latest reading large with what it means and what to do, a ' +
    'line chart of the readings, the readings newest first with a remove button on each, and what each range of numbers means']
])

/** The section that fetches figures of the real world as they are now (liveFigureFragment). */
export const LIVE_KIND: string = 'live_figure'

/** The live section's figure number `k` (1 to 3) as a number, for a formula or another section: 0 until it has an answer. */
export function liveFigureNumber(k: number): string { return 'liveNumber(state.liveFigure' + k.toString() + ')' }

/**
 * Up to three figures of the real world as they are now (a price, a rate, the weather), with where and when they were read. The
 * call is written by the host, never the model (LiveBlock.ets): a public JSON API found and fetched at generation
 * (Vera.Source.fetch, one GET, which the home-screen card can make too), or, with none, a web search read on each refresh
 * (Vera.Live.fetch). Both answer the same lines, so one handler reads either:
 *
 *   ok / error: <reason>, <figure 1>, <figure 2>, <figure 3>, source<TAB>domain<TAB>address, asof<TAB>time
 *
 * It starts empty (a placeholder box) and fetches a second after the screen opens: no figure on it was written by a model. The
 * first figure is the screen's own, a tile across the whole width, with how it moved since the last answer; the others are tiles
 * in pairs below it. Where it is from and when is behind the info button, not on the screen. A failure keeps the figures shown and
 * says why. One per screen, so its names are its own (not indexed): the plan's formulas read its figures through its
 * ports by the same names wherever it is on the screen.
 */
/** A fixed section for a camera need: the live preview and its shutter, with the photos it captured under it. */
export function cameraCaptureFragment(): FragmentSpec {
  return new FragmentSpec(
    'camera_capture',
    'A live camera preview inside the app with a shutter that captures a photo and keeps it',
    '',
    [new StateFieldSpec('photosIDX', 'string[]')],
    '  let photosIDX: string[] = [];',
    'photosIDX: photosIDX',
    `function capturePhotoIDX(state: AppState, uri: string): AppState {
  let out: string[] = [];
  let i: number = 0;
  while (i < state.photosIDX.length()) {
    out.push(state.photosIDX[i]);
    i = i + 1;
  }
  out.push(uri);
  return {photosIDX: out__PASSTHROUGH__};
}`,
    `{
  let photoViews: ui.View[] = [];
  photoViews.push(ui.Camera("default", "capturePhotoIDX", "back", "Capture page"));
  let i: number = 0;
  while (i < state.photosIDX.length()) {
    photoViews.push(ui.Image("default", state.photosIDX[i], "Captured page"));
    i = i + 1;
  }
  sections.push(ui.Section("content", "Photograph", "Use the live preview, then tap Capture", photoViews));
}`,
    [], [])
}

function liveFigureFragment(): FragmentSpec {
  let spec = new FragmentSpec(
    LIVE_KIND,
    'One to three figures of the real world as they are now (a price, an exchange rate, an index, the weather now, a live score) that ' +
    'the screen fetches from the internet and keeps up to date, shown with where and when they were read; not a fact that does not ' +
    'change, a figure at a stated date, a forecast or a past figure',
    '',
    [new StateFieldSpec('liveFigure1', 'string'), new StateFieldSpec('liveFigure2', 'string'), new StateFieldSpec('liveFigure3', 'string'),
     new StateFieldSpec('liveSource', 'string'), new StateFieldSpec('liveAsOf', 'string'), new StateFieldSpec('liveNote', 'string'),
     new StateFieldSpec('liveLastCall', 'number'), new StateFieldSpec('livePrevious', 'string'), new StateFieldSpec('livePreviousAt', 'string'),
     new StateFieldSpec('liveShowSource', 'boolean'), new StateFieldSpec('liveBusy', 'boolean'), new StateFieldSpec('liveChecked', 'string'),
     new StateFieldSpec('liveSame', 'boolean')],
    '',
    `liveFigure1: "", liveFigure2: "", liveFigure3: "", liveSource: "", liveAsOf: "", liveNote: "", liveLastCall: 0, livePrevious: "", livePreviousAt: "", liveShowSource: false, liveBusy: false, liveChecked: "", liveSame: false`,
    `function liveWith(state: AppState, f1: string, f2: string, f3: string, source: string, asOf: string, note: string, lastCall: number,
    previous: string, previousAt: string, showSource: boolean, busy: boolean, checked: string, same: boolean): AppState {
  return {liveFigure1: f1, liveFigure2: f2, liveFigure3: f3, liveSource: source, liveAsOf: asOf, liveNote: note, liveLastCall: lastCall,
    livePrevious: previous, livePreviousAt: previousAt, liveShowSource: showSource, liveBusy: busy, liveChecked: checked,
    liveSame: same__PASSTHROUGH__};
}

function liveKeep(state: AppState, note: string, lastCall: number, busy: boolean): AppState {
  return liveWith(state, state.liveFigure1, state.liveFigure2, state.liveFigure3, state.liveSource, state.liveAsOf, note, lastCall,
    state.livePrevious, state.livePreviousAt, state.liveShowSource, busy, state.liveChecked, state.liveSame);
}

function liveTwo(n: number): string {
  if (n < 10) { return "0" + ui.numberToString(n); }
  return ui.numberToString(n);
}

function liveClock(): string {
  return liveTwo(time.hourOfDay()) + ":" + liveTwo(time.minuteOfHour());
}

// The first number in the text as the page wrote it, as digits with "." for its decimal point. The separator written last is the
// decimal one when both are there ("1,234.56", "1.234,56"); a lone comma is a decimal comma ("92,35") unless three digits follow it
// ("1,234"); one written twice ("1.234.567") and spaces group thousands.
function liveNumeral(text: string): string {
  let run: string = "";
  let started: boolean = false;
  let done: boolean = false;
  let negative: boolean = false;
  let dots: number = 0;
  let commas: number = 0;
  let last: string = "";
  let after: number = 0;
  for (let c: string of text) {
    if (!done) {
      if (strings.contains("0123456789", c)) {
        run = run + c;
        started = true;
        after = after + 1;
      } else if (started && (c === "." || c === ",")) {
        run = run + c;
        last = c;
        after = 0;
        if (c === ".") { dots = dots + 1; } else { commas = commas + 1; }
      } else if (c === "-" && !started) {
        negative = true;
      } else if (started && c !== " " && c !== "\u00a0" && c !== "\u202f") {
        done = true;
      }
    }
  }
  let point: string = "";
  if (dots > 0 && commas > 0) {
    point = last;
  } else if (dots === 1) {
    point = ".";
  } else if (commas === 1 && (after !== 3 || strings.startsWith(run, "0,"))) {
    point = ",";
  }
  let out: string = "";
  if (negative) { out = "-"; }
  for (let c: string of run) {
    if (c === point) { out = out + "."; } else if (c !== "." && c !== ",") { out = out + c; }
  }
  return out;
}

function liveNumber(text: string): number {
  return strings.toNumber(liveNumeral(text), 0);
}

// How many places a figure is shown with, at most: about six digits in all, so a rate keeps its fifth place (1.11743) and a coin
// that an API answers as 75883.35636482359 does not keep its eleventh.
function liveCap(n: number, places: number): number {
  let a: number = n;
  if (a < 0) { a = 0 - a; }
  let most: number = 6;
  while (a >= 1 && most > 0) {
    a = a / 10;
    most = most - 1;
  }
  if (places > most) { return most; }
  return places;
}

// Whether the text is a bare number as an API answers it, with nothing a page wrote around it ("$76,022.73", "10.7 °C" are not).
function liveBare(text: string): boolean {
  // A sign only before the number: "2-1" is a score, not a number.
  let digits: boolean = false;
  for (let c: string of text) {
    if (strings.contains("0123456789", c)) { digits = true; }
    else if (c === "-" || c === "+") { if (digits) { return false; } }
    else if (!strings.contains("., \\u00a0", c)) { return false; }
  }
  return digits;
}

// A currency written before its number: "$", "€", "£", "₽", "¥", "₹", "₩", "₺", "₴", "₸".
function liveSymbol(unit: string): boolean {
  return strings.length(unit) === 1 && strings.contains("$\u20ac\u00a3\u20bd\u00a5\u20b9\u20a9\u20ba\u20b4\u20b8", unit);
}

// A bare number as people read it: rounded for its size, thousands grouped, money to the cent.
function liveTidy(text: string, money: boolean): string {
  let n: number = liveNumber(text);
  let negative: boolean = n < 0;
  let a: number = n;
  if (negative) { a = 0 - n; }
  // Money is to the cent: never fewer places, and past a thousand no more.
  let places: number = liveCap(n, liveDecimals(text));
  if (money && a >= 1 && places < 2) { places = 2; }
  if (money && a >= 1000) { places = 2; }
  let plain: string = ui.formatNumber(a, places);
  let whole: string = plain;
  let rest: string = "";
  let parts: string[] = strings.split(plain, ".");
  if (parts.length() > 1) { whole = parts[0]; rest = "." + parts[1]; }
  let grouped: string = "";
  let left: number = strings.length(whole);
  for (let c: string of whole) {
    grouped = grouped + c;
    left = left - 1;
    if (left > 0 && left % 3 === 0) { grouped = grouped + ","; }
  }
  if (negative) { return "-" + grouped + rest; }
  return grouped + rest;
}

function liveShown(text: string, unit: string): string {
  if (text === "") { return "-"; }
  if (liveBare(text)) {
    let money: boolean = liveSymbol(unit);
    let tidy: string = liveTidy(text, money);
    if (money) {
      if (strings.startsWith(tidy, "-")) { return "-" + unit + strings.substring(tidy, 1, strings.length(tidy)); }
      return unit + tidy;
    }
    if (unit === "") { return tidy; }
    return tidy + " " + unit;
  }
  if (unit === "" || strings.contains(text, unit)) { return text; }
  // "10°" with the unit "°C": the source wrote the degree sign already.
  if (strings.startsWith(unit, "°") && strings.contains(text, "°")) { return text; }
  return text + " " + unit;
}

function liveWeather(text: string): string {
  if (text === "") { return "-"; }
  let c: number = liveNumber(text);
  if (c === 0) { return "Clear sky"; }
  if (c === 1) { return "Mainly clear"; }
  if (c === 2) { return "Partly cloudy"; }
  if (c === 3) { return "Overcast"; }
  if (c === 45 || c === 48) { return "Fog"; }
  if (c >= 51 && c <= 55) { return "Drizzle"; }
  if (c === 56 || c === 57) { return "Freezing drizzle"; }
  if (c === 61) { return "Light rain"; }
  if (c === 63) { return "Rain"; }
  if (c === 65) { return "Heavy rain"; }
  if (c === 66 || c === 67) { return "Freezing rain"; }
  if (c === 71) { return "Light snow"; }
  if (c === 73) { return "Snow"; }
  if (c === 75) { return "Heavy snow"; }
  if (c === 77) { return "Snow grains"; }
  if (c >= 80 && c <= 82) { return "Rain showers"; }
  if (c === 85 || c === 86) { return "Snow showers"; }
  if (c === 95) { return "Thunderstorm"; }
  if (c === 96 || c === 99) { return "Thunderstorm with hail"; }
  return text;
}

function liveWhen(asOf: string): string {
  if (strings.length(asOf) >= 16 && strings.substring(asOf, 10, 11) === "T") { return strings.substring(asOf, 11, 16); }
  return asOf;
}

function liveChange(state: AppState): string {
  if (state.livePrevious === "" || state.liveFigure1 === "") { return ""; }
  let now: number = liveNumber(state.liveFigure1);
  let was: number = liveNumber(state.livePrevious);
  if (was === 0 || now === was) { return ""; }
  let moved: number = now - was;
  let arrow: string = "\\u25b2 +";
  if (moved < 0) { arrow = "\\u25bc "; }
  // As many places as the figure has: a rate that moved 0.00004 is not "+0.00".
  let livePlaces: number = liveDecimals(state.liveFigure1);
  let pastPlaces: number = liveDecimals(state.livePrevious);
  if (pastPlaces > livePlaces) { livePlaces = pastPlaces; }
  livePlaces = liveCap(now, livePlaces);
  let percent: number = moved / was * 100;
  let liveShare: string = ui.formatNumber(percent, 2) + "%";
  if (percent < 0.01 && percent > 0) { liveShare = "<0.01%"; }
  if (percent > -0.01 && percent < 0) { liveShare = "-<0.01%"; }
  return arrow + ui.formatNumber(moved, livePlaces) + " (" + liveShare + ") since " + liveWhen(state.livePreviousAt);
}

function liveDecimals(text: string): number {
  let places: number = 0;
  let after: boolean = false;
  for (let c: string of liveNumeral(text)) {
    if (c === ".") {
      after = true;
    } else if (after) {
      places = places + 1;
    }
  }
  if (places > 6) { return 6; }
  return places;
}

function liveUnder(state: AppState, moves: boolean): string {
  let under: string = "";
  if (moves) { under = liveChange(state); }
  if (state.liveShowSource && state.liveSource !== "") {
    let where: string = state.liveSource;
    if (state.liveAsOf !== "") { where = where + " \\u00b7 " + liveWhen(state.liveAsOf); }
    if (under !== "") { under = under + "\\n"; }
    under = under + where;
  }
  return under;
}

function liveToggleSource(state: AppState, ignored: number): AppState {
  return liveWith(state, state.liveFigure1, state.liveFigure2, state.liveFigure3, state.liveSource, state.liveAsOf, state.liveNote,
    state.liveLastCall, state.livePrevious, state.livePreviousAt, !state.liveShowSource, state.liveBusy, state.liveChecked, state.liveSame);
}

function liveLine(lines: string[], at: number, kept: string): string {
  if (at < lines.length()) {
    let t: string = strings.trim(lines[at]);
    if (t !== "") { return t; }
  }
  return kept;
}

function liveFetch(state: AppState, now: number): AppState {
  sdk.call("__LIVE_TARGET__", __LIVE_ARGS__, "liveAnswer");
  return liveKeep(state, state.liveNote, now, true);
}

function liveRefresh(state: AppState, ignored: number): AppState {
  // One request at a time: while one is out, the button says so and is off.
  if (state.liveBusy) { return state; }
  return liveFetch(state, time.nowSeconds());
}

function liveTick(state: AppState, elapsedMs: number): AppState {
  let now: number = time.nowSeconds();
  // An answer that never came does not leave the screen "Updating..." for good.
  if (state.liveBusy) {
    if (now - state.liveLastCall < 20) { return state; }
    return liveKeep(state, "The source did not answer in time.", state.liveLastCall, false);
  }
  if (now - state.liveLastCall < __LIVE_EVERY__) { return state; }
  return liveFetch(state, now);
}

// Why an update failed, as a sentence for the person: the call's "error: " or "error 502: " is for the trace, not the screen.
function liveWhy(value: string): string {
  let why: string = strings.trim(value);
  if (strings.startsWith(why, "error")) {
    let parts: string[] = strings.split(why, ": ");
    if (parts.length() > 1) {
      why = "";
      let i: number = 1;
      while (i < parts.length()) {
        if (i > 1) { why = why + ": "; }
        why = why + parts[i];
        i = i + 1;
      }
    }
  }
  if (strings.length(why) > 140) { why = strings.substring(why, 0, 140); }
  if (why === "") { return "The source did not answer."; }
  why = strings.toUpperCase(strings.substring(why, 0, 1)) + strings.substring(why, 1, strings.length(why));
  if (!strings.endsWith(why, ".")) { why = why + "."; }
  return why;
}

function liveAnswer(state: AppState, value: string): AppState {
  if (!strings.startsWith(value, "ok")) {
    let why: string = liveWhy(value);
    return liveKeep(state, why, state.liveLastCall, false);
  }
  let lines: string[] = strings.split(value, "\\n");
  let source: string = state.liveSource;
  let asOf: string = state.liveAsOf;
  if (lines.length() > 4) {
    let src: string[] = strings.split(lines[4], "\\t");
    if (src.length() > 1) { source = src[1]; }
  }
  if (lines.length() > 5) {
    let when: string[] = strings.split(lines[5], "\\t");
    if (when.length() > 1) { asOf = when[1]; }
  }
  // The first figure as it was before this answer, and when: what the change under it is told against.
  let first: string = liveLine(lines, 1, state.liveFigure1);
  let previous: string = state.livePrevious;
  let previousAt: string = state.livePreviousAt;
  if (state.liveFigure1 !== "" && first !== state.liveFigure1) {
    previous = state.liveFigure1;
    previousAt = state.liveAsOf;
  }
  let second: string = liveLine(lines, 2, state.liveFigure2);
  let third: string = liveLine(lines, 3, state.liveFigure3);
  // Whether this answer moved anything: a refresh that changes nothing still says it checked.
  let same: boolean = state.liveFigure1 !== "" && first === state.liveFigure1 && second === state.liveFigure2 && third === state.liveFigure3;
  return liveWith(state, first, second, third, source, asOf, "", state.liveLastCall, previous, previousAt, state.liveShowSource,
    false, liveClock(), same);
}`,
    `{
    let liveTiles: ui.View[] = [];
__LIVE_ROWS__
    // Only before the first answer: one that came with no first figure still shows the others, with "-" for it.
    let liveWaiting: boolean = state.liveChecked === "" && state.liveNote === "";
    let liveInfo: string = "Show the source";
    if (state.liveShowSource) { liveInfo = "Hide the source"; }
    // The tiles alone in their section, so it draws no card around their cards; the buttons and the source under them.
    sections.push(ui.Section("content", "", "", [
      ui.When(liveWaiting, ui.Skeleton("default", 320, 112)),
      ui.When(!liveWaiting, ui.TileGrid("default", liveTiles))
    ]));
    // Where the figures are from is under the first one, shown and hidden by the info button.
    // What a refresh did: "Updating..." while it is out, then when it answered and whether anything moved.
    let liveActions: ui.View[] = [];
    if (!state.liveBusy && state.liveChecked !== "") {
      let liveCheckedText: string = "Updated " + state.liveChecked;
      if (state.liveSame) { liveCheckedText = liveCheckedText + " \\u00b7 no change"; }
      liveActions.push(ui.Badge("default", liveCheckedText, "check"));
    }
    liveActions.push(ui.IconButton("quiet", "info", liveInfo, "liveToggleSource", 0, state.liveSource !== ""));
    let liveButton: string = "Refresh";
    if (state.liveBusy) { liveButton = "Updating..."; }
    liveActions.push(ui.Button("secondary", liveButton, "liveRefresh", 0, !state.liveBusy));
    sections.push(ui.Section("supporting", "", "", [
      ui.ActionBar("end", liveActions),
      ui.Ticker("default", "live", 1000, true, "liveTick")
    ]));
    sections.push(ui.Section("supporting", "", "", [
      ui.When(state.liveNote !== "", ui.InsetBanner("warning", "Could not update", state.liveNote, "", "", "info"))
    ]));
  }`,
    [],
    [],
    ['import * as sdk from "std/sdk"', 'import * as strings from "std/strings"', 'import * as time from "std/time"'],
    [],
    [new PortSpec('writes', 'live1', 'number', liveFigureNumber(1), '', true),
     new PortSpec('writes', 'live2', 'number', liveFigureNumber(2), '', true),
     new PortSpec('writes', 'live3', 'number', liveFigureNumber(3), '', true),
     new PortSpec('writes', 'live_source', 'string', 'liveSource'),
     new PortSpec('writes', 'live_asof', 'string', 'liveAsOf')],
    [],
    ['needs_real_data', 'needs_integration', 'needs_live_ticking']
  )
  spec.indexed = false
  spec.owns = 'the figures it fetches, how the first moved since the last answer, where and when they were read (behind an info button), and a Refresh button'
  spec.tab = 'Live'
  spec.hostFields = [
    new ContentFieldSpec('__LIVE_TARGET__', 'target', 'Vera.Source.fetch', 'Vera.Source.fetch or Vera.Live.fetch', 20),
    new ContentFieldSpec('__LIVE_ARGS__', 'args', '["url", "https://example.org/figures", "paths", "value"]', 'the call\'s parameters, written out', 600),
    new ContentFieldSpec('__LIVE_EVERY__', 'every', '300', 'seconds between fetches', 6),
    new ContentFieldSpec('__LIVE_ROWS__', 'rows', '    liveTiles.push(ui.Tile("accent", 2, "Value", liveShown(state.liveFigure1, ""), liveUnder(state, true), ""));',
      'one Tile line for each figure', 900)
  ]
  return spec
}

export function fragments(): FragmentSpec[] {
  let all: FragmentSpec[] = [
    checklistFragment(), metricsFragment(), timerFragment(), calendarEventFragment(),
    actionsFragment(), progressGoalFragment(), keyFactsFragment(), trendChartFragment(),
    noteFragment(), ratingFragment(), spotlightFragment(),
    searchListFragment(), dataTableFragment(), timelineFragment(),
    barChartFragment(),
    masterListFragment(), detailViewFragment(), listSummaryFragment(), filterBoxFragment(),
    recordLogFragment(), numberStripFragment(), breakdownTableFragment(), seriesChartFragment(), settleUpFragment(),
    itineraryFragment(), progressLineFragment(), intentPanelFragment(), remindersFragment(),
    quickLogFragment(), doseScheduleFragment(),
    dueItemsFragment(), pointsLedgerFragment(),
    ideaDeckFragment(), intervalTimerFragment(), readingStatusFragment(), liveFigureFragment()
  ]
  for (let f of all) { if (f.owns.length === 0 && SECTION_OWNS.has(f.kind)) { f.owns = SECTION_OWNS.get(f.kind)! } }
  return all
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
