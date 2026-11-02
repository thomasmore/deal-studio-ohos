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
import { Sketch, SketchInput, SketchOption, SketchAsk, JevAsk, PlanReview, ComposeResult, composeFromSketch, closePartialJson, sketchSignature, describeSketch,
  listNeeds, clockOptions, listOptions, choice, askReady, LIST_SECTIONS, PART } from './VeraCompose'
import { NeedsPlan, Need, NEEDS_PROMPT, plainScenes, WIDGET_ROOM, WIDGET_NEEDS_NOTE, capForWidget, dropUnasked, NEED_COUNTDOWN, NEED_ACTION, NEED_FIGURE, ON_END, ON_ADDED, ON_TAP, parseNeedsPlan, sketchFrom,
  needOf } from './NeedsPlan'

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
  return LIST_SECTIONS.filter((kind: string): boolean => !read || kind === 'record_log')
}

export class ChooseRequest {
  /** Jev's request body; '' when no need is left a choice. */
  body: string = ''
  /** Questions the second call does not ask: the ones this call asked, and the ones the plan's facts have answered. */
  settled: string[] = []
}

/** The one question per need that a part and a section both do, with only the options the plan's facts leave. */
export function buildChooseRequest(prompt: string, plan: NeedsPlan, sketch: Sketch): ChooseRequest {
  let out = new ChooseRequest()
  let questions: Record<string, Object> = {}
  if (sketch.hasCountdown) {
    out.settled.push('clock.part')
    let options = clockOptions(sketch)
    if (options !== null && timerMayTakeCountdown(plan)) {
      questions['clock.part'] = choice('The app needs the countdown "' + sketch.countdown + '". Which of these does exactly that?', options!)
    }
  }
  if (sketch.list !== null) {
    out.settled.push('list.part')
    let options = listOptions(sketch)
    if (options !== null) {
      let allowed = listSectionsFor(plan)
      let narrowed: Map<string, string> = new Map<string, string>()
      options!.forEach((describe: string, key: string) => { if (key === PART || allowed.indexOf(key) >= 0) { narrowed.set(key, describe) } })
      if (narrowed.size > 1) {
        questions['list.part'] = choice('The person keeps ' + sketch.list!.label + '.' + listNeeds(sketch) + ' Which of these does exactly that?', narrowed)
      }
    }
  }
  if (sketch.ready.length > 0) {
    askReady(sketch, questions)
    out.settled.push('real_data')
    for (let i = 0; i < sketch.ready.length; i++) { out.settled.push('ready.' + i.toString(), 'whose.' + i.toString()) }
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

class DrawnPlan {
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
    let sketch = sketchFrom(plan!)
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
    let plan = reply !== null ? parseNeedsPlan(reply!) : null
    let sketch = plan !== null ? sketchFrom(plan!) : null
    if (plan !== null && sketch !== null) {
      out.text = reply!
      out.plan = plan
      out.sketch = sketch
      return out
    }
    let wrong = reply === null ? 'there was no answer' : 'it was not one JSON object in the form asked for: ' + reply!.substring(0, 200)
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
  if (drawn.plan === null) { result.note = 'no usable plan after ' + drawn.tries.toString() + ' tries'; return result }
  let plan: NeedsPlan = drawn.plan!
  let sketch: Sketch = drawn.sketch!
  let text = drawn.text
  throwIfCancelled(cancellation)
  let settled = review !== null && sketch.questions.length > 0 ? await review(sketch) : ''
  throwIfCancelled(cancellation)
  if (settled.length > 0) {
    prompt = prompt + '\n\n' + settled
    let again = Date.now()
    let redrawn = await drawPlan(askPlan, prompt, onSketch, note, cancellation)
    throwIfCancelled(cancellation)
    result.sketchMs += Date.now() - again
    result.replanned = true
    result.planTries += redrawn.tries
    if (redrawn.plan === null) { result.note = 'no usable plan drawn again after ' + redrawn.tries.toString() + ' tries'; return result }
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
    let redone = sketchFrom(plan)
    if (redone !== null) { redone!.questions = sketch.questions; sketch = redone! }
  }
  // What the model added that the request does not ask for (a note, a reminder nobody named) is not built.
  let unasked = dropUnasked(plan, prompt)
  // A widget has room for a few things: the plan was asked to keep to them, and what it did not is cut here.
  let cut: string[] = widget ? capForWidget(plan, WIDGET_ROOM) : []
  if (unasked.length > 0 || cut.length > 0) {
    let redone = sketchFrom(plan)
    if (redone !== null) { redone!.questions = sketch.questions; sketch = redone! }
  }
  let startedOn = startOnRequested(sketch, prompt)
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
