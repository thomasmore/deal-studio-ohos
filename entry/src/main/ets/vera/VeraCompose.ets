/**
 * Composition from a sketch: json-render's Jev composer, generalised to programs with logic.
 *
 * json-render (vercel-labs) has Jev pick among app-owned, fully configured component recipes and
 * assembles the result in code; Jev never writes text or code, and nothing computes. Here the
 * recipes are generated per request instead of prepared in advance, and logic is a finite choice too:
 *
 *   1. sketch  -- the generating model, thinking off, turns the request into data: the inputs with
 *                 their ranges and options, fixed numbers, the values the screen must show, a
 *                 countdown or a stopwatch, a list the person adds entries to, the events, and
 *                 whatever else the request asks for. No code.
 *   2. choose  -- Jev answers one independent question per requirement: which widget for each input,
 *                 which unit-checked expression produces each value (operands: inputs, constants,
 *                 earlier values, the clock's seconds, the list's count and total) and whether it
 *                 is one step at all, what sets the countdown's length, which effect each event is
 *                 and at which moment, and whether an item the sketch could not place is something
 *                 a part already does.
 *   3. build   -- this file assembles a VERA program from the answers; the compiler checks it.
 *
 * Coverage is structural: a value with no formula, an operand that does not exist yet, or an event
 * with no effect is reported as unbound rather than replaced by a default, and a composition with
 * anything unbound is not served. Only what the sketch added on its own -- an event the request did
 * not ask for, a number nothing reads and Jev says it did not ask for -- is left out instead, and the
 * status line names it.
 */

import { NeedsPlan } from './NeedsPlan'
import { OperationCancellation, throwIfCancelled } from './OperationCancellation'
import { FragmentSpec, StateFieldSpec, PortSpec, VetoSpec, fragments, vetoes, LIVE_KIND, liveFigureNumber } from './VeraTemplates'
import { composeFragments } from './VeraSectionCompose'
import { blockDefaults } from './VeraTemplateContent'
import { askSelector } from './VeraSelector'
import { ScreenPlan, PlanSlot, PlanComponent, StateItem, assemblePlan, FILL_PART, FILL_BLOCK, FILL_EFFECT, FILL_HOLE, FILL_OPEN,
  PLAN_FROM_SKETCH, TO_WRITE } from './ScreenPlan'


/** On whenever there is a TypeSafe key; `--ps veraCompose 0` switches it off for the session. */
let enabled: boolean = true
export function setComposeEnabled(on: boolean): void { enabled = on }
export function composeEnabled(): boolean { return enabled }

/**
 * Whether a need nothing in the vocabulary or the catalogue does is left to a custom section the model writes
 * (agent/AgentCustom.ets) rather than refusing the screen; `--ps veraCustom 0` turns that off.
 */
let customEnabled: boolean = true
export function setCustomSectionsEnabled(on: boolean): void { customEnabled = on }
export function customSectionsEnabled(): boolean { return customEnabled }

/** Whether a request the composer cannot serve is generated with its sketch as a plan; `--ps veraComposePlan 0` turns that off. */
let planEnabled: boolean = true
export function setComposePlanEnabled(on: boolean): void { planEnabled = on }
export function composePlanEnabled(): boolean { return planEnabled }

/**
 * Kinds of the catalogue the plan may ask for: the sections whose substance is content written for the request, which
 * the parts above cannot build. Left out are the blocks that do what a part already does (a timer, a log of entries,
 * reminders, a note, a slider, summary numbers, one calendar event, buttons), so a plan does not move a part's job
 * into a section and lose the figures worked out from it; the blocks only useful next to another (a filter box, a
 * detail view, the readers of a log); and the intent panel, whose rows are a call of their own.
 */
export const READY_KINDS: string[] = ['checklist', 'key_facts', 'trend_chart', 'spotlight', 'search_list', 'data_table', 'timeline',
  'bar_chart', 'itinerary', 'idea_deck']

/** Something the plan cannot settle without the person: the answers, and the one the plan was drawn for. */
export class SketchQuestion {
  id: string = ''
  ask: string = ''
  options: string[] = []
  fallback: number = 0
  /** What the person answered, typed or chosen (askBlocking); '' while not asked, when the default stands. */
  answer: string = ''
}

/** The answer a question stands at: the person's, else its default. */
export function answerTo(q: SketchQuestion): string {
  if (q.answer.length > 0) { return q.answer }
  return q.fallback >= 0 && q.fallback < q.options.length ? q.options[q.fallback] : ''
}

/** Words of an answer worth finding again in a query or a title: not "the", "now", "match". */
function answerWords(answer: string): string[] {
  const COMMON: string[] = ['the', 'and', 'for', 'now', 'today', 'live', 'current', 'match', 'game', 'price', 'rate', 'weather']
  return answer.split(/[^A-Za-z0-9\u00C0-\u024F\u0400-\u04FF]+/).filter((w: string): boolean =>
    w.length > 2 && COMMON.indexOf(w.toLowerCase()) < 0)
}

/**
 * What the person answered (or the default that stood) is what the live figures are about: a plan drawn for the default often writes
 * a query without it ("live football match score now" for "Arsenal"), and then a search finds no one match and the screen does not
 * say whose figures it shows. The answer's words go into each live query that lacks them, and onto the screen's eyebrow when its
 * title, eyebrow and subtitle do not name it. Returns what was added, for the trace.
 */
export function keepAnswers(sketch: Sketch, answers: string[]): string {
  if (sketch.live.length === 0) { return '' }
  let notes: string[] = []
  for (let answer of answers) {
    let words = answerWords(answer)
    if (words.length === 0) { continue }
    for (let l of sketch.live) {
      let query = l.query.length > 0 ? l.query : l.label
      let missing = words.filter((w: string): boolean => query.toLowerCase().indexOf(w.toLowerCase()) < 0)
      if (missing.length > 0) {
        l.query = query + ' ' + missing.join(' ')
        notes.push('query "' + l.query + '"')
      }
    }
    let header = (sketch.title + ' ' + sketch.eyebrow + ' ' + sketch.subtitle).toLowerCase()
    if (words.some((w: string): boolean => header.indexOf(w.toLowerCase()) < 0)) {
      let named = answer.replace(/\s*\b(now|today|right now)\s*$/i, '').trim()
      sketch.eyebrow = sketch.eyebrow.length > 0 ? sketch.eyebrow + ' \u00b7 ' + named : named
      notes.push('eyebrow "' + sketch.eyebrow + '"')
    }
  }
  return notes.join('; ')
}

export class SketchOption {
  label: string = ''
  value: number = 0
}

export class SketchInput {
  id: string = ''
  label: string = ''
  kind: string = 'count'
  min: number = 0
  max: number = 100
  value: number = 0
  unit: string = ''
  /** money, percent, count, seconds, minutes or number: what the input measures, for unit-checked formulas. */
  measure: string = 'number'
  options: SketchOption[] = []
  /**
   * Set once and rarely changed (a goal, a threshold, a glass size, hours of sleep), not what the person works with each time:
   * drawn folded under Settings at the foot of the screen (settingsPart), not above what the screen is for. See markSettings.
   */
  setting: boolean = false
}

export class SketchValue {
  id: string = ''
  label: string = ''
  means: string = ''
  format: string = 'plain'
  unit: string = ''
  /** For a plain number, how many digits after the point it is shown with; -1 for the usual one. */
  decimals: number = -1
  /** The sketch's own expression for it, used only where no formula of the vocabulary is chosen; '' when none. */
  formula: string = ''
  /** The sketch's worked example for the formula: sample numbers for what it reads, and what it gives for them. */
  given: Map<string, number> = new Map<string, number>()
  result: number = NaN
  /** A step toward another figure that the request does not ask to see: worked out, not shown. */
  hidden: boolean = false
  /**
   * A yes or a no worked out as 1 or 0 ("currentTemp >= threshold ? 1 : 0", or the plan's format "yes_no"): shown as Yes or No.
   * As a number it read "Fever level 0" (Baby fever).
   */
  yesNo: boolean = false
}

export class SketchEvent {
  id: string = ''
  when: string = ''
  what: string = ''
  /** False when the sketch added the event on its own; such an event is dropped rather than refused. */
  asked: boolean = true
}

export class SketchConstant {
  id: string = ''
  label: string = ''
  value: number = 0
  measure: string = 'number'
}

/** One thing each entry of a list holds: words, a number, a time of day or an on/off. */
export class ListField {
  id: string = ''
  label: string = ''
  kind: string = 'text'
  /** For a number, what it measures, as for inputs. */
  measure: string = 'number'
  unit: string = ''
  /** For a plain number, how many digits after the point it is shown with; -1 for the usual one. */
  decimals: number = -1
  /** The form's starting value: minutes since midnight for a time, 1 for an on/off that starts on. */
  value: number = 0
  /**
   * A number the request itself gives for this field ("a fever of 37.5°C"): the list starts with one entry holding it, so the
   * figures that read the entries show it at once instead of "No reading yet". NaN when the request names none.
   */
  seed: number = NaN
}

/** Entries the person adds through a form of up to four fields (none: one entry per tap), each stamped with the minute it was added. */
export class SketchList {
  label: string = ''
  fields: ListField[] = []
}

const FIELD_KINDS: string[] = ['text', 'number', 'time', 'date', 'toggle']
const MAX_FIELDS: number = 4

/** The list's first field of `kind`, or null. */
function firstField(l: SketchList, kind: string): ListField | null {
  for (let f of l.fields) { if (f.kind === kind) { return f } }
  return null
}

/**
 * The words an item of `other` starts with when the plan of needs made it a scene (NeedsPlan.ets): a picture the app draws
 * itself, which nothing ready does. It is written in the section hole on a ui.Surface (AgentCustom.ets), and neither a part
 * nor a section of the catalogue is asked about it.
 */
export const SCENE_MARK: string = 'a scene the app draws itself: '

export function isScene(need: string): boolean { return need.startsWith(SCENE_MARK) }

/**
 * A figure of the real world as it is now (a price, a rate, the weather, a score) that the screen fetches itself: the
 * live_figure section of the catalogue (LiveBlock.ets) when Jev says so, and a number the plan's formulas may read by its id.
 */
export class SketchLive {
  id: string = ''
  label: string = ''
  means: string = ''
  /** The unit or currency shown beside it: "USD", "°C"; '' for none. */
  unit: string = ''
  /** money, percent, count or number: what it measures, for unit-checked formulas. */
  measure: string = 'number'
  /** A few words a web search finds it with as it is now: "Bitcoin price USD". */
  query: string = ''
}

/** At most this many live figures on a screen: one source answers up to three (VeraSource.ets's SOURCE_MAX_FIGURES). */
export const MAX_LIVE: number = 3

export class Sketch {
  title: string = ''
  eyebrow: string = ''
  subtitle: string = ''
  inputs: SketchInput[] = []
  constants: SketchConstant[] = []
  values: SketchValue[] = []
  countdown: string = ''
  hasCountdown: boolean = false
  /** The id the sketch says sets the countdown's length; a hint for Jev's question, not a binding. */
  countdownLength: string = ''
  stopwatch: string = ''
  hasStopwatch: boolean = false
  list: SketchList | null = null
  events: SketchEvent[] = []
  /** Figures of the real world the screen fetches itself, in the order the plan gave them. */
  live: SketchLive[] = []
  /** Live figures past the third, which one source cannot answer: left out, in words. */
  liveCut: string[] = []
  /** Needs a ready-made section of the catalogue handles whole, in words; Jev chooses the section for each. */
  ready: string[] = []
  /** What the plan would ask the person, each drawn for its default answer. */
  questions: SketchQuestion[] = []
  /** What the request asks for beyond the fields above; anything here makes the request unbound. */
  other: string[] = []
}

const INPUT_KINDS: string[] = ['amount', 'percent', 'count', 'choice', 'toggle', 'text', 'time']

/** Kinds that hold a number a formula can use: not a switch, not typed words. */
function isNumeric(kind: string): boolean { return kind !== 'toggle' && kind !== 'text' }
const VALUE_FORMATS: string[] = ['money', 'percent', 'count', 'seconds', 'minutes', 'clock', 'fraction', 'plain']
const MEASURES: string[] = ['money', 'percent', 'count', 'seconds', 'minutes', 'clock', 'number']

function str(o: Record<string, Object>, key: string, fallback: string): string {
  let v = o[key]
  return typeof v === 'string' ? v as string : fallback
}

function num(o: Record<string, Object>, key: string, fallback: number): number {
  let v = o[key]
  return typeof v === 'number' && isFinite(v as number) ? v as number : fallback
}

/** The digits after the point the sketch asks for, 0 to 6, whole; -1 when it asks for none or nonsense. */
function decimalsOf(o: Record<string, Object>): number {
  let n = num(o, 'decimals', -1)
  return n >= 0 && n <= 6 && Math.floor(n) === n ? n : -1
}

function isIdentifier(s: string): boolean {
  return /^[a-z][A-Za-z0-9]*$/.test(s) && RESERVED_IDS.indexOf(s) < 0
}

/**
 * The id as a usable name: a model's "duration" or a second "total" is renamed rather than dropped,
 * since dropping it silently took the one input a countdown could run from. '' when it cannot be a name.
 */
function usableId(raw: string, seen: string[]): string {
  if (!/^[a-z][A-Za-z0-9]*$/.test(raw)) { return '' }
  let id = raw
  let n = 1
  while (!isIdentifier(id) || seen.indexOf(id) >= 0) {
    id = raw + 'Item' + (n > 1 ? n.toString() : '')
    n++
  }
  return id
}

/** Names the assembled program uses for itself; an input or value may not take them. */
const RESERVED_IDS: string[] = ['state', 'value', 'elapsedMs', 'running', 'finished', 'effectStatus', 'remaining',
  'elapsed', 'duration', 'view', 'init', 'ui', 'math', 'strings', 'sdk', 'time', 'entries', 'entryCount', 'entryTotal',
  'draftText', 'draftNumberText', 'entry', 'out', 'rows', 'i', 'e', 'emptyEntries', 'firstEntries', 'total', 'next', 'startAt',
  'effectNote', 'share', 'countdownSeconds', 'addEntry', 'removeEntry', 'ignored', 'onEntryAnswer', 'answered', 'marked',
  'note', 'sub', 'undoRemove', 'expireUndo', 'removedEntries', 'removedAt', 'gone', 'none']

/** The sketch from the model's reply, or null when it is not one. Ids that cannot be names are dropped. */
export function parseSketch(text: string): Sketch | null {
  let start = text.indexOf('{')
  let end = text.lastIndexOf('}')
  if (start < 0 || end <= start) { return null }
  let o: Record<string, Object>
  try {
    o = JSON.parse(text.substring(start, end + 1)) as Record<string, Object>
  } catch (_e) {
    return null
  }
  let sketch = new Sketch()
  sketch.title = str(o, 'title', 'App')
  sketch.eyebrow = str(o, 'eyebrow', '')
  sketch.subtitle = str(o, 'subtitle', '')
  let seen: string[] = []
  let inputs = o['inputs']
  if (Array.isArray(inputs)) {
    for (let raw of inputs as Object[]) {
      let r = raw as Record<string, Object>
      let input = new SketchInput()
      input.id = usableId(str(r, 'id', ''), seen)
      if (input.id.length === 0) { continue }
      input.label = str(r, 'label', input.id)
      input.kind = str(r, 'kind', 'count')
      if (INPUT_KINDS.indexOf(input.kind) < 0) { input.kind = 'count' }
      input.min = num(r, 'min', 0)
      input.max = num(r, 'max', 100)
      input.value = num(r, 'value', input.min)
      input.unit = str(r, 'unit', '')
      input.setting = r['setting'] === true
      input.measure = str(r, 'measure', input.kind === 'percent' ? 'percent' : (input.kind === 'count' ? 'count' : 'number'))
      if (MEASURES.indexOf(input.measure) < 0 || input.measure === 'clock') { input.measure = 'number' }
      if (input.measure === 'money') { input.unit = currencySign(input.unit) }
      // A length of time the sketch called a time ("kind": "time", "measure": "seconds") is a number of seconds or minutes, as it says.
      // Unless it is minutes after midnight, which is what its range says: 0 to 1439 ("Start time" 09:00 is 540). A length of time
      // (a rest of 0 to 3600 seconds, a stop of 15 to 240 minutes) is a number, as it says. The range may start later in the
      // day (a wake time of 05:00 to 23:59 is 300 to 1439): it is the end at midnight that says so.
      let minutesOfTheDay = input.measure === 'minutes' && input.min < 1439 && input.max >= 1439 && input.max <= 1440
      if (input.kind === 'time' && isTime(input.measure) && !minutesOfTheDay) { input.kind = 'count' }
      // A number the plan says is minutes since midnight ("Sleep starts", unit "minutes since midnight", 1320) is a time of day: typed as
      // a number it read 1320 in a text field (Water reminder on the phone). Its words say so, not its range: a count of minutes up to
      // 1440 is as often a length ("Daily screen-time limit", 0 to 1440, 120 is two hours, not 02:00).
      if ((input.kind === 'count' || input.kind === 'amount') && /since midnight|time of day/i.test(input.unit + ' ' + input.label) &&
        input.value >= 0 && input.value < 1440) { input.kind = 'time' }
      // A time of day is minutes since midnight, whatever measure the sketch wrote.
      if (input.kind === 'time') {
        input.measure = 'clock'
        input.value = Math.max(0, Math.min(1439, Math.round(num(r, 'value', 480))))
      }
      let options = r['options']
      if (Array.isArray(options)) {
        for (let rawOption of options as Object[]) {
          let ro = rawOption as Record<string, Object>
          let option = new SketchOption()
          option.label = str(ro, 'label', '')
          option.value = num(ro, 'value', 0)
          if (option.label.length > 0) { input.options.push(option) }
        }
      }
      if (input.kind === 'choice' && input.options.length === 0) { continue }
      // Options labelled "25 minutes" whose values are 1500: the values are seconds, whatever the measure says.
      if (input.kind === 'choice' && input.measure === 'minutes' && input.options.every((o: SketchOption): boolean => leadingNumber(o.label) > 0 &&
        o.label.toLowerCase().indexOf('min') >= 0 && o.value === leadingNumber(o.label) * 60)) { input.measure = 'seconds' }
      if (input.kind === 'choice') {
        // The starting choice is an option index; a model sometimes gives the option's value instead.
        let at = input.options.findIndex((o: SketchOption): boolean => o.value === input.value)
        if (!(Number.isInteger(input.value) && input.value >= 0 && input.value < input.options.length)) {
          input.value = at >= 0 ? at : 0
        }
      }
      seen.push(input.id)
      sketch.inputs.push(input)
    }
  }
  let constants = o['constants']
  if (Array.isArray(constants)) {
    for (let raw of constants as Object[]) {
      let r = raw as Record<string, Object>
      let constant = new SketchConstant()
      constant.id = usableId(str(r, 'id', ''), seen)
      if (constant.id.length === 0 || typeof r['value'] !== 'number') { continue }
      constant.label = str(r, 'label', constant.id)
      constant.value = num(r, 'value', 0)
      constant.measure = str(r, 'measure', 'number')
      if (MEASURES.indexOf(constant.measure) < 0 || constant.measure === 'clock') { constant.measure = 'number' }
      seen.push(constant.id)
      sketch.constants.push(constant)
    }
  }
  let live = o['live']
  if (Array.isArray(live)) {
    for (let raw of live as Object[]) {
      if (raw === null || typeof raw !== 'object') { continue }
      let r = raw as Record<string, Object>
      let figure = new SketchLive()
      figure.id = usableId(str(r, 'id', ''), seen)
      if (figure.id.length === 0) { continue }
      // One source answers three figures: a fourth is left out, said on the Metrics tab -- not a need for the written section,
      // which can fetch nothing either and only put a notice above the screen (Weather today: "Chance of rain").
      if (sketch.live.length >= MAX_LIVE) { sketch.liveCut.push(str(r, 'label', figure.id)); continue }
      figure.label = str(r, 'label', figure.id)
      figure.means = str(r, 'means', figure.label)
      figure.unit = str(r, 'unit', '')
      figure.measure = str(r, 'measure', 'number')
      if (['money', 'percent', 'count', 'number'].indexOf(figure.measure) < 0) { figure.measure = 'number' }
      if (figure.measure === 'money') { figure.unit = currencySign(figure.unit) }
      figure.query = str(r, 'query', figure.label)
      seen.push(figure.id)
      sketch.live.push(figure)
    }
  }
  let countdown = o['countdown']
  if (countdown !== null && countdown !== undefined && typeof countdown === 'object') {
    sketch.hasCountdown = true
    sketch.countdown = str(countdown as Record<string, Object>, 'label', 'Timer')
    sketch.countdownLength = str(countdown as Record<string, Object>, 'length', '')
  }
  let stopwatch = o['stopwatch']
  if (stopwatch !== null && stopwatch !== undefined && typeof stopwatch === 'object') {
    let label = str(stopwatch as Record<string, Object>, 'label', 'Stopwatch')
    // One clock per screen: a stopwatch beside a countdown is something the parts do not make.
    if (sketch.hasCountdown) { sketch.other.push('a stopwatch as well as a countdown') }
    else { sketch.hasStopwatch = true; sketch.stopwatch = label }
  }
  let list = o['list']
  if (list !== null && list !== undefined && typeof list === 'object' && !Array.isArray(list)) {
    let r = list as Record<string, Object>
    let l = new SketchList()
    l.label = str(r, 'label', 'Entries')
    // Names the entry record already has, and type names, are not field names.
    let taken: string[] = ['minute', 'status', 'number', 'string', 'boolean']
    let rawFields = r['fields']
    let given: Record<string, Object>[] = []
    if (Array.isArray(rawFields)) {
      for (let raw of rawFields as Object[]) { given.push(raw as Record<string, Object>) }
    } else {
      // The older shape: words under "text", one number under "number".
      if (str(r, 'text', '').length > 0) {
        let t: Record<string, Object> = {}
        t['id'] = 'words'
        t['label'] = str(r, 'text', '')
        t['kind'] = 'text'
        given.push(t)
      }
      if (str(r, 'number', '').length > 0) {
        let n: Record<string, Object> = {}
        n['id'] = 'amount'
        n['label'] = str(r, 'number', '')
        n['kind'] = 'number'
        n['measure'] = str(r, 'measure', 'number')
        n['unit'] = str(r, 'unit', '')
        given.push(n)
      }
    }
    for (let rf of given) {
      if (l.fields.length >= MAX_FIELDS) { break }
      let field = new ListField()
      field.id = usableId(str(rf, 'id', ''), taken)
      if (field.id.length === 0) { continue }
      field.label = str(rf, 'label', field.id)
      field.kind = str(rf, 'kind', 'text')
      if (FIELD_KINDS.indexOf(field.kind) < 0) { field.kind = 'text' }
      field.measure = str(rf, 'measure', 'number')
      if (MEASURES.indexOf(field.measure) < 0 || field.measure === 'clock') { field.measure = 'number' }
      field.unit = field.measure === 'money' ? currencySign(str(rf, 'unit', '')) : str(rf, 'unit', '')
      field.decimals = decimalsOf(rf)
      field.value = num(rf, 'value', field.kind === 'time' ? 480 : 0)
      if (field.kind === 'time') {
        field.measure = 'clock'
        field.value = Math.max(0, Math.min(1439, Math.round(field.value)))
      }
      taken.push(field.id)
      l.fields.push(field)
    }
    sketch.list = l
    ensureLapFields(sketch)
  }
  let values = o['values']
  if (Array.isArray(values)) {
    for (let raw of values as Object[]) {
      let r = raw as Record<string, Object>
      let value = new SketchValue()
      value.id = usableId(str(r, 'id', ''), seen)
      if (value.id.length === 0) { continue }
      value.label = str(r, 'label', value.id)
      value.means = str(r, 'means', value.label)
      value.format = str(r, 'format', 'plain')
      value.yesNo = value.format === 'yes_no' || isYesNoFormula(str(r, 'formula', ''))
      if (value.format === 'yes_no') { value.format = 'plain' }
      // "time_of_day" is the internal clock format; a sketch's own "clock" more often means a length of time.
      if (value.format === 'time_of_day') { value.format = 'clock' }
      else if (value.format === 'clock' || VALUE_FORMATS.indexOf(value.format) < 0) { value.format = 'plain' }
      value.unit = value.format === 'money' ? currencySign(str(r, 'unit', '')) : str(r, 'unit', '')
      value.decimals = decimalsOf(r)
      value.formula = str(r, 'formula', '').trim()
      value.hidden = r['shown'] === false
      let example = r['example']
      if (example !== null && example !== undefined && typeof example === 'object') {
        let ex = example as Record<string, Object>
        let given = ex['given']
        if (given !== null && given !== undefined && typeof given === 'object') {
          let g = given as Record<string, Object>
          for (let key of Object.keys(g)) {
            if (typeof g[key] === 'number') { value.given.set(key, g[key] as number) }
          }
        }
        value.result = num(ex, 'result', NaN)
      }
      seen.push(value.id)
      sketch.values.push(value)
    }
  }
  let other = o['other']
  if (Array.isArray(other)) {
    for (let item of other as Object[]) {
      if (typeof item === 'string' && (item as string).trim().length > 0) { sketch.other.push((item as string).trim()) }
    }
  }
  let questions = o['questions']
  if (Array.isArray(questions)) {
    for (let raw of questions as Object[]) {
      if (raw === null || typeof raw !== 'object') { continue }
      let r = raw as Record<string, Object>
      let q = new SketchQuestion()
      q.id = str(r, 'id', 'q' + sketch.questions.length.toString())
      q.ask = str(r, 'ask', '').trim()
      let options = r['options']
      if (Array.isArray(options)) {
        for (let item of options as Object[]) { if (typeof item === 'string' && (item as string).trim().length > 0) { q.options.push((item as string).trim()) } }
      }
      let d = r['default']
      q.fallback = typeof d === 'number' ? Math.max(0, Math.min(q.options.length - 1, Math.round(d as number))) : 0
      if (q.ask.length > 0 && q.options.length >= 2 && q.options.length <= 4 && sketch.questions.length < 2) { sketch.questions.push(q) }
    }
  }
  let ready = o['ready']
  if (Array.isArray(ready)) {
    for (let item of ready as Object[]) {
      // A need written as an object ({"need": ..., "what": ...}) is its words joined.
      let words = ''
      if (typeof item === 'string') {
        words = item as string
      } else if (item !== null && typeof item === 'object') {
        let parts: string[] = []
        let fields = item as Record<string, Object>
        Object.keys(fields).forEach((k: string) => { if (typeof fields[k] === 'string') { parts.push(fields[k] as string) } })
        words = parts.join('. ')
      }
      if (words.trim().length > 0) { sketch.ready.push(words.trim()) }
    }
  }
  let events = o['events']
  if (Array.isArray(events)) {
    for (let raw of events as Object[]) {
      let r = raw as Record<string, Object>
      let event = new SketchEvent()
      event.id = str(r, 'id', '')
      event.when = str(r, 'when', '')
      event.what = str(r, 'what', '')
      event.asked = r['asked'] !== false
      if (event.what.length > 0) { sketch.events.push(event) }
    }
  }
  return sketch
}

// ---- Currency ----

/** Currency names and codes a sketch writes, by the sign shown in front of an amount. */
const CURRENCY_SIGNS: string[][] = [
  ['CA$', 'canadian dollar', 'canadian dollars', 'cad'], ['A$', 'australian dollar', 'australian dollars', 'aud'],
  ['NZ$', 'new zealand dollar', 'new zealand dollars', 'nzd'], ['HK$', 'hong kong dollar', 'hong kong dollars', 'hkd'],
  ['S$', 'singapore dollar', 'singapore dollars', 'sgd'], ['MX$', 'mexican peso', 'mexican pesos', 'mxn'],
  ['R$', 'real', 'reais', 'brazilian real', 'brl'], ['CN¥', 'yuan', 'renminbi', 'rmb', 'cny', 'chinese yuan'],
  ['$', 'dollar', 'dollars', 'usd', 'us$', 'us dollar', 'us dollars', 'u.s. dollars'],
  ['€', 'euro', 'euros', 'eur'], ['£', 'pound', 'pounds', 'gbp', 'sterling', 'pound sterling', 'pounds sterling', 'british pounds'],
  ['¥', 'yen', 'jpy', 'japanese yen'], ['₹', 'rupee', 'rupees', 'inr', 'indian rupees'], ['₩', 'won', 'krw', 'korean won'],
  ['₽', 'ruble', 'rubles', 'rouble', 'roubles', 'rub'], ['₺', 'lira', 'turkish lira', 'try'], ['₪', 'shekel', 'shekels', 'ils'],
  ['₫', 'dong', 'vnd'], ['฿', 'baht', 'thb'], ['₱', 'philippine peso', 'philippine pesos', 'php'], ['CHF ', 'franc', 'francs', 'swiss franc', 'swiss francs', 'chf']]

/**
 * The sign an amount is shown with: a sketch writes its currency as "dollars" or "USD" as often as "$", and the
 * screen showed "dollars22.44". A currency not known here keeps its own word, set apart from the number ("kr 12.00").
 */
export function currencySign(unit: string): string {
  let u = unit.trim()
  if (u.length === 0 || !/[A-Za-z]/.test(u)) { return u }
  let key = u.toLowerCase().replace(/\s+/g, ' ')
  for (let row of CURRENCY_SIGNS) {
    for (let k = 1; k < row.length; k++) { if (row[k] === key) { return row[0] } }
  }
  return u + ' '
}

// ---- A value's written formula ----

/**
 * A formula the sketch writes for a value, used only where no formula of the vocabulary fits: numbers, the
 * screen's own names, + - * / %, parentheses and a few of std/math. Parsed here rather than by the compiler,
 * so that nothing else -- no call, no state, no other name -- can get in, and so that its worked example can
 * be checked before the screen is built.
 */
class ExprNode {
  kind: string = 'num'
  value: number = 0
  name: string = ''
  op: string = ''
  args: ExprNode[] = []
}

class ParsedExpr {
  node: ExprNode | null = null
  error: string = ''
  /** The names it reads, each once. */
  reads: string[] = []
}

/** std/math functions a formula may use, with how many arguments each takes. */
const EXPR_FUNCTIONS: Map<string, number> = new Map<string, number>([['floor', 1], ['ceil', 1], ['round', 1], ['abs', 1],
  ['sqrt', 1], ['min', 2], ['max', 2], ['pow', 2]])
const MAX_FORMULA: number = 300
const COMPARISONS: string[] = ['<', '<=', '>', '>=', '==', '!=', '===', '!==']

function exprTokens(text: string): string[] {
  let out: string[] = []
  let i = 0
  while (i < text.length) {
    let c = text.charAt(i)
    if (c === ' ' || c === '\t') { i++; continue }
    let m = text.substring(i).match(/^(\d+(\.\d+)?|\.\d+|[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?|===|!==|<=|>=|==|!=|[-+*\/%(),<>])/)
    if (m === null) { return ['?' + c] }
    out.push(m[0])
    i += m[0].length
  }
  return out
}

export function parseFormula(text: string, known: string[]): ParsedExpr {
  let result = new ParsedExpr()
  if (text.length === 0 || text.length > MAX_FORMULA) { result.error = text.length === 0 ? 'no formula' : 'too long'; return result }
  let tokens = exprTokens(text)
  let at = 0
  let fail = (why: string): ExprNode => {
    if (result.error.length === 0) { result.error = why }
    return new ExprNode()
  }
  let peek = (): string => at < tokens.length ? tokens[at] : ''
  let binary = (op: string, a: ExprNode, b: ExprNode): ExprNode => {
    let n = new ExprNode()
    n.kind = 'bin'
    n.op = op
    n.args = [a, b]
    return n
  }
  // One comparison, worth 1 when it holds and 0 when not ("ready" is remaining <= 0); it does not chain.
  let comparison = (): ExprNode => {
    let left = expression()
    let t = peek()
    if (COMPARISONS.indexOf(t) < 0) { return left }
    at++
    let n = binary(t === '===' ? '==' : (t === '!==' ? '!=' : t), left, expression())
    n.kind = 'cmp'
    if (COMPARISONS.indexOf(peek()) >= 0) { return fail('compares twice in a row') }
    return n
  }
  let expression = (): ExprNode => {
    let left = term()
    while (peek() === '+' || peek() === '-') { let op = tokens[at++]; left = binary(op, left, term()) }
    return left
  }
  let term = (): ExprNode => {
    let left = unary()
    while (peek() === '*' || peek() === '/' || peek() === '%') { let op = tokens[at++]; left = binary(op, left, unary()) }
    return left
  }
  let unary = (): ExprNode => {
    if (peek() === '-') {
      at++
      let n = new ExprNode()
      n.kind = 'neg'
      n.args = [unary()]
      return n
    }
    if (peek() === '+') { at++; return unary() }
    return primary()
  }
  let primary = (): ExprNode => {
    let t = peek()
    if (t.length === 0) { return fail('ends too soon') }
    at++
    if (t === '(') {
      let inner = comparison()
      if (peek() !== ')') { return fail('a ( without its )') }
      at++
      return inner
    }
    if (/^(\d|\.)/.test(t)) {
      let n = new ExprNode()
      n.value = Number(t)
      return n
    }
    if (/^[A-Za-z_]/.test(t)) {
      if (peek() === '(') {
        let name = t.replace(/^(math|Math)\./, '')
        let arity = EXPR_FUNCTIONS.get(name)
        if (arity === undefined) { return fail('uses ' + t + ', which a formula cannot') }
        at++
        let n = new ExprNode()
        n.kind = 'call'
        n.name = name
        if (peek() !== ')') {
          n.args.push(comparison())
          while (peek() === ',') { at++; n.args.push(comparison()) }
        }
        if (peek() !== ')') { return fail(t + '( without its )') }
        at++
        // min and max of more than two fold into pairs.
        if ((name === 'min' || name === 'max') && n.args.length > 2) {
          let folded = n.args[0]
          for (let k = 1; k < n.args.length; k++) {
            let pair = new ExprNode()
            pair.kind = 'call'
            pair.name = name
            pair.args = [folded, n.args[k]]
            folded = pair
          }
          return folded
        }
        if (n.args.length !== arity) { return fail(name + ' takes ' + arity.toString() + ' numbers') }
        return n
      }
      if (known.indexOf(t) < 0) { return fail('reads ' + t + ', which the screen does not have') }
      let n = new ExprNode()
      n.kind = 'id'
      n.name = t
      if (result.reads.indexOf(t) < 0) { result.reads.push(t) }
      return n
    }
    return fail('has ' + t.replace(/^\?/, '') + ' where a number belongs')
  }
  let node = comparison()
  if (result.error.length === 0 && at < tokens.length) { result.error = 'has ' + tokens[at].replace(/^\?/, '') + ' left over' }
  if (result.error.length === 0) { result.node = node }
  return result
}

/** The formula's number, names read from `env`; NaN when a name has no number. Division by 0 gives 0, as share() does. */
function evalFormula(n: ExprNode, env: Map<string, number>): number {
  if (n.kind === 'num') { return n.value }
  if (n.kind === 'id') { return env.get(n.name) ?? NaN }
  if (n.kind === 'neg') { return -evalFormula(n.args[0], env) }
  let a = evalFormula(n.args[0], env)
  let b = n.args.length > 1 ? evalFormula(n.args[1], env) : 0
  if (n.kind === 'cmp') {
    let holds = n.op === '<' ? a < b : n.op === '<=' ? a <= b : n.op === '>' ? a > b : n.op === '>=' ? a >= b :
      n.op === '==' ? a === b : a !== b
    return holds ? 1 : 0
  }
  if (n.kind === 'bin') {
    if (n.op === '+') { return a + b }
    if (n.op === '-') { return a - b }
    if (n.op === '*') { return a * b }
    if (n.op === '/') { return b === 0 ? 0 : a / b }
    return b === 0 ? 0 : a % b
  }
  if (n.name === 'floor') { return Math.floor(a) }
  if (n.name === 'ceil') { return Math.ceil(a) }
  if (n.name === 'round') { return Math.round(a) }
  if (n.name === 'abs') { return Math.abs(a) }
  if (n.name === 'sqrt') { return Math.sqrt(a) }
  if (n.name === 'min') { return Math.min(a, b) }
  if (n.name === 'max') { return Math.max(a, b) }
  return Math.pow(a, b)
}

/**
 * The unit of time a written formula gives, when it only adds, subtracts, rounds or picks among lengths of one
 * unit (a plain number goes with either): 'seconds', 'minutes', or '' for anything else -- a product or a
 * quotient may already be the conversion itself (remaining / 60).
 */
function writtenMeasure(n: ExprNode, operands: Operand[]): string {
  if (n.kind === 'num') { return 'any' }
  if (n.kind === 'id') {
    let o = operands.find((x: Operand): boolean => x.id === n.name)
    return o !== undefined && isTime(o.measure) ? o.measure : ''
  }
  let alike = n.kind === 'neg' || (n.kind === 'bin' && (n.op === '+' || n.op === '-')) ||
    (n.kind === 'call' && ['round', 'floor', 'ceil', 'abs', 'min', 'max'].indexOf(n.name) >= 0)
  if (!alike) { return '' }
  let unit = 'any'
  for (let a of n.args) {
    let m = writtenMeasure(a, operands)
    if (m === '' || (m !== 'any' && unit !== 'any' && m !== unit)) { return '' }
    if (m !== 'any') { unit = m }
  }
  return unit
}

/** The formula in VERA: the names are the view's locals, and division goes through share(). */
function formulaVera(n: ExprNode): string {
  if (n.kind === 'num') { return numberLiteral(n.value) }
  if (n.kind === 'id') { return n.name }
  if (n.kind === 'neg') { return '(0 - ' + formulaVera(n.args[0]) + ')' }
  if (n.kind === 'call') {
    let args: string[] = []
    for (let a of n.args) { args.push(formulaVera(a)) }
    return 'math.' + n.name + '(' + args.join(', ') + ')'
  }
  if (n.kind === 'cmp') {
    let op = n.op === '==' ? '===' : (n.op === '!=' ? '!==' : n.op)
    return 'whether(' + formulaVera(n.args[0]) + ' ' + op + ' ' + formulaVera(n.args[1]) + ')'
  }
  if (n.op === '/') { return 'share(' + formulaVera(n.args[0]) + ', ' + formulaVera(n.args[1]) + ')' }
  return '(' + formulaVera(n.args[0]) + ' ' + n.op + ' ' + formulaVera(n.args[1]) + ')'
}

const COMPARISON_WORDS: Map<string, string> = new Map<string, string>([['<', 'is less than'], ['<=', 'is at most'],
  ['>', 'is more than'], ['>=', 'is at least'], ['==', 'equals'], ['!=', 'differs from']])

/** The formula in words for Jev: each name as its shown label. */
function formulaWords(n: ExprNode, sketch: Sketch): string {
  if (n.kind === 'num') { return numberLiteral(n.value) }
  if (n.kind === 'id') { return '"' + partLabel(sketch, n.name) + '"' }
  if (n.kind === 'neg') { return '-' + formulaWords(n.args[0], sketch) }
  if (n.kind === 'call') {
    let args: string[] = []
    for (let a of n.args) { args.push(formulaWords(a, sketch)) }
    return n.name + '(' + args.join(', ') + ')'
  }
  if (n.kind === 'cmp') {
    return '(1 if ' + formulaWords(n.args[0], sketch) + ' ' + (COMPARISON_WORDS.get(n.op) ?? n.op) + ' ' +
      formulaWords(n.args[1], sketch) + ', else 0)'
  }
  let op = n.op === '*' ? 'x' : n.op
  return '(' + formulaWords(n.args[0], sketch) + ' ' + op + ' ' + formulaWords(n.args[1], sketch) + ')'
}

/** The label of an input, constant, value or part number, for a formula in words. */
function partLabel(sketch: Sketch, id: string): string {
  let own = labelOf(sketch, id)
  if (own.length > 0) { return own }
  for (let o of operandList(sketch, sketch.values.length)) { if (o.id === id) { return o.label } }
  return id
}

/** The names value number `index`'s formula may read: numeric inputs, constants, the values before it and the parts' numbers. */
function formulaNames(sketch: Sketch, index: number): string[] {
  let out: string[] = []
  for (let o of operandList(sketch, index)) { if (out.indexOf(o.id) < 0) { out.push(o.id) } }
  return out
}

// ---- The vocabulary Jev chooses from ----

class Formula {
  id: string
  operands: number
  describe: string
  constructor(id: string, operands: number, describe: string) {
    this.id = id
    this.operands = operands
    this.describe = describe
  }
}

/**
 * Formulas are never chosen apart from their operands: Jev answered "add a percent" and "the tip
 * amount" to two separate questions and the program added 75% instead of $75. As in json-render,
 * every option Jev sees is a complete recipe -- here an expression over named operands -- and only
 * the ones whose units fit are offered at all.
 */
const FORMULAS: Formula[] = [
  new Formula('copy', 1, 'exactly the first operand, unchanged'),
  new Formula('add', 2, 'the first operand plus the second'),
  new Formula('subtract', 2, 'the first operand minus the second'),
  new Formula('multiply', 2, 'the first operand times the second'),
  new Formula('divide', 2, 'the first operand divided by the second'),
  new Formula('divide_up', 2, 'the first operand divided by the second, rounded up to a whole number'),
  new Formula('percent_of', 2, 'the second operand percent of the first, i.e. first * second / 100'),
  new Formula('add_percent', 2, 'the first operand increased by the second operand percent, i.e. first * (1 + second / 100)'),
  new Formula('subtract_percent', 2, 'the first operand reduced by the second operand percent, i.e. first * (1 - second / 100)'),
  new Formula('round_up', 1, 'the first operand rounded up to a whole number'),
  new Formula('ratio_percent', 2, 'the first operand as a percent of the second, i.e. first / second * 100')
]

class Widget {
  id: string
  kinds: string[]
  describe: string
  constructor(id: string, kinds: string[], describe: string) {
    this.id = id
    this.kinds = kinds
    this.describe = describe
  }
}

const WIDGETS: Widget[] = [
  new Widget('typed_number', ['amount', 'count', 'percent'], 'a text field the person types a number into'),
  new Widget('stepper', ['count', 'percent'], 'a whole number set with - and + buttons, one step at a time'),
  new Widget('slider', ['percent', 'count', 'amount'], 'a slider across a range, for a percentage or a level'),
  new Widget('select', ['choice'], 'a drop-down of the named options'),
  new Widget('switch', ['toggle'], 'an on/off switch'),
  new Widget('text_field', ['text'], 'a text field for words'),
  new Widget('time_field', ['time'], 'a time picker for a time of day')
]

/**
 * One argument of an effect, filled from the screen: a list field of the new entry, an input, a constant,
 * or one of the fixed choices its kind offers. text and toggle go under `key`; a time of day goes as
 * hour and minute; minutes go as a whole number.
 */
class EffectParam {
  name: string
  kind: string
  key: string
  describe: string
  constructor(name: string, kind: string, key: string, describe: string) {
    this.name = name
    this.kind = kind
    this.key = key
    this.describe = describe
  }
}

class Effect {
  id: string
  describe: string
  target: string
  fixed: string[]
  params: EffectParam[]
  /** What an entry shows once the phone answers without an error; '' for an effect whose answer is not shown on an entry. */
  done: string
  /** sdk.call's mode for an intent target ("foreground"), '' for none. */
  mode: string
  /** The label of the button that does it, on the screen or on an entry. */
  button: string
  constructor(id: string, describe: string, target: string, fixed: string[], params: EffectParam[], done: string,
      mode: string = '', button: string = 'Go') {
    this.id = id
    this.describe = describe
    this.target = target
    this.fixed = fixed
    this.params = params
    this.done = done
    this.mode = mode
    this.button = button
  }
}

const EFFECTS: Effect[] = [
  new Effect('vibrate', 'vibrate the phone', 'SensorServiceKit.vibrator.vibrate', ['duration', '2000'], [], ''),
  // The platform tone generator (VeraSdkBackend's TonePlayer adapter): a short tone that plays out by itself.
  new Effect('beep', 'play a short alert sound', 'AudioKit.TonePlayer.start', ['type', 'DOUBLE_BEEP'], [], ''),
  // VeraCalendarSdk's flat addEvent: today at hour:minute, an hour long; it answers with the event's ID.
  new Effect('calendar_add', 'add an event to the phone\'s calendar at a time of day, with a title, a reminder and, if wanted, a daily repeat',
    'CalendarKit.Calendar.addEvent', [], [
      new EffectParam('title', 'text', 'title', 'the title of the calendar event'),
      new EffectParam('time', 'clock', '', 'the time of day the event starts'),
      new EffectParam('repeat', 'toggle', 'repeat', 'whether the event repeats every day'),
      new EffectParam('remind', 'minutes', 'remindBefore', 'how many minutes before the start the phone reminds')
    ], 'In the calendar', '', 'Add to calendar'),
  // VeraIntentCatalog's probed navigateTo: Petal Maps' StartNavigate to a place by name and, when known, coordinates.
  // Its start point is not honoured (it routes from where the phone is), so none is offered.
  new Effect('navigate', 'start navigation in the maps app to a place, given its name and, if known, its latitude and longitude',
    'com.huawei.hmos.maps.app/entry/EntryAbility/StartNavigate', ['trafficType', 'Drive'], [
      new EffectParam('place', 'text', 'dstLocation.locationName', 'the name of the place to go to'),
      new EffectParam('latitude', 'number', 'dstLocation.latitude', 'the latitude of the place to go to'),
      new EffectParam('longitude', 'number', 'dstLocation.longitude', 'the longitude of the place to go to')
    ], '', 'foreground', 'Navigate'),
  // deleteEvents takes the IDs addEvent answered with; the program keeps them (calendarIds) when it adds and clears.
  new Effect('calendar_clear', 'delete every calendar event this app added', 'CalendarKit.Calendar.deleteEvents', [], [], '', '',
    'Clear calendar'),
  // A plain launch of the calendar app (VeraIntentCatalog's probed openCalendar): nothing to tell it.
  new Effect('calendar_open', 'open the phone\'s calendar app', 'com.huawei.hmos.calendar/phone/MainAbility', [], [], '', '',
    'Open calendar')
]

/** The "none of these" of an argument, saying what it means for that kind, so a fixed choice is not passed over. */
const OTHER_SOURCE: Map<string, string> = new Map<string, string>([
  ['text', 'some other title, which none of these gives'],
  ['clock', 'some other time of day, which none of these gives'],
  ['toggle', 'some repeat other than once or every day'],
  ['minutes', 'a number of minutes that none of these holds'],
  ['number', 'some other number, which none of these gives']])

function effectOf(id: string): Effect | undefined {
  return EFFECTS.find((x: Effect): boolean => x.id === id)
}

/**
 * Where an effect's argument can come from, keyed entry.<field>, input.<id>, const.<id> or fixed.<choice>.
 * Only sources whose kind fits are offered, as with a formula's operands.
 */
function paramSources(sketch: Sketch, p: EffectParam): Map<string, string> {
  let m: Map<string, string> = new Map<string, string>()
  let numeric = (kind: string): boolean => kind !== 'text' && kind !== 'toggle' && kind !== 'time' && kind !== 'choice'
  let fits = (kind: string, measure: string): boolean =>
    (p.kind === 'text' && kind === 'text') || (p.kind === 'clock' && kind === 'time') || (p.kind === 'toggle' && kind === 'toggle') ||
      (p.kind === 'minutes' && numeric(kind) && isTime(measure)) || (p.kind === 'number' && numeric(kind) && !isTime(measure))
  let phrase = (what: string): string => p.kind === 'toggle' ? 'every day when ' + what + ' is on, once when it is off' : what
  if (sketch.list !== null) {
    for (let f of sketch.list.fields) {
      if (fits(f.kind, f.measure)) { m.set('entry.' + f.id, phrase('the entry\'s "' + f.label + '" (the one just added, or the one whose button was tapped)')) }
    }
  }
  for (let input of sketch.inputs) {
    if (fits(input.kind, input.measure)) { m.set('input.' + input.id, phrase('"' + input.label + '" as set on the screen')) }
  }
  for (let c of sketch.constants) {
    if (p.kind === 'minutes' && isTime(c.measure)) { m.set('const.' + c.id, 'the fixed ' + c.label + ', ' + numberLiteral(c.value) + ' ' + c.measure) }
    if (p.kind === 'number' && !isTime(c.measure)) { m.set('const.' + c.id, 'the fixed ' + c.label + ', ' + numberLiteral(c.value)) }
  }
  if (p.kind === 'number') { m.set('fixed.blank', 'left out: not known, so the app goes by the other details') }
  if (p.kind === 'text') { m.set('fixed.title', 'the app\'s title, "' + sketch.title + '"') }
  if (p.kind === 'toggle') {
    m.set('fixed.once', 'once, never repeating: what an event is when the request does not ask for a repeat')
    m.set('fixed.daily', 'every day, always: the request asks for every event to repeat daily')
  }
  // A constant of 0 minutes is the same answer as fixed.zero: offering both would split Jev's confidence between them.
  let zeroConstant = sketch.constants.some((c: SketchConstant): boolean => isTime(c.measure) && c.value === 0)
  if (p.kind === 'minutes' && !zeroConstant) {
    m.set('fixed.zero', '0: an alert right at the start time, which is what a reminder with no lead time named means, ' +
      'also when the event itself is the reminder')
  }
  if (p.kind === 'minutes') {
    m.set('fixed.none', 'no alert: the request asks for neither a reminder nor an alert')
  }
  return m
}

/** The moments an effect can happen at, each offered only when the screen has the part that makes it. */
function momentsOf(sketch: Sketch): Map<string, string> {
  let m: Map<string, string> = new Map<string, string>()
  if (sketch.hasCountdown) { m.set('countdown_end', 'when the countdown reaches zero') }
  if (sketch.list !== null) { m.set('entry_added', 'right after the person adds an entry to the list') }
  if (sketch.list !== null) { m.set('row_button', 'when the person taps its button on one entry of the list, for that entry') }
  m.set('button', 'when the person taps a button for it on the screen')
  return m
}

/** The moments a person's tap starts, each with a handler of its own: do_<event> on the screen, row_<event> on an entry. */
function tapMoment(moment: string): boolean { return moment === 'button' || moment === 'row_button' }

const SHOWS: string[] = ['stat', 'hero', 'progress']

function describeInput(input: SketchInput): string {
  if (input.kind === 'choice') {
    let parts: string[] = []
    for (let o of input.options) { parts.push(o.label + ' = ' + o.value.toString()) }
    return 'input "' + input.label + '": the number of the chosen option (' + parts.join(', ') + ')'
  }
  if (input.kind === 'time') { return 'input "' + input.label + '" (a time of day)' }
  return 'input "' + input.label + '" (' + input.kind + (input.unit.length > 0 ? ', ' + input.unit : '') + ')'
}

class Operand {
  id: string
  label: string
  measure: string
  constructor(id: string, label: string, measure: string) {
    this.id = id
    this.label = label
    this.measure = measure
  }
}

/**
 * The values a countdown's length is made of, found from the sketch's own formulas starting at the one it names: they are worked out
 * before the clock runs, so none of them may read the clock (a round length taken as the countdown's duration over the rounds, for a
 * countdown whose duration is the rounds' total).
 */
function lengthFeeders(sketch: Sketch): string[] {
  let out: string[] = []
  let todo: string[] = [sketch.countdownLength]
  while (todo.length > 0) {
    let id = todo.pop()!
    let v = sketch.values.find((x: SketchValue): boolean => x.id === id)
    if (v === undefined || out.indexOf(id) >= 0) { continue }
    out.push(id)
    let words: string[] = v.formula.split(/[^A-Za-z0-9_]+/)
    for (let other of sketch.values) {
      if (other.id !== id && words.indexOf(other.id) >= 0) { todo.push(other.id) }
    }
  }
  return out
}

function operandList(sketch: Sketch, index: number): Operand[] {
  let out: Operand[] = []
  // Live figures first: a product is offered as money times a count (resultMeasure), and the price is the money.
  for (let l of sketch.live) { out.push(new Operand(l.id, l.label + ' (fetched from the internet as it is now)', l.measure)) }
  for (let input of sketch.inputs) {
    if (isNumeric(input.kind)) { out.push(new Operand(input.id, input.label, input.measure)) }
  }
  for (let c of sketch.constants) { out.push(new Operand(c.id, c.label + ' (fixed: ' + numberLiteral(c.value) + ')', c.measure)) }
  for (let i = 0; i < index; i++) {
    let v = sketch.values[i]
    out.push(new Operand(v.id, v.label, v.format === 'plain' ? 'number' : v.format))
  }
  let feedsClock = index < sketch.values.length && lengthFeeders(sketch).indexOf(sketch.values[index].id) >= 0
  if (sketch.hasCountdown && !feedsClock) {
    out.push(new Operand('remaining', 'seconds left on the countdown', 'seconds'))
    out.push(new Operand('elapsed', 'seconds passed on the countdown', 'seconds'))
    out.push(new Operand('duration', 'whole length of the countdown', 'seconds'))
  }
  if (sketch.hasStopwatch) { out.push(new Operand('elapsed', 'seconds passed on the stopwatch', 'seconds')) }
  if (sketch.list !== null) {
    out.push(new Operand('entryCount', 'how many ' + sketch.list.label + ' there are', 'count'))
    let numberField = firstField(sketch.list, 'number')
    if (numberField !== null) {
      out.push(new Operand('entryTotal', numberField.label + ' of all ' + sketch.list.label + ' added up', numberField.measure))
    }
  }
  return out
}

/** What `formula` over a and b measures, or '' when their units do not fit it. */
function resultMeasure(formula: string, a: Operand, b: Operand | null): string {
  let scalar = (m: string): boolean => m === 'count' || m === 'number'
  if (formula === 'copy') { return a.measure }
  // A time of day is shown as it is; adding to it or scaling it is not offered.
  if (a.measure === 'clock' || (b !== null && b.measure === 'clock')) { return '' }
  // Rounding a plain number up makes a whole count of things; rounded money is still money.
  if (formula === 'round_up') { return a.measure === 'number' || a.measure === 'fraction' ? 'count' : a.measure }
  // A value times itself is a square; any other formula of an operand with itself is not worth offering.
  if (b === null || (a.id === b.id && formula !== 'multiply')) { return '' }
  if (formula === 'add' || formula === 'subtract') { return a.measure === b.measure && a.measure !== 'percent' ? a.measure : '' }
  if (formula === 'multiply') { return scalar(b.measure) && a.measure !== 'percent' ? a.measure : '' }
  if (formula === 'divide') {
    if (scalar(b.measure)) { return a.measure }
    return a.measure === b.measure ? 'fraction' : ''
  }
  if (formula === 'divide_up') {
    let d = resultMeasure('divide', a, b)
    return d === 'number' || d === 'fraction' || d === 'count' ? 'count' : d
  }
  if (formula === 'ratio_percent') { return a.measure === b.measure ? 'percent' : '' }
  if (formula === 'percent_of' || formula === 'add_percent' || formula === 'subtract_percent') {
    return b.measure === 'percent' && a.measure !== 'percent' ? a.measure : ''
  }
  return ''
}

function expressionText(formula: string, a: Operand, b: Operand | null): string {
  let bl = b !== null ? b.label : ''
  if (formula === 'copy') { return a.label + ', as it is' }
  if (formula === 'round_up') { return a.label + ', rounded up to a whole number' }
  if (formula === 'add') { return a.label + ' + ' + bl }
  if (formula === 'subtract') { return a.label + ' - ' + bl }
  if (formula === 'multiply') { return b !== null && b.id === a.id ? a.label + ' squared' : a.label + ' x ' + bl }
  if (formula === 'divide') { return a.label + ' / ' + bl }
  if (formula === 'divide_up') { return a.label + ' / ' + bl + ', rounded up to a whole number' }
  if (formula === 'percent_of') { return bl + ' percent of ' + a.label }
  if (formula === 'subtract_percent') { return a.label + ' reduced by ' + bl + ' percent' }
  if (formula === 'ratio_percent') { return a.label + ' as a percent of ' + bl }
  return a.label + ' increased by ' + bl + ' percent'
}

/**
 * Whether a result measured `m` can be a value of format `format`. A plain value is a number that is
 * not money, a percent or a time; a fraction is any ratio of two like amounts (steps out of a goal).
 */
function fitsFormat(m: string, format: string, formula: string, a: Operand, b: Operand | null): boolean {
  if (m.length === 0) { return false }
  if (format === 'plain') { return m === 'number' || m === 'fraction' || (m === 'count' && formula !== 'round_up' && formula !== 'divide_up') }
  if (format === 'fraction' && formula === 'divide' && b !== null && a.id !== b.id && a.measure === b.measure) { return true }
  // A time in either unit can be a time value: the binding converts it to the value's own unit.
  if (isTime(format) && isTime(m)) { return true }
  return m === format
}

/** Says so when the composer turns a time in one unit into the value's other unit. */
function converted(m: string, format: string): string {
  return isTime(m) && isTime(format) && m !== format ? ', turned from ' + m + ' into ' + format : ''
}

/** The formulas whose operands can swap without changing the result: each pair is offered once. */
const COMMUTATIVE: string[] = ['add', 'multiply']

/** Every unit-consistent expression for value number `index`, keyed "formula:a:b". */
export function expressionsFor(sketch: Sketch, index: number): Map<string, string> {
  let v = sketch.values[index]
  let operands = operandList(sketch, index)
  let out: Map<string, string> = new Map<string, string>()
  for (let f of FORMULAS) {
    for (let ai = 0; ai < operands.length; ai++) {
      let a = operands[ai]
      if (f.operands === 1) {
        let m = resultMeasure(f.id, a, null)
        if (fitsFormat(m, v.format, f.id, a, null)) { out.set(f.id + ':' + a.id + ':', expressionText(f.id, a, null) + converted(m, v.format)) }
        continue
      }
      for (let bi = COMMUTATIVE.indexOf(f.id) >= 0 ? ai : 0; bi < operands.length; bi++) {
        let b = operands[bi]
        // The countdown's length less its time passed is its time left, already offered as such; two names for
        // one number split Jev's answer between them.
        if (f.id === 'subtract' && a.id === 'duration' && (b.id === 'elapsed' || b.id === 'remaining')) { continue }
        let m = resultMeasure(f.id, a, b)
        if (fitsFormat(m, v.format, f.id, a, b)) { out.set(f.id + ':' + a.id + ':' + b.id, expressionText(f.id, a, b) + converted(m, v.format)) }
      }
    }
  }
  return out
}

/**
 * A number the screen needs that nothing works out, as an input the person sets instead, starting from `value`: the
 * plan's own guess when it gave one. It takes `id` as it is, so whatever reads that name reads the input.
 */
function defaultInput(comp: Composition, id: string, label: string, measure: string, value: number): SketchInput {
  let input = new SketchInput()
  input.id = id
  input.label = label
  input.kind = measure === 'money' ? 'amount' : (measure === 'percent' ? 'percent' : 'count')
  input.measure = measure
  input.value = isFinite(value) ? value : 0
  input.min = measure === 'minutes' || measure === 'seconds' ? 1 : 0
  input.max = Math.max(100, Math.ceil(Math.abs(input.value) * 4))
  // The inputs of the sketch and of the composition's copy of it are one list.
  comp.sketch.inputs.push(input)
  comp.widgets.set(id, defaultWidget(input.kind))
  comp.defaulted.push(label + ': set by you, starting at ' + numberLiteral(input.value) + (measure === 'minutes' ||
    measure === 'seconds' ? ' ' + measure : ''))
  return input
}

/** Every name the sketch already uses, so a name made for it is new. */
function sketchIds(sketch: Sketch): string[] {
  let ids: string[] = RESERVED_IDS.slice()
  for (let i of sketch.inputs) { ids.push(i.id) }
  for (let k of sketch.constants) { ids.push(k.id) }
  for (let v of sketch.values) { ids.push(v.id) }
  if (sketch.list !== null) { for (let f of sketch.list!.fields) { ids.push(f.id) } }
  return ids
}

/** The starting number of an input, a constant or a value's worked example, NaN when there is none. */
function startingNumber(sketch: Sketch, source: string): number {
  let id = source.substring(source.indexOf('.') + 1)
  let input = sketch.inputs.find((i: SketchInput): boolean => i.id === id)
  // A choice's own value is its option's position; its numbers are the options'.
  if (input !== undefined && input.options.length > 0) {
    let most = input.options[0].value
    for (let o of input.options) { most = Math.max(most, o.value) }
    return most
  }
  if (input !== undefined) { return input.value }
  let k = sketch.constants.find((c: SketchConstant): boolean => c.id === id)
  if (k !== undefined) { return k.value }
  let v = sketch.values.find((x: SketchValue): boolean => x.id === id)
  return v !== undefined ? v.result : NaN
}

function copyOf(m: Map<string, string>): Map<string, string> {
  let out: Map<string, string> = new Map<string, string>()
  m.forEach((v: string, k: string) => { out.set(k, v) })
  return out
}

/** The plan's own questions to the person, as one sentence for a question to Jev; '' when it asked none. */
function planQuestions(sketch: Sketch): string {
  if (sketch.questions.length === 0) { return '' }
  return ' The plan also asked the person: ' + sketch.questions.map((q: SketchQuestion): string =>
    '"' + q.ask + '" (' + q.options.join(' / ') + ')').join('; ') + '.'
}

export function choice(instructions: string, criteria: Map<string, string>): Record<string, Object> {
  let c: Record<string, Object> = {}
  criteria.forEach((describe: string, key: string) => { c[key] = describe })
  let q: Record<string, Object> = {}
  q['type'] = 'choice'
  q['instructions'] = instructions
  q['criteria'] = c
  return q
}

const FIELD_WORDS: Map<string, string> = new Map<string, string>([['text', 'words'], ['number', 'a number'],
  ['time', 'a time of day'], ['toggle', 'on/off']])

function describeList(l: SketchList): string {
  let fields: string[] = []
  for (let f of l.fields) { fields.push('"' + f.label + '" (' + (FIELD_WORDS.get(f.kind) ?? f.kind) + ')') }
  let adding = fields.length > 0 ? 'the person fills in ' + fields.join(', ') + ' and adds an entry' : 'each tap on Add adds an entry'
  return 'a list of ' + l.label + ': ' + adding + '; each entry shows what was filled in and the time it was added, ' +
    'shows what the phone answered when the phone does something as it is added, and can be removed'
}

/** A number field's label with what it counts in, when the label does not say: "Timer length" is in seconds, so "Timer length (seconds)". */
function labelWithUnit(input: SketchInput): string {
  let unit = input.measure === 'seconds' || input.measure === 'minutes' ? input.measure : input.unit.trim()
  if (unit.length === 0 || input.label.toLowerCase().indexOf(unit.toLowerCase()) >= 0) { return input.label }
  return input.label + ' (' + unit + ')'
}

/** The whole number a label starts with ("25 minutes" is 25); 0 when it does not start with one. */
function leadingNumber(label: string): number {
  let digits = ''
  for (let i = 0; i < label.length; i++) {
    let c = label.charCodeAt(i)
    if (c >= 48 && c <= 57) { digits += label.charAt(i) } else if (digits.length > 0 || c !== 32) { break }
  }
  return digits.length > 0 ? parseInt(digits) : 0
}

/** Whether a stopwatch's list is its laps: the list or the stopwatch is named for laps, splits or rounds. */
function isLapList(sketch: Sketch): boolean {
  if (!sketch.hasStopwatch || sketch.list === null) { return false }
  // Whole words: "Elapsed time" is no lap.
  let words = (sketch.list!.label + ' ' + sketch.stopwatch).toLowerCase().split(' ')
  return words.some((w: string): boolean => ['lap', 'laps', 'split', 'splits', 'round', 'rounds'].indexOf(w.trim()) >= 0)
}

/** A laps list has words ("Lap 3") and the time passed to hold, whatever fields the sketch gave it. */
function ensureLapFields(sketch: Sketch): void {
  if (!isLapList(sketch)) { return }
  let list = sketch.list!
  if (firstField(list, 'text') === null) {
    let f = new ListField()
    f.id = 'lap'; f.label = 'Lap'; f.kind = 'text'
    list.fields.unshift(f)
  }
  // The first number is the time passed when the lap was taken, the second what that lap took.
  let numbers = list.fields.filter((f: ListField): boolean => f.kind === 'number')
  if (numbers.length === 0) {
    let f = new ListField()
    f.id = 'seconds'; f.label = 'Total'; f.kind = 'number'; f.measure = 'seconds'
    list.fields.push(f)
  }
  if (numbers.length < 2 && list.fields.length < MAX_FIELDS) {
    let f = new ListField()
    f.id = 'split'; f.label = 'Split'; f.kind = 'number'; f.measure = 'seconds'
    list.fields.push(f)
  }
}

/**
 * Whether the stopwatch records laps into the list: its Lap button adds an entry with the time passed, and the list has no form to type
 * one in. Not when an event answers an entry (that is the list's own use of its entries).
 */
function hasLaps(comp: Composition): boolean {
  return isLapList(comp.sketch) && entryAnswerEvent(comp).length === 0
}

/**
 * Whether an input nothing else reads stays for the section the model writes. When a section of the catalogue took the list, its own form
 * is where entries are made: an input the sketch had beside the list only repeats it, unless a need of the section's own names it. The
 * needs "shows ..." are what the section left behind and read no input.
 */
function keptForCustom(comp: Composition, input: SketchInput): boolean {
  let label = input.label.toLowerCase()
  let named = comp.custom.some((need: string): boolean => !need.startsWith('shows ') && need.toLowerCase().indexOf(label) >= 0)
  if (named) { return true }
  // Beside a list part, an input that shares a word with one of the list's own fields ("Mood scale" and "Mood") is that field again.
  // A choice or a number is a number field again; a switch, a time or words are not.
  if (comp.sketch.list !== null && (input.kind === 'choice' || isNumeric(input.kind))) {
    let words = wordsOf(input.label)
    for (let f of comp.sketch.list!.fields) {
      if (f.kind === 'number' && wordsOf(f.label).some((w: string): boolean => words.indexOf(w) >= 0)) { return false }
    }
  }
  return comp.replaced.every((r: Replaced): boolean => LIST_SECTIONS.indexOf(r.kind) < 0)
}

/** The lower-case words of three letters or more in a label. */
function wordsOf(text: string): string[] {
  return text.toLowerCase().split(' ').map((w: string): string => w.trim()).filter((w: string): boolean => w.length >= 3)
}

function isTime(measure: string): boolean { return measure === 'seconds' || measure === 'minutes' }

/**
 * A number the person sets in hours: the plan writes one as measure number with "hours" in its unit (NeedsPlan.ets), since
 * seconds and minutes are the only time measures. It can be what a countdown runs for ("5 hours" became a 5-minute timer beside
 * an unused "Fly duration" in hours: nothing took it as the length, and the fallback length is 5 minutes).
 */
function inHours(input: SketchInput): boolean {
  return isNumeric(input.kind) && input.measure === 'number' && /^\s*(h|hrs?|hours?)\s*$/i.test(input.unit)
}

/** What a countdown's length is counted in: seconds, minutes, or hours for an input in hours (inHours). */
function lengthUnitOf(sketch: Sketch, id: string): string {
  for (let i of sketch.inputs) { if (i.id === id && inHours(i)) { return 'hours' } }
  return measureOf(sketch, id)
}

const TIME_UNITS: Map<string, string> = new Map<string, string>([['seconds', 'a number of seconds'], ['minutes', 'a number of minutes'],
  ['neither', 'not a length of time']])

/** A choice not marked as a time, whose numbers might still be lengths: not money, not a percent. */
function isLengthChoice(input: SketchInput): boolean {
  return input.kind === 'choice' && !isTime(input.measure) && input.measure !== 'money' && input.measure !== 'percent'
}

function unitQuestion(label: string, numbers: string): string {
  return 'Going by the request and these labels, is the number of "' + label + '" (' + numbers + ') a number of seconds or of minutes?'
}

/** An input's numbers as the person sees them: each option's label beside its number, or the range and unit. */
function numbersOf(input: SketchInput): string {
  if (input.kind === 'choice') {
    let parts: string[] = []
    for (let o of input.options) { parts.push(o.label + ' = ' + numberLiteral(o.value)) }
    return parts.join(', ')
  }
  return numberLiteral(input.min) + ' to ' + numberLiteral(input.max) + ', starting at ' + numberLiteral(input.value) +
    (input.unit.length > 0 ? ', unit ' + input.unit : '')
}

/** What the input, constant or value `id` measures, '' when it is none of them. */
function measureOf(sketch: Sketch, id: string): string {
  for (let i of sketch.inputs) { if (i.id === id) { return i.measure } }
  for (let c of sketch.constants) { if (c.id === id) { return c.measure } }
  for (let v of sketch.values) { if (v.id === id) { return v.format } }
  return ''
}

/**
 * The sources a countdown's length can come from: inputs, constants and values measured in seconds or minutes. Units are
 * checked here as for formulas: Jev once ran a tea timer from the tea type's option number, 0 to 2.
 */
function lengthSources(sketch: Sketch): Map<string, string> {
  let sources: Map<string, string> = new Map<string, string>()
  for (let input of sketch.inputs) {
    if (isNumeric(input.kind) && isTime(input.measure)) { sources.set(input.id, describeInput(input) + ', in ' + input.measure) }
    else if (inHours(input)) { sources.set(input.id, describeInput(input) + ', in hours') }
    // A choice's numbers are offered whatever measure the sketch wrote: its labels say what they are, and the
    // unit question reads them (a tea timer's 120 / 180 / 300 came marked as a count).
    else if (isLengthChoice(input)) { sources.set(input.id, describeInput(input)) }
  }
  for (let c of sketch.constants) {
    // A fixed length of nothing is never what a countdown runs for.
    if (isTime(c.measure) && c.value > 0) { sources.set(c.id, 'the fixed ' + c.label + ', ' + numberLiteral(c.value) + ' ' + c.measure) }
  }
  for (let v of sketch.values) {
    if (isTime(v.format)) { sources.set(v.id, 'the worked-out "' + v.label + '": ' + v.means + ', in ' + v.format) }
  }
  return sources
}

/** Every name `id` is worked out from, itself included, following the chosen formulas back to inputs. */
function dependsOn(comp: Composition, id: string): string[] {
  let out: string[] = []
  let todo: string[] = [id]
  while (todo.length > 0) {
    let next = todo.pop()!
    if (next.length === 0 || out.indexOf(next) >= 0) { continue }
    out.push(next)
    let b = comp.bindings.get(next)
    if (b !== undefined) {
      todo.push(b.a)
      todo.push(b.b)
      for (let name of b.reads) { todo.push(name) }
    }
  }
  return out
}

const CLOCK_OPERANDS: string[] = ['remaining', 'elapsed', 'duration']

/**
 * What each part on the screen provides, for asking Jev whether an item of the sketch's "other" is
 * one of them after all. Each option is a part this screen actually has, described by what it does.
 */
function partsOf(sketch: Sketch): Map<string, string> {
  let parts: Map<string, string> = new Map<string, string>()
  // Each control an input can have, and a fraction's bar, as a part of its own: an item that names one
  // ("a slider for the tip", "a progress bar toward the goal") is that part, and choosing it draws it so.
  for (let input of sketch.inputs) {
    for (let w of WIDGETS) {
      if (w.kinds.indexOf(input.kind) >= 0) { parts.set('widget.' + input.id + '.' + w.id, w.describe + ', for "' + input.label + '"') }
    }
  }
  for (let v of sketch.values) {
    parts.set('value.' + v.id, 'the figure "' + v.label + '", shown as a number: ' + v.means)
    if (v.format === 'fraction') { parts.set('bar.' + v.id, 'a progress bar that fills as "' + v.label + '" goes from 0 to 1: ' + v.means) }
  }
  // As drawn: the time as minutes and seconds (1:05:00 past an hour), ticking each second, and its three buttons.
  if (sketch.hasCountdown) {
    parts.set('countdown', 'the countdown: the time left, shown as minutes and seconds such as 5:30 and counting down each ' +
      'second, with Start, Stop and Reset buttons')
  }
  if (sketch.hasStopwatch) {
    parts.set('stopwatch', 'the stopwatch: the time passed, shown as minutes and seconds such as 5:30 and counting up each ' +
      'second, with Start, Stop and Reset buttons')
  }
  if (sketch.list !== null) { parts.set('list', describeList(sketch.list)) }
  // The figures as rows, with the fixed numbers they come from: what "a table of bill, tip and total" asks for.
  if (sketch.values.length > 0 && sketch.list === null) {
    parts.set('figures', 'a table or list of the figures, one row each: the fixed numbers they are worked out from, then ' +
      'each worked-out figure, with its label and its value')
  }
  for (let e of sketch.events) {
    if (e.asked) { parts.set('event.' + e.id, 'when ' + e.when + ', the phone will ' + e.what) }
  }
  parts.set('state', 'the app keeps everything between visits: what the person set or added is saved and is there when the app opens again')
  return parts
}

/** The shown label of an input, constant or value, '' when the id is none of them. */
function labelOf(sketch: Sketch, id: string): string {
  for (let i of sketch.inputs) { if (i.id === id) { return i.label } }
  for (let c of sketch.constants) { if (c.id === id) { return c.label } }
  for (let v of sketch.values) { if (v.id === id) { return v.label } }
  return ''
}

export function describeSketch(sketch: Sketch): string {
  let lines: string[] = []
  for (let input of sketch.inputs) { lines.push('- ' + describeInput(input)) }
  for (let c of sketch.constants) { lines.push('- fixed: ' + c.label + ' = ' + numberLiteral(c.value)) }
  for (let l of sketch.live) { lines.push('- shows "' + l.label + '" as it is now, fetched from the internet: ' + l.means) }
  if (sketch.hasCountdown) {
    let length = labelOf(sketch, sketch.countdownLength)
    lines.push('- a countdown: ' + sketch.countdown + (length.length > 0 ? ', as long as "' + length + '"' : ''))
  }
  if (sketch.hasStopwatch) { lines.push('- a stopwatch: ' + sketch.stopwatch) }
  if (sketch.list !== null) { lines.push('- ' + describeList(sketch.list)) }
  for (let v of sketch.values) { lines.push('- shows "' + v.label + '": ' + v.means) }
  for (let e of sketch.events) { lines.push('- when ' + e.when + ': ' + e.what) }
  for (let need of sketch.ready) { lines.push('- a ready-made section for: ' + need) }
  return lines.join('\n')
}

/**
 * Whether an item of a chat widget's description is what it must show or do, or a detail of its look. A table,
 * a chart or a picture of data is never a detail: left out, the widget would not show what was asked for.
 */
function detailQuestion(item: string): Record<string, Object> {
  let part: Map<string, string> = new Map<string, string>()
  part.set('core', 'something the widget must work out, show, keep or do for the request to be served: a figure, a table, ' +
    'a chart or picture of data, a list, a timer, a game, a phone action, data from outside the phone, or what a button does ' +
    'when that is more than calculating, resetting or clearing (choosing at random, playing, sending)')
  part.set('detail', 'a detail of how the widget looks or is worked: layout, labels, units, number formatting, a note, message ' +
    'or reference line, a validation message, a button that only calculates, resets or clears, or updating as inputs change')
  return choice('In a widget for this request, what is "' + item + '"?', part)
}

/** The Jev request: one independent choice per requirement in the sketch. */
/** The sections of the catalogue a countdown or stopwatch may be, and the part, as the options of one question; null for neither. */
export function clockOptions(sketch: Sketch): Map<string, string> | null {
  // The section counts down from one of a few set times; it has no stopwatch.
  if (!sketch.hasCountdown) { return null }
  let out: Map<string, string> = new Map<string, string>()
  out.set(PART, 'the app builds its own countdown from the numbers on the screen: start, stop and reset, a length that follows what ' +
    'the person sets, and phone actions at its end')
  for (let f of fragments()) { if (CLOCK_SECTIONS.indexOf(f.kind) >= 0) { out.set(f.kind, f.criteria) } }
  return out.size > 1 ? out : null
}

/** The sections a list the person fills in may be, and the part, as the options of one question; null when there is no list. */
export function listOptions(sketch: Sketch): Map<string, string> | null {
  if (sketch.list === null) { return null }
  let out: Map<string, string> = new Map<string, string>()
  out.set(PART, 'the app\'s own plain list: ' + describeList(sketch.list!) + '. Each entry is typed into a form of those fields and added ' +
    'with an Add button. The only figures it gives are how many entries there are ' +
    'and the sum of one number field; it has no total for each person or category, no chart of them and no settling up of who owes whom')
  for (let f of fragments()) {
    if (LIST_SECTIONS.indexOf(f.kind) < 0) { continue }
    // The readers of the catalogue show what the log publishes: the question says so, as the part's own limits are said.
    out.set(f.kind, f.kind === 'record_log' ? f.criteria + '. Readers of the catalogue add to it figures for each person or category ' +
      '(totals, an average, a balance), a bar chart of them and who should pay whom' : f.criteria)
  }
  return out.size > 1 ? out : null
}

/** What the screen is to show besides the list, in words, for the question about the list: the plan's values and other needs. */
export function listNeeds(sketch: Sketch): string {
  let needs: string[] = []
  for (let v of sketch.values) { needs.push(v.label + (v.means.length > 0 ? ' (' + v.means + ')' : '')) }
  for (let o of sketch.other) { needs.push(o) }
  for (let r of sketch.ready) { needs.push(r) }
  return needs.length === 0 ? '' : ' The screen also has to show or do: ' + needs.slice(0, 8).join('; ') + '.'
}

/**
 * The questions about the plan's ready needs: which section of the catalogue does each, whose data it shows, and whether the
 * sections' content has to come from a search. Nothing when the plan has none. (The needs plan asks them first, NeedsChoose.ets.)
 */
/**
 * Whether an item of the plan's "other" is something an itinerary already does, asked of each when the plan has content for a
 * section: whether one is chosen is decided in the same call, so the question that names the chosen section's own (within.other)
 * cannot say what an itinerary holds. Read only when the itinerary is chosen; without it the West Lake plan's "when to head back"
 * and "walking time between stops" were written again beside the itinerary, disagreeing with it ("Broken Bridge to Broken Bridge").
 */
export function askItinerary(sketch: Sketch, questions: Record<string, Object>): void {
  // Only where an itinerary could be the answer: a plan with content for a section and a time of day or a length of time in it.
  // Asked of every plan with ready needs, a habit tracker's six "other" items were six questions on every call (review of #46).
  if (sketch.ready.length === 0 || !hasTimes(sketch)) { return }
  let spec = fragments().find((f: FragmentSpec): boolean => f.kind === 'itinerary')
  if (spec === undefined) { return }
  let verdict: Map<string, string> = new Map<string, string>()
  verdict.set('yes', 'yes: an itinerary like that already does it')
  verdict.set('no', 'no: it is something more')
  for (let i = 0; i < sketch.other.length; i++) {
    if (isScene(sketch.other[i])) { continue }
    questions['itinerary.other.' + i.toString()] = choice('If the places were shown as an itinerary that already has ' + spec!.owns +
      ', would "' + sketch.other[i] + '" be part of that itinerary?', verdict)
  }
  // Each time of day or length of time the plan works out: the itinerary's own (a stop's time, when the day ends, how long it
  // takes, the minutes between stops) or not. "Time at the airport before boarding" is not, and does not leave with them (itineraryShows).
  let own: Map<string, string> = new Map<string, string>()
  // A total of the stops' own numbers is theirs too: "Total walking" and "Time at stops" stood above the stops as the plan's own
  // figures (1:30:00, 4:30:00), worked out from its inputs and not from the stops shown, so free to disagree with them.
  own.set('yes', 'yes: it is one of those, a stop of the day with its time, or a total or count of the stops, their lengths or the time between them')
  own.set('no', 'no: it is about something else than the stops (the time at an airport, daylight, a budget)')
  for (let v of sketch.values) {
    if (v.format !== 'clock' && v.format !== 'minutes') { continue }
    questions['itinerary.value.' + v.id] = choice('If the places were shown as an itinerary that already has ' + spec!.owns +
      ', would the figure "' + v.label + '" (' + v.means + ') be one of those?', own)
  }
}

/** Whether the plan has a time of day the person sets, or a time of day or a length of time it works out: what an itinerary is made of. */
function hasTimes(sketch: Sketch): boolean {
  return sketch.inputs.some((i: SketchInput): boolean => i.kind === 'time') ||
    sketch.values.some((v: SketchValue): boolean => v.format === 'clock' || v.format === 'minutes')
}

/**
 * Whether a time-of-day figure ends the plan's list of places or steps -- a flight to catch, a closing time. Asked for each when the
 * plan has content for a section; a section that reads "deadline" shows only what fits before it.
 */
export function askDeadline(sketch: Sketch, questions: Record<string, Object>): void {
  if (sketch.ready.length === 0) { return }
  // One yes or no for each: a pick among several is near chance when none of them is plainly the one.
  let verdict: Map<string, string> = new Map<string, string>()
  verdict.set('yes', 'yes: the places or steps have to be over by this time')
  verdict.set('no', 'no: it is some other time')
  for (let v of sketch.values) {
    if (v.format !== 'clock') { continue }
    questions['deadline.' + v.id] = choice('Is "' + v.label + '" (' + v.means + ') the time of day by which the list of places or steps ' +
      'has to be over (the latest time that a flight, a train or a closing time allows)?', verdict)
  }
}

/**
 * One yes or no for each live figure of the plan: whether it is a figure of the real world that changes by itself and the screen
 * fetches as it is now (the live_figure section), or not -- a fact that does not change, or a figure at a stated date. A yes or
 * no is asked, not a pick among the sections: a pick among many is near chance when none of them is plainly the one.
 */
export function askLive(sketch: Sketch, questions: Record<string, Object>): void {
  let verdict: Map<string, string> = new Map<string, string>()
  verdict.set('yes', 'yes: it changes by itself from hour to hour or day to day (a price, an exchange rate, the weather now, today\'s ' +
    'forecast, a live score), and the screen fetches it from the internet as it is now and keeps it up to date')
  verdict.set('no', 'no: it does not change, it is for a past date, or the person types it in')
  for (let i = 0; i < sketch.live.length; i++) {
    let l = sketch.live[i]
    questions['live.' + i.toString()] = choice('The app shows "' + l.label + '" (' + l.means + '). Is it a figure of the real world ' +
      'that the screen fetches as it is right now?', verdict)
  }
}

/** Above this, Jev's yes to a live figure is taken: a yes or no is reliable well above the cosmetic bar (INCLUDE_ABOVE). */
export const LIVE_ABOVE: number = 0.65

export function askReady(sketch: Sketch, questions: Record<string, Object>): void {
  if (sketch.ready.length === 0) { return }
  let sections: Map<string, string> = new Map<string, string>()
  for (let f of fragments()) { if (READY_KINDS.indexOf(f.kind) >= 0) { sections.set(f.kind, f.criteria) } }
  sections.set('none', 'none of these: it needs something none of these sections does')
  // A section's content is written for the request; the person's own records cannot be, however a plan words them.
  let whose: Map<string, string> = new Map<string, string>()
  whose.set('own', 'the person\'s own records: notes, entries, contacts, messages or files they keep, which nobody else could write')
  whose.set('written', 'facts, places, steps, figures or suggestions that anyone could look up or write for the request')
  for (let i = 0; i < sketch.ready.length; i++) {
    questions['ready.' + i.toString()] = choice('The request needs "' + sketch.ready[i] + '". Which of these sections does exactly that?', sections)
    questions['whose.' + i.toString()] = choice('What does "' + sketch.ready[i] + '" show?', whose)
  }
  // The catalogue's own question: whether the sections' content has to come from a search.
  let real = vetoes().find((v: VetoSpec): boolean => v.key === 'needs_real_data')!
  questions['real_data'] = choice(real.instructions, real.criteria)
}

/**
 * `settled` names questions that are not asked because something else answered them already (the needs plan's own choice of a
 * section or a part, NeedsChoose.ets); readComposition reads those answers from the body it is given.
 */
export function buildComposeRequest(prompt: string, sketch: Sketch, widget: boolean = false, settled: string[] = [],
    sections: Map<string, string> = new Map<string, string>()): string {
  let questions: Record<string, Object> = {}

  let theme: Map<string, string> = new Map<string, string>()
  theme.set('clean', 'restrained and neutral')
  theme.set('soft', 'calm and friendly')
  theme.set('expressive', 'bold and atmospheric')
  theme.set('technical', 'precise, for numbers and tools')
  theme.set('playful', 'light and fun')
  questions['theme'] = choice('Which overall look fits this app best?', theme)

  for (let input of sketch.inputs) {
    let widgets: Map<string, string> = new Map<string, string>()
    for (let w of WIDGETS) {
      if (w.kinds.indexOf(input.kind) >= 0) { widgets.set(w.id, w.describe) }
    }
    if (widgets.size > 1) {
      questions['widget.' + input.id] = choice('How should the person set "' + input.label + '"? Follow the request where it names a control.', widgets)
    }
    // Whether a number nothing turns out to read is the sketch's extra, or something the request wants
    // that the parts cannot use: only the request can tell, so Jev reads it rather than the sketch.
    if (isNumeric(input.kind)) {
      let asked: Map<string, string> = new Map<string, string>()
      asked.set('asked', 'the request asks for it or clearly needs it')
      asked.set('added', 'the request neither asks for it nor needs it')
      questions['asked.' + input.id] = choice('Does the request ask for the person to set "' + input.label + '"?' + planQuestions(sketch), asked)
    }
  }

  for (let i = 0; i < sketch.values.length; i++) {
    let v = sketch.values[i]
    // As for inputs: a figure the sketch added on its own is left out when nothing can work it out.
    let asked: Map<string, string> = new Map<string, string>()
    asked.set('asked', 'the request asks for it or clearly needs it')
    asked.set('added', 'the request neither asks for it nor needs it')
    questions['asked.value.' + v.id] = choice('Does the request ask to see "' + v.label + '" (' + v.means + ')?' + planQuestions(sketch), asked)
    // The sketch's own formula, in words, for when the vocabulary has none: Jev reads it against the request.
    let written = parseFormula(v.formula, formulaNames(sketch, i))
    if (written.node !== null) {
      let verdict: Map<string, string> = new Map<string, string>()
      verdict.set('right', 'yes: exactly that, with the right numbers, operations and units')
      verdict.set('wrong', 'no: it uses a wrong number, operation or unit, or works out something else')
      questions['written.' + v.id] = choice('Going by the request, is "' + v.label + '" (' + v.means + ') worked out as ' +
        formulaWords(written.node, sketch) + '?', verdict)
    }
    let expressions = expressionsFor(sketch, i)
    if (expressions.size === 0 || expressions.size >= MAX_CRITERIA) { continue }
    expressions.set('unavailable', 'none of these is exactly it: it takes another operation, more steps, or other numbers')
    questions['expr.' + v.id] = choice('Which of these is exactly how "' + v.label + '" (' + v.means + ') is worked out? ' +
      'One that is only part of the calculation is wrong.', expressions)
    // Asked apart from the pick: a value that takes several steps has no right option, and Jev then
    // picks the nearest one (a mortgage payment as loan x monthly rate, litres as distance / 100).
    let steps: Map<string, string> = new Map<string, string>()
    steps.set('one', 'one of those numbers as it is, or one step from them: two added, subtracted, multiplied or divided, ' +
      'a percent of one, one as a percent of another, one rounded up, or one divided by another and rounded up')
    steps.set('more', 'more than one step, or something other than arithmetic')
    let known: string[] = []
    for (let o of operandList(sketch, i)) { known.push(o.label) }
    questions['steps.' + v.id] = choice('The app already has these numbers: ' + known.join('; ') + '. Starting from them, ' +
      'how is "' + v.label + '" worked out: ' + v.means + '?', steps)
    let shows: Map<string, string> = new Map<string, string>()
    shows.set('stat', 'one figure among the others in a row of figures')
    shows.set('hero', 'the one big number the screen is about')
    shows.set('progress', 'a progress bar (the value is a fraction from 0 to 1)')
    questions['show.' + v.id] = choice('How should "' + v.label + '" be shown?', shows)
  }

  if (sketch.hasCountdown) {
    let sources = lengthSources(sketch)
    if (sources.size > 0) {
      questions['countdown.length'] = choice('What sets how many seconds the countdown "' + sketch.countdown + '" runs?', sources)
    }
    // The unit of a length the person or the sketch gives, read from its labels rather than taken from the
    // sketch's measure: a sketch once marked a choice of "1 minute = 60, 3 minutes = 180" as minutes.
    for (let input of sketch.inputs) {
      if (isNumeric(input.kind) && (isTime(input.measure) || isLengthChoice(input))) {
        questions['unit.' + input.id] = choice(unitQuestion(input.label, numbersOf(input)), TIME_UNITS)
      }
    }
    for (let c of sketch.constants) {
      if (isTime(c.measure)) { questions['unit.' + c.id] = choice(unitQuestion(c.label, 'fixed at ' + numberLiteral(c.value)), TIME_UNITS) }
    }
  }

  // As for inputs: a field the sketch added on its own is left out, when nothing reads it.
  if (sketch.list !== null) {
    for (let f of sketch.list.fields) {
      let asked: Map<string, string> = new Map<string, string>()
      asked.set('asked', 'the request asks for it or clearly needs it')
      asked.set('added', 'the request neither asks for it nor needs it')
      questions['asked.field.' + f.id] = choice('Does the request ask the person to fill in "' + f.label + '" for each entry of ' +
        sketch.list.label + '?' + planQuestions(sketch), asked)
    }
  }

  let moments = momentsOf(sketch)
  for (let e of sketch.events) {
    let effects: Map<string, string> = new Map<string, string>()
    for (let fx of EFFECTS) { effects.set(fx.id, fx.describe) }
    effects.set('unavailable', 'none of these')
    questions['effect.' + e.id] = choice('What should the phone do ' + e.when + ' ("' + e.what + '")?', effects)
    for (let fx of EFFECTS) {
      for (let prm of fx.params) {
        let sources = paramSources(sketch, prm)
        sources.set('unavailable', OTHER_SOURCE.get(prm.kind) ?? 'none of these')
        questions['arg.' + e.id + '.' + fx.id + '.' + prm.name] = choice('Suppose the phone is to ' + fx.describe + ', at the moment "' +
          e.when + '" ("' + e.what + '"). Going by the request, what gives ' + prm.describe + '?', sources)
      }
    }
    if (moments.size > 0) {
      let when: Map<string, string> = copyOf(moments)
      when.set('unavailable', 'some other moment')
      questions['moment.' + e.id] = choice('When does "' + e.what + '" happen (' + e.when + ')?', when)
    }
  }

  let parts = partsOf(sketch)
  for (let i = 0; i < sketch.other.length; i++) {
    if (isScene(sketch.other[i])) { continue }
    let options: Map<string, string> = copyOf(parts)
    options.set('none', 'none of these: it needs something the app does not have')
    questions['covers.' + i.toString()] = choice('The request also asks for "' + sketch.other[i] +
      '". Is that exactly what one of these parts of the app already does?', options)
    // As for inputs and values: an item the sketch added on its own is left out rather than refused.
    // Whether it is the person's or the plan's own: it is the person's when the request is about what it does or shows, and
    // when a question the plan itself put to the person concerns it -- a plan that asks how something should be done cannot
    // then call it unasked.
    let asked: Map<string, string> = new Map<string, string>()
    asked.set('asked', 'the request names it, or is about what it does or shows, or clearly needs it, or one of the plan\'s questions to the person concerns it')
    asked.set('added', 'the plan\'s own addition: the request is not about it and no question to the person concerns it')
    questions['asked.other.' + i.toString()] = choice('Is "' + sketch.other[i] + '" something the person wants?' + planQuestions(sketch), asked)
    // A chat widget's description is written as a spec, down to labels and buttons; a detail of how the widget
    // looks or is worked is left out rather than refused, as long as what it works out or does is all there.
    if (widget) { questions['detail.' + i.toString()] = detailQuestion(sketch.other[i]) }
  }
  // Which ready-made section handles each need the plan gave one, by the catalogue's own words for each.
  askReady(sketch, questions)
  askLive(sketch, questions)
  askDeadline(sketch, questions)
  askItinerary(sketch, questions)
  if (sketch.ready.length > 0) {
    // A plan names a section's own buttons and lists again as events and items of other: what a section does is left
    // to it, by Jev's reading rather than the plan's.
    let needs: Map<string, string> = new Map<string, string>()
    for (let i = 0; i < sketch.ready.length; i++) {
      // A section already chosen for the need says what it holds, so that what it holds is not asked of the person a second time.
      let spec = fragments().find((f: FragmentSpec): boolean => f.kind === sections.get('ready.' + i.toString()))
      needs.set('ready.' + i.toString(), 'part of the ready-made section for: ' + sketch.ready[i] +
        (spec !== undefined && spec.owns.length > 0 ? ' (the section already has: ' + spec.owns + ')' : ''))
    }
    needs.set('none', 'no: something of its own, apart from all of these')
    for (let e of sketch.events) {
      questions['within.event.' + e.id] = choice('Is "' + e.when + ': ' + e.what + '" part of one of these?', needs)
    }
    for (let input of sketch.inputs) {
      questions['within.input.' + input.id] = choice('Is setting "' + input.label + '" part of one of these?', needs)
    }
    for (let v of sketch.values) {
      questions['within.value.' + v.id] = choice('Is showing "' + v.label + '" (' + v.means + ') part of one of these?', needs)
    }
    for (let i = 0; i < sketch.other.length; i++) {
      if (isScene(sketch.other[i])) { continue }
      questions['within.other.' + i.toString()] = choice('Is "' + sketch.other[i] + '" part of one of these?', needs)
    }
  }
  // The same for an event no effect does: "show 'Egg is ready' at zero" was sketched as one.
  if (widget) {
    for (let e of sketch.events) { questions['detail.event.' + e.id] = detailQuestion(e.when + ': ' + e.what) }
  }

  let body: Record<string, Object> = {}
  body['model'] = 'jev-latest'
  body['state'] = 'Request: ' + prompt + '\nThe app has:\n' + describeSketch(sketch)
  if (settled.length > 0) {
    let kept: Record<string, Object> = {}
    Object.keys(questions).forEach((key: string) => { if (settled.indexOf(key) < 0) { kept[key] = questions[key] } })
    body['questions'] = kept
  } else {
    body['questions'] = questions
  }
  return JSON.stringify(body)
}

// ---- Reading Jev's answers ----

export class Binding {
  /** A formula of the vocabulary, or 'written' for the sketch's own expression in `expr`. */
  formula: string = ''
  a: string = ''
  b: string = ''
  /** For a written formula: the VERA expression, and the names it reads. */
  expr: string = ''
  reads: string[] = []
  show: string = 'stat'
  /** ' * 60' or ' / 60' when the formula gives a time in the other unit from the value's format, else ''. */
  scale: string = ''
}

/** A section of the catalogue chosen in place of a part. */
export class Replaced {
  kind: string
  need: string
  /** What the section is to do that the plan fixed and the section's own defaults would not (a countdown's length), in words; '' when nothing. */
  detail: string
  constructor(kind: string, need: string, detail: string = '') {
    this.kind = kind
    this.need = need
    this.detail = detail
  }
}

/** A length of time in words: "2 hours", "15 minutes", "90 seconds". */
export function lengthWords(seconds: number): string {
  let plural = (n: number, unit: string): string => n.toString() + ' ' + unit + (n === 1 ? '' : 's')
  if (seconds >= 3600 && seconds % 3600 === 0) { return plural(seconds / 3600, 'hour') }
  if (seconds >= 60 && seconds % 60 === 0) { return plural(seconds / 60, 'minute') }
  return plural(Math.round(seconds), 'second')
}

export class Composition {
  sketch: Sketch
  /**
   * The figure (a time of day) Jev named as the time by which the list of places or steps has to be over: it is published under
   * the name "deadline", for a section that reads it (the itinerary hides the stops that would run past it). '' when none.
   */
  deadline: string = ''
  theme: string = 'clean'
  widgets: Map<string, string> = new Map<string, string>()
  bindings: Map<string, Binding> = new Map<string, Binding>()
  countdownFrom: string = ''
  /** seconds, minutes or hours: what the countdown's length is counted in. */
  countdownUnit: string = 'seconds'
  effects: Map<string, string> = new Map<string, string>()
  /** For each kept event, where each of its effect's arguments comes from (a paramSources key). */
  args: Map<string, Map<string, string>> = new Map<string, Map<string, string>>()
  /** The moment each kept event happens at: countdown_end or entry_added. */
  moments: Map<string, string> = new Map<string, string>()
  /** The events the program carries out: the sketch's, less those it added on its own that nothing could do. */
  events: SketchEvent[] = []
  /** What was left out without refusing, for the trace. */
  dropped: string[] = []
  /** What the plan left open and a default settled, in words for the person: "Cook time: set by you, starting at 6". */
  defaulted: string[] = []
  /** The inputs the screen shows: the sketch's, less numbers nothing reads. */
  inputs: SketchInput[] = []
  /** Requirements nothing in the vocabulary was chosen for; a composition with any is not served. */
  unbound: string[] = []
  /** What the request asks the phone to do that no effect does, in words: the asked events left unbound or to a written section. */
  unboundNeeds: string[] = []
  /** Every answer with its confidence, for the trace. */
  answers: string[] = []
  /** A picture drawn from the sketch alone, before Jev answers: values it has no expression for show a dash. */
  provisional: boolean = false
  /**
   * For a chat bubble (vera-widget.txt): no header or hero, at most two sections -- the result first, the
   * controls under it -- and four rows of a list.
   */
  widget: boolean = false
  /** The figures drawn as rows of a list, the fixed numbers they come from first: an item of "other" asked for a table. */
  figures: boolean = false
  /** The catalogue's sections Jev chose for the plan's ready needs, in plan order, after the composition's own parts. */
  blocks: string[] = []
  /**
   * The live figures Jev said the screen fetches itself, in the order of the live_figure section's figures (1 to 3): it is in
   * `blocks` once when any is here, and the formulas read them through its ports.
   */
  live: SketchLive[] = []
  /** For each of the sketch's ready needs, the section Jev chose for it, '' for none. */
  readyKinds: string[] = []
  /** Whether their content has to come from a search: real places, prices or facts rather than placeholders. */
  realData: boolean = false
  /** Needs neither the parts nor a section do, for a custom section the model writes (agent/AgentCustom.ets). */
  custom: string[] = []
  /** Inputs a figure left to the custom section reads: they stay on the screen though no part reads them. */
  customReads: string[] = []
  /** The needs of `custom` that are something the phone or another app does: the section is shown the phone's functions for them. */
  phoneNeeds: string[] = []
  /**
   * For such a need, the effect Jev named for it before something it needs (a place, a title) could not be given: a section of
   * the catalogue that does that effect does the need too (dropProvided).
   */
  customEffects: Map<string, string> = new Map<string, string>()
  /**
   * What was left out of the plan because a section of the catalogue is said to do it, in words: the section's own options
   * decide whether it does, so the finished screen is read against these (agent/AgentClaims.ets).
   */
  claimed: string[] = []
  /** Sections that took the place of a part the plan called for (a countdown, a list), with the need they were chosen for. */
  replaced: Replaced[] = []
  constructor(sketch: Sketch) { this.sketch = sketch }
}

const PICK_ABOVE: number = 0.25

/**
 * Leaves out the events whose effect a chosen section already does (SlotSpec.provides, for the slots Jev turned on): the
 * section's button and the part's would be the same button twice. Returns what was left out, in words.
 */
export function dropProvided(comp: Composition, provided: string[]): string[] {
  let out: string[] = []
  comp.events = comp.events.filter((e: SketchEvent): boolean => {
    let fx = comp.effects.get(e.id)
    if (fx === undefined || provided.indexOf(fx) < 0) { return true }
    comp.effects.delete(e.id)
    comp.args.delete(e.id)
    comp.moments.delete(e.id)
    comp.dropped.push('event "' + e.what + '": a section does it')
    out.push(e.what)
    return false
  })
  // An event whose effect was named but could not be given what it needs (the place of a stop: the section's stops are the section's)
  // went to the section the model writes; a section that does that effect does it, so it is not written as well.
  let done: string[] = []
  comp.customEffects.forEach((fx: string, need: string) => { if (provided.indexOf(fx) >= 0) { done.push(need) } })
  for (let need of done) {
    comp.customEffects.delete(need)
    comp.custom = comp.custom.filter((c: string): boolean => c !== need)
    comp.phoneNeeds = comp.phoneNeeds.filter((c: string): boolean => c !== need)
    comp.unboundNeeds = comp.unboundNeeds.filter((c: string): boolean => c !== need)
    comp.dropped.push('event "' + need + '": a section does it')
    out.push(need)
  }
  return out
}

/** The sketch with another list, for a composition that leaves some of the list's fields out. */
function withList(sketch: Sketch, list: SketchList | null): Sketch {
  let out = new Sketch()
  out.title = sketch.title
  out.eyebrow = sketch.eyebrow
  out.subtitle = sketch.subtitle
  out.inputs = sketch.inputs
  out.constants = sketch.constants
  out.values = sketch.values
  out.countdown = sketch.countdown
  out.hasCountdown = sketch.hasCountdown
  out.countdownLength = sketch.countdownLength
  out.stopwatch = sketch.stopwatch
  out.hasStopwatch = sketch.hasStopwatch
  out.list = list
  out.events = sketch.events
  out.live = sketch.live
  out.liveCut = sketch.liveCut
  out.ready = sketch.ready
  out.other = sketch.other
  return out
}

/**
 * How a figure the model writes is to be shown, in words: a time of day held as minutes since midnight shown as the raw number
 * ("960" for 16:00) is not a time.
 */
function figureForm(v: SketchValue): string {
  return figureShown(v) + planWorked(v)
}

/** What the plan itself says about working the figure out: its formula and the worked example, for the one who writes it. */
function planWorked(v: SketchValue): string {
  if (v.formula.length === 0) { return '' }
  let said = ' (the plan works it out as ' + v.formula
  if (!Number.isNaN(v.result)) {
    let given: string[] = []
    v.given.forEach((n: number, name: string) => { given.push(name + ' = ' + numberLiteral(n)) })
    said += '; for ' + (given.length > 0 ? given.join(', ') : 'its example') + ' that is ' + numberLiteral(v.result)
  }
  return said + ')'
}

function figureShown(v: SketchValue): string {
  if (v.yesNo) { return ' (a yes or a no worked out as 1 or 0: show it as Yes or No, or as words that say which, never as the number)' }
  if (v.format === 'clock') { return ' (a time of day: show it as hh:mm, never as the number of minutes since midnight)' }
  if (v.format === 'minutes') { return ' (a length of time in minutes: show it as minutes, or as hours and minutes)' }
  if (v.format === 'seconds') { return ' (a length of time in seconds: show it as m:ss)' }
  if (v.format === 'money') { return ' (money: show it with its currency sign' + (v.unit.length > 0 ? ' ' + v.unit : '') + ')' }
  if (v.format === 'percent') { return ' (a percent: show it with the % sign)' }
  return ''
}

/**
 * A formula decides what the screen computes, so a hesitant pick is refused: a fuel calculator's
 * "distance x litres per 100 km" came at 0.30-0.38, while right picks have come at 0.42 and above.
 */
const FORMULA_ABOVE: number = 0.4

/** How sure Jev must be that a value takes several steps before its pick is set aside. */
const MORE_STEPS_ABOVE: number = 0.5

/** Jev takes at most 255 criteria per question, the "unavailable" option included. */
const MAX_CRITERIA: number = 255

export function answerOf(answers: Record<string, Object>, key: string, allowed: string[], log: string[],
    above: number = PICK_ABOVE): string {
  let a = answers[key] as Record<string, Object>
  if (a === null || a === undefined) { log.push(key + '=?'); return '' }
  let c = a['choice']
  let confidence = typeof a['confidence'] === 'number' ? a['confidence'] as number : 1
  let picked = typeof c === 'string' ? c as string : ''
  log.push(key + '=' + picked + '@' + confidence.toFixed(2))
  if (allowed.indexOf(picked) < 0 || confidence < above) { return '' }
  return picked
}

/** Whether any value's formula reads one of `names`. */
function readsAny(comp: Composition, names: string[]): boolean {
  let found = false
  comp.bindings.forEach((b: Binding) => {
    for (let name of [b.a, b.b].concat(b.reads)) { if (names.indexOf(name) >= 0) { found = true } }
  })
  return found
}

/** The sketch without its countdown or stopwatch: a section does it. */
function withoutClock(sketch: Sketch): Sketch {
  let out = withList(sketch, sketch.list)
  out.inputs = sketch.inputs
  out.countdown = ''
  out.hasCountdown = false
  out.stopwatch = ''
  out.hasStopwatch = false
  return out
}

/**
 * Whether the `timer` section may take the countdown's place: the length is one fixed time of the plan's (a person who sets it
 * needs the part, which follows the input), and nothing else on the screen is wired to the clock -- an event at its end, a value
 * that reads the time left or passed.
 */
export function canReplaceClock(comp: Composition): boolean {
  let sketch = comp.sketch
  if (!sketch.hasCountdown || comp.blocks.indexOf('timer') >= 0) { return false }
  if (!sketch.constants.some((k: SketchConstant): boolean => k.id === comp.countdownFrom)) { return false }
  let atEnd = false
  comp.moments.forEach((moment: string) => { if (moment === 'countdown_end') { atEnd = true } })
  return !atEnd && !readsAny(comp, CLOCK_OPERANDS)
}

/**
 * Whether the countdown may be the interval timer: its lengths and rounds are the section's own settings, so the plan's lengths may be
 * inputs; but nothing else on the screen may read the clock, and nothing but a buzz may happen as it ends (the section signals each
 * change of phase itself).
 */
export function canTakeRounds(comp: Composition): boolean {
  if (!comp.sketch.hasCountdown || comp.blocks.indexOf('interval_timer') >= 0) { return false }
  let other = false
  comp.moments.forEach((moment: string, id: string) => {
    if (moment !== 'countdown_end') { return }
    let effect = comp.effects.get(id) ?? ''
    if (effect !== 'vibrate' && effect !== 'beep') { other = true }
  })
  return !other && !readsAny(comp, CLOCK_OPERANDS)
}

/** What a points ledger does on a tap: award a task, redeem a reward, keep the balance. */
const LEDGER_WORDS: RegExp = /\b(rewards?|tasks?|chores?|stars?|points?|balance|redeem\w*|earn\w*|spend\w*)\b/i

/** The sections that would list the ledger's tasks or rewards a second time; the plan picked each of them in one run or another. */
const LEDGER_TAKES: string[] = ['checklist', 'idea_deck', 'data_table', 'search_list', 'key_facts', 'timeline', 'bar_chart']

/** The plan's inputs for the people's names: the ledger names its own. */
function ledgerNames(comp: Composition): string[] {
  return unique(comp.inputs.concat(comp.sketch.inputs).filter((i: SketchInput): boolean => i.kind === 'text' &&
    /\b(kids?|child(ren)?|person|people|names?|first|second)\b/i.test(i.label)).map((i: SketchInput): string => i.id))
}

/** The events the plan put on adding or tapping an entry leave with the list, to the section that takes it; each is said in the trace. */
function handEntryEvents(comp: Composition, why: string): void {
  let entryMoment = (id: string): boolean => { let m = comp.moments.get(id) ?? ''; return m === 'entry_added' || m === 'row_button' }
  let gone = comp.events.filter((e: SketchEvent): boolean => entryMoment(e.id))
  comp.events = comp.events.filter((e: SketchEvent): boolean => !entryMoment(e.id))
  for (let e of gone) {
    comp.moments.delete(e.id)
    comp.effects.delete(e.id)
    comp.args.delete(e.id)
    comp.dropped.push('event "' + e.what + '": ' + why)
  }
  // An argument taken from an entry, on an event that stays, keeps the list part: those are left as they were.
}

function handTapsToLedger(comp: Composition): void {
  handEntryEvents(comp, 'the points ledger does it')
  // The ledger names its people, keeps the rewards and what was redeemed, and shows each balance: the plan's inputs for the kids'
  // names, its second lists of rewards and redemptions and its figures over stars were all drawn again beside it (Chore stars).
  let names = ledgerNames(comp)
  comp.inputs = comp.inputs.filter((i: SketchInput): boolean => names.indexOf(i.id) < 0)
  comp.sketch.inputs = comp.sketch.inputs.filter((i: SketchInput): boolean => names.indexOf(i.id) < 0)
  for (let id of names) { comp.dropped.push('input "' + id + '": the points ledger names its people') }
  let ledgers = comp.custom.filter((n: string): boolean => LEDGER_WORDS.test(n) || n.startsWith('a second list of entries'))
  comp.custom = comp.custom.filter((n: string): boolean => ledgers.indexOf(n) < 0)
  comp.phoneNeeds = comp.phoneNeeds.filter((n: string): boolean => ledgers.indexOf(n) < 0)
  comp.unboundNeeds = comp.unboundNeeds.filter((n: string): boolean => ledgers.indexOf(n) < 0)
  for (let n of ledgers) { comp.claimed.push(n) }
  // A list of the same tasks as a checklist or a deck of ideas ("pick a chore") beside the ledger is the same list twice.
  // The blocks of the ready needs are in the order of those needs that have one (screenPlan numbers them so): the one for this need is
  // taken out at its own place, and the need is left with no block, so no slot points past the blocks.
  let at = 0
  for (let i = 0; i < comp.readyKinds.length; i++) {
    let kind = comp.readyKinds[i]
    if (kind.length === 0) { continue }
    if (LEDGER_TAKES.indexOf(kind) < 0 || !LEDGER_WORDS.test(comp.sketch.ready[i] ?? '') || comp.blocks[at] !== kind) { at++; continue }
    comp.blocks.splice(at, 1)
    comp.readyKinds[i] = ''
    comp.dropped.push('"' + comp.sketch.ready[i] + '": the points ledger lists the tasks')
  }
}

/** A length that is one of the interval timer's phases, and a count that is its rounds. */
const PHASE_WORDS: RegExp = /\b(focus|work|break|rest|blocks?|rounds?|intervals?|phases?|sprints?|pomodoros?)\b/i
const COUNT_WORDS: RegExp = /\b(rounds?|blocks?|sets?|cycles?|reps?|pomodoros?)\b/i

/** What says a length of a phase or a number of rounds: the interval timer's own settings. */
const ROUND_WORDS: RegExp = /\b(rounds?|blocks?|sets?|cycles?|reps?|intervals?|breaks?|rest|focus|work|phases?|sessions?)\b/i

/**
 * The interval timer sets its own lengths and rounds and shows its phase, its round and the focus time done: the plan's inputs for
 * the same (a select of "Focus block", "Break", a stepper of "Blocks"), the figures worked out from them (total focus time) and a
 * second countdown for the break are its, and drawn beside it they were all there twice (Homework timer on the phone). They leave;
 * what is left of them is claimed by the section and read against the finished screen.
 */
/** Whether an event's argument is taken from the input `id`. */
function argReads(comp: Composition, id: string): boolean {
  let found = false
  comp.args.forEach((given: Map<string, string>) => { given.forEach((source: string) => { if (source === 'input.' + id) { found = true } }) })
  return found
}

function handRoundsToTimer(comp: Composition): void {
  let sketch = comp.sketch
  // Only the lengths of a phase and the number of rounds: "Reminder every (minutes)" or "Work hours today" stay.
  let leaving = sketch.inputs.filter((i: SketchInput): boolean => i.kind !== 'text' && i.kind !== 'toggle' &&
    ((i.measure === 'seconds' || i.measure === 'minutes' || i.kind === 'choice') ? PHASE_WORDS.test(i.label) : COUNT_WORDS.test(i.label)))
    .map((i: SketchInput): string => i.id)
    // Not one an event that stays passes on, or the written section reads: it would read a name nothing defines.
    .filter((id: string): boolean => !argReads(comp, id) && comp.customReads.indexOf(id) < 0)
  if (leaving.length === 0) { return }
  for (let id of leaving) { comp.widgets.delete(id) }
  sketch.inputs = sketch.inputs.filter((i: SketchInput): boolean => leaving.indexOf(i.id) < 0)
  comp.inputs = comp.inputs.filter((i: SketchInput): boolean => leaving.indexOf(i.id) < 0)
  // A figure worked out from one that leaves leaves too ("Total session" from the focus and break totals).
  let away: string[] = leaving.slice()
  let reads = (v: SketchValue): boolean => away.some((id: string): boolean => new RegExp('\\b' + id + '\\b').test(v.formula))
  let gone: SketchValue[] = []
  let more = true
  while (more) {
    more = false
    for (let v of sketch.values) {
      if (gone.indexOf(v) < 0 && reads(v)) { gone.push(v); away.push(v.id); more = true }
    }
  }
  sketch.values = sketch.values.filter((v: SketchValue): boolean => gone.indexOf(v) < 0)
  // Totals of the session worked out from the lengths are the plan's, not the request's: claimed, they came back to be written as
  // "900s" and "4500s".
  for (let v of gone) {
    comp.bindings.delete(v.id)
    comp.dropped.push('value "' + v.label + '": the interval timer shows its own')
  }
  // "Switches to the other phase when a block or a break runs out" is what the timer does.
  for (let e of sketch.events) {
    let need = e.what + ' (' + e.when + ')'
    if (comp.custom.indexOf(need) < 0 || !(ROUND_WORDS.test(need) || /\b(countdown|runs? out|ends?)\b/i.test(e.when))) { continue }
    comp.custom = comp.custom.filter((n: string): boolean => n !== need)
    comp.phoneNeeds = comp.phoneNeeds.filter((n: string): boolean => n !== need)
    comp.unboundNeeds = comp.unboundNeeds.filter((n: string): boolean => n !== need)
    comp.dropped.push('event "' + e.what + '": the interval timer moves from phase to phase itself')
  }
  // The break's countdown is the timer's rest phase: not read against the screen, where Jev did not find a second clock and the
  // section written for it failed into "Part of this app could not be built".
  let rounds = sketch.other.filter((o: string): boolean => o.startsWith('a second countdown') || ROUND_WORDS.test(o))
  sketch.other = sketch.other.filter((o: string): boolean => rounds.indexOf(o) < 0)
  for (let o of rounds) { comp.dropped.push('"' + o + '": the interval timer\'s rest phase') }
  for (let id of leaving) { comp.dropped.push('input "' + id + '": the interval timer sets it') }
}

export function replaceClock(comp: Composition, kind: string = 'timer'): void {
  if (kind !== 'timer') {
    let need = comp.sketch.countdown
    let numbers = planNumbers(comp.sketch)
    comp.sketch = withoutClock(comp.sketch)
    comp.countdownFrom = ''
    comp.blocks.push(kind)
    comp.replaced.push(new Replaced(kind, need, numbers.length > 0 ? 'starts from the plan\'s numbers: ' + numbers : ''))
    if (kind === 'interval_timer') { handRoundsToTimer(comp) }
    comp.claimed.push(need)
    comp.dropped.push('"' + need + '": a section does it, not a part')
    return
  }
  let need = comp.sketch.countdown
  // The length the plan fixed goes with the need: the section writes its own presets, and a countdown of two hours that the
  // section shows as fifteen minutes is not the countdown the request asked for.
  let source = comp.sketch.constants.find((k: SketchConstant): boolean => k.id === comp.countdownFrom)
  let length = source === undefined ? '' : lengthWords(source.measure === 'minutes' ? source.value * 60 : source.value)
  comp.sketch = withoutClock(comp.sketch)
  comp.countdownFrom = ''
  comp.blocks.push('timer')
  comp.replaced.push(new Replaced('timer', need, length.length > 0 ? 'counts down ' + length + ' (its first preset)' : ''))
  comp.claimed.push(length.length > 0 ? need + ', counting down ' + length : need)
  comp.dropped.push('"' + need + '": a section does it, not a part')
}

/**
 * A total of minutes or seconds over the list's entries (the minutes logged, the hours worked) is a quantity, not a time on a
 * clock: shown with its unit ("150 min"), not as 2:30:00, which reads as a time of day and as 0:00 before anything is entered.
 */
function showEntryTotalsAsNumbers(comp: Composition): void {
  let shown: SketchValue[] = []
  for (let v of comp.sketch.values) {
    if (!isTime(v.format) || !comp.bindings.has(v.id) || !dependsOn(comp, v.id).some((n: string): boolean => ENTRY_OPERANDS.indexOf(n) >= 0)) {
      shown.push(v)
      continue
    }
    let plain = new SketchValue()
    plain.id = v.id
    plain.label = v.label
    plain.means = v.means
    plain.format = 'plain'
    plain.unit = v.format === 'minutes' ? 'min' : 's'
    plain.decimals = v.decimals >= 0 ? v.decimals : 0
    plain.formula = v.formula
    plain.hidden = v.hidden
    plain.given = v.given
    plain.result = v.result
    shown.push(plain)
  }
  comp.sketch.values = shown
}

/** What a value over the entries reads. */
const ENTRY_OPERANDS: string[] = ['entryCount', 'entryTotal']

/** The values that work from the list's entries, directly or through other values. */
function valuesOverEntries(comp: Composition): string[] {
  let out: string[] = []
  for (let v of comp.sketch.values) {
    if (comp.bindings.has(v.id) && dependsOn(comp, v.id).some((n: string): boolean => ENTRY_OPERANDS.indexOf(n) >= 0)) { out.push(v.id) }
  }
  return out
}

/**
 * Whether `kind` (a section that keeps the person's entries) may take the list part's place: no event is wired to the part (when
 * an entry is added or tapped, an argument taken from an entry). Values over the entries -- a total, a count -- keep the part,
 * except for `record_log`: it publishes totals, averages, balances and counts for the readers of the catalogue to show, so those
 * values go to them (replaceList).
 */
export function canReplaceList(comp: Composition, kind: string, takesTaps: boolean = false): boolean {
  if (comp.sketch.list === null || LIST_SECTIONS.indexOf(kind) < 0 || comp.blocks.indexOf(kind) >= 0) { return false }
  let onEntry = false
  let entryMoment = (id: string): boolean => { let m = comp.moments.get(id) ?? ''; return m === 'entry_added' || m === 'row_button' }
  // A section that takes the taps on its entries over (takesTaps) takes their events too; an event that stays may still read an entry.
  comp.moments.forEach((moment: string, id: string) => { if (entryMoment(id) && !takesTaps) { onEntry = true } })
  comp.args.forEach((given: Map<string, string>, id: string) => {
    if (takesTaps && entryMoment(id)) { return }
    given.forEach((source: string) => { if (source.startsWith('entry.')) { onEntry = true } })
  })
  return !onEntry && (LIST_PUBLISHERS.indexOf(kind) >= 0 || valuesOverEntries(comp).length === 0)
}

/**
 * The plan's own numbers, in words, for a section that takes a part's place: the glass of 250 ml and the goal of 2000 ml a water
 * plan set, the 15 minutes of focus and 5 of rest a homework plan set. Without them the section's content was written from the
 * request alone and came out at its defaults (1 ml a tap, no goal: Water reminder on the phone).
 */
export function planNumbers(sketch: Sketch): string {
  let out: string[] = []
  for (let i of sketch.inputs) {
    if (i.kind === 'text' || i.kind === 'toggle') { continue }
    let value = i.kind === 'choice' ? (i.options[i.value] !== undefined ? i.options[i.value].label : '') :
      (i.kind === 'time' || i.measure === 'clock' ? clockWords(i.value) : numberLiteral(i.value) + (i.unit.length > 0 ? ' ' + i.unit : ''))
    if (value.length > 0) { out.push(i.label + ' ' + value) }
  }
  for (let k of sketch.constants) { out.push(k.label + ' ' + numberLiteral(k.value)) }
  // The reading the request gives is the section's first one (seedFromRequest).
  if (sketch.list !== null) {
    for (let f of sketch.list!.fields) { if (!isNaN(f.seed)) { out.push('first reading of ' + f.label + ' ' + numberLiteral(f.seed) + (f.unit.length > 0 ? ' ' + f.unit : '')) } }
  }
  return out.join('; ')
}

function clockWords(minutes: number): string {
  let h = Math.floor(minutes / 60) % 24
  let m = Math.round(minutes % 60)
  return (h < 10 ? '0' : '') + h.toString() + ':' + (m < 10 ? '0' : '') + m.toString()
}

/**
 * The section takes the list part's place. The values over the entries leave the plan as needs the catalogue is asked about
 * (AgentAlign.ets offers the readers of what the section publishes first), and a written section otherwise.
 */
export function replaceList(comp: Composition, kind: string): void {
  let need = comp.sketch.list!.label
  let numbers = kind === 'record_log' ? '' : planNumbers(comp.sketch)
  let leaving = valuesOverEntries(comp)
  let gone: SketchValue[] = comp.sketch.values.filter((v: SketchValue): boolean => leaving.indexOf(v.id) >= 0)
  comp.sketch = withList(comp.sketch, null)
  comp.sketch.values = comp.sketch.values.filter((v: SketchValue): boolean => leaving.indexOf(v.id) < 0)
  for (let v of gone) {
    comp.bindings.delete(v.id)
    let shown = 'shows ' + v.label + (v.means.length > 0 ? ': ' + v.means : '')
    // A section that shows its own figures over the entries (today's total toward the goal, doses taken) is said to show this one,
    // and the finished screen is read for it; one it does not show goes back to be written. Beside record_log the readers show it.
    if (kind !== 'record_log') { comp.claimed.push(shown) }
    else if (customEnabled) { comp.custom.push(shown) } else { comp.unbound.push(shown) }
    comp.dropped.push('value "' + v.label + '": left to what the section that keeps the entries publishes')
  }
  comp.blocks.push(kind)
  comp.replaced.push(new Replaced(kind, need, numbers.length > 0 ? 'starts from the plan\'s numbers: ' + numbers : ''))
  // Not a claim for the finished screen to be read against: the pick was a question about this very list, and reading the screen
  // for "keeps expenses" asks the same thing again (and wrote a section for what the log already does).
  comp.dropped.push('"' + need + '": a section does it, not a part')
}

/** Sections that show figures written for them, and the reader of a record_log that shows the same thing from the records. */
const LOG_READERS: Map<string, string> = new Map<string, string>([['bar_chart', 'series_chart'], ['data_table', 'breakdown_table']])

/**
 * A chart or table beside a log of records shows the log. bar_chart and data_table show figures written for them, and they are
 * the only ones a ready need can be given: Shared costs' "a bar chart of what each friend has paid" was drawn from made-up sums
 * (12000, 8500, ...), and its table of who paid what read "Anna $120.00 +$45.00", above a log of no payments and totals of
 * $0.00. With a record_log on the screen each becomes the reader that shows the log's totals per person or category through its
 * ports (series_chart, breakdown_table).
 */
export function readLogInCharts(comp: Composition): void {
  if (comp.blocks.indexOf('record_log') < 0) { return }
  for (let i = 0; i < comp.blocks.length; i++) {
    let reader = LOG_READERS.get(comp.blocks[i])
    if (reader === undefined || comp.blocks.indexOf(reader) >= 0) { continue }
    let written = comp.blocks[i]
    comp.blocks[i] = reader
    for (let j = 0; j < comp.readyKinds.length; j++) { if (comp.readyKinds[j] === written) { comp.readyKinds[j] = reader } }
    comp.dropped.push('the ' + written + ' shows the log of records on the screen, not figures written for it')
  }
}

/**
 * A countdown or a list the plan calls for may be a section of the catalogue instead of the part, when Jev says so with the
 * confidence of any other pick and nothing else on the screen needs what the part has (canReplaceClock, canReplaceList). The
 * section takes the part's place in the plan; what the person sets for it is the section's own.
 */
function chooseSections(comp: Composition, answers: Record<string, Object>): void {
  // The itinerary marks each stop reached itself: a list of the stops reached beside it is the same thing twice (Shanghai layover:
  // "Stops reached" with a Stop field and an Add button above the stops, each with its own check).
  if (comp.blocks.indexOf('itinerary') >= 0 && comp.sketch.list !== null &&
      /\b(reached|visited|arrived|been)\b/i.test(comp.sketch.list!.label + ' ' + comp.sketch.list!.fields.map((f: ListField): string => f.label).join(' '))) {
    let wired = false
    comp.moments.forEach((m: string) => { if (m === 'entry_added' || m === 'row_button') { wired = true } })
    // Nor while something still reads the entries: an event's argument, a figure ("Stops done" counts them).
    comp.args.forEach((given: Map<string, string>) => {
      given.forEach((source: string) => { if (source.startsWith('entry.')) { wired = true } })
    })
    if (valuesOverEntries(comp).length > 0) { wired = true }
    if (!wired) {
      let label = comp.sketch.list!.label
      comp.sketch = withList(comp.sketch, null)
      comp.dropped.push('"' + label + '": the itinerary marks each stop reached')
    }
  }
  let clock = comp.sketch.hasCountdown ? answerOf(answers, 'clock.part', CLOCK_SECTIONS, comp.answers, READY_ABOVE) : ''
  if (comp.sketch.hasCountdown) { console.info('VERA-CHOOSE clock.part=' + (clock.length > 0 ? clock : 'part')) }
  if (clock === 'timer' && canReplaceClock(comp)) { replaceClock(comp) }
  else if (clock === 'interval_timer' && canTakeRounds(comp)) { replaceClock(comp, 'interval_timer') }
  if (comp.sketch.list !== null) {
    let kind = answerOf(answers, 'list.part', LIST_SECTIONS, comp.answers, READY_ABOVE)
    // Points earned for tasks and spent on rewards are the ledger's whole job, taps on a task or a reward among it: what the plan
    // wired to those taps is the ledger's, and a checklist of the same tasks beside it is the same list twice (Chore stars).
    // A reading's status is worked out by the section as each reading is added: what the plan wired to adding one is its. Both are
    // decided before anything is handed over, so a refusal leaves the composition as it was.
    let takesTaps = kind === 'points_ledger' || kind === 'reading_status'
    let can = kind.length > 0 && canReplaceList(comp, kind, takesTaps)
    if (can && kind === 'points_ledger') { handTapsToLedger(comp) }
    if (can && kind === 'reading_status') { handEntryEvents(comp, 'the reading section shows the status of each reading') }
    console.info('VERA-CHOOSE list.part=' + (kind.length > 0 ? kind : 'part') + (kind.length > 0 && !can ? ' (refused: the part is wired to)' : ''))
    if (can) { replaceList(comp, kind) }
  }
}

/**
 * The live figures Jev says the screen fetches as they are now go to one live_figure section, in plan order. One it says no to is
 * not fetched: the written section is told of it, and a figure whose formula reads it cannot be worked out, so it is refused.
 */
function readLive(comp: Composition, answers: Record<string, Object>): void {
  for (let label of comp.sketch.liveCut) { comp.dropped.push('"' + label + '": one source answers three figures at most') }
  for (let i = 0; i < comp.sketch.live.length; i++) {
    let l = comp.sketch.live[i]
    let yes = answerOf(answers, 'live.' + i.toString(), ['yes'], comp.answers, LIVE_ABOVE) === 'yes'
    console.info('VERA-COMPOSE live.' + i.toString() + ' "' + l.label + '" -> ' + (yes ? LIVE_KIND : 'none') + ' ' +
      JSON.stringify(answers['live.' + i.toString()] ?? null).substring(0, 400))
    if (yes) { comp.live.push(l); continue }
    if (customEnabled) { comp.custom.push(l.label + ' (' + l.means + ')') } else { comp.unbound.push('no section fetches: ' + l.label) }
  }
  if (comp.live.length > 0 && comp.blocks.indexOf(LIVE_KIND) < 0) { comp.blocks.push(LIVE_KIND) }
  // A value whose binding reads a refused figure is refused with it in dropValues, once the bindings are known: the written formula
  // is not the only way to read it, the vocabulary's operands offer every live figure too.
}

export function readComposition(body: string, sketch: Sketch, widget: boolean = false): Composition {
  let comp = new Composition(sketch)
  // Its own list of inputs: a default adds one (defaultInput), and the sketch is read again for a widget.
  comp.sketch = withList(sketch, sketch.list)
  comp.sketch.inputs = sketch.inputs.slice()
  comp.widget = widget
  let answers: Record<string, Object> = {}
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let found = parsed['answers']
    if (found !== null && found !== undefined) { answers = found as Record<string, Object> }
  } catch (_e) {
    comp.unbound.push('no answer from Jev')
    return comp
  }
  let theme = answerOf(answers, 'theme', ['clean', 'soft', 'expressive', 'technical', 'playful'], comp.answers)
  comp.theme = theme.length > 0 ? theme : 'clean'
  // A ready need is the section Jev names for it, confidently; one it names none for is refused, as an item of other is.
  let served: string[] = []
  for (let i = 0; i < sketch.ready.length; i++) {
    let kind = answerOf(answers, 'ready.' + i.toString(), READY_KINDS, comp.answers, READY_ABOVE)
    let own = answerOf(answers, 'whose.' + i.toString(), ['own'], comp.answers, OWN_RECORDS_ABOVE) === 'own'
    // Which section a ready need went to, and how sure Jev was of each: the pick is otherwise visible only as its result.
    console.info('VERA-COMPOSE ready.' + i.toString() + ' "' + sketch.ready[i] + '" -> ' + (kind.length > 0 ? kind : 'none') + ' ' +
      JSON.stringify(answers['ready.' + i.toString()] ?? null).substring(0, 400))
    comp.readyKinds.push(own ? '' : kind)
    if (own && customEnabled) {
      // Their own records are theirs to enter: a section that keeps what they add, starting empty, and makes up none.
      comp.custom.push(sketch.ready[i] + ' -- these are the person\'s own: they add, change and remove them; the list starts ' +
        'empty and the app never makes any up')
    } else if (own) {
      comp.unbound.push('the person\'s own records, which no section can make up: ' + sketch.ready[i])
    } else if (kind.length > 0) {
      comp.blocks.push(kind)
      served.push('ready.' + i.toString())
    } else {
      if (customEnabled) { comp.custom.push(sketch.ready[i]) } else { comp.unbound.push('no section for: ' + sketch.ready[i]) }
    }
  }
  if (comp.blocks.length > 0) { comp.realData = answerOf(answers, 'real_data', ['true'], comp.answers, REAL_DATA_ABOVE) === 'true' }
  readLive(comp, answers)

  for (let input of sketch.inputs) {
    let allowed: string[] = []
    for (let w of WIDGETS) { if (w.kinds.indexOf(input.kind) >= 0) { allowed.push(w.id) } }
    let ruled = countWidget(input)
    let picked = ruled.length > 0 ? ruled :
      (allowed.length === 1 ? allowed[0] : answerOf(answers, 'widget.' + input.id, allowed, comp.answers))
    comp.widgets.set(input.id, picked.length > 0 ? picked : allowed[0])
  }

  // Values nothing could work out, with why: refused, or left out at the end when the sketch added them.
  let failed: Map<string, string> = new Map<string, string>()
  // A figure a chosen section already shows is that section's (what it holds is said to Jev: FragmentSpec.owns): it leaves,
  // and an input only it read leaves with it, rather than both being put on the screen beside the section. It is still
  // worked out here, so a figure that stays and reads it keeps a working binding (dropValues).
  let shownBySection: string[] = []
  for (let i = 0; i < sketch.values.length; i++) {
    let v = sketch.values[i]
    let keys: string[] = []
    expressionsFor(sketch, i).forEach((_d: string, key: string) => { keys.push(key) })
    let binding = new Binding()
    let show = answerOf(answers, 'show.' + v.id, SHOWS, comp.answers)
    binding.show = show.length > 0 ? show : (v.format === 'fraction' ? 'progress' : 'stat')
    if (comp.blocks.length > 0 && answerOf(answers, 'within.value.' + v.id, served, comp.answers, COVERED_ABOVE).length > 0) {
      shownBySection.push(v.id)
    }
    if (keys.length === 0 || keys.length >= MAX_CRITERIA) {
      let why = keys.length === 0 ? 'nothing to work it out from' : 'too many ways to work it out'
      let fault = useWritten(comp, answers, i, binding)
      if (fault.length > 0) { failed.set(v.id, why + '; ' + fault) }
      comp.bindings.set(v.id, binding)
      continue
    }
    let picked = answerOf(answers, 'expr.' + v.id, keys, comp.answers, FORMULA_ABOVE)
    if (answerOf(answers, 'steps.' + v.id, ['more'], comp.answers, MORE_STEPS_ABOVE).length > 0) { picked = '' }
    if (picked.length > 0) {
      let parts = picked.split(':')
      binding.formula = parts[0]
      binding.a = parts[1]
      binding.b = parts[2]
      binding.scale = timeScale(sketch, i, binding, v.format)
    }
    let formula = FORMULAS.find((f: Formula): boolean => f.id === binding.formula)
    let why = ''
    if (formula === undefined) {
      why = 'no formula'
    } else if (binding.a.length === 0 || (formula.operands === 2 && binding.b.length === 0)) {
      why = formula.id + ' without its operands'
    } else {
      let stray = strayNumber(sketch, v, formula.id)
      if (stray.length > 0) { why = 'uses ' + stray + ', which no fixed number holds' }
    }
    if (why.length > 0) {
      let fault = useWritten(comp, answers, i, binding)
      if (fault.length > 0) { failed.set(v.id, why + '; ' + fault) }
    } else if (writtenSaysMore(v, binding.formula)) {
      // The plan's own formula bounds or rounds what the vocabulary's cannot ("max(0, a - b)" is not
      // "subtract"): it wins when it holds up. When it does not, the vocabulary's stays, unchanged.
      useWritten(comp, answers, i, binding)
    }
    comp.bindings.set(v.id, binding)
  }

  if (sketch.hasCountdown) {
    let sources: string[] = []
    lengthSources(sketch).forEach((_d: string, key: string) => { sources.push(key) })
    comp.countdownFrom = answerOf(answers, 'countdown.length', sources, comp.answers)
    let unclear = comp.countdownFrom.length === 0 ||
      dependsOn(comp, comp.countdownFrom).some((d: string): boolean => CLOCK_OPERANDS.indexOf(d) >= 0)
    if (!unclear) {
      // A worked-out value's unit is its format; an input's or a constant's is Jev's reading of its labels.
      comp.countdownUnit = lengthUnitOf(sketch, comp.countdownFrom)
      // Hours are the plan's own unit, written in words: no question is asked of them (they are not seconds or minutes).
      if (comp.countdownUnit !== 'hours' && answers['unit.' + comp.countdownFrom] !== undefined) {
        comp.countdownUnit = answerOf(answers, 'unit.' + comp.countdownFrom, ['seconds', 'minutes'], comp.answers, UNIT_ABOVE)
        if (comp.countdownUnit.length === 0) {
          // Not a length of time at all -- a tea timer once ran from its choice's position, 0 to 2 -- is not used for one.
          // A time Jev is only unsure of the unit of is read by its size: past two hours' worth of minutes is seconds.
          unclear = answerOf(answers, 'unit.' + comp.countdownFrom, ['neither'], [], UNIT_ABOVE) === 'neither'
          if (!unclear) {
            let start = startingNumber(comp.sketch, comp.countdownFrom)
            comp.countdownUnit = isFinite(start) && start > 120 ? 'seconds' : 'minutes'
            comp.defaulted.push(labelOf(sketch, comp.countdownFrom) + ': taken as ' + comp.countdownUnit)
          }
        }
      }
    }
    if (unclear) {
      // Nothing sets how long it runs (or only the countdown itself, or a number that is not a time): the person sets
      // it, in minutes.
      let id = usableId('countdownLength', sketchIds(comp.sketch))
      defaultInput(comp, id, (sketch.countdown.length > 0 ? sketch.countdown : 'Timer') + ' length', 'minutes', 5)
      comp.countdownFrom = id
      comp.countdownUnit = 'minutes'
    }
  }

  let effectIds: string[] = []
  for (let fx of EFFECTS) { effectIds.push(fx.id) }
  let momentIds: string[] = []
  momentsOf(sketch).forEach((_d: string, key: string) => { momentIds.push(key) })
  // Inputs only an event left to a section reads: what they were for goes with it (a reminder's lead time).
  let sectionInputs: string[] = []
  for (let e of sketch.events) {
    let within = answerOf(answers, 'within.event.' + e.id, served, comp.answers, COVERED_ABOVE)
    if (within.length > 0) {
      comp.dropped.push('event "' + e.what + '": the section for "' + sketch.ready[Number(within.substring(6))] + '" does it')
      comp.claimed.push(e.what + ' (' + e.when + ')')
      let fx = effectOf(answerOf(answers, 'effect.' + e.id, effectIds, []))
      if (fx !== undefined) {
        for (let prm of fx.params) {
          let keys: string[] = []
          paramSources(sketch, prm).forEach((_d: string, key: string) => { keys.push(key) })
          let source = answerOf(answers, 'arg.' + e.id + '.' + fx.id + '.' + prm.name, keys, [], ARG_ABOVE)
          if (source.startsWith('input.')) { sectionInputs.push(source.substring(6)) }
        }
      }
      continue
    }
    let picked = answerOf(answers, 'effect.' + e.id, effectIds, comp.answers)
    let moment = momentIds.length > 0 ? answerOf(answers, 'moment.' + e.id, momentIds, comp.answers) : ''
    let missing = picked.length === 0 ? 'no effect' : (moment.length === 0 ? 'nothing on the screen marks that moment' : '')
    let fx = effectOf(picked)
    let args: Map<string, string> = new Map<string, string>()
    if (missing.length === 0 && fx !== undefined) {
      for (let prm of fx.params) {
        let keys: string[] = []
        paramSources(sketch, prm).forEach((_d: string, key: string) => { keys.push(key) })
        let source = answerOf(answers, 'arg.' + e.id + '.' + fx.id + '.' + prm.name, keys, comp.answers, ARG_ABOVE)
        if (source.length === 0) { missing = 'nothing gives ' + prm.describe; break }
        if (source.startsWith('entry.') && moment !== 'entry_added' && moment !== 'row_button') {
          missing = prm.describe + ' is an entry\'s, but no entry is added or tapped then'
          break
        }
        args.set(prm.name, source)
      }
      // An entry shows one answer: two effects answering for the same new entry would overwrite each other.
      if (missing.length === 0 && fx.done.length > 0 && moment === 'entry_added' && entryAnswerEvent(comp).length > 0) {
        missing = 'a second answer for the same entry'
      }
    }
    if (missing.length === 0) {
      comp.args.set(e.id, args)
      comp.effects.set(e.id, picked)
      comp.moments.set(e.id, moment)
      comp.events.push(e)
    } else if (e.asked && comp.widget && missing === 'no effect' &&
        answerOf(answers, 'detail.event.' + e.id, ['detail'], comp.answers, OTHER_ADDED_ABOVE) === 'detail') {
      comp.dropped.push('event "' + e.what + '": a detail of how the widget looks or is worked')
    } else if (e.asked && customEnabled) {
      // Something the phone or another app does that the effects cannot do as asked -- none of them is it, nothing on the
      // screen marks its moment, nothing gives one of its details: a section the model writes, shown the phone's
      // functions found for it, does it, with its own controls for what the screen lacks.
      let need = e.what + ' (' + e.when + ')'
      comp.custom.push(need)
      comp.phoneNeeds.push(need)
      comp.unboundNeeds.push(need)
      if (picked.length > 0) { comp.customEffects.set(need, picked) }
    } else if (e.asked) {
      comp.unbound.push('event "' + e.what + '": ' + missing)
      comp.unboundNeeds.push(e.what + ' (' + e.when + ')')
    } else {
      // The sketch's own idea, not the request's: leave it out rather than refuse the screen.
      comp.dropped.push('event "' + e.what + '": ' + missing)
    }
  }

  chooseSections(comp, answers)
  readLogInCharts(comp)

  // An item of "other" may still be something a part does; only Jev's confident "this part" covers it.
  let partIds: string[] = []
  partsOf(sketch).forEach((_d: string, key: string) => { partIds.push(key) })
  for (let i = 0; i < sketch.other.length; i++) {
    // An item a section took over when it took a part's place (handRoundsToTimer) is gone from the composition's plan.
    if (comp.sketch.other.indexOf(sketch.other[i]) < 0) { continue }
    if (isScene(sketch.other[i])) {
      if (customEnabled) { comp.custom.push(sketch.other[i]) } else { comp.unbound.push('not in the vocabulary: ' + sketch.other[i]) }
      continue
    }
    let within = answerOf(answers, 'within.other.' + i.toString(), served, comp.answers, COVERED_ABOVE)
    if (within.length > 0) { comp.claimed.push(sketch.other[i]); continue }
    if (comp.blocks.indexOf('itinerary') >= 0 &&
        answerOf(answers, 'itinerary.other.' + i.toString(), ['yes'], comp.answers, COVERED_ABOVE) === 'yes') {
      comp.claimed.push(sketch.other[i])
      continue
    }
    let covered = answerOf(answers, 'covers.' + i.toString(), partIds, comp.answers)
    let a = answers['covers.' + i.toString()] as Record<string, Object>
    let confidence = a !== null && a !== undefined && typeof a['confidence'] === 'number' ? a['confidence'] as number : 0
    if (covered.length > 0 && confidence >= COVERED_ABOVE) {
      // The item names how a part is drawn: that control for the input, the bar for the fraction.
      let named = covered.split('.')
      if (named[0] === 'widget') { comp.widgets.set(named[1], named[2]) }
      let bound = comp.bindings.get(named[1])
      if (named[0] === 'bar' && bound !== undefined) { bound.show = 'progress' }
      if (named[0] === 'figures') { comp.figures = true }
    } else if (answerOf(answers, 'asked.other.' + i.toString(), ['added'], comp.answers, OTHER_ADDED_ABOVE) === 'added') {
      comp.dropped.push('"' + sketch.other[i] + '": not asked for, and nothing does it')
    } else if (comp.widget && answerOf(answers, 'detail.' + i.toString(), ['detail'], comp.answers, OTHER_ADDED_ABOVE) === 'detail') {
      comp.dropped.push('"' + sketch.other[i] + '": a detail of how the widget looks or is worked')
    } else {
      if (customEnabled) { comp.custom.push(sketch.other[i]) } else { comp.unbound.push('not in the vocabulary: ' + sketch.other[i]) }
    }
  }
  // A field of the list that the request did not ask for and nothing reads -- not an argument, not the title
  // (the first words), not the total (the first number) -- is left out, as an input is.
  let list = comp.sketch.list
  if (list !== null) {
    let used: string[] = []
    comp.args.forEach((given: Map<string, string>) => {
      given.forEach((source: string) => { if (source.startsWith('entry.')) { used.push(source.substring(6)) } })
    })
    let kept: ListField[] = []
    for (let f of list.fields) {
      let shown = f === firstField(list, 'text') || f === firstField(list, 'number')
      let extra = answerOf(answers, 'asked.field.' + f.id, ['added'], comp.answers, ADDED_ABOVE) === 'added'
      if (extra && !shown && used.indexOf(f.id) < 0) { comp.dropped.push('field "' + f.label + '": not asked for, and nothing reads it') }
      else { kept.push(f) }
    }
    if (kept.length < list.fields.length) {
      let trimmed = new SketchList()
      trimmed.label = list.label
      trimmed.fields = kept
      comp.sketch = withList(comp.sketch, trimmed)
    }
  }
  // The time of day that ends the plan's list of places or steps, when one of the figures worked out is it. Before the values
  // leave and the inputs are read: the itinerary's own times are not it (itineraryShows), nor is the day's start (dayStart).
  let sure: number = 0
  for (let v of comp.sketch.values) {
    if (v.format !== 'clock' || !comp.bindings.has(v.id)) { continue }
    if (answerOf(answers, 'deadline.' + v.id, ['yes'], comp.answers, DEADLINE_ABOVE) !== 'yes') { continue }
    let a = answers['deadline.' + v.id] as Record<string, Object>
    let confidence = typeof a['confidence'] === 'number' ? a['confidence'] as number : 1
    // Two that say yes: the surer one.
    if (confidence > sure) { sure = confidence; comp.deadline = v.id }
  }
  dropValues(comp, answers, failed, served, shownBySection)
  // One nothing could work out leaves all the same; the itinerary is then given no deadline rather than a name nothing defines.
  if (comp.deadline.length > 0 && !comp.bindings.has(comp.deadline)) { comp.deadline = '' }
  // Figures over points the plan could not work out are the ledger's balances, not a section to write.
  if (comp.replaced.some((r: Replaced): boolean => r.kind === 'points_ledger')) {
    let figures = comp.custom.filter((n: string): boolean => n.startsWith('the figure "') && LEDGER_WORDS.test(n))
    comp.custom = comp.custom.filter((n: string): boolean => figures.indexOf(n) < 0)
    for (let n of figures) { comp.dropped.push(n.substring(0, n.indexOf('":') + 1) + ': the points ledger shows the balances') }
    // The names may come back with the inputs a figure read; they are still the ledger's.
    let names = ledgerNames(comp)
    comp.inputs = comp.inputs.filter((i: SketchInput): boolean => names.indexOf(i.id) < 0)
    comp.customReads = comp.customReads.filter((id: string): boolean => names.indexOf(id) < 0)
  }
  // An input nothing reads does nothing. A number the request did not ask for is the sketch's extra and is
  // left out, and the note says so; one it asked for, a switch or words mean the request wants something
  // the parts do not do with it. The day's start time is read by the itinerary (dayStart).
  let read: string[] = [comp.countdownFrom, dayStart(comp)]
  comp.bindings.forEach((b: Binding) => {
    read.push(b.a)
    read.push(b.b)
    for (let name of b.reads) { read.push(name) }
  })
  comp.args.forEach((given: Map<string, string>) => {
    given.forEach((source: string) => { if (source.startsWith('input.')) { read.push(source.substring(6)) } })
  })
  for (let input of comp.sketch.inputs) {
    if (read.indexOf(input.id) >= 0 || comp.customReads.indexOf(input.id) >= 0) { comp.inputs.push(input); continue }
    let extra = isNumeric(input.kind) && answerOf(answers, 'asked.' + input.id, ['added'], comp.answers, ADDED_ABOVE) === 'added'
    if (extra) { comp.dropped.push('input "' + input.label + '": not asked for, and nothing reads it') }
    else if (sectionInputs.indexOf(input.id) >= 0 || answerOf(answers, 'within.input.' + input.id, served, comp.answers, COVERED_ABOVE).length > 0) {
      comp.dropped.push('input "' + input.label + '": a section does it')
      if (sectionInputs.indexOf(input.id) < 0) { comp.claimed.push('the person sets ' + input.label) }
    }
    // What the custom section does may well read it (the dice to roll): it stays, and the section is told it is there.
    else if (comp.custom.length > 0 && keptForCustom(comp, input)) {
      comp.inputs.push(input)
      comp.customReads.push(input.id)
    }
    // Nothing on the screen would use it: left out, and the person is told, rather than the screen refused.
    else { comp.dropped.push('input "' + input.label + '": nothing on the screen uses it') }
  }
  showEntryTotalsAsNumbers(comp)
  // Inputs that nothing reads make a form that does nothing: the sketch has lost what they were for.
  if (sketch.values.length === 0 && !sketch.hasCountdown && !sketch.hasStopwatch && sketch.list === null && comp.events.length === 0 &&
      comp.blocks.length === 0 && comp.custom.length === 0) {
    comp.unbound.push('nothing uses the inputs')
  }
  return comp
}

/**
 * Of the values nothing could work out, those the request did not ask for and nothing kept reads -- no
 * other value, not the countdown's length, not an item of "other" they were said to cover -- are left out,
 * as an input is; the rest refuse the screen. A value read only by others left out goes with them.
 */
/** The live figure a binding is no more than (a copy, times or over a fixed 1, a written formula of its name alone); '' for none. */
export function copiesLive(comp: Composition, b: Binding): string {
  let live = (id: string): boolean => comp.live.some((l: SketchLive): boolean => l.id === id)
  if (b.scale.length > 0) { return '' }
  let one = (id: string): boolean => comp.sketch.constants.some((k: SketchConstant): boolean => k.id === id && k.value === 1)
  if (b.formula === 'copy' && live(b.a)) { return b.a }
  if (b.formula === 'multiply' && live(b.a) && one(b.b)) { return b.a }
  if (b.formula === 'multiply' && live(b.b) && one(b.a)) { return b.b }
  if (b.formula === 'divide' && live(b.a) && one(b.b)) { return b.a }
  if (b.formula === 'written') {
    let m = /^\(*\s*([A-Za-z_][A-Za-z0-9_]*)\s*(\*\s*1(\.0+)?)?\s*\)*$/.exec(b.expr.trim())
    if (m !== null && live(m[1])) { return m[1] }
    let n = /^\(*\s*1(\.0+)?\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)*$/.exec(b.expr.trim())
    if (n !== null && live(n[2])) { return n[2] }
  }
  return ''
}

function dropValues(comp: Composition, answers: Record<string, Object>, failed: Map<string, string>, served: string[],
                    shownBySection: string[]): void {
  let sketch = comp.sketch
  // A figure a section took over when it took a part's place (handRoundsToTimer) is gone from the plan, and with it what failed of it.
  let taken: string[] = []
  failed.forEach((_why: string, id: string) => { if (!sketch.values.some((v: SketchValue): boolean => v.id === id)) { taken.push(id) } })
  for (let id of taken) { failed.delete(id) }
  // A live figure Jev said no to is fetched by nothing (readLive) and has no local to read (inputLocals): a value whose binding
  // reads it -- by the vocabulary's operands as much as by a written formula -- cannot be worked out.
  let unfetched: string[] = sketch.live.filter((l: SketchLive): boolean => !comp.live.some((k: SketchLive): boolean => k.id === l.id))
    .map((l: SketchLive): string => l.id)
  // A value worked out from one that cannot be is no better off: its example passed on a number given to it.
  for (let v of sketch.values) {
    let b = comp.bindings.get(v.id)
    if (failed.has(v.id) || b === undefined) { continue }
    let reads = [b.a, b.b].concat(b.reads)
    let live = reads.filter((id: string): boolean => unfetched.indexOf(id) >= 0)
    if (live.length > 0) { failed.set(v.id, 'reads ' + live.join(', ') + ', which nothing fetches'); continue }
    let from = reads.find((id: string): boolean => failed.has(id))
    if (from !== undefined) { failed.set(v.id, 'reads "' + labelOf(sketch, from) + '", which nothing works out') }
  }
  let leaving: string[] = []
  // A value a section of the catalogue shows is that section's, and leaves as one not asked for does. The itinerary's own times
  // leave whether or not a formula was found for them: one that was not would be written beside the itinerary instead.
  let sections: string[] = []
  let written: string[] = []
  let itinerary = itineraryShows(comp, answers)
  failed.forEach((_why: string, id: string) => {
    if (answerOf(answers, 'asked.value.' + id, ['added'], comp.answers, ADDED_ABOVE) === 'added') { leaving.push(id) }
    else if (answerOf(answers, 'within.value.' + id, served, comp.answers, COVERED_ABOVE).length > 0 || itinerary.indexOf(id) >= 0) {
      leaving.push(id); sections.push(id)
    }
  })
  // One a section shows that could be worked out leaves too, unless a figure that stays reads it (the loop below
  // brings it back, still bound).
  for (let id of shownBySection.concat(itinerary)) {
    if (!failed.has(id) && leaving.indexOf(id) < 0) { leaving.push(id); sections.push(id) }
  }
  // The same figure twice -- the same formula over the same names, drawn the same way -- is shown once: the plan named "goal
  // progress" and "progress" for one fraction and both came out as bars (Water reminder).
  let seen: string[] = []
  // The deadline first, so that of two the same it is the other that leaves.
  let order = sketch.values.filter((v: SketchValue): boolean => v.id === comp.deadline)
    .concat(sketch.values.filter((v: SketchValue): boolean => v.id !== comp.deadline))
  for (let v of order) {
    let b = comp.bindings.get(v.id)
    if (b === undefined || failed.has(v.id) || leaving.indexOf(v.id) >= 0 || v.hidden) { continue }
    // A figure that is a live figure itself ("$1 in rubles" beside the rate) is that figure twice: the live section shows it.
    let copied = copiesLive(comp, b)
    if (copied.length > 0) {
      leaving.push(v.id)
      comp.dropped.push('value "' + v.label + '": the live section shows ' + copied)
      continue
    }
    let key = [b.formula, b.a, b.b, b.expr, b.scale, b.show].join('|')
    if (seen.indexOf(key) >= 0) { leaving.push(v.id) } else { seen.push(key) }
  }
  let covering: string[] = []
  for (let i = 0; i < sketch.other.length; i++) {
    let a = answers['covers.' + i.toString()] as Record<string, Object>
    let part = a !== null && a !== undefined && typeof a['choice'] === 'string' ? (a['choice'] as string).split('.') : []
    if (part.length === 2 && (part[0] === 'value' || part[0] === 'bar')) { covering.push(part[1]) }
  }
  let changed = true
  while (changed) {
    changed = false
    // The deadline stays with what it is worked out from: the itinerary reads it (the deadline port), and it was chosen before the
    // values left, so one that left would point at nothing.
    let needed: string[] = dependsOn(comp, comp.countdownFrom).concat(covering, dependsOn(comp, comp.deadline))
    for (let v of sketch.values) {
      if (leaving.indexOf(v.id) >= 0) { continue }
      let b = comp.bindings.get(v.id)
      if (b !== undefined) { needed = needed.concat([b.a, b.b], b.reads) }
    }
    let kept = leaving.filter((id: string): boolean => needed.indexOf(id) < 0)
    changed = kept.length < leaving.length
    leaving = kept
  }
  // A figure nothing can work out, that the request wants, is left to the custom section: the model writes its working
  // and Jev reads it against what the figure means (agent/AgentCustom.ets). Its inputs stay on the screen for it.
  if (customEnabled) {
    // Not one the parts themselves read -- the countdown's length, a figure worked out from it: the written section's names
    // are its own, so the parts would be left reading a name nothing defines.
    let readByParts: string[] = dependsOn(comp, comp.countdownFrom)
    for (let v of sketch.values) {
      let b = comp.bindings.get(v.id)
      if (b === undefined || failed.has(v.id)) { continue }
      readByParts = readByParts.concat([b.a, b.b], b.reads)
    }
    failed.forEach((_why: string, id: string) => {
      if (leaving.indexOf(id) >= 0) { return }
      // A figure a section took over when it took a part's place (handRoundsToTimer) is gone from the plan.
      let found = sketch.values.find((x: SketchValue): boolean => x.id === id)
      if (found === undefined) { return }
      let v: SketchValue = found
      if (readByParts.indexOf(id) >= 0) {
        // The parts read it by name -- the countdown's length, a figure worked out from it: it becomes a number the
        // person sets, under the same name, starting from the plan's own example.
        let measure = v.format === 'money' || v.format === 'percent' || v.format === 'minutes' || v.format === 'seconds' ?
          v.format : 'number'
        defaultInput(comp, id, v.label, measure, v.result)
        leaving.push(id)
        written.push(id)
        return
      }
      comp.custom.push('the figure "' + v.label + '": ' + v.means + figureForm(v))
      for (let input of sketch.inputs) { if (new RegExp('\\b' + input.id + '\\b').test(v.formula)) { comp.customReads.push(input.id) } }
      leaving.push(id)
      written.push(id)
    })
  }
  failed.forEach((why: string, id: string) => {
    let label = labelOf(sketch, id)
    if (written.indexOf(id) >= 0) { return }
    if (leaving.indexOf(id) < 0) { comp.unbound.push('"' + label + '": ' + why) }
    else if (sections.indexOf(id) >= 0) { claimShown(comp, label, itinerary.indexOf(id) >= 0) }
    else { comp.dropped.push('value "' + label + '": not asked for, and ' + why) }
  })
  for (let id of unique(shownBySection.concat(itinerary))) {
    if (failed.has(id) || leaving.indexOf(id) < 0) { continue }
    claimShown(comp, labelOf(sketch, id), itinerary.indexOf(id) >= 0)
  }
  if (leaving.length === 0) { return }
  for (let id of leaving) { comp.bindings.delete(id) }
  let out = withList(sketch, sketch.list)
  out.values = sketch.values.filter((v: SketchValue): boolean => leaving.indexOf(v.id) < 0)
  comp.sketch = out
  if (out.values.length === 0 && !out.hasCountdown && !out.hasStopwatch && out.list === null && comp.events.length === 0 &&
      comp.blocks.length === 0 && comp.custom.length === 0) {
    comp.unbound.push('nothing left to show once the values not asked for are left out')
  }
}

/**
 * A number the value's own description works with that no formula can reach: formulas take no literals,
 * so "distance times consumption divided by 100" with no constant 100 has no right option, and Jev's
 * pick among the wrong ones is the nearest, not the answer. The numbers inside a percent formula, and the
 * 60 between seconds and minutes for a time value, count.
 */
function strayNumber(sketch: Sketch, v: SketchValue, formula: string): string {
  let held: number[] = []
  for (let c of sketch.constants) { held.push(c.value) }
  if (formula === 'percent_of' || formula === 'add_percent' || formula === 'subtract_percent' || formula === 'ratio_percent') {
    held.push(100)
    held.push(1)
  }
  // A time value converts between seconds and minutes itself.
  if (isTime(v.format)) { held.push(60) }
  let found = v.means.match(/\d+(\.\d+)?/g)
  if (found === null) { return '' }
  for (let n of found) {
    if (held.indexOf(Number(n)) < 0) { return n }
  }
  return ''
}

/**
 * A written formula is used only when it parses into the names the screen has, reproduces the sketch's own
 * worked example, and Jev reads it as right for the request.
 */
const WRITTEN_ABOVE: number = 0.5
/**
 * How sure Jev must be that a figure is the time that ends the plan's list for the sections that read it to hide what runs past it.
 * Not tuned: the one right case seen on a phone came at 0.46 (and 0.34 as one of three); what is hidden is said in a banner.
 */
const DEADLINE_ABOVE: number = 0.4

/**
 * Binds value number `index` to the sketch's written formula, or says why not. The worked example is run
 * through the values before it as they are bound, so a mistake earlier in the chain fails here too.
 */
function useWritten(comp: Composition, answers: Record<string, Object>, index: number, binding: Binding): string {
  let sketch = comp.sketch
  let v = sketch.values[index]
  if (v.formula.length === 0) { return 'no written formula' }
  let parsed = parseFormula(v.formula, formulaNames(sketch, index))
  if (parsed.node === null) { return 'its written formula ' + parsed.error }
  if (Number.isNaN(v.result)) { return 'its written formula has no worked example' }
  let env = exampleNumbers(comp, index)
  let got = evalFormula(parsed.node, env)
  if (Number.isNaN(got)) {
    let missing = parsed.reads.filter((name: string): boolean => !env.has(name) || Number.isNaN(env.get(name)!))
    return 'its worked example gives no number for ' + (missing.length > 0 ? missing.join(', ') : 'it')
  }
  if (Math.abs(got - v.result) > Math.max(0.011, Math.abs(v.result) * 0.006)) {
    return 'its written formula gives ' + numberLiteral(Math.round(got * 1000) / 1000) + ' for its worked example, not ' + numberLiteral(v.result)
  }
  if (answerOf(answers, 'written.' + v.id, ['right'], comp.answers, WRITTEN_ABOVE).length === 0) {
    return 'Jev does not read its written formula as right'
  }
  binding.formula = 'written'
  binding.expr = formulaVera(parsed.node)
  binding.reads = parsed.reads
  // As for the vocabulary's formulas: seconds shown as minutes are divided, not read as minutes. An egg timer's
  // "time left", format minutes, was written as the countdown's remaining seconds and read 6:00:00 for 6 minutes.
  let m = writtenMeasure(parsed.node, operandList(sketch, index))
  binding.scale = m === 'seconds' && v.format === 'minutes' ? ' / 60' : (m === 'minutes' && v.format === 'seconds' ? ' * 60' : '')
  comp.answers.push('written.' + v.id + ': ' + v.formula)
  return ''
}

/**
 * Whether value `v`'s written formula does something formula `formulaId` of the vocabulary cannot: bounds it (max, min),
 * takes its size (abs), rounds it or raises it. A ceil is what divide_up and round_up already do.
 */
export function writtenSaysMore(v: SketchValue, formulaId: string): boolean {
  let calls = v.formula.match(/\b(max|min|abs|floor|ceil|round|pow|sqrt)\s*\(/g)
  if (calls === null) { return false }
  let rounding = formulaId === 'divide_up' || formulaId === 'round_up'
  return calls.some((c: string): boolean => !(rounding && c.indexOf('ceil') === 0))
}

/**
 * The numbers the worked example of value number `index` runs on: the example's own, then the inputs' starting
 * numbers and the constants, then each value before it as bound so far.
 */
function exampleNumbers(comp: Composition, index: number): Map<string, number> {
  let sketch = comp.sketch
  let v = sketch.values[index]
  let env: Map<string, number> = new Map<string, number>()
  for (let input of sketch.inputs) {
    if (!isNumeric(input.kind)) { continue }
    if (input.kind === 'choice') {
      let o = input.options[Math.round(input.value)]
      env.set(input.id, o !== undefined ? o.value : NaN)
    } else {
      env.set(input.id, input.value)
    }
  }
  for (let c of sketch.constants) { env.set(c.id, c.value) }
  v.given.forEach((n: number, key: string) => { env.set(key, n) })
  for (let k = 0; k < index; k++) {
    let earlier = sketch.values[k]
    if (v.given.has(earlier.id)) { continue }
    env.set(earlier.id, boundNumber(comp, k, env))
  }
  return env
}

/** What value number `k` comes to under `env` as it is bound; NaN when it is not bound. */
function boundNumber(comp: Composition, k: number, env: Map<string, number>): number {
  let earlier = comp.sketch.values[k]
  let b = comp.bindings.get(earlier.id)
  if (b === undefined) { return NaN }
  let n = NaN
  if (b.formula === 'written') {
    let parsed = parseFormula(earlier.formula, formulaNames(comp.sketch, k))
    n = parsed.node !== null ? evalFormula(parsed.node, env) : NaN
    return b.scale === ' / 60' ? n / 60 : (b.scale === ' * 60' ? n * 60 : n)
  }
  let a = env.get(b.a) ?? NaN
  let o = env.get(b.b) ?? NaN
  let share = (x: number, y: number): number => y === 0 ? 0 : x / y
  if (b.formula === 'copy') { n = a }
  else if (b.formula === 'add') { n = a + o }
  else if (b.formula === 'subtract') { n = a - o }
  else if (b.formula === 'multiply') { n = a * o }
  else if (b.formula === 'divide') { n = share(a, o) }
  else if (b.formula === 'divide_up') { n = Math.ceil(share(a, o)) }
  else if (b.formula === 'percent_of') { n = a * o / 100 }
  else if (b.formula === 'add_percent') { n = a * (1 + o / 100) }
  else if (b.formula === 'subtract_percent') { n = a * (1 - o / 100) }
  else if (b.formula === 'round_up') { n = Math.ceil(a) }
  else if (b.formula === 'ratio_percent') { n = share(a, o) * 100 }
  if (b.scale === ' / 60') { n = n / 60 }
  if (b.scale === ' * 60') { n = n * 60 }
  return n
}

/** The kept event whose effect's answer is shown on the entry it was added with, or ''. */
function entryAnswerEvent(comp: Composition): string {
  for (let e of comp.events) {
    let fx = effectOf(comp.effects.get(e.id) ?? '')
    if (fx !== undefined && fx.done.length > 0 && comp.moments.get(e.id) === 'entry_added') { return e.id }
  }
  return ''
}

/** Covering a missing feature serves a screen, so it takes more than picking a widget does. */
const COVERED_ABOVE: number = 0.5
/** An effect's argument decides what the phone is told, so it takes what a formula's operand takes. */
const ARG_ABOVE: number = 0.4
/** A length in the wrong unit runs the countdown sixty times too long or too short. */
const UNIT_ABOVE: number = 0.5
/** Leaving an input out hides it from the person, so Jev has to be as sure it was not asked for. */
const ADDED_ABOVE: number = 0.5

/**
 * Higher than for an input or a value: an item of "other" is often the very thing the vocabulary lacks
 * ("restaurants near me"), and leaving it out serves a screen without it. Set before any run, not tuned.
 */
const OTHER_ADDED_ABOVE: number = 0.7

/** A section is a whole part of the screen, so it takes the bar a block takes in the blocks' own pick (SECTION_PICK_ABOVE). Not tuned. */
export const READY_ABOVE: number = 0.5
/** The option that is the composer's own part, in the questions that put a part and sections side by side. */
export const PART: string = 'part'
/** Sections that keep what the person enters, one entry at a time: the ones a list part may be replaced by. */
export const LIST_SECTIONS: string[] = ['record_log', 'reminders', 'quick_log', 'dose_schedule', 'due_items', 'points_ledger', 'reading_status']

/**
 * The sections that keep the person's entries and show their own figures over them (totals today, doses taken, items due soon,
 * balances, the latest reading's status): beside them the figures a plan works out over the entries leave for what the section
 * shows (replaceList). `reminders` shows none.
 */
export const LIST_PUBLISHERS: string[] = ['record_log', 'quick_log', 'dose_schedule', 'due_items', 'points_ledger', 'reading_status']

/** The sections a countdown may be: one countdown of a set time, or work and rest in rounds. */
export const CLOCK_SECTIONS: string[] = ['timer', 'interval_timer']
/** The bar the catalogue gives its own needs_real_data question (VeraTemplates.vetoes). */
const REAL_DATA_ABOVE: number = 0.35
/** Made-up records in place of the person's own mislead; any lean toward "own" refuses the section. Not tuned. */
const OWN_RECORDS_ABOVE: number = 0.2

// ---- Assembling the program ----

function quote(s: string): string {
  return '"' + s.split('\\').join('\\\\').split('"').join('\\"').split('\n').join(' ') + '"'
}

function numberLiteral(n: number): string {
  return isFinite(n) ? n.toString() : '0'
}

class Field {
  name: string
  type: string
  init: string
  constructor(name: string, type: string, init: string) {
    this.name = name
    this.type = type
    this.init = init
  }
}

function inputFields(comp: Composition): Field[] {
  let fields: Field[] = []
  for (let input of comp.inputs) {
    let widget = comp.widgets.get(input.id) ?? ''
    if (input.kind === 'toggle') {
      fields.push(new Field(input.id, 'boolean', input.value !== 0 ? 'true' : 'false'))
    } else if (input.kind === 'text') {
      fields.push(new Field(input.id, 'string', '""'))
    } else if (input.kind === 'choice') {
      let start = Math.max(0, Math.min(input.options.length - 1, Math.round(input.value)))
      fields.push(new Field(input.id + 'Index', 'number', start.toString()))
    } else if (widget === 'typed_number') {
      fields.push(new Field(input.id + 'Text', 'string', quote(numberLiteral(input.value))))
    } else {
      fields.push(new Field(input.id, 'number', numberLiteral(input.value)))
    }
  }
  return fields
}

function clockFields(): Field[] {
  return [new Field('elapsedMs', 'number', '0'), new Field('running', 'boolean', 'false'), new Field('finished', 'boolean', 'false')]
}

function entryFields(list: SketchList): Field[] {
  let fields: Field[] = [new Field('entries', 'LogEntry[]', 'emptyEntries')]
  for (let f of list.fields) { fields.push(new Field(draftOf(f), draftType(f), draftInit(f))) }
  // The entry removed last and where it stood, so one tap can put it back (none, or exactly one).
  fields.push(new Field('removedEntries', 'LogEntry[]', 'emptyEntries'))
  fields.push(new Field('removedAt', 'number', '-1'))
  return fields
}

function effectFields(comp: Composition): Field[] {
  let fields: Field[] = []
  if (hasBanner(comp)) { fields.push(new Field('effectStatus', 'string', '""')) }
  if (keepsCalendarIds(comp)) { fields.push(new Field('calendarIds', 'string', '""')) }
  return fields
}

/** A countdown or a stopwatch: both run on a Ticker with start, stop and reset. */
export function hasClock(sketch: Sketch): boolean { return sketch.hasCountdown || sketch.hasStopwatch }

/** The state field holding what the form has for `f` before the entry is added. */
function draftOf(f: ListField): string { return 'draft_' + f.id }

/**
 * Words and numbers are typed, so their drafts are text; a time is minutes since midnight, a date the day number
 * time.daysSinceEpoch() counts; an on/off is a boolean.
 */
function draftType(f: ListField): string {
  if (f.kind === 'time' || f.kind === 'date') { return 'number' }
  if (f.kind === 'toggle') { return 'boolean' }
  return 'string'
}

function draftInit(f: ListField): string {
  if (f.kind === 'time') { return numberLiteral(f.value) }
  // A date starts at today: an expiry or a due date typed as words could not be compared with any day (Pantry expiry).
  if (f.kind === 'date') { return 'time.daysSinceEpoch()' }
  if (f.kind === 'toggle') { return f.value !== 0 ? 'true' : 'false' }
  return '""'
}

/** The entry's value of `f`, read from the form. */
function draftValue(f: ListField): string {
  if (f.kind === 'text') { return 'strings.trim(state.' + draftOf(f) + ')' }
  if (f.kind === 'number') { return 'strings.toNumber(state.' + draftOf(f) + ', 0)' }
  return 'state.' + draftOf(f)
}

function entryType(f: ListField): string {
  if (f.kind === 'text') { return 'string' }
  if (f.kind === 'toggle') { return 'boolean' }
  return 'number'
}

/** Whether some kept event's answer goes to the screen's banner rather than to an entry. */
function hasBanner(comp: Composition): boolean {
  let answering = entryAnswerEvent(comp)
  return comp.events.some((e: SketchEvent): boolean => e.id !== answering)
}

/** The expression a paramSources key stands for, where the call is made. */
function sourceExpr(comp: Composition, source: string): string {
  let dot = source.indexOf('.')
  let scope = source.substring(0, dot)
  let id = source.substring(dot + 1)
  if (scope === 'entry') { return 'entry.' + id }
  if (scope === 'fixed') { return id === 'title' ? quote(comp.sketch.title) : '0' }
  if (scope === 'input') {
    let input = comp.sketch.inputs.find((i: SketchInput): boolean => i.id === id)
    // Numbers are locals (inputLocals); words and on/offs are read from state.
    if (input !== undefined && !isNumeric(input.kind)) { return 'state.' + id }
  }
  return id
}

function sourceMeasure(sketch: Sketch, source: string): string {
  let id = source.substring(source.indexOf('.') + 1)
  if (source.startsWith('entry.') && sketch.list !== null) {
    for (let f of sketch.list.fields) { if (f.id === id) { return f.measure } }
  }
  return measureOf(sketch, id)
}

/** Whether the calls at `moment` read a number input or a constant, which then need their locals. */
function callsNeedLocals(comp: Composition, moment: string): boolean {
  let needed = false
  for (let e of comp.events) {
    if (comp.moments.get(e.id) !== moment) { continue }
    (comp.args.get(e.id) ?? new Map<string, string>()).forEach((source: string) => {
      if (source.startsWith('const.') || (source.startsWith('input.') && sourceExpr(comp, source).indexOf('state.') < 0)) { needed = true }
    })
  }
  return needed
}

/** The handler a tap at `moment` runs for event `id`. */
function tapHandler(id: string, moment: string): string { return (moment === 'row_button' ? 'row_' : 'do_') + id }

/** Lines adding `value` to state.calendarIds as `ids` when it is an event ID (addEvent answers with one). */
function idCapture(): string[] {
  return ['  let ids: string = state.calendarIds;',
    '  if (strings.toNumber(value, 0) > 0) { if (ids === "") { ids = value; } else { ids = ids + "," + value; } }']
}

/** Whether the program keeps the IDs of the calendar events it adds: it also has an effect that deletes them. */
function keepsCalendarIds(comp: Composition): boolean {
  let kept: string[] = []
  comp.effects.forEach((fx: string) => { kept.push(fx) })
  return kept.indexOf('calendar_add') >= 0 && kept.indexOf('calendar_clear') >= 0
}

/**
 * The lines that make the calls for the events at `moment` (only `only`'s, when given): each argument worked
 * out, then sdk.call.
 */
function effectCallsAt(comp: Composition, moment: string, only: string = ''): string[] {
  let calls: string[] = []
  let answering = entryAnswerEvent(comp)
  for (let n = 0; n < comp.events.length; n++) {
    let e = comp.events[n]
    if (comp.moments.get(e.id) !== moment || (only.length > 0 && e.id !== only)) { continue }
    let fx = effectOf(comp.effects.get(e.id) ?? '')
    if (fx === undefined) { continue }
    let args: string[] = []
    for (let a of fx.fixed) { args.push(quote(a)) }
    let given = comp.args.get(e.id) ?? new Map<string, string>()
    for (let prm of fx.params) {
      let source = given.get(prm.name) ?? ''
      // Locals take an underscore, which no id from the sketch has.
      let local = 'call_' + prm.name + n.toString()
      if (prm.kind === 'text') {
        args.push(quote(prm.key))
        args.push(sourceExpr(comp, source))
      } else if (prm.kind === 'clock') {
        calls.push('  let ' + local + ': number = math.round(' + sourceExpr(comp, source) + ');')
        args.push('"hour"')
        args.push('ui.numberToString(math.floor(' + local + ' / 60))')
        args.push('"minute"')
        args.push('ui.numberToString(' + local + ' % 60)')
      } else if (prm.kind === 'toggle') {
        args.push(quote(prm.key))
        if (source === 'fixed.daily' || source === 'fixed.once') {
          args.push(source === 'fixed.daily' ? '"daily"' : '"once"')
        } else {
          calls.push('  let ' + local + ': string = "once";')
          calls.push('  if (' + sourceExpr(comp, source) + ') { ' + local + ' = "daily"; }')
          args.push(local)
        }
      } else if (prm.kind === 'number') {
        args.push(quote(prm.key))
        args.push(source === 'fixed.blank' ? '""' : 'ui.numberToString(' + sourceExpr(comp, source) + ')')
      } else if (source === 'fixed.zero') {
        args.push(quote(prm.key))
        args.push('"0"')
      } else if (source !== 'fixed.none') {
        let per = sourceMeasure(comp.sketch, source) === 'seconds' ? ' / 60' : ''
        args.push(quote(prm.key))
        args.push('ui.numberToString(math.round(' + sourceExpr(comp, source) + per + '))')
      }
    }
    let handler = e.id === answering ? 'onEntryAnswer' : 'onEffect'
    if (fx.id === 'calendar_add' && e.id !== answering && keepsCalendarIds(comp)) { handler = 'onCalendarAdded' }
    let mode = fx.mode.length > 0 ? ', ' + quote(fx.mode) : ''
    if (fx.id === 'calendar_clear') {
      // Only the events this program added, by the IDs their answers gave; with none there is nothing to ask.
      let ids = keepsCalendarIds(comp) ? 'state.calendarIds' : '""'
      calls.push('  if (' + ids + ' !== "") { sdk.call(' + quote(fx.target) + ', ["ids", ' + ids + '], "onCalendarCleared"); }')
      continue
    }
    calls.push('  sdk.call(' + quote(fx.target) + ', [' + args.join(', ') + '], ' + quote(handler) + mode + ');')
  }
  return calls
}

/**
 * The digits after the point a number is shown with: what the sketch asks for a plain number or a count (a measurement that
 * loses its meaning rounded to one digit), else the measure's own -- cents for money, whole for a count, one otherwise.
 */
function decimalsFor(measure: string, asked: number): number {
  if (asked >= 0 && (measure === 'number' || measure === 'plain' || measure === 'count')) { return asked }
  // A fraction (0.0054, a monthly rate) is shown with enough digits to say something; one digit would read as 0.0.
  if (measure === 'fraction') { return asked >= 0 ? asked : 4 }
  return measure === 'money' ? 2 : (measure === 'count' ? 0 : 1)
}

function amountText(measure: string, unit: string, expr: string, asked: number = -1): string {
  if (measure === 'money') { return quote(unit) + ' + ui.formatNumber(' + expr + ', 2)' }
  if (measure === 'percent') { return 'ui.formatNumber(' + expr + ', 1) + "%"' }
  if (isTime(measure)) { return durationText(measure, expr) }
  if (measure === 'clock') { return 'ui.clockToString(math.round((' + expr + ') - math.floor((' + expr + ') / 1440) * 1440))' }
  return 'ui.formatNumber(' + expr + ', ' + decimalsFor(measure, asked).toString() + ')'
}

/**
 * `{b: value, ...}` setting the named fields the program has; the composer passes every other field through
 * (__PASSTHROUGH__ in VeraSectionCompose.ets).
 */
function changed(fields: Field[], replaced: Map<string, string>): string {
  let parts: string[] = []
  replaced.forEach((value: string, name: string) => {
    if (fields.some((f: Field): boolean => f.name === name)) { parts.push(name + ': ' + value) }
  })
  return '{' + parts.join(', ') + '__PASSTHROUGH__}'
}

/** Lines that bring every numeric input into a local of its own name, read from state. */
function inputLocals(comp: Composition): string[] {
  let lines: string[] = []
  for (let input of comp.inputs) {
    let widget = comp.widgets.get(input.id) ?? ''
    if (!isNumeric(input.kind)) { continue }
    if (input.kind === 'choice') {
      let values: string[] = []
      for (let o of input.options) { values.push(numberLiteral(o.value)) }
      lines.push('  let ' + input.id + 'Values: number[] = [' + values.join(', ') + '];')
      lines.push('  let ' + input.id + ': number = ' + input.id + 'Values[state.' + input.id + 'Index];')
    } else if (widget === 'typed_number') {
      lines.push('  let ' + input.id + ': number = strings.toNumber(state.' + input.id + 'Text, 0);')
    } else {
      lines.push('  let ' + input.id + ': number = state.' + input.id + ';')
    }
  }
  for (let c of comp.sketch.constants) { lines.push('  let ' + c.id + ': number = ' + numberLiteral(c.value) + ';') }
  // A live figure is read off the live_figure section's state, through its port: what it fetched last, 0 before the first answer.
  for (let i = 0; i < comp.live.length; i++) { lines.push('  let ' + comp.live[i].id + ': number = ' + liveFigureNumber(i + 1) + ';') }
  return lines
}

/** How a formula's time converts to the value's unit: seconds left on a countdown shown as minutes, say. */
function timeScale(sketch: Sketch, index: number, b: Binding, format: string): string {
  if (!isTime(format)) { return '' }
  let operands = operandList(sketch, index)
  let a = operands.find((o: Operand): boolean => o.id === b.a)
  if (a === undefined) { return '' }
  let other = operands.find((o: Operand): boolean => o.id === b.b)
  let m = resultMeasure(b.formula, a, other !== undefined ? other : null)
  if (m === 'seconds' && format === 'minutes') { return ' / 60' }
  if (m === 'minutes' && format === 'seconds') { return ' * 60' }
  return ''
}

function formulaExpr(b: Binding): string {
  let e = bareExpr(b)
  return b.scale.length > 0 ? '(' + e + ')' + b.scale : e
}

function bareExpr(b: Binding): string {
  if (b.formula === 'written') { return b.expr }
  if (b.formula === 'copy') { return b.a }
  if (b.formula === 'add') { return b.a + ' + ' + b.b }
  if (b.formula === 'subtract') { return b.a + ' - ' + b.b }
  if (b.formula === 'multiply') { return b.a + ' * ' + b.b }
  if (b.formula === 'divide') { return 'share(' + b.a + ', ' + b.b + ')' }
  if (b.formula === 'divide_up') { return 'math.ceil(share(' + b.a + ', ' + b.b + '))' }
  if (b.formula === 'percent_of') { return b.a + ' * ' + b.b + ' / 100' }
  if (b.formula === 'add_percent') { return b.a + ' * (1 + ' + b.b + ' / 100)' }
  if (b.formula === 'subtract_percent') { return b.a + ' * (1 - ' + b.b + ' / 100)' }
  if (b.formula === 'round_up') { return 'math.ceil(' + b.a + ')' }
  if (b.formula === 'ratio_percent') { return 'share(' + b.a + ', ' + b.b + ') * 100' }
  return '0'
}

/** A time as m:ss (or h:mm:ss), from seconds or minutes. */
/**
 * What a number of an entry reads as in its row. A length of time the person logs (30 minutes of a workout) is a quantity with its
 * unit, "30 min", not 30:00, which reads as a time of day.
 */
function entryAmountText(f: ListField): string {
  if (isTime(f.measure)) {
    return 'ui.formatNumber(e.' + f.id + ', ' + (f.decimals >= 0 ? f.decimals : 0).toString() + ') + ' + quote(f.measure === 'minutes' ? ' min' : ' s')
  }
  return amountText(f.measure, f.unit, 'e.' + f.id, f.decimals)
}

function durationText(measure: string, expr: string): string {
  return 'ui.durationToString(math.ceil(' + expr + (measure === 'minutes' ? ' * 60' : '') + '))'
}

/** A formula whose answer is a yes or a no: a condition giving 1 or 0 (or 0 or 1). */
export function isYesNoFormula(formula: string): boolean {
  return /\?\s*(1|0)\s*:\s*(0|1)\s*\)?\s*$/.test(formula.trim()) && !/\?\s*(1|0)\s*:\s*\1\s*\)?\s*$/.test(formula.trim())
}

/** Yes or No for a figure that is a yes or a no, as the text a stat or a row shows. */
function yesNoText(expr: string): string { return '((' + expr + ') !== 0 ? "Yes" : "No")' }

function statFor(v: SketchValue, expr: string): string {
  if (v.yesNo) { return 'ui.Stat("default", ' + quote(v.label) + ', ' + yesNoText(expr) + ', "", "check")' }
  if (isTime(v.format) || v.format === 'clock') {
    return 'ui.Stat("default", ' + quote(v.label) + ', ' + amountText(v.format, v.unit, expr) + ', "", "clock")'
  }
  let prefix = v.format === 'money' ? v.unit : ''
  let suffix = v.format === 'percent' ? '%' : (v.format !== 'money' && v.unit.length > 0 ? ' ' + v.unit : '')
  let decimals = decimalsFor(v.format, v.decimals)
  return 'ui.NumberStat("default", ' + quote(v.label) + ', ' + expr + ', ' + quote(prefix) + ', ' + quote(suffix) + ', 1, "", "chart", ' + decimals.toString() + ')'
}

/** One row of the figures' table: the label, and the number at the right edge as a stat would show it. */
function figureRow(v: SketchValue, expr: string): string {
  if (v.yesNo) { return 'ui.ListItem("default", ' + quote(v.label) + ', "", ' + yesNoText(expr) + ', "", 0, true, "")' }
  if (isTime(v.format) || v.format === 'clock') {
    return 'ui.ListItem("default", ' + quote(v.label) + ', "", ' + amountText(v.format, v.unit, expr) + ', "", 0, false, "")'
  }
  let prefix = v.format === 'money' ? v.unit : ''
  let suffix = v.format === 'percent' ? '%' : (v.format !== 'money' && v.unit.length > 0 ? ' ' + v.unit : '')
  let decimals = decimalsFor(v.format, v.decimals)
  return 'ui.NumberListItem("default", ' + quote(v.label) + ', "", ' + expr + ', ' + quote(prefix) + ', ' + quote(suffix) +
    ', 1, "", 0, false, "", ' + decimals.toString() + ')'
}

function heroText(v: SketchValue, expr: string): string {
  if (v.yesNo) { return yesNoText(expr) }
  if (isTime(v.format) || v.format === 'clock') { return amountText(v.format, v.unit, expr) }
  if (v.format === 'money') { return quote(v.unit) + ' + ui.formatNumber(' + expr + ', 2)' }
  if (v.format === 'percent') { return 'ui.formatNumber(' + expr + ', 1) + "%"' }
  return 'ui.formatNumber(' + expr + ', ' + decimalsFor(v.format, v.decimals).toString() + ')'
}

/** A block made for this request, for the blocks' composer (composeFragments): its names are its own, never renamed. */
function part(kind: string, fields: Field[], functions: string[], view: string[], supportClass: string = '', initStatements: string = ''): FragmentSpec {
  let state: StateFieldSpec[] = []
  let inits: string[] = []
  for (let f of fields) {
    state.push(new StateFieldSpec(f.name, f.type))
    inits.push(f.name + ': ' + f.init)
  }
  let spec = new FragmentSpec(kind, '', supportClass, state, initStatements, inits.join(', '), functions.join('\n\n'), view.join('\n'), [], [])
  spec.indexed = false
  return spec
}

/** The text of a function: its lines joined. */
function fn(lines: string[]): string { return lines.join('\n') }

/** What the figures come to on the screen, worked out once for the hero, the summary and a widget's first section. */
class Figures {
  /** Values shown as the hero, by id (a screen shows the first). */
  heroes: string[] = []
  /** Progress bars. */
  bars: string[] = []
  /** Stats for the metric group: a widget's hero values first. */
  stats: string[] = []
  /** The figures as one table, '' when they are not one. */
  table: string = ''
  /** The clock's time, for a hero or a widget's stat. */
  clockLabel: string = ''
  clockShown: string = ''
  clockButtons: string = ''
}

/** Whether value `v` is an average over the list's entries: it divides by their count, and says "average" or "mean". */
function isEntryAverage(sketch: Sketch, v: SketchValue, b: Binding): boolean {
  if (sketch.list === null || (b.b !== 'entryCount' && b.reads.indexOf('entryCount') < 0)) { return false }
  let words = (v.label + ' ' + v.means).toLowerCase()
  return words.indexOf('average') >= 0 || words.indexOf('mean') >= 0 || words.indexOf('avg') >= 0
}

/** How many figures a row of stats shows at once: an average that is a dash until there are entries takes two places in the list, one on screen. */
function statColumns(stats: string[]): number {
  return stats.filter((st: string): boolean => st.indexOf('ui.When(entryCount === 0,') !== 0).length
}

/**
 * How full a bar for value `v` is, as a share of one: a fraction already is one, a percent is a hundredth of itself.
 * Empty for any other value -- a count or an amount has no "full", so it is shown as a figure instead of a bar.
 */
export function barFraction(v: SketchValue): string {
  if (v.format === 'fraction') { return v.id }
  if (v.format === 'percent') { return '(' + v.id + ' / 100)' }
  return ''
}

function figuresOf(comp: Composition): Figures {
  let sketch = comp.sketch
  let out = new Figures()
  let stats: string[] = []
  let leading: string[] = []
  for (let v of sketch.values) {
    let b = comp.bindings.get(v.id)!
    // A step toward another figure is worked out with the rest and shown nowhere.
    if (v.hidden) { continue }
    if (b.show === 'hero' && comp.widget) { leading.push(statFor(v, v.id)) }
    else if (b.show === 'hero') { out.heroes.push(v.id) }
    else if (b.show === 'progress' && barFraction(v).length > 0) {
      out.bars.push('ui.Progress("accent", ' + quote(v.label) + ', math.round(math.min(math.max(' + barFraction(v) + ', 0), 1) * 1000), 1000)')
    }
    else if (comp.provisional && b.formula.length === 0) { stats.push('ui.Stat("default", ' + quote(v.label) + ', "—", "", "chart")') }
    else if (isEntryAverage(sketch, v, b)) {
      // An average of no entries is not 0.0: until there is one, the figure is a dash.
      stats.push('ui.When(entryCount > 0, ' + statFor(v, v.id) + ')')
      stats.push('ui.When(entryCount === 0, ui.Stat("default", ' + quote(v.label) + ', "—", "", "chart"))')
    }
    else { stats.push(statFor(v, v.id)) }
  }
  stats = leading.concat(stats)
  // The fixed numbers the figures are worked out from -- a tip split's bill -- as rows of the figures' table when
  // one was asked for, and as figures of their own on a screen with nothing to set.
  let displayOnly = comp.inputs.length === 0 && sketch.list === null && !hasClock(sketch)
  let givens: SketchValue[] = []
  if (comp.figures || displayOnly) {
    let read: string[] = []
    comp.bindings.forEach((b: Binding) => {
      read.push(b.a)
      read.push(b.b)
      for (let name of b.reads) { read.push(name) }
    })
    let currency = ''
    for (let v of sketch.values) { if (v.format === 'money' && currency.length === 0) { currency = v.unit } }
    for (let c of sketch.constants) {
      if (read.indexOf(c.id) < 0) { continue }
      let g = new SketchValue()
      g.id = c.id
      g.label = c.label
      g.format = c.measure === 'number' ? 'plain' : c.measure
      g.unit = c.measure === 'money' ? currency : ''
      givens.push(g)
    }
  }
  let figureRows: string[] = []
  if (comp.figures) {
    for (let g of givens) { figureRows.push(figureRow(g, g.id)) }
    for (let v of sketch.values) {
      let b = comp.bindings.get(v.id)!
      if (v.hidden || (b.show === 'progress' && barFraction(v).length > 0) || out.heroes.indexOf(v.id) >= 0) { continue }
      figureRows.push(figureRow(v, v.id))
    }
    stats = []
  } else if (displayOnly) {
    let fixed: string[] = []
    for (let g of givens) { fixed.push(statFor(g, g.id)) }
    stats = fixed.concat(stats)
  }
  out.stats = stats
  out.table = figureRows.length > 0 ? 'ui.ListGroup("default", "", [' + figureRows.join(', ') + '])' : ''
  // The clock brings its own time, so a sketch that lists no value for it still shows one.
  out.clockLabel = sketch.hasCountdown ? sketch.countdown : sketch.stopwatch
  // Time left rounds up (it reads 0:00 only at the end), time passed rounds down.
  out.clockShown = 'ui.durationToString(' + (sketch.hasCountdown ? 'math.ceil(remaining)' : 'math.floor(elapsed)') + ')'
  out.clockButtons = 'ui.ActionBar("spread", [ui.Button("primary", "Start", "onStart", 0, !state.running), ' +
    'ui.Button("secondary", "Stop", "onStop", 0, state.running), ' +
    (hasLaps(comp) ? 'ui.Button("secondary", "Lap", "lapEntry", 0, state.running), ' : '') +
    'ui.Button("secondary", "Reset", "onReset", 0, true)])'
  return out
}

/** The countdown or stopwatch: its state, its ticks, start, stop and reset, and the Ticker that drives it. */
function clockPart(comp: Composition, fields: Field[]): FragmentSpec {
  let sketch = comp.sketch
  let functions: string[] = []
  let ticking: Map<string, string> = new Map<string, string>()
  ticking.set('elapsedMs', 'next')
  if (sketch.hasCountdown) {
    let seconds: string[] = ['function countdownSeconds(state: AppState): number {']
    for (let l of inputLocals(comp)) { seconds.push(l) }
    // A length worked out from values brings those values along, in sketch order.
    let needed = dependsOn(comp, comp.countdownFrom)
    for (let v of sketch.values) {
      let b = comp.bindings.get(v.id)
      if (needed.indexOf(v.id) >= 0 && b !== undefined) { seconds.push('  let ' + v.id + ': number = ' + formulaExpr(b) + ';') }
    }
    let perUnit = comp.countdownUnit === 'minutes' ? ' * 60' : (comp.countdownUnit === 'hours' ? ' * 3600' : '')
    seconds.push('  return ' + (comp.countdownFrom.length > 0 ? comp.countdownFrom + perUnit : '0') + ';')
    seconds.push('}')
    functions.push(fn(seconds))

    let effectCalls = effectCallsAt(comp, 'countdown_end')
    let done: Map<string, string> = new Map<string, string>()
    done.set('elapsedMs', 'total'); done.set('running', 'false'); done.set('finished', 'true')
    if (effectCalls.length > 0) { done.set('effectStatus', '"pending"') }
    if (callsNeedLocals(comp, 'countdown_end')) { effectCalls = inputLocals(comp).concat(effectCalls) }
    let tick: string[] = ['function onTick(state: AppState, elapsedMs: number): AppState {',
      '  if (!state.running) { return state; }',
      '  let total: number = countdownSeconds(state) * 1000;',
      '  let next: number = state.elapsedMs + elapsedMs;',
      '  if (next < total) { return ' + changed(fields, ticking) + '; }']
    for (let c of effectCalls) { tick.push(c) }
    tick.push('  return ' + changed(fields, done) + ';')
    tick.push('}')
    functions.push(fn(tick))
  } else {
    // A stopwatch has no end: it only accumulates.
    functions.push(fn(['function onTick(state: AppState, elapsedMs: number): AppState {',
      '  if (!state.running) { return state; }',
      '  let next: number = state.elapsedMs + elapsedMs;',
      '  return ' + changed(fields, ticking) + ';',
      '}']))
  }
  let start: Map<string, string> = new Map<string, string>()
  start.set('running', 'true'); start.set('finished', 'false')
  start.set('elapsedMs', 'startAt')
  let stop: Map<string, string> = new Map<string, string>()
  stop.set('running', 'false')
  let reset: Map<string, string> = new Map<string, string>()
  reset.set('running', 'false'); reset.set('finished', 'false'); reset.set('elapsedMs', '0')
  functions.push(fn(['function onStart(state: AppState, ignored: number): AppState {',
    '  let startAt: number = state.elapsedMs;',
    '  if (state.finished) { startAt = 0; }',
    '  return ' + changed(fields, start) + ';',
    '}']))
  functions.push(fn(['function onStop(state: AppState, ignored: number): AppState {', '  return ' + changed(fields, stop) + ';', '}']))
  functions.push(fn(['function onReset(state: AppState, ignored: number): AppState {', '  return ' + changed(fields, reset) + ';', '}']))
  return part('clock', clockFields(), functions, ['sections.push(ui.Ticker("default", "clock", 200, state.running, "onTick"));'])
}

/**
 * The numbers every other part draws from, as locals at the top of the view: each input, the clock's time, the
 * list's count and total, and every value in sketch order. Its view is not a block of its own, so they stay in scope.
 */
/**
 * The locals the figures are worked out from, as lines of a function body: the inputs and constants, the clock's time, the
 * list's count and total, then one `let` for each value up to and including value `upto` (all when -1).
 */
function figureLocals(comp: Composition, upto: number = -1): string[] {
  let sketch = comp.sketch
  let list = sketch.list
  let view: string[] = inputLocals(comp)
  if (sketch.hasCountdown) {
    view.push('  let duration: number = countdownSeconds(state);')
    view.push('  let elapsed: number = math.min(state.elapsedMs / 1000, duration);')
    view.push('  let remaining: number = duration - elapsed;')
  } else if (sketch.hasStopwatch) {
    view.push('  let elapsed: number = state.elapsedMs / 1000;')
  }
  if (list !== null) {
    view.push('  let entryCount: number = state.entries.length();')
    view.push('  let entryTotal: number = 0;')
    let totalField = firstField(list, 'number')
    if (totalField !== null) { view.push('  for (let e: LogEntry of state.entries) { entryTotal = entryTotal + e.' + totalField.id + '; }') }
  }
  for (let i = 0; i < sketch.values.length; i++) {
    if (upto >= 0 && i > upto) { break }
    let v = sketch.values[i]
    let b = comp.bindings.get(v.id)!
    view.push('  let ' + v.id + ': number = ' + formulaExpr(b) + ';')
  }
  return view
}

/** The name of the function that works out value `id` from the state alone, for a section that reads it through a port. */
function portFunction(id: string): string { return 'port_' + id }

/** Whether a section of the catalogue on this screen reads a value through a port: only then are the values published. */
function sectionsRead(comp: Composition): boolean {
  return compositionBlocks(comp).some((spec: FragmentSpec): boolean => spec.ports.some((p: PortSpec): boolean => p.dir === 'reads'))
}

function figuresPart(comp: Composition): FragmentSpec {
  let sketch = comp.sketch
  let functions: string[] = [fn(['function share(a: number, b: number): number {', '  if (b === 0) { return 0; }', '  return a / b;', '}'])]
  // A written formula's comparison, as 1 or 0; only a program that has one carries it.
  let compares = false
  comp.bindings.forEach((b: Binding) => { if (b.expr.indexOf('whether(') >= 0) { compares = true } })
  if (compares) { functions.push(fn(['function whether(holds: boolean): number {', '  if (holds) { return 1; }', '  return 0;', '}'])) }
  let view: string[] = figureLocals(comp)
  if (hasBanner(comp)) {
    view.push('  let effectNote: string = "Phone: " + state.effectStatus;')
    view.push('  if (state.effectStatus === "pending") { effectNote = "Asking the phone..."; }')
  }
  // A chat widget's two sections, filled by the parts after this one: what it shows, then what the person sets and adds.
  if (comp.widget) {
    view.push('  let shows: ui.View[] = [];')
    view.push('  let sets: ui.View[] = [];')
  }
  let spec = part('figures', [], functions, view)
  // Each value as a function of the state, published under the value's id, when a section of the catalogue reads one.
  if (sectionsRead(comp)) {
    for (let i = 0; i < sketch.values.length; i++) {
      let v = sketch.values[i]
      if (!comp.bindings.has(v.id)) { continue }
      let body: string[] = ['function ' + portFunction(v.id) + '(state: AppState): number {'].concat(figureLocals(comp, i))
      body.push('  return ' + v.id + ';')
      body.push('}')
      spec.functions += '\n\n' + fn(body)
      spec.ports.push(new PortSpec('writes', v.id, 'number', portFunction(v.id) + '(state)', '', true))
      if (v.id === comp.deadline) { spec.ports.push(new PortSpec('writes', 'deadline', 'number', portFunction(v.id) + '(state)', '', true)) }
    }
  }
  return spec
}

/** The hero: the first hero value or the clock, with the progress bars and the clock's buttons; a widget's first section instead. */
function heroPart(comp: Composition, figs: Figures): FragmentSpec {
  let sketch = comp.sketch
  let view: string[] = []
  let heroChildren: string[] = figs.bars.slice()
  if (hasClock(sketch)) { heroChildren.push(figs.clockButtons) }
  if (comp.widget) {
    for (let b of figs.bars) { view.push('shows.push(' + b + ');') }
    if (hasClock(sketch) && sketch.values.every((v: SketchValue): boolean => comp.bindings.get(v.id)!.show !== 'hero')) {
      view.push('shows.push(ui.Stat("default", ' + quote(figs.clockLabel) + ', ' + figs.clockShown + ', "", "clock"));')
    }
    if (figs.stats.length > 0) { view.push('shows.push(ui.MetricGroup("default", ' + Math.min(statColumns(figs.stats), 2).toString() + ', [' + figs.stats.join(', ') + ']));') }
    if (figs.table.length > 0) { view.push('shows.push(' + figs.table + ');') }
    if (hasClock(sketch)) { view.push('shows.push(' + figs.clockButtons + ');') }
  } else if (figs.heroes.length > 0) {
    let v = sketch.values.find((x: SketchValue): boolean => x.id === figs.heroes[0])!
    view.push('sections.push(ui.Section("hero", "", "", [ui.Hero("accent", ' + quote(v.label) + ', ' + heroText(v, v.id) + ', "", [' + heroChildren.join(', ') + '])]));')
  } else if (hasClock(sketch)) {
    view.push('sections.push(ui.Section("hero", "", "", [ui.Hero("accent", ' + quote(figs.clockLabel) + ', ' + figs.clockShown + ', "", [' + heroChildren.join(', ') + '])]));')
  } else if (heroChildren.length > 0) {
    view.push('sections.push(ui.Section("content", "", "", [' + heroChildren.join(', ') + ']));')
  }
  return part('hero', [], [], view)
}

/**
 * The inputs drawn folded under Settings: those marked as settings, when the screen has something else to show above them -- a list,
 * a clock, a figure or a section of the catalogue. A screen of inputs alone keeps them where they are: they are all it has.
 */
export function foldedSettings(comp: Composition): string[] {
  if (comp.widget) { return [] }
  let settings = comp.inputs.filter((i: SketchInput): boolean => i.setting)
  if (settings.length === 0) { return [] }
  let other = comp.sketch.list !== null || hasClock(comp.sketch) || comp.blocks.length > 0 ||
    comp.sketch.values.some((v: SketchValue): boolean => !v.hidden) ||
    comp.inputs.some((i: SketchInput): boolean => !i.setting)
  return other ? settings.map((i: SketchInput): string => i.id) : []
}

/** The settings, folded under one row at the foot of the screen; a tap shows them. Drawn after every section (ScreenPlan's assemblePlan). */
function settingsPart(settingControls: string[]): FragmentSpec | null {
  if (settingControls.length === 0) { return null }
  let functions: string[] = [fn(['function toggleSettings(state: AppState, ignored: number): AppState {',
    '  return {settingsOpen: !state.settingsOpen__PASSTHROUGH__};', '}'])]
  let count = settingControls.length.toString() + (settingControls.length === 1 ? ' setting' : ' settings')
  let view: string[] = ['{',
    '  let settingsWord: string = "Show";',
    '  if (state.settingsOpen) { settingsWord = "Hide"; }',
    '  sections.push(ui.Section("supporting", "", "", [',
    '    ui.ListItem("default", "Settings", ' + quote(count) + ', settingsWord, "toggleSettings", 0, true, ""),',
    '    ui.When(state.settingsOpen, ui.Column("default", [' + settingControls.join(', ') + ']))',
    '  ]));',
    '}']
  let spec = part(SETTINGS_KIND, [new Field('settingsOpen', 'boolean', 'false')], functions, view)
  return spec
}

/**
 * What the person sets once for the whole screen: one control and one setter per input. A new countdown length restarts the countdown.
 * The controls of the settings folded at the foot of the screen go into `folding`, for settingsPart.
 */
function inputsPart(comp: Composition, fields: Field[], folding: string[]): FragmentSpec {
  let sketch = comp.sketch
  let functions: string[] = []
  let controls: string[] = []
  for (let input of comp.inputs) {
    let widget = comp.widgets.get(input.id) ?? ''
    let replaced: Map<string, string> = new Map<string, string>()
    let type = 'number'
    if (input.kind === 'toggle') { replaced.set(input.id, 'value'); type = 'boolean' }
    else if (input.kind === 'text') { replaced.set(input.id, 'value'); type = 'string' }
    else if (input.kind === 'choice') { replaced.set(input.id + 'Index', 'value') }
    else if (widget === 'typed_number') { replaced.set(input.id + 'Text', 'value'); type = 'string' }
    else { replaced.set(input.id, 'value') }
    if (sketch.hasCountdown && dependsOn(comp, comp.countdownFrom).indexOf(input.id) >= 0) {
      replaced.set('elapsedMs', '0'); replaced.set('running', 'false'); replaced.set('finished', 'false')
    }
    functions.push(fn(['function set_' + input.id + '(state: AppState, value: ' + type + '): AppState {',
      '  return ' + changed(fields, replaced) + ';', '}']))

    let handler = quote('set_' + input.id)
    if (widget === 'select') {
      let labels: string[] = []
      for (let o of input.options) { labels.push(quote(o.label)) }
      controls.push('ui.Select("default", ' + quote(input.label) + ', [' + labels.join(', ') + '], state.' + input.id + 'Index, ' + handler + ')')
    } else if (widget === 'text_field') {
      controls.push('ui.TextField("default", ' + quote(input.label) + ', state.' + input.id + ', ' + handler + ')')
    } else if (widget === 'time_field') {
      controls.push('ui.TimeField("default", ' + quote(input.label) + ', state.' + input.id + ', ' + handler + ')')
    } else if (widget === 'switch') {
      controls.push('ui.Toggle("default", ' + quote(input.label) + ', state.' + input.id + ', ' + handler + ')')
    } else if (widget === 'typed_number') {
      controls.push('ui.TextField("default", ' + quote(labelWithUnit(input)) + ', state.' + input.id + 'Text, ' + handler + ', "number")')
    } else if (widget === 'slider') {
      let label = input.kind === 'percent' ? quote(input.label + ' ') + ' + ui.numberToString(state.' + input.id + ') + "%"' : quote(input.label)
      controls.push('ui.Slider("accent", ' + label + ', state.' + input.id + ', ' + numberLiteral(input.min) + ', ' + numberLiteral(input.max) + ', ' + handler + ')')
    } else {
      controls.push('ui.NumberField("default", ' + quote(labelWithUnit(input)) + ', state.' + input.id + ', ' + numberLiteral(input.min) + ', ' + numberLiteral(input.max) + ', ' + handler + ')')
    }
  }
  let view: string[] = []
  let folded = foldedSettings(comp)
  let main = controls.filter((_c: string, i: number): boolean => folded.indexOf(comp.inputs[i].id) < 0)
  if (comp.widget) {
    for (let c of controls) { view.push('sets.push(' + c + ');') }
  } else if (main.length > 0) {
    view.push('sections.push(ui.Section("content", "", "", [' + main.join(', ') + ']));')
  }
  controls.forEach((c: string, i: number) => { if (folded.indexOf(comp.inputs[i].id) >= 0) { folding.push(c) } })
  let spec = part('inputs', inputFields(comp), functions, view)
  // What the person sets, under the input's id, for a section that reads it: a switch, typed words, a number. A choice is its
  // option's index, and typed digits are text, so neither is a number under that name.
  for (let input of comp.inputs) {
    let widget = comp.widgets.get(input.id) ?? ''
    if (input.kind === 'choice' || widget === 'typed_number') { continue }
    spec.ports.push(new PortSpec('writes', input.id, inputType(input), input.id))
    if (input.id === dayStart(comp)) { spec.ports.push(new PortSpec('writes', 'start', 'number', input.id)) }
  }
  return spec
}

/**
 * A value a section shows leaves the plan, and is read against the finished screen -- except the itinerary's own times
 * (itineraryShows). They are read by the plan's names ("shows Lunch at", "shows Walking time", "shows Back at start"), which the
 * itinerary does not use: it says the stops' windows, "Minutes between stops", "Day ends" and "Day length". Not found under the
 * plan's name, each came back to be written as a section of its own beside the stops, a line of text or every stop again, often
 * with a warning above the plan (West Lake, a family day, three runs, a new name each time).
 */
function claimShown(comp: Composition, label: string, itineraryOwn: boolean): void {
  if (itineraryOwn) {
    comp.dropped.push('value "' + label + '": the itinerary\'s own times')
    return
  }
  comp.dropped.push('value "' + label + '": a section shows it')
  comp.claimed.push('shows ' + label)
}

/**
 * The figures an itinerary on the screen already shows: on a day of stops, a time of day or a length of time is the itinerary's --
 * it shows each stop's window, when the day ends and how long it takes, worked out from the stops. The plan's own figure for the
 * same thing was worked out another way and disagreed with it (West Lake: "Back by 11:30" under a last stop ending at 17:15, "Day
 * length 150 min" for eight hours of stops). Not the time the stops must be over by (a flight to catch): the itinerary reads that
 * one. They leave as a figure a section shows does, unless a figure that stays reads them (dropValues).
 */
function itineraryShows(comp: Composition, answers: Record<string, Object>): string[] {
  if (comp.blocks.indexOf('itinerary') < 0) { return [] }
  // Only those Jev reads as the itinerary's own (askItinerary): every time on the screen went, "Minutes of sunlight left" with
  // the rest, reported as shown although the itinerary shows nothing like it (review of #46). And not the deadline it reads.
  return comp.sketch.values.filter((v: SketchValue): boolean => (v.format === 'clock' || v.format === 'minutes') && v.id !== comp.deadline &&
    answerOf(answers, 'itinerary.value.' + v.id, ['yes'], comp.answers, COVERED_ABOVE) === 'yes').map((v: SketchValue): string => v.id)
}

/** The time of day the plan's own example gives for the deadline (comp.deadline); NaN when there is none. */
function deadlineExample(comp: Composition): number {
  if (comp.deadline.length === 0) { return NaN }
  let v = comp.sketch.values.find((x: SketchValue): boolean => x.id === comp.deadline)
  return v === undefined ? NaN : v.result
}

/**
 * The input that sets when the itinerary's day starts: the one time of day the person sets on a screen with an itinerary. With it
 * the itinerary draws no start field of its own, which beside the form's was a second start time only one of which did anything
 * (West Lake: "Start time 09:00" and "Day starts 09:00"). '' when there is none, or more than one and so no telling which.
 */
function dayStart(comp: Composition): string {
  if (comp.blocks.indexOf('itinerary') < 0) { return '' }
  // Not a time at or after the deadline: one input "Flight departs" (21:00) with "Back at the airport by" = flight - 120 as the
  // deadline started the day at the flight, after its own deadline, and showed no stop, with no start field left to fix it (review
  // of #46). A landing time the deadline is worked out from (08:00, leave by 17:00) is still the day's start: told apart by the
  // plan's own example of the deadline, not by what it is worked out from.
  let endsBy = deadlineExample(comp)
  let times = comp.sketch.inputs.filter((i: SketchInput): boolean => i.kind === 'time' && !(isFinite(endsBy) && i.value >= endsBy))
  return times.length === 1 ? times[0].id : ''
}

/** A screen's figures under its controls: the table, then the metric group. A widget shows them in its first section. */
function summaryPart(comp: Composition, figs: Figures): FragmentSpec {
  let view: string[] = []
  if (!comp.widget) {
    if (figs.table.length > 0) { view.push('sections.push(ui.Section("summary", "", "", [' + figs.table + ']));') }
    if (figs.stats.length > 0) {
      view.push('sections.push(ui.Section("summary", "", "", [ui.MetricGroup("default", ' + Math.min(statColumns(figs.stats), 3).toString() + ', [' + figs.stats.join(', ') + '])]));')
    }
  }
  return part('summary', [], [], view)
}

/** The list the person keeps adding to: the form, adding and removing an entry, the answer of the phone for each, and the entries. */
function listPart(comp: Composition, list: SketchList, fields: Field[]): FragmentSpec {
  let entryClass: string[] = ['@jsonable', 'class LogEntry {']
  for (let f of list.fields) { entryClass.push('  ' + f.id + ': ' + entryType(f) + ';') }
  entryClass.push('  minute: number;')
  let answering = entryAnswerEvent(comp)
  if (answering.length > 0) { entryClass.push('  status: string;') }
  entryClass.push('}')

  let functions: string[] = []
  // The new entry's fields, adding it (a copy of the old array plus one), and removing one by position.
  for (let f of list.fields) {
    let replaced: Map<string, string> = new Map<string, string>()
    replaced.set(draftOf(f), 'value')
    functions.push(fn(['function set_' + draftOf(f) + '(state: AppState, value: ' + draftType(f) + '): AppState {',
      '  return ' + changed(fields, replaced) + ';', '}']))
  }
  let added: Map<string, string> = new Map<string, string>()
  added.set('entries', 'out')
  // Adding is the next thing done: a removal can no longer be undone.
  added.set('removedEntries', 'none')
  // Typed fields empty for the next entry; a time and an on/off keep what was set.
  for (let f of list.fields) { if (draftType(f) === 'string') { added.set(draftOf(f), '""') } }
  let calls = effectCallsAt(comp, 'entry_added')
  if (comp.events.some((e: SketchEvent): boolean => comp.moments.get(e.id) === 'entry_added' && e.id !== answering)) {
    added.set('effectStatus', '"pending"')
  }
  let add: string[] = ['function addEntry(state: AppState, ignored: number): AppState {']
  // An entry needs its words, or else its number; a list with neither adds one per tap.
  let required = firstField(list, 'text') ?? firstField(list, 'number')
  if (required !== null) { add.push('  if (strings.trim(state.' + draftOf(required) + ') === "") { return state; }') }
  if (callsNeedLocals(comp, 'entry_added')) { for (let l of inputLocals(comp)) { add.push(l) } }
  let members: string[] = []
  for (let f of list.fields) { members.push(f.id + ': ' + draftValue(f)) }
  members.push('minute: time.hourOfDay() * 60 + time.minuteOfHour()')
  if (answering.length > 0) { members.push('status: "pending"') }
  add.push('  let none: LogEntry[] = [];')
  add.push('  let entry: LogEntry = {' + members.join(', ') + '};')
  add.push('  let out: LogEntry[] = [];')
  add.push('  for (let e: LogEntry of state.entries) { out.push(e); }')
  add.push('  out.push(entry);')
  for (let c of calls) { add.push(c) }
  add.push('  return ' + changed(fields, added) + ';')
  add.push('}')
  functions.push(fn(add))
  if (hasLaps(comp)) {
    // A lap is an entry the stopwatch makes: "Lap N" for its words, the time passed for its number.
    let lapMembers: string[] = []
    let worded = false
    let numbered = false
    let timed = false
    let total = firstField(list, 'number')
    for (let f of list.fields) {
      if (f.kind === 'text' && !worded) { lapMembers.push(f.id + ': "Lap " + ui.numberToString(state.entries.length() + 1)'); worded = true }
      else if (f.kind === 'number' && !numbered) { lapMembers.push(f.id + ': math.round(state.elapsedMs / 1000)'); numbered = true }
      else if (f.kind === 'number' && !timed) { lapMembers.push(f.id + ': math.round(state.elapsedMs / 1000) - before'); timed = true }
      else { lapMembers.push(f.id + ': ' + (f.kind === 'text' ? '""' : (f.kind === 'toggle' ? 'false' : '0'))) }
    }
    lapMembers.push('minute: time.hourOfDay() * 60 + time.minuteOfHour()')
    let lapped: Map<string, string> = new Map<string, string>()
    lapped.set('entries', 'out')
    // A lap moves the entries on, as an Add does: a removal can no longer be undone into its old place.
    lapped.set('removedEntries', 'none')
    functions.push(fn(['function lapEntry(state: AppState, ignored: number): AppState {',
      '  let none: LogEntry[] = [];',
      '  let before: number = 0;',
      '  if (state.entries.length() > 0) { before = state.entries[state.entries.length() - 1].' + total!.id + '; }',
      '  let lap: LogEntry = {' + lapMembers.join(', ') + '};',
      '  let out: LogEntry[] = [];',
      '  for (let e: LogEntry of state.entries) { out.push(e); }',
      '  out.push(lap);',
      '  return ' + changed(fields, lapped) + ';',
      '}']))
  }
  if (answering.length > 0) {
    // Answers come back in the order the calls went out: each goes to the oldest entry still waiting.
    let copied: string[] = []
    for (let f of list.fields) { copied.push(f.id + ': e.' + f.id) }
    copied.push('minute: e.minute')
    copied.push('status: value')
    let answered: Map<string, string> = new Map<string, string>()
    answered.set('entries', 'out')
    let capture = keepsCalendarIds(comp) && comp.effects.get(answering) === 'calendar_add'
    if (capture) { answered.set('calendarIds', 'ids') }
    let answer: string[] = ['function onEntryAnswer(state: AppState, value: string): AppState {']
    if (capture) { for (let l of idCapture()) { answer.push(l) } }
    answer.push('  let out: LogEntry[] = [];')
    answer.push('  let marked: boolean = false;')
    answer.push('  for (let e: LogEntry of state.entries) {')
    answer.push('    if (marked === false && e.status === "pending") {')
    answer.push('      let answered: LogEntry = {' + copied.join(', ') + '};')
    answer.push('      out.push(answered);')
    answer.push('      marked = true;')
    answer.push('    } else {')
    answer.push('      out.push(e);')
    answer.push('    }')
    answer.push('  }')
    answer.push('  return ' + changed(fields, answered) + ';')
    answer.push('}')
    functions.push(fn(answer))
  }
  let removed: Map<string, string> = new Map<string, string>()
  removed.set('entries', 'out')
  removed.set('removedEntries', 'gone')
  removed.set('removedAt', 'value')
  functions.push(fn(['function removeEntry(state: AppState, value: number): AppState {',
    '  let out: LogEntry[] = [];',
    '  let gone: LogEntry[] = [];',
    '  let i: number = 0;',
    '  while (i < state.entries.length()) {',
    '    if (i !== value) { out.push(state.entries[i]); } else { gone.push(state.entries[i]); }',
    '    i = i + 1;',
    '  }',
    '  return ' + changed(fields, removed) + ';',
    '}']))
  // Undo puts the removed entry back where it stood.
  let restored: Map<string, string> = new Map<string, string>()
  restored.set('entries', 'out')
  restored.set('removedEntries', 'none')
  restored.set('removedAt', '-1')
  let expired: Map<string, string> = new Map<string, string>()
  expired.set('removedEntries', 'none')
  expired.set('removedAt', '-1')
  functions.push(fn(['function undoRemove(state: AppState, ignored: number): AppState {',
    '  if (state.removedEntries.length() === 0) { return state; }',
    '  let out: LogEntry[] = [];',
    '  let none: LogEntry[] = [];',
    '  let i: number = 0;',
    '  while (i < state.entries.length()) {',
    '    if (i === state.removedAt) { out.push(state.removedEntries[0]); }',
    '    out.push(state.entries[i]);',
    '    i = i + 1;',
    '  }',
    '  if (state.removedAt >= state.entries.length()) { out.push(state.removedEntries[0]); }',
    '  return ' + changed(fields, restored) + ';',
    '}']))

  // "Removed / Undo" is for the moment after a removal: it goes by itself, also when the program is opened later.
  functions.push(fn(['function expireUndo(state: AppState, elapsedMs: number): AppState {',
    '  let none: LogEntry[] = [];',
    '  return ' + changed(fields, expired) + ';',
    '}']))

  let form: string[] = []
  for (let f of list.fields) {
    let at = 'state.' + draftOf(f) + ', ' + quote('set_' + draftOf(f))
    if (f.kind === 'text') { form.push('ui.TextField("default", ' + quote(f.label) + ', ' + at + ')') }
    else if (f.kind === 'number') { form.push('ui.TextField("default", ' + quote(f.label) + ', ' + at + ', "number")') }
    else if (f.kind === 'time') { form.push('ui.TimeField("default", ' + quote(f.label) + ', ' + at + ')') }
    else if (f.kind === 'date') { form.push('ui.DateField("default", ' + quote(f.label) + ', ' + at + ')') }
    else { form.push('ui.Toggle("default", ' + quote(f.label) + ', ' + at + ')') }
  }
  // Add is off until the entry has what addEntry needs, so the tap is never silently ignored.
  let canAdd = required !== null ? 'strings.trim(state.' + draftOf(required) + ') !== ""' : 'true'
  form.push('ui.ActionBar("end", [ui.Button("primary", "Add", "addEntry", 0, ' + canAdd + ')])')
  // Laps are made by the stopwatch's Lap button: there is no form to type one in.
  let laps = hasLaps(comp)
  if (laps) { form = [] }
  // Newest first, at most 20 rows (a container holds 20 children), 4 in a chat bubble. A tap on a row removes it --
  // unless the row has buttons of its own (row_button events): then it is followed by a bar with them and Remove,
  // two children a row, so at most 10 rows.
  let rowButtons: string[] = []
  for (let e of comp.events) {
    if (comp.moments.get(e.id) !== 'row_button') { continue }
    rowButtons.push('ui.Button("secondary", ' + quote(effectOf(comp.effects.get(e.id) ?? '')!.button) + ', ' + quote(tapHandler(e.id, 'row_button')) + ', i, true)')
  }
  // The title is the words (else the number); the number (else the time) sits at the right edge; the
  // rest, the time it was added and what the phone answered go underneath.
  let textField = firstField(list, 'text')
  let numberField = firstField(list, 'number')
  let titleField = textField ?? numberField
  let trailingField = textField !== null && numberField !== null ? numberField : firstField(list, 'time')
  let shown = (f: ListField): string => f.kind === 'text' ? 'e.' + f.id :
    (f.kind === 'time' ? 'ui.clockToString(e.' + f.id + ')' : (f.kind === 'date' ? 'ui.dateToString(e.' + f.id + ')' : entryAmountText(f)))
  let title = titleField !== null ? shown(titleField) : '"#" + ui.numberToString(i + 1)'
  let trailing = trailingField !== null ? shown(trailingField) : '""'
  let pieces: string[] = []
  let flags: ListField[] = []
  for (let f of list.fields) {
    if (f === titleField || f === trailingField) { continue }
    if (f.kind === 'toggle') { flags.push(f) } else { pieces.push(shown(f)) }
  }
  pieces.push('"Added " + ui.clockToString(e.minute)')
  let view: string[] = ['let rows: ui.View[] = [];',
    'let i: number = entryCount - 1;',
    'while (i >= 0 && i > entryCount - ' + (comp.widget ? '5' : (rowButtons.length > 0 ? '11' : '21')) + ') {',
    '  let e: LogEntry = state.entries[i];',
    '  let sub: string = ' + pieces.join(' + " · " + ') + ';']
  for (let f of flags) { view.push('  if (e.' + f.id + ') { sub = ' + quote(f.label + ' · ') + ' + sub; }') }
  if (answering.length > 0) {
    let done = effectOf(comp.effects.get(answering) ?? '')!.done
    view.push('  let note: string = "";')
    view.push('  if (e.status === "pending") { note = "Asking the phone..."; }')
    view.push('  if (strings.startsWith(e.status, "error") || strings.startsWith(e.status, "declined")) { note = "Phone: " + e.status; }')
    view.push('  if (note === "" && e.status !== "") { note = ' + quote(done) + '; }')
    view.push('  sub = note + " · " + sub;')
  }
  if (rowButtons.length > 0) {
    view.push('  rows.push(ui.ListItem("default", ' + title + ', sub, ' + trailing + ', "", 0, false, ""));')
    view.push('  rows.push(ui.ActionBar("end", [' + rowButtons.join(', ') + ', ui.Button("secondary", "Remove", "removeEntry", i, true)]));')
  } else {
    // A row and an action bar with one button are drawn as one row with the button at its end.
    view.push('  rows.push(ui.ListItem("default", ' + title + ', sub, ' + trailing + ', "", 0, false, ""));')
    view.push('  rows.push(ui.ActionBar("end", [ui.Button("secondary", "Remove", "removeEntry", i, true)]));')
  }
  view.push('  i = i - 1;')
  view.push('}')
  let listNodes: string[] = ['ui.SectionHeader("default", ' + quote(list.label) + ', "Newest first", ui.numberToString(entryCount))',
    'ui.When(entryCount === 0, ui.EmptyState("default", "Nothing added yet", ' +
    quote(laps ? 'Start the stopwatch and tap Lap.' : (form.length > 1 ? 'Fill in the fields above and tap Add.' : 'Tap Add to add one.')) + ', "", "", "list"))',
    'ui.When(entryCount > 0, ui.ListGroup("default", "", rows))',
    'ui.When(state.removedEntries.length() > 0, ui.Snackbar("default", "Removed", "Undo", "undoRemove"))',
    // The interval moves with the number of entries: a second removal while the first Undo shows must start the six seconds again,
    // and a ticker that is running is left alone unless its interval changed (VeraPreview.reconcileTimers).
    'ui.Ticker("default", "undoClock", 6000 + state.entries.length() % 7, state.removedEntries.length() > 0, "expireUndo")']
  if (comp.widget) {
    for (let node of form.concat(listNodes)) { view.push('sets.push(' + node + ');') }
  } else {
    if (form.length > 0) { view.push('sections.push(ui.Section("content", "", "", [' + form.join(', ') + ']));') }
    view.push('sections.push(ui.Section("content", "", "", [' + listNodes.join(', ') + ']));')
  }
  let init = '  let emptyEntries: LogEntry[] = [];'
  let fieldsInit = entryFields(list)
  if (list.fields.some((f: ListField): boolean => !isNaN(f.seed))) {
    // The entry the request names: its number, the rest as an empty form would leave them, stamped now.
    let seeded: string[] = []
    for (let f of list.fields) {
      if (!isNaN(f.seed)) { seeded.push(f.id + ': ' + numberLiteral(f.seed)) }
      else if (f.kind === 'text') { seeded.push(f.id + ': ""') }
      else if (f.kind === 'toggle') { seeded.push(f.id + ': ' + (f.value !== 0 ? 'true' : 'false')) }
      else if (f.kind === 'time') { seeded.push(f.id + ': time.hourOfDay() * 60 + time.minuteOfHour()') }
      else if (f.kind === 'date') { seeded.push(f.id + ': time.daysSinceEpoch()') }
      else { seeded.push(f.id + ': 0') }
    }
    seeded.push('minute: time.hourOfDay() * 60 + time.minuteOfHour()')
    if (answering.length > 0) { seeded.push('status: ""') }
    init += '\n  let firstEntries: LogEntry[] = [{' + seeded.join(', ') + '}];'
    fieldsInit = fieldsInit.map((f: Field): Field => f.name === 'entries' ? new Field('entries', 'LogEntry[]', 'firstEntries') : f)
  }
  let spec = part('list', fieldsInit, functions, view, fn(entryClass), init)
  spec.ports.push(new PortSpec('writes', 'entries', 'LogEntry[]', 'entries'))
  spec.ports.push(new PortSpec('writes', 'count', 'number', 'state.entries.length()', '', true))
  return spec
}

/** What the phone is asked to do outside this screen: the buttons that ask it, their answers, and the banner with the last one. */
function effectsPart(comp: Composition, fields: Field[]): FragmentSpec {
  let functions: string[] = []
  // A tapped button's own handler: do_<event> on the screen, row_<event> for the entry its button is on.
  for (let e of comp.events) {
    let moment = comp.moments.get(e.id) ?? ''
    if (!tapMoment(moment)) { continue }
    let fx = effectOf(comp.effects.get(e.id) ?? '')!
    let tapped: Map<string, string> = new Map<string, string>()
    tapped.set('effectStatus', '"pending"')
    let tap: string[] = ['function ' + tapHandler(e.id, moment) + '(state: AppState, ' + (moment === 'row_button' ? 'index' : 'ignored') + ': number): AppState {']
    if (moment === 'row_button') {
      tap.push('  if (index < 0 || index >= state.entries.length()) { return state; }')
      tap.push('  let entry: LogEntry = state.entries[index];')
    }
    if (fx.id === 'calendar_clear') {
      let nothing: Map<string, string> = new Map<string, string>()
      nothing.set('effectStatus', '"No calendar events added yet"')
      tap.push('  if (' + (keepsCalendarIds(comp) ? 'state.calendarIds' : '""') + ' === "") { return ' + changed(fields, nothing) + '; }')
    }
    if (callsNeedLocals(comp, moment)) { for (let l of inputLocals(comp)) { tap.push(l) } }
    for (let c of effectCallsAt(comp, moment, e.id)) { tap.push(c) }
    tap.push('  return ' + changed(fields, tapped) + ';')
    tap.push('}')
    functions.push(fn(tap))
  }
  if (keepsCalendarIds(comp)) {
    // Every event this program adds is remembered by the ID its answer gave, so that it can delete exactly those.
    let added: Map<string, string> = new Map<string, string>()
    added.set('effectStatus', 'value')
    added.set('calendarIds', 'ids')
    functions.push(fn(['function onCalendarAdded(state: AppState, value: string): AppState {'].concat(idCapture(),
      ['  return ' + changed(fields, added) + ';', '}'])))
  }
  if (comp.events.some((e: SketchEvent): boolean => comp.effects.get(e.id) === 'calendar_clear')) {
    let cleared: Map<string, string> = new Map<string, string>()
    cleared.set('effectStatus', 'value')
    if (keepsCalendarIds(comp)) { cleared.set('calendarIds', 'left') }
    let clear: string[] = ['function onCalendarCleared(state: AppState, value: string): AppState {']
    if (keepsCalendarIds(comp)) {
      clear.push('  let left: string = state.calendarIds;')
      clear.push('  if (value === "ok") { left = ""; }')
    }
    clear.push('  return ' + changed(fields, cleared) + ';')
    clear.push('}')
    functions.push(fn(clear))
  }
  if (hasBanner(comp)) {
    let status: Map<string, string> = new Map<string, string>()
    status.set('effectStatus', 'value')
    functions.push(fn(['function onEffect(state: AppState, value: string): AppState {', '  return ' + changed(fields, status) + ';', '}']))
  }
  // The buttons of the events a tap on the screen starts.
  let screenButtons: string[] = []
  for (let e of comp.events) {
    if (comp.moments.get(e.id) !== 'button') { continue }
    screenButtons.push('ui.Button("secondary", ' + quote(effectOf(comp.effects.get(e.id) ?? '')!.button) + ', ' + quote(tapHandler(e.id, 'button')) + ', 0, true)')
  }
  let view: string[] = []
  let into = comp.widget ? 'sets.push(' : 'sections.push('
  if (screenButtons.length > 0) {
    let bar = 'ui.ActionBar("end", [' + screenButtons.join(', ') + '])'
    view.push(comp.widget ? 'sets.push(' + bar + ');' : 'sections.push(ui.Section("content", "", "", [' + bar + ']));')
  }
  if (hasBanner(comp)) { view.push(into + 'ui.When(state.effectStatus !== "", ui.InsetBanner("default", "Done", effectNote, "", "", "info")));') }
  return part('effects', effectFields(comp), functions, view)
}

/** A chat widget's two sections, from what the parts before put in them. */
function widgetPart(): FragmentSpec {
  return part('widget', [], [], ['if (shows.length() > 0) { sections.push(ui.Section("summary", "", "", shows)); }',
    'if (sets.length() > 0) { sections.push(ui.Section("content", "", "", sets)); }'])
}

/** The composition as blocks for the blocks' composer: each part's state and handlers, then one block with the whole view. */
export function compositionParts(comp: Composition): FragmentSpec[] {
  let sketch = comp.sketch
  let fields: Field[] = inputFields(comp)
  if (hasClock(sketch)) { fields = fields.concat(clockFields()) }
  if (sketch.list !== null) { fields = fields.concat(entryFields(sketch.list)) }
  fields = fields.concat(effectFields(comp))
  let figs = figuresOf(comp)
  let parts: FragmentSpec[] = []
  if (hasClock(sketch)) { parts.push(clockPart(comp, fields)) }
  parts.push(figuresPart(comp))
  parts.push(heroPart(comp, figs))
  let folding: string[] = []
  parts.push(inputsPart(comp, fields, folding))
  parts.push(summaryPart(comp, figs))
  if (sketch.list !== null) { parts.push(listPart(comp, sketch.list, fields)) }
  parts.push(effectsPart(comp, fields))
  if (comp.widget) { parts.push(widgetPart()) }
  // One view block for the whole composition, as a catalogue block has one: the figures every part draws from stay
  // inside it, out of the way of any other block on the same screen.
  let view: string[] = ['{']
  for (let p of parts) {
    for (let line of p.viewBlock.split('\n')) { if (line.length > 0) { view.push('  ' + line) } }
    p.viewBlock = ''
  }
  view.push('}')
  let screen = part('screen', [], [], view)
  screen.tab = 'Overview'
  parts.push(screen)
  let settings = settingsPart(folding)
  if (settings !== null) { parts.push(settings) }
  return parts
}

/** The kind of the part that holds the folded settings: drawn last on the screen. */
export const SETTINGS_KIND: string = 'settings'

/** Text as it goes between the quotes of a string literal. */
function inQuotes(s: string): string {
  let quoted = quote(s)
  return quoted.substring(1, quoted.length - 1)
}

/** What the screen's own parts already hold, for a section the model writes: to use, not to make again. */
export class PartsContract {
  /** The state the parts own, one entry each, in words and field names. */
  lines: string[] = []
  clock: boolean = false
  list: boolean = false
}

export function partsContract(comp: Composition): PartsContract {
  let out = new PartsContract()
  let sketch = comp.sketch
  if (hasClock(sketch)) {
    out.clock = true
    out.lines.push('a clock (' + (sketch.hasCountdown ? 'a countdown' : 'a stopwatch') + '): state.elapsedMs is the milliseconds passed, state.running whether it runs, ' +
      'state.finished whether it ended. Its Start, Stop and Reset buttons and its Ticker are already on the screen and drive it: ' +
      'the section draws no timer, no Start/Stop/Reset buttons and no Ticker of its own, and keeps no clock state of its own; ' +
      'it reads state.elapsedMs' + (sketch.hasCountdown ? ' and countdownSeconds(state), the length in seconds' : '') + '.')
  }
  if (sketch.list !== null) {
    out.list = true
    let fields: string[] = []
    for (let f of sketch.list!.fields) { fields.push(f.id + ': ' + entryType(f)) }
    fields.push('minute: number')
    let answering = entryAnswerEvent(comp).length > 0
    out.lines.push('a list of entries: state.entries is LogEntry[] with the fields {' + fields.join(', ') + (answering ? ', status: string' : '') + '}. ' +
      'Its form, its Add and Remove buttons and its rows are already on the screen. The section makes no list of its own for the same entries; ' +
      'to add one it copies state.entries into a new array, pushes a LogEntry (minute: time.hourOfDay() * 60 + time.minuteOfHour()) and returns {entries: thatArray __PASSTHROUGH__}.')
  }
  // What a chosen section already shows: written again beside it and worked out another way, it disagreed with it (West
  // Lake: a "Day at a glance" with its own day length and time back beside the itinerary's).
  for (let kind of comp.blocks) {
    let spec = fragments().find((f: FragmentSpec): boolean => f.kind === kind)
    if (spec === undefined || spec.owns.length === 0) { continue }
    out.lines.push('a ' + kind + ' section, already on the screen, which has ' + spec.owns + '. Its state is in the program below. The section ' +
      'shows none of that again and works none of it out another way -- no second list, form, time, schedule or summary of the same things; ' +
      'what it needs of them it reads from that state.')
  }
  // The live figures are fetched by their section: a section that needs them reads them, and fetches nothing itself.
  if (comp.live.length > 0) {
    let read: string[] = []
    for (let i = 0; i < comp.live.length; i++) { read.push('"' + comp.live[i].label + '" is ' + liveFigureNumber(i + 1)) }
    out.lines.push('figures fetched from the internet as they are now, by the ' + LIVE_KIND + ' section: ' + read.join(', ') +
      ' (0 until the first answer); state.liveSource and state.liveAsOf say where and when they were read. The section reads them ' +
      'and makes no sdk.call, web fetch or Ticker of its own for them.')
  }
  return out
}

/**
 * The inputs kept only for the section the model was to write: nothing else on the screen reads them. When that section
 * could not be written they have nothing to do, and are left off.
 */
export function inputsOnlyForCustom(comp: Composition): string[] {
  let read: string[] = [comp.countdownFrom]
  comp.bindings.forEach((b: Binding) => {
    read.push(b.a)
    read.push(b.b)
    for (let name of b.reads) { read.push(name) }
  })
  comp.args.forEach((given: Map<string, string>) => {
    given.forEach((source: string) => { if (source.startsWith('input.')) { read.push(source.substring(6)) } })
  })
  return comp.customReads.filter((id: string): boolean => read.indexOf(id) < 0)
}

/** The inputs left for the custom section, as it finds them in the state: "Dice" is state.dice, a typed number its text. */
export function customInputs(comp: Composition): string[] {
  let out: string[] = []
  for (let input of comp.inputs) {
    if (comp.customReads.indexOf(input.id) < 0) { continue }
    let widget = comp.widgets.get(input.id) ?? ''
    let field = input.kind === 'choice' ? input.id + 'Index (the index of the chosen option: ' +
      input.options.map((o: SketchOption): string => o.label).join(', ') + ')' :
      (widget === 'typed_number' ? input.id + 'Text (the number as typed; strings.toNumber reads it)' : input.id)
    out.push('"' + input.label + '": state.' + field)
  }
  return out
}

/** The catalogue's sections the composition has, in screen order, after its own parts. */
export function compositionBlocks(comp: Composition): FragmentSpec[] {
  let out: FragmentSpec[] = []
  for (let kind of comp.blocks) {
    let spec = fragments().find((f: FragmentSpec): boolean => f.kind === kind)
    if (spec !== undefined) { out.push(spec) }
  }
  return out
}

/** The VERA type an input's value is: a number for every kind but a switch and typed words. */
function inputType(input: SketchInput): string {
  return input.kind === 'toggle' ? 'boolean' : (input.kind === 'text' ? 'string' : 'number')
}

function unique(names: string[]): string[] {
  let out: string[] = []
  for (let n of names) { if (n.length > 0 && out.indexOf(n) < 0) { out.push(n) } }
  return out
}

/**
 * The composition as a plan (ScreenPlan.ets): the sketch's state, one slot for each thing the screen does, filled by
 * the composer's parts, the catalogue's sections Jev chose (`blockValues` holds each one's slot, content and hole
 * values, in comp.blocks order; a section without them gets the catalogue's defaults) and `custom`, the section the
 * model wrote for comp.custom. What Jev chose nothing for is an open slot: a need with no custom section yet, and
 * everything unbound.
 */
export function screenPlan(comp: Composition, blockValues: Map<string, string>[] = [], custom: FragmentSpec | null = null): ScreenPlan {
  let sketch = comp.sketch
  let plan = new ScreenPlan()
  plan.origin = PLAN_FROM_SKETCH
  plan.widget = comp.widget
  plan.globals.set('__THEME__', comp.theme)
  // A chat widget has no header: the conversation already says what it is.
  plan.globals.set('__HEADER_STYLE__', comp.widget ? 'none' : 'default')
  if (comp.widget) { plan.globals.set('__WIDGET__', 'true') }
  plan.globals.set('__TITLE__', inQuotes(sketch.title))
  plan.globals.set('__EYEBROW__', inQuotes(sketch.eyebrow))
  plan.globals.set('__SUPPORTING__', inQuotes(sketch.subtitle))
  // A clock says what a timed screen is about; a list icon says nothing about the subject, so a screen with only a list gets none.
  plan.globals.set('__HEADER_ICON__', hasClock(sketch) ? 'clock' : '')

  for (let input of comp.inputs) { plan.state.push(new StateItem(input.id, 'input', inputType(input), input.label)) }
  for (let k of sketch.constants) { plan.state.push(new StateItem(k.id, 'constant', 'number', k.label)) }
  for (let v of sketch.values) { if (comp.bindings.has(v.id)) { plan.state.push(new StateItem(v.id, 'value', 'number', v.label)) } }
  if (hasClock(sketch)) { plan.state.push(new StateItem('clock', 'clock', 'number', sketch.hasCountdown ? sketch.countdown : sketch.stopwatch)) }
  if (sketch.list !== null) { plan.state.push(new StateItem('entries', 'list', 'LogEntry[]', sketch.list.label)) }

  // The composer's parts, then the catalogue's sections, then the custom section: the order they are on the screen in.
  let parts = compositionParts(comp)
  for (let p of parts) { plan.components.push(new PlanComponent(FILL_PART, p, new Map<string, string>())) }
  let blocks = compositionBlocks(comp)
  for (let i = 0; i < blocks.length; i++) {
    plan.components.push(new PlanComponent(FILL_BLOCK, blocks[i], i < blockValues.length ? blockValues[i] : blockDefaults(blocks[i].kind)))
  }
  if (custom !== null) { plan.components.push(new PlanComponent(FILL_HOLE, custom, new Map<string, string>())) }
  let partAt = (kind: string): number => {
    let at = parts.findIndex((p: FragmentSpec): boolean => p.kind === kind)
    return at >= 0 ? at : parts.length - 1
  }
  let add = (slot: PlanSlot, fill: string, by: number, detail: string = ''): void => {
    plan.fillWith(slot, fill, by, detail)
    plan.slots.push(slot)
  }

  for (let input of comp.inputs) {
    let slot = new PlanSlot('input.' + input.id, 'the person sets ' + input.label)
    slot.writes = [input.id]
    add(slot, FILL_PART, partAt('inputs'))
  }
  for (let v of sketch.values) {
    let b = comp.bindings.get(v.id)
    if (b === undefined) { continue }
    let slot = new PlanSlot('value.' + v.id, v.label + (v.means.length > 0 ? ': ' + v.means : ''))
    slot.reads = unique([b.a, b.b].concat(b.reads))
    slot.writes = [v.id]
    add(slot, FILL_PART, partAt('figures'))
  }
  if (hasClock(sketch)) {
    let slot = new PlanSlot('clock', sketch.hasCountdown ? 'counts down ' + sketch.countdown : 'counts up ' + sketch.stopwatch)
    slot.reads = unique([comp.countdownFrom])
    slot.writes = ['clock']
    add(slot, FILL_PART, partAt('clock'))
  }
  if (sketch.list !== null) {
    let slot = new PlanSlot('list', 'the person adds ' + sketch.list.label)
    slot.writes = ['entries']
    add(slot, FILL_PART, partAt('list'))
  }
  for (let e of comp.events) {
    let slot = new PlanSlot('event.' + e.id, e.what)
    slot.when = comp.moments.get(e.id) ?? ''
    slot.asked = e.asked
    let reads: string[] = []
    let args = comp.args.get(e.id)
    // An argument is read from the state (an input, a fixed number, an entry of the list) or is a fixed choice, which reads nothing.
    if (args !== undefined) {
      args.forEach((source: string) => {
        let name = source.substring(source.indexOf('.') + 1)
        if (source.startsWith('entry.')) { reads.push('entries.' + name) } else if (!source.startsWith('fixed.')) { reads.push(name) }
      })
    }
    slot.reads = unique(reads)
    add(slot, FILL_EFFECT, partAt('effects'), comp.effects.get(e.id) ?? '')
  }
  let block = parts.length
  for (let i = 0; i < comp.readyKinds.length; i++) {
    if (comp.readyKinds[i].length === 0) { continue }
    let slot = new PlanSlot('ready.' + i.toString(), sketch.ready[i])
    // The section chosen may be a reader put in its place (readLogInCharts).
    slot.accepts = unique(READY_KINDS.concat([comp.readyKinds[i]]))
    add(slot, FILL_BLOCK, block++)
  }
  // The live figures' section comes after the ready needs' blocks and before the sections that took a part's place (readLive runs
  // before chooseSections), so it has a slot of its own here, or every slot after it points one section too early.
  if (comp.blocks.indexOf(LIVE_KIND) >= 0) {
    let slot = new PlanSlot('live', 'fetches ' + comp.live.map((l: SketchLive): string => l.label).join(', ') + ' as they are now')
    slot.accepts = [LIVE_KIND]
    slot.writes = comp.live.map((l: SketchLive): string => l.id)
    add(slot, FILL_BLOCK, block++)
  }
  // A section that took a part's place: a slot of its own, filled by it.
  for (let r of comp.replaced) {
    let slot = new PlanSlot('section.' + r.kind, r.need)
    slot.accepts = [r.kind]
    add(slot, FILL_BLOCK, block++)
  }
  for (let i = 0; i < comp.custom.length; i++) {
    let slot = new PlanSlot('custom.' + i.toString(), comp.custom[i])
    slot.reads = comp.customReads.slice()
    slot.phone = comp.phoneNeeds.indexOf(comp.custom[i]) >= 0
    if (custom !== null) { add(slot, FILL_HOLE, plan.components.length - 1) } else { add(slot, FILL_OPEN, -1, TO_WRITE) }
  }
  for (let i = 0; i < comp.unbound.length; i++) { add(new PlanSlot('unbound.' + i.toString(), comp.unbound[i]), FILL_OPEN, -1, 'nothing does it') }
  return plan
}

/**
 * The plan of the whole screen as one hole (agent/AgentHole.ets), for when nothing narrower can be built: the sketch's
 * header, and a slot to be written for each thing it says the screen does -- what the person sets, what is worked out,
 * the clock, the list, what the phone does (each looked up), the ready needs and the rest. Jev reads the written
 * screen against every one of them.
 */
export function wholeScreenPlan(sketch: Sketch, widget: boolean): ScreenPlan {
  let plan = new ScreenPlan()
  plan.origin = PLAN_FROM_SKETCH
  plan.widget = widget
  plan.globals.set('__THEME__', 'clean')
  plan.globals.set('__HEADER_STYLE__', widget ? 'none' : 'default')
  plan.globals.set('__TITLE__', inQuotes(sketch.title))
  plan.globals.set('__EYEBROW__', inQuotes(sketch.eyebrow))
  plan.globals.set('__SUPPORTING__', inQuotes(sketch.subtitle))
  // A clock says what a timed screen is about; a list icon says nothing about the subject, so a screen with only a list gets none.
  plan.globals.set('__HEADER_ICON__', hasClock(sketch) ? 'clock' : '')
  let n = 0
  let add = (need: string, phone: boolean = false): void => { plan.addToWrite('screen.' + (n++).toString(), need, phone) }
  for (let input of sketch.inputs) {
    add('the person sets ' + input.label + (input.options.length > 0 ? ' (one of: ' +
      input.options.map((o: SketchOption): string => o.label).join(', ') + ')' : (input.unit.length > 0 ? ' (' + input.unit + ')' : '')))
  }
  for (let v of sketch.values) { add('shows ' + v.label + (v.means.length > 0 ? ': ' + v.means : '')) }
  if (sketch.hasCountdown) { add('counts ' + sketch.countdown + ' down to zero, with start, stop and reset') }
  if (sketch.hasStopwatch) { add('counts ' + sketch.stopwatch + ' up from zero, with start, stop and reset') }
  if (sketch.list !== null) {
    let list = sketch.list!
    add('the person adds ' + list.label + (list.fields.length > 0 ? ', each with ' +
      list.fields.map((f: ListField): string => f.label).join(', ') : '') + ', and sees them listed')
  }
  for (let e of sketch.events) { if (e.asked) { add(e.what + ' (' + e.when + ')', true) } }
  for (let r of sketch.ready) { add(r) }
  for (let o of sketch.other) { add(o) }
  return plan
}

/** The fixed numbers the sketch names, for the whole screen's writer: "Pi: 3.14". */
export function sketchConstants(sketch: Sketch): string[] {
  return sketch.constants.map((k: SketchConstant): string => k.label + ': ' + numberLiteral(k.value))
}

/**
 * The program, or '' when the composition has anything unbound: its plan (screenPlan above) assembled, with what is
 * not written yet left out -- the program so far, which a custom section is written against.
 */
export function assembleProgram(comp: Composition, blockValues: Map<string, string>[] = [], custom: FragmentSpec | null = null): string {
  if (comp.unbound.length > 0) { return '' }
  return assemblePlan(screenPlan(comp, blockValues, custom), true)
}

/** How many blocks of its own a composition puts before its sections: the slot number of its first section, less one. */
export function partCount(comp: Composition): number { return compositionParts(comp).length }


// ---- Pictures before the program is ready ----

/**
 * A whole number is set the same way every time, not as Jev happens to answer: - and + for a short range of whole numbers, typed for a
 * long one (2000 ml in steps of one) or one with a fraction. The same "hours until the flight" was a stepper in one run and a text
 * field in the next (Istanbul and Shanghai layover). '' leaves it to the choice.
 */
export function countWidget(input: SketchInput): string {
  if (input.kind !== 'count') { return '' }
  let whole = Number.isInteger(input.value) && Number.isInteger(input.min) && Number.isInteger(input.max)
  return whole && input.max - input.min <= 100 ? 'stepper' : 'typed_number'
}

/** The widget each kind gets when nobody has chosen yet. */
function defaultWidget(kind: string): string {
  if (kind === 'amount') { return 'typed_number' }
  if (kind === 'percent') { return 'slider' }
  if (kind === 'count') { return 'stepper' }
  if (kind === 'choice') { return 'select' }
  if (kind === 'text') { return 'text_field' }
  if (kind === 'time') { return 'time_field' }
  return 'switch'
}

/**
 * A program drawn from the sketch alone, for the screen to show while Jev (or a whole generation) is
 * still working: the inputs as default widgets, every value as a dash, a progress bar at zero. Shown
 * with taps off; never served. Empty when the sketch has nothing to draw yet.
 */
export function provisionalProgram(sketch: Sketch, widget: boolean = false): string {
  if (sketch.title.length === 0 && sketch.inputs.length === 0 && sketch.values.length === 0) { return '' }
  let comp = new Composition(sketch)
  comp.provisional = true
  comp.widget = widget
  comp.theme = 'clean'
  comp.inputs = sketch.inputs
  for (let input of sketch.inputs) { comp.widgets.set(input.id, defaultWidget(input.kind)) }
  for (let v of sketch.values) {
    let b = new Binding()
    b.show = v.format === 'fraction' ? 'progress' : 'stat'
    comp.bindings.set(v.id, b)
  }
  if (sketch.hasCountdown) {
    let sources: string[] = []
    lengthSources(sketch).forEach((_d: string, key: string) => { sources.push(key) })
    comp.countdownFrom = sources.length > 0 ? sources[0] : ''
    comp.countdownUnit = lengthUnitOf(sketch, comp.countdownFrom)
  }
  return assembleProgram(comp)
}

/**
 * The longest prefix of a streamed JSON object that ends after a complete value, closed with the
 * brackets still open at that point, so a half-written sketch parses. Cut points are right after a
 * closing bracket and right before a comma, outside strings; '' before the first one.
 */
export function closePartialJson(text: string): string {
  let start = text.indexOf('{')
  if (start < 0) { return '' }
  let stack: string[] = []
  let inString = false
  let escaped = false
  let cut = -1
  let closersAtCut = ''
  for (let i = start; i < text.length; i++) {
    let c = text[i]
    if (inString) {
      if (escaped) { escaped = false } else if (c === '\\') { escaped = true } else if (c === '"') { inString = false }
      continue
    }
    if (c === '"') { inString = true }
    else if (c === '{') { stack.push('}') }
    else if (c === '[') { stack.push(']') }
    else if (c === '}' || c === ']') {
      stack.pop()
      if (stack.length === 0) { return text.substring(start, i + 1) }
      cut = i + 1
      closersAtCut = stack.slice().reverse().join('')
    } else if (c === ',') {
      cut = i
      closersAtCut = stack.slice().reverse().join('')
    }
  }
  if (cut < 0) { return '' }
  return text.substring(start, cut) + closersAtCut
}

/** What a partial sketch would draw, to redraw only when it changes. */
export function sketchSignature(sketch: Sketch): string {
  let ids: string[] = [sketch.title, sketch.eyebrow, sketch.subtitle]
  for (let i of sketch.inputs) { ids.push(i.id + ':' + i.options.length.toString()) }
  for (let v of sketch.values) { ids.push(v.id) }
  ids.push(sketch.hasCountdown ? 'countdown' : (sketch.hasStopwatch ? 'stopwatch' : ''))
  ids.push(sketch.list !== null ? 'list:' + sketch.list.fields.map((f: ListField): string => f.id + '/' + f.kind).join(',') : '')
  return ids.join('|')
}

/**
 * The sketch as a plan for a generation that the composer could not serve: the same inputs and values,
 * so the finished program keeps the structure the preview showed while it was being written.
 */
export function sketchPlan(sketch: Sketch): string {
  let lines: string[] = ['A sketch of this app, made before writing it, which the screen already shows as a preview:']
  for (let i of sketch.inputs) {
    let options = i.options.length > 0 ? ', options ' + i.options.map((o: SketchOption): string => o.label).join(' / ') : ''
    lines.push('- input "' + i.label + '" (' + i.kind + (!isNumeric(i.kind) || i.kind === 'choice' ? '' : ', ' + i.min.toString() + ' to ' + i.max.toString()) + options + ')')
  }
  for (let c of sketch.constants) { lines.push('- fixed: ' + c.label + ' = ' + numberLiteral(c.value)) }
  if (sketch.hasCountdown) { lines.push('- a countdown: ' + sketch.countdown) }
  if (sketch.hasStopwatch) { lines.push('- a stopwatch: ' + sketch.stopwatch) }
  if (sketch.list !== null) { lines.push('- ' + describeList(sketch.list)) }
  for (let v of sketch.values) { lines.push('- shows "' + v.label + '": ' + v.means) }
  for (let e of sketch.events) { lines.push('- ' + e.when + ': ' + e.what) }
  for (let need of sketch.ready) { lines.push('- a ready-made section: ' + need) }
  for (let item of sketch.other) { lines.push('- also: ' + item) }
  lines.push('Keep these inputs, values and their labels where they fit the request, and add whatever else it needs. The request decides.')
  return lines.join('\n')
}

// ---- The whole route, as the Generate screen runs it ----

export class ComposeResult {
  /** A validated multi-screen plan, carried before the one-screen Sketch loses its relationships. */
  appPlan: NeedsPlan | null = null
  /** A reply attempted screen structure but none could be validated; do not erase it in a flat fallback. */
  appPlanFailed: boolean = false
  /** The assembled program; empty when the request cannot be composed. */
  source: string = ''
  /** One line for the trace and the status area: why, or what was chosen. */
  note: string = ''
  sketchMs: number = 0
  jevMs: number = 0
  sketch: string = ''
  answers: string[] = []
  /** The parsed sketch, null when there was none; the page keeps it as a plan for a fallback generation. */
  parsed: Sketch | null = null
  /** What the sketch added and the screen leaves out, for the person to see. */
  dropped: string[] = []
  /** What the request asks the phone to do that no effect does (Composition.unboundNeeds), for whoever builds the screen instead. */
  unboundNeeds: string[] = []
  /** The plan was drawn again with what the person answered. */
  replanned: boolean = false
  /** How many times the plan was asked for until one could be used (NeedsChoose.ets's drawPlan), all drawings together. */
  planTries: number = 0
  /**
   * The composition, whenever nothing is unbound. When it has sections of the catalogue or needs a custom section,
   * those are filled first and the program assembled after (assembleProgram with them), so `source` is still empty;
   * otherwise `source` is already its program. Null when the composition is not served.
   */
  composition: Composition | null = null
}

/** Compatibility entry point; all application selectors share VeraSelector. */
export async function askJev(body: string, apiKey: string, cancellation?: OperationCancellation): Promise<string> {
  return askSelector(body, apiKey, cancellation)
}

/** Asks for the sketch: (system prompt, request, reply so far) -> the whole reply, or null when there was none. */
export type SketchAsk = (system: string, user: string, onText: (soFar: string) => void, think: boolean) => Promise<string | null>
/** Asks Jev: request body -> response body, '' when there was none. */
export type JevAsk = (body: string) => Promise<string>

/**
 * Runs between the plan and Jev's choices with the plan: text that settles what the plan left open (the person's answers),
 * for the plan to be drawn again with, or '' to go on with the plan as it is.
 */
export type PlanReview = (sketch: Sketch) => Promise<string>

/**
 * Jev's choices for a plan already drawn, and the composition read from them. `pre` are answers given before this call (the
 * needs plan's choices of a section or a part, NeedsChoose.ets): they are put into Jev's body and the questions they answer
 * are named in `settled`, so Jev is not asked them twice.
 */
export async function composeFromSketch(result: ComposeResult, prompt: string, sketch: Sketch, askChoices: JevAsk,
    widget: boolean = false, pre: Record<string, Object> | null = null, settled: string[] = [],
    cancellation?: OperationCancellation): Promise<ComposeResult> {
  throwIfCancelled(cancellation)
  result.parsed = sketch
  let started = Date.now()
  let chosen: Map<string, string> = new Map<string, string>()
  if (pre !== null) {
    for (let i = 0; i < sketch.ready.length; i++) {
      let answer = pre![('ready.' + i.toString())]
      if (answer !== undefined && answer !== null && typeof answer === 'object') {
        let kind = (answer as Record<string, Object>)['choice']
        if (typeof kind === 'string') { chosen.set('ready.' + i.toString(), kind as string) }
      }
    }
  }
  let request = buildComposeRequest(prompt, sketch, widget, settled, chosen)
  throwIfCancelled(cancellation)
  let body = await askChoices(request)
  throwIfCancelled(cancellation)
  // No answer is most often the network: once more before the plan is left to the route's wider holes.
  if (body.length === 0) {
    throwIfCancelled(cancellation)
    body = await askChoices(request)
    throwIfCancelled(cancellation)
  }
  result.jevMs += Date.now() - started
  if (body.length === 0) { result.note = 'Jev did not answer twice'; return result }
  if (pre !== null) { body = withAnswers(body, pre!) }
  let comp = readComposition(body, sketch, widget)
  result.answers = comp.answers
  if (comp.unbound.length > 0) {
    result.note = 'unbound: ' + comp.unbound.join('; ')
    result.unboundNeeds = comp.unboundNeeds
    return result
  }
  result.unboundNeeds = comp.unboundNeeds
  result.dropped = comp.dropped
  result.composition = comp
  if (comp.blocks.length === 0 && comp.custom.length === 0) { result.source = assembleProgram(comp) }
  result.note = 'composed: ' + sketch.inputs.length.toString() + ' inputs, ' + sketch.values.length.toString() + ' values' +
    (sketch.hasCountdown ? ', countdown' : '') + (sketch.hasStopwatch ? ', stopwatch' : '') + (sketch.list !== null ? ', list' : '') +
    (comp.events.length > 0 ? ', ' + comp.events.length.toString() + ' effects' : '') +
    (comp.blocks.length > 0 ? ', sections ' + comp.blocks.join('+') + (comp.realData ? ' (real data)' : '') : '') +
    (comp.custom.length > 0 ? ', custom: ' + comp.custom.join('; ') : '') +
    (comp.dropped.length > 0 ? '; left out: ' + comp.dropped.join('; ') : '')
  return result
}

/** Jev's body with more answers in it, which win over any of the same name. */
function withAnswers(body: string, more: Record<string, Object>): string {
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let answers: Record<string, Object> = {}
    let found = parsed['answers']
    if (found !== null && found !== undefined) { answers = found as Record<string, Object> }
    Object.keys(more).forEach((key: string) => { answers[key] = more[key] })
    parsed['answers'] = answers
    return JSON.stringify(parsed)
  } catch (_e) {
    return body
  }
}
