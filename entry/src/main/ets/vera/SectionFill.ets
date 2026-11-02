/**
 * Filling the catalogue's sections for a screen, the one way the agent (agent/VeraAgent.ets) and the host harness do it: a search when the content has to be real, the content call, the checks on what the
 * search said, then the holes, settled against the whole program.
 *
 * The network calls come from the caller (BlockCalls), so the app and the host harness fill sections the same way.
 */

import { OperationCancellation, PredicateCancellation, throwIfCancelled } from './OperationCancellation'
import { fillSectionsContent, blockDefaults, ContentAsk } from './VeraTemplateContent'
import { fillHoles, holesOf, holeValues, HoleInstance, HoleAsk, HoleFill } from './VeraHoles'
import { checkLiveProvenance } from './VeraLive'
import { SEARCH_CHARS, SEARCH_CHARS_DATA } from './VeraWebSearch'

/** Blocks that show facts of the real world: filled from a search whatever the pick said. A chart of invented round numbers is never what a chart request wants. */
const GROUNDED_KINDS: string[] = ['trend_chart', 'live_facts']

/** Sections of the catalogue to have their content (and their holes) filled for this request. */
export class BlockRequest {
  /** The sections' kinds, in screen order. */
  kinds: string[] = []
  /** The request as the person typed it: what the search, the phone lookup and the live-source check keep. */
  prompt: string = ''
  /** What the models are shown as the request when it is not the person's own words (a rewrite); '' for the prompt. */
  work: string = ''
  /** The Generate screen's generation mode: 'deepseek', 'local' or 'server'. Holes are written only in 'deepseek'. */
  mode: string = 'deepseek'
  /** Their content has to come from a search: real places, prices or facts. */
  realData: boolean = false
  /** How many blocks of its own the screen puts before them: the first section's slot number, less one. */
  offset: number = 0
  /** Jev's cosmetic choice for each section's slots (token to value), in `kinds` order; empty for the catalogue's defaults. */
  slotValues: Map<string, string>[] = []
  /** Jev's choice for the whole screen's own tokens (theme, header), under what the content call writes. */
  globals: Map<string, string> = new Map<string, string>()
  /** The whole program for the sections' values (in `kinds` order) and the screen's tokens, for holes to be checked against the compiler. */
  compose: (values: Map<string, string>[], globals: Map<string, string>) => string =
    (_values: Map<string, string>[], _globals: Map<string, string>): string => ''
}

export class BlockFill {
  /** Each section's slot, content and hole values, in `kinds` order. */
  values: Map<string, string>[] = []
  /** The same before the holes were written: what the composition record keeps. */
  baseValues: Map<string, string>[] = []
  /** The screen's tokens: the request's, under what the content call wrote. */
  globals: Map<string, string> = new Map<string, string>()
  /** The hole bodies the model wrote, by hole. */
  holeBodies: Map<string, string> = new Map<string, string>()
  /** One line for the trace. */
  note: string = ''
  /** Why the sections cannot be served (real data needed and no search), '' when they can. */
  failed: string = ''
  /** The content call's note, the live-source checks' notes and the holes' note, each apart. */
  contentNote: string = ''
  liveNotes: string[] = []
  holesNote: string = ''
  /** A search was made for these sections, and what it found ('' when it found nothing) and whether it found something. */
  grounded: boolean = false
  searchText: string = ''
  searched: boolean = false
  /** -1 when no search was made. */
  searchMs: number = -1
  contentMs: number = 0
  holesMs: number = 0
  /** The caller asked to stop while this ran; the rest is not filled. */
  cancelled: boolean = false
}

export class BlockCalls {
  /** A web search for the request, with the budget of characters to keep: the results as text; null when there is no search to make. */
  search: ((query: string, chars: number) => Promise<string>) | null = null
  /** The content model. */
  content: ContentAsk = async (_system: string, _user: string, _budget: number): Promise<string | null> => null
  /** The model that writes hole bodies. */
  hole: HoleAsk = async (_system: string, _user: string): Promise<string | null> => null
  /** The phone functions found for the request, for a hole that may call the phone. */
  sdkContext: (prompt: string) => Promise<string> = async (_prompt: string): Promise<string> => ''
  /** One line for the person: what is being done now. */
  status: (text: string) => void = (_text: string): void => {}
  /** True once the person has asked to stop. */
  cancelled: () => boolean = (): boolean => false
  cancellation?: OperationCancellation
}

/** Per-section copies of `values` with `extra` merged in; the maps given are not changed. */
export function mergedValues(values: Map<string, string>[], extra: Map<string, string>[]): Map<string, string>[] {
  let out: Map<string, string>[] = []
  for (let i = 0; i < values.length; i++) {
    let m: Map<string, string> = new Map<string, string>()
    values[i].forEach((v: string, k: string) => { m.set(k, v) })
    if (i < extra.length) { extra[i].forEach((v: string, k: string) => { m.set(k, v) }) }
    out.push(m)
  }
  return out
}

/** Whether these sections have to be filled from a search: the pick said the request needs real data, or one of them shows real-world facts whatever was said. */
export function needsGrounding(kinds: string[], realData: boolean): boolean {
  return realData || kinds.some((k: string): boolean => GROUNDED_KINDS.indexOf(k) >= 0)
}

/** What a search answered, as something to fill from: not a failure, not an empty answer. */
function searchFound(text: string): boolean {
  return text.length > 0 && !text.startsWith('Search failed:') && text !== 'No results.'
}

/**
 * Real data with no search to ground it is refused: a screen of invented places, prices or figures is not what was
 * asked for. Never throws on its own account; the calls given are expected not to.
 */
export async function fillSections(request: BlockRequest, calls: BlockCalls): Promise<BlockFill> {
  let fill = new BlockFill()
  throwIfCancelled(calls.cancellation)
  if (calls.cancelled()) { fill.cancelled = true; return fill }
  let cancellation: OperationCancellation = new PredicateCancellation((): boolean => calls.cancelled(), calls.cancellation)
  let work = request.work.length > 0 ? request.work : request.prompt
  let searchText = ''
  if (needsGrounding(request.kinds, request.realData)) {
    if (calls.search === null) { fill.failed = 'sections need real data and no search is available'; return fill }
    calls.status('Looking up real data...')
    let searchStart = Date.now()
    throwIfCancelled(cancellation)
    searchText = await calls.search!(request.prompt, request.kinds.indexOf('trend_chart') >= 0 ? SEARCH_CHARS_DATA : SEARCH_CHARS)
    throwIfCancelled(cancellation)
    fill.searchMs = Date.now() - searchStart
    fill.grounded = true
    fill.searchText = searchText
    fill.searched = searchFound(searchText)
  }

  let contentStart = Date.now()
  throwIfCancelled(cancellation)
  let content = await fillSectionsContent(request.kinds, work, request.mode, searchText, calls.content, cancellation)
  throwIfCancelled(cancellation)
  fill.contentMs = Date.now() - contentStart
  fill.contentNote = content.note

  request.globals.forEach((v: string, k: string) => { fill.globals.set(k, v) })
  content.globalValues.forEach((v: string, k: string) => { fill.globals.set(k, v) })

  // The catalogue's defaults, under Jev's choices, under what the content call wrote.
  let values: Map<string, string>[] = []
  for (let i = 0; i < request.kinds.length; i++) {
    let m: Map<string, string> = new Map<string, string>()
    blockDefaults(request.kinds[i]).forEach((v: string, k: string) => { m.set(k, v) })
    if (i < request.slotValues.length) { request.slotValues[i].forEach((v: string, k: string) => { m.set(k, v) }) }
    let written = content.instanceValues[i]
    if (written !== undefined) { written.forEach((v: string, k: string) => { m.set(k, v) }) }
    // The first figures and the source of a live block are shown as found only if the search said so.
    if (request.kinds[i] === 'live_facts') { fill.liveNotes.push(checkLiveProvenance(m, searchText, request.prompt)) }
    values.push(m)
  }
  fill.baseValues = mergedValues(values, [])

  // Holes count slots across the whole screen: the screen's own blocks come first.
  let kinds: string[] = []
  let padded: Map<string, string>[] = []
  for (let i = 0; i < request.offset; i++) { kinds.push('none'); padded.push(new Map<string, string>()) }
  kinds = kinds.concat(request.kinds)
  padded = padded.concat(values)
  let holes = holesOf(kinds, padded)
  if (holes.some((h: HoleInstance): boolean => h.spec.byModel)) {
    if (request.mode !== 'deepseek') {
      fill.holesNote = 'holes=default(' + request.mode + ')'
    } else {
      calls.status('Writing the details...')
      let holesStart = Date.now()
      throwIfCancelled(cancellation)
      let sdkContext = holes.some((h: HoleInstance): boolean => h.spec.usesSdk) ? await calls.sdkContext(request.prompt) : ''
      throwIfCancelled(cancellation)
      let filled: HoleFill = await fillHoles(work, kinds, calls.hole,
        (bodies: Map<string, string>): string =>
          request.compose(mergedValues(values, holeValues(kinds, bodies).slice(request.offset)), fill.globals),
        padded, sdkContext, cancellation)
      throwIfCancelled(cancellation)
      values = mergedValues(values, holeValues(kinds, filled.bodies).slice(request.offset))
      fill.holeBodies = filled.bodies
      fill.holesMs = Date.now() - holesStart
      fill.holesNote = filled.note
    }
  }
  throwIfCancelled(cancellation)
  fill.values = values

  let notes: string[] = [fill.contentNote]
  if (fill.grounded) { notes.push('search=' + (fill.searched ? 'ok' : 'empty')) }
  for (let live of fill.liveNotes) { notes.push(live) }
  if (fill.holesNote.length > 0) { notes.push(fill.holesNote) }
  fill.note = notes.join(' ')
  return fill
}
