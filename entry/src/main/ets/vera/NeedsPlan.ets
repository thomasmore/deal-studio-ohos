/**
 * The plan of a new screen as the model writes it when it knows nothing of how the screen will be built: the needs of the
 * request, in words, by what each does and whose data it is -- never by the part or the section of the catalogue that will do it.
 * NeedsChoose.ets chooses those; sketchFrom here turns the plan and the choices into the Sketch the composer reads
 * (VeraCompose.ets), so everything after the plan is as it was.
 *
 * The prompt names no section and no part. What it does say of a countdown, a stopwatch and entries is what the person sees,
 * which a part and a section of the catalogue both give.
 */

import { Sketch, parseSketch, SCENE_MARK } from './VeraCompose'

export const NEED_FIGURE: string = 'figure'
export const NEED_COUNTDOWN: string = 'countdown'
export const NEED_STOPWATCH: string = 'stopwatch'
export const NEED_ENTRIES: string = 'entries'
export const NEED_CONTENT: string = 'content'
export const NEED_ACTION: string = 'action'
export const NEED_OTHER: string = 'other'
/** A picture the app draws itself every frame, moving on its own or touched anywhere: written as a ui.Surface in the section hole. */
export const NEED_SCENE: string = 'scene'
/** A figure of the real world as it is now (a price, a rate, the weather), fetched by the app itself: the live_figure section. */
export const NEED_LIVE: string = 'live'
const NEED_TYPES: string[] = [NEED_FIGURE, NEED_LIVE, NEED_COUNTDOWN, NEED_STOPWATCH, NEED_ENTRIES, NEED_CONTENT, NEED_ACTION, NEED_SCENE, NEED_OTHER]

/** The moments an action can be tied to, for the choice of what does a need (NeedsChoose.ets). */
export const ON_END: string = 'countdown_end'
export const ON_ADDED: string = 'entry_added'
export const ON_TAP: string = 'row_tap'
export const ON_BUTTON: string = 'button'
export const ON_TIME: string = 'time'
const ON_MOMENTS: string[] = [ON_END, ON_ADDED, ON_TAP, ON_BUTTON, ON_TIME, 'other']

/**
 * The numbers a screen's time and entries give a formula, under names that mean the same whoever gives them. The composer
 * reads them under its own (right-hand) names.
 */
const QUANTITIES: string[][] = [['clock.remaining', 'remaining'], ['clock.elapsed', 'elapsed'], ['clock.duration', 'duration'],
  ['entries.count', 'entryCount'], ['entries.total', 'entryTotal']]

export class Need {
  /** Stable within a plan; old one-screen replies receive a positional id. */
  id: string = ''
  /** References to needs whose data this presentation uses, not copies of their collections. */
  uses: string[] = []
  /** One of NEED_TYPES. */
  type: string = NEED_OTHER
  /** The need's own words: what it is, for the question of what does it. */
  words: string = ''
  /** The need as the composer's plan holds it (VeraCompose.ets's parseSketch reads these fields): a figure, a countdown, ... */
  raw: Record<string, Object> = {}
  /** For an action: the moment it is tied to. */
  on: string = ''
  /** For a figure: the quantities it reads (clock.remaining, entries.count, ...). */
  reads: string[] = []
  /** For a countdown: the id the plan says sets its length. */
  length: string = ''
  /** For content and an action: the words of the request that ask for it, as the model quoted them. */
  from: string = ''
}

export class NeedScreen {
  id: string = ''
  needs: string[] = []
}

export class NeedTransition {
  from: string = ''
  to: string = ''
  on: string = ''
  /** Optional need id followed by .id: the selected record, never its array position. */
  record: string = ''
}

export class NeedsPlan {
  /** Effective request after blocking questions, set by composeNeeds before the app handoff. */
  request: string = ''
  /** Title, eyebrow, subtitle, inputs, constants, questions: as the composer's plan has them. */
  base: Record<string, Object> = {}
  needs: Need[] = []
  /** Omitted in old replies and ordinary one-screen apps. */
  screens: NeedScreen[] = []
  startScreen: string = ''
  /** Presentation is independent of entry point: peer views can be tabs; record flows use pages. */
  presentation: string = 'pages'
  compact: boolean = false
  transitions: NeedTransition[] = []
}

/**
 * What the model is asked. The rules are the composer's own for numbers, times and units: they are what keeps a formula
 * checkable, and they do not depend on who does the work.
 */
export const NEEDS_PROMPT: string =
  'You turn a request for a small phone app into a JSON plan of what the app needs. Write no code. Answer with one JSON object:\n' +
  '{"title": short app title, "eyebrow": 1-3 word label in capitals, "subtitle": one short line,\n' +
  ' "inputs": [{"id": camelCase, "label": shown label, "kind": "amount" | "percent" | "count" | "choice" | "toggle" | "text" | "time",\n' +
  '   "measure": "money" | "percent" | "count" | "seconds" | "minutes" | "number", "min": number, "max": number, "value": starting number, "unit": the currency or unit the request uses, or "",\n' +
  '   "setting": true for a value set once and rarely changed afterwards (a goal, a threshold, a size, a gap, sleep hours) that the request does not state, else leave it out,\n' +
  '   "options": only for choice: [{"label": shown text, "value": the number the option stands for, such as a length of time}];\n' +
  '   a choice\'s own "value" is the index of the starting option}],\n' +
  ' "constants": [{"id": camelCase, "label": what it is, "value": number, "measure": as for inputs}],\n' +
  ' "needs": [one object for each thing the app shows or does beyond inputs and constants, in the order the screen shows them, each of one type:\n' +
  '   {"type": "figure", "id": camelCase, "label": shown label, "means": what the number is, in plain words,\n' +
  '    "format": "money" | "percent" | "count" | "seconds" | "minutes" | "time_of_day" | "fraction" | "yes_no" (a condition, 1 for yes and 0 for no) | "plain", "unit": as for inputs,\n' +
  '    "decimals": for a plain number, how many digits after the point to show, 0 to 6, only when one digit would lose what matters,\n' +
  '    "shown": false for every figure that only feeds another figure and is not what the request names, however informative it looks; otherwise leave it out,\n' +
  '    "formula": how it is worked out, as an expression over the ids of inputs, constants, live figures, the figures before it and the quantities below,\n' +
  '    with numbers, + - * / %, parentheses and floor, ceil, round, abs, min, max, pow, sqrt,\n' +
  '    "example": {"given": {each id or quantity the formula needs, directly or through the figures before it: a sample number},\n' +
  '    "result": the number the formula gives for them}},\n' +
  '   {"type": "live", "id": camelCase, "label": shown label, "means": what the figure is, in plain words, "measure": "money" | "percent" | "count" | "number",\n' +
  '    "unit": the currency or unit it is shown in, "query": 3 to 8 words a web search finds it with as it is now},\n' +
  '   {"type": "countdown", "label": what is being timed, "length": the id of the input, constant or figure that sets how long it runs},\n' +
  '   {"type": "stopwatch", "label": what is being timed},\n' +
  '   {"type": "entries", "label": what the entries are, "fields": what each entry holds, up to 4 for a one-screen app: [{"id": camelCase, "label": shown label,\n' +
  '    "kind": "text" | "number" | "time" | "date" | "toggle" ("date" for a calendar day: an expiry, a due date, a birthday), "measure": ' +
  'for a number, as for inputs, "unit": as for inputs, "value": starting value,\n' +
  '    "decimals": for a plain number, as for a figure}] (no fields when adding an entry takes only a tap)},\n' +
  '   {"type": "content", "what": in plain words everything the need involves: what it lists or shows, what the person does with it, what the phone does,\n' +
  '    "from": the words of the request that ask for it, copied exactly},\n' +
  '   {"type": "action", "id": camelCase, "when": the moment, "what": what the phone does, "asked": true if the request asks for it, false if you add it,\n' +
  '    "on": "countdown_end" | "entry_added" | "row_tap" | "button" | "time" | "other",\n' +
  '    "from": the words of the request that ask for it, copied exactly},\n' +
  '   {"type": "scene", "what": in plain words what is drawn, what moves on its own or follows the finger, how it starts and stops, ' +
  'and what it decides or changes, "from": the words of the request that ask for it, copied exactly},\n' +
  '   {"type": "other", "what": a few words}],\n' +
  ' "questions": [at most 2, usually none: {"id": camelCase, "ask": a short question for the person, "options": 2 to 4 short answers,\n' +
  '   "default": the index of the answer this plan assumes}]}\n' +
  'What each type brings with it, so it is never listed again: a countdown, start, stop and reset buttons and the time left; ' +
  'a stopwatch, start, stop and reset buttons and the time passed; entries, a form with its fields, an add button, the list of entries ' +
  'with their fields and the time each was added, a way to remove one, and how many there are and what their first number adds up to; ' +
  'when the phone does something as an entry is added, that entry shows what the phone answered. ' +
  'The quantities a figure may read: entries.count and entries.total (the first number field of the entries added up) when there are entries; ' +
  'clock.remaining, clock.elapsed and clock.duration, in seconds, when there is a countdown; clock.elapsed, in seconds, when there is a stopwatch. ' +
  'The app keeps its state between visits. ' +
  'When the request needs distinct views or an editor/detail flow, you MUST add top-level screens, startScreen and transitions to this SAME reply, in Generate AND Chat. ' +
  'Opening an item to see its details or edit it is a navigation flow even if the person never says screen. Do not hide destinations only in a need\'s prose. ' +
  'Add presentation: "tabs" for peer views in a compact widget, or "pages" for list/detail/editor navigation. Tabs and pages share the same screen metadata and data ownership. ' +
  'Do not add screens to an ordinary calculator, form, timer or simple list just to separate related information. A plain inline form is not a separate view. ' +
  'For a multi-screen app give EVERY need a unique camelCase id (including entries, content and other). Each collection has ONE owning need; ' +
  'another presentation, editor, summary or history refers to that need with uses: [need ids], never duplicates its records. ' +
  'screens: [{"id": camelCase, "needs": [need ids shown or edited here]}], startScreen: one screen id, ' +
  'transitions: [{"from": screen id, "to": screen id, "on": what the person does, "record": optional "owningNeed.id"}]. ' +
  'Use 2 to 8 screens only when warranted. Every screen is reachable from startScreen through these transitions. ' +
  'Include navigation, selected-record behavior and Save/Cancel in the relevant needs, not external phone actions. ' +
  'A list shown on several screens or in an editor remains one collection with stable record IDs. ' +
  'A live figure is a number of the real world that changes by itself and that the app fetches from the internet as it is now and keeps up to date: ' +
  'a price, an exchange rate, an index, the weather now, a live score; at most 3, and the app shows each with where and when it was read. ' +
  'It is never also a figure or content; a figure worked out from it (what the person\'s coins are worth) is a figure whose formula reads its id, and ' +
  'whose example gives it a sample number. Today\'s forecast (the high, the chance of rain) is live too: it is fetched the same way. ' +
  'A fact that does not change or a figure at a past date is content, not live. ' +
  'The app fetches a live figure from one fixed address written when it is made, so the place, the currency or the thing it is about ' +
  'is fixed in its query ("Moscow temperature now", "Bitcoin price USD"): it is never an input the person types or changes, ' +
  'and nothing on the screen chooses it. When the request does not say which place or thing it is, that is a question, ' +
  'with a sensible default as its answer, and each of its options names exactly one place or thing (a city, a team, a coin), ' +
  'never a kind or a group of them ("a Premier League match"): a search for a group finds no one figure.\n' +
  'Rules: inputs are only what the person sets once for the whole screen; what each entry holds goes in its fields. ' +
  'A quantity is in one place: one the person records again and again (a temperature, a weight, a dose taken) is a field of the entries ' +
  'and the figures read the latest or all of them, never also an input. ' +
  'When several named people each do something that is counted for them (two kids earning stars for chores, friends paying), each ' +
  'time is an entry with a field for who did it and its amount, so each person\'s total can be worked out; a list ticked once for ' +
  'everyone cannot say whose it was. ' +
  'content is what the app starts with, written for the request: items, places, steps, facts or figures that anyone could look up or suggest. ' +
  'What the person keeps themselves -- their notes, entries, records, contacts or messages -- is never content: it starts empty, and is entries. ' +
  'Everything a need brings -- its items, its buttons, what the phone does from them, its counts -- belongs to that need alone: ' +
  'it is never also an input, a figure, an action or an other. ' +
  'A time of day (an input or field of kind time, a figure of format time_of_day) is minutes since midnight, 07:30 being 450; ' +
  'a length of time, such as time left or a pace, is never a time of day. constants are fixed numbers the app needs and the person does not set. ' +
  'A number the request names itself (three undos, 15-minute blocks, four friends) is a constant, not an input, unless the request asks ' +
  'the person to set or change it. ' +
  'figures are every number the request asks to show, in an order where each can be worked out from inputs, constants, the quantities above ' +
  'and the figures before it, in one step: two numbers added, subtracted, multiplied or divided, a percent of a number, one number as a percent ' +
  'of another, a number rounded up, or one number divided by another and rounded up. A number that takes more steps gets a figure for each step ' +
  'before it. A progress bar is a figure with format fraction. A formula gives its figure in the figure\'s format: seconds or minutes as the format says, ' +
  'minutes since midnight for time_of_day, 0 to 100 for percent, 0 to 1 for fraction; in a formula a choice\'s id stands for its chosen option\'s value. ' +
  'A length of time is in seconds, option values, constants and figures included (it is shown as m:ss); only a number the person types in minutes is in minutes, ' +
  'and its measure says so. ' +
  'actions are things the phone does outside this screen, one per action: a detail of an action, such as its reminder or its repeat, belongs in that action, ' +
  'and showing something on this screen is never an action; every number an action needs, such as how many minutes before a reminder goes off, is an input, ' +
  'a field or a constant (a reminder whose lead time the request does not name is a constant of 0 minutes, so it goes off at the start), and every time of day ' +
  'it needs, such as when it starts, is a time input or a time field, even when the request does not name it. ' +
  'other lists everything the request asks for that no type above covers; it is empty only when nothing is left out. Leaving a requested feature out of the plan is wrong. ' +
  'Keep to what the request asks for: no inputs, figures or actions it does not need. ' +
  'Where the request gives a number for something the person sets (a length of time, an amount, a count), that input starts at it, ' +
  'and a choice among several values has that one among its options and starts on it. ' +
  'A countdown or a stopwatch is for a length of time the person starts and watches run: a reminder, an alarm or a notification is an action ' +
  'the phone does at its time, never a countdown, and the time left until it is not shown unless the request asks for it. ' +
  'entries are only records the person keeps and adds to; items the request names for the person to tick off or read are content, ' +
  'never also entries. What is written for the request (content) shows its own progress and counts: no figure counts its items, ' +
  'and entries.count and entries.total are only for entries the person adds. ' +
  'A need that only helps fill in another need, such as a list of choices for a field, belongs to that need and is not a need of its own. ' +
  'A scene is a picture the app draws itself that moves on its own or is touched anywhere on it: a wheel that spins, a ball that rolls, ' +
  'dice that tumble, a drawing or signature area, a physics toy, an animated dial. A chart, a progress bar or a ring that only shows a figure is ' +
  'never a scene, and a scene is planned only when the request asks for something drawn, animated, moving or touched in its own ' +
  'words: a coin flip or a dice roll that does not ask for an animation is built from the other types. ' +
  'A camera view is never a scene: the person is looking through the camera, not at a picture the app draws. Plan photographing, ' +
  'scanning or looking through the camera as other. Describe the live preview and what the person captures with the shutter. ' +
  'A request in which the person photographs, scans or points the camera at something always needs a live camera view; never leave it out. ' +
  'What a scene decides and everything that changes with it -- the result, the winner, a balance or score it pays into, the ' +
  'results so far -- belongs to that scene, written in its what, and is never also a figure, entries or an action; the inputs the person sets ' +
  'for it (a stake, a choice) stay inputs. When what the person draws or signs is kept with each record (a signature on a receipt, ' +
  'a sketch on a note), the records belong to the scene as well: no entries need for them, and the scene\'s what names what each ' +
  'record keeps; a drawing is kept as its strokes and shown again from them, never as an image or a file. ' +
  'Labels are short: three words at most. ' +
  'When the request does not say which place, person, thing or period it is about and what the app shows depends on it, that goes first in questions ' +
  '(not units, looks or anything a default does well): the app is made for the answer, and the person is not made to type it into the app for ' +
  'content the app has to look up. ' +
  'A number of hours or days is measure number with its unit written in unit (hours, days): measure seconds or minutes is only for a number counted in seconds or minutes. ' +
  'The screen shows what the request names; the steps worked out on the way to it are shown: false. ' +
  'A content or action need is written only when the request itself asks for it, in words you can quote: a note, a tip, an example, ' +
  'a reminder or a notification the request does not name is not written, however useful it would be. ' +
  'Use the numbers the request gives; where it gives none, pick sensible ones. ' +
  'questions are only for what the request leaves out and no sensible choice can stand in for, because the answer changes ' +
  'what the app is (which two units a converter is between, which kind of thing a tracker keeps); never for a number, a ' +
  'label, a look or anything a default does well. The plan is drawn for each question\'s default answer.'

function text(o: Record<string, Object>, key: string): string {
  let v = o[key]
  return typeof v === 'string' ? (v as string).trim() : ''
}

/** The quantities of QUANTITIES a formula (or the sample numbers of its example) names. */
function quantitiesIn(raw: Record<string, Object>): string[] {
  let found: string[] = []
  let formula = text(raw, 'formula')
  for (let q of QUANTITIES) { if (formula.indexOf(q[0]) >= 0 && found.indexOf(q[0]) < 0) { found.push(q[0]) } }
  return found
}

/** A formula, or the names of an example's sample numbers, with the quantities under the composer's own names. */
function composerNames(s: string): string {
  let out = s
  for (let q of QUANTITIES) { out = out.split(q[0]).join(q[1]) }
  return out
}

/** The plan from the model's reply, or null when it is not one. */
export function parseNeedsPlan(reply: string, problems: string[] = []): NeedsPlan | null {
  let start = reply.indexOf('{')
  let end = reply.lastIndexOf('}')
  if (start < 0 || end <= start) { return null }
  let o: Record<string, Object>
  try {
    o = JSON.parse(reply.substring(start, end + 1)) as Record<string, Object>
  } catch (_e) {
    return null
  }
  let plan = new NeedsPlan()
  let keep: string[] = ['title', 'eyebrow', 'subtitle', 'inputs', 'constants', 'questions']
  for (let key of keep) { if (o[key] !== undefined) { plan.base[key] = o[key] } }
  let needs = o['needs']
  if (!Array.isArray(needs)) { return o['screens'] === undefined ? plan : null }
  for (let item of needs as Object[]) {
    if (item === null || typeof item !== 'object') { continue }
    let raw = item as Record<string, Object>
    let type = text(raw, 'type')
    if (NEED_TYPES.indexOf(type) < 0) { continue }
    let need = new Need()
    need.id = text(raw, 'id') || 'need' + plan.needs.length.toString()
    let uses = raw['uses']
    let multi = Array.isArray(o['screens']) && (o['screens'] as Object[]).length > 1
    if (multi && uses !== undefined && (!Array.isArray(uses) || (uses as Object[]).some((v: Object): boolean => typeof v !== 'string'))) {
      problems.push('Need ' + need.id + ' has invalid uses: expected an array of need ids')
      return null
    }
    need.uses = multi && uses !== undefined ? (uses as string[]).slice() : []
    need.type = type
    need.raw = raw
    if (type === NEED_FIGURE) {
      need.words = text(raw, 'label') + (text(raw, 'means').length > 0 ? ' (' + text(raw, 'means') + ')' : '')
      need.reads = quantitiesIn(raw)
    } else if (type === NEED_LIVE) {
      need.words = text(raw, 'label') + (text(raw, 'means').length > 0 ? ' (' + text(raw, 'means') + ')' : '')
    } else if (type === NEED_COUNTDOWN || type === NEED_STOPWATCH || type === NEED_ENTRIES) {
      need.words = text(raw, 'label')
      need.length = text(raw, 'length')
    } else if (type === NEED_ACTION) {
      need.words = text(raw, 'when') + ': ' + text(raw, 'what')
      need.on = ON_MOMENTS.indexOf(text(raw, 'on')) >= 0 ? text(raw, 'on') : 'other'
      need.from = text(raw, 'from')
    } else {
      need.words = text(raw, 'what')
      if (type === NEED_CONTENT || type === NEED_SCENE) { need.from = text(raw, 'from') }
    }
    plan.needs.push(need)
  }
  let problem = readScreens(plan, o)
  if (problem.length > 0) { problems.push(problem); return null }
  return plan
}

/** Screen plans are validated before they can bypass the one-screen composer. No guessed dangling references. */
function readScreens(plan: NeedsPlan, raw: Record<string, Object>): string {
  let screens = raw['screens']
  // Optional one-screen metadata must not impose the shared-app id/reference contract on legacy plans.
  if (Array.isArray(screens) && screens.length < 2) { return '' }
  if (screens === undefined) {
    return raw['startScreen'] === undefined && raw['transitions'] === undefined ? '' : 'startScreen/transitions require screens'
  }
  if (!Array.isArray(screens) || screens.length > 8) { return 'screens must be an array of 2 to 8 screens' }
  let presentation = raw['presentation']
  if (presentation !== undefined && presentation !== 'pages' && presentation !== 'tabs') { return 'presentation must be pages or tabs' }
  if (presentation !== undefined) { plan.presentation = presentation as string }
  let validId = (id: string): boolean => /^[a-z][A-Za-z0-9_]{0,47}$/.test(id)
  let ids: string[] = []
  for (let n of plan.needs) {
    if (!validId(text(n.raw, 'id'))) { return 'Every multi-screen need requires a valid id: missing/invalid id for ' + n.words }
    if (ids.indexOf(n.id) >= 0) { return 'Duplicate need id: ' + n.id }
    ids.push(n.id)
  }
  for (let n of plan.needs) {
    for (let id of n.uses) {
      if (ids.indexOf(id) < 0 || id === n.id) { return 'Need ' + n.id + ' has dangling/self uses reference: ' + id }
    }
  }
  let screenIds: string[] = []
  for (let item of screens as Object[]) {
    if (item === null || typeof item !== 'object') { return 'Each screen must be an object with id and needs' }
    let value = item as Record<string, Object>
    let screen = new NeedScreen()
    screen.id = text(value, 'id')
    if (!validId(screen.id) || screenIds.indexOf(screen.id) >= 0) { return 'Missing, invalid or duplicate screen id: ' + screen.id }
    let refs = value['needs']
    if (!Array.isArray(refs) || refs.some((id: Object): boolean => typeof id !== 'string' || ids.indexOf(id as string) < 0)) {
      return 'Screen ' + screen.id + ' needs must reference declared need ids'
    }
    screen.needs = (refs as string[]).slice()
    screenIds.push(screen.id)
    plan.screens.push(screen)
  }
  plan.startScreen = text(raw, 'startScreen')
  if (screenIds.indexOf(plan.startScreen) < 0) { return 'startScreen must reference a declared screen id' }
  let transitions = raw['transitions']
  if (transitions !== undefined && !Array.isArray(transitions)) { return 'transitions must be an array' }
  for (let item of (transitions ?? []) as Object[]) {
    if (item === null || typeof item !== 'object') { return 'Each transition must be an object' }
    let value = item as Record<string, Object>
    let t = new NeedTransition()
    t.from = text(value, 'from'); t.to = text(value, 'to'); t.on = text(value, 'on'); t.record = text(value, 'record')
    if (value['record'] !== undefined && typeof value['record'] !== 'string') { return 'Transition record must be a need id or need.id string' }
    // A bare declared owner names the same record source. Canonicalize locally rather than buying another plan.
    if (ids.indexOf(t.record) >= 0) { t.record += '.id' }
    if (screenIds.indexOf(t.from) < 0 || screenIds.indexOf(t.to) < 0 || t.on.length === 0) { return 'Transition requires declared from/to screens and a nonempty on' }
    if (t.record.length > 0 && (!t.record.endsWith('.id') || ids.indexOf(t.record.substring(0, t.record.length - 3)) < 0)) { return 'Transition has an undeclared record owner: ' + t.record }
    plan.transitions.push(t)
  }
  let reached: string[] = [plan.startScreen]
  for (let i = 0; i < screenIds.length; i++) {
    for (let t of plan.transitions) { if (reached.indexOf(t.from) >= 0 && reached.indexOf(t.to) < 0) { reached.push(t.to) } }
  }
  return reached.length === screenIds.length ? '' : 'Every screen must be reachable from startScreen through transitions'
}

/** A named destination in prose must not silently go through the lossy flat composer.
 * Conservative English structural guard, not a semantic classifier of every possible request.
 */
export function navigationPlanProblem(plan: NeedsPlan): string {
  if (plan.screens.length > 1) { return '' }
  // Action needs describe the PHONE's destinations, not this app's internal views.
  let words = plan.needs.filter((n: Need): boolean => n.type !== NEED_ACTION).map((n: Need): string => n.words).join('\n')
  if (!/\b(?:detail|editor|edit|second|another|separate)\s+(?:screen|view|page)\b|\b(?:opens?|navigat\w*)\b[^.\n]{0,80}\b(?:details|editor|screen|page)\b/i.test(words)) { return '' }
  return 'The needs describe navigation to a detail/editor or another view, but the plan has no multi-view metadata. ' +
    'Declare screens, startScreen and transitions for every destination; use one shared collection and record IDs. ' +
    'Use presentation pages for list/detail/editor flows or tabs for peer views. Do not flatten the navigation into a single inline section.'
}

/** Only metadata and questions, not the lossy one-list/one-clock projection, for the app-plan handoff. */
export function planningSketch(plan: NeedsPlan): Sketch | null {
  return plan.screens.length > 1 ? parseSketch(JSON.stringify(plan.base)) : sketchFrom(plan)
}

/** The first need of a type, or null. One countdown, one stopwatch and one list of entries make a screen: a second is left to `other`. */
export function needOf(plan: NeedsPlan, type: string): Need | null {
  for (let n of plan.needs) { if (n.type === type) { return n } }
  return null
}

/**
 * The composer's plan for this one: each need as its own field. A need the choices give to a section of the catalogue is
 * a `ready` need (NeedsChoose.ets puts Jev's answer for it where readComposition looks); the others are as the plan wrote them.
 * Null when the composer cannot read the result.
 */
export function sketchFrom(plan: NeedsPlan): Sketch | null {
  let o: Record<string, Object> = {}
  Object.keys(plan.base).forEach((key: string) => { o[key] = plan.base[key] })
  let values: Object[] = []
  let events: Object[] = []
  let ready: Object[] = []
  let live: Object[] = []
  let other: Object[] = []
  for (let n of plan.needs) {
    let r: Record<string, Object> = {}
    Object.keys(n.raw).forEach((key: string) => { r[key] = n.raw[key] })
    if (n.type === NEED_FIGURE) {
      r['formula'] = composerNames(text(r, 'formula'))
      let example = r['example']
      if (example !== null && example !== undefined && typeof example === 'object') {
        let e = example as Record<string, Object>
        let given = e['given']
        if (given !== null && given !== undefined && typeof given === 'object') {
          let g = given as Record<string, Object>
          let renamed: Record<string, Object> = {}
          Object.keys(g).forEach((key: string) => { renamed[composerNames(key)] = g[key] })
          let e2: Record<string, Object> = {}
          Object.keys(e).forEach((key: string) => { e2[key] = e[key] })
          e2['given'] = renamed
          r['example'] = e2
        }
      }
      values.push(r)
    } else if (n.type === NEED_COUNTDOWN || n.type === NEED_STOPWATCH) {
      // One clock per screen: a second is left to the part's own rule in parseSketch (a stopwatch beside a countdown is `other`).
      if (n.type === NEED_COUNTDOWN && o['countdown'] === undefined) { o['countdown'] = r }
      else if (n.type === NEED_STOPWATCH && o['stopwatch'] === undefined) { o['stopwatch'] = r }
      else { other.push('a second ' + (n.type === NEED_COUNTDOWN ? 'countdown' : 'stopwatch') + ': ' + n.words) }
    } else if (n.type === NEED_ENTRIES) {
      if (o['list'] === undefined) { o['list'] = r } else { other.push('a second list of entries: ' + n.words) }
    } else if (n.type === NEED_LIVE) {
      live.push(r)
    } else if (n.type === NEED_CONTENT) {
      ready.push(n.words)
    } else if (n.type === NEED_ACTION) {
      events.push(r)
    } else if (n.type === NEED_SCENE) {
      if (isCameraNeed(n.words)) {
        // A camera view is not a drawn scene: the written section uses ui.Camera, with a live preview, not a Surface.
        other.push(n.words)
      } else {
        // Marked, so it goes to the written section as a scene: nothing of the catalogue or the parts draws one.
        other.push(SCENE_MARK + n.words)
      }
    } else {
      other.push(n.words)
    }
  }
  o['values'] = values
  o['events'] = events
  o['ready'] = ready
  o['live'] = live
  o['other'] = other
  return parseSketch(JSON.stringify(o))
}

export function isCameraNeed(words: string): boolean {
  return /\b(?:cameras?|photograph(?:s|ed|ing|y)?|scan(?:s|ned|ning|ners?)?)\b/i.test(words)
}

/**
 * True only for a need the capture fragment can actually satisfy on its own:
 * framing a live preview, snapping one photo and keeping it. A need that also
 * asks to scan, decode, recognize or identify something (a QR scanner that
 * decodes a code and opens its URL), or one that mentions a camera only in
 * passing (a camera-settings checklist, "display ... without taking photos"),
 * is not satisfied by appending a captured JPEG to a photo list, so it returns
 * false and is left for the section writer -- the rest of the behavior stays
 * open instead of being silently dropped with no unsupported-feature notice.
 */
export function isCameraCaptureNeed(words: string): boolean {
  if (!isCameraNeed(words)) { return false }
  if (/\b(scan|scanner|scanning|qr|barcode|bar\s?code|decode|recognize|recognise|identify|detect|checklist|settings)\b/i.test(words)) {
    return false
  }
  if (/without\b[^.]*\b(taking|capturing|snapping|shooting)\b/i.test(words)) { return false }
  return true
}

/**
 * A request that says the person photographs or scans something must keep a
 * camera need even when the plan leaves it out: the Exam Prep starter does, and
 * a plan without it served a practice screen with no way to photograph a page.
 * The need is written as other, so the section writer gets ui.Camera.
 * For a multi-screen plan, return a retry reason if the camera has no screen.
 */
export function ensureCameraNeed(plan: NeedsPlan, prompt: string): string {
  if (!isCameraNeed(prompt)) { return '' }
  for (let n of plan.needs) {
    if ((isCameraNeed(n.words) || isCameraNeed(n.from)) &&
        (plan.screens.length === 0 || plan.screens.some((s: NeedScreen): boolean => s.needs.indexOf(n.id) >= 0))) { return '' }
  }
  if (plan.screens.length > 0) {
    return 'Describe the requested camera need, give it an id and reference that id on the relevant screen'
  }
  let need = new Need()
  need.type = NEED_OTHER
  need.words = 'A live camera view inside the app: the person frames what they want to photograph and taps a shutter; ' +
    'the captured photo is shown and kept.'
  plan.needs.push(need)
  return ''
}

const STOP_WORDS: string[] = ['the', 'and', 'for', 'with', 'that', 'this', 'when', 'from', 'your', 'you', 'are', 'its', 'has', 'have', 'will',
  'all', 'any', 'can', 'each', 'every', 'into', 'then', 'than', 'what', 'who', 'how', 'out', 'one', 'new', 'get', 'set', 'per']

/** Spaces and punctuation, ASCII and the wide forms Chinese and Japanese write: what separates words in any script. */
const BREAKS: RegExp = /[\s!-/:-@[-`{-~ -¿ -⁯　-〿！-／：-＠［-｀｛-･]+/
/**
 * Scripts written without spaces between words (Chinese, Japanese kana, Thai, Lao, Myanmar, Khmer): there a run between two breaks is a
 * whole clause, so it is compared by its pairs of characters instead.
 */
const UNSPACED: RegExp = /[㐀-鿿豈-﫿぀-ヿ฀-໿က-႟ក-៿]/

/** Lower case, the wide forms as the narrow ones, every run of breaks one space. */
function plain(sentence: string): string {
  return sentence.normalize('NFKC').toLowerCase().split(BREAKS).filter((w: string): boolean => w.length > 0).join(' ')
}

/**
 * The words of a sentence that carry its meaning: lower case, three letters or more, not one of the small ones; in a script written
 * without spaces, each pair of characters (a single character when that is all there is).
 */
function meaningWords(sentence: string): string[] {
  let found: string[] = []
  let add = (w: string): void => { if (found.indexOf(w) < 0) { found.push(w) } }
  for (let w of plain(sentence).split(' ')) {
    if (w.length === 0) { continue }
    if (UNSPACED.test(w)) {
      if (w.length === 1) { add(w) }
      for (let i = 0; i + 1 < w.length; i++) { add(w.substring(i, i + 2)) }
    } else if (w.length >= 3 && STOP_WORDS.indexOf(w) < 0) {
      add(w)
    }
  }
  return found
}

/**
 * Whether the words a need quotes from the request are in it: the quote as it stands, in any language, or at least half of its meaning
 * words are the request's own (a plural or a longer form of one counts). A quote that is not from the request is a need the model made
 * up; one with nothing to compare (no meaning words) cannot be judged, and stays.
 */
export function asksFor(request: string, quote: string): boolean {
  let q = plain(quote)
  if (q.length === 0) { return false }
  if (plain(request).indexOf(q) >= 0) { return true }
  let words = meaningWords(quote)
  if (words.length === 0) { return true }
  let have = meaningWords(request)
  let same = (a: string, b: string): boolean => a === b || (a.length >= 4 && b.length >= 4 && (a.startsWith(b) || b.startsWith(a)))
  let found = words.filter((w: string): boolean => have.some((h: string): boolean => same(w, h))).length
  return found * 2 >= words.length
}

/**
 * The needs the request does not ask for, taken out of the plan: a content or action need whose quote is not the request's (one with no
 * quote stays). The
 * inputs and figures such an action needed are left with nothing that reads them, and the composer leaves them out.
 * Returns the words of each need dropped.
 */
export function dropUnasked(plan: NeedsPlan, request: string): string[] {
  let dropped: string[] = []
  let kept: Need[] = []
  for (let n of plan.needs) {
    // A need with no quote at all cannot be judged and stays: the check is for what the model made up and signed with words not the request's.
    if ((n.type === NEED_CONTENT || n.type === NEED_ACTION) && n.from.length > 0 && !asksFor(request, n.from)) {
      dropped.push(n.words.length > 60 ? n.words.substring(0, 60) + '...' : n.words)
    } else {
      kept.push(n)
    }
  }
  plan.needs = kept
  // Do not hand a writer references to a need the request never asked for.
  let ids = kept.map((n: Need): string => n.id)
  for (let n of kept) { n.uses = n.uses.filter((id: string): boolean => ids.indexOf(id) >= 0) }
  for (let s of plan.screens) { s.needs = s.needs.filter((id: string): boolean => ids.indexOf(id) >= 0) }
  for (let t of plan.transitions) {
    if (t.record.length > 0 && ids.indexOf(t.record.substring(0, t.record.length - 3)) < 0) { t.record = '' }
  }
  return dropped
}

/** Every scene of the plan made a need of type other, with the same words; returns how many there were. */
export function plainScenes(plan: NeedsPlan): number {
  let n = 0
  for (let need of plan.needs) {
    if (need.type === NEED_SCENE) { need.type = NEED_OTHER; n++ }
  }
  return n
}

/** How many things a widget in a chat reply has room for: it is about 360 by 420 vp and does not scroll. */
export const WIDGET_ROOM: number = 5

/** Added to the request the plan is drawn from, for a widget; the cap below holds when the model does not keep to it. */
export const WIDGET_NEEDS_NOTE: string =
  '\n\nThis app is a small widget inside a chat reply, about 360 by 420 points with no scrolling: plan only the ' +
  WIDGET_ROOM.toString() + ' things the request names first or most plainly, and leave the rest out. ' +
  'Keep requested navigation: declare the same screens/startScreen/transitions as a full app. Use tabs for peer views, pages for record detail/editor flows. ' +
  'Do not cut a declared multi-view flow into independent blocks; keep each active view compact.'

/**
 * A widget's plan cut to what fits in it: the first `room` needs the person sees, in the plan's order. A figure that only feeds
 * another (`shown: false`) takes no room. What read a need that was cut goes with it: a figure of the entries or the clock, an
 * action at the end of the countdown or on an entry. Returns the words of each need cut.
 */
export function capForWidget(plan: NeedsPlan, room: number): string[] {
  let cut: Need[] = []
  let kept: Need[] = []
  let seen = 0
  for (let n of plan.needs) {
    if (n.type === NEED_FIGURE && n.raw['shown'] === false) { kept.push(n); continue }
    if (seen < room) { seen++; kept.push(n) } else { cut.push(n) }
  }
  let has = (type: string): boolean => kept.some((n: Need): boolean => n.type === type)
  let supplied = (reads: string): boolean => reads.startsWith('entries.') ? has(NEED_ENTRIES) : has(NEED_COUNTDOWN) || has(NEED_STOPWATCH)
  // A figure's formula names the figures and the live figures before it by id: one that names one cut is cut with it.
  let readsCut = (n: Need): boolean => {
    let formula = text(n.raw, 'formula')
    return formula.length > 0 && cut.some((c: Need): boolean => {
      let id = c.type === NEED_FIGURE || c.type === NEED_LIVE ? text(c.raw, 'id') : ''
      return id.length > 0 && new RegExp('(^|[^A-Za-z0-9_.])' + id + '(?![A-Za-z0-9_])').test(formula)
    })
  }
  let orphan = (n: Need): boolean => {
    if (n.type === NEED_FIGURE) { return n.reads.some((q: string): boolean => !supplied(q)) || readsCut(n) }
    if (n.type === NEED_ACTION) {
      return (n.on === ON_END && !has(NEED_COUNTDOWN)) || ((n.on === ON_ADDED || n.on === ON_TAP) && !has(NEED_ENTRIES))
    }
    return false
  }
  // A figure cut may have been what another figure read, so the check runs until nothing more goes.
  for (let again = true; again;) {
    again = false
    let next: Need[] = []
    for (let n of kept) { if (orphan(n)) { cut.push(n); again = true } else { next.push(n) } }
    kept = next
  }
  plan.needs = kept
  return cut.map((n: Need): string => n.words.length > 60 ? n.words.substring(0, 60) + '...' : n.words)
}
