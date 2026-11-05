/**
 * What the composition leaves for the model to write, offered once more to the catalogue first. The plan's ready needs, the
 * events no effect does and the items of "other" that the vocabulary lacks all end up in `custom`, and the model writes a
 * section for them; but a section of the catalogue may already do exactly that (a daily medicine reminder is `reminders`, a
 * single calendar event is `calendar_event`). One Jev question per such need -- a ready-made section of the list, or none --
 * and only what Jev finds no section for is left to be written.
 *
 * What stays for the model whatever Jev says: the person's own records (a section with content would make them up) and the
 * figures worked out by a formula the vocabulary lacks (they are the screen's own). A section Jev names that the screen
 * already has is not taken as covering the need: its slots here are the catalogue's defaults, and a need it would only
 * cover with a slot turned on would be lost. On by default; `--ps veraAlign 0` (setAlignEnabled) turns it off, and nothing here runs.
 */

import { OperationCancellation, throwIfCancelled } from '../OperationCancellation'
import { Composition, SketchInput, SketchValue, READY_KINDS, JevAsk, LIST_SECTIONS, hasClock, canReplaceList, replaceList,
  isScene } from '../VeraCompose'
import { fragments, vetoes, FragmentSpec, VetoSpec } from '../VeraTemplates'

/** Sections a need that nothing else does may be given: the plan's ready kinds, and the two that do phone work no effect does. */
export const ALIGN_KINDS: string[] = READY_KINDS.concat(['reminders', 'calendar_event'])
/** Of those, the two that do phone work: their content is the person's own entry, never looked up. */
const PHONE_KINDS: string[] = ['reminders', 'calendar_event']
/** The sections of the wide pool whose content is the person's own or a setting, so nothing in it is looked up either. */
const OWN_CONTENT_KINDS: string[] = PHONE_KINDS.concat(['timer', 'note', 'rating', 'record_log', 'progress_goal'])
/** Sections that stand alone and still are not offered, in the wide pool as in the plain one. */
const NOT_OFFERED: string[] = ['actions', 'metrics', 'intent_panel', 'filter_box']
/** How sure Jev must be of a section for a need, as for a section's pick (VeraSectionCompose.ets). */
export const ALIGN_ABOVE: number = 0.5
/** The bar the catalogue gives its own needs_real_data question. */
const REAL_DATA_ABOVE: number = 0.35
const NONE: string = 'none'
/** How sure Jev must be that a need is about the person's own data for a section that writes its own content to be refused it; low, as the composer's, since such a section makes the data up. */
const WHOSE_OWN_ABOVE: number = 0.2
/** The mark the composer puts on a need that is the person's own records (VeraCompose.ets's readComposition). */
export const OWN_MARK: string = ' -- these are the person\'s own'
const FIGURE_MARK: string = 'the figure "'

let alignEnabled: boolean = true
export function setAlignEnabled(on: boolean): void { alignEnabled = on }
export function alignIsEnabled(): boolean { return alignEnabled }

let alignWide: boolean = true
export function setAlignWide(on: boolean): void { alignWide = on }
export function alignIsWide(): boolean { return alignWide }

/** A block that takes no value from another block: it makes sense on its own. */
function standsAlone(spec: FragmentSpec): boolean {
  for (let port of spec.ports) { if (port.dir === 'reads' && !port.optional) { return false } }
  return true
}

/**
 * The pool for this screen: a section is not offered for a need when the screen already has a part that does the same job --
 * a `timer` beside a countdown, or a log of entries beside the list the person fills in, would be two of the same. A list
 * part is given up for a section that keeps entries when nothing else is wired to it (canReplaceList); otherwise those
 * sections are not offered.
 */
export function alignKindsFor(comp: Composition): string[] {
  return alignKinds().filter((kind: string): boolean => {
    if (kind === 'timer' && hasClock(comp.sketch)) { return false }
    if (LIST_SECTIONS.indexOf(kind) >= 0 && comp.sketch.list !== null) { return canReplaceList(comp, kind) }
    return true
  })
}

/** A block that only shows what another block on the screen holds: no content of its own to look up. */
function isReader(kind: string): boolean {
  let spec = fragments().find((f: FragmentSpec): boolean => f.kind === kind)
  return spec !== undefined && !standsAlone(spec)
}

/** A section whose content is written for the request (items, rows, facts, a chart): it would make up what the person's own data holds. */
function isContentKind(kind: string): boolean {
  return OWN_CONTENT_KINDS.indexOf(kind) < 0 && !isReader(kind)
}

/** The sections a need the parts could not do may be given: the plain pool, or with `wide` every one that stands alone. */
export function alignKinds(): string[] {
  if (!alignWide) { return ALIGN_KINDS }
  let out: string[] = ALIGN_KINDS.slice()
  for (let spec of fragments()) {
    if (standsAlone(spec) && NOT_OFFERED.indexOf(spec.kind) < 0 && out.indexOf(spec.kind) < 0) { out.push(spec.kind) }
  }
  return out
}

export class AlignedNeed {
  need: string = ''
  /** The section Jev named, '' for none or for less than ALIGN_ABOVE. */
  kind: string = ''
  p: number = 0
  /** A section Jev named for a need about the person's own records that writes content of its own: not taken. */
  rejected: string = ''
}

export class AlignResult {
  /** One entry for each need that was asked about. */
  asked: AlignedNeed[] = []
  /** The sections added to the composition, in order. */
  added: string[] = []
  /** The needs now done by those sections: no longer for the model to write. */
  taken: string[] = []
  /** Whether Jev says the added sections' content has to come from a search. */
  realData: boolean = false
  /** How many needs the second question, about readers of the sections the first chose, found a section for. */
  readers: number = 0
  /** For the trace: what was asked and decided, '' when nothing was. */
  note: string = ''
  ms: number = 0
}

/**
 * The needs of `custom` a reader may show: not a figure the plan works out with a formula of its own, but the person's own records
 * are fine -- a reader makes up nothing, it shows what the log holds (a chart of the entries, a table per category).
 */
export function alignReaderCandidates(comp: Composition): string[] {
  return comp.custom.filter((need: string): boolean => !need.startsWith(FIGURE_MARK) && !isScene(need))
}

/** The needs of `custom` a section may do: not the person's own records, not a figure. */
export function alignCandidates(comp: Composition): string[] {
  // A value of format fraction is drawn by the figures part as a progress bar: a need for "a progress bar" is already done.
  let bar = comp.sketch.values.some((v: SketchValue): boolean => v.format === 'fraction')
  // A scene is drawn by the program itself: no section of the catalogue draws one.
  return comp.custom.filter((need: string): boolean => need.indexOf(OWN_MARK) < 0 && !need.startsWith(FIGURE_MARK) &&
    !isScene(need) && !(bar && need.toLowerCase().indexOf('progress') >= 0))
}

function criteriaOf(specs: FragmentSpec[], kinds: string[]): Record<string, Object> {
  let out: Record<string, Object> = {}
  for (let spec of specs) { if (kinds.indexOf(spec.kind) >= 0) { out[spec.kind] = spec.criteria } }
  out[NONE] = 'no listed part does it'
  return out
}

/** One batched Jev request: for each need a choice among the sections of ALIGN_KINDS or none, and whether the content must be real. */
export function buildAlignRequest(prompt: string, needs: string[], kinds: string[] = alignKinds(), shows: string = ''): string {
  let questions: Record<string, Object> = {}
  let criteria = criteriaOf(fragments(), kinds)
  for (let i = 0; i < needs.length; i++) {
    let q: Record<string, Object> = {}
    q['type'] = 'choice'
    q['instructions'] = 'A person asked for an app. One thing it must do: "' + needs[i] + '". Which ready-made part of the screen does ' +
      'exactly that on its own, with nothing important missing? Answer none if no listed part does it.' +
      (shows.length > 0 ? ' The screen already shows ' + shows + ': a part that would only repeat one of these, or count something else, is not what is asked.' : '')
    q['criteria'] = criteria
    questions['need.' + i.toString()] = q
    // Whether the need is about the person's own data: a section that writes content of its own would make that up.
    if (kinds.some((k: string): boolean => isContentKind(k))) {
      let whose: Record<string, Object> = {}
      let options: Record<string, Object> = {}
      options['own'] = 'the person\'s own data, or what is worked out from it or done with it: what they entered, their totals, who owes whom, ' +
        'their progress, marks they make on their own entries'
      options['written'] = 'facts, places, steps, figures or suggestions that anyone could look up or write for the request, before the person enters anything'
      whose['type'] = 'choice'
      whose['instructions'] = 'What does "' + needs[i] + '" show or do?'
      whose['criteria'] = options
      questions['whose.' + i.toString()] = whose
    }
  }
  let real: VetoSpec | undefined = vetoes().find((v: VetoSpec): boolean => v.key === 'needs_real_data')
  if (real !== undefined) {
    let rq: Record<string, Object> = {}
    rq['type'] = 'choice'
    rq['instructions'] = real.instructions
    let rc: Record<string, Object> = {}
    real.criteria.forEach((text: string, key: string) => { rc[key] = text })
    rq['criteria'] = rc
    questions['real_data'] = rq
  }
  let body: Record<string, Object> = {}
  body['model'] = 'jev-latest'
  body['state'] = prompt
  body['questions'] = questions
  return JSON.stringify(body)
}

function answerOf(answers: Record<string, Object>, key: string): Record<string, Object> | null {
  let a = answers[key]
  return a === null || a === undefined ? null : a as Record<string, Object>
}

/**
 * How likely Jev finds it that a need is about the person's own data: the probability of that option, not whether it was the one
 * chosen -- "the players and their points" came as own 0.42 against written 0.58, and the section that writes rows is not the answer
 * to a table of the person's own scores. Without probabilities, the choice and its confidence.
 */
function ownProbability(answer: Record<string, Object> | null): number {
  if (answer === null) { return 0 }
  let p = answer['probabilities']
  if (p !== null && p !== undefined && typeof (p as Record<string, Object>)['own'] === 'number') { return (p as Record<string, Object>)['own'] as number }
  return answer['choice'] === 'own' ? (typeof answer['confidence'] === 'number' ? answer['confidence'] as number : 1) : 0
}

/** Jev's answers as one decision per need, in order; a need Jev did not answer, or is unsure of, has no section. */
export function readAlignment(body: string, needs: string[], result: AlignResult, kinds: string[] = alignKinds()): void {
  let answers: Record<string, Object> = {}
  try {
    let found = (JSON.parse(body) as Record<string, Object>)['answers']
    if (found !== null && found !== undefined) { answers = found as Record<string, Object> }
  } catch (_e) {
    // No usable answer: nothing below is decided.
  }
  for (let i = 0; i < needs.length; i++) {
    let aligned = new AlignedNeed()
    aligned.need = needs[i]
    let a = answerOf(answers, 'need.' + i.toString())
    if (a !== null) {
      let choice = typeof a['choice'] === 'string' ? a['choice'] as string : ''
      aligned.p = typeof a['confidence'] === 'number' ? a['confidence'] as number : 1
      if (kinds.indexOf(choice) >= 0 && aligned.p >= ALIGN_ABOVE) { aligned.kind = choice }
    }
    let own = ownProbability(answerOf(answers, 'whose.' + i.toString())) >= WHOSE_OWN_ABOVE
    if (own && aligned.kind.length > 0 && isContentKind(aligned.kind)) {
      aligned.rejected = aligned.kind
      aligned.kind = ''
    }
    result.asked.push(aligned)
  }
  let real = answerOf(answers, 'real_data')
  if (real !== null) {
    let p = typeof real['confidence'] === 'number' ? real['confidence'] as number : 1
    result.realData = real['choice'] === 'true' && p >= REAL_DATA_ABOVE
  }
}

/**
 * Gives the composition the sections found: each new kind once, whatever number of needs it does, and takes those needs out
 * of what is left to write. A need whose section the screen already has stays, as the header says. Inputs the composer kept
 * only for the section the model was to write are left out when nothing is left to write: they would read nothing.
 */
export function applyAlignment(comp: Composition, result: AlignResult): void {
  for (let aligned of result.asked) {
    if (aligned.kind.length === 0) { continue }
    if (comp.blocks.indexOf(aligned.kind) >= 0 && result.added.indexOf(aligned.kind) < 0) { continue }
    if (result.added.indexOf(aligned.kind) < 0) {
      // A list the person fills in is given up for the section that keeps entries, not kept beside it.
      if (comp.sketch.list !== null && canReplaceList(comp, aligned.kind)) { replaceList(comp, aligned.kind) } else { comp.blocks.push(aligned.kind) }
      result.added.push(aligned.kind)
    }
    result.taken.push(aligned.need)
    comp.custom = comp.custom.filter((n: string): boolean => n !== aligned.need)
    comp.phoneNeeds = comp.phoneNeeds.filter((n: string): boolean => n !== aligned.need)
    comp.unboundNeeds = comp.unboundNeeds.filter((n: string): boolean => n !== aligned.need)
  }
  if (result.taken.length > 0 && comp.custom.length === 0 && comp.customReads.length > 0) {
    let kept = comp.inputs.filter((i: SketchInput): boolean => comp.customReads.indexOf(i.id) >= 0)
    if (kept.length > 0) {
      comp.dropped.push('input ' + kept.map((i: SketchInput): string => '"' + i.label + '"').join(', ') + ': a section does it')
      comp.inputs = comp.inputs.filter((i: SketchInput): boolean => comp.customReads.indexOf(i.id) < 0)
    }
    comp.customReads = []
  }
  // Only a section with content of its own is filled from a search.
  if (result.realData && result.added.some((k: string): boolean => OWN_CONTENT_KINDS.indexOf(k) < 0 && !isReader(k))) { comp.realData = true }
}

/** What the sections on the screen publish, as "name:type". */
function publishedBy(kinds: string[]): string[] {
  let out: string[] = []
  for (let spec of fragments()) {
    if (kinds.indexOf(spec.kind) < 0) { continue }
    for (let port of spec.ports) { if (port.dir === 'writes') { out.push(port.name + ':' + port.type) } }
  }
  return out
}

/**
 * The readers of the catalogue the screen can feed: every port one reads is published by a section on the screen, by name
 * and type, and the screen does not have it yet. [] unless the pool is wide.
 */
export function readerKinds(comp: Composition): string[] {
  if (!alignWide) { return [] }
  let published = publishedBy(comp.blocks)
  let out: string[] = []
  for (let spec of fragments()) {
    if (standsAlone(spec) || comp.blocks.indexOf(spec.kind) >= 0 || NOT_OFFERED.indexOf(spec.kind) >= 0) { continue }
    let fed = true
    for (let port of spec.ports) { if (port.dir === 'reads' && !port.optional && published.indexOf(port.name + ':' + port.type) < 0) { fed = false } }
    if (fed) { out.push(spec.kind) }
  }
  return out
}

/** What the screen's own parts already show, in a few words: the inputs and figures by label; '' when there are none. */
function screenShows(comp: Composition): string {
  let labels: string[] = []
  for (let i of comp.sketch.inputs) { labels.push(i.label) }
  for (let v of comp.sketch.values) { labels.push(v.label) }
  return labels.slice(0, 10).map((l: string): string => '"' + l + '"').join(', ')
}

/** One Jev question round over `needs` among `kinds`; false when Jev gave no answer. */
async function alignRound(comp: Composition, prompt: string, askJev: JevAsk, needs: string[], kinds: string[], result: AlignResult,
    cancellation?: OperationCancellation): Promise<boolean> {
  throwIfCancelled(cancellation)
  let body = ''
  try {
    body = await askJev(buildAlignRequest(prompt, needs, kinds, screenShows(comp)))
    throwIfCancelled(cancellation)
  } catch (_e) {
    throwIfCancelled(cancellation)
    if ((_e as Error).name === 'OperationCancelledError') { throw (_e as Error) }
    body = ''
  }
  if (body.length === 0) { return false }
  let round = new AlignResult()
  readAlignment(body, needs, round, kinds)
  applyAlignment(comp, round)
  result.asked = result.asked.concat(round.asked)
  result.added = result.added.concat(round.added)
  result.taken = result.taken.concat(round.taken)
  if (round.realData) { result.realData = true }
  return true
}

/**
 * Asks Jev about what is left to write and gives the composition the sections it finds. Never throws. A reader of what a section
 * on the screen publishes is asked about first: a total, a count or a balance over the section's own records is the reader's to
 * show, and a section standing alone (a key-facts block, a chart) would only make the figures up.
 */
export async function alignLeftovers(comp: Composition, prompt: string, askJev: JevAsk,
    cancellation?: OperationCancellation): Promise<AlignResult> {
  throwIfCancelled(cancellation)
  let result = new AlignResult()
  if (alignCandidates(comp).length === 0 && (readerKinds(comp).length === 0 || alignReaderCandidates(comp).length === 0)) { return result }
  let started = Date.now()
  let answered = true
  let readers = readerKinds(comp)
  if (readers.length > 0) { answered = await alignRound(comp, prompt, askJev, alignReaderCandidates(comp), readers, result, cancellation) }
  throwIfCancelled(cancellation)
  let rest = alignCandidates(comp)
  if (answered && rest.length > 0) {
    let before = comp.blocks.length
    answered = await alignRound(comp, prompt, askJev, rest, alignKindsFor(comp), result, cancellation)
    // A section just chosen may publish what a reader shows: what is still left is asked of those readers.
    throwIfCancelled(cancellation)
    let more = answered && comp.blocks.length > before ? readerKinds(comp) : []
    let left = alignReaderCandidates(comp)
    if (more.length > 0 && left.length > 0) { await alignRound(comp, prompt, askJev, left, more, result, cancellation) }
  }
  throwIfCancelled(cancellation)
  result.readers = result.added.filter((kind: string): boolean => isReader(kind)).length
  result.ms = Date.now() - started
  if (!answered) {
    result.note = '; align: Jev did not answer'
    return result
  }
  result.note = '; align: ' + result.asked.map((a: AlignedNeed): string => a.kind.length > 0 ? a.kind + '@' + a.p.toFixed(2) : (a.rejected.length > 0 ? 'none(own, not ' + a.rejected + ')' : 'none')).join(', ') +
    (result.added.length > 0 ? ' -> sections ' + result.added.join('+') : '')
  return result
}
