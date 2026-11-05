/**
 * On-device embedding cache for VeraIntentIndex's pool -- the curated
 * catalogue (7 rows) plus whatever VeraIntentRegistry has read off this
 * phone (0 to ~640, changes only when apps are installed/removed).
 *
 * Different shape from VeraSdkEmbeddingCache.ets on purpose, not by
 * oversight: that corpus is a static, versioned rawfile recomputed whole on
 * any mismatch, because there are 16,511 of them and no identity worth
 * tracking row to row. This one is small and keyed by identity (catalog
 * name, or raw registry target) specifically so a phone's rarely-changing
 * intent set only ever pays to embed entries it hasn't seen before --
 * installing one more app should not re-embed the other 639.
 *
 * Persisted as JSON, not a flat binary buffer: at this size (≤~650 rows) the
 * parse cost is trivial, and a key->vector map is the natural shape for
 * "which keys are missing" -- no need for sdk-index.json-style layout
 * invalidation.
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { IntentEntry, allEntries, celiaEntryIfInstalled } from './VeraIntentIndex'
import { embedBatch, embedOne, embeddingModelReady, MODEL_FILE } from './VeraEmbeddings'
import { loadRawfileText } from './LlamaEngine'
import { scoreCeliaCorpus, CeliaScored, celiaIntentEmbeddingsReady } from './VeraCeliaIntentEmbeddingCache'
import { resourceManager } from '@kit.LocalizationKit'

const DOMAIN = 0x0000
// See VeraSdkEmbeddingCache.ets's own comment on this constant -- same
// reasoning, same number: ~145ms/entry on-device means one chunk's native
// call blocks the main thread for about 1.2s, safely under the 3s warning
// threshold HarmonyOS's freeze watchdog logs before a kill.
const CHUNK_SIZE = 8
const BUNDLED_RAWFILE = 'intent-embeddings.json'

/** FNV-1a over the embedded text, so a description that changes (a new
 * summary, a reworded one) is a different key and gets embedded again. The
 * cache used to be keyed by name alone, which kept serving the vector of the
 * old text. Same hash the SDK cache header uses. */
function textHash(s: string): string {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h = (h ^ s.charCodeAt(i)) >>> 0
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16)
}

/** The intent's own name, then what it is for -- the summary alone, as the SDK
 * does (tools/build-intent-embeddings.py builds this exact text; keep them in
 * step). Not the address, and not the appended parameter list: the bundle path
 * only adds noise to the vector and the summary already says which app. An
 * entry with no summary falls back to its description. */
function entryEmbeddingText(e: IntentEntry): string {
  return e.label + ' ' + (e.summary.length > 0 ? e.summary : e.description)
}

/** raw:bundle/IntentName#hash for a registry intent, so the host can compute the
 * same key without knowing its module or ability; catalog rows keep their name. */
function entryKey(e: IntentEntry): string {
  let id = e.summaryKey.length > 0 ? e.summaryKey : e.name
  return e.kind + ':' + id + '#' + textHash(entryEmbeddingText(e))
}

/** key -> L2-normalized vector. Whatever's in here is usable; a key missing
 * from it (model never loaded, or not embedded yet) is simply skipped by
 * findIntentFunctionByEmbedding, not treated as a reason to fail. */
let vectors: Map<string, number[]> = new Map<string, number[]>()
let dimension = 0
let loadedFromDisk = false
let bundledTried = false
let building: Promise<void> | null = null

export function intentEmbeddingsReady(): boolean { return vectors.size > 0 }

function cacheFilePath(filesDir: string): string { return filesDir + '/vera/intent-embeddings.json' }

function readCache(filesDir: string): void {
  if (loadedFromDisk) { return }
  loadedFromDisk = true
  try {
    let stat = fs.statSync(cacheFilePath(filesDir))
    if (stat.size === 0) { return }
    let text = fs.readTextSync(cacheFilePath(filesDir))
    let obj = JSON.parse(text) as Record<string, Object>
    let dim = obj['dimension'] as number
    let rows = obj['vectors'] as Record<string, Object>
    if (rows === null || rows === undefined) { return }
    for (let key of Object.keys(rows)) {
      let v = rows[key] as number[]
      if (v.length === dim) { vectors.set(key, v) }
    }
    dimension = dim
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-EMBED cache hit, ' + vectors.size.toString() + ' vectors, dim=' + dim.toString())
  } catch (_e) {
    // No cache file yet, or an unreadable one -- start from empty, same as
    // VeraIntentRegistry.loadRegistry()'s own "failure is not an error" rule.
  }
}

function writeCache(filesDir: string): void {
  try {
    let rows: Record<string, Object> = {}
    vectors.forEach((v: number[], key: string) => { rows[key] = v })
    let obj: Record<string, Object> = {}
    obj['dimension'] = dimension
    obj['vectors'] = rows
    let file = fs.openSync(cacheFilePath(filesDir),
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, JSON.stringify(obj))
    } finally {
      fs.closeSync(file)
    }
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-INTENT-EMBED cache write failed: ' + (e as Error).message)
  }
}

/** FNV-1a over VeraEmbeddings.MODEL_FILE, the same number the SDK cache header
 * carries; tools/build-intent-embeddings.py computes it identically. */
function modelHash(): number {
  let h = 0x811c9dc5
  for (let i = 0; i < MODEL_FILE.length; i++) {
    h = (h ^ MODEL_FILE.charCodeAt(i)) >>> 0
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h
}

/**
 * Seeds `vectors` from the bundled rawfile (tools/build-intent-embeddings.py,
 * run host-side against intent-summaries.json and the same GGUF), so a fresh
 * install does not spend ~90 s embedding ~640 intents on the phone. Only what
 * the device cache does not already hold is taken, and a file built with a
 * different model is ignored outright -- its vectors live in another space.
 * Returns how many vectors were added.
 */
async function readBundled(mgr: resourceManager.ResourceManager): Promise<number> {
  if (bundledTried) { return 0 }
  bundledTried = true
  try {
    let text = await loadRawfileText(mgr, BUNDLED_RAWFILE)
    let obj = JSON.parse(text) as Record<string, Object>
    if ((obj['modelHash'] as number) !== modelHash()) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-INTENT-EMBED bundled vectors built with another model -- ignored')
      return 0
    }
    let dim = obj['dimension'] as number
    if (dimension !== 0 && dimension !== dim) { return 0 }
    let rows = obj['vectors'] as Record<string, Object>
    let added = 0
    for (let key of Object.keys(rows)) {
      let v = rows[key] as number[]
      if (v.length === dim && !vectors.has(key)) { vectors.set(key, v); added++ }
    }
    dimension = dim
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-EMBED bundled ' + added.toString() + ' vectors, dim=' + dim.toString())
    return added
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-INTENT-EMBED no usable bundled vectors: ' + (e as Error).message)
    return 0
  }
}

async function build(filesDir: string, mgr: resourceManager.ResourceManager | null): Promise<void> {
  readCache(filesDir)
  if (mgr !== null) {
    let added = await readBundled(mgr)
    if (added > 0) { writeCache(filesDir) }
  }
  let entries = allEntries()
  let missing: IntentEntry[] = []
  for (let e of entries) {
    // celia-tier entries are embedded once, offline, host-side, over celia's
    // whole static corpus (VeraCeliaIntentEmbeddingCache.ets) -- embedding
    // them again here, one device-present subset at a time, would duplicate
    // that work on-device at the ~145ms/entry cost this file exists to avoid.
    if (e.kind === 'celia') { continue }
    if (!vectors.has(entryKey(e))) { missing.push(e) }
  }
  if (missing.length === 0) { return }
  if (!embeddingModelReady()) { return }
  // Drop vectors of texts that no longer exist, so the file does not grow by a
  // full copy every time the descriptions are rewritten.
  let live: Set<string> = new Set<string>()
  for (let e of entries) { live.add(entryKey(e)) }
  let stale: string[] = []
  vectors.forEach((_v: number[], key: string) => { if (!live.has(key)) { stale.push(key) } })
  for (let key of stale) { vectors.delete(key) }

  let startedAt = Date.now()
  let embedded = 0
  for (let start = 0; start < missing.length; start += CHUNK_SIZE) {
    let chunk = missing.slice(start, Math.min(start + CHUNK_SIZE, missing.length))
    let texts: string[] = []
    for (let e of chunk) { texts.push(entryEmbeddingText(e)) }
    let vecs = await embedBatch(texts)
    if (vecs === null) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-INTENT-EMBED build aborted at ' + start.toString() +
        '/' + missing.length.toString() + ' -- embedding became unavailable')
      break
    }
    for (let i = 0; i < chunk.length; i++) {
      let v = vecs[i]
      if (v.length === 0) { continue } // this one entry failed to embed -- leave it absent, not zeroed
      if (dimension === 0) { dimension = v.length }
      if (v.length === dimension) {
        vectors.set(entryKey(chunk[i]), v)
        embedded++
      }
    }
  }
  if (embedded > 0) {
    hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-EMBED embedded ' + embedded.toString() + ' new of ' +
      missing.length.toString() + ' missing in ' + (Date.now() - startedAt).toString() + 'ms')
    writeCache(filesDir)
  }
}

/**
 * Kicks off the cache build (missing-keys only), fire-and-forget safe from
 * GeneratePage.ets -- and safe to call again later (e.g. once
 * loadRegistry() actually finishes, or after a fresh app install changes
 * the registry): each call only coalesces with one already in flight, not
 * with one that has already finished, so a later call always re-checks
 * `allEntries()` for anything still missing. This matters in practice --
 * loadRegistry()'s own device read is a separate, independent async
 * operation with no ordering guarantee against this one, so the first call
 * here can genuinely run before the registry has populated at all (confirmed
 * on-device this session: a first pass embedded only the 7 catalog rows
 * plus a handful of early raw entries, not the full ~640).
 */
export function ensureIntentEmbeddings(filesDir: string,
    mgr: resourceManager.ResourceManager | null = null): Promise<void> {
  if (building === null) {
    building = build(filesDir, mgr).then((): void => { building = null })
  }
  return building!
}

/**
 * The top `limit` intent candidates for `need` by cosine similarity --
 * null means "nothing embedded yet", which DeepSeekEngine.ets treats as
 * "fall back to findIntentFunction". Scores only entries that have a cached
 * vector; one that doesn't (never embedded, or failed to embed) is simply
 * absent from the ranking, not a zero score dragging it to the bottom --
 * either way it does not surface, but this way a partially-built cache
 * degrades by shrinking the candidate pool, not by never favouring anything.
 */
export async function findIntentFunctionByEmbedding(need: string, limit: number = 8): Promise<IntentEntry[] | null> {
  if (vectors.size === 0 && !celiaIntentEmbeddingsReady()) { return null }
  // Same two-piece timing as VeraSdkEmbeddingCache.ets's findSdkFunctionByEmbedding
  // -- see its comment for why queryEmbedMs and scanMs are kept apart.
  let queryStartedAt = Date.now()
  let q = await embedOne(need)
  let queryEmbedMs = Date.now() - queryStartedAt
  if (q === null) { return null }

  let scanStartedAt = Date.now()
  let entries = allEntries()
  let scored: IntentEntry[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let e of entries) {
    let v = vectors.get(entryKey(e))
    if (v === undefined || v.length !== dimension) { continue }
    let dot = 0
    for (let d = 0; d < dimension; d++) { dot = dot + q[d] * v[d] }
    scores.set(entryKey(e), dot)
    scored.push(e)
  }
  // Celia tier: its own precomputed corpus, scanned natively against the
  // same query vector, filtered to what this device actually has through
  // the identical rule the token path uses (VeraIntentIndex.
  // celiaEntryIfInstalled) -- one filter, never two copies that could drift.
  let celiaScored = scoreCeliaCorpus(q)
  if (celiaScored !== null) {
    for (let cs of celiaScored) {
      let e = celiaEntryIfInstalled(cs.entry)
      if (e === null) { continue }
      scores.set(entryKey(e), cs.score)
      scored.push(e)
    }
  }
  scored.sort((a: IntentEntry, b: IntentEntry) => {
    let sa = scores.get(entryKey(a)) as number
    let sb = scores.get(entryKey(b)) as number
    return sb - sa
  })
  let scanMs = Date.now() - scanStartedAt

  hilog.info(DOMAIN, 'VERA', 'VERA-INTENT-EMBED-TIMING queryEmbedMs=' + queryEmbedMs.toString() +
    ' scanMs=' + scanMs.toString() + ' totalMs=' + (queryEmbedMs + scanMs).toString())

  return scored.slice(0, limit)
}
