// Catalogue holes (VeraHoles.ets) written by DeepSeek for requests given, the way SectionFill.ets asks them, with every
// call recorded: the agent's route seldom reaches them (a list with a search box is a ready section), so they are asked
// here directly. $ARKESTR_API_KEY.
//
//   node tools/vera-harness/hole-run.js -o OUTDIR -p PROMPTS.tsv [-j JOBS] [-t TEMP] [--lookups FILE] [label ...]
//
// PROMPTS: family<TAB>label<TAB>hole<TAB>prompt, where hole is rowMatches (a filter box over a list and its details) or
// whenFinished (a timer that calls the phone at zero; its SDK functions come from --lookups, the phone's own answers, and a
// request the cache does not hold is shown none, recorded as a miss). Writes OUTDIR/<label>/asks.jsonl: `ask` events
// (task catalogue-hole, system, user, reply, the bodies it parses to), then one `fill` event with the bodies kept, the note
// and `behaviour`: the kept program run in the VM ('ok' or what it did wrong).
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const {fragments} = loadVera('VeraTemplates')
const {expandListRows} = loadVera('VeraTemplateContent')
const {composeProgram} = loadVera('VeraSectionCompose')
const {compileVeraSource} = loadVera('VeraCompiler')
const {holesOf, holeValues, fillHoles, parseHoleAnswer} = loadVera('VeraHoles')
const {VirtualMachine, deserializeVbc2, decodeRuntimeValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi')
const {foundTargets} = loadVera('agent/AgentCustom')

const args = process.argv.slice(2)
const option = (flag, fallback) => { const i = args.indexOf(flag); if (i < 0) return fallback; const v = args[i + 1]; args.splice(i, 2); return v }
const out = option('-o', path.join(require('node:os').tmpdir(), 'hole-run'))
const promptFile = option('-p', '')
const jobs = Number(option('-j', '4'))
const temperature = Number(option('-t', '0'))
const lookupFile = option('--lookups', '')
const lookups = lookupFile ? new Map(Object.entries(JSON.parse(fs.readFileSync(lookupFile, 'utf8')))) : null
if (!promptFile) { console.error('usage: hole-run.js -o OUTDIR -p PROMPTS.tsv [-j JOBS] [-t TEMP] [--lookups FILE] [label ...]'); process.exit(2) }
const prompts = fs.readFileSync(promptFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith('#')).map(l => l.split('\t'))
  .filter(([, label]) => !args.length || args.includes(label))

async function deepseek(system, user, maxTokens, meta) {
  const res = await fetch('https://api.deepseek.com/chat/completions', {method: 'POST',
    headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + process.env.ARKESTR_API_KEY},
    body: JSON.stringify({model: 'deepseek-flash', stream: false, temperature, max_tokens: maxTokens, thinking: {type: 'disabled'},
      messages: [{role: 'system', content: system}, {role: 'user', content: user}]})})
  const body = await res.json()
  if (!res.ok) throw Error('DeepSeek HTTP ' + res.status + ' ' + JSON.stringify(body).slice(0, 200))
  Object.assign(meta, {model: body.model, finish: body.choices[0].finish_reason, usage: body.usage})
  return body.choices[0].message.content
}

const globals = new Map([['__THEME__', 'clean'], ['__HEADER_STYLE__', 'default'], ['__BANNER_SECTION__', 'hide'], ['__TITLE__', 'Check']])
const rows = [['Pasta Bake', 'Boil eight minutes, then bake.'], ['Tomato Soup', 'Simmer for an hour.'], ['Green Salad', 'Toss and serve.']]
const SCREENS = {rowMatches: ['filter_box', 'master_list', 'detail_view'], whenFinished: ['timer']}

/** Each block's values: its first slot values and fallbacks, the rows above for the list, and the timer's finish action on. */
function baseValues(kinds) {
  return kinds.map(kind => {
    const spec = fragments().find(f => f.kind === kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, c.fallback))
    spec.listFields.forEach(l => m.set(l.token, expandListRows(kind === 'master_list' ? rows : undefined, l).text))
    for (const hole of spec.holes) if (hole.slot) m.set(hole.slot, 'true')
    return m
  })
}

function builder(kinds) {
  return bodies => {
    const extra = holeValues(kinds, bodies)
    return composeProgram(kinds, globals, baseValues(kinds).map((m, i) => { extra[i].forEach((v, t) => m.set(t, v)); return m }))
  }
}

const str = v => decodeRuntimeValue(['s', v])
const texts = n => [n.text, n.label, n.value].filter(Boolean).concat((n.children || []).flatMap(texts))

/**
 * What the kept bodies do that the hole's purpose rules out, or 'ok'. The compiler does not check sdk.call targets: one not
 * among the SDK functions shown compiles and does nothing (asked with none, DeepSeek wrote sdk.call("flashlight", ...)).
 */
function behaviour(hole, source, bodies, sdkContext) {
  const found = foundTargets(sdkContext)
  for (const body of Object.values(bodies)) {
    for (const m of body.matchAll(/sdk\.call\(\s*"([^"]*)"/g)) {
      if (!found.includes(m[1])) return 'calls ' + m[1] + ', not among the SDK functions shown'
    }
  }
  try {
    const r = compileVeraSource(source)
    const vm = new VirtualMachine(deserializeVbc2(r.vbc2 !== undefined ? r.vbc2 : r), new UiHostEnvironment())
    let st = vm.execute('init')
    const shown = () => texts(decodeVeraUi(vm.execute('view', [st]))[0]).join('|')
    if (hole !== 'rowMatches') { shown(); return 'ok' }
    // The one rule every request shares (the hole's purpose): nothing typed, every row stays. What a typed text keeps is
    // the request's own (title only, exact title, hide what matches), so it is only run, not judged.
    if (!rows.every(([label]) => shown().includes(label))) return 'not every row shown while the box is empty'
    st = vm.execute('setFilter1', [st, str('Soup')])
    shown()
    return 'ok'
  } catch (e) {
    return 'did not run: ' + e.message
  }
}

async function one([family, label, hole, prompt]) {
  const kinds = SCREENS[hole]
  if (!kinds) return console.log(label.padEnd(24), 'unknown hole', hole)
  const holes = holesOf(kinds, baseValues(kinds)).filter(h => h.spec.byModel)
  const events = []
  let seq = 0
  let sdkContext = ''
  if (holes.some(h => h.spec.usesSdk) && lookups !== null) {
    const query = prompt.substring(0, 300)
    const text = lookups.get('find_sdk_function\u0000' + query + '\u00000')
    events.push({kind: 'lookup', seq: seq++, tool: 'find_sdk_function', query, both: false, hit: text !== undefined})
    sdkContext = text === undefined ? '' : text.substring(0, 2500)
  }
  const ask = async (system, user) => {
    const meta = {}
    const entry = {kind: 'ask', task: 'catalogue-hole', seq: seq++, temperature, system, user}
    try {
      entry.reply = await deepseek(system, user, 500, meta)
      entry.parsed = Object.fromEntries(parseHoleAnswer(entry.reply, holes))
      return entry.reply
    } catch (e) { entry.error = e.message; return null }
    finally { Object.assign(entry, meta); events.push(entry) }
  }
  const build = builder(kinds)
  const fill = await fillHoles(prompt, kinds, ask, build, baseValues(kinds), sdkContext)
  const kept = fill.bodies.size > 0 ? behaviour(hole, build(fill.bodies), Object.fromEntries(fill.bodies), sdkContext) : 'nothing kept'
  events.push({kind: 'fill', seq: seq++, hole, bodies: Object.fromEntries(fill.bodies), note: fill.note, behaviour: kept})
  const dir = path.join(out, label)
  fs.mkdirSync(dir, {recursive: true})
  fs.writeFileSync(path.join(dir, 'asks.jsonl'), events.map(e => JSON.stringify(Object.assign({label, family, prompt}, e)) + '\n').join(''))
  console.log(label.padEnd(24), fill.note.padEnd(28), kept)
}

;(async () => {
  const queue = prompts.slice()
  await Promise.all(Array.from({length: Math.min(jobs, queue.length)}, async () => { while (queue.length) await one(queue.shift()) }))
})()
