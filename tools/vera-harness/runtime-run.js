// What a running program asks the model, live on the host as the phone asks it, every model request recorded by model-tap.js:
//   live  -- a figure as it is now: the source finder at generation (VeraSourceFind.ets's findSource with SourceAppCalls.ets's
//            calls: the search, DeepSeek, the GET), then Vera.Live.fetch (VeraLive.ets: a search and the model reading it);
//   ask   -- words for the person: Vera.Ask.text (VeraAsk.ets).
// The search is Exa ($EXA_API_KEY), the model DeepSeek ($ARKESTR_API_KEY).
//
//   node tools/vera-harness/runtime-run.js -o OUTDIR -p ITEMS.tsv [-j JOBS] [label ...]
//
// ITEMS.tsv is vera-tuning's prompts/batches/rtNN-runtime.tsv (family<TAB>label<TAB>live<TAB>figure, or
// family<TAB>label<TAB>ask<TAB>maxWords<TAB>prompt). Writes OUTDIR/<label>/asks.jsonl: the asks (tasks source-find,
// live-read, ask-text) and one event of how it ended (kind source, live or ask).
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const args = process.argv.slice(2)
const option = (flag, fallback) => { const i = args.indexOf(flag); if (i < 0) return fallback; const v = args[i + 1]; args.splice(i, 2); return v }
const out = option('-o', '')
const itemFile = option('-p', '')
const jobs = Number(option('-j', '4'))
if (!out || !itemFile) { console.error('usage: runtime-run.js -o OUTDIR -p ITEMS.tsv [-j JOBS] [label ...]'); process.exit(2) }

const tap = require('./model-tap')
tap.install()
const {loadVera} = require('./source-loader')
const {settings} = loadVera('SettingsStore')
Object.assign(settings, {hasExaKey: () => Boolean(process.env.EXA_API_KEY), getExaKey: () => process.env.EXA_API_KEY || '', hasApiKey: () => true,
  getApiKey: () => process.env.ARKESTR_API_KEY || '', getBaseUrl: () => 'https://api.deepseek.com', getModel: () => 'deepseek-flash'})
const {findSource} = loadVera('VeraSourceFind')
const {appSourceCalls} = loadVera('SourceAppCalls')
const {liveNeed} = loadVera('LiveBlock')
const {SketchLive} = loadVera('VeraCompose')
const {liveFetch} = loadVera('VeraLive')
const {askText, resetAsk} = loadVera('VeraAsk')

const items = fs.readFileSync(itemFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith('#')).map(l => l.split('\t'))
  .filter(([, label]) => !args.length || args.includes(label))

async function live(log, figure) {
  const want = Object.assign(new SketchLive(), {id: 'figure', label: figure, means: figure, query: figure})
  log.task = 'source-find'
  const found = await tap.run(log, () => findSource(liveNeed('Show ' + figure + ' as it is now', [want]), appSourceCalls()))
  log.asks.push({kind: 'source', seq: log.seq++, ok: found.spec !== null, spec: found.spec, tried: found.tried})
  log.task = 'live-read'
  const answer = await tap.run(log, () => liveFetch(new Map([['query', figure], ['labels', figure]])))
  log.asks.push({kind: 'live', seq: log.seq++, labels: [figure], answer})
  return (found.spec !== null ? 'source found' : 'no source') + ', live ' + answer.split('\n')[0].slice(0, 60)
}

async function words(log, maxWords, prompt) {
  log.task = 'ask-text'
  // The per-minute cap is the person's key guarded against one program; the harness asks for many programs at once.
  resetAsk()
  const answer = await tap.run(log, () => askText(new Map([['prompt', prompt], ['maxWords', String(maxWords)]])))
  log.asks.push({kind: 'ask-result', seq: log.seq++, prompt, maxWords: Number(maxWords), answer})
  return answer.startsWith('error') ? answer : answer.split(/\s+/).length + ' words'
}

async function one([family, label, kind, a, b]) {
  const dir = path.join(out, label)
  fs.mkdirSync(dir, {recursive: true})
  const log = {asks: [], seq: 0}
  let said = ''
  try { said = kind === 'live' ? await live(log, a) : await words(log, a, b) } catch (e) { log.asks.push({kind: 'error', seq: log.seq++, error: e.message}); said = 'ERROR ' + e.message }
  fs.writeFileSync(path.join(dir, 'asks.jsonl'), log.asks.map(x => JSON.stringify(Object.assign({label, family}, x)) + '\n').join(''))
  console.log(label.padEnd(30), said.slice(0, 140))
}

;(async () => {
  fs.mkdirSync(out, {recursive: true})
  const queue = items.slice()
  await Promise.all(Array.from({length: Math.min(jobs, queue.length)}, async () => { while (queue.length) await one(queue.shift()) }))
})()
