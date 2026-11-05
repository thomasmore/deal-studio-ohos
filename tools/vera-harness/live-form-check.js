// Actual form service and stores, with only filesystem/platform boundaries mocked.
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const { loadVera } = require('./source-loader')
const disk = new Map(), cache = new Map()
const filesystem = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, mkdirSync() {},
  openSync(file) { return { fd: file } },
  writeSync(file, value) { disk.set(file, value) }, closeSync() {},
  statSync(file) { if (!disk.has(file)) throw Error('absent'); return { size: disk.get(file).length } },
  readTextSync(file) { if (!disk.has(file)) throw Error('absent'); return disk.get(file) },
  renameSync(from, to) { assert(disk.has(from)); disk.set(to, disk.get(from)); disk.delete(from) },
  unlinkSync(file) { disk.delete(file) },
  listFileSync(dir) { return [...disk.keys()].filter(file => path.dirname(file) === dir).map(file => path.basename(file)) }
}
const base = path.join(__dirname, '../../entry/src/main/ets/vera')
function load(name) {
  if (cache.has(name)) return cache.get(name).exports
  if (name === 'VeraLiveWidget' || name === 'VeraStateStamp' || name === 'VeraSource') return loadVera(name)
  const module = { exports: {} }; cache.set(name, module)
  const source = fs.readFileSync(path.join(base, name + '.ets'), 'utf8')
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true } }).outputText
  new Function('require','module','exports', compiled)(dep => {
    if (dep === '@kit.CoreFileKit') return { fileIo: filesystem }
    if (dep === '@kit.FormKit') return { formBindingData: { createFormBindingData: value => value } }
    if (dep.startsWith('./')) return load(dep.slice(2))
    throw Error(dep)
  }, module, module.exports)
  return module.exports
}
const {store} = load('ProjectStore'), {formBindings} = load('FormBindings')
store.init('/fixture'); formBindings.init('/fixture')
const project = store.createProject('Counter','🔢')
const source = fs.readFileSync(path.join(__dirname,'examples/widget-counter.vera'),'utf8')
const version = store.createVersion(project.id,source,loadVera('VeraCompiler').compileVeraSource(source).vbc2,'Counter')
formBindings.bind('form-1',project.id); formBindings.bind('form-2',project.id)
assert.deepEqual(formBindings.formsFor(project.id), ['form-1','form-2'])
const {FormBindings} = load('FormBindings'), other = new FormBindings(); other.init('/fixture')
assert.equal(other.projectFor('form-1'), project.id)
const service = load('LiveFormService'), {veraStateStamp} = load('VeraStateStamp')
const initial = service.liveFrame(project.id)
assert(initial.live)
assert(store.loadState(project.id,version.id,veraStateStamp(version.vbc2)))
;(async () => {
const tap = async (token, value) => service.liveFormTap('form-1', JSON.stringify({action:'message',handler:'change',token,value}))
const updated = await tap(initial.token,1)
assert(updated.live); assert.equal(updated.formId,'form-1'); assert.notEqual(updated.token,initial.token)
const saved = store.loadState(project.id,version.id,veraStateStamp(version.vbc2))
const stale = await tap(initial.token,1)
assert.match(stale.status,/changed/)
assert.equal(store.loadState(project.id,version.id,veraStateStamp(version.vbc2)),saved)
const forged = await tap(updated.token,999)
assert.match(forged.status,/not available/)
assert.equal(store.loadState(project.id,version.id,veraStateStamp(version.vbc2)),saved)
assert.equal(store.listVersions(project.id).length,1)
assert(![...disk.keys()].some(file=>file.endsWith('.tmp')))
// A second widget sees the same commit and its previous token becomes stale.
assert.equal(service.liveBinding(project.id,'form-2').token, updated.token)
const second = await service.liveFormTap('form-2', JSON.stringify({handler:'change',token:updated.token,value:-1}))
assert.notEqual(second.token,updated.token)
assert.match((await tap(updated.token,1)).status,/changed/)
// Additive refinement publishes saved state before the new version is discoverable.
const nextSource = source + '\nfunction widgetHelper(): number { return 1; }'
const nextCode = loadVera('VeraCompiler').compileVeraSource(nextSource).vbc2
const carried = store.loadState(project.id,version.id,veraStateStamp(version.vbc2))
const nextVersion = store.createVersion(project.id,nextSource,nextCode,'Make widget','','','','','',null,carried,veraStateStamp(nextCode))
assert.equal(store.loadState(project.id,nextVersion.id,veraStateStamp(nextCode)),carried)
assert.equal(store.loadState(project.id,version.id,veraStateStamp(version.vbc2)),carried)
formBindings.bind('form-1','missing-project')
assert.equal(service.liveFrame(formBindings.projectFor('form-1')).title,'App removed')
formBindings.bind('form-1',project.id)
assert.equal(service.liveBinding(project.id,'form-1').formId,'form-1')
other.unbind('form-1'); assert.equal(formBindings.projectFor('form-1'),''); assert.equal(formBindings.projectFor('form-2'),project.id)
assert.equal(service.liveBinding('', 'unbound').formId, 'unbound')
// The periodic update: widgetRefresh brings yesterday's state up to date once per period, however many cards show it.
const {refreshLedger} = load('FormBindings'); refreshLedger.init('/fixture')
const {WidgetSession} = loadVera('VeraLiveWidget')
const dailySource = fs.readFileSync(path.join(__dirname,'examples/widget-daily.vera'),'utf8')
const daily = store.createProject('Daily','📅')
const dailyVersion = store.createVersion(daily.id,dailySource,loadVera('VeraCompiler').compileVeraSource(dailySource).vbc2,'Daily')
const dailyStamp = veraStateStamp(dailyVersion.vbc2)
formBindings.bind('form-d1',daily.id); formBindings.bind('form-d2',daily.id)
const withFields = (count, day) => { const s = JSON.parse(new WidgetSession(dailyVersion.vbc2,'x','').encodedState())
  for (const [name, value] of s[2]) { if (name === 'count') value[1] = count; if (name === 'day' && day !== null) value[1] = day }
  return JSON.stringify(s) }
const countOf = () => JSON.parse(store.loadState(daily.id,dailyVersion.id,dailyStamp))[2].find(f => f[0] === 'count')[1][1]
store.saveState(daily.id,dailyVersion.id,dailyStamp,withFields(5, 1))
const T = 1_800_000_000_000
const first = await service.liveFormRefresh('form-d1', T)
assert(first.ran); assert.equal(countOf(), 0, 'a new day starts the count again'); assert.equal(first.binding.formId, 'form-d1')
store.saveState(daily.id,dailyVersion.id,dailyStamp,withFields(3, null))
assert(!(await service.liveFormRefresh('form-d2', T + 60_000) ).ran, 'the second card in the same period does not run it again')
const later = await service.liveFormRefresh('form-d2', T + service.REFRESH_EVERY_MS)
assert(later.ran); assert.equal(countOf(), 3, 'the same day keeps its count')
assert(!(await service.liveFormRefresh('form-2', T) ).ran, 'a program without widgetRefresh is only redrawn')
// A live source: widgetRefresh asks for Vera.Source.fetch, the card makes the GET and hands the answer to the program's handler
// before drawing and saving. Any other phone call from widgetRefresh is still refused.
const liveSource = fs.readFileSync(path.join(__dirname,'examples/widget-source.vera'),'utf8')
const live = store.createProject('IMOEX','📈')
const liveVersion = store.createVersion(live.id,liveSource,loadVera('VeraCompiler').compileVeraSource(liveSource).vbc2,'IMOEX')
formBindings.bind('form-s1',live.id)
const asked = []
const fetched = await service.liveFormRefresh('form-s1', T, async params => { asked.push(Object.fromEntries(params))
  return 'ok\n2461.3\n\n\nsource\tiss.moex.com\thttps://iss.moex.com/x\nasof\t14:05:00' })
assert(fetched.ran); assert.equal(asked.length, 1); assert.equal(asked[0].paths, 'marketdata.data[0][1]')
assert(JSON.stringify(fetched.binding.nodes).includes('2461.3'), 'the card draws the figure fetched now')
assert(store.loadState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2)).includes('2461.3'), 'and the app sees it')
const failed = await service.liveFormRefresh('form-s1', T + service.REFRESH_EVERY_MS, async () => 'error: HTTP 503')
assert(failed.ran); assert(JSON.stringify(failed.binding.nodes).includes('2461.3'), 'a failed fetch keeps the last figure')
// The card's Refresh button fetches the source too, before the card is drawn and saved. (From a fresh state: the program's own
// Refresh ignores a second press within ten seconds of the last fetch, and the update above has just fetched.)
store.saveState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2),new WidgetSession(liveVersion.vbc2,'x','').encodedState())
const shown = service.liveFrame(live.id)
const button = JSON.stringify(shown.nodes).includes('"refresh"')
assert(button, 'the widget has its Refresh button')
const tapped = await service.liveFormTap('form-s1', JSON.stringify({handler: 'refresh', token: shown.token, value: 0}),
  async () => 'ok\n2470.1\n\n\nsource\tiss.moex.com\thttps://iss.moex.com/x\nasof\t15:00:00')
assert(JSON.stringify(tapped.nodes).includes('2470.1'), 'a tap on Refresh draws the figure fetched')
assert(store.loadState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2)).includes('2470.1'))
// The app saves while the card's fetch is out: the app's state is kept and the answer handed to it, not overwritten by the
// card's copy loaded before the fetch.
{
  const fresh = new WidgetSession(liveVersion.vbc2,'x','').encodedState()
  store.saveState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2),fresh)
  const shown = service.liveFrame(live.id)
  const appState = JSON.parse(fresh); for (const f of appState[2]) if (f[0] === 'lastCall') f[1][1] = 42
  await service.liveFormTap('form-s1', JSON.stringify({handler: 'refresh', token: shown.token, value: 0}), async () => {
    store.saveState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2),JSON.stringify(appState))
    return 'ok\n2480.5\n\n\nsource\tiss.moex.com\thttps://iss.moex.com/x\nasof\t15:10:00' })
  const after = JSON.parse(store.loadState(live.id,liveVersion.id,veraStateStamp(liveVersion.vbc2)))[2]
  assert.equal(after.find(f => f[0] === 'lastCall')[1][1], 42, 'the app\'s save during the fetch is kept')
  assert.equal(after.find(f => f[0] === 'value')[1][1], '2480.5', 'and the answer is on it')
}
// Two cards of one project updated together: the period is marked before the fetch, so only one of them fetches.
{
  formBindings.bind('form-s2', live.id)
  let fetches = 0
  const slow = async () => { fetches++; await new Promise(r => setTimeout(r, 20)); return 'ok\n2490\n\n\nsource\tiss.moex.com\thttps://iss.moex.com/x\nasof\t15:20:00' }
  const at = T + 5 * service.REFRESH_EVERY_MS
  const [a, b] = await Promise.all([service.liveFormRefresh('form-s1', at, slow), service.liveFormRefresh('form-s2', at, slow)])
  assert.equal(fetches, 1, 'one fetch for the burst'); assert.equal([a.ran, b.ran].filter(Boolean).length, 1)
}
// Add widget through the system widget manager: the project offered is taken by the next card, once, while fresh.
formBindings.offer(project.id, T)
assert.equal(other.takeOffer(T + 30_000), project.id, 'the card added in the manager takes the offered project')
assert.equal(formBindings.takeOffer(T + 31_000), '', 'a second card is not bound to it')
formBindings.offer(project.id, T)
assert.equal(formBindings.takeOffer(T + 6 * 60_000), '', 'a stale offer is dropped')
console.log('PASS live forms: Add widget offer taken once while fresh, periodic widgetRefresh once per period, binding persistence/removal, shared state, first render commit, transport, stale/forged rejection, atomic writes, live source on the card')
})().catch(e => { console.error(e); process.exit(1) })
