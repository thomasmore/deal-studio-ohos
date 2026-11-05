/**
 * A flat, searchable index of every intent celia's own tool catalogue names
 * a concrete bundle for (tools/build-celia-intent-index.py, ~680 entries on
 * the celia snapshot this was built from) -- the intent-side counterpart to
 * VeraSdkIndex.ets's static SDK surface, built the same way for the same
 * reason: 844 celia tools is too many to hand-curate one at a time the way
 * the 7-row VeraIntentCatalog is, and unlike VeraIntentRegistry's live
 * device read, there is no device to probe celia's own declarations
 * against -- it's a static, offline artifact.
 *
 * This is NOT a source of truth for what a device can actually call: a
 * celia entry names a bundle and an intent, never a module or an ability,
 * because celia doesn't declare those -- only VeraIntentRegistry's live
 * registry does. VeraIntentIndex.ets is where the two meet: it searches this
 * file's whole corpus unfiltered, the same way findSdkFunction does, and
 * only afterward drops whatever the connected device doesn't actually have,
 * splicing in the real target/modes for what survives. Nothing here is ever
 * handed to the model directly.
 *
 * Search follows VeraSdkIndex.findSdkFunction's own shape exactly (same
 * identifierTokens/needWords, same brute-force scored scan) -- see that
 * file's doc comment for why whole-token matching, not substring, and why a
 * linear scan is the right call at this corpus size.
 */

import { resourceManager } from '@kit.LocalizationKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { loadRawfileText } from './LlamaEngine'
import { requestWords, describeParamHint } from './VeraIntentRegistry'
import { identifierTokens, needWords } from './VeraSdkIndex'

const DOMAIN = 0x0000

/** One parameter celia's own tool schema declares, with its real platform
 * wire key already resolved (tools/intent_import.resolve_template_params) --
 * never celia's internal field name used as if it were the wire key. */
export class CeliaParam {
  name: string = ''
  platformName: string = ''
  kind: string = ''
  values: string[] = []
  required: boolean = false
  description: string = ''
}

/** One candidate the celia-driven search step can return -- no device
 * presence check yet, no target: VeraIntentIndex.ets adds both. */
export class CeliaIntentEntry {
  bundle: string = ''
  intentName: string = ''
  /** celia's own tool name -- a label only, never shown to the model. */
  name: string = ''
  /** One or two plain sentences, written by tools/build-celia-intent-index.py. */
  description: string = ''
  params: CeliaParam[] = []
  /** One line per param, via describeParamHint -- built once at load, so a
   * celia-sourced hint and a live-registry-sourced one (VeraIntentRegistry's
   * own describeSchemaProperty) read identically. */
  paramHints: string[] = []
  nameTokens: string[] = []
  descriptionTokens: string[] = []
}

/** JSON produced by tools/flatten-celia-intent-index.py -> typed entries,
 * tokenized and hinted once. */
export function parseCeliaIntentIndex(json: string): CeliaIntentEntry[] {
  let raw = JSON.parse(json) as Record<string, Object>[]
  let entries: CeliaIntentEntry[] = []
  for (let obj of raw) {
    let e = new CeliaIntentEntry()
    e.bundle = obj['bundle'] as string
    e.intentName = obj['intentName'] as string
    e.name = obj['name'] as string
    e.description = obj['description'] as string
    let rawParams = obj['params'] as Record<string, Object>[]
    for (let p of rawParams) {
      let param = new CeliaParam()
      param.name = p['name'] as string
      param.platformName = p['platformName'] as string
      param.kind = p['kind'] as string
      let values = p['values'] as Object[]
      for (let v of values) { param.values.push(v.toString()) }
      param.required = p['required'] as boolean
      param.description = p['description'] as string
      e.params.push(param)
      e.paramHints.push(describeParamHint(param.platformName, param.kind, param.values,
        param.description, param.required))
    }
    e.nameTokens = identifierTokens(e.name)
    e.descriptionTokens = requestWords(e.description)
    entries.push(e)
  }
  return entries
}

const W_NAME = 3
const W_DESCRIPTION = 1

function scoreEntry(entry: CeliaIntentEntry, words: string[]): number {
  let score = 0
  for (let w of words) {
    if (entry.nameTokens.indexOf(w) >= 0) { score = score + W_NAME }
    if (entry.descriptionTokens.indexOf(w) >= 0) { score = score + W_DESCRIPTION }
  }
  return score
}

/**
 * The top `limit` celia candidates for `need` -- a brute-force scan over
 * `index` (~680 entries), unfiltered by device presence on purpose: that
 * filter runs afterward, in VeraIntentIndex.ets, against whatever this scan
 * returns. Callers should over-fetch (pass a limit well above the external
 * 8) so enough candidates survive the filter.
 */
export function findCeliaIntentFunction(index: CeliaIntentEntry[], need: string, limit: number): CeliaIntentEntry[] {
  let words = needWords(need)
  let scored: CeliaIntentEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let e of index) {
    let s = scoreEntry(e, words)
    if (s > 0) {
      let key = e.bundle + '/' + e.intentName
      scores.set(key, s)
      scored.push(e)
    }
  }
  scored.sort((a: CeliaIntentEntry, b: CeliaIntentEntry) => {
    let ka = a.bundle + '/' + a.intentName
    let kb = b.bundle + '/' + b.intentName
    let sa = scores.get(ka) as number
    let sb = scores.get(kb) as number
    if (sa !== sb) { return sb - sa }
    return ka < kb ? -1 : 1
  })
  return scored.slice(0, limit)
}

let cache: CeliaIntentEntry[] = []
let loading: Promise<number> | null = null

/** Reads the bundled index once and remembers it -- parsing ~680 entries is
 * worth doing before, not during, a generation. */
export function loadCeliaIntentIndex(mgr: resourceManager.ResourceManager): Promise<number> {
  if (loading === null) { loading = loadCeliaIntentIndexRead(mgr) }
  return loading!
}

async function loadCeliaIntentIndexRead(mgr: resourceManager.ResourceManager): Promise<number> {
  try {
    let text = await loadRawfileText(mgr, 'celia-intent-index.json')
    cache = parseCeliaIntentIndex(text)
    hilog.info(DOMAIN, 'VERA', 'VERA-CELIA loaded ' + cache.length.toString() + ' celia intent candidates')
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-CELIA unavailable: ' + (e as Error).message)
    cache = []
  }
  return cache.length
}

export function celiaIndexSize(): number { return cache.length }

/** The loaded index itself, in load order -- VeraCeliaIntentEmbeddingCache.ets
 * keys its cache file to this order and needs the real entries to embed. */
export function celiaIntentIndexEntries(): CeliaIntentEntry[] { return cache }

/** find_intent_function's celia tier, as VeraIntentIndex.ets reaches it:
 * search the loaded index, unfiltered. */
export function findCeliaIntentFunctionFromCache(need: string, limit: number): CeliaIntentEntry[] {
  return findCeliaIntentFunction(cache, need, limit)
}
