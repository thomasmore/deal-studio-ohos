/**
 * A searchable, tool-callable view over the two places a generated program's
 * intent calls come from: the curated catalogue (VeraIntentCatalog, 7 rows,
 * typed, probed on a phone) and the raw device registry (VeraIntentRegistry,
 * up to 640 addresses, uncurated). Existed before this file as text spliced
 * into the prompt ahead of generation, chosen by JevSelector's two-stage
 * classifier (or its lexical fallback when Jev doesn't answer).
 *
 * That pre-splicing is what broke the comparison with sdk.call: whatever
 * JevSelector picked (or its lexical tail found) was already sitting in the
 * prompt as ready text before the model started reasoning, so it won even
 * when the model also called find_sdk_function and got a correct answer for
 * the same request (docs/selector-design.md). Giving intents the same
 * mechanism sdk.call already uses -- one tool the model calls when it
 * decides it needs something, searched locally, no network, no pre-selection
 * -- means neither has a head start baked into how the prompt was built.
 *
 * JevSelector.ets and its network round trips are untouched and still
 * callable; nothing here deletes them. GeneratePage simply stops invoking
 * them in favour of this.
 *
 * Both a catalogue row and a raw registry hit are now offered as sdk.call,
 * never intent.call or a typed intent.<name>: std/intent is no longer a
 * module a new program can import at all (VeraCompiler.collectImports), so
 * sdk.call is the only way a program written from now on reaches an intent.
 * A catalogue row's real address, mode and probed platform values (including
 * any valueMap translation, e.g. "work" -> the platform's own literal) are
 * substituted directly into the suggested call, and 'launch' rows (nothing to
 * tell the target, e.g. opening the calendar app) come back as a three-part
 * target -- see runRawIntent in VeraIntents.ets for how the two target shapes
 * are told apart and run. std/intent is no longer registered by the compiler
 * at all (a separate, revertible commit), so a program saved before that
 * change keeps running from its existing bytecode but cannot be recompiled
 * (Refine) without reverting it.
 */

import { INTENT_CATALOG, IntentSpec, IntentParam, unreachableTarget, ignoredIntent } from './VeraIntentCatalog'
import { registryEntries, RegistryEntry, requestWords } from './VeraIntentRegistry'
import { identifierTokens, needWords } from './VeraSdkIndex'
import { CeliaIntentEntry, celiaIntentIndexEntries, celiaIndexSize } from './VeraCeliaIntentIndex'
import { loadRawfileText } from './LlamaEngine'
import { resourceManager } from '@kit.LocalizationKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

/** One candidate find_intent_function can return. */
export class IntentEntry {
  /** 'catalog' (probed, so its address and values are trustworthy), 'celia'
   * (celia's own tool catalogue named a real parameter schema, and the
   * connected device actually has it -- celiaEntryIfInstalled below), or
   * 'raw' (the device registry, no description beyond what the registry
   * itself gives). All three come back as an sdk.call. */
  kind: string = ''
  /** An internal identifier only -- never shown to the model. */
  name: string = ''
  domain: string = ''
  description: string = ''
  /** A ready-to-copy sdk.call, so the model copies a working shape -- with
   * real platform values already substituted in -- rather than reconstructing
   * one from a param list. */
  callHint: string = ''
  /** What the embedding is computed from, ahead of the description: the
   * intent's own name, not its address. */
  label: string = ''
  /** What the intent is for, in plain words, without the appended parameter
   * list or keywords -- the embedded text, like the SDK's. Empty when no
   * summary exists, and then the embedding falls back to the description. */
  summary: string = ''
  /** bundle/IntentName, the key of intent-summaries.json and of the bundled
   * intent-embeddings.json; empty for a catalog row. */
  summaryKey: string = ''
  nameTokens: string[] = []
  descriptionTokens: string[] = []
}

/**
 * One or two plain sentences per intent, keyed bundle/IntentName, written by
 * tools/build-intent-summaries.py from the phone's intent list and the
 * assistant's own tool catalogue, and bundled as intent-summaries.json. The
 * registry says an intent exists; this says what it is for, which the registry
 * almost never does (displayName and keywords are empty on this phone).
 */
let summaries: Map<string, string> = new Map<string, string>()
let loading: Promise<number> | null = null

export function loadIntentSummaries(mgr: resourceManager.ResourceManager): Promise<number> {
  if (loading === null) { loading = loadIntentSummariesRead(mgr) }
  return loading!
}

async function loadIntentSummariesRead(mgr: resourceManager.ResourceManager): Promise<number> {
  try {
    let text = await loadRawfileText(mgr, 'intent-summaries.json')
    let obj = JSON.parse(text) as Record<string, string>
    for (let key of Object.keys(obj)) { summaries.set(key, obj[key]) }
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-SUMMARIES loaded ' + summaries.size.toString())
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-INTENT-SUMMARIES unavailable: ' + (e as Error).message)
  }
  return summaries.size
}

/**
 * The one value a closed-set param would send for a given program-level
 * value, translating through the row's own valueMap when it has one (e.g.
 * startNavigate's "work" -> "公司") and passing it through unchanged
 * otherwise. Every closed-set value the row accepts is shown this way in the
 * description, not just the first, so the model can write whichever one the
 * request actually needs instead of only ever copying the example.
 */
function platformValue(p: IntentParam, programValue: string): string {
  let mapped = p.valueMap.get(programValue)
  return mapped !== undefined ? mapped as string : programValue
}

function catalogEntry(spec: IntentSpec): IntentEntry {
  let e = new IntentEntry()
  e.kind = 'catalog'
  e.name = spec.name
  e.label = spec.name
  e.summary = spec.summary
  e.domain = spec.domain
  let fields: string[] = []
  let pairs: string[] = []
  for (let p of spec.params) {
    if (p.values.length > 0) {
      let shown: string[] = []
      for (let v of p.values) { shown.push(v + '=' + platformValue(p, v)) }
      fields.push(p.platformName + ' (one of: ' + shown.join(' ') + ')')
    } else {
      fields.push(p.platformName + ' (' + p.kind + ')')
    }
    let example = p.values.length > 0 ? platformValue(p, p.values[0]) : ''
    if (example.length > 0) { pairs.push('"' + p.platformName + '", "' + example + '"') }
  }
  e.description = spec.summary + (fields.length > 0 ? '. Platform fields: ' + fields.join(', ') : '')
  // 'launch' has no intent name and nothing to tell the target, so the target
  // is just bundle/module/ability -- three parts, not four. runRawIntent
  // (VeraIntents.ets) tells the two shapes apart the same way.
  let target = spec.via === 'launch'
    ? spec.bundle + '/' + spec.moduleName + '/' + spec.ability
    : spec.bundle + '/' + spec.moduleName + '/' + spec.ability + '/' + spec.intentName
  let modeArg = spec.via === 'launch' ? '' : ', "' + spec.mode + '"'
  e.callHint = 'sdk.call("' + target + '", [' + pairs.join(', ') + '], "yourHandlerName"' + modeArg + ')'
  e.nameTokens = identifierTokens(spec.name)
  e.descriptionTokens = requestWords(e.description)
  return e
}

function rawEntry(entry: RegistryEntry): IntentEntry {
  let e = new IntentEntry()
  e.kind = 'raw'
  e.name = entry.target
  e.domain = entry.domain
  let summary = summaries.get(entry.bundle + '/' + entry.intentName)
  e.summary = summary !== undefined ? summary as string : ''
  e.summaryKey = entry.bundle + '/' + entry.intentName
  // With a summary the description is what the intent is for; without one it
  // is all the registry gave us -- the name and the app it lives in.
  let bits: string[] = [summary !== undefined ? summary as string : entry.intentName + ' (' + entry.bundle + ')']
  // paramHints carries type, allowed values and required-ness when the app
  // declared a real schema (VeraIntentRegistry.describeSchemaProperty) --
  // the same quality of hint a catalogue row gives, from real platform data.
  // Falls back to bare names for the common case of a declared name with no
  // further shape, and to nothing at all when the app declared no schema.
  if (entry.paramHints.length > 0) { bits.push('parameters -- ' + entry.paramHints.join('; ')) }
  else if (entry.params.length > 0) { bits.push('parameters: ' + entry.params.join(' ')) }
  if (entry.words.length > 0) { bits.push(entry.words) }
  e.description = bits.join(', ')
  e.label = entry.intentName
  let mode = entry.modes.indexOf('background') >= 0 ? 'background' : 'foreground'
  // sdk.call, not intent.call: the two raw escape hatches are unified (see
  // buildStdSdkModule in VeraCompiler.ets). Argument order is (target,
  // params, handler, mode) -- mode trails because it is the optional one,
  // unlike intent.call's own (target, params, mode, handler).
  e.callHint = 'sdk.call("' + entry.target + '", [], "yourHandlerName", "' + mode + '")'
  e.nameTokens = identifierTokens(entry.intentName)
  e.descriptionTokens = requestWords(e.description)
  return e
}

/** registryEntries() indexed by bundle/intentName, rebuilt only when its
 * length changes -- the same invalidation rule allEntries() already uses,
 * so a celia candidate's device-presence check is a map lookup, not a scan. */
let registryByKey: Map<string, RegistryEntry> = new Map<string, RegistryEntry>()
let cachedRegistryKeyLength = -1

function registryIndex(): Map<string, RegistryEntry> {
  let len = registryEntries().length
  if (cachedRegistryKeyLength !== len) {
    registryByKey = new Map<string, RegistryEntry>()
    for (let r of registryEntries()) { registryByKey.set(r.bundle + '/' + r.intentName, r) }
    cachedRegistryKeyLength = len
  }
  return registryByKey
}

/**
 * A celia-sourced candidate, once the connected device is confirmed to
 * actually have it -- null otherwise, which drops it rather than ever
 * inventing a target. Celia only ever names a bundle and an intent; the
 * module, the ability and the real declared modes come from the live
 * registry entry, exactly the way a raw registry hit's own target already
 * does, never guessed from celia's data.
 *
 * Exported for VeraIntentEmbeddingCache.ets, so the embedding search path's
 * celia tier is filtered by the identical rule the token path uses here --
 * one filter, not two copies that could drift.
 */
export function celiaEntryIfInstalled(c: CeliaIntentEntry): IntentEntry | null {
  let reg = registryIndex().get(c.bundle + '/' + c.intentName)
  if (reg === undefined || unreachableTarget(c.bundle) || ignoredIntent(c.bundle, c.intentName)) { return null }
  let e = new IntentEntry()
  e.kind = 'celia'
  e.name = reg.target
  e.domain = reg.domain
  e.summary = c.description
  let bits: string[] = [c.description]
  if (c.paramHints.length > 0) { bits.push('parameters -- ' + c.paramHints.join('; ')) }
  e.description = bits.join(', ')
  e.label = c.name
  let mode = reg.modes.indexOf('background') >= 0 ? 'background' : 'foreground'
  e.callHint = 'sdk.call("' + reg.target + '", [], "yourHandlerName", "' + mode + '")'
  e.nameTokens = c.nameTokens
  e.descriptionTokens = requestWords(e.description)
  return e
}

const W_NAME = 3
const W_DOMAIN = 2
const W_DESCRIPTION = 1

function scoreEntry(e: IntentEntry, words: string[]): number {
  let score = 0
  let domainTokens = identifierTokens(e.domain)
  for (let w of words) {
    if (e.nameTokens.indexOf(w) >= 0) { score = score + W_NAME }
    if (domainTokens.indexOf(w) >= 0) { score = score + W_DOMAIN }
    if (e.descriptionTokens.indexOf(w) >= 0) { score = score + W_DESCRIPTION }
  }
  return score
}

/**
 * Builds (or reuses) the IntentEntry pool -- tokenizing names/descriptions
 * and assembling each row's callHint string is real work repeated for
 * nothing if done fresh on every search, so it's kept across calls.
 *
 * Invalidated by registry size rather than built once and forgotten: this
 * file can be asked to search before VeraIntentRegistry.loadRegistry()'s
 * device read finishes, and locking in whatever the registry had at that
 * moment (possibly still empty) would mean no raw intent ever surfaces for
 * the rest of the session even after the real registry arrives. Comparing
 * registryEntries().length catches exactly that case -- a later call with a
 * now-nonempty registry rebuilds once more, and then stays cached, because
 * loadRegistry() itself only ever populates the registry once per process.
 */
let cachedEntries: IntentEntry[] | null = null
let cachedRegistryLength = -1
let cachedSummariesLength = -1
let cachedCeliaLength = -1

/**
 * Exported for VeraIntentEmbeddingCache.ets -- the same pool findIntentFunction
 * searches by token, now also searchable by embedding.
 *
 * Three tiers, in trust order: the 7 hand-probed catalog rows; every celia
 * entry the connected device actually has (real summary, real structured
 * parameters, from tools/build-celia-intent-index.py's ~680-entry static
 * corpus -- searched whole, filtered to this device only here, never
 * before); and a bare raw-registry fallback for whatever's installed that
 * celia's own snapshot never named at all, so coverage never shrinks
 * relative to before celia existed. A bundle/intentName celia does cover
 * never falls through to the weaker raw tier.
 */
export function allEntries(): IntentEntry[] {
  let registryLength = registryEntries().length
  let celiaLength = celiaIndexSize()
  if (cachedEntries !== null && cachedRegistryLength === registryLength &&
      cachedSummariesLength === summaries.size && cachedCeliaLength === celiaLength) {
    return cachedEntries!
  }
  let entries: IntentEntry[] = []
  for (let spec of INTENT_CATALOG) {
    if (!unreachableTarget(spec.bundle) && !ignoredIntent(spec.bundle, spec.intentName)) { entries.push(catalogEntry(spec)) }
  }
  let celiaMatched: Set<string> = new Set<string>()
  for (let c of celiaIntentIndexEntries()) {
    let e = celiaEntryIfInstalled(c)
    if (e !== null) {
      entries.push(e)
      celiaMatched.add(c.bundle + '/' + c.intentName)
    }
  }
  for (let reg of registryEntries()) {
    if (!celiaMatched.has(reg.bundle + '/' + reg.intentName) && !unreachableTarget(reg.bundle) &&
        !ignoredIntent(reg.bundle, reg.intentName)) { entries.push(rawEntry(reg)) }
  }
  cachedEntries = entries
  cachedRegistryLength = registryLength
  cachedSummariesLength = summaries.size
  cachedCeliaLength = celiaLength
  return entries
}

/** catalog beats celia beats raw on a score tie -- catalog is typed and
 * probed, celia carries a real written summary and real structured
 * parameters, raw is the registry's own bare fallback. */
function kindRank(kind: string): number {
  if (kind === 'catalog') { return 0 }
  if (kind === 'celia') { return 1 }
  return 2
}

/**
 * The top `limit` intent candidates for `need` -- a brute-force scan over
 * the catalogue (7 rows), celia's device-present matches (0 to ~680), and
 * whatever's left in the raw registry (0 to ~640).
 *
 * Ties favour the higher-trust tier; see kindRank.
 */
export function findIntentFunction(need: string, limit: number = 8): IntentEntry[] {
  let entries = allEntries()
  let words = needWords(need)
  let scored: IntentEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let e of entries) {
    let s = scoreEntry(e, words)
    if (s > 0) {
      let key = e.kind + ':' + e.name
      scores.set(key, s)
      scored.push(e)
    }
  }
  scored.sort((a: IntentEntry, b: IntentEntry) => {
    let ka = a.kind + ':' + a.name
    let kb = b.kind + ':' + b.name
    let sa = scores.get(ka) as number
    let sb = scores.get(kb) as number
    if (sa !== sb) { return sb - sa }
    if (a.kind !== b.kind) { return kindRank(a.kind) - kindRank(b.kind) }
    return ka < kb ? -1 : 1
  })
  return scored.slice(0, limit)
}
