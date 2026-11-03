// Vera.Live.fetch (VeraLive.ets): a live figure read off a web search each time a program asks, the fallback when no public API was
// found for it. Against canned search results and model replies: how the model's reading is checked against the results, the
// answer's lines, and that a figure or an address the search did not contain is never shown as found. No network.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const live = loadVera('VeraLive')
const search = loadVera('VeraWebSearch')
const {settings} = loadVera('SettingsStore')

// ---- the pure parts -------------------------------------------------------------------------------------------------------------
assert.equal(live.normalizeFigure('1 234,56 RUB'), '1234.56rub')
assert.equal(live.foundIn('92,45', 'Rate: 92.45 RUB today'), true, 'comma and dot are the same mark')
assert.equal(live.foundIn('92.45', 'rate 92,45'), true)
assert.equal(live.foundIn('93.00', 'rate 92.45'), false)
assert.equal(live.foundIn('-', 'a - b'), false)
assert.equal(live.foundIn('', 'abc'), false)
// a figure is found as a number of its own, not inside a longer one
assert.equal(live.foundIn('5', 'in 2025 it rose'), false, '5 is not in 2025')
assert.equal(live.foundIn('1.2', 'it was 11.25 then'), false, '1.2 is not in 11.25')
assert.equal(live.foundIn('1,2', 'it was 11,25 then'), false, 'with the comma as the mark too')
assert.equal(live.foundIn('25', 'in 2025 and 25 more'), true, 'a later occurrence may be the right one')
assert.equal(live.foundIn('5', 'one, 5, and 6'), true, 'a comma between numbers in a list is not part of a number')
assert.equal(live.foundIn('5', 'it cost 5.'), true, 'a full stop after it is a full stop')
assert.equal(live.foundIn('92.45', 'USD 92,45 EUR'), true)
assert.equal(live.foundIn('92.45 RUB', 'rate 92.45 RUB.'), true)
assert.equal(live.foundIn('$5', 'costs $5 each'), true, 'a value that begins with a sign is matched on its number end only')
assert.equal(live.domainOf('https://www.cbr.ru/currency_base/daily/?x=1'), 'cbr.ru')
assert.equal(live.domainOf('http://rates.example.com'), 'rates.example.com')
assert.equal(live.domainOf('example.org/path'), 'example.org')

const HITS = [
  {title: 'Bank of Russia official rates', url: 'https://www.cbr.ru/currency_base/daily/', snippet: 'USD 92,45 EUR 100,10 as of today'},
  {title: 'Some blog', url: 'https://blog.example.com/fx', snippet: 'My guess: the dollar will reach 120 next year, 99.99 now'}
]
// the model names a result; the figure must be in that result, and the source is that result's own address
let r = live.readExtraction('1|1|92,45\n2|1|100,10', [1, 2], HITS)
assert.deepEqual(r.values, ['92,45', '100,10', '']); assert.equal(r.accepted, 2); assert.equal(r.source, 0); assert.equal(r.rejected, 0)
r = live.readExtraction('1|1|93,00', [1], HITS)
assert.equal(r.accepted, 0); assert.equal(r.rejected, 1, 'a figure not in the named result is dropped')
r = live.readExtraction('1|2|92,45', [1], HITS)
assert.equal(r.accepted, 0, 'right figure, wrong result: dropped')
r = live.readExtraction('1|9|92,45\n2|-|-\nnonsense\n7|1|1', [1, 2], HITS)
assert.equal(r.accepted, 0); assert.equal(r.rejected, 0, 'a result number that does not exist, a dash, junk and an unasked label are ignored')
r = live.readExtraction('1|2|99.99\n1|1|92,45', [1], HITS)
assert.equal(r.values[0], '99.99', 'the first answer for a label wins'); assert.equal(r.source, 1)
assert.equal(live.formatAnswer(live.readExtraction('1|1|92,45', [1], HITS), HITS, '14:05'),
  'ok\n92,45\n\n\nsource\tcbr.ru\thttps://www.cbr.ru/currency_base/daily/\nasof\t14:05')
assert.match(live.formatAnswer(live.readExtraction('1|1|93,00', [1], HITS), HITS, '14:05'), /^error: the figures were not in the search results \(the model gave 1 that were not\)/)

// ---- the compiler lets this one host address through even when the SDK index knows nothing of it, and still refuses another
// "Vera." one; its parameters are written out, as Vera.Source.fetch's (E2114) ---------------------------------------------------
globalThis.__sdkTargetHook = () => false
{
  const program = 'import * as ui from "std/ui"\nimport * as sdk from "std/sdk"\n@jsonable class AppState { v: string; }\n' +
    'function init(): AppState { return {v: ""}; }\n' +
    'function refresh(state: AppState, ignored: number): AppState { sdk.call("Vera.Live.fetch", ["query", "usd rub today", "labels", "USD/RUB"], "onLive"); return state; }\n' +
    'function onLive(state: AppState, answer: string): AppState { return {v: answer}; }\n' +
    'function view(state: AppState): ui.View { return ui.Column("default", [ui.Text("body", state.v), ui.Button("primary", "Refresh", "refresh", 0, true)]); }\n'
  compileVeraSource(program)
  assert.throws(() => compileVeraSource(program.replace('Vera.Live.fetch', 'Vera.Live.fetchh')), e => e.diagnostics.some(d => d.code === 'E2110'))
  assert.throws(() => compileVeraSource(program.replace('"usd rub today"', 'state.v')), e => e.diagnostics.some(d => d.code === 'E2114'))
}

// ---- the host function end to end, with a canned search and a canned model ---------------------------------------------------------
;(async () => {
  settings.hasExaKey = () => true; settings.hasApiKey = () => true; settings.getApiKey = () => 'k'; settings.getBaseUrl = () => 'https://m'; settings.getModel = () => 'm'
  let searches = []
  search.webSearchHits = async q => { searches.push(q); return {hits: HITS, error: ''} }
  const model = reply => { globalThis.__veraHttp = () => ({on() {}, destroy() {}, request: async () => ({responseCode: 200, result: JSON.stringify({choices: [{message: {content: reply}}]})})}) }
  const fresh = async p => { live.resetLiveAnswers(); return live.liveFetch(p) }
  const params = new Map([['query', 'usd rub today'], ['labels', 'USD/RUB||']])
  model('1|1|92,45')
  let answer = await fresh(params)
  assert.match(answer, /^ok\n92,45\n\n\nsource\tcbr\.ru\thttps:\/\/www\.cbr\.ru\/currency_base\/daily\/\nasof\t\d\d:\d\d:\d\d$/); assert.deepEqual(searches, ['usd rub today'])
  model('1|1|95,00')
  assert.match(await fresh(params), /^error: the figures were not in the search results/)
  model('1|2|99.99')
  assert.match(await fresh(params), /^ok\n99\.99\n\n\nsource\tblog\.example\.com\thttps:\/\/blog\.example\.com\/fx/, 'the source is the result the figure was found in')
  globalThis.__veraHttp = () => ({on() {}, destroy() {}, request: async () => ({responseCode: 500, result: ''})})
  assert.equal(await fresh(params), 'error: the model did not answer')
  search.webSearchHits = async () => ({hits: [], error: 'no results'})
  assert.equal(await fresh(params), 'error: no results')
  search.webSearchHits = async () => ({hits: [], error: 'search answered HTTP 401'})
  assert.equal(await fresh(params), 'error: search answered HTTP 401')
  assert.equal(await fresh(new Map([['query', ''], ['labels', 'A||']])), 'error: nothing to look up')
  assert.equal(await fresh(new Map([['query', 'x'], ['labels', '||']])), 'error: nothing to look up')
  settings.hasExaKey = () => false
  assert.match(await fresh(params), /^error: no search key/)
  settings.hasExaKey = () => true; settings.hasApiKey = () => false
  assert.match(await fresh(params), /^error: no model key/)
  // The same query and labels asked again within LIVE_REUSE_MS are answered from what was read: no second search, no second model call.
  settings.hasExaKey = () => true; settings.hasApiKey = () => true
  live.resetLiveAnswers(); searches = []
  let modelCalls = 0
  search.webSearchHits = async q => { searches.push(q); return {hits: HITS, error: ''} }
  globalThis.__veraHttp = () => ({on() {}, destroy() {}, request: async () => { modelCalls++; return {responseCode: 200, result: JSON.stringify({choices: [{message: {content: '1|1|92,45'}}]})} }})
  const first = await live.liveFetch(params); const again = await live.liveFetch(params)
  assert.equal(again, first); assert.equal(searches.length, 1); assert.equal(modelCalls, 1, 'the second call did not search or ask the model')
  await live.liveFetch(new Map([['query', 'usd rub today'], ['labels', 'EUR/RUB||']]))
  assert.equal(searches.length, 2, 'other labels are another question')
  // An error is not kept: it is tried again.
  live.resetLiveAnswers(); searches = []
  search.webSearchHits = async q => { searches.push(q); return {hits: [], error: 'no results'} }
  await live.liveFetch(params); await live.liveFetch(params)
  assert.equal(searches.length, 2, 'an error is asked again')
  delete globalThis.__veraHttp
  console.log('live-check: ok')
})().catch(e => { console.error(e); process.exit(1) })
