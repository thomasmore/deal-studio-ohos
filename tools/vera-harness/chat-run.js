// The phone's chat (VeraChat.ets's chatReply) live on the host: the app's own requests, its tool rounds (find_sdk_function and
// find_intent_function on the host lookup, web_search on Exa), streamed as on the phone, each recorded by model-tap.js. The
// person's messages are DeepSeek playing one from a seed line (not trained on): the first message, then up to N-1 more, each
// a reply to what the chat said. $ARKESTR_API_KEY, $EXA_API_KEY (optional: without it the chat offers no search).
//
//   node tools/vera-harness/chat-run.js -o OUTDIR -p SEEDS.tsv [-n TURNS] [-j JOBS] --host-lookup DIR [label ...]
//
// SEEDS.tsv: label<TAB>what the person is about (a topic and its examples). Writes OUTDIR/<label>/asks.jsonl: every model
// request with its answer (kind ask, task chat), and one `turn` event per person message with the chat's whole reply and
// whether parseReply read it (a widget marker cut or malformed is an error).
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const args = process.argv.slice(2)
const option = (flag, fallback) => { const i = args.indexOf(flag); if (i < 0) return fallback; const v = args[i + 1]; args.splice(i, 2); return v }
const out = option('-o', '')
const seedFile = option('-p', '')
const turns = Number(option('-n', '3'))
const jobs = Number(option('-j', '4'))
const hostLookupDir = option('--host-lookup', '')
if (!out || !seedFile || !hostLookupDir) { console.error('usage: chat-run.js -o OUTDIR -p SEEDS.tsv [-n TURNS] [-j JOBS] --host-lookup DIR [label ...]'); process.exit(2) }

// Stand-ins before anything is loaded: the phone's lookup on the host, then the http module on fetch with the recorder.
require('./host-lookup').install({phoneFiles: hostLookupDir})
const tap = require('./model-tap')
tap.install()
const {loadVera} = require('./source-loader')
const {settings} = loadVera('SettingsStore')
Object.assign(settings, {getApiKey: () => process.env.ARKESTR_API_KEY || '', getBaseUrl: () => 'https://api.deepseek.com',
  getModel: () => 'deepseek-flash', getExaKey: () => process.env.EXA_API_KEY || ''})
const chat = loadVera('VeraChat')
const {ReplyStats} = loadVera('VeraChatStats')

const seeds = fs.readFileSync(seedFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith('#')).map(l => l.split('\t'))
  .filter(([label]) => !args.length || args.includes(label))

const PERSON = 'You play a person using the chat assistant built into their phone. You write only what they type: plain, ' +
  'casual, 3 to 25 words, no greeting. Vary what they want: sometimes a question words can answer, sometimes a small tool, ' +
  'tracker, timer or calculator to use, sometimes a few things compared, sometimes something on the phone itself (an alarm, ' +
  'a message, a calendar entry). Reply with JSON only: {"message": "..."}; {"message": ""} when the person would be done.'

/** The person's next message, from DeepSeek directly (not through the app, so not recorded). */
async function person(seed, history) {
  const said = history.map(t => (t.role === 'user' ? 'Person: ' : 'Assistant: ') + t.text).join('\n\n')
  const ask = history.length === 0 ? 'What they are about: ' + seed + '\n\nWrite their first message.' :
    'What they are about: ' + seed + '\n\nThe chat so far:\n' + said + '\n\nWrite their next message: a follow-up, a correction, ' +
    'a change to the widget the assistant offered, or a new related question.'
  const res = await fetch('https://api.deepseek.com/chat/completions', {method: 'POST',
    headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + process.env.ARKESTR_API_KEY},
    body: JSON.stringify({model: 'deepseek-flash', temperature: 1.0, max_tokens: 200, thinking: {type: 'disabled'},
      response_format: {type: 'json_object'}, messages: [{role: 'system', content: PERSON}, {role: 'user', content: ask}]})})
  const body = await res.json()
  if (!res.ok) throw Error('DeepSeek HTTP ' + res.status)
  try { return String(JSON.parse(body.choices[0].message.content).message || '').trim() } catch (e) { return '' }
}

async function one([label, seed]) {
  const dir = path.join(out, label)
  fs.mkdirSync(dir, {recursive: true})
  const log = {asks: [], seq: 0, task: 'chat'}
  const history = []
  let said = 0
  try {
    for (let t = 0; t < turns; t++) {
      const message = await person(seed, history)
      if (!message) break
      history.push(Object.assign(new chat.ChatTurn(), {messageId: history.length + 1, role: 'user', text: message}))
      const reply = await tap.run(log, () => chat.chatReply(history, () => {}, () => {}, new ReplyStats()))
      const parsed = chat.parseReply(reply, true)
      log.asks.push({kind: 'turn', seq: log.seq++, turn: t, message, reply, error: parsed.error, widget: parsed.appDescription.length > 0})
      history.push(Object.assign(new chat.ChatTurn(), {messageId: history.length + 1, role: 'assistant', text: reply}))
      said++
    }
  } catch (e) { log.asks.push({kind: 'error', seq: log.seq++, error: e.message}) }
  fs.writeFileSync(path.join(dir, 'asks.jsonl'), log.asks.map(a => JSON.stringify(Object.assign({label}, a)) + '\n').join(''))
  const calls = log.asks.filter(a => a.kind === 'ask').length
  const errors = log.asks.filter(a => a.kind === 'error' || (a.kind === 'turn' && a.error)).length
  console.log(label.padEnd(28), said + ' turn(s), ' + calls + ' model call(s)' + (errors ? ', ' + errors + ' error(s)' : ''))
}

;(async () => {
  fs.mkdirSync(out, {recursive: true})
  const queue = seeds.slice()
  await Promise.all(Array.from({length: Math.min(jobs, queue.length)}, async () => { while (queue.length) await one(queue.shift()) }))
})()
