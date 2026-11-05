/**
 * Embedding cache for VeraSdkIndex's corpus (tools/build-sdk-index.py's
 * 16,511 entries) -- the piece EmbeddingGemma can't precompute host-side as
 * part of the normal build, because the model only runs through the native
 * llama.cpp binding (VeraEmbeddings.ets), which is device-only.
 *
 * Three sources, tried in order, cheapest first:
 *  1. {filesDir}/vera/sdk-embeddings.bin -- this device's own cache, from a
 *     previous run of step 2 or 3.
 *  2. The bundled rawfile of the same name (tools/build-sdk-embeddings.py,
 *     run host-side against the same corpus and the same GGUF, the same way
 *     tools/build-sdk-index.py already produces the bundled sdk-index.json)
 *     -- read once, then copied into (1) so every later launch takes the
 *     fast path without touching resourceManager again.
 *  3. Computed on-device, in the background, chunked (see CHUNK_SIZE) --
 *     the ~31-minute fallback for whenever (1) and (2) are both unusable
 *     (first run on a device with no network for the bundle... there isn't
 *     one, it's bundled; realistically this is for a corpus/model mismatch
 *     caught by the hashes below, or a build that skipped the host step).
 *
 * Recomputed whole, not incrementally: unlike the intent registry (up to
 * ~640 entries, changes as apps are installed -- see
 * VeraIntentEmbeddingCache.ets), sdk-index.json is a static, versioned
 * rawfile baked in at build time.
 *
 * A cache file (device-local or bundled) is rejected if either hash in its
 * header doesn't match what's expected right now: sourceHash over the
 * corpus's entry identities (sdk-index.json was rebuilt) or modelHash over
 * VeraEmbeddings.MODEL_FILE (the embedding model changed). Checking only the
 * corpus and not the model was a real gap in the first version of this file
 * -- a bundled or on-disk cache from a different model would have been
 * accepted silently, serving vectors from the wrong vector space with
 * nothing to catch it.
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { resourceManager } from '@kit.LocalizationKit'
import { SdkEntry, sdkIndexEntries, SdkTargetFilter } from './VeraSdkIndex'
import { embedBatch, embedOne, embeddingModelReady, MODEL_FILE } from './VeraEmbeddings'
import { nativeScanCorpus } from './LlamaEngine'

const DOMAIN = 0x0000
/** 'VSD1' as an int32 -- just a tag to reject a file that isn't this cache. */
const MAGIC = 0x56534431
/** Bumped because the header grew a field (modelHash) -- an old 5-int file
 * fails this check outright rather than being misread 4 bytes short. Bumped
 * again (4) when sdkEmbeddingText switched to the summary and the index
 * collapsed to one entry per function: neither hash covers the text, so
 * without this a cache built from the old text would still pass and quietly
 * serve the old vectors. */
const FORMAT_VERSION = 4
const HEADER_INTS = 6 // magic, version, count, dimension, source hash, model hash
const BUNDLED_RAWFILE = 'sdk-embeddings.bin'
/**
 * How many entries go into one native llamaEmbedBatch call. Measured on
 * device this session: ~145ms/entry, sequential (the native side decodes
 * one text at a time; see napi_llama.cpp's LlamaEmbedBatch). 8 keeps one
 * chunk's blocking native call around 1.2s -- comfortably under the 3s
 * THREAD_BLOCK_3S warning HarmonyOS's watchdog logs before a sustained 6s
 * block kills the process (confirmed on-device: a run with no inter-chunk
 * yield at all hit exactly that and was killed -- see
 * VeraEmbeddings.ets's embedBatch, which now yields to the event loop after
 * every call).
 */
const CHUNK_SIZE = 8

function sdkKey(e: SdkEntry): string { return e.kit + '.' + e.module + '.' + e.name }

function sdkEmbeddingText(e: SdkEntry): string {
  // Must match embedding_text in tools/build-sdk-embeddings.py exactly. The
  // summary replaces the description rather than joining it: on the gold set
  // the two together ranked worse at the top than the summary alone.
  let body = e.summary.length > 0 ? e.summary : e.description
  let parts: string[] = [e.kit, e.module, e.name, body]
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

/** Over entry identity only (kit.module.name), not their descriptions --
 * cheap, and sdk-index.json is rebuilt as a whole file, so a changed
 * description always comes with a changed entry set to key off of. */
function sourceHash(entries: SdkEntry[]): number {
  let h = 0x811c9dc5
  for (let e of entries) { h = fnv1a(sdkKey(e), h) }
  return h >>> 0
}

/** Over VeraEmbeddings.MODEL_FILE -- catches a cache built from a different
 * embedding model, which sourceHash alone never could (tools/
 * build-sdk-embeddings.py computes this exact same way). */
function modelHash(): number {
  return fnv1a(MODEL_FILE, 0x811c9dc5)
}

/** One L2-normalized vector per entry, in sdkIndexEntries() order, flattened. */
let vectors: Float32Array | null = null
let dimension = 0
let ready = false
let building: Promise<void> | null = null

export function sdkEmbeddingsReady(): boolean { return ready }

function cacheFilePath(filesDir: string): string { return filesDir + '/vera/sdk-embeddings.bin' }

/** What validateHeader trusts the payload with, once a header checks out. */
class HeaderShape {
  count: number = 0
  dim: number = 0
}

/** Validates a cache's header against the corpus and model expected right
 * now; returns the entry count and vector dimension to trust the payload
 * with, or null if anything about this file doesn't match. Shared between
 * the device-local cache and the bundled rawfile -- same format, same
 * rules, only the byte source differs. */
function validateHeader(header: Int32Array, entries: SdkEntry[]): HeaderShape | null {
  // >>> 0 on every header read, not just the two hash fields: Int32Array
  // reads a 32-bit pattern as *signed*, but fnv1a/sourceHash/modelHash all
  // return the unsigned interpretation of that same pattern (their own
  // `>>> 0`). A hash at or above 0x80000000 -- modelHash is one, confirmed
  // on-device this session -- reads back negative from the array and can
  // never equal the positive value the hash functions return, rejecting a
  // header that is actually byte-for-byte correct.
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

function readCache(filesDir: string, entries: SdkEntry[]): boolean {
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

/**
 * The bundled rawfile, built host-side by tools/build-sdk-embeddings.py
 * against the same sdk-index.json and the same GGUF, so a fresh install
 * skips the ~31-minute on-device build entirely. Tried only when the
 * device-local cache (readCache) misses; on success, also written to the
 * device-local path so the next launch doesn't need resourceManager again.
 */
async function readBundledCache(mgr: resourceManager.ResourceManager, filesDir: string,
    entries: SdkEntry[]): Promise<boolean> {
  try {
    // getRawFileContent returns a Uint8Array, not an ArrayBuffer -- and its
    // own .buffer isn't guaranteed to start at byte 0 (byteOffset could be
    // nonzero). .slice() always returns a fresh Uint8Array backed by its own
    // buffer at offset 0, which is what a typed-array view over it needs.
    let data = await mgr.getRawFileContent(BUNDLED_RAWFILE)
    if (data.byteLength < HEADER_INTS * 4) { return false }
    let header = new Int32Array(data.slice(0, HEADER_INTS * 4).buffer)
    let valid = validateHeader(header, entries)
    if (valid === null) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-SDK-EMBED bundled cache present but stale -- corpus or model changed since it was built')
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
    hilog.warn(DOMAIN, 'VERA', 'VERA-SDK-EMBED no usable bundled cache: ' + (e as Error).message)
    return false
  }
}

function writeCache(filesDir: string, entries: SdkEntry[], dim: number, flat: Float32Array): void {
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
    hilog.warn(DOMAIN, 'VERA', 'VERA-SDK-EMBED cache write failed: ' + (e as Error).message)
  }
}

async function build(filesDir: string, mgr: resourceManager.ResourceManager): Promise<void> {
  let entries = sdkIndexEntries()
  if (entries.length === 0) { return }
  if (readCache(filesDir, entries)) {
    hilog.info(DOMAIN, 'VERA', 'VERA-SDK-EMBED cache hit, ' + entries.length.toString() +
      ' vectors, dim=' + dimension.toString())
    return
  }
  if (await readBundledCache(mgr, filesDir, entries)) {
    hilog.info(DOMAIN, 'VERA', 'VERA-SDK-EMBED bundled cache hit, ' + entries.length.toString() +
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
    for (let e of chunk) { texts.push(sdkEmbeddingText(e)) }
    let chunkStartedAt = Date.now()
    let vecs = await embedBatch(texts)
    if (vecs === null) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-SDK-EMBED build aborted at ' + start.toString() +
        '/' + entries.length.toString() + ' -- embedding became unavailable')
      return
    }
    // Every ~50 chunks, not every one -- enough to watch real cadence
    // (confirm chunks are genuinely spaced out, not a replay of the
    // continuous-block freeze this logging helped catch) without flooding
    // hilog over a ~16,511-entry build.
    if (start === 0 || (start / CHUNK_SIZE) % 50 === 0) {
      hilog.info(DOMAIN, 'VERA', 'VERA-SDK-EMBED progress ' + start.toString() + '/' + entries.length.toString() +
        ' chunk ' + (Date.now() - chunkStartedAt).toString() + 'ms total ' + (Date.now() - startedAt).toString() + 'ms')
    }
    for (let v of vecs) {
      if (dim === 0 && v.length > 0) { dim = v.length }
      if (dim > 0 && v.length === dim) {
        for (let x of v) { flatList.push(x) }
      } else {
        // A single entry's text failed to embed (too long, decode error) --
        // zero vector, so it scores 0 against every query and simply never
        // surfaces, rather than corrupting every later entry's offset.
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
  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-EMBED built ' + entries.length.toString() +
    ' vectors, dim=' + dim.toString() + ' in ' + (Date.now() - startedAt).toString() + 'ms')
  writeCache(filesDir, entries, dim, flat)
}

/**
 * Kicks off the cache build (or disk load), fire-and-forget safe from
 * GeneratePage.ets -- and safe to call again later, the same "coalesce with
 * one in flight, not with one already finished" shape
 * VeraIntentEmbeddingCache.ets's ensureIntentEmbeddings uses, for the same
 * reason: loadSdkIndex()'s own rawfile read is a separate, independent
 * async operation with no ordering guarantee against this one, and this
 * call can genuinely run before it finishes -- confirmed on-device this
 * session (entries.length was still 0, so build() took its very first
 * early-return and never actually started embedding anything).
 */
export function ensureSdkEmbeddings(filesDir: string, mgr: resourceManager.ResourceManager): Promise<void> {
  if (building === null) {
    building = build(filesDir, mgr).then((): void => { building = null })
  }
  return building!
}

/**
 * The top `limit` sdk candidates for `need` by cosine similarity alone --
 * null means "not ready" (cache still building, or embedding unavailable
 * this session), which DeepSeekEngine.ets treats as "fall back to
 * findSdkFunction", never as an error. Compares the query against the
 * *whole* corpus, not a token-prefiltered shortlist -- the whole point,
 * since the motivating failures (VeraSdkIndex.ets's doc comment) share zero
 * tokens with their correct answer and would never reach a shortlist built
 * that way.
 */
export async function findSdkFunctionByEmbedding(need: string, limit: number = 8,
    only: SdkTargetFilter | null = null): Promise<SdkEntry[] | null> {
  if (!ready || vectors === null) { return null }
  // Timed in two pieces, not one -- "how long did this take" conflates two
  // very different costs: a live model inference to embed the query
  // (queryEmbedMs, the same cost token search never pays at all) and a pure
  // in-memory scan over 16,511 cached vectors (scanMs). Reported separately
  // so a benchmark can say which one actually dominates.
  let queryStartedAt = Date.now()
  let q = await embedOne(need)
  let queryEmbedMs = Date.now() - queryStartedAt
  if (q === null) { return null }
  let entries = sdkIndexEntries()
  if (entries.length * dimension !== vectors!.length) { return null }

  let scanStartedAt = Date.now()
  // Dot product against all 16,511 cached vectors, done in native C++
  // (napi_llama.cpp's LlamaScanCorpus) rather than an ArkTS loop -- the
  // same ~12.7M multiply-adds, previously measured at ~584ms interpreted
  // in ArkTS (docs/embeddings-benchmark.md's timing section).
  let scores: Float32Array = nativeScanCorpus(q, vectors!, dimension, entries.length)
  let idx: number[] = []
  for (let i = 0; i < entries.length; i++) { idx.push(i) }
  idx.sort((a: number, b: number) => scores[b] - scores[a])
  let scanMs = Date.now() - scanStartedAt

  hilog.info(DOMAIN, 'VERA', 'VERA-SDK-EMBED-TIMING queryEmbedMs=' + queryEmbedMs.toString() +
    ' scanMs=' + scanMs.toString() + ' totalMs=' + (queryEmbedMs + scanMs).toString())

  // The filter applies after scoring, so the scan stays one native pass over
  // the whole cache; the top `limit` are taken from what passes.
  let out: SdkEntry[] = []
  for (let i = 0; i < idx.length && out.length < limit; i++) {
    let e = entries[idx[i]]
    if (only !== null && !only!(e.kit + '.' + e.module + '.' + e.name)) { continue }
    out.push(e)
  }
  return out
}
