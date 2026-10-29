/**
 * Embedding cache for VeraCeliaIntentIndex's corpus (tools/build-celia-
 * intent-index.py's ~680 entries) -- a structural copy of
 * VeraSdkEmbeddingCache.ets: same three-source load order, same header/hash
 * format, same chunked on-device fallback. See that file's doc comment for
 * why each source exists and in what order.
 *
 * The celia corpus doesn't vary per device (celia's own tool catalogue is
 * the same regardless of what's installed), so, like the SDK surface, it is
 * embedded whole and offline -- not the per-device key->vector shape
 * VeraIntentEmbeddingCache.ets uses for the old, device-db-driven intent
 * summaries, which genuinely does vary (a device's own registry size).
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { resourceManager } from '@kit.LocalizationKit'
import { CeliaIntentEntry, celiaIntentIndexEntries } from './VeraCeliaIntentIndex'
import { embedBatch, embedOne, embeddingModelReady, MODEL_FILE } from './VeraEmbeddings'
import { nativeScanCorpus } from './LlamaEngine'

const DOMAIN = 0x0000
/** 'VCI1' as an int32 -- just a tag to reject a file that isn't this cache. */
const MAGIC = 0x56434931
const FORMAT_VERSION = 1
const HEADER_INTS = 6 // magic, version, count, dimension, source hash, model hash
const BUNDLED_RAWFILE = 'celia-intent-embeddings.bin'
/** Same measured per-entry native cost VeraSdkEmbeddingCache.ets's own
 * comment documents -- see that file for the ~145ms/entry, THREAD_BLOCK_3S
 * reasoning behind this exact number. */
const CHUNK_SIZE = 8

function celiaKey(e: CeliaIntentEntry): string { return e.bundle + '/' + e.intentName }

function celiaEmbeddingText(e: CeliaIntentEntry): string {
  // Must match embedding_text in tools/build-celia-intent-embeddings.py exactly.
  let parts: string[] = [e.bundle, e.intentName, e.name, e.description]
  return parts.filter((p: string): boolean => p.length > 0).join(' ')
}

function fnv1a(s: string, seed: number): number {
  let h = seed
  for (let i = 0; i < s.length; i++) {
    h = h ^ s.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return h >>> 0
}

function sourceHash(entries: CeliaIntentEntry[]): number {
  let h = 0x811c9dc5
  for (let e of entries) { h = fnv1a(celiaKey(e), h) }
  return h >>> 0
}

function modelHash(): number {
  return fnv1a(MODEL_FILE, 0x811c9dc5)
}

let vectors: Float32Array | null = null
let dimension = 0
let ready = false
let building: Promise<void> | null = null

export function celiaIntentEmbeddingsReady(): boolean { return ready }

function cacheFilePath(filesDir: string): string { return filesDir + '/vera/celia-intent-embeddings.bin' }

class HeaderShape {
  count: number = 0
  dim: number = 0
}

function validateHeader(header: Int32Array, entries: CeliaIntentEntry[]): HeaderShape | null {
  // See VeraSdkEmbeddingCache.ets's own validateHeader for why every header
  // field is read through `>>> 0`, not just the hashes.
  if ((header[0] >>> 0) !== MAGIC) { return null }
  if ((header[1] >>> 0) !== FORMAT_VERSION) { return null }
  let count = header[2] >>> 0
  let dim = header[3] >>> 0
  if (count !== entries.length) { return null }
  if ((header[4] >>> 0) !== sourceHash(entries)) { return null }
  if ((header[5] >>> 0) !== modelHash()) { return null }
  let result = new HeaderShape()
  result.count = count
  result.dim = dim
  return result
}

function readCache(filesDir: string, entries: CeliaIntentEntry[]): boolean {
  let path = cacheFilePath(filesDir)
  try {
    let stat = fs.statSync(path)
    if (stat.size < HEADER_INTS * 4) { return false }
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY)
    try {
      let headerBuf = new ArrayBuffer(HEADER_INTS * 4)
      fs.readSync(file.fd, headerBuf)
      let valid = validateHeader(new Int32Array(headerBuf), entries)
      if (valid === null) { return false }
      let payloadBytes = valid.count * valid.dim * 4
      if (stat.size < HEADER_INTS * 4 + payloadBytes) { return false }
      let payloadBuf = new ArrayBuffer(payloadBytes)
      fs.readSync(file.fd, payloadBuf)
      vectors = new Float32Array(payloadBuf)
      dimension = valid.dim
      ready = true
      return true
    } finally {
      fs.closeSync(file)
    }
  } catch (_e) {
    return false
  }
}

async function readBundledCache(mgr: resourceManager.ResourceManager, filesDir: string,
    entries: CeliaIntentEntry[]): Promise<boolean> {
  try {
    let data = await mgr.getRawFileContent(BUNDLED_RAWFILE)
    if (data.byteLength < HEADER_INTS * 4) { return false }
    let header = new Int32Array(data.slice(0, HEADER_INTS * 4).buffer)
    let valid = validateHeader(header, entries)
    if (valid === null) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-CELIA-EMBED bundled cache present but stale -- corpus or model changed since it was built')
      return false
    }
    let payloadBytes = valid.count * valid.dim * 4
    if (data.byteLength < HEADER_INTS * 4 + payloadBytes) { return false }
    let flat = new Float32Array(data.slice(HEADER_INTS * 4, HEADER_INTS * 4 + payloadBytes).buffer)
    vectors = flat
    dimension = valid.dim
    ready = true
    writeCache(filesDir, entries, valid.dim, flat)
    return true
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-CELIA-EMBED no usable bundled cache: ' + (e as Error).message)
    return false
  }
}

function writeCache(filesDir: string, entries: CeliaIntentEntry[], dim: number, flat: Float32Array): void {
  try {
    let file = fs.openSync(cacheFilePath(filesDir),
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try {
      let headerBuf = new ArrayBuffer(HEADER_INTS * 4)
      let header = new Int32Array(headerBuf)
      header[0] = MAGIC
      header[1] = FORMAT_VERSION
      header[2] = entries.length
      header[3] = dim
      header[4] = sourceHash(entries)
      header[5] = modelHash()
      fs.writeSync(file.fd, headerBuf)
      fs.writeSync(file.fd, flat.buffer)
    } finally {
      fs.closeSync(file)
    }
  } catch (e) {
    hilog.warn(DOMAIN, 'VERA', 'VERA-CELIA-EMBED cache write failed: ' + (e as Error).message)
  }
}

async function build(filesDir: string, mgr: resourceManager.ResourceManager): Promise<void> {
  let entries = celiaIntentIndexEntries()
  if (entries.length === 0) { return }
  if (readCache(filesDir, entries)) {
    hilog.info(DOMAIN, 'VERA', 'VERA-CELIA-EMBED cache hit, ' + entries.length.toString() +
      ' vectors, dim=' + dimension.toString())
    return
  }
  if (await readBundledCache(mgr, filesDir, entries)) {
    hilog.info(DOMAIN, 'VERA', 'VERA-CELIA-EMBED bundled cache hit, ' + entries.length.toString() +
      ' vectors, dim=' + dimension.toString())
    return
  }
  if (!embeddingModelReady()) { return }

  let dim = 0
  let flatList: number[] = []
  let startedAt = Date.now()
  for (let start = 0; start < entries.length; start += CHUNK_SIZE) {
    let chunk = entries.slice(start, Math.min(start + CHUNK_SIZE, entries.length))
    let texts: string[] = []
    for (let e of chunk) { texts.push(celiaEmbeddingText(e)) }
    let chunkStartedAt = Date.now()
    let vecs = await embedBatch(texts)
    if (vecs === null) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-CELIA-EMBED build aborted at ' + start.toString() +
        '/' + entries.length.toString() + ' -- embedding became unavailable')
      return
    }
    if (start === 0 || (start / CHUNK_SIZE) % 50 === 0) {
      hilog.info(DOMAIN, 'VERA', 'VERA-CELIA-EMBED progress ' + start.toString() + '/' + entries.length.toString() +
        ' chunk ' + (Date.now() - chunkStartedAt).toString() + 'ms total ' + (Date.now() - startedAt).toString() + 'ms')
    }
    for (let v of vecs) {
      if (dim === 0 && v.length > 0) { dim = v.length }
      if (dim > 0 && v.length === dim) {
        for (let x of v) { flatList.push(x) }
      } else {
        for (let i = 0; i < dim; i++) { flatList.push(0) }
      }
    }
  }
  if (dim === 0) { return }

  let flat = new Float32Array(flatList.length)
  for (let i = 0; i < flatList.length; i++) { flat[i] = flatList[i] }
  vectors = flat
  dimension = dim
  ready = true
  hilog.info(DOMAIN, 'VERA', 'VERA-CELIA-EMBED built ' + entries.length.toString() +
    ' vectors, dim=' + dim.toString() + ' in ' + (Date.now() - startedAt).toString() + 'ms')
  writeCache(filesDir, entries, dim, flat)
}

/** Fire-and-forget safe from GeneratePage.ets, same coalescing shape
 * VeraSdkEmbeddingCache.ets's ensureSdkEmbeddings uses. */
export function ensureCeliaIntentEmbeddings(filesDir: string, mgr: resourceManager.ResourceManager): Promise<void> {
  if (building === null) {
    building = build(filesDir, mgr).then((): void => { building = null })
  }
  return building!
}

/** One celia entry and its raw cosine score against an already-embedded query. */
export class CeliaScored {
  entry: CeliaIntentEntry = new CeliaIntentEntry()
  score: number = 0
}

/**
 * Scores the whole celia corpus against a query vector someone else already
 * computed -- synchronous, and deliberately not folded into
 * findCeliaIntentFunctionByEmbedding below, so VeraIntentEmbeddingCache.ets's
 * merged search can call embedOne once for both tiers instead of once each.
 * null means "not ready" (cache still building, model unavailable, or a
 * corpus/dimension mismatch), the same contract every embedding path here
 * uses for "fall back to token search", never an error.
 */
export function scoreCeliaCorpus(q: number[]): CeliaScored[] | null {
  if (!ready || vectors === null) { return null }
  let entries = celiaIntentIndexEntries()
  if (entries.length * dimension !== vectors!.length) { return null }
  let scores: Float32Array = nativeScanCorpus(q, vectors!, dimension, entries.length)
  let out: CeliaScored[] = []
  for (let i = 0; i < entries.length; i++) {
    let s = new CeliaScored()
    s.entry = entries[i]
    s.score = scores[i]
    out.push(s)
  }
  return out
}

/**
 * The top `limit` celia candidates for `need` by cosine similarity, over
 * the *whole* corpus, standalone (embeds its own query) -- the parity
 * function VeraSdkEmbeddingCache.ets's own findSdkFunctionByEmbedding is,
 * not what VeraIntentEmbeddingCache.ets's merged search actually calls (see
 * scoreCeliaCorpus above). Null means "not ready".
 */
export async function findCeliaIntentFunctionByEmbedding(need: string, limit: number): Promise<CeliaIntentEntry[] | null> {
  let q = await embedOne(need)
  if (q === null) { return null }
  let scored = scoreCeliaCorpus(q)
  if (scored === null) { return null }
  scored.sort((a: CeliaScored, b: CeliaScored) => b.score - a.score)
  let out: CeliaIntentEntry[] = []
  for (let i = 0; i < scored.length && i < limit; i++) { out.push(scored[i].entry) }
  return out
}
