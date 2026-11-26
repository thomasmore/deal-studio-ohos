'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const root = path.resolve(__dirname, '../../entry/src/main/ets')
const cache = new Map()
const disk = new Map()
const timers = new Map()
const hosts = []
const bridges = []
const calls = []
const grants = new Map()
const consentChecks = []
const remembered = []
const callbackErrors = []
const unhandled = []
const traces = []
let now = 100000
let nextTimer = 0
let platform = () => Promise.resolve('ok')
const filesystem = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  mkdirSync() {},
  openSync(file) { return { fd: file } },
  writeSync(file, value) { disk.set(file, value) },
  closeSync() {},
  statSync(file) {
    if (!disk.has(file)) throw Error('absent')
    return { size: disk.get(file).length }
  },
  readTextSync(file) {
    if (!disk.has(file)) throw Error('absent')
    return disk.get(file)
  },
  renameSync(from, to) {
    assert(disk.has(from))
    disk.set(to, disk.get(from))
    disk.delete(from)
  },
  unlinkSync(file) { disk.delete(file) },
  listFileSync(dir) { return [...disk.keys()].filter(file => path.dirname(file) === dir).map(file => path.basename(file)) }
}
const forbidden = name => new Proxy({}, { get(_target, key) {
  throw Error('Forbidden platform access: ' + name + '.' + String(key))
} })
const consent = {
  has(stamp, target) {
    consentChecks.push([stamp, target])
    return grants.get(stamp)?.has(target) === true
  },
  remember(stamp, target) {
    remembered.push([stamp, target])
    if (!grants.has(stamp)) grants.set(stamp, new Set())
    grants.get(stamp).add(target)
  }
}
function adapter(route, target, values, mode) {
  assert(values instanceof Map)
  const call = { route, target, values: [...values], mode }
  calls.push(call)
  return platform(call)
}
function load(file) {
  file = path.resolve(file)
  if (cache.has(file)) return cache.get(file).exports
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
    reportDiagnostics: true
  })
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, file + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'))
  const module = { exports: {} }
  cache.set(file, module)
  const importer = name => {
    if (name.endsWith('/VeraIntents')) return { runRawIntent: (target, values, mode) => adapter('intent', target, values, mode) }
    if (name.endsWith('/VeraSdkBackend')) return { runSdkAdapter: (target, values) => adapter('sdk', target, values) }
    if (name.endsWith('/VeraConsentStore')) return { consent }
    if (name === '@kit.CoreFileKit') return { fileIo: filesystem }
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: forbidden('hilog') }
    if (name.startsWith('@kit.') || name === 'libllama.so') return forbidden(name)
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'))
    throw Error('Unsupported dependency: ' + name + ' from ' + file)
  }
  new Function('require', 'module', 'exports', compiled.outputText)(importer, module, module.exports)
  return module.exports
}
const runtime = name => load(path.join(root, 'runtime', name + '.ets'))
const vera = name => load(path.join(root, 'vera', name + '.ets'))
const { InProcessHost } = runtime('InProcessHost')
const { HostEffectsBridge } = runtime('HostEffectsBridge')
const { StageTrace } = runtime('trace/StageTrace')
const { EffectController, executeEffect, effectValues, effectConsentKey, effectConsentTitle, effectConsentValues } = runtime('EffectController')
const { compileVeraSource } = vera('VeraCompiler')
const { veraStateStamp } = vera('VeraStateStamp')
const { store } = vera('ProjectStore')
store.init('/effects-fixture')
const target = 'com.example.effects/entry/EntryAbility/Record'
const sdkTarget = 'Fixture.device.read'
const effectCode = (label = 'fire', name = target, mode = '') =>
  `sdk.call("${name}", ["label", "${label}", "value", ui.numberToString(state.n)], "answered"${mode ? ', "' + mode + '"' : ''});`
function fixture({ refresh = false, refreshCount = 1, initial = 1, bad = false } = {}) {
  return `
@jsonable class AppState {
  n: number;
  field: string;
  answers: string[];
  observed: string[];
  order: string[];
  refreshes: number;
}
function init(): AppState {
  return {n: ${initial}, field: "initial", answers: [], observed: [], order: [], refreshes: 0};
}
function fire(state: AppState, value: number): AppState {
  state.n = state.n + value;
  ${effectCode()}
  return state;
}
function sdkFire(state: AppState, value: number): AppState {
  ${effectCode('sdk', sdkTarget)}
  return state;
}
function foreground(state: AppState, value: number): AppState {
  ${effectCode('foreground', target, 'foreground')}
  return state;
}
function ordered(state: AppState, value: number): AppState {
  sdk.call("${target}", ["z", "first", "a", "", "z", "last"], "answered");
  return state;
}
function pair(state: AppState, value: number): AppState {
  ${effectCode('first')}
  ${effectCode('second')}
  return state;
}
function add(state: AppState, value: number): AppState {
  state.n = state.n + value;
  state.order.push("add");
  return state;
}
function edit(state: AppState, value: string): AppState {
  state.field = value;
  state.order.push("field");
  return state;
}
function answered(state: AppState, value: string): AppState {
  state.answers.push(value);
  state.observed.push(state.field);
  state.order.push("answer");
  return state;
}
function widgetRefresh(state: AppState): AppState {
  state.refreshes = state.refreshes + 1;
  ${refresh ? Array.from({ length: refreshCount }, (_, index) => effectCode(index === 0 ? 'refresh' : 'refresh-' + index)).join('\n  ') : ''}
  return state;
}
function view(state: AppState): ui.View {
  ${bad ? 'let empty: number[] = []; state.n = empty[2];' : ''}
  return ui.Text("body", state.field);
}
`
}
function compile(source) {
  try {
    const { vbc2 } = compileVeraSource(source)
    return { vbc2, stamp: veraStateStamp(vbc2) }
  } catch (error) {
    if (error.diagnostics) error.message += '\n' + JSON.stringify(error.diagnostics)
    throw error
  }
}
const programs = {
  basic: compile(fixture()), newer: compile(fixture({ initial: 9 })),
  refresh: compile(fixture({ refresh: true })), bad: compile(fixture({ bad: true }))
}
function unpack(value) {
  assert(Array.isArray(value), 'snapshots must be VM tagged tuples')
  switch (value[0]) {
    case 'n': case 's': case 'b': return value[1]
    case 'z': return null
    case 'a': return value[1].map(unpack)
    case 'o': return Object.fromEntries(value[2].map(([key, item]) => [key, unpack(item)]))
    default: assert.fail('unknown snapshot tag: ' + value[0])
  }
}
const decode = encoded => unpack(JSON.parse(encoded))
const config = (mode = 'LIVE_EPHEMERAL', persistKey = '') => ({ mode, persistKey, seedState: '' })
function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
async function microtasks() {
  for (let i = 0; i < 40; i++) await Promise.resolve()
}
function runTimer() {
  const due = [...timers].filter(([, timer]) => timer.at <= now)
    .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0]
  if (!due) return false
  timers.delete(due[0])
  due[1].callback(...due[1].args)
  return true
}
async function pump() {
  for (let i = 0; i < 5000; i++) {
    await microtasks()
    if (!runTimer()) return
  }
  assert.fail('fake timer drain must terminate')
}
async function finish(promise) {
  let settled = false, value, failure
  Promise.resolve(promise).then(result => { settled = true; value = result }, error => { settled = true; failure = error })
  for (let i = 0; !settled && i < 5000; i++) {
    await microtasks()
    if (!settled) assert(runTimer(), 'operation unresolved without runnable fake timers')
  }
  assert(settled, 'operation did not settle')
  if (failure) throw failure
  return value
}
function accepted(result) {
  assert.equal(result.status, 'ACCEPTED', JSON.stringify(result))
  return result.inputSeq
}
function input(handle, action, value = 0, kind = 'HANDLER') {
  return { appId: handle.appId, vmGeneration: handle.vmGeneration, kind, action,
    payload: { kind: typeof value === 'string' ? 'STRING' : 'NUMBER', num: typeof value === 'number' ? value : 0,
      str: typeof value === 'string' ? value : '', bool: false, phase: 'move', id: 0, x: 0, y: 0 },
    persist: false, draws: [] }
}
function harness(options = {}) {
  const host = new InProcessHost(() => now)
  hosts.push(host)
  const p = { host, frames: [], snapshots: [], effects: [], errors: [], pending: [], failures: [],
    admissions: [], posts: [], events: [], fields: [], flushes: [], handle: null, binding: null,
    frameHook: null, effectHook: null, writableHook: null, postHook: null, flushHook: null }
  const invoke = (name, ...args) => {
    if (!p[name]) return
    try { return p[name](...args) } catch (error) { callbackErrors.push(error) }
  }
  const postResult = host.postEffectResult.bind(host)
  host.postEffectResult = (handle, effectId, text) => {
    p.events.push('post')
    const admission = p.postHook ? p.postHook(handle, effectId, text, postResult) : postResult(handle, effectId, text)
    p.posts.push({ handle, effectId, text, admission })
    return admission
  }
  p.flushInput = appId => {
    p.flushes.push(appId)
    p.events.push('flush')
    if (p.flushHook) return p.flushHook(appId)
    while (p.fields.length) {
      const value = p.fields.shift()
      accepted(host.postInput(p.handle, input(p.handle, 'edit', value, 'FIELD')))
    }
  }
  p.bridge = new HostEffectsBridge(host, {
    askBeforeCalls: false,
    onPending: effect => p.pending.push(effect),
    flushPendingInputFor: appId => p.flushInput(appId),
    onAdmitted: (effect, seq) => p.admissions.push({ effect, seq }),
    onFailure: (effect, error) => p.failures.push({ effect, error }),
    ...options
  })
  bridges.push(p.bridge)
  p.subscriber = {
    onViewFrame(frame) { p.frames.push(frame); p.events.push('frame'); invoke('frameHook', frame) },
    onStateSnapshot(encoded) { p.snapshots.push(decode(encoded)); p.events.push('snapshot') },
    onStateSaved() {},
    onError(kind, message, seq) { p.errors.push({ kind, message, seq }) },
    onEffectRequest(effect) {
      p.effects.push(effect)
      p.events.push('effect')
      p.binding.onEffectRequest(effect)
      invoke('effectHook', effect)
    },
    flushPendingInputFor: appId => p.flushInput(appId),
    onMailboxWritable() { p.events.push('writable'); p.bridge.onMailboxWritable(); invoke('writableHook') }
  }
  p.begin = (stamp = programs.basic.vbc2) => { p.binding = p.bridge.beginBinding(stamp); return p.binding }
  p.acquire = async (program = programs.basic, settings = config()) => {
    p.begin(program.vbc2)
    const promise = host.acquire('', program, settings, p.subscriber)
    p.handle = await finish(promise)
    p.binding.bind(p.handle)
    return p.handle
  }
  p.replace = async (program = programs.newer) => {
    p.begin(program.vbc2)
    p.handle = await finish(host.replaceProgram(p.handle, program, config()))
    p.binding.bind(p.handle)
    return p.handle
  }
  p.post = (action = 'fire', value = 0) => accepted(host.postInput(p.handle, input(p.handle, action, value)))
  p.snapshot = async () => decode(await finish(host.requestSnapshot(p.handle)))
  return p
}
function request(effectId = 1, extra = {}) {
  return { appId: 'app', vmGeneration: 1, effectId, kind: 'sdk', rawTarget: target,
    params: [], mode: 'background', resultHandler: 'answered', ...extra }
}
function controller(options = {}) {
  const p = { pending: [], completed: [], epoch: 1, stamp: 'version-a', active: true }
  p.controller = new EffectController({ askBeforeCalls: true, stamp: () => p.stamp,
    generation: () => p.epoch, isCurrent: () => p.active,
    onPending: effect => p.pending.push(effect), complete: (effect, text) => p.completed.push({ effect, text }), ...options })
  return p
}
const tests = []
function test(name, run) { tests.push({ name, run }) }

test('real sdk.call buffers initial widgetRefresh until actual acquired handle, flushes fields, dispatches result and persists snapshot', async () => {
  const answer = deferred()
  platform = () => answer.promise
  const p = harness()
  p.begin(programs.refresh.stamp)
  const acquiring = p.host.acquire('', programs.refresh, config('LIVE_PERSISTENT', 'project/version'), p.subscriber)
  assert.equal(p.effects.length, 1)
  assert.equal(p.handle, null)
  assert.equal(calls.length, 0)
  p.handle = await finish(acquiring)
  p.fields.push('typed before answer')
  p.binding.bind(p.handle)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].route, 'intent')
  assert.equal(calls[0].mode, 'background')
  answer.resolve('{"result":"verbatim"}')
  await pump()
  const state = await p.snapshot()
  assert.deepEqual(state.answers, ['{"result":"verbatim"}'])
  assert.deepEqual(state.observed, ['typed before answer'])
  assert.deepEqual(state.order, ['field', 'answer'])
  assert.equal(p.posts[0].handle, p.handle)
  assert.equal(p.posts[0].effectId, p.effects[0].effectId)
  assert.equal(p.admissions[0].seq, 2)
  assert(p.events.indexOf('flush') < p.events.indexOf('post'))
  assert.deepEqual(p.snapshots.at(-1), state)
  const saved = JSON.parse(disk.get('/effects-fixture/vera/project/version.state.json'))
  assert.equal(saved.stamp, programs.refresh.stamp)
  assert.deepEqual(unpack(saved.value), state)
  assert.deepEqual(p.errors, [])
  assert.deepEqual(p.failures, [])
})

test('real SDK dotted target and explicit foreground intent use actual executeEffect routing', async () => {
  const p = harness()
  await p.acquire()
  p.post('sdkFire')
  p.post('foreground')
  await pump()
  assert.deepEqual(calls.map(call => [call.route, call.target, call.mode]), [
    ['sdk', sdkTarget, undefined], ['intent', target, 'foreground']
  ])
  assert.deepEqual((await p.snapshot()).answers, ['ok', 'ok'])
})

test('real handler flat parameters arrive as ordered Map with duplicate replacement and default background mode', async () => {
  const p = harness()
  await p.acquire()
  p.post('ordered')
  await pump()
  assert.deepEqual(calls[0], { route: 'intent', target, values: [['z', 'last'], ['a', '']], mode: 'background' })
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
})

test('slash predicate requires sdk kind; other-kind slash remains SDK and Map preserves insertion/default values', async () => {
  const effect = request(1, { kind: 'calendar', params: ['z', 'first', 'a', '', 'z', 'last', 'dangling'] })
  assert.deepEqual([...effectValues(effect)], [['z', 'last'], ['a', '']])
  await executeEffect(effect)
  await executeEffect(request(2))
  assert.deepEqual(calls, [
    { route: 'sdk', target, values: [['z', 'last'], ['a', '']], mode: undefined },
    { route: 'intent', target, values: [], mode: 'background' }
  ])
  assert.equal(effectConsentKey(effect), target)
  assert.equal(effectConsentTitle(request()), 'Run Record')
  assert.equal(effectConsentTitle(request(2, { rawTarget: sdkTarget })), 'Run read')
  assert.equal(effectConsentValues(effect), 'z: last\na: ')
  assert.equal(effectConsentValues(request()), '(no parameters)')
})

for (const action of ['fire', 'sdkFire']) {
  for (const text of ['{\"intentName\":\"Record\",\"nested\":{\"ok\":true}}', 'ok', 'declined code=10010001', 'error 2200003: denied', 'declined by the person', '']) {
    test(action + ' real result handler receives unchanged ' + JSON.stringify(text), async () => {
      platform = () => Promise.resolve(text)
      const p = harness()
      await p.acquire()
      p.post(action)
      await pump()
      assert.deepEqual((await p.snapshot()).answers, [text])
      assert.equal(p.posts[0].text, text)
      assert.equal(p.posts.length, 1)
      assert.equal(calls.length, 1)
      assert.equal(calls[0].route, action === 'fire' ? 'intent' : 'sdk')
    })
  }
}

test('consent refusal returns exact string through real result handler and never calls platform', async () => {
  const p = harness({ askBeforeCalls: true })
  await p.acquire()
  p.post()
  assert.equal(calls.length, 0)
  assert.equal(p.pending.at(-1).rawTarget, target)
  p.bridge.refusePending()
  await pump()
  assert.deepEqual((await p.snapshot()).answers, ['declined by the person'])
  assert.equal(calls.length, 0)
  assert.deepEqual(remembered, [])
})

test('consent grants are keyed by captured stamp and raw target; replacement version must ask again', async () => {
  const p = harness({ askBeforeCalls: true })
  await p.acquire()
  p.post()
  p.bridge.allowPending()
  await pump()
  assert.deepEqual(remembered, [[programs.basic.vbc2, target]])
  p.post()
  await pump()
  assert.equal(calls.length, 2)
  p.post('sdkFire')
  assert.equal(p.pending.at(-1).rawTarget, sdkTarget)
  assert.equal(calls.length, 2)
  p.bridge.refusePending()
  await pump()
  await p.replace()
  p.post()
  assert.equal(calls.length, 2)
  assert.equal(p.pending.at(-1).rawTarget, target)
  assert.deepEqual(consentChecks.at(-1), [programs.newer.vbc2, target])
  p.bridge.allowPending()
  await pump()
  assert.deepEqual(remembered, [[programs.basic.vbc2, target], [programs.newer.vbc2, target]])
  assert.equal(calls.length, 3)
})

test('pending consent holds even no-consent followers, then allowed calls overlap and complete out of order', async () => {
  const first = deferred(), second = deferred(), third = deferred()
  const waiting = [first, second, third]
  platform = () => waiting[calls.length - 1].promise
  const p = controller()
  p.controller.accept([request(1), request(2, { kind: 'calendar' }), request(3)])
  assert.equal(calls.length, 0)
  assert.equal(p.pending.filter(Boolean).length, 1)
  p.controller.allowPending()
  assert.equal(calls.length, 3)
  assert.deepEqual(remembered, [['version-a', target]])
  second.resolve('second')
  third.resolve('third')
  first.resolve('first')
  await microtasks()
  assert.deepEqual(p.completed.map(item => [item.effect.effectId, item.text]), [[2, 'second'], [3, 'third'], [1, 'first']])
})

test('no-consent real platform calls overlap and dispatch in completion order', async () => {
  const first = deferred(), second = deferred()
  platform = () => calls.length === 1 ? first.promise : second.promise
  const p = harness()
  await p.acquire()
  p.post('pair')
  assert.equal(calls.length, 2)
  second.resolve('second')
  await pump()
  first.resolve('first')
  await pump()
  assert.deepEqual((await p.snapshot()).answers, ['second', 'first'])
  assert.deepEqual(p.posts.map(item => item.effectId), [p.effects[1].effectId, p.effects[0].effectId])
})

for (const [name, fail, text] of [
  ['synchronous adapter throw', () => { throw Error('sync adapter') }, 'error: sync adapter'],
  ['adapter rejection', () => Promise.reject(Error('async adapter')), 'error: async adapter'],
  ['non-Error rejection', () => Promise.reject('plain rejection'), 'error: plain rejection'],
  ['null rejection', () => Promise.reject(null), 'error: null']
]) {
  test(name + ' returns error prefix to real VM', async () => {
    platform = fail
    const p = harness()
    await p.acquire()
    p.post()
    await pump()
    assert.deepEqual((await p.snapshot()).answers, [text])
    assert.equal(p.posts[0].text, text)
    assert.deepEqual(p.failures, [])
  })
}

test('controller captures stamp at acceptance and copies request params across consent wait', async () => {
  const p = controller()
  const effect = request(1, { params: ['key', 'original'] })
  p.controller.accept([effect])
  effect.params[1] = 'mutated'
  effect.rawTarget = 'wrong.target'
  p.stamp = 'version-b'
  p.controller.allowPending()
  await microtasks()
  assert.deepEqual(remembered, [['version-a', target]])
  assert.deepEqual(calls[0].values, [['key', 'original']])
  assert.equal(p.completed[0].effect.rawTarget, target)
})

for (const kind of ['invalidate', 'generation', 'inactive']) {
  test('controller drops stale completion after ' + kind, async () => {
    const answer = deferred()
    platform = () => answer.promise
    const p = controller({ askBeforeCalls: false })
    p.controller.accept([request()])
    if (kind === 'invalidate') p.controller.invalidate()
    if (kind === 'generation') p.epoch++
    if (kind === 'inactive') p.active = false
    answer.resolve('stale')
    await microtasks()
    assert.deepEqual(p.completed, [])
  })
}

test('controller invalidation clears pending consent and held followers', async () => {
  const p = controller()
  p.controller.accept([request(), request(2)])
  p.controller.invalidate()
  p.controller.allowPending()
  p.controller.refusePending()
  await microtasks()
  assert.equal(calls.length, 0)
  assert.deepEqual(p.completed, [])
  assert.equal(p.pending.at(-1), null)
})

test('wrong app/generation and duplicate requests are rejected before and after actual handle binding', async () => {
  const p = harness()
  p.begin(programs.refresh.stamp)
  const acquiring = p.host.acquire('', programs.refresh, config(), p.subscriber)
  const original = p.effects[0]
  p.binding.onEffectRequest({ ...original, appId: 'wrong' })
  p.binding.onEffectRequest({ ...original, vmGeneration: original.vmGeneration + 1 })
  p.binding.onEffectRequest(original)
  p.handle = await finish(acquiring)
  p.binding.bind(p.handle)
  p.binding.onEffectRequest(original)
  p.binding.onEffectRequest({ ...original, appId: 'wrong', effectId: 90 })
  p.binding.onEffectRequest({ ...original, vmGeneration: 999, effectId: 91 })
  await pump()
  assert.equal(calls.length, 1)
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
  assert.equal(p.posts.length, 1)
})

test('prebind buffer snapshots request and params and cannot be rebound to a second lease', async () => {
  const p = harness()
  p.begin(programs.refresh.stamp)
  const acquiring = p.host.acquire('', programs.refresh, config(), p.subscriber)
  const original = p.effects[0]
  original.params[1] = 'mutated-after-buffer'
  original.rawTarget = 'mutated.target'
  p.handle = await finish(acquiring)
  p.binding.bind(p.handle)
  p.binding.bind({ ...p.handle, appId: 'different' })
  await pump()
  assert.equal(calls[0].target, target)
  assert.equal(calls[0].values[0][1], 'refresh')
  assert.equal(p.posts[0].handle, p.handle)
})

test('replacement widgetRefresh buffers before returned handle and old binding never accepts replacement effects', async () => {
  const p = harness()
  await p.acquire()
  const oldHandle = p.handle, oldBinding = p.binding
  p.begin(programs.refresh.stamp)
  const replacing = p.host.replaceProgram(oldHandle, programs.refresh, config())
  assert.equal(p.effects.length, 1)
  assert.equal(calls.length, 0)
  const emitted = p.effects[0]
  assert.equal(emitted.vmGeneration, oldHandle.vmGeneration + 1)
  oldBinding.onEffectRequest(emitted)
  p.handle = await finish(replacing)
  p.binding.bind(p.handle)
  oldBinding.bind(p.handle)
  await pump()
  assert.equal(calls.length, 1)
  assert.equal(p.posts[0].handle, p.handle)
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
})

test('failed binding discards buffered effects; failed acquire never executes platform', async () => {
  const p = harness()
  p.begin()
  const failed = p.binding
  failed.onEffectRequest(request())
  failed.failBinding()
  failed.bind({ appId: 'app', vmGeneration: 1, leaseId: 'late' })
  failed.onEffectRequest(request(2))
  await microtasks()
  assert.equal(calls.length, 0)
  p.begin(programs.bad.stamp)
  await assert.rejects(p.host.acquire('', programs.bad, config(), p.subscriber), error => error.code === 'ACTOR_NOT_READY')
  p.binding.failBinding()
  await microtasks()
  assert.equal(calls.length, 0)
})

for (const lifecycle of ['release', 'replace', 'promotion', 'dispose']) {
  test(lifecycle + ' invalidates in-flight origin and never rebinds stale callbacks to new handle', async () => {
    const answer = deferred()
    platform = () => answer.promise
    const p = harness()
    await p.acquire()
    p.post()
    const oldHandle = p.handle, oldBinding = p.binding, oldEffect = p.effects[0]
    p.bridge.invalidate()
    if (lifecycle === 'release') {
      await finish(p.host.release(oldHandle))
      await p.acquire()
    } else if (lifecycle === 'replace') {
      await p.replace()
    } else if (lifecycle === 'promotion') {
      p.begin(programs.basic.stamp)
      p.handle = await finish(p.host.promote(oldHandle, 'LIVE_PERSISTENT', 'promoted/version'))
      p.binding.bind(p.handle)
    } else {
      await finish(p.host.dispose())
    }
    oldBinding.bind(p.handle)
    oldBinding.onEffectRequest({ ...oldEffect, effectId: oldEffect.effectId + 100 })
    oldBinding.failBinding()
    answer.resolve('stale result')
    await pump()
    assert.equal(calls.length, 1)
    assert.equal(p.posts.length, 0)
    if (lifecycle !== 'dispose') {
      assert.deepEqual((await p.snapshot()).answers, [])
      platform = () => Promise.resolve('new result')
      p.post()
      await pump()
      assert.deepEqual((await p.snapshot()).answers, ['new result'])
      assert.equal(p.posts[0].handle, p.handle)
    }
  })
}

test('captureValidity cancellation while field flush awaits suppresses result', async () => {
  let valid = true
  const gate = deferred()
  const p = harness({ captureValidity: () => () => valid })
  await p.acquire()
  p.flushHook = () => gate.promise
  p.post()
  await microtasks()
  assert.equal(p.flushes.length, 1)
  valid = false
  gate.resolve()
  await pump()
  assert.equal(p.posts.length, 0)
  assert.deepEqual((await p.snapshot()).answers, [])
  assert.deepEqual(p.failures, [])
})

test('binding replacement while awaiting field flush drops old result and preserves new result', async () => {
  const gate = deferred()
  const p = harness()
  await p.acquire()
  p.flushHook = () => gate.promise
  p.post()
  await microtasks()
  await p.replace()
  gate.resolve()
  p.flushHook = null
  p.post()
  await pump()
  assert.equal(p.posts.length, 1)
  assert.equal(p.posts[0].handle, p.handle)
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
})

test('readyToPost false defers without timers and explicit flush resumes exactly once', async () => {
  let ready = false
  const p = harness({ readyToPost: () => ready })
  await p.acquire()
  p.post()
  await microtasks()
  assert.equal(p.posts.length, 0)
  assert.equal(timers.size, 0)
  ready = true
  await finish(p.bridge.flush())
  await pump()
  assert.equal(p.posts.length, 1)
  await finish(p.bridge.flush())
  await pump()
  assert.equal(p.posts.length, 1)
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
})

test('REJECTED admission is terminal and never retried or reexecuted', async () => {
  const answer = deferred()
  platform = () => answer.promise
  const p = harness()
  await p.acquire()
  p.post()
  await finish(p.host.release(p.handle))
  answer.resolve('late')
  await microtasks()
  assert.equal(p.posts.length, 1)
  assert.equal(p.posts[0].admission.status, 'REJECTED')
  await finish(p.bridge.onMailboxWritable())
  await finish(p.bridge.flush())
  await pump()
  assert.equal(p.posts.length, 1)
  assert.equal(calls.length, 1)
})

test('in-flight field flush and older actions are admitted before result', async () => {
  const gate = deferred()
  const p = harness()
  await p.acquire()
  let once = true
  p.flushHook = async () => {
    if (!once) return
    once = false
    await gate.promise
    accepted(p.host.postInput(p.handle, input(p.handle, 'edit', 'composed', 'FIELD')))
  }
  p.post()
  await microtasks()
  p.post('add', 5)
  assert.equal(p.posts.length, 0)
  gate.resolve()
  await pump()
  const state = await p.snapshot()
  assert.equal(state.n, 6)
  assert.deepEqual(state.order, ['add', 'field', 'answer'])
  assert.deepEqual(state.observed, ['composed'])
  assert.equal(p.posts[0].admission.inputSeq, 4)
})

test('composition deferred promise flush keeps completion queued until composition is committed', async () => {
  const composition = deferred()
  const p = harness()
  await p.acquire()
  p.flushHook = () => composition.promise.then(() => {
    accepted(p.host.postInput(p.handle, input(p.handle, 'edit', 'IME committed', 'FIELD')))
  })
  p.post('pair')
  await microtasks()
  assert.equal(p.posts.length, 0)
  assert.equal(calls.length, 2)
  assert.equal(timers.size, 0)
  composition.resolve()
  await pump()
  assert.deepEqual((await p.snapshot()).observed, ['IME committed', 'IME committed'])
  assert.equal(p.posts.length, 2)
})

function fillMailbox(p) {
  for (let i = 0; i < 240; i++) accepted(p.host.postInput(p.handle, input(p.handle, 'add', 1)))
  for (let i = 0; i < 16; i++) accepted(p.host.postRefresh(p.handle, 'APP'))
  assert.equal(p.host.postRefresh(p.handle, 'APP').status, 'BACKPRESSURE')
  now += 9
}
function fillOnNextFrame(p) {
  p.frameHook = () => {
    p.frameHook = null
    fillMailbox(p)
  }
}

test('real mailbox full256 in onFrame yields, rejects result BACKPRESSURE then writable retries same text once without reexecution', async () => {
  platform = () => Promise.resolve('{"retry":"same text"}')
  const p = harness()
  await p.acquire()
  fillOnNextFrame(p)
  p.post()
  assert.equal(calls.length, 1)
  await microtasks()
  assert.equal(p.posts.length, 1)
  assert.equal(p.posts[0].admission.status, 'BACKPRESSURE')
  assert.equal(p.admissions.length, 0)
  assert.equal(timers.size, 1)
  await pump()
  assert.deepEqual(p.posts.map(item => item.admission.status), ['BACKPRESSURE', 'ACCEPTED'])
  assert.deepEqual(p.posts.map(item => item.text), ['{"retry":"same text"}', '{"retry":"same text"}'])
  assert.equal(p.posts[0].effectId, p.posts[1].effectId)
  assert.equal(p.posts[0].handle, p.posts[1].handle)
  assert.equal(calls.length, 1)
  assert.equal(p.admissions.length, 1)
  const state = await p.snapshot()
  assert.equal(state.n, 241)
  assert.deepEqual(state.answers, ['{"retry":"same text"}'])
  assert(p.events.includes('writable'))
})

test('retained BACKPRESSURE completions retry FIFO in completion order, not request order', async () => {
  const first = deferred(), second = deferred()
  platform = () => calls.length === 1 ? first.promise : second.promise
  const p = harness()
  await p.acquire()
  fillOnNextFrame(p)
  p.post('pair')
  second.resolve('second')
  await microtasks()
  first.resolve('first')
  await microtasks()
  assert(p.posts.every(item => item.admission.status === 'BACKPRESSURE'))
  assert.equal(p.posts[0].effectId, p.effects[1].effectId)
  await pump()
  assert.deepEqual((await p.snapshot()).answers, ['second', 'first'])
  assert.deepEqual(p.posts.filter(item => item.admission.status === 'ACCEPTED').map(item => item.text), ['second', 'first'])
  assert.equal(calls.length, 2)
})

test('reentrant writable while still blocked must not spin microtasks or busy retry timers', async () => {
  const p = harness()
  await p.acquire()
  let attempts = 0
  p.postHook = (handle, id, text, post) => {
    attempts++
    if (attempts > 4) throw Error('bounded guard: reentrant writable busy loop')
    const admission = post(handle, id, text)
    if (admission.status === 'BACKPRESSURE') p.bridge.onMailboxWritable()
    return admission
  }
  fillOnNextFrame(p)
  p.post()
  await microtasks()
  assert(attempts <= 2, 'reentrant writable repeatedly retried unchanged BACKPRESSURE: ' + attempts)
  assert.equal(timers.size, 1)
  assert.equal(calls.length, 1)
  assert.deepEqual(p.failures, [])
})

for (const lifecycle of ['invalidate', 'replace']) {
  test('synchronous post fast-frame callback ' + lifecycle + ' cannot shift another result or notify stale admission', async () => {
    const p = harness()
    await p.acquire()
    p.post('pair')
    let replacing = null
    p.frameHook = () => {
      p.frameHook = null
      if (lifecycle === 'invalidate') p.bridge.invalidate()
      else {
        p.begin(programs.newer.stamp)
        replacing = p.host.replaceProgram(p.handle, programs.newer, config())
      }
    }
    await pump()
    assert.equal(p.posts.length, 1)
    assert.equal(p.admissions.length, 0)
    if (replacing) {
      p.handle = await finish(replacing)
      p.binding.bind(p.handle)
      p.post()
      await pump()
      assert.deepEqual((await p.snapshot()).answers, ['ok'])
      assert.equal(p.posts.length, 2)
    } else {
      assert.deepEqual((await p.snapshot()).answers, ['ok'])
    }
  })
}

test('synchronous post fast-frame reentrant refusal appends result without losing or duplicating queued completion', async () => {
  const p = harness({ askBeforeCalls: true })
  await p.acquire()
  grants.set(programs.basic.vbc2, new Set([target]))
  p.post('pair')
  p.post('sdkFire')
  assert.equal(p.pending.at(-1).rawTarget, sdkTarget)
  p.frameHook = () => {
    p.frameHook = null
    p.bridge.refusePending()
  }
  await pump()
  assert.deepEqual((await p.snapshot()).answers, ['ok', 'ok', 'declined by the person'])
  assert.equal(p.posts.length, 3)
  assert.equal(p.admissions.length, 3)
  assert.equal(calls.length, 2)
  assert.equal(new Set(p.posts.map(item => item.effectId)).size, 3)
})

for (const point of ['captureValidity', 'validity', 'flush', 'readyToPost', 'postEffectResult', 'onAdmitted']) {
  test('throwing ' + point + ' callback is reported once, removes failed result, and leaves no unhandled rejection', async () => {
    const failure = Error('fixture ' + point)
    let throwOnce = true
    const fail = () => {
      if (throwOnce) { throwOnce = false; throw failure }
    }
    const options = {}
    if (point === 'captureValidity') options.captureValidity = () => { fail(); return () => true }
    if (point === 'validity') options.captureValidity = () => () => { fail(); return true }
    if (point === 'readyToPost') options.readyToPost = () => { fail(); return true }
    if (point === 'onAdmitted') options.onAdmitted = fail
    const p = harness(options)
    await p.acquire()
    if (point === 'flush') p.flushHook = fail
    if (point === 'postEffectResult') p.postHook = (handle, id, text, post) => { fail(); return post(handle, id, text) }
    p.post('pair')
    await pump()
    assert.equal(p.failures.length, 1)
    assert.equal(p.failures[0].error, failure)
    const state = await p.snapshot()
    assert.equal(state.answers.length, point === 'onAdmitted' ? 2 : 1)
    assert.equal(calls.length, 2)
    const count = p.posts.length
    await finish(p.bridge.flush())
    await pump()
    assert.equal(p.posts.length, count)
    assert.deepEqual(unhandled, [])
  })
}

test('failed replacement binding cannot resurrect buffered requests or disturb the restored old actor', async () => {
  const p = harness()
  await p.acquire()
  const oldHandle = p.handle, oldBinding = p.binding
  p.begin(programs.bad.vbc2)
  const failed = p.binding
  failed.onEffectRequest(request(100, { appId: oldHandle.appId, vmGeneration: oldHandle.vmGeneration + 1 }))
  await assert.rejects(p.host.replaceProgram(oldHandle, programs.bad, config()), error => error.code === 'ACTOR_NOT_READY')
  failed.failBinding()
  failed.bind(oldHandle)
  oldBinding.bind(oldHandle)
  oldBinding.onEffectRequest(request(101, { appId: oldHandle.appId, vmGeneration: oldHandle.vmGeneration }))
  await microtasks()
  assert.equal(calls.length, 0)
  p.begin(programs.basic.vbc2)
  p.binding.bind(oldHandle)
  p.post()
  await pump()
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
  assert.equal(p.posts.length, 1)
})

test('rejected asynchronous field flush reports failure and removes only that result', async () => {
  const p = harness()
  await p.acquire()
  let once = true
  p.flushHook = () => {
    if (!once) return
    once = false
    return Promise.reject(Error('field flush rejected'))
  }
  p.post('pair')
  await pump()
  assert.equal(p.failures.length, 1)
  assert.equal(p.failures[0].error.message, 'field flush rejected')
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
  assert.equal(p.posts.length, 1)
})

test('throwing failure reporter is contained and later completion still posts', async () => {
  const reported = []
  const p = harness({ onFailure: (effect, error) => { reported.push([effect, error]); throw Error('reporter failure') } })
  await p.acquire()
  let once = true
  p.flushHook = () => {
    if (once) { once = false; throw Error('flush failure') }
  }
  p.post('pair')
  await pump()
  assert.equal(reported.length, 1)
  assert.equal(reported[0][1].message, 'flush failure')
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
  assert.deepEqual(unhandled, [])
})

test('COALESCED effect result is reported as invalid and never retried', async () => {
  const p = harness()
  await p.acquire()
  p.postHook = () => ({ status: 'COALESCED' })
  p.post()
  await pump()
  assert.equal(p.failures.length, 1)
  assert.equal(p.failures[0].error.message, 'EFFECT_RESULT cannot be coalesced')
  await finish(p.bridge.onMailboxWritable())
  await pump()
  assert.equal(p.posts.length, 1)
  assert.equal(calls.length, 1)
})

for (const previous of [false, true]) {
  test('reentrant beginBinding from onPending(null) keeps newest binding with previous=' + previous, async () => {
    let armed = false, newest
    const p = harness({ onPending: effect => {
      p.pending.push(effect)
      if (effect === null && armed) {
        armed = false
        newest = p.bridge.beginBinding(programs.basic.vbc2)
      }
    } })
    if (previous) await p.acquire()
    armed = true
    const superseded = p.bridge.beginBinding('superseded')
    assert(newest)
    superseded.bind({ appId: 'wrong', vmGeneration: 99, leaseId: 'wrong' })
    superseded.onEffectRequest(request(100))
    superseded.failBinding()
    p.binding = newest
    if (!previous) p.handle = await finish(p.host.acquire('', programs.basic, config(), p.subscriber))
    newest.bind(p.handle)
    p.post()
    await pump()
    assert.equal(calls.length, 1)
    assert.equal(p.posts.length, 1)
    assert.deepEqual((await p.snapshot()).answers, ['ok'])
    assert.deepEqual(p.failures, [])
  })
}

for (const allowed of [true, false]) {
  test('controller ' + (allowed ? 'allow' : 'refuse') + ' clear callback cannot let accepted followers overtake resolution', async () => {
    const order = []
    let inserted = false
    platform = call => { order.push('execute:' + call.values[0][1]); return Promise.resolve('ok') }
    const tagged = id => request(id, { kind: id === 1 ? 'sdk' : 'calendar', params: ['id', String(id)] })
    const p = controller({
      onPending: effect => {
        if (effect === null && !inserted) {
          inserted = true
          p.controller.accept([tagged(3)])
          assert.deepEqual(order, [])
        }
      },
      complete: effect => order.push('complete:' + effect.effectId)
    })
    p.controller.accept([tagged(1), tagged(2)])
    if (allowed) p.controller.allowPending()
    else p.controller.refusePending()
    assert.deepEqual(order, allowed ? ['execute:1', 'execute:2', 'execute:3'] : ['complete:1', 'execute:2', 'execute:3'])
    await microtasks()
    assert.deepEqual(order, allowed
      ? ['execute:1', 'execute:2', 'execute:3', 'complete:1', 'complete:2', 'complete:3']
      : ['complete:1', 'execute:2', 'execute:3', 'complete:2', 'complete:3'])
    assert.deepEqual(remembered, allowed ? [['version-a', target]] : [])
  })
}

for (const resolution of ['resolved', 'rejected', 'refused']) {
  test('throwing controller complete after ' + resolution + ' reports failure and preserves reentrant followers and rerun', async () => {
    const failure = Error('complete ' + resolution)
    const failures = [], completed = []
    let once = true
    platform = () => resolution === 'rejected' ? Promise.reject(Error('adapter rejected')) : Promise.resolve('ok')
    const p = controller({ askBeforeCalls: resolution === 'refused',
      onFailure: (effect, error) => failures.push({ effect, error }),
      complete: (effect, text) => {
        completed.push([effect.effectId, text])
        if (once) {
          once = false
          p.controller.accept([request(3, { kind: 'calendar' })])
          throw failure
        }
      }
    })
    p.controller.accept([request(1), request(2, { kind: 'calendar' })])
    if (resolution === 'refused') p.controller.refusePending()
    await microtasks()
    p.controller.accept([request(4, { kind: 'calendar' })])
    await microtasks()
    assert.deepEqual(completed.map(item => item[0]), [1, 2, 3, 4])
    assert.equal(completed[0][1], resolution === 'refused' ? 'declined by the person'
      : resolution === 'rejected' ? 'error: adapter rejected' : 'ok')
    assert.equal(failures.length, 1)
    assert.equal(failures[0].effect.effectId, 1)
    assert.equal(failures[0].error, failure)
    assert.equal(calls.length, resolution === 'refused' ? 3 : 4)
    assert.deepEqual(unhandled, [])
  })
}

for (const point of ['show', 'allow-clear', 'refuse-clear', 'invalidate-clear']) {
  test('throwing controller onPending at ' + point + ' reports once and leaves followers runnable', async () => {
    const failure = Error('pending ' + point)
    const failures = []
    let once = true
    const p = controller({
      onPending: effect => {
        const matches = point === 'show' ? effect !== null : effect === null
        if (matches && once) {
          once = false
          p.controller.accept([request(3, { kind: 'calendar' })])
          throw failure
        }
      },
      onFailure: (effect, error) => failures.push({ effect, error })
    })
    p.controller.accept([request(1), request(2, { kind: 'calendar' })])
    if (point === 'allow-clear') p.controller.allowPending()
    if (point === 'refuse-clear') p.controller.refusePending()
    if (point === 'invalidate-clear') p.controller.invalidate()
    await microtasks()
    p.controller.accept([request(4, { kind: 'calendar' })])
    await microtasks()
    assert.equal(failures.length, 1)
    assert.equal(failures[0].error, failure)
    assert.equal(failures[0].effect?.effectId ?? null, point === 'invalidate-clear' ? null : 1)
    assert.deepEqual(p.completed.map(item => item.effect.effectId), point === 'invalidate-clear' ? [3, 4] : [2, 3, 4])
    assert.equal(calls.length, point === 'invalidate-clear' ? 2 : 3)
    p.controller.allowPending()
    p.controller.refusePending()
    await microtasks()
    assert.equal(failures.length, 1)
    assert.deepEqual(unhandled, [])
  })
}

for (const point of ['begin', 'invalidate']) {
  test('throwing bridge onPending(null) at ' + point + ' reports without breaking next binding', async () => {
    const failure = Error('bridge clear ' + point)
    let armed = false
    const p = harness({ onPending: effect => {
      if (effect === null && armed) { armed = false; throw failure }
    } })
    if (point === 'invalidate') await p.acquire()
    armed = true
    if (point === 'invalidate') p.bridge.invalidate()
    await p.acquire()
    p.post('pair')
    await pump()
    assert.equal(p.failures.length, 1)
    assert.equal(p.failures[0].effect, null)
    assert.equal(p.failures[0].error, failure)
    assert.deepEqual((await p.snapshot()).answers, ['ok', 'ok'])
  })
}

test('field flush barrier returning bridge.flush does not await itself and drains each result once', async () => {
  const p = harness()
  await p.acquire()
  p.flushHook = () => p.bridge.flush()
  p.post('pair')
  await pump()
  assert.equal(p.posts.length, 2)
  assert.equal(p.flushes.length, 2)
  assert.equal(calls.length, 2)
  assert.deepEqual((await p.snapshot()).answers, ['ok', 'ok'])
  assert.deepEqual(p.failures, [])
})

test('active flush is an immediately resolved kick, not a completion barrier', async () => {
  const gate = deferred()
  const p = harness()
  await p.acquire()
  p.flushHook = () => gate.promise
  p.post('pair')
  await microtasks()
  assert.equal(p.flushes.length, 1)
  await finish(p.bridge.flush())
  await finish(p.bridge.flush())
  assert.equal(p.posts.length, 0)
  assert.equal(p.flushes.length, 1)
  assert.equal(timers.size, 0)
  gate.resolve()
  await pump()
  assert.equal(p.posts.length, 2)
  assert.deepEqual((await p.snapshot()).answers, ['ok', 'ok'])
  await finish(p.bridge.flush())
  await pump()
  assert.equal(p.posts.length, 2)
})

for (const [text, outcome] of [['ok', 'OK'], ['declined code=7', 'DECLINED'], ['error 7: denied', 'ERROR']]) {
  test('host-authoritative ' + outcome + ' result trace precedes EXECUTE and duplicate admission adds no trace', async () => {
    platform = () => Promise.resolve(text)
    const p = harness()
    await p.acquire()
    p.post()
    await pump()
    const effect = p.effects[0]
    const requests = traces.filter(record => record.event === 'EFFECT_REQUEST')
    const results = traces.filter(record => record.event === 'EFFECT_RESULT')
    assert.equal(requests.length, 1)
    assert.equal(results.length, 1)
    assert.equal(results[0].session, requests[0].session)
    assert.deepEqual(results[0].attributes, { id: effect.effectId, resultHandler: 'answered', generation: p.handle.vmGeneration, outcome })
    const execution = traces.find(record => record.event === 'EXECUTE' && record.attributes.kind === 'EFFECT_RESULT')
    assert(execution)
    assert.equal(execution.session, results[0].session)
    assert(traces.indexOf(results[0]) < traces.indexOf(execution))
    const count = traces.length
    assert.equal(p.host.postEffectResult(p.handle, effect.effectId, 'duplicate').status, 'REJECTED')
    p.binding.onEffectRequest(effect)
    await pump()
    assert.equal(traces.length, count)
    assert.equal(calls.length, 1)
    assert.deepEqual((await p.snapshot()).answers, [text])
  })
}

test('BACKPRESSURE emits no premature result trace and retry emits one host result before execution', async () => {
  const p = harness()
  await p.acquire()
  fillOnNextFrame(p)
  p.post()
  await microtasks()
  assert.equal(p.posts[0].admission.status, 'BACKPRESSURE')
  assert.equal(traces.filter(record => record.event === 'EFFECT_REQUEST').length, 1)
  assert.equal(traces.filter(record => record.event === 'EFFECT_RESULT').length, 0)
  await pump()
  const results = traces.filter(record => record.event === 'EFFECT_RESULT')
  const execution = traces.find(record => record.event === 'EXECUTE' && record.attributes.kind === 'EFFECT_RESULT')
  assert.equal(results.length, 1)
  assert.equal(results[0].attributes.outcome, 'OK')
  assert(execution)
  assert(traces.indexOf(results[0]) < traces.indexOf(execution))
  assert.equal(traces.filter(record => record.event === 'EFFECT_REQUEST').length, 1)
  assert.equal(calls.length, 1)
  assert.deepEqual((await p.snapshot()).answers, ['ok'])
})

for (const phase of ['buffered', 'consent', 'in-flight', 'queued', 'backpressure', 'barrier', 'invalidity']) {
  test('stale bridge ' + phase + ' emits exactly one drop per effect and no duplicate request trace', async () => {
    const answer = deferred(), barrier = deferred()
    let valid = true
    if (phase === 'in-flight') platform = () => answer.promise
    const p = harness({ askBeforeCalls: phase === 'consent', captureValidity: () => () => valid,
      readyToPost: () => phase !== 'queued' })
    if (phase === 'buffered') {
      p.begin(programs.refresh.vbc2)
      p.handle = await finish(p.host.acquire('', programs.refresh, config(), p.subscriber))
    } else {
      await p.acquire()
      if (phase === 'barrier') p.flushHook = () => barrier.promise
      if (phase === 'backpressure') fillOnNextFrame(p)
      p.post(phase === 'consent' ? 'pair' : 'fire')
      if (phase === 'invalidity') valid = false
      await microtasks()
    }
    const oldBinding = p.binding
    const state = p.bridge.binding
    assert(state.owners instanceof Map)
    assert.equal(state.owners.size, phase === 'invalidity' ? 0 : p.effects.length)
    if (phase === 'backpressure') assert.equal(p.posts[0].admission.status, 'BACKPRESSURE')
    const effects = [...p.effects]
    const requestTraces = traces.filter(record => record.event === 'EFFECT_REQUEST')
    assert.equal(requestTraces.length, effects.length)
    assert.equal(traces.filter(record => record.event === 'EFFECT_RESULT').length, phase === 'invalidity' ? 1 : 0)
    p.bridge.invalidate()
    assert.equal(state.owners.size, 0)
    p.bridge.invalidate()
    oldBinding.bind(p.handle)
    for (const effect of effects) oldBinding.onEffectRequest(effect)
    oldBinding.failBinding()
    answer.resolve('late')
    barrier.resolve()
    await pump()
    await finish(p.bridge.flush())
    await pump()
    const results = traces.filter(record => record.event === 'EFFECT_RESULT')
    assert.equal(results.length, effects.length)
    for (const effect of effects) {
      const matching = results.filter(record => record.attributes.id === effect.effectId &&
        record.attributes.generation === effect.vmGeneration && record.attributes.outcome === 'DROPPED_STALE')
      assert.equal(matching.length, 1)
      const requested = requestTraces.find(record => record.attributes.id === effect.effectId &&
        record.attributes.generation === effect.vmGeneration)
      assert(requested)
      assert.equal(matching[0].session, requested.session)
    }
    assert.equal(traces.filter(record => record.event === 'EFFECT_REQUEST').length, effects.length)
    assert.equal(traces.filter(record => record.event === 'EXECUTE' && record.attributes.kind === 'EFFECT_RESULT').length, 0)
    assert.equal(p.posts.filter(post => post.admission.status === 'ACCEPTED').length, 0)
    assert.equal(p.posts.length, phase === 'backpressure' ? 1 : 0)
    assert.deepEqual((await p.snapshot()).answers, [])
    assert.deepEqual(p.failures, [])
  })
}

for (const lifecycle of ['rebind', 'invalidate']) {
  test('initial prebind effects remain owned when first pending callback triggers ' + lifecycle, async () => {
    const program = compile(fixture({ refresh: true, refreshCount: 3 }))
    let interrupted = false
    const p = harness({ askBeforeCalls: true, onPending: effect => {
      p.pending.push(effect)
      if (effect !== null && !interrupted) {
        interrupted = true
        if (lifecycle === 'rebind') p.begin(program.vbc2)
        else p.bridge.invalidate()
      }
    } })
    const oldBinding = p.begin(program.vbc2)
    const acquiring = p.host.acquire('', program, config(), p.subscriber)
    assert.equal(p.effects.length, 3)
    assert.equal(calls.length, 0)
    assert.deepEqual(p.pending, [null])
    p.handle = await finish(acquiring)
    const effects = [...p.effects]
    oldBinding.bind(p.handle)
    assert(interrupted)
    assert.deepEqual(p.pending.filter(Boolean).map(effect => effect.effectId), [effects[0].effectId])
    const dropped = traces.filter(record => record.event === 'EFFECT_RESULT')
    assert.equal(dropped.length, 3)
    for (const effect of effects) {
      assert.equal(dropped.filter(record => record.attributes.id === effect.effectId &&
        record.attributes.generation === effect.vmGeneration && record.attributes.outcome === 'DROPPED_STALE').length, 1)
    }
    assert.equal(calls.length, 0)
    assert.equal(p.posts.length, 0)
    if (lifecycle === 'invalidate') p.begin(program.vbc2)
    p.binding.bind(p.handle)
    oldBinding.bind(p.handle)
    for (const effect of effects) oldBinding.onEffectRequest(effect)
    oldBinding.failBinding()
    p.post()
    assert.equal(p.pending.at(-1).effectId, p.effects[3].effectId)
    p.bridge.allowPending()
    await pump()
    assert.equal(calls.length, 1)
    assert.equal(p.posts.length, 1)
    assert.equal(p.posts[0].effectId, p.effects[3].effectId)
    assert.deepEqual((await p.snapshot()).answers, ['ok'])
    assert.deepEqual(traces.filter(record => record.event === 'EFFECT_RESULT' &&
      record.attributes.outcome === 'DROPPED_STALE'), dropped)
    assert.equal(traces.filter(record => record.event === 'EFFECT_REQUEST').length, 4)
    assert.deepEqual(p.failures, [])
  })
}

for (const settlement of ['never', 'resolve', 'reject']) {
  test('controller invalidation immediately discards unresolved adapter once; later ' + settlement + ' cannot affect new work', async () => {
    const answer = deferred()
    const discarded = [], failures = []
    platform = () => answer.promise
    const p = controller({ askBeforeCalls: false, traceOwner: {}, traceRequests: true,
      onDiscard: effect => discarded.push(effect), onFailure: (effect, error) => failures.push({ effect, error }) })
    p.controller.accept([request(1), request(2)])
    assert.equal(calls.length, 2)
    assert.deepEqual(discarded, [])
    assert.equal(traces.filter(record => record.event === 'EFFECT_RESULT').length, 0)
    p.controller.invalidate()
    assert.deepEqual(discarded.map(effect => effect.effectId), [1, 2])
    const dropped = traces.filter(record => record.event === 'EFFECT_RESULT')
    assert.deepEqual(dropped.map(record => [record.attributes.id, record.attributes.outcome]),
      [[1, 'DROPPED_STALE'], [2, 'DROPPED_STALE']])
    p.controller.invalidate()
    assert.equal(discarded.length, 2)
    assert.deepEqual(p.completed, [])
    p.epoch++
    platform = () => Promise.resolve('new generation')
    p.controller.accept([request(3, { vmGeneration: p.epoch })])
    await microtasks()
    assert.deepEqual(p.completed.map(item => [item.effect.effectId, item.text]), [[3, 'new generation']])
    const beforeSettlement = [...traces]
    if (settlement === 'resolve') answer.resolve('stale completion')
    if (settlement === 'reject') answer.reject(Error('stale rejection'))
    await pump()
    p.controller.invalidate()
    assert.deepEqual(discarded.map(effect => effect.effectId), [1, 2])
    assert.deepEqual(traces, beforeSettlement)
    assert.equal(calls.length, 3)
    assert.deepEqual(p.completed.map(item => [item.effect.effectId, item.text]), [[3, 'new generation']])
    assert.deepEqual(failures, [])
    assert.deepEqual(unhandled, [])
  })
}

for (const lifecycle of ['invalidate', 'rebind']) {
  for (const settlement of ['never', 'resolve', 'reject']) {
    test('bridge ' + lifecycle + ' immediately drops in-flight effects once; later ' + settlement + ' cannot reach new binding', async () => {
      const answer = deferred()
      platform = () => answer.promise
      const p = harness()
      await p.acquire()
      const oldBinding = p.binding, oldHandle = p.handle
      p.post('pair')
      const effects = [...p.effects]
      assert.equal(calls.length, 2)
      assert.equal(traces.filter(record => record.event === 'EFFECT_RESULT').length, 0)
      if (lifecycle === 'invalidate') p.bridge.invalidate()
      else p.begin(programs.newer.vbc2)
      const dropped = traces.filter(record => record.event === 'EFFECT_RESULT')
      assert.equal(dropped.length, 2)
      for (const effect of effects) {
        assert.equal(dropped.filter(record => record.attributes.id === effect.effectId &&
          record.attributes.generation === oldHandle.vmGeneration && record.attributes.outcome === 'DROPPED_STALE').length, 1)
      }
      assert.equal(p.posts.length, 0)
      if (lifecycle === 'invalidate') p.begin(programs.newer.vbc2)
      p.handle = await finish(p.host.replaceProgram(oldHandle, programs.newer, config()))
      p.binding.bind(p.handle)
      oldBinding.bind(p.handle)
      for (const effect of effects) oldBinding.onEffectRequest(effect)
      oldBinding.failBinding()
      assert.equal(calls.length, 2)
      platform = () => Promise.resolve('new binding')
      p.post()
      await pump()
      assert.equal(p.posts.length, 1)
      assert.equal(p.posts[0].handle, p.handle)
      assert.deepEqual((await p.snapshot()).answers, ['new binding'])
      const beforeSettlement = [...traces]
      if (settlement === 'resolve') answer.resolve('stale completion')
      if (settlement === 'reject') answer.reject(Error('stale rejection'))
      await pump()
      await finish(p.bridge.flush())
      await pump()
      assert.deepEqual(traces, beforeSettlement)
      assert.deepEqual(traces.filter(record => record.event === 'EFFECT_RESULT' &&
        record.attributes.outcome === 'DROPPED_STALE'), dropped)
      assert.equal(calls.length, 3)
      assert.equal(p.posts.length, 1)
      assert.equal(p.admissions.length, 1)
      assert.deepEqual((await p.snapshot()).answers, ['new binding'])
      assert.deepEqual(p.failures, [])
      assert.deepEqual(unhandled, [])
    })
  }
}

for (const buffered of [false, true]) {
  test('accepted effects retain request session and release strong owners with buffered=' + buffered, async () => {
    const answer = deferred()
    platform = () => answer.promise
    const p = harness()
    if (buffered) await p.acquire(programs.refresh)
    else { await p.acquire(); p.post('pair') }
    const state = p.bridge.binding
    assert(state.owners instanceof Map)
    assert.equal(state.owners.size, p.effects.length)
    const requests = traces.filter(record => record.event === 'EFFECT_REQUEST')
    assert.equal(requests.length, p.effects.length)
    for (const effect of p.effects) assert(StageTrace.effectOwner(effect))
    answer.resolve('private response payload')
    await pump()
    assert.equal(state.owners.size, 0)
    const results = traces.filter(record => record.event === 'EFFECT_RESULT')
    assert.equal(results.length, requests.length)
    for (const requested of requests) {
      const matching = results.filter(record => record.attributes.id === requested.attributes.id &&
        record.attributes.generation === requested.attributes.generation)
      assert.equal(matching.length, 1)
      assert.equal(matching[0].session, requested.session)
      assert.equal(matching[0].attributes.outcome, 'OK')
    }
    for (const effect of p.effects) p.binding.onEffectRequest(effect)
    assert.equal(state.owners.size, 0)
    p.bridge.invalidate()
    assert.equal(state.owners.size, 0)
    assert.equal(traces.filter(record => record.event === 'EFFECT_RESULT').length, results.length)
    const serialized = JSON.stringify(traces)
    for (const payload of [target, 'private response payload', 'initial']) assert(!serialized.includes(payload))
    for (const requested of requests) {
      assert.match(requested.attributes.rawTarget, /^[0-9a-f]{16}$/)
      assert.match(requested.attributes.params, /^[0-9a-f]{16}$/)
      assert.match(requested.attributes.rawMode, /^[0-9a-f]{16}$/)
    }
    assert.deepEqual(p.failures, [])
  })
}

test('same effect id and generation stay session-isolated across actors and bridge rebindings', async () => {
  const late = deferred()
  platform = () => late.promise
  const p = harness(), q = harness()
  await p.acquire()
  await q.acquire()
  p.post()
  q.post()
  const first = p.effects[0], second = q.effects[0]
  assert.equal(first.effectId, second.effectId)
  assert.equal(first.vmGeneration, second.vmGeneration)
  const firstOwner = StageTrace.effectOwner(first), secondOwner = StageTrace.effectOwner(second)
  assert(firstOwner)
  assert(secondOwner)
  assert.notEqual(firstOwner, secondOwner)
  const requests = traces.filter(record => record.event === 'EFFECT_REQUEST')
  assert.equal(requests.length, 2)
  assert.notEqual(requests[0].session, requests[1].session)
  const oldState = p.bridge.binding, oldBinding = p.binding
  p.bridge.invalidate()
  assert.equal(oldState.owners.size, 0)
  assert.equal(q.bridge.binding.owners.size, 1)
  const firstDrop = traces.filter(record => record.event === 'EFFECT_RESULT')
  assert.equal(firstDrop.length, 1)
  assert.equal(firstDrop[0].session, requests[0].session)
  await finish(p.host.release(p.handle))
  await p.acquire()
  platform = () => Promise.resolve('new actor response')
  p.post()
  const third = p.effects[1]
  assert.equal(third.effectId, first.effectId)
  assert.equal(third.vmGeneration, first.vmGeneration)
  const thirdOwner = StageTrace.effectOwner(third)
  assert(thirdOwner)
  assert.notEqual(thirdOwner, firstOwner)
  assert.notEqual(thirdOwner, secondOwner)
  oldBinding.onEffectRequest(first)
  oldBinding.failBinding()
  await pump()
  late.resolve('old actor response')
  await pump()
  const allRequests = traces.filter(record => record.event === 'EFFECT_REQUEST')
  const results = traces.filter(record => record.event === 'EFFECT_RESULT')
  assert.equal(allRequests.length, 3)
  assert.equal(new Set(allRequests.map(record => record.session)).size, 3)
  assert.equal(results.length, 3)
  for (const [index, requested] of allRequests.entries()) {
    const matching = results.filter(record => record.session === requested.session)
    assert.equal(matching.length, 1)
    assert.equal(matching[0].attributes.id, requested.attributes.id)
    assert.equal(matching[0].attributes.generation, requested.attributes.generation)
    assert.equal(matching[0].attributes.outcome, index === 0 ? 'DROPPED_STALE' : 'OK')
  }
  assert.equal(oldState.owners.size, 0)
  assert.equal(p.bridge.binding.owners.size, 0)
  assert.equal(q.bridge.binding.owners.size, 0)
  assert.deepEqual((await p.snapshot()).answers, ['new actor response'])
  assert.deepEqual((await q.snapshot()).answers, ['old actor response'])
  assert.equal(calls.length, 3)
})

test('trace configure resets weak effect owner associations and disabled associations stay absent', async () => {
  const effect = request(), owner = {}
  StageTrace.associateEffectOwner(effect, owner)
  assert.equal(StageTrace.effectOwner(effect), owner)
  assert.equal(StageTrace.effectOwner({ ...effect }), undefined)
  assert.deepEqual(Object.keys(effect).sort(), Object.keys(request()).sort())
  StageTrace.configure(true, record => traces.push(record))
  assert.equal(StageTrace.effectOwner(effect), undefined)
  StageTrace.associateEffectOwner(effect, owner)
  assert.equal(StageTrace.effectOwner(effect), owner)
  StageTrace.configure(false, record => traces.push(record))
  assert.equal(StageTrace.effectOwner(effect), undefined)
  const disabled = request(2)
  StageTrace.associateEffectOwner(disabled, owner)
  assert.equal(StageTrace.effectOwner(disabled), undefined)
  StageTrace.configure(true, record => traces.push(record))
  assert.equal(StageTrace.effectOwner(effect), undefined)
  assert.equal(StageTrace.effectOwner(disabled), undefined)
  assert.deepEqual(traces, [])
})

test('disabled host requests carry no owner association or retained bridge owners', async () => {
  StageTrace.configure(false, record => traces.push(record))
  const late = deferred()
  platform = () => late.promise
  const p = harness()
  await p.acquire(programs.refresh)
  const state = p.bridge.binding
  assert.equal(StageTrace.effectOwner(p.effects[0]), undefined)
  assert.equal(state.owners.size, 0)
  p.bridge.invalidate()
  assert.equal(state.owners.size, 0)
  late.resolve('disabled response')
  await pump()
  assert.deepEqual(traces, [])
  StageTrace.configure(true, record => traces.push(record))
  assert.equal(StageTrace.effectOwner(p.effects[0]), undefined)
  assert.equal(p.posts.length, 0)
})

const originals = {
  now: Date.now, random: Math.random, setTimeout: global.setTimeout, clearTimeout: global.clearTimeout,
  setInterval: global.setInterval, clearInterval: global.clearInterval,
  console: Object.fromEntries(['info', 'warn', 'error'].map(level => [level, console[level]]))
}
const onUnhandled = error => unhandled.push(error)
async function main() {
  let passed = 0
  process.on('unhandledRejection', onUnhandled)
  try {
    Date.now = () => now
    Math.random = () => 0.125
    global.setTimeout = (callback, delay = 0, ...args) => {
      assert.equal(typeof callback, 'function')
      const id = ++nextTimer
      timers.set(id, { callback, at: now + Math.max(0, Number(delay)), args })
      return id
    }
    global.clearTimeout = id => timers.delete(id)
    global.setInterval = () => { throw Error('unexpected interval') }
    global.clearInterval = () => { throw Error('unexpected interval cleanup') }
    for (const level of ['info', 'warn', 'error']) console[level] = () => {}
    for (const { name, run } of tests) {
      now = 100000
      timers.clear()
      disk.clear()
      calls.length = 0
      grants.clear()
      consentChecks.length = 0
      remembered.length = 0
      callbackErrors.length = 0
      unhandled.length = 0
      traces.length = 0
      StageTrace.configure(true, record => traces.push(record))
      hosts.length = 0
      bridges.length = 0
      platform = () => Promise.resolve('ok')
      try {
        await run()
        await new Promise(resolve => setImmediate(resolve))
        assert.deepEqual(callbackErrors, [], 'subscriber fixture callback failed')
        assert.deepEqual(unhandled, [], 'unhandled asynchronous callback failure')
        passed++
        console.log('PASS ' + name)
      } catch (error) {
        originals.console.error('FAIL ' + name + '\n' + error.stack)
        process.exitCode = 1
      } finally {
        for (const bridge of bridges) bridge.invalidate()
        for (const host of hosts) await finish(host.dispose())
        timers.clear()
      }
    }
  } finally {
    StageTrace.configure(false)
    Date.now = originals.now
    Math.random = originals.random
    global.setTimeout = originals.setTimeout
    global.clearTimeout = originals.clearTimeout
    global.setInterval = originals.setInterval
    global.clearInterval = originals.clearInterval
    Object.assign(console, originals.console)
    process.removeListener('unhandledRejection', onUnhandled)
  }
  console.log(`host-effects-check: ${passed}/${tests.length} deterministic actual-source scenarios passed`)
  console.log('Scope: real InProcessHost/AppActor/compiler/VM/ProjectStore/EffectController/HostEffectsBridge/executeEffect; module-mocked adapters and consent, in-memory files and fake clock/timers; no platform, device, model or services.')
}
main().catch(error => {
  originals.console.error(error.stack)
  process.exitCode = 1
})
