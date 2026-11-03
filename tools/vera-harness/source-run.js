// Live run of a live source on the host: the finder (Exa + DeepSeek + the real API), the program written on its note by DeepSeek
// with the generation prompt (up to three attempts, the error fed back as Generate does), then the program run as the phone runs
// it: each handler tapped until one asks for Vera.Source.fetch, the real GET made by VeraSource.sourceFetch, the answer handed
// to the program's handler, and the screen's texts printed. Needs ARKESTR_API_KEY (DeepSeek) and EXA_API_KEY.
//   node tools/vera-harness/source-run.js ["prompt" ...]
const fs = require('node:fs'), path = require('node:path')
const {loadVera} = require('./source-loader')
// The platform http module, on node's fetch (GET and POST), for VeraSource.httpGetText and the Exa search.
globalThis.__veraHttp = () => ({destroy() {}, on() {}, async request(url, o) {
  const r = await fetch(url, {method: o.method || 'GET', headers: o.header, body: o.extraData, signal: AbortSignal.timeout(20000)})
  return {responseCode: r.status, result: await r.text()}
}})
const S = loadVera('VeraSource'), F = loadVera('VeraSourceFind'), L = loadVera('VeraLive')
// Vera.Live.fetch, the fallback, as the phone makes it: Exa and DeepSeek with the keys of this shell.
const {settings} = loadVera('SettingsStore')
Object.assign(settings, {hasExaKey: () => true, getExaKey: () => process.env.EXA_API_KEY, hasApiKey: () => true,
  getApiKey: () => process.env.ARKESTR_API_KEY, getBaseUrl: () => 'https://api.deepseek.com', getModel: () => 'deepseek-flash'})
const {compileVeraSource} = loadVera('VeraCompiler'), {smokeRun} = loadVera('VeraSmoke')
const {VirtualMachine, deserializeVbc2, VeraStringValue, VeraNumberValue, VeraBooleanValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi'), {describeCatalogForPrompt} = loadVera('VeraUiCatalog')
const skill = fs.readFileSync(path.join(__dirname, '../../entry/src/main/resources/rawfile/vera-skill.txt'), 'utf8')
const language = skill.replace('{{UI_CATALOG}}', describeCatalogForPrompt(null)).replace('{{UI_TOOL_NOTE}}', '')

async function ds(messages, maxTokens) {
  const r = await fetch('https://api.deepseek.com/chat/completions', {method: 'POST',
    headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + process.env.ARKESTR_API_KEY},
    body: JSON.stringify({model: 'deepseek-flash', temperature: 0, max_tokens: maxTokens, thinking: {type: 'disabled'}, messages})})
  const b = await r.json(); if (!r.ok) throw Error('DeepSeek ' + r.status); return b.choices[0].message.content
}
async function exa(query) {
  const r = await fetch('https://api.exa.ai/search', {method: 'POST', headers: {'Content-Type': 'application/json', 'x-api-key': process.env.EXA_API_KEY},
    body: JSON.stringify({query, numResults: 6, contents: {text: {maxCharacters: 1200}}})})
  const b = await r.json(); return (b.results || []).map((x, i) => `${i + 1}. ${x.title} (${x.url})\n${(x.text || '').slice(0, 1200)}`).join('\n\n')
}
const sourceOf = text => { const m = /```[a-z]*\n([\s\S]*?)```/.exec(text); return (m ? m[1] : text).trim() }

function texts(nodes, out = []) { for (const n of nodes) { if (n.text) out.push(n.text); if (n.kind === 'numbertext') out.push(String(n.numberValue)); texts(n.children || [], out) } return out }
function plain(kind) { return kind === 'string' ? new VeraStringValue('') : kind === 'boolean' ? new VeraBooleanValue(true) : new VeraNumberValue(kind === 'number' ? 1000 : 0) }

async function runApp(compiled) {
  const host = new UiHostEnvironment(), vm = new VirtualMachine(deserializeVbc2(compiled.vbc2), host)
  let state = vm.execute('init')
  // As the phone: the ticker in the view runs first; the other handlers are tried only when there is none.
  const tickers = []; (function find(nodes) { for (const n of nodes) { if (n.kind === 'ticker' && n.action) tickers.push(n.action); find(n.children || []) } })(decodeVeraUi(vm.execute('view', [state])))
  const order = tickers.length ? tickers.map(t => [t, 'number']) : [...compiled.handlers]
  for (const [name, kind] of order) {
    for (let i = 0; i < 400; i++) {   // a ticker: up to 400 ticks of a second
      host.effectsAllowed = true; host.pendingEffects = []
      let next; try { next = vm.execute(name, [state, plain(kind)]) } catch (e) { break }
      const effect = host.pendingEffects.find(e => e.rawTarget === 'Vera.Source.fetch' || e.rawTarget === 'Vera.Live.fetch')
      host.effectsAllowed = false
      state = next
      if (effect) {
        const t = Date.now(), answer = effect.rawTarget === 'Vera.Live.fetch' ? await L.liveFetch(effect.values) : await S.sourceFetch(effect.values)
        state = vm.execute(effect.resultHandler, [state, new VeraStringValue(answer)])
        return {via: (tickers.length ? 'ticker ' : 'NO TICKER, handler ') + name + ' after ' + (i + 1) + ' s', fetchMs: Date.now() - t, answer: answer.split('\n').slice(0, 2).join(' | '),
          screen: texts(decodeVeraUi(vm.execute('view', [state]))).join(' · ').slice(0, 300)}
      }
      if (kind !== 'number') break
    }
  }
  return {via: 'none: no handler asked for the source'}
}

;(async () => {
  const prompts = process.argv.slice(2).length ? process.argv.slice(2) : ['Current weather in Moscow, auto-updated regularly', 'Live IMOEX value']
  for (const prompt of prompts) {
    const t0 = Date.now()
    const calls = new F.SourceCalls()
    calls.search = exa
    calls.askJson = (system, user) => ds([{role: 'system', content: system}, {role: 'user', content: user}], 1200)
    calls.get = url => S.httpGetText(url)
    const query = (await ds([{role: 'system', content: loadVera('LiveFigures').LIVE_QUERY_PROMPT}, {role: 'user', content: prompt}], 60)).trim()
    const found = await F.findSource(prompt + '\nThe figure to fetch: ' + query, calls)
    console.log('\n== ' + prompt + '\n   query: ' + query + '\n   source: ' + (found.spec ? found.spec.url + ' -> ' + found.spec.labels.map((l, i) => l + '=' + found.spec.values[i]).join(', ') : 'NONE ' + found.tried.join('; ')) + '  (' + (found.ms / 1000).toFixed(1) + ' s)')
    let spec = found.spec, extra = ''
    if (!spec) {
      // No API: the program reads the figure off a search on each refresh, starting from the results of one made now.
      const results = await exa(query)
      if (!results) { console.log('   search found nothing: the route'); continue }
      spec = F.searchSpec(query)
      extra = '\n\n' + loadVera('LiveFigures').liveFiguresNote('Web results for "' + query + '".\n' + results)
      console.log('   fallback: Vera.Live.fetch "' + query + '"')
    }
    found.spec = spec
    const genStart = Date.now()
    let feedback = '', program = '', ok = false, attempt = 0
    for (attempt = 1; attempt <= 3 && !ok; attempt++) {
      const reply = await ds([{role: 'system', content: language}, {role: 'user', content: prompt + '\n\n' + F.sourceNote(found.spec) + extra + feedback}], 8000)
      program = sourceOf(reply)
      let err = ''
      try { const c = compileVeraSource(program); err = smokeRun(c) || F.sourceUseError(program, found.spec) || F.sourceShownError(program, c.vbc2, found.spec) } catch (e) { err = e.message }
      if (!err) { ok = true; break }
      console.log('   attempt ' + attempt + ': ' + err.split('\n')[0].slice(0, 200))
      feedback = '\n\nThe previous program:\n' + program + '\n\nIt failed: ' + err + '\nWrite the whole program again, fixed.'
    }
    console.log('   program: ' + (ok ? 'ok on attempt ' + attempt + ', ' + program.split('\n').length + ' lines' : 'FAILED') + ' (' + ((Date.now() - genStart) / 1000).toFixed(1) + ' s)')
    if (!ok) continue
    const name = prompt.replace(/\W+/g, '-').toLowerCase().slice(0, 40)
    fs.writeFileSync(path.join(process.env.SOURCE_RUN_OUT || '/tmp', name + '.vera'), program)
    const run = await runApp(compileVeraSource(program))
    console.log('   run: via ' + run.via + (run.answer ? '\n   answer: ' + run.answer + ' (' + run.fetchMs + ' ms)\n   screen: ' + run.screen : ''))
    console.log('   total ' + ((Date.now() - t0) / 1000).toFixed(1) + ' s')
  }
})().catch(e => { console.error(e); process.exit(1) })
