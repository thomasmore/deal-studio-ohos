/**
 * Embedding index over the optional std/ui components, so the prompt can
 * describe only the ones a request needs (VeraUiCatalog.CORE_COMPONENTS are
 * always described and are not indexed).
 *
 * Same shape as VeraIntentEmbeddingCache.ets: a small JSON cache keyed by
 * identity, here the component name plus a hash of the text it was embedded
 * from, so editing a component's summary or guidance re-embeds that one
 * component and nothing else. About two dozen vectors: the scan is a plain
 * loop and the cost of a query is the embedding of the query itself.
 *
 * Every function degrades to "no answer" (null) when the embedding model is
 * not loaded, and the caller then describes the whole catalogue -- erring wide
 * costs prompt tokens, erring narrow costs a compile error.
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { ComponentSpec, optionalComponents, componentEmbeddingText } from './VeraUiCatalog'
import { embedBatch, embedOne, embeddingModelReady } from './VeraEmbeddings'

const DOMAIN = 0x0000
const CHUNK_SIZE = 8

/** name:hash -> L2-normalised vector. */
let vectors: Map<string, number[]> = new Map<string, number[]>()
let dimension = 0
let loadedFromDisk = false
let building: Promise<void> | null = null

function textHash(text: string): string {
  let h = 5381
  for (let i = 0; i < text.length; i++) { h = ((h * 33) ^ text.charCodeAt(i)) | 0 }
  return (h >>> 0).toString(16)
}

function componentKey(c: ComponentSpec): string {
  return c.name + ':' + textHash(componentEmbeddingText(c))
}

function cacheFilePath(filesDir: string): string { return filesDir + '/vera/ui-embeddings.json' }

export function uiEmbeddingsReady(): boolean {
  for (let c of optionalComponents()) {
    if (!vectors.has(componentKey(c))) { return false }
  }
  return vectors.size > 0
}

function readCache(filesDir: string): void {
  if (loadedFromDisk) { return }
  loadedFromDisk = true
  try {
    let stat = fs.statSync(cacheFilePath(filesDir))
    if (stat.size === 0) { return }
    let obj = JSON.parse(fs.readTextSync(cacheFilePath(filesDir))) as Record<string, Object>
    let dim = obj['dimension'] as number
    let rows = obj['vectors'] as Record<string, Object>
    if (rows === null || rows === undefined) { return }
    for (let key of Object.keys(rows)) {
      let v = rows[key] as number[]
      if (v.length === dim) { vectors.set(key, v) }
    }
    dimension = dim
    hilog.info(DOMAIN, 'VERA', 'VERA-UI-EMBED cache hit, ' + vectors.size.toString() + ' vectors')
  } catch (_e) {
    // No cache yet, or an unreadable one: start empty.
  }
}

function writeCache(filesDir: string): void {
  try {
    // Only what the catalogue still has, so a removed or reworded component
    // does not leave a stale vector behind.
    let live = new Set<string>()
    for (let c of optionalComponents()) { live.add(componentKey(c)) }
    let rows: Record<string, Object> = {}
    vectors.forEach((v: number[], key: string) => { if (live.has(key)) { rows[key] = v } })
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
    hilog.warn(DOMAIN, 'VERA', 'VERA-UI-EMBED cache write failed: ' + (e as Error).message)
  }
}

async function build(filesDir: string): Promise<void> {
  readCache(filesDir)
  let missing: ComponentSpec[] = []
  for (let c of optionalComponents()) {
    if (!vectors.has(componentKey(c))) { missing.push(c) }
  }
  if (missing.length === 0 || !embeddingModelReady()) { return }

  let startedAt = Date.now()
  let embedded = 0
  for (let start = 0; start < missing.length; start += CHUNK_SIZE) {
    let chunk = missing.slice(start, Math.min(start + CHUNK_SIZE, missing.length))
    let texts: string[] = []
    for (let c of chunk) { texts.push(componentEmbeddingText(c)) }
    let vecs = await embedBatch(texts)
    if (vecs === null) { break }
    for (let i = 0; i < chunk.length; i++) {
      let v = vecs[i]
      if (v.length === 0) { continue }
      if (dimension === 0) { dimension = v.length }
      if (v.length === dimension) {
        vectors.set(componentKey(chunk[i]), v)
        embedded++
      }
    }
  }
  if (embedded > 0) {
    hilog.info(DOMAIN, 'VERA', 'VERA-UI-EMBED embedded ' + embedded.toString() + ' of ' +
      missing.length.toString() + ' in ' + (Date.now() - startedAt).toString() + 'ms')
    writeCache(filesDir)
  }
}

/** Builds or loads the component vectors; safe to call again, coalesces with one in flight. */
export function ensureUiEmbeddings(filesDir: string): Promise<void> {
  if (building === null) {
    building = build(filesDir).then((): void => { building = null })
  }
  return building!
}

/**
 * The optional components that best match `need`, most similar first. Skips
 * names in `exclude` (already in the prompt) when given. null means the index
 * is not ready, and the caller falls back to the whole catalogue.
 */
export async function findUiComponentsByEmbedding(need: string, limit: number,
    exclude: Set<string> | null = null): Promise<string[] | null> {
  if (!uiEmbeddingsReady()) { return null }
  let q = await embedOne(need)
  if (q === null) { return null }
  let scored: string[] = []
  let scores: Map<string, number> = new Map<string, number>()
  for (let c of optionalComponents()) {
    if (exclude !== null && exclude.has(c.name)) { continue }
    let v = vectors.get(componentKey(c))
    if (v === undefined || v.length !== dimension) { continue }
    let dot = 0
    for (let d = 0; d < dimension; d++) { dot = dot + q[d] * v[d] }
    scores.set(c.name, dot)
    scored.push(c.name)
  }
  scored.sort((a: string, b: string) => (scores.get(b) as number) - (scores.get(a) as number))
  return scored.slice(0, limit)
}
