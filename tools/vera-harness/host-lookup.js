// The phone's function lookup (find_intent_function / find_sdk_function, DeepSeekEngine.ets's discoveryToolResult) on the
// host: the app's own index, embedding and merge code, with stand-ins only for what a phone alone has.
//
//   const lookup = require('./host-lookup')
//   lookup.install({phoneFiles, llamaEmbedding})   // before the first loadVera of anything
//   await lookup.ready()
//   const text = await lookup.find('find_sdk_function', need, false)
//
// Stand-ins (source-loader.js's globalThis.__veraModules):
//   libllama.so          a query is embedded by the host build of llama-embedding with the phone's own model, mean pooling
//                        and L2 norm (as tools/build-sdk-embeddings.py builds the bundled vectors); corpus scoring in JS
//   @kit.LocalizationKit rawfiles from entry/src/main/resources/rawfile
//   @kit.CoreFileKit     the app's filesDir is `phoneFiles` (models/, vera/ pulled from the phone); writes go to an
//                        overlay next to it, never into the copy
//   @kit.AbilityKit      insightIntentDriver answers with phoneFiles/intent-registry.json (the phone's own answer,
//                        VeraIntentRegistry.ets's "registry" trace event)
//
//   node tools/vera-harness/host-lookup.js --phone-files DIR --check TRACE_OR_DIR...   compares with the phone's own
//   answers ("lookup" trace events) and prints each that differs.
'use strict'
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const {execFileSync} = require('node:child_process')

const repo = path.join(__dirname, '../..')
const RAWFILE = path.join(repo, 'entry/src/main/resources/rawfile')
const FILES_DIR = '/host-lookup/files'

let phoneFiles = ''
let overlay = ''
let llamaEmbedding = ''
let modelPath = ''
let queryCache = null
let queryCacheFile = ''

/** A phone path under filesDir as a host path: the overlay when something was written there, else the pulled copy. */
function hostPath(p, writing) {
  if (!p.startsWith(FILES_DIR + '/')) throw Error('host-lookup: a path outside filesDir: ' + p)
  const rel = p.slice(FILES_DIR.length + 1)
  const written = path.join(overlay, rel)
  if (writing || fs.existsSync(written)) return written
  return path.join(phoneFiles, rel)
}

const OpenMode = {READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000, APPEND: 0o2000}
const open = new Map()
let nextFd = 100
const fileIo = {
  OpenMode,
  statSync(p) { const s = fs.statSync(hostPath(p, false)); return {size: s.size, isDirectory: () => s.isDirectory(), isFile: () => s.isFile()} },
  accessSync(p) { return fs.existsSync(hostPath(p, false)) },
  openSync(p, mode = 0) {
    const writing = (mode & 3) !== 0
    const host = hostPath(p, writing)
    if (writing) fs.mkdirSync(path.dirname(host), {recursive: true})
    const flags = writing ? ((mode & OpenMode.TRUNC) ? 'w' : (mode & OpenMode.APPEND) ? 'a' : 'r+') : 'r'
    const fd = nextFd++
    open.set(fd, {fd: fs.openSync(host, flags), position: 0})
    return {fd, path: p}
  },
  readSync(fd, buffer, options) {
    const f = open.get(fd)
    const view = Buffer.from(buffer)
    const at = options && options.offset !== undefined ? options.offset : f.position
    const n = fs.readSync(f.fd, view, 0, options && options.length !== undefined ? options.length : view.length, at)
    if (!(options && options.offset !== undefined)) f.position += n
    return n
  },
  writeSync(fd, data) {
    const f = open.get(fd)
    const bytes = typeof data === 'string' ? Buffer.from(data, 'utf8') : Buffer.from(data)
    return fs.writeSync(f.fd, bytes)
  },
  closeSync(file) { const fd = typeof file === 'number' ? file : file.fd; const f = open.get(fd); if (f) { fs.closeSync(f.fd); open.delete(fd) } },
  readTextSync(p) { return fs.readFileSync(hostPath(p, false), 'utf8') },
  mkdirSync(p) { fs.mkdirSync(hostPath(p, true), {recursive: true}) },
  unlinkSync(p) { const h = hostPath(p, true); if (fs.existsSync(h)) fs.unlinkSync(h) },
  renameSync(a, b) { fs.renameSync(hostPath(a, true), hostPath(b, true)) },
}

const resourceManager = {
  async getRawFileContent(name) { return new Uint8Array(fs.readFileSync(path.join(RAWFILE, name))) },
}

/** One embedding per text, as the phone's napi_llama.cpp makes it; queries are cached on disk across runs. */
function embed(texts) {
  const out = new Array(texts.length)
  const missing = []
  texts.forEach((t, i) => { const v = queryCache.get(t); if (v) out[i] = v; else missing.push(i) })
  if (missing.length > 0) {
    if (missing.length > 64) {
      // The app asks for a whole corpus only when every cached copy of its vectors is stale: on the host that would be
      // a long silent job, and it means the copies pulled from the phone are not the ones it uses.
      throw Error('host-lookup: asked to embed ' + missing.length + ' texts at once, a corpus rebuild; pull the phone\'s caches again')
    }
    const file = path.join(os.tmpdir(), 'host-lookup-' + process.pid + '-' + crypto.randomBytes(4).toString('hex') + '.txt')
    // llama-embedding reads one prompt per line.
    fs.writeFileSync(file, missing.map(i => texts[i].split('\n').join(' ')).join('\n'))
    let stdout
    try {
      stdout = execFileSync(llamaEmbedding, ['-m', modelPath, '-f', file, '--pooling', 'mean', '--embd-normalize', '2',
        '--embd-output-format', 'array', '-c', '512', '-t', '4'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 1 << 28})
    } finally { fs.unlinkSync(file) }
    const line = stdout.split('\n').find(l => l.trim().startsWith('['))
    if (!line) throw Error('host-lookup: no vectors from llama-embedding')
    const vecs = JSON.parse(line)
    if (vecs.length !== missing.length) throw Error('host-lookup: ' + vecs.length + ' vectors for ' + missing.length + ' texts')
    missing.forEach((i, k) => { out[i] = vecs[k]; queryCache.set(texts[i], vecs[k]) })
    fs.writeFileSync(queryCacheFile, JSON.stringify(Object.fromEntries(queryCache)))
  }
  return out
}

const nativeLlama = {
  async llamaEmbedInit() { return true },
  async llamaEmbedBatch(texts) { return embed(texts) },
  llamaBuildInfo() { return 'host llama-embedding' },
  llamaEmbedFree() {},
  llamaScanCorpus(query, corpus, dimension, count) {
    const scores = new Float32Array(count)
    for (let r = 0; r < count; r++) {
      let s = 0
      const base = r * dimension
      for (let d = 0; d < dimension; d++) s += query[d] * corpus[base + d]
      scores[r] = s
    }
    return scores
  },
}

/** Registers the stand-ins. Must run before the first loadVera of any module that imports them. */
function install(options) {
  phoneFiles = path.resolve(options.phoneFiles)
  overlay = path.resolve(options.overlay || path.join(phoneFiles, '..', path.basename(phoneFiles) + '-overlay'))
  llamaEmbedding = options.llamaEmbedding || path.join(repo, 'entry/src/main/cpp/llama.cpp/build-host/bin/llama-embedding')
  const {MODEL_FILE} = {MODEL_FILE: 'embeddinggemma-300m-q4_k_m.gguf'}
  modelPath = path.join(phoneFiles, 'models', MODEL_FILE)
  for (const [what, p] of [['the phone\'s files', phoneFiles], ['llama-embedding', llamaEmbedding], ['the embedding model', modelPath],
    ['the phone\'s intent registry', path.join(phoneFiles, 'intent-registry.json')]]) {
    if (!fs.existsSync(p)) throw Error('host-lookup: ' + what + ' not found at ' + p)
  }
  queryCacheFile = path.join(overlay, 'query-embeddings.json')
  fs.mkdirSync(overlay, {recursive: true})
  queryCache = new Map(fs.existsSync(queryCacheFile) ? Object.entries(JSON.parse(fs.readFileSync(queryCacheFile, 'utf8'))) : [])
  const registry = JSON.parse(fs.readFileSync(path.join(phoneFiles, 'intent-registry.json'), 'utf8'))
  globalThis.__veraModules = Object.assign(globalThis.__veraModules || {}, {
    // `import nativeLlama from 'libllama.so'` compiles to require(...).default.
    'libllama.so': Object.assign({default: nativeLlama}, nativeLlama),
    '@kit.LocalizationKit': {resourceManager},
    '@kit.CoreFileKit': {fileIo},
    '@kit.ArkTS': {util: {TextDecoder: {create: () => ({decodeToString: bytes => Buffer.from(bytes).toString('utf8')})},
      TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')) } }}},
    '@kit.AbilityKit': {insightIntentDriver: {GetInsightIntentFlag: {GET_FULL_INSIGHT_INTENT: 1, GET_SUMMARY_INSIGHT_INTENT: 2},
      getAllInsightIntentInfo: async () => registry}},
  })
}

let readiness = null
/** Loads what the phone loads before a lookup (VeraDiscovery.ets, then VeraCapabilities.ets's warmEmbeddings). */
function ready() {
  if (readiness !== null) return readiness
  const {loadVera} = require('./source-loader')
  readiness = (async () => {
    await loadVera('VeraDiscovery').loadDiscovery(FILES_DIR, resourceManager)
    if (!await loadVera('VeraEmbeddings').loadEmbeddingModel(FILES_DIR)) throw Error('host-lookup: the embedding model did not load')
    await Promise.all([
      loadVera('VeraSdkEmbeddingCache').ensureSdkEmbeddings(FILES_DIR, resourceManager),
      loadVera('VeraIntentEmbeddingCache').ensureIntentEmbeddings(FILES_DIR, resourceManager),
      loadVera('VeraCeliaIntentEmbeddingCache').ensureCeliaIntentEmbeddings(FILES_DIR, resourceManager),
    ])
    const state = {
      sdk: loadVera('VeraSdkEmbeddingCache').sdkEmbeddingsReady(),
      intent: loadVera('VeraIntentEmbeddingCache').intentEmbeddingsReady(),
      celia: loadVera('VeraCeliaIntentEmbeddingCache').celiaIntentEmbeddingsReady(),
      registry: loadVera('VeraIntentRegistry').registrySize(),
    }
    if (!state.sdk || !state.intent || !state.celia || state.registry === 0) throw Error('host-lookup: not ready ' + JSON.stringify(state))
    return state
  })()
  return readiness
}

/** What the phone's lookup answers for one query, as DeepSeekEngine.ets's discoveryToolResult gives it. */
async function find(tool, query, both) {
  await ready()
  const {loadVera} = require('./source-loader')
  return loadVera('DeepSeekEngine').discoveryToolResult(tool, query, 0, both)
}

module.exports = {install, ready, find}

if (require.main === module) {
  const args = process.argv.slice(2)
  const at = args.indexOf('--phone-files')
  const check = args.indexOf('--check')
  if (at < 0 || check < 0) { console.error('usage: host-lookup.js --phone-files DIR --check TRACE_OR_DIR...'); process.exit(2) }
  install({phoneFiles: args[at + 1]})
  const traces = p => fs.statSync(p).isFile() ? [p] : fs.readdirSync(p, {withFileTypes: true})
    .flatMap(e => e.isDirectory() ? traces(path.join(p, e.name)) : e.name === 'trace.jsonl' ? [path.join(p, e.name)] : [])
  const cases = args.slice(check + 1).filter(a => a !== args[at + 1] && a !== '--phone-files').flatMap(traces)
    .flatMap(f => fs.readFileSync(f, 'utf8').split('\n').filter(l => l.includes('"event":"lookup"')).map(l => JSON.parse(l)))
  const targets = text => (text.match(/"target"\s*:\s*"([^"]+)"/g) || []).map(m => m.replace(/.*"([^"]+)"$/, '$1'))
  ;(async () => {
    console.log('ready', JSON.stringify(await ready()))
    // The phone embeds on ARM and the host on x86: near-tied scores can swap places, so besides identical text the
    // check counts the same first answer and how much of the list is the same.
    let same = 0, sameOrder = 0, sameFirst = 0, overlap = 0
    for (const c of cases) {
      const text = await find(c.tool, c.query, c.both)
      const a = targets(c.text), b = targets(text)
      if (text === c.text) same++
      if (JSON.stringify(a) === JSON.stringify(b)) sameOrder++
      if (a[0] === b[0]) sameFirst++
      const common = a.filter(t => b.includes(t)).length
      overlap += a.length + b.length === 0 ? 1 : common / Math.max(a.length, b.length)
      if (a[0] !== b[0] || common < Math.max(a.length, b.length) - 2) {
        console.log('DIFF', c.tool, JSON.stringify(c.query.slice(0, 80)), '\n  phone:', a.slice(0, 6).join(' '), '\n  host: ', b.slice(0, 6).join(' '))
      }
    }
    const n = cases.length
    console.log(`${n} lookups: identical text ${same}, same targets in order ${sameOrder}, same first ${sameFirst}, ` +
      `mean overlap ${(overlap / n * 100).toFixed(1)}%`)
  })().catch(e => { console.error(e); process.exit(1) })
}
