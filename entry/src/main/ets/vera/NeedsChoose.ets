/**
 * The plan of a new screen, drawn without knowing the parts or the catalogue (NeedsPlan.ets), and the choice of what does each
 * need: a section of the catalogue, or the composer's own part. One Jev call puts the two side by side for every need that both can
 * do (a countdown, entries the person keeps, content written for the request); what a section cannot stand in for is taken
 * out of the options before they are asked, from the plan's own facts, so nothing a choice gives is taken back afterwards.
 *
 * The answers go to the composer under the keys it reads (clock.part, list.part, ready.N, whose.N, real_data), and the
 * second call, for what only the parts can settle (widgets, formulas, effects, moments), does not ask them again. A choice
 * Jev does not give leaves the part.
 */

import { OperationCancellation, isCancelled, throwIfCancelled } from './OperationCancellation'
import { Sketch, SketchInput, ListField, SketchOption, SketchAsk, JevAsk, PlanReview, ComposeResult, composeFromSketch, closePartialJson, sketchSignature, describeSketch,
  listNeeds, clockOptions, listOptions, choice, askReady, askLive, SketchQuestion, answerTo, keepAnswers, LIST_SECTIONS, LIST_PUBLISHERS, PART } from './VeraCompose'
import { NeedsPlan, Need, NEEDS_PROMPT, plainScenes, WIDGET_ROOM, WIDGET_NEEDS_NOTE, capForWidget, dropUnasked, NEED_COUNTDOWN, NEED_ACTION, NEED_FIGURE, ON_END, ON_ADDED, ON_TAP, parseNeedsPlan, sketchFrom, planningSketch,
  ensureCameraNeed, needOf, navigationPlanProblem } from './NeedsPlan'

/** Whether the list keeps a reading in a unit the request gives a number in: a temperature, a pressure, a weight. */
export function readsMeasure(sketch: Sketch, prompt: string): boolean {
  if (sketch.list === null) { return false }
  let units = requestedMeasures(prompt).map((p: [number, string]): string => p[1]).filter((u: string): boolean => u !== 'ml' && u !== 'km')
  return units.length > 0 && sketch.list!.fields.some((f: ListField): boolean => f.kind === 'number' &&
    units.indexOf(unitKey(f.unit.length > 0 ? f.unit : f.label)) >= 0)
}

/** Whether the request asks for points or stars earned for tasks and spent on rewards. */
export function asksPoints(prompt: string): boolean {
  // Spending on its own is not it ("API tokens I spend"): spent on something, or a reward.
  return /\b(stars?|points?|tokens?)\b/i.test(prompt) && /\b(rewards?|redeem\w*|prizes?)\b|\bspen(d|t|ds|ding)\b( \w+){0,2} on\b/i.test(prompt)
}

/** Whether the request asks for something logged with one tap rather than typed in. */
export function asksOneTap(prompt: string): boolean {
  return /\b(one|single|a|1)[ -]tap\b|\bwith a tap\b|\btap to (log|add|count)\b|一键|点一下/i.test(prompt)
}

/** Whether the request asks for work and rest in turns: blocks with breaks between them, rounds, intervals, a pomodoro. */
export function asksForRounds(prompt: string): boolean {
  // Each word with what makes it a turn of work and rest: "the rest of the day", "sets of reminders" and "blocks of text" are not.
  return /\b(pomodoro|rounds?|intervals?|reps|work and rest|rest (between|periods?|intervals?)|breaks? (in )?between|with (\w+ )?breaks|\d+ ?(s|sec|seconds?|min|minutes?) (of )?(rest|breaks?)|(\d+|\w+) sets\b|sets? of \d+|cycles? of (work|focus|\d+))\b/i.test(prompt) ||
    /番茄|休息|\d+\s*轮|几轮|每轮|轮次/.test(prompt)
}

/**
 * Whether the `timer` section may take the countdown's place: its length is one fixed time of the plan's (a person who sets it
 * needs the part, which follows the input), nothing happens when it ends, and no figure reads the time left or passed.
 */
export function timerMayTakeCountdown(plan: NeedsPlan): boolean {
  let countdown = needOf(plan, NEED_COUNTDOWN)
  if (countdown === null) { return false }
  let fixed = false
  let constants = plan.base['constants']
  if (Array.isArray(constants)) {
    for (let k of constants as Object[]) {
      let r = k as Record<string, Object>
      if (r['id'] === countdown!.length) { fixed = true }
    }
  }
  if (!fixed) { return false }
  for (let n of plan.needs) {
    if (n.type === NEED_ACTION && n.on === ON_END) { return false }
    if (n.type === NEED_FIGURE && n.reads.some((q: string): boolean => q.startsWith('clock.'))) { return false }
  }
  return true
}

/**
 * The sections that keep what the person enters which may take the list part's place: none when something happens as an entry
 * is added or tapped; and when a figure reads the entries, only `record_log`, which publishes totals, averages and counts for
 * the readers of the catalogue to show.
 */
export function listSectionsFor(plan: NeedsPlan): string[] {
  for (let n of plan.needs) {
    if (n.type === NEED_ACTION && (n.on === ON_ADDED || n.on === ON_TAP)) { return [] }
  }
  let read = plan.needs.some((n: Need): boolean => n.type === NEED_FIGURE && n.reads.some((q: string): boolean => q.startsWith('entries.')))
  return LIST_SECTIONS.filter((kind: string): boolean => !read || LIST_PUBLISHERS.indexOf(kind) >= 0)
}

export class ChooseRequest {
  /** Jev's request body; '' when no need is left a choice. */
  body: string = ''
  /** Questions the second call does not ask: the ones this call asked, and the ones the plan's facts have answered. */
  settled: string[] = []
  /** Answers the request's own words settle without Jev, under the keys Jev's would be: "with one tap" is the one-tap log. */
  forced: Record<string, Object> = {}
}

/** The answer the request's own words give, under the key Jev's would be, as sure as can be. */
function forcedChoice(kind: string): Record<string, Object> {
  let says: Record<string, Object> = {}
  says['type'] = 'choice'
  says['choice'] = kind
  says['confidence'] = 1
  return says
}

/** The one question per need that a part and a section both do, with only the options the plan's facts leave. */
export function buildChooseRequest(prompt: string, plan: NeedsPlan, sketch: Sketch): ChooseRequest {
  let out = new ChooseRequest()
  let questions: Record<string, Object> = {}
  if (sketch.hasCountdown) {
    out.settled.push('clock.part')
    let options = clockOptions(sketch)
    // The interval timer is offered for work and rest in rounds, whoever sets the lengths; the plain timer only for one set length.
    if (options !== null && !asksForRounds(prompt)) { options!.delete('interval_timer') }
    if (options !== null && !timerMayTakeCountdown(plan)) { options!.delete('timer') }
    if (options !== null && options!.has('interval_timer')) {
      // Work and rest in turns is the interval timer, without asking: asked, Jev kept the plain countdown, and the screen said a break
      // could not be timed on this phone (Homework timer).
      out.forced['clock.part'] = forcedChoice('interval_timer')
    } else if (options !== null && options!.size > 1) {
      questions['clock.part'] = choice('The app needs the countdown "' + sketch.countdown + '". Which of these does exactly that?', options!)
    }
  }
  if (sketch.list !== null) {
    out.settled.push('list.part')
    let options = listOptions(sketch)
    if (options !== null) {
      let allowed = listSectionsFor(plan)
      let narrowed: Map<string, string> = new Map<string, string>()
      // "Logs a glass with one tap" is the one-tap log or the plain list, nothing else: asked among all of them, Jev took the
      // list's typed form two times of three (Water reminder on the phone).
      // Asked between the two, Jev still took the typed form, so the request's own words decide.
      let oneTap = asksOneTap(prompt) && allowed.indexOf('quick_log') >= 0
      // Points or stars earned and spent on rewards: the ledger, whatever is wired to a tap (it awards and redeems on taps itself).
      // A reading the request gives in a unit the list keeps ("a fever of 37.5°C", a Temperature field): readings with a status.
      // Only where the plan's facts let a section take the list, as the one-tap log: "text me when a star is added" keeps the part.
      let ledger = asksPoints(prompt) && allowed.indexOf('points_ledger') >= 0
      let reading = !asksPoints(prompt) && readsMeasure(sketch, prompt) && allowed.indexOf('reading_status') >= 0
      options!.forEach((describe: string, key: string) => { if (key === PART || allowed.indexOf(key) >= 0) { narrowed.set(key, describe) } })
      if (ledger || reading) {
        out.forced['list.part'] = forcedChoice(reading ? 'reading_status' : 'points_ledger')
        narrowed = new Map<string, string>([[reading ? 'reading_status' : 'points_ledger', 'the request says so']])
      } else if (oneTap) {
        out.forced['list.part'] = forcedChoice('quick_log')
        narrowed = new Map<string, string>([['quick_log', 'the request says one tap']])
      } else if (narrowed.size > 1) {
        questions['list.part'] = choice('The person keeps ' + sketch.list!.label + '.' + listNeeds(sketch) + ' Which of these does exactly that?', narrowed)
      }
      // Which sections were offered for the list and why the others were not: the plan's actions on an entry keep the part.
      console.info('VERA-CHOOSE list "' + sketch.list!.label + '" offered=' + Array.from(narrowed.keys()).join(',') +
        ' actions=' + plan.needs.filter((n: Need): boolean => n.type === NEED_ACTION).map((n: Need): string => n.on).join(','))
    }
  }
  if (sketch.ready.length > 0) {
    askReady(sketch, questions)
    out.settled.push('real_data')
    for (let i = 0; i < sketch.ready.length; i++) { out.settled.push('ready.' + i.toString(), 'whose.' + i.toString()) }
  }
  if (sketch.live.length > 0) {
    askLive(sketch, questions)
    for (let i = 0; i < sketch.live.length; i++) { out.settled.push('live.' + i.toString()) }
  }
  if (Object.keys(questions).length === 0) { return out }
  let body: Record<string, Object> = {}
  body['model'] = 'jev-latest'
  body['state'] = 'Request: ' + prompt + '\nThe app has:\n' + describeSketch(sketch)
  body['questions'] = questions
  out.body = JSON.stringify(body)
  return out
}

/** Jev's answers to the choices, as they came: the composer reads them under these keys. Null when there are none. */
export function readChoices(body: string): Record<string, Object> | null {
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let found = parsed['answers']
    if (found !== null && found !== undefined && typeof found === 'object') { return found as Record<string, Object> }
  } catch (_e) {
    return null
  }
  return null
}

/** Every length of time the request names, in seconds, each once: "10 minute", "2 hours", "90 s". */
export function requestedSeconds(prompt: string): number[] {
  let found: number[] = []
  let pattern = /(\d+(?:\.\d+)?)[ -]?(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b/gi
  let m = pattern.exec(prompt)
  while (m !== null) {
    let unit = m[2].toLowerCase()
    let each = unit.startsWith('h') ? 3600 : (unit.startsWith('m') ? 60 : 1)
    let seconds = Math.round(parseFloat(m[1]) * each)
    if (seconds > 0 && found.indexOf(seconds) < 0) { found.push(seconds) }
    m = pattern.exec(prompt)
  }
  return found
}

/**
 * A request that names one length of time ("a 10 minute timer") starts the one input that holds a length on it, when the plan
 * has the length among its options (or within its range) and starts elsewhere. Returns what was changed, in words; '' when nothing.
 */
export function startOnRequested(sketch: Sketch, prompt: string): string {
  let wanted = requestedSeconds(prompt)
  if (wanted.length !== 1) { return '' }
  let lengths = sketch.inputs.filter((i: SketchInput): boolean => i.measure === 'seconds' || i.measure === 'minutes')
  if (lengths.length !== 1) { return '' }
  let input = lengths[0]
  let unit = input.measure === 'minutes' ? 60 : 1
  if (input.kind === 'choice') {
    let at = input.options.findIndex((o: SketchOption): boolean => Math.round(o.value * unit) === wanted[0])
    if (at < 0 || input.value === at) { return '' }
    input.value = at
    return input.label + ' starts on ' + input.options[at].label
  }
  let value = wanted[0] / unit
  if (input.kind !== 'amount' && input.kind !== 'count') { return '' }
  if (input.value === value || value < input.min || value > input.max) { return '' }
  input.value = value
  return input.label + ' starts at ' + value.toString()
}

/** The unit a number in the request or a field's unit or label is in, as one key; '' when none is recognised. */
export function unitKey(text: string): string {
  let t = text.toLowerCase()
  // Fahrenheit first: "degrees fahrenheit" and "Temperature (°F)" say degrees and temperature too.
  if (/°\s*f\b|℉|fahrenheit/.test(t)) { return 'fahrenheit' }
  if (/°\s*c\b|℃|celsius|\bdegrees?\b|temperature|\btemp\b/.test(t)) { return 'celsius' }
  if (/\bml\b|millilit/.test(t)) { return 'ml' }
  if (/\bkg\b|kilo(gram)?s?\b/.test(t)) { return 'kg' }
  if (/\bkm\b|kilomet/.test(t)) { return 'km' }
  if (/\bbpm\b|heart rate|pulse/.test(t)) { return 'bpm' }
  if (/mmhg|blood pressure/.test(t)) { return 'mmhg' }
  if (/mmol|blood sugar|glucose/.test(t)) { return 'mmol' }
  return ''
}

/** Every number the request names with a unit, as [value, unit key] pairs, each pair once. */
export function requestedMeasures(prompt: string): [number, string][] {
  let found: [number, string][] = []
  let pattern = /(\d+(?:[.,]\d+)?)\s*(°\s*[cf]\b|℃|degrees?(?:\s+(?:celsius|fahrenheit))?|ml\b|millilit\w*|kg\b|km\b|bpm\b|mmhg\b|mmol\S*)/gi
  let m = pattern.exec(prompt)
  while (m !== null) {
    let value = parseFloat(m[1].replace(',', '.'))
    let unit = unitKey(m[2])
    if (unit.length > 0 && !found.some((p: [number, string]): boolean => p[0] === value && p[1] === unit)) { found.push([value, unit]) }
    m = pattern.exec(prompt)
  }
  return found
}

/**
 * A request that states a reading the person has now ("my baby has a fever of 37.5°C") starts the list of readings with it,
 * when the list has exactly one number field in that unit and the request names exactly one number in it. Without it the
 * screen said "No reading yet" under a request that gave the reading. Returns what was done, in words; '' when nothing.
 */
export function seedFromRequest(sketch: Sketch, prompt: string): string {
  if (sketch.list === null) { return '' }
  // Not the size of a tap or a goal ("log 250 ml with one tap", "get down to 70 kg"): what was not measured is no reading. Millilitres
  // and kilometres are sizes and goals far more often than readings, as readsMeasure has them.
  let measures = requestedMeasures(prompt).filter((p: [number, string]): boolean => p[1] !== 'ml' && p[1] !== 'km' &&
    !aimedAt(prompt, p[0]))
  if (measures.length === 0) { return '' }
  let done: string[] = []
  for (let unit of measures.map((p: [number, string]): string => p[1]).filter((u: string, i: number, a: string[]): boolean => a.indexOf(u) === i)) {
    let values = measures.filter((p: [number, string]): boolean => p[1] === unit)
    if (values.length !== 1) { continue }
    let fields = sketch.list!.fields.filter((f: ListField): boolean => f.kind === 'number' &&
      (unitKey(f.unit) === unit || (f.unit.length === 0 && unitKey(f.label) === unit)))
    if (fields.length !== 1) { continue }
    fields[0].seed = values[0][0]
    done.push(fields[0].label + ' starts with ' + values[0][0].toString())
  }
  return done.join('; ')
}

/** Whether the request names `value` as a goal, a limit or the size of a tap rather than as a reading it has now. */
function aimedAt(prompt: string, value: number): boolean {
  let digits = /(\d+(?:[.,]\d+)?)/g
  let m = digits.exec(prompt)
  while (m !== null) {
    if (parseFloat(m[1].replace(',', '.')) === value) {
      let before = prompt.substring(Math.max(0, m.index - 30), m.index)
      let after = prompt.substring(m.index, Math.min(prompt.length, m.index + m[0].length + 30))
      if (/\b(goal|target|aim|reach|get (down |up )?to|lose|gain|under|below|above|over|at least|at most|up to|limit|per|each|every|log|add)\b\W*(\w+\W+)?$/i.test(before) ||
        /^[\d.,]+\s*[^\s\d]+\s+(a |per |each |with one |with a )?(goal|target|day|tap)\b/i.test(after)) { return true }
    }
    m = digits.exec(prompt)
  }
  return false
}

/** Labels of inputs that are settings by their words: a goal, a limit, a size, a gap, quiet or sleep hours, a warning level. */
const SETTING_WORDS: RegExp = /\b(threshold|goal|target|limit|size|gap|between|buffer|margin|warn|alert|soon|asleep|sleep|awake|wake|quiet|reminder interval|every)\b/i

/**
 * Marks the inputs that are settings: those the plan says are, or whose label says so, unless the request states their value (then
 * they are what the request is about: "12 hours before my flight"). Returns the labels marked, for the note.
 */
export function markSettings(sketch: Sketch, prompt: string): string[] {
  let marked: string[] = []
  let numbers = (prompt.match(/\d+(?:[.,:]\d+)?/g) ?? []).map((n: string): number => parseFloat(n.replace(',', '.').replace(':', '.')))
  for (let input of sketch.inputs) {
    let byWords = SETTING_WORDS.test(input.label) && input.kind !== 'text' && input.kind !== 'choice'
    if (!input.setting && !byWords) { continue }
    // As the request says it: a time of day as 7:30 (450 minutes), a length in hours or minutes (2 hours as 120 minutes).
    let said = (n: number): boolean => n === input.value || n * 60 === input.value || n === input.value * 60 ||
      (input.kind === 'time' && Math.floor(n) * 60 + Math.round((n - Math.floor(n)) * 100) === input.value)
    let stated = numbers.some(said) && input.value !== 0
    input.setting = !stated
    if (input.setting) { marked.push(input.label) }
  }
  return marked
}

class DrawnPlan {
  appAttempted: boolean = false
  text: string = ''
  plan: NeedsPlan | null = null
  sketch: Sketch | null = null
  tries: number = 0
}

/** One plan, streamed: each new shape of it goes to onSketch as it arrives. */
async function drawOnce(askPlan: SketchAsk, prompt: string, onSketch: (partial: Sketch) => void, think: boolean,
    cancellation?: OperationCancellation): Promise<string | null> {
  throwIfCancelled(cancellation)
  let shown = ''
  let show = (reply: string): void => {
    if (isCancelled(cancellation)) { return }
    let plan = parseNeedsPlan(reply)
    if (plan === null) { return }
    ensureCameraNeed(plan!, prompt)
    let sketch = planningSketch(plan!)
    if (sketch === null) { return }
    let signature = sketchSignature(sketch!)
    if (signature === shown) { return }
    shown = signature
    onSketch(sketch!)
  }
  let reply = await askPlan(NEEDS_PROMPT, prompt, (soFar: string): void => {
    let closed = closePartialJson(soFar)
    if (closed.length > 0) { show(closed) }
  }, think)
  throwIfCancelled(cancellation)
  if (reply !== null) { show(reply!) }
  return reply
}

/** A plan that can be used, asked for until there is one: the first, then once more with what was wrong with it quoted, then once thinking. */
async function drawPlan(askPlan: SketchAsk, prompt: string, onSketch: (partial: Sketch) => void, note: string = '',
    cancellation?: OperationCancellation): Promise<DrawnPlan> {
  throwIfCancelled(cancellation)
  let out = new DrawnPlan()
  let user = prompt + note
  for (let attempt = 0; attempt < 3; attempt++) {
    out.tries = attempt + 1
    throwIfCancelled(cancellation)
    let reply = await drawOnce(askPlan, user, onSketch, attempt === 2, cancellation)
    throwIfCancelled(cancellation)
    if (reply !== null) {
      try {
        let body = reply!.substring(reply!.indexOf('{'), reply!.lastIndexOf('}') + 1)
        let raw = JSON.parse(body) as Record<string, Object>
        let screens = raw['screens']
        if (screens !== undefined && (!Array.isArray(screens) || screens.length > 1)) { out.appAttempted = true }
      } catch (_e) {}
    }
    let problems: string[] = []
    let plan = reply !== null ? parseNeedsPlan(reply!, problems) : null
    let cameraProblem = plan !== null ? ensureCameraNeed(plan!, prompt) : ''
    let sketch = plan !== null ? planningSketch(plan!) : null
    let navigation = plan !== null ? navigationPlanProblem(plan!) : ''
    // Prose is only a heuristic. It may request a better plan, but cannot disable the ordinary fallback on its own.
    if (plan !== null && sketch !== null && navigation.length === 0 && cameraProblem.length === 0) {
      out.text = reply!
      out.plan = plan
      out.sketch = sketch
      return out
    }
    if (cameraProblem.length > 0) { problems.push(cameraProblem) }
    let wrong = navigation.length > 0 ? navigation : (problems.length > 0 ? problems.join('; ') :
      (reply === null ? 'there was no answer' : 'it was not one JSON object in the form asked for: ' + reply!.substring(0, 200)))
    user = prompt + note + '\n\nThe last answer could not be used: ' + wrong + '. Answer with the JSON object only, in the form asked for.'
  }
  return out
}

/**
 * Added to the request the plan is drawn from when the route was told part of the screen is a scene (AgentSurface.ets): the
 * plan model on its own makes a spinning wheel a figure and a button.
 */
export function sceneNote(scene: string): string {
  return '\n\nPart of this screen is a scene, one need of type scene: ' + scene
}

/**
 * The whole of composing a new screen, from the plan of needs: the plan, the person's answers to what it asks, Jev's choice of
 * a section or a part for each need, then the composer's own choices (widgets, formulas, effects, moments) over what is left.
 */
export async function composeNeeds(prompt: string, askPlan: SketchAsk, askChoices: JevAsk,
    onSketch: (partial: Sketch) => void = (_s: Sketch): void => {}, widget: boolean = false,
    review: PlanReview | null = null, scene: string = '', sceneAllowed: boolean = true,
    cancellation?: OperationCancellation): Promise<ComposeResult> {
  throwIfCancelled(cancellation)
  let result = new ComposeResult()
  let started = Date.now()
  // What the plan is told besides the request: a widget's room, and the scene the route was told part of the screen is.
  let note = (widget ? WIDGET_NEEDS_NOTE : '') + (scene.length > 0 ? sceneNote(scene) : '')
  let drawn = await drawPlan(askPlan, prompt, onSketch, note, cancellation)
  throwIfCancelled(cancellation)
  result.sketchMs = Date.now() - started
  result.planTries = drawn.tries
  if (drawn.plan === null) {
    result.appPlanFailed = drawn.appAttempted
    result.note = 'no usable plan after ' + drawn.tries.toString() + ' tries'
    return result
  }
  let plan: NeedsPlan = drawn.plan!
  let sketch: Sketch = drawn.sketch!
  let text = drawn.text
  throwIfCancelled(cancellation)
  let settled = review !== null && sketch.questions.length > 0 ? await review(sketch) : ''
  throwIfCancelled(cancellation)
  // What each question stands at, the person's answer or its default, before a plan drawn again drops the questions.
  let answered: string[] = sketch.questions.map((q: SketchQuestion): string => answerTo(q)).filter((a: string): boolean => a.length > 0)
  let clarified: string[] = sketch.questions.filter((q: SketchQuestion): boolean => answerTo(q).length > 0)
    .map((q: SketchQuestion): string => q.ask + ' ' + answerTo(q))
  if (settled.length > 0) {
    prompt = prompt + '\n\n' + settled
    let again = Date.now()
    let redrawn = await drawPlan(askPlan, prompt, onSketch, note, cancellation)
    throwIfCancelled(cancellation)
    result.sketchMs += Date.now() - again
    result.replanned = true
    result.planTries += redrawn.tries
    if (redrawn.plan === null) {
      result.appPlanFailed = plan.screens.length > 1 || redrawn.appAttempted
      result.note = 'no usable plan drawn again after ' + redrawn.tries.toString() + ' tries'
      return result
    }
    plan = redrawn.plan!
    sketch = redrawn.sketch!
    sketch.questions = []
    text = redrawn.text
  }
  result.sketch = text
  // The route asked whether anything here is drawn and was told no: a scene the plan made up anyway (a coin flip that
  // asked for no animation) is built as any other need.
  let unscened = sceneAllowed ? 0 : plainScenes(plan)
  if (unscened > 0) {
    let redone = planningSketch(plan)
    if (redone !== null) { redone!.questions = sketch.questions; sketch = redone! }
  }
  // What the model added that the request does not ask for (a note, a reminder nobody named) is not built.
  let unasked = dropUnasked(plan, prompt)
  // A multi-screen app is written once from the full plan, before choosing any flat parts or sections.
  if (plan.screens.length > 1) {
    plan.request = prompt + (clarified.length > 0 ? '\n\nClarification answers (chosen or default):\n' + clarified.join('\n') : '')
    plan.compact = widget
    result.appPlan = plan
    result.note = 'shared app (' + plan.presentation + (widget ? ', compact' : '') + '): ' + plan.screens.map((s): string => s.id).join(', ')
    if (unasked.length > 0) {
      result.note += '; not in the request, so not built: ' + unasked.join('; ')
      result.dropped = unasked.map((words: string): string => 'not in the request: ' + words)
    }
    return result
  }
  // A widget has room for a few things: the plan was asked to keep to them, and what it did not is cut here.
  let cut: string[] = widget ? capForWidget(plan, WIDGET_ROOM) : []
  if (unasked.length > 0 || cut.length > 0) {
    let redone = sketchFrom(plan)
    if (redone !== null) { redone!.questions = sketch.questions; sketch = redone! }
  }
  let kept = keepAnswers(sketch, answered)
  if (kept.length > 0) { console.info('VERA-COMPOSE answers kept: ' + kept) }
  let startedOn = startOnRequested(sketch, prompt)
  markSettings(sketch, prompt)
  let seeded = seedFromRequest(sketch, prompt)
  if (seeded.length > 0) { startedOn = startedOn.length > 0 ? startedOn + '; ' + seeded : seeded }
  let choose = buildChooseRequest(prompt, plan, sketch)
  let answers: Record<string, Object> | null = null
  let skipped: string[] = choose.settled
  if (choose.body.length > 0) {
    let asked = Date.now()
    throwIfCancelled(cancellation)
    let body = await askChoices(choose.body)
    throwIfCancelled(cancellation)
    if (body.length === 0) {
      throwIfCancelled(cancellation)
      body = await askChoices(choose.body)
      throwIfCancelled(cancellation)
    }
    result.jevMs = Date.now() - asked
    answers = body.length > 0 ? readChoices(body) : null
    // Without the choices the parts stay, and the composer asks what a section is for (ready.N, whose.N, real_data) itself.
    if (answers === null) { skipped = [] }
  }
  // What the request's words settled stands whether or not Jev answered the rest.
  let forcedKeys = Object.keys(choose.forced)
  if (forcedKeys.length > 0) {
    // Added to what is already settled, not in its place: the plan's facts settled clock.part and the rest whether or not Jev was asked.
    if (answers === null) { answers = {}; skipped = skipped.concat(forcedKeys.filter((k: string): boolean => skipped.indexOf(k) < 0)) }
    for (let k of forcedKeys) { answers![k] = choose.forced[k] }
  }
  throwIfCancelled(cancellation)
  let composed = await composeFromSketch(result, prompt, sketch, askChoices, widget, answers, skipped, cancellation)
  throwIfCancelled(cancellation)
  if (startedOn.length > 0) { composed.note += '; ' + startedOn + ', as the request says' }
  if (unscened > 0) { composed.note += '; no scene: the request asks for nothing drawn, so ' + unscened.toString() + ' is built as any other need' }
  if (unasked.length > 0) {
    composed.note += '; not in the request, so not built: ' + unasked.join('; ')
    for (let words of unasked) { composed.dropped.push('not in the request: ' + words) }
  }
  if (cut.length > 0) {
    composed.note += '; no room in a widget, so not built: ' + cut.join('; ')
    for (let words of cut) { composed.dropped.push('no room in a widget: ' + words) }
  }
  return composed
}
