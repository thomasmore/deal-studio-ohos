/**
 * A flat, searchable index of the OpenHarmony system API surface, built
 * offline by tools/build-sdk-index.py from interface_sdk-js and read here as
 * one bundled JSON array (16,511 entries across 47 kits, on the checkout this
 * was built from).
 *
 * This is not VeraIntentCatalog and not VeraIntentRegistry. The catalogue's
 * rows are probed on a phone and typed; the registry's addresses are read
 * live from a device the app is running on. Neither fits here: interface_sdk-
 * js is a static, offline artifact -- there is no device to probe it against
 * function by function, and there are too many of them (16,511) to curate one
 * at a time the way the 7-row catalogue is. So a program never gets a typed
 * sdk.* function the way it gets intent.playMusicList: it gets an address
 * found by search, the same way intent.call's raw escape hatch works, except
 * the search runs as a tool the generating model calls itself rather than a
 * classifier run once before generation starts (see docs/selector-design.md).
 *
 * findSdkFunction's matching is deliberately not semantic: a query word is
 * matched as a whole token, never a raw substring, against name (camelCase-
 * split: "setTorchMode" -> {set, torch, mode}) and module, and as a whole
 * word against description. Substring matching was tried first and let
 * "turn" match inside "reTURN" for nearly every entry, since almost every
 * description ends "...uses a promise to return the result" -- the exact
 * failure class docs/prompts/intent-coverage.md already documents for the
 * intent registry's own lexical fallback ("came" matching "camera"). Whole-
 * token matching fixes that class of bug, but confirmed, not fixed, on real
 * queries: a genuine synonym gap remains ("toggle bluetooth" never finds
 * enableBluetooth/disableBluetooth; "take a photo" never finds
 * PhotoOutput.capture; "turn on the flashlight" loses to turnOnRadio/
 * turnOffRadio because "turn" is a real word in both and "flashlight" only
 * scores as a description hit, not a name hit, against the real answer,
 * CameraManager.setTorchMode). That gap is the documented trigger for an
 * embeddings upgrade, not something more weight-tuning closes.
 */

import { resourceManager } from '@kit.LocalizationKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { loadRawfileText } from './LlamaEngine'
import { requestWords } from './VeraIntentRegistry'

const DOMAIN = 0x0000

/** One candidate the search step can return -- no contract, no probe. */
export class SdkEntry {
  kit: string = ''
  module: string = ''
  name: string = ''
  params: string = ''
  returnType: string = ''
  description: string = ''
  /** One or two plain sentences on what it does and what it is for, from
   * tools/build-sdk-summaries.py; '' when there is none. */
  summary: string = ''
  since: string = ''
  deprecated: boolean = false
  systemapi: boolean = false
  permission: string = ''
  file: string = ''
  /** camelCase-split words of `name`, lowercased -- computed once at load. */
  nameTokens: string[] = []
  /** Same, for `module`. */
  moduleTokens: string[] = []
  /** Whole words of `description` and `summary`, lowercased -- computed once at load. */
  descriptionTokens: string[] = []
}

/**
 * "setTorchMode" -> ['set', 'torch', 'mode']; "UIAbility" -> ['ui', 'ability'].
 * Exported: VeraIntentIndex.ets reuses this for the same reason
 * VeraSdkIndex reuses VeraIntentRegistry's requestWords -- one tokenizer for
 * one concern, not two copies that drift.
 */
export function identifierTokens(name: string): string[] {
  let matches = name.match(/[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+/g)
  if (matches === null) { return [] }
  let tokens: string[] = []
  for (let m of matches) { tokens.push(m.toLowerCase()) }
  return tokens
}

/** JSON produced by tools/build-sdk-index.py -> typed entries, tokenized once. */
export function parseSdkIndex(json: string): SdkEntry[] {
  let raw = JSON.parse(json) as Record<string, Object>[]
  let entries: SdkEntry[] = []
  for (let obj of raw) {
    let e = new SdkEntry()
    e.kit = obj['kit'] as string
    e.module = obj['module'] as string
    e.name = obj['name'] as string
    e.params = obj['params'] as string
    e.returnType = obj['returnType'] as string
    e.description = obj['description'] as string
    e.summary = (obj['summary'] as string | undefined) ?? ''
    e.since = obj['since'] as string
    e.deprecated = obj['deprecated'] as boolean
    e.systemapi = obj['systemapi'] as boolean
    e.permission = obj['permission'] as string
    e.file = obj['file'] as string
    e.nameTokens = identifierTokens(e.name)
    e.moduleTokens = identifierTokens(e.module)
    e.descriptionTokens = requestWords(e.description + ' ' + e.summary)
    entries.push(e)
  }
  return entries
}

/**
 * Grammatical filler that a length cutoff alone doesn't catch: "the" is
 * exactly as long as "add", and unlike "add" it says nothing. Keeping the
 * cutoff at 3 (rather than the registry's 4) matters here because this
 * surface's names are verb-led -- add/get/set/put/run -- and those verbs
 * carry real signal at length 3.
 */
const STOPWORDS: string[] = ['the', 'and', 'for', 'are', 'was', 'her', 'its',
  'but', 'not', 'you', 'all', 'can', 'has', 'had', 'out', 'who', 'why', 'how',
  'did', 'does', 'own', 'too', 'any', 'may', 'say', 'she', 'his', 'him', 'our',
  'per', 'via', 'with', 'from', 'that', 'this', 'have', 'been', 'were', 'they',
  'them', 'what', 'when', 'then', 'than', 'into', 'onto', 'over', 'will',
  'would', 'could', 'should', 'about']

/** Exported for VeraIntentIndex.ets -- the same "need" string shape, same filler to drop. */
export function needWords(need: string): string[] {
  let words: string[] = []
  for (let w of requestWords(need)) {
    if (w.length >= 3 && STOPWORDS.indexOf(w) < 0) { words.push(w) }
  }
  return words
}

const W_NAME = 3
const W_MODULE = 2
const W_DESCRIPTION = 1
const KIT_BONUS = 2
const DEPRECATED_PENALTY = 1

function scoreEntry(entry: SdkEntry, words: string[]): number {
  let score = 0
  for (let w of words) {
    if (entry.nameTokens.indexOf(w) >= 0) { score = score + W_NAME }
    if (entry.moduleTokens.indexOf(w) >= 0) { score = score + W_MODULE }
    if (entry.descriptionTokens.indexOf(w) >= 0) { score = score + W_DESCRIPTION }
  }
  let kit = entry.kit.toLowerCase()
  for (let w of words) {
    if (kit.indexOf(w) >= 0 || w.indexOf(kit) >= 0) { score = score + KIT_BONUS; break }
  }
  if (entry.deprecated) { score = score - DEPRECATED_PENALTY }
  return score
}

/**
 * The top `limit` sdk candidates for `need`, best first -- a brute-force scan
 * over `index`. That is deliberate, not a shortcut: at 16,511 entries a
 * linear scan with this scoring is microseconds to low milliseconds, which is
 * nothing next to the multi-second round trip to the model that calls this.
 * An inverted index or ANN structure would only earn its keep at a much
 * larger N than this surface has.
 */
/** Keeps a candidate ("Kit.Module.name") in the results; null keeps every one. */
export type SdkTargetFilter = (target: string) => boolean

export function findSdkFunction(index: SdkEntry[], need: string, limit: number = 8,
    only: SdkTargetFilter | null = null): SdkEntry[] {
  let words = needWords(need)
  let scored: SdkEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let i = 0; i < index.length; i++) {
    let entry = index[i]
    if (only !== null && !only!(entry.kit + '.' + entry.module + '.' + entry.name)) { continue }
    let s = scoreEntry(entry, words)
    if (s > 0) {
      let key = entry.kit + '.' + entry.module + '.' + entry.name
      scores.set(key, s)
      scored.push(entry)
    }
  }
  scored.sort((a: SdkEntry, b: SdkEntry) => {
    let ka = a.kit + '.' + a.module + '.' + a.name
    let kb = b.kit + '.' + b.module + '.' + b.name
    let sa = scores.get(ka) as number
    let sb = scores.get(kb) as number
    if (sa !== sb) { return sb - sa }
    return ka < kb ? -1 : 1
  })
  return scored.slice(0, limit)
}

let cache: SdkEntry[] = []
let targets: Map<string, boolean> = new Map<string, boolean>()
let loading: Promise<number> | null = null

/**
 * Whether `target` ("Kit.Module.name") is one of the entries this index
 * knows -- the check `intent.call` cannot make, because the intent registry
 * is read from the device at runtime and this index is a static artifact
 * built ahead of time. Fails open (true) while the index has not loaded: a
 * selector that cannot answer must not block a generation, the same rule
 * JevSelector follows for the intent side.
 */
export function isValidSdkTarget(target: string): boolean {
  if (cache.length === 0) { return true }
  return targets.has(target)
}

/**
 * Reads the bundled index once and remembers it -- once, because it only
 * changes when the SDK version this was built from changes, and parsing
 * 16,511 entries is worth doing before, not during, a generation.
 */
export function loadSdkIndex(mgr: resourceManager.ResourceManager): Promise<number> {
  if (loading === null) { loading = loadSdkIndexRead(mgr) }
  return loading!
}

async function loadSdkIndexRead(mgr: resourceManager.ResourceManager): Promise<number> {
  try {
    let text = await loadRawfileText(mgr, 'sdk-index.json')
    cache = parseSdkIndex(text)
    for (let e of cache) { targets.set(e.kit + '.' + e.module + '.' + e.name, true) }
    hilog.info(DOMAIN, 'VERA', 'VERA-SDK loaded ' + cache.length.toString() + ' sdk candidates')
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-SDK unavailable: ' + (e as Error).message)
    cache = []
  }
  return cache.length
}

export function sdkIndexSize(): number { return cache.length }

/** The loaded index itself, in load order -- VeraSdkEmbeddingCache.ets keys
 * its cache file to this order and needs the real entries to embed. */
export function sdkIndexEntries(): SdkEntry[] { return cache }

/** find_sdk_function as DeepSeek's tool call reaches it: search the loaded index. */
export function findSdkFunctionFromCache(need: string, limit: number = 8, only: SdkTargetFilter | null = null): SdkEntry[] {
  return findSdkFunction(cache, need, limit, only)
}
