/**
 * Composition of a screen from sections. selectSections() asks Jev, in one batched request, which FragmentSpec (VeraTemplates.ets) goes
 * in each of SECTION_COUNT ordered slots -- or 'none' for an empty slot -- then composeProgram()
 * assembles the chosen fragments into one `.vera` program for compileVeraSource.
 *
 * Why a composer instead of a plain substitute(): a fragment is not a whole program,
 * it is one piece (state fields, an init() contribution, handler function(s), one view() block)
 * that has to be merged with zero or more other fragments' pieces into a single AppState/init/
 * view. Two mechanics make that merge safe:
 *
 * - Every fragment's state field and function names contain the literal substring "IDX",
 *   replaced here with the fragment's 1-based slot number, so two instances of the same kind
 *   (e.g. two `metrics` sections) never collide.
 * - Vera has no object-spread, so every fragment's update function must return the *entire*
 *   AppState literally. A fragment's `functions` text therefore carries one `__PASSTHROUGH__`
 *   token, filled in here with `, otherField: state.otherField` for every *other* chosen
 *   fragment's state fields -- the only piece of this merge a fragment cannot write for itself,
 *   because only the composer knows the full set of fragments present in a given composition.
 *
 * Everything else a fragment's view() block computes (loop counters, row arrays, local flags)
 * needs no indexing or pass-through at all: each fragment's viewBlock is wrapped in its own bare
 * `{ ... }` statement, and VeraCompiler.ets's checkBlock gives every such block its own child
 * Scope, so sibling blocks' same-named locals never collide -- confirmed by the host compile
 * sweep (tools/..., see conversation history) before this file was written, not assumed.
 *
 * One POST, never throws, any doubt falls back
 * to a null pick so the caller falls straight through to normal generation. Vetoes are the same
 * VeraTemplates.vetoes() list, asked once per request regardless of composition, with the same
 * meaning (a capability gate on the whole request) -- `needs_multiple_counters` still exists
 * unchanged for now; its wording only needs to stop treating two counters as automatically
 * disqualifying once this lands and is verified (see the plan), not before.
 */

import { noteService, httpFailure, SERVICE_JEV } from './ServiceHealth'
import { http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { layouts, arrangeInLayout, completeRequiredSlots, swapForLayout, layoutKinds, kindsOfLayout, placeKinds, fitToSlots, LAYOUT_NONE, LAYOUT_STACK } from './VeraLayouts'
import { FragmentSpec, StateFieldSpec, SlotSpec, VetoSpec, ContentFieldSpec, fragments, vetoes, bannerSectionView } from './VeraTemplates'

const DOMAIN = 0x0000
const ENDPOINT: string = 'https://api.typesafe.ai/v1/systemone'
const MODEL: string = 'jev-latest'

/** Ordered section slots composed into one screen. Small and bounded -- see this file's header comment and the plan's "no per-node round trips" non-goal. */
const SECTION_COUNT: number = 6

/** Top-level bar for a section's fragment-kind choice: a wrong answer here skips that slot entirely. */
const SECTION_PICK_ABOVE: number = 0.5
/** A section answer below SECTION_PICK_ABOVE but at or above this is a weak candidate: reported, and may be confirmed by VeraPickVerify.ets. */
const WEAK_FROM: number = 0.25
/**
 * When no section cleared its bar, the one block (that can stand alone) whose own yes/no question "does the request ask for this
 * part" is answered above this is built. Each kind has such a question, independent of the others: a 26-way section choice
 * splits its probability between the kinds, so an obvious plain list scored 0.3 as a section pick and 0.5 to 0.6 as a yes/no.
 * Provisional: calibrated on one prompt so far (see eval/results/2026-10-19-*want*).
 */
const WANT_ABOVE: number = 0.5
/** Per-slot cosmetic bar. */
const SLOT_PICK_ABOVE: number = 0.25
/**
 * Bar for a per-part "does the request ask for this" answer once a layout is chosen. These are independent yes/no
 * questions, so unlike a section's one-of-many choice (whose confidence is spread over every kind) a part the
 * request plainly asks for scores high.
 */
const INCLUDE_ABOVE: number = 0.65
/**
 * Bar for the layout answer. A layout is not just an order: its required slots add blocks nobody asked for, so it must be
 * sure. Measured on the phone: a plain "Grocery list app" got progress_list at 0.68 (and list_summary was then forced in);
 * the prompts a layout is for got 1.00. Includes follow the same gap: wanted parts scored 0.77 and up, unwanted ones 0.46 and less.
 */
const LAYOUT_ABOVE: number = 0.8
/**
 * Bar for a section's top choice when that kind covers a veto that fired (FragmentSpec.covers): the veto and the choice
 * are two answers that agree. On the 59 intent prompts Jev put intent_panel first at 0.26-0.48 on 11 of them, most with
 * needs_integration above 0.8.
 */
const COVERING_PICK_ABOVE: number = 0.25

/**
 * Vetoes that no longer drop a request to generation from scratch: whatever they flag (a calculation,
 * a form, a search, a second counter, a phone API) is something the model can add on top of a
 * composed base, so Jev still picks the visual structure. Measured on the gold sets
 * (eval/results/2026-10-15-jev-baseline.json): with every veto hard, 23 of 49 prompts left the
 * template path, 12 of them on needs_search_or_form alone.
 */
const SOFT_VETOES: string[] = ['needs_integration', 'needs_search_or_form', 'needs_multiple_counters', 'needs_multiple_series', 'needs_live_ticking', 'needs_logic']
/**
 * Above this probability needs_integration stays a hard veto: a request that is mostly a phone API or
 * another app (camera, video call, navigation) has no fragment worth keeping as a base. The baseline's
 * camera-app, video-call, shanghai-layover and map-restaurants all sit at 0.90 or more.
 */
const INTEGRATION_HARD_ABOVE: number = 0.9
/**
 * A soft veto starts a model call instead of ending the template path, so it must be surer than the
 * old reject-and-regenerate bars (0.3 to 0.65) were: "Grocery list app" scored needs_search_or_form
 * 0.61 against a 0.6 bar and would have paid for a completion it does not need. Floor for the vetoes
 * whose old bars were low; needs_integration keeps its own bar, because a model that adds the phone
 * call is exactly what those requests need.
 */
const SOFT_MIN_ABOVE: number = 0.7
const SOFT_FLOORED: string[] = ['needs_search_or_form', 'needs_live_ticking', 'needs_multiple_counters', 'needs_multiple_series']

const GLOBAL_THEME_VALUES: string[] = ['clean', 'soft', 'expressive', 'editorial', 'technical', 'playful']

function globalThemeCriteria(): Map<string, string> {
  let m: Map<string, string> = new Map<string, string>()
  m.set('clean', 'restrained and neutral')
  m.set('soft', 'calm and friendly')
  m.set('expressive', 'bold and atmospheric')
  m.set('editorial', 'text-forward, magazine-like')
  m.set('technical', 'dense, precise numbers')
  m.set('playful', 'energetic')
  return m
}

function globalHeaderStyleCriteria(): Map<string, string> {
  let m: Map<string, string> = new Map<string, string>()
  m.set('default', 'left-aligned')
  m.set('center', 'centered')
  return m
}

/** One section slot's outcome: a chosen kind (with its slot values, tokens still containing "IDX") or 'none'. */
export class SectionPick {
  kind: string
  /** token (containing "IDX") -> chosen value; empty when kind is 'none'. */
  slotValues: Map<string, string>
  constructor(kind: string, slotValues: Map<string, string>) {
    this.kind = kind
    this.slotValues = slotValues
  }
}

/** Every outcome of selectSections. */
export class SectionPickOutcome {
  /** null when every slot is 'none', vetoed, or any doubt makes the whole composition unsafe to attempt. */
  sections: SectionPick[] | null
  /** Global (not per-slot) cosmetic choices: "__THEME__", "__HEADER_STYLE__", "__BANNER_SECTION__". */
  globalValues: Map<string, string>
  note: string
  /**
   * True only when needs_real_data alone cleared its bar (no other veto did) and fragment-picking
   * ran anyway -- the caller should ground content-fill in one web search rather than treating
   * this as a hard veto.
   */
  needsRealData: boolean
  /**
   * True when one or more soft vetoes (SOFT_VETOES) fired: the sections are still a good visual
   * base, but the request also needs behaviour no fragment has. The caller composes the base and
   * hands it to the model to finish, instead of dropping to generation from scratch.
   */
  needsLogic: boolean
  /** The soft vetoes that fired (needsLogic), by key: what the request needs that no section does. */
  softVetoes: string[] = []
  /** The layout the sections were arranged in ('stack' when Jev chose none or the placement broke a slot rule). */
  layout: string = LAYOUT_STACK
  /** When nothing was chosen and nothing vetoed: the kinds Jev named below the bar (at least WEAK_FROM), in section order. */
  weakKinds: string[] = []
  /** Jev's answer body as received, so the weak candidates can be re-read once confirmed. */
  rawBody: string = ''
  /** The block built from its own yes/no question because no section cleared its bar ('' when none), and that question's answer. */
  wanted: string = ''
  wantedP: number = 0
  constructor(sections: SectionPick[] | null, globalValues: Map<string, string>, note: string, needsRealData: boolean = false,
      needsLogic: boolean = false) {
    this.sections = sections
    this.globalValues = globalValues
    this.note = note
    this.needsRealData = needsRealData
    this.needsLogic = needsLogic
  }
}

function criteriaRecord(criteria: Map<string, string>): Record<string, Object> {
  let out: Record<string, Object> = {}
  criteria.forEach((text: string, key: string) => { out[key] = text })
  return out
}

/** "__LIST_STYLE_IDX__" -> "list_style"; the request/response key suffix for a per-slot cosmetic SlotSpec. */
function slotKey(token: string): string {
  let trimmed = token
  if (trimmed.startsWith('__')) { trimmed = trimmed.substring(2) }
  if (trimmed.endsWith('__')) { trimmed = trimmed.substring(0, trimmed.length - 2) }
  trimmed = trimmed.split('_IDX').join('')
  return trimmed.toLowerCase()
}

/**
 * One batched request: a `choice` for every section slot (which fragment kind, or none), every
 * kind's own cosmetic slots for every slot (asked regardless of outcome, the "ask everything"
 * pattern), the three global cosmetic
 * choices, and the veto questions. A second call per slot would spend the latency this approach
 * exists to save.
 */
export function buildSectionRequest(prompt: string): string {
  let specs = fragments()
  let questions: Record<string, Object> = {}

  let kindCriteria: Record<string, Object> = {}
  for (let spec of specs) { kindCriteria[spec.kind] = spec.criteria }
  kindCriteria['none'] = 'nothing is needed in this part of the screen'

  for (let i = 1; i <= SECTION_COUNT; i++) {
    let question: Record<string, Object> = {}
    question['type'] = 'choice'
    question['instructions'] = 'What belongs in section ' + i.toString() + ' of the screen (in top-to-bottom order)? ' +
      'Answer none if this section is not needed, or if what is needed is anything beyond the listed ' +
      'parts -- a part that is not listed, or calling any phone API, SDK function or other app. A form, a ' +
      'search box or figures worked out from entered records are fine when one of the listed parts is exactly that. ' +
      'A specific real-world fact, price, or figure is fine to ' +
      'show as a plain labelled number or short fact, even though its exact value is not known yet -- ' +
      'so is a simple chart of a handful of data points.'
    question['criteria'] = kindCriteria
    questions['section' + i.toString()] = question

    for (let spec of specs) {
      for (let slot of spec.slots) {
        let slotQuestion: Record<string, Object> = {}
        slotQuestion['type'] = slot.kind
        slotQuestion['instructions'] = slot.instructions
        slotQuestion['criteria'] = criteriaRecord(slot.criteria)
        questions['section' + i.toString() + '.' + spec.kind + '.' + slotKey(slot.token)] = slotQuestion
      }
    }
  }

  let includeCriteria: Map<string, string> = new Map<string, string>()
  includeCriteria.set('true', 'yes, the request asks for this part')
  includeCriteria.set('false', 'no, it does not')
  for (let kind of layoutKinds()) {
    let spec = findFragment(specs, kind)
    if (spec === null) { continue }
    let includeQuestion: Record<string, Object> = {}
    includeQuestion['type'] = 'noul'
    includeQuestion['instructions'] = 'Does the request ask for this part of the screen: ' + spec.criteria + '?'
    includeQuestion['criteria'] = criteriaRecord(includeCriteria)
    questions['include.' + kind] = includeQuestion
  }

  let asked: string[] = layoutKinds()
  for (let spec of specs) {
    if (asked.indexOf(spec.kind) >= 0) { continue }
    let wantQuestion: Record<string, Object> = {}
    wantQuestion['type'] = 'noul'
    wantQuestion['instructions'] = 'Does the request ask for this part of the screen: ' + spec.criteria + '?'
    wantQuestion['criteria'] = criteriaRecord(includeCriteria)
    questions['want.' + spec.kind] = wantQuestion
  }

  let layoutCriteria: Record<string, Object> = {}
  for (let layout of layouts()) { layoutCriteria[layout.id] = layout.criteria }
  layoutCriteria[LAYOUT_NONE] = 'no particular arrangement'
  let layoutQuestion: Record<string, Object> = {}
  layoutQuestion['type'] = 'choice'
  layoutQuestion['instructions'] = 'How are the parts of this screen related? Pick master_detail only when the person ' +
    'chooses an item in a list and its details appear in another part of the screen.'
  layoutQuestion['criteria'] = layoutCriteria
  questions['__LAYOUT__'] = layoutQuestion

  let themeQuestion: Record<string, Object> = {}
  themeQuestion['type'] = 'choice'
  themeQuestion['instructions'] = 'Which overall look fits best for the whole screen?'
  themeQuestion['criteria'] = criteriaRecord(globalThemeCriteria())
  questions['__THEME__'] = themeQuestion

  let headerQuestion: Record<string, Object> = {}
  headerQuestion['type'] = 'choice'
  headerQuestion['instructions'] = 'Should the title block be left-aligned (default) or centered?'
  headerQuestion['criteria'] = criteriaRecord(globalHeaderStyleCriteria())
  questions['__HEADER_STYLE__'] = headerQuestion

  for (let veto of vetoes()) {
    let question: Record<string, Object> = {}
    question['type'] = 'noul'
    question['instructions'] = veto.instructions
    question['criteria'] = criteriaRecord(veto.criteria)
    questions['veto.' + veto.key] = question
  }

  let body: Record<string, Object> = {}
  body['model'] = MODEL
  body['state'] = prompt
  body['questions'] = questions
  return JSON.stringify(body)
}

/**
 * The slot questions alone, for sections already chosen: what each one is to show or offer (a button for each item, a
 * calendar, a style), read against the request. Whoever chose the sections without this call (the agent's composer) gets
 * the catalogue's defaults, which leave out everything optional the request asks for.
 */
export function buildSlotRequest(prompt: string, kinds: string[]): string {
  let specs = fragments()
  let questions: Record<string, Object> = {}
  for (let i = 0; i < kinds.length; i++) {
    let spec = findFragment(specs, kinds[i])
    if (spec === null) { continue }
    for (let slot of spec.slots) {
      let slotQuestion: Record<string, Object> = {}
      slotQuestion['type'] = slot.kind
      slotQuestion['instructions'] = slot.instructions
      slotQuestion['criteria'] = criteriaRecord(slot.criteria)
      questions['section' + (i + 1).toString() + '.' + spec.kind + '.' + slotKey(slot.token)] = slotQuestion
    }
  }
  let body: Record<string, Object> = {}
  body['model'] = MODEL
  body['state'] = prompt
  body['questions'] = questions
  return JSON.stringify(body)
}

/** Each chosen section's slot values (token to value, `kinds` order) from the answer to buildSlotRequest; defaults when unreadable. */
export function readSlotValues(body: string, kinds: string[]): Map<string, string>[] {
  let specs = fragments()
  let answers: Record<string, Object> = {}
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let raw = parsed['answers']
    if (raw !== null && raw !== undefined) { answers = raw as Record<string, Object> }
  } catch (_e) {
    answers = {}
  }
  let out: Map<string, string>[] = []
  for (let i = 0; i < kinds.length; i++) {
    let values: Map<string, string> = new Map<string, string>()
    let spec = findFragment(specs, kinds[i])
    if (spec !== null) {
      for (let slot of spec.slots) { values.set(slot.token, readSlotValue(answers, i + 1, kinds[i], slot)) }
    }
    out.push(values)
  }
  return out
}

function findFragment(specs: FragmentSpec[], kind: string): FragmentSpec | null {
  for (let spec of specs) { if (spec.kind === kind) { return spec } }
  return null
}

export function readChoiceValue(answers: Record<string, Object>, key: string, allowed: string[], above: number, fallback: string): string {
  let raw = answers[key]
  if (raw === null || raw === undefined) { return fallback }
  let answer = raw as Record<string, Object>
  let choice = answer['choice']
  if (choice === null || choice === undefined || typeof choice !== 'string') { return fallback }
  let picked = choice as string
  if (allowed.indexOf(picked) < 0) { return fallback }
  let confidence = answer['confidence']
  let sure = confidence !== null && confidence !== undefined && typeof confidence === 'number' ? confidence as number : 1
  if (sure < above) { return fallback }
  return picked
}

function readNoulProbability(answers: Record<string, Object>, key: string): number {
  let raw = answers[key]
  if (raw === null || raw === undefined) { return 0 }
  let value = (raw as Record<string, Object>)['noul']
  if (value === null || value === undefined || typeof value !== 'number') { return 0 }
  return value as number
}

/** The yes/no answer to "does the request ask for this block": the include question for a layout kind, else the want question. */
function wantProbability(answers: Record<string, Object>, kind: string): number {
  let include = readNoulProbability(answers, 'include.' + kind)
  return include > 0 ? include : readNoulProbability(answers, 'want.' + kind)
}

/** A block that makes sense on its own: it takes no value from another block. */
function standsAlone(spec: FragmentSpec): boolean {
  for (let port of spec.ports) { if (port.dir === 'reads' && !port.optional) { return false } }
  return true
}

function readNoulValue(answers: Record<string, Object>, key: string, above: number): boolean {
  let raw = answers[key]
  if (raw === null || raw === undefined) { return false }
  let answer = raw as Record<string, Object>
  let value = answer['noul']
  if (value === null || value === undefined || typeof value !== 'number') { return false }
  return (value as number) > above
}

function readSlotValue(answers: Record<string, Object>, slotIndex: number, kind: string, slot: SlotSpec): string {
  let key = 'section' + slotIndex.toString() + '.' + kind + '.' + slotKey(slot.token)
  let fallback = slot.values[0]
  let raw = answers[key]
  if (raw === null || raw === undefined) { return fallback }
  let answer = raw as Record<string, Object>
  if (slot.kind === 'noul') {
    let value = answer['noul']
    if (value === null || value === undefined || typeof value !== 'number') { return fallback }
    return (value as number) > (slot.above >= 0 ? slot.above : SLOT_PICK_ABOVE) ? slot.values[1] : slot.values[0]
  }
  let choice = answer['choice']
  if (choice === null || choice === undefined || typeof choice !== 'string') { return fallback }
  let picked = choice as string
  if (slot.values.indexOf(picked) < 0) { return fallback }
  let confidence = answer['confidence']
  let sure = confidence !== null && confidence !== undefined && typeof confidence === 'number' ? confidence as number : 1
  if (sure < SLOT_PICK_ABOVE) { return fallback }
  return picked
}

/** True when the block at `at` has no ports, or one of them meets a port of the other direction, name and type on the screen. */
function hasPartner(specs: FragmentSpec[], placed: SectionPick[], at: number): boolean {
  let spec = findFragment(specs, placed[at].kind)
  if (spec === null || spec.ports.length === 0) { return true }
  for (let j = 0; j < placed.length; j++) {
    let other = j === at ? null : findFragment(specs, placed[j].kind)
    if (other === null) { continue }
    for (let port of spec.ports) {
      for (let candidate of other.ports) {
        if (candidate.dir !== port.dir && candidate.name === port.name && candidate.type === port.type) { return true }
      }
    }
  }
  return false
}

/** Missing/unreadable is treated as triggered (1), not 0. */
function readVetoProbability(answers: Record<string, Object>, veto: VetoSpec): number {
  let raw = answers['veto.' + veto.key]
  if (raw === null || raw === undefined) { return 1 }
  let answer = raw as Record<string, Object>
  let value = answer['noul']
  if (value === null || value === undefined || typeof value !== 'number') { return 1 }
  return value as number
}

/**
 * Interprets Jev's answer. Any doubt (unreadable JSON, a tripped veto) returns a null `sections`
 * list so the caller falls through to normal generation. A single slot landing on 'none' or low confidence is not
 * doubt about the *whole* request; it just leaves that slot empty, same as a single bad cosmetic
 * slot answer falling back to its default.
 */
export function readSectionPick(body: string, confirmed: string[] = []): SectionPickOutcome {
  let specs = fragments()
  let emptyGlobals: Map<string, string> = new Map<string, string>()
  let answers: Record<string, Object> = {}
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let found = parsed['answers']
    if (found === null || found === undefined) { return new SectionPickOutcome(null, emptyGlobals, 'none (no answers)') }
    answers = found as Record<string, Object>
  } catch (_e) {
    return new SectionPickOutcome(null, emptyGlobals, 'none (answer unreadable)')
  }

  let vetoNotes: string[] = []
  let logicNotes: string[] = []
  let needsRealData = false
  let realDataProbability = 0
  let fired: string[] = []
  for (let veto of vetoes()) {
    let probability = readVetoProbability(answers, veto)
    let bar = SOFT_FLOORED.indexOf(veto.key) >= 0 ? Math.max(veto.above, SOFT_MIN_ABOVE) : veto.above
    if (probability > bar) {
      fired.push(veto.key)
      let tag = veto.key + '=' + probability.toFixed(2)
      if (veto.key === 'needs_real_data') {
        needsRealData = true
        realDataProbability = probability
      } else if (SOFT_VETOES.indexOf(veto.key) >= 0 && !(veto.key === 'needs_integration' && probability >= INTEGRATION_HARD_ABOVE)) {
        logicNotes.push(tag)
      } else {
        vetoNotes.push(tag)
      }
    }
  }
  let kindIds: string[] = []
  for (let spec of specs) { kindIds.push(spec.kind) }
  let allowedKinds: string[] = kindIds.concat(['none'])

  let picks: SectionPick[] = []
  let notes: string[] = []
  /** Picks kept under SECTION_PICK_ABOVE because they cover a veto, and their index in notes. */
  let weakPicks: SectionPick[] = []
  let weakNoteAt: number[] = []
  for (let i = 1; i <= SECTION_COUNT; i++) {
    let kind = readChoiceValue(answers, 'section' + i.toString(), allowedKinds, SECTION_PICK_ABOVE, 'none')
    let coverNote = ''
    if (kind === 'none') {
      let weak = readChoiceValue(answers, 'section' + i.toString(), allowedKinds, COVERING_PICK_ABOVE, 'none')
      let weakSpec = findFragment(specs, weak)
      if (weakSpec !== null) {
        for (let key of weakSpec.covers) {
          if (fired.indexOf(key) >= 0 && coverNote.length === 0) { kind = weak; coverNote = '(covers ' + key + ')' }
        }
      }
    }
    if (kind === 'none' && confirmed.length > 0) {
      // a weak candidate somebody else has confirmed (VeraPickVerify.ets) counts as picked
      let weak = readChoiceValue(answers, 'section' + i.toString(), allowedKinds, WEAK_FROM, 'none')
      if (confirmed.indexOf(weak) >= 0) { kind = weak }
    }
    if (kind === 'none') {
      picks.push(new SectionPick('none', new Map<string, string>()))
      notes.push('section' + i.toString() + '=none')
      continue
    }
    let spec = findFragment(specs, kind)
    if (spec === null) {
      picks.push(new SectionPick('none', new Map<string, string>()))
      notes.push('section' + i.toString() + '=none(unknown)')
      continue
    }
    // Jev answers every slot independently, and for a plain list it said "checklist" twice in 10 of
    // 11 baseline prompts -- two identical lists on screen. A kind already placed above is dropped.
    let repeated = false
    for (let earlier of picks) { if (earlier.kind === kind) { repeated = true } }
    if (repeated) {
      picks.push(new SectionPick('none', new Map<string, string>()))
      notes.push('section' + i.toString() + '=none(duplicate ' + kind + ')')
      continue
    }
    let slotValues: Map<string, string> = new Map<string, string>()
    for (let slot of spec.slots) {
      slotValues.set(slot.token, readSlotValue(answers, i, kind, slot))
    }
    picks.push(new SectionPick(kind, slotValues))
    if (coverNote.length > 0) { weakPicks.push(picks[picks.length - 1]); weakNoteAt.push(notes.length) }
    notes.push('section' + i.toString() + '=' + kind + coverNote)
  }

  let anyPicked = false
  let rescuedKind = ''
  let rescuedP = 0
  for (let pick of picks) { if (pick.kind !== 'none') { anyPicked = true } }
  if (!anyPicked) {
    let bestKind = ''
    let best = WANT_ABOVE
    for (let spec of specs) {
      if (!standsAlone(spec)) { continue }
      let p = wantProbability(answers, spec.kind)
      if (p > best) { best = p; bestKind = spec.kind }
    }
    let wanted = findFragment(specs, bestKind)
    if (wanted !== null) {
      let wantedValues: Map<string, string> = new Map<string, string>()
      for (let slot of wanted.slots) { wantedValues.set(slot.token, readSlotValue(answers, 1, wanted.kind, slot)) }
      picks[0] = new SectionPick(wanted.kind, wantedValues)
      notes[0] = 'section1=' + wanted.kind + '(wanted ' + best.toFixed(2) + ')'
      rescuedKind = wanted.kind
      rescuedP = best
    }
  }

  let layoutIds: string[] = [LAYOUT_NONE]
  for (let layout of layouts()) { layoutIds.push(layout.id) }
  let layoutId = readChoiceValue(answers, '__LAYOUT__', layoutIds, LAYOUT_ABOVE, LAYOUT_NONE)
  let layoutNote = ''
  let placed: SectionPick[] = picks
  let usedLayout = LAYOUT_STACK
  if (layoutId !== LAYOUT_NONE && layoutId !== LAYOUT_STACK) {
    let kindsNow: string[] = []
    for (let pick of picks) { kindsNow.push(pick.kind) }
    let addedNote = ''
    let wanted: string[] = []
    let wantedP: number[] = []
    for (let kind of kindsOfLayout(layoutId)) {
      let p = readNoulProbability(answers, 'include.' + kind)
      if (p > INCLUDE_ABOVE) {
        // likeliest first, so a full slot keeps the part the request asks for most
        let at = 0
        while (at < wantedP.length && wantedP[at] >= p) { at = at + 1 }
        wanted.splice(at, 0, kind)
        wantedP.splice(at, 0, p)
      }
    }
    let swapped = swapForLayout(layoutId, kindsNow)
    let included = placeKinds(kindsNow, fitToSlots(layoutId, kindsNow, wanted))
    let filled = swapped.concat(included).concat(completeRequiredSlots(layoutId, kindsNow))
    for (let i of filled) {
      let added = findFragment(specs, kindsNow[i])
      if (added === null) { continue }
      let addedValues: Map<string, string> = new Map<string, string>()
      for (let slot of added.slots) { addedValues.set(slot.token, readSlotValue(answers, i + 1, added.kind, slot)) }
      picks[i] = new SectionPick(added.kind, addedValues)
      addedNote = addedNote + ' +' + added.kind
    }
    let order = arrangeInLayout(layoutId, kindsNow)
    if (order === null) {
      layoutNote = ' layout=' + layoutId + '(rejected, stack)' + addedNote
    } else {
      placed = []
      for (let i of order) { placed.push(picks[i]) }
      usedLayout = layoutId
      layoutNote = ' layout=' + layoutId + addedNote
    }
  }

  // A weak pick is two answers that agree only when the block works on its own. A block with ports (a number strip, a
  // filter box) works only beside the block at the other end of one of them; with none on the screen, a reader shows its
  // fallbacks and a writer publishes to nobody. Checked after the layout, which can add that partner. Only the pick goes:
  // the veto it covered is then decided like any other, below.
  for (let w = 0; w < weakPicks.length; w++) {
    let at = placed.indexOf(weakPicks[w])
    if (at < 0 || hasPartner(specs, placed, at)) { continue }
    placed[at] = new SectionPick('none', new Map<string, string>())
    let slot = notes[weakNoteAt[w]].split('=')[0]
    notes[weakNoteAt[w]] = slot + '=none(' + weakPicks[w].kind + ' has no partner)'
  }

  // A veto a chosen block already covers (VeraTemplates.ets FragmentSpec.covers: a search box is the search a
  // needs_search_or_form veto asks for, a record log is the several-field form and the running totals) would only pay for a
  // model completion that adds nothing. coversIf is the same for a block whose phone actions are slots: it covers
  // needs_integration only when one of them came out true. A hard veto is decided here, after the blocks are known, and
  // stays a rejection when nothing chosen covers it.
  let covered: string[] = []
  for (let pick of placed) {
    let spec = findFragment(specs, pick.kind)
    if (spec === null) { continue }
    for (let key of spec.covers) { if (covered.indexOf(key) < 0) { covered.push(key) } }
    for (let rule of spec.coversIf) {
      let parts = rule.split('=')
      if (parts.length !== 2) { continue }
      for (let token of parts[1].split('|')) {
        if (pick.slotValues.get(token) === 'true' && covered.indexOf(parts[0]) < 0) { covered.push(parts[0]) }
      }
    }
  }
  let remainingHard: string[] = []
  for (let tag of vetoNotes) { if (covered.indexOf(tag.split('=')[0]) < 0) { remainingHard.push(tag) } }
  if (remainingHard.length > 0) {
    let hardNote = 'vetoed ' + remainingHard.join(' ')
    if (needsRealData) { hardNote = hardNote + ' needs_real_data=' + realDataProbability.toFixed(2) }
    return new SectionPickOutcome(null, emptyGlobals, hardNote)
  }
  if (covered.length > 0) {
    let kept: string[] = []
    for (let tag of logicNotes) {
      let key = tag.split('=')[0]
      if (covered.indexOf(key) < 0) { kept.push(tag) }
    }
    logicNotes = kept
  }

  let anyChosen = false
  for (let pick of placed) { if (pick.kind !== 'none') { anyChosen = true } }
  if (!anyChosen) {
    let nothing = new SectionPickOutcome(null, emptyGlobals, 'none (' + notes.join(' ') + ')')
    for (let i = 1; i <= SECTION_COUNT; i++) {
      let weak = readChoiceValue(answers, 'section' + i.toString(), allowedKinds, WEAK_FROM, 'none')
      if (weak !== 'none' && nothing.weakKinds.indexOf(weak) < 0) { nothing.weakKinds.push(weak) }
    }
    return nothing
  }

  let globals: Map<string, string> = new Map<string, string>()
  globals.set('__THEME__', readChoiceValue(answers, '__THEME__', GLOBAL_THEME_VALUES, SLOT_PICK_ABOVE, 'clean'))
  globals.set('__HEADER_STYLE__', readChoiceValue(answers, '__HEADER_STYLE__', ['default', 'center'], SLOT_PICK_ABOVE, 'default'))
  // The banner's text is a canned placeholder ("Demo banner"), so a composed screen never shows it.
  globals.set('__BANNER_SECTION__', 'hide')

  let note = notes.join(' ') + layoutNote
  if (needsRealData) { note = note + ' needs_real_data=' + realDataProbability.toFixed(2) }
  if (logicNotes.length > 0) { note = note + ' logic=' + logicNotes.join(',') }
  let outcome = new SectionPickOutcome(placed, globals, note, needsRealData, logicNotes.length > 0)
  outcome.softVetoes = logicNotes.map((tag: string): string => tag.substring(0, tag.indexOf('=')))
  outcome.layout = usedLayout
  outcome.wanted = rescuedKind
  outcome.wantedP = rescuedP
  return outcome
}

/**
 * Assembles one `.vera` program from the chosen fragments. Both `chosenKinds` and
 * `instanceValues` are indexed by *original* slot position (0-based here, 1-based in the
 * generated identifiers) -- a 'none'/unknown slot is simply skipped, it does not shift later
 * slots' instance numbers or `instanceValues` indices. This matters because a caller naturally
 * builds `instanceValues` the same way SectionPickOutcome.sections and
 * VeraTemplateContent.ets's SectionContentFillResult.instanceValues already are: one entry per
 * slot, including empty entries for 'none' slots, never compacted. Content tokens come from
 * VeraTemplateContent.ets's content-fill, keyed per slot instance.
 */
/**
 * Resolves "IDX" to a slot's instance number, then applies every one of that slot's own
 * slot/content token->value substitutions. Used by composeProgram for every per-instance text
 * piece (initStatements, functions, viewBlock alike) -- a content token like "__ITEM1_IDX__" can
 * live in any of them (checklist's item labels are built in init()'s initStatements, not view()),
 * so substitution cannot be limited to just the view block. Module-level, not nested inside
 * composeProgram -- ArkTS does not support nested functions (arkts-no-nested-funcs).
 */
function resolveInstanceText(text: string, idx: string, values: Map<string, string> | undefined, indexed: boolean = true): string {
  let resolved = indexed ? text.split('IDX').join(idx) : text
  if (values !== undefined) {
    values.forEach((value: string, token: string) => {
      let resolvedToken = indexed ? token.split('IDX').join(idx) : token
      resolved = resolved.split(resolvedToken).join(value)
    })
  }
  return resolved
}

const PASSTHROUGH: string = '__PASSTHROUGH__'

function isIdentChar(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '_'
}

/** The keys an object literal sets between its opening brace at `open` and `end`, at its own level only. */
function keysSet(text: string, open: number, end: number): string[] {
  let keys: string[] = []
  let depth = 0
  let expectKey = true
  let i = open + 1
  while (i < end) {
    let c = text.charAt(i)
    if (c === '"') {
      i++
      while (i < end && text.charAt(i) !== '"') { i += text.charAt(i) === '\\' ? 2 : 1 }
      expectKey = false
    } else if (c === '{' || c === '(' || c === '[') {
      depth++
      expectKey = false
    } else if (c === '}' || c === ')' || c === ']') {
      depth--
    } else if (c === ',' && depth === 0) {
      expectKey = true
    } else if (expectKey && depth === 0 && isIdentChar(c)) {
      let start = i
      while (i < end && isIdentChar(text.charAt(i))) { i++ }
      let name = text.substring(start, i)
      while (i < end && text.charAt(i) === ' ') { i++ }
      if (i < end && text.charAt(i) === ':') { keys.push(name) }
      expectKey = false
      continue
    }
    i++
  }
  return keys
}

/**
 * Every __PASSTHROUGH__ in `text` replaced by `, name: state.name` for each AppState field its object literal does not
 * already set. A block names its own fields and passes the rest through; a part that also sets another part's
 * field (an input that restarts the countdown) names that one too, and it is not passed through twice.
 */
function fillPassthrough(text: string, fields: string[]): string {
  let out = ''
  let opens: number[] = []
  let i = 0
  let copied = 0
  while (i < text.length) {
    let c = text.charAt(i)
    if (c === '"') {
      i++
      while (i < text.length && text.charAt(i) !== '"') { i += text.charAt(i) === '\\' ? 2 : 1 }
    } else if (c === '/' && text.charAt(i + 1) === '/') {
      while (i < text.length && text.charAt(i) !== '\n') { i++ }
      continue
    } else if (c === '{') {
      opens.push(i)
    } else if (c === '}') {
      opens.pop()
    } else if (c === '_' && text.startsWith(PASSTHROUGH, i)) {
      let set = opens.length > 0 ? keysSet(text, opens[opens.length - 1], i) : []
      let rest = ''
      for (let name of fields) { if (set.indexOf(name) < 0) { rest = rest + ', ' + name + ': state.' + name } }
      // A comma already written before the token ({a: 1, __PASSTHROUGH__}) is the one the passthrough brings.
      let upTo = i
      while (upTo > copied && text.charAt(upTo - 1) === ' ') { upTo-- }
      if (upTo > copied && text.charAt(upTo - 1) === ',') { upTo-- } else { upTo = i }
      // A literal that sets nothing ({__PASSTHROUGH__}: the state as it is) takes the fields without a leading comma.
      let before = upTo
      while (before > 0 && text.charAt(before - 1) === ' ') { before-- }
      if (before > 0 && text.charAt(before - 1) === '{' && rest.length > 0) { rest = rest.substring(2) }
      out = out + text.substring(copied, upTo) + rest
      i += PASSTHROUGH.length
      copied = i
      continue
    }
    i++
  }
  return out + text.substring(copied)
}

/**
 * A hole's text as it goes into the program: the body between two //@hole marker lines, so a compile
 * error can be traced back to the hole (VeraHoles.ets reads the markers). `instance` is the slot's
 * 1-based number, the same one "IDX" resolves to.
 */
export function markedHole(key: string, instance: string, body: string): string {
  // A body may name a handler of its own block as "...IDX"; the number is settled here, so a stored body survives the block moving.
  return '//@hole ' + key + instance + ' begin\n' + body.split('IDX').join(instance) + '\n//@hole ' + key + instance + ' end'
}

/** instanceValues for one slot plus the default body of every hole the caller left unfilled. */
function withHoleDefaults(spec: FragmentSpec, idx: string, values: Map<string, string> | undefined): Map<string, string> {
  let merged: Map<string, string> = new Map<string, string>()
  if (values !== undefined) { values.forEach((v: string, k: string) => { merged.set(k, v) }) }
  for (let hole of spec.holes) {
    if (!merged.has(hole.token)) { merged.set(hole.token, markedHole(hole.key, idx, hole.defaultBody)) }
  }
  return merged
}

/**
 * Port binding. For every reads port of the fragment in slot i, the publishers are the other chosen
 * slots with a writes port of the same name and type; the port is bound to the first of them (state
 * field of that slot's instance), or to the port's own fallback expression when there is none.
 * Returns, per slot, token -> Vera expression, to be applied to that slot's text. A slot with no
 * reads ports (or 'none') gets an empty map. Exported for the host checks.
 */
export function bindPorts(chosenKinds: string[]): Map<string, string>[] {
  return bindSpecPorts(specsOf(chosenKinds))
}

/** The block of each chosen kind, null for 'none' or a kind there is no block of. */
export function specsOf(chosenKinds: string[]): (FragmentSpec | null)[] {
  let allSpecs = fragments()
  let specAt: (FragmentSpec | null)[] = []
  for (let kind of chosenKinds) { specAt.push(findFragment(allSpecs, kind)) }
  return specAt
}

function bindSpecPorts(specAt: (FragmentSpec | null)[]): Map<string, string>[] {
  let out: Map<string, string>[] = []
  for (let i = 0; i < specAt.length; i++) {
    let bound: Map<string, string> = new Map<string, string>()
    let spec = specAt[i]
    if (spec !== null) {
      for (let port of spec.ports) {
        if (port.dir !== 'reads') { continue }
        let expr = port.fallback
        for (let j = 0; j < specAt.length; j++) {
          if (j === i) { continue }
          let other = specAt[j]
          if (other === null) { continue }
          let found = ''
          for (let candidate of other.ports) {
            if (candidate.dir === 'writes' && candidate.name === port.name && candidate.type === port.type) {
              let resolvedRef = candidate.ref.split('IDX').join((j + 1).toString())
              found = candidate.computed ? resolvedRef : 'state.' + resolvedRef
              break
            }
          }
          if (found.length > 0) { expr = found; break }
        }
        bound.set(port.ref, expr)
      }
    }
    out.push(bound)
  }
  return out
}

function applyPorts(text: string, bound: Map<string, string>): string {
  let resolved = text
  bound.forEach((expr: string, token: string) => { resolved = resolved.split(token).join(expr) })
  return resolved
}

export function composeProgram(chosenKinds: string[], globalValues: Map<string, string>, instanceValues: Map<string, string>[]): string {
  return composeFragments(specsOf(chosenKinds), globalValues, instanceValues)
}

/**
 * The program from the blocks given in screen order -- the catalogue's (fragments()) or ones made for one request
 * (VeraCompose.ets's parts). specAt[i] is null for an empty slot; every other array below is indexed the same way,
 * by original slot position. Globals: __THEME__, __TITLE__, __EYEBROW__, __SUPPORTING__ (text as it goes between
 * quotes), __HEADER_STYLE__ ('none' for no header), __HEADER_ICON__ ('check' when not given), __BANNER_SECTION__.
 */
/** The state field that holds which pane of a widget's tabs is open. */
const TAB_FIELD: string = 'paneTab'

/** The name of a block's tab: the block's own (`tab`), else its kind in words ("record_log" is "Record log"), made different from the tabs before it. */
function paneLabel(spec: FragmentSpec, taken: string[]): string {
  let words = spec.tab.length > 0 ? spec.tab : spec.kind.split('_').join(' ')
  let label = words.substring(0, 1).toUpperCase() + words.substring(1)
  if (label.length > 14) { label = label.substring(0, 14) }
  let out = label
  let n = 2
  while (taken.indexOf(out) >= 0) { out = label + ' ' + n.toString(); n++ }
  return out
}

export function composeFragments(specAt: (FragmentSpec | null)[], globalValues: Map<string, string>,
    instanceValues: Map<string, string>[]): string {

  let supportClasses: string[] = []
  let extraImports: string[] = []
  for (let spec of specAt) {
    if (spec === null) { continue }
    if (spec.supportClass.length > 0 && supportClasses.indexOf(spec.supportClass) < 0) {
      supportClasses.push(spec.supportClass)
    }
    for (let imp of spec.imports) {
      if (extraImports.indexOf(imp) < 0) { extraImports.push(imp) }
    }
  }

  let allFieldNames: string[][] = []
  let classFieldLines: string[] = []
  for (let i = 0; i < specAt.length; i++) {
    let spec = specAt[i]
    let idx = (i + 1).toString()
    let names: string[] = []
    if (spec !== null) {
      for (let field of spec.stateFields) {
        let name = spec.indexed ? field.name.split('IDX').join(idx) : field.name
        names.push(name)
        classFieldLines.push('  ' + name + ': ' + field.type + ';')
      }
    }
    allFieldNames.push(names)
  }

  // A widget in a chat reply is one window: when more than one block has a view, each is a pane of ui.Tabs, and the screen
  // holds which one is open. Every handler passes that field through like any other.
  let widget = globalValues.get('__WIDGET__') === 'true'
  let paneOf: number[] = []
  if (widget) {
    for (let i = 0; i < specAt.length; i++) {
      let spec = specAt[i]
      if (spec !== null && spec.viewBlock.length > 0) { paneOf.push(i) }
    }
  }
  let tabbed = paneOf.length > 1
  if (tabbed) {
    classFieldLines.push('  ' + TAB_FIELD + ': number;')
    allFieldNames.push([TAB_FIELD])
  }

  let portBindings = bindSpecPorts(specAt)
  let slotValues: Map<string, string>[] = []
  for (let i = 0; i < specAt.length; i++) {
    let spec = specAt[i]
    slotValues.push(spec === null ? new Map<string, string>() : withHoleDefaults(spec, (i + 1).toString(), instanceValues[i]))
  }
  let initStatementLines: string[] = []
  let initEntryParts: string[] = []
  for (let i = 0; i < specAt.length; i++) {
    let spec = specAt[i]
    if (spec === null) { continue }
    let idx = (i + 1).toString()
    if (spec.initStatements.length > 0) { initStatementLines.push(applyPorts(resolveInstanceText(spec.initStatements, idx, slotValues[i], spec.indexed), portBindings[i])) }
    if (spec.initEntries.length > 0) { initEntryParts.push(spec.indexed ? spec.initEntries.split('IDX').join(idx) : spec.initEntries) }
  }

  let everyField: string[] = []
  for (let names of allFieldNames) { for (let name of names) { everyField.push(name) } }
  let functionBlocks: string[] = []
  for (let i = 0; i < specAt.length; i++) {
    let spec = specAt[i]
    if (spec === null) { continue }
    let idx = (i + 1).toString()
    let fn = applyPorts(resolveInstanceText(spec.functions, idx, slotValues[i], spec.indexed), portBindings[i])
    functionBlocks.push(fillPassthrough(fn, everyField))
  }

  if (tabbed) {
    functionBlocks.push(fillPassthrough('function setPaneTab(state: AppState, index: number): AppState {\n  return {' + TAB_FIELD +
      ': index' + PASSTHROUGH + '};\n}', everyField))
  }
  let viewBlocks: string[] = []
  let tabNames: string[] = []
  let tabPanes: string[] = []
  for (let i = 0; i < specAt.length; i++) {
    let spec = specAt[i]
    if (spec === null) { continue }
    let idx = (i + 1).toString()
    let block = applyPorts(resolveInstanceText(spec.viewBlock, idx, slotValues[i], spec.indexed), portBindings[i]).split('__WIDGET__').join(widget ? 'true' : 'false')
    let pane = paneOf.indexOf(i)
    if (tabbed && pane >= 0 && block.length > 0) {
      let name = 'pane' + pane.toString()
      block = 'let ' + name + ': ui.View[] = [];\n' + block.split('sections.push(').join(name + '.push(')
      tabNames.push(paneLabel(spec, tabNames))
      tabPanes.push('ui.Column("default", ' + name + ')')
    }
    viewBlocks.push(block)
  }

  let bannerShow = globalValues.get('__BANNER_SECTION__') === 'show'
  let theme = globalValues.get('__THEME__')
  if (theme === undefined) { theme = 'clean' }
  let headerStyle = globalValues.get('__HEADER_STYLE__')
  if (headerStyle === undefined) { headerStyle = 'default' }
  let title = globalValues.get('__TITLE__')
  if (title === undefined) { title = '' }

  let lines: string[] = []
  lines.push('import * as ui from "std/ui"')
  for (let imp of extraImports) { lines.push(imp) }
  lines.push('')
  for (let sc of supportClasses) { lines.push(sc); lines.push('') }
  lines.push('@jsonable')
  lines.push('class AppState {')
  for (let l of classFieldLines) { lines.push(l) }
  lines.push('}')
  lines.push('')
  lines.push('function init(): AppState {')
  for (let l of initStatementLines) { lines.push(l) }
  if (tabbed) { initEntryParts.push(TAB_FIELD + ': 0') }
  lines.push('  return {' + initEntryParts.join(', ') + '};')
  lines.push('}')
  lines.push('')
  for (let fb of functionBlocks) { lines.push(fb); lines.push('') }
  lines.push('function view(state: AppState): ui.View {')
  lines.push('  let sections: ui.View[] = [];')
  let eyebrow = globalValues.get('__EYEBROW__')
  if (eyebrow === undefined) { eyebrow = '' }
  let supporting = globalValues.get('__SUPPORTING__')
  if (supporting === undefined) { supporting = '' }
  let icon = globalValues.get('__HEADER_ICON__')
  if (icon === undefined) { icon = 'check' }
  if (headerStyle !== 'none') {
    lines.push('  sections.push(ui.Header("' + headerStyle + '", "' + title + '", "' + eyebrow + '", "' + supporting + '", "' + icon + '"));')
  }
  for (let vb of viewBlocks) { if (vb.length > 0) { lines.push('  ' + vb.split('\n').join('\n  ')) } }
  if (tabbed) {
    lines.push('  sections.push(ui.Tabs("default", [' + tabNames.map((n: string): string => '"' + n + '"').join(', ') + '], state.' + TAB_FIELD +
      ', "setPaneTab", [' + tabPanes.join(', ') + ']));')
  }
  if (bannerShow) { lines.push('  sections.push(' + bannerSectionView() + ');') }
  lines.push('  return ui.AppTheme("' + theme + '", "", sections);')
  lines.push('}')
  return lines.join('\n')
}

/** The section and layout answers with their confidence, one short line for the log: what Jev said before any bar was applied. */
function rawAnswers(body: string): string {
  try {
    let parsed = JSON.parse(body) as Record<string, Object>
    let answers = parsed['answers'] as Record<string, Object>
    let parts: string[] = []
    for (let i = 1; i <= SECTION_COUNT; i++) {
      let a = answers['section' + i.toString()] as Record<string, Object>
      if (a === undefined || a === null) { continue }
      let conf = a['confidence']
      parts.push('s' + i.toString() + '=' + (a['choice'] as string) + '@' + (typeof conf === 'number' ? (conf as number).toFixed(2) : '?'))
    }
    for (let kind of layoutKinds()) {
      let inc = answers['include.' + kind] as Record<string, Object>
      if (inc !== undefined && inc !== null && typeof inc['noul'] === 'number' && (inc['noul'] as number) > 0.05) {
        parts.push('+' + kind + '@' + (inc['noul'] as number).toFixed(2))
      }
    }
    for (let spec of fragments()) {
      let want = answers['want.' + spec.kind] as Record<string, Object>
      if (want !== undefined && want !== null && typeof want['noul'] === 'number' && (want['noul'] as number) > 0.05) {
        parts.push('?' + spec.kind + '@' + (want['noul'] as number).toFixed(2))
      }
    }
    let layout = answers['__LAYOUT__'] as Record<string, Object>
    if (layout !== undefined && layout !== null) {
      let conf = layout['confidence']
      parts.push('layout=' + (layout['choice'] as string) + '@' + (typeof conf === 'number' ? (conf as number).toFixed(2) : '?'))
    }
    return parts.join(' ')
  } catch (_e) {
    return '(unreadable)'
  }
}

/**
 * Live call. Never throws and never rejects -- a selector that cannot answer must not stop
 * generation, the rule JevSelector.ets follows too.
 */
/**
 * After a failed call, Jev is not asked again for a minute. A phone on a network the service refuses (HTTP 451 "not available in
 * your region", seen as a 15 s read timeout for this 72 KB request) otherwise waited out the timeout on every generation, twice
 * with the request rewrite; now the first generation pays it and the following ones go straight on to the model.
 */
const RETRY_AFTER_FAILURE_MS: number = 60000
let failedAt: number = 0

/**
 * Whether an HTTP answer is about the service, not this request: not available in this region (451), rate limiting (429: the service
 * is throttling this phone, so the next requests would be too), or a server error (5xx). Timeouts and connection errors are
 * the same (the catch below). Any other answer -- a 400 for this body, a 401 for the key -- is this request's, and the next goes on.
 */
export function pausesSelector(code: number): boolean {
  return code === 451 || code === 429 || code >= 500
}

export async function selectSections(prompt: string, apiKey: string): Promise<SectionPickOutcome> {
  let emptyGlobals: Map<string, string> = new Map<string, string>()
  if (apiKey.length === 0 || prompt.trim().length === 0) { return new SectionPickOutcome(null, emptyGlobals, 'none (no key or prompt)') }
  if (failedAt > 0 && Date.now() - failedAt < RETRY_AFTER_FAILURE_MS) {
    return new SectionPickOutcome(null, emptyGlobals, 'none (selector unreachable, not asked again for a minute)')
  }
  let client = http.createHttp()
  let failStart = Date.now()
  try {
    let headers: Record<string, string> = {}
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ' + apiKey
    let started = Date.now()
    let body = buildSectionRequest(prompt)
    // When the answer does not come: how long until the headers, and how long in all (VERA-SECTIONS-NET lines).
    let headersAt = 0
    client.on('headersReceive', (): void => { headersAt = Date.now() - started })
    let response = await client.request(ENDPOINT, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      connectTimeout: 5000,
      readTimeout: 10000
    })
    hilog.info(DOMAIN, 'VERA', 'VERA-SECTIONS-NET bodyChars=' + body.length.toString() + ' headersMs=' + headersAt.toString() +
      ' totalMs=' + (Date.now() - started).toString() + ' http=' + (response.responseCode as number).toString())
    let code = response.responseCode as number
    if (code !== 200) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-SECTIONS http ' + code.toString())
      // Only an answer about the service itself pauses it: one about this request (a 400 for this body) says nothing of the next.
      if (pausesSelector(code)) { failedAt = Date.now() }
      noteService(SERVICE_JEV, false, httpFailure(code, String(response.result)))
      return new SectionPickOutcome(null, emptyGlobals, 'none (selector answered ' + code.toString() + (pausesSelector(code) ?
        ', not asked again for a minute' : '') + ')')
    }
    noteService(SERVICE_JEV, true)
    let outcome = readSectionPick(response.result as string)
    outcome.rawBody = response.result as string
    hilog.info(DOMAIN, 'VERA', 'VERA-SECTIONS ms=' + (Date.now() - started).toString() + ' picked=' + outcome.note)
    hilog.info(DOMAIN, 'VERA', 'VERA-SECTIONS raw ' + rawAnswers(response.result as string))
    return outcome
  } catch (e) {
    let err = e as BusinessError
    hilog.warn(DOMAIN, 'VERA', 'VERA-SECTIONS failed: ' + err.message + ' code=' + String(err.code) + ' after=' + (Date.now() - failStart).toString() + 'ms')
    failedAt = Date.now()
    noteService(SERVICE_JEV, false, err.message)
    return new SectionPickOutcome(null, emptyGlobals, 'none (selector unreachable)')
  } finally {
    client.destroy()
  }
}
