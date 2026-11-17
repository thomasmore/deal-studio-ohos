'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const baseline = require('./stage-trace-baseline')
const options = baseline.parseArgs(process.argv.slice(2))
const {loadSource, loadVera, sourceRoot} = require('./source-loader')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const {createPreview, effectRequest, seedEffects} = require('./preview-fixture')
const fixtures = new Set()
const traceFile = path.join(sourceRoot, 'runtime/trace/StageTrace.ets')
if (!fs.existsSync(traceFile)) {
  console.error('stage-trace-check: BLOCKED: runtime/trace/StageTrace.ets is not present')
  process.exit(2)
}
const {StageTrace} = loadSource(traceFile)
for (const name of ['configure', 'enabled', 'emit', 'digest', 'snapshot', 'frame', 'request']) {
  assert.equal(typeof StageTrace[name], 'function', 'StageTrace.' + name)
}
const renderer = fs.readFileSync(path.join(sourceRoot, 'components/VeraPreview.ets'), 'utf8')
const required = ['EXECUTE', 'INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE', 'EFFECT_REQUEST', 'EFFECT_RESULT',
  'FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_APPLY', 'FIELD_ACTION_DROP', 'TICK_DELIVERED', 'TICK_SKIPPED',
  'SURFACE_FRAME', 'SURFACE_SKIPPED', 'DRAW', 'RESUME_STATE_RELOAD', 'TIMERS_STOPPED', 'ERROR']
const results = [], observed = new Set()
const secret = 'private-payload-7f3c9a'
let captured = [], segments = [], rendererScenarios = false
const scenarios = []
function capture() {
  const records = [], full = []
  segments.push(full)
  StageTrace.configure(true, record => { records.push(record); full.push(record); captured.push(record); observed.add(record.event) })
  assert.equal(StageTrace.enabled(), true)
  return records
}
function events(records) { return records.map(record => record.event) }
function sequence(records, expected) {
  let at = -1
  for (const event of expected) {
    at = records.findIndex((record, index) => index > at && record.event === event)
    assert(at >= 0, expected.join(' -> ') + '; observed ' + events(records).join(' -> '))
  }
}
function privateRecords(records, sensitive = [secret]) {
  const encoded = JSON.stringify(records)
  for (const value of sensitive) assert(!encoded.includes(value), 'raw payload leaked: ' + value)
}
async function test(name, action) {
  captured = []; segments = []
  const failures = []
  try {
    await action()
    for (const record of captured) {
      assert.equal(typeof record.session, 'number')
      assert(record.session > 0)
      assert.equal(typeof record.event, 'string')
      assert.equal(typeof record.at, 'number')
      assert(Number.isFinite(record.at))
      assert(record.attributes && typeof record.attributes === 'object')
    }
    privateRecords(captured)
  } catch (error) {
    failures.push(error.stack || String(error))
  } finally {
    StageTrace.configure(false)
    for (const fixture of fixtures) {
      try {
        fixture.p.fieldEdits.clear()
        if (!fixture.p.disposed) fixture.p.aboutToDisappear()
        await fixture.p.operations
      } catch (error) {
        failures.push(error.stack || String(error))
      } finally {
        try {
          await fixture.runtime.dispose()
          assert.equal(fixture.timers.size, 0)
        } catch (error) {
          failures.push(error.stack || String(error))
        }
      }
    }
    fixtures.clear()
  }
  results.push(failures.length ? {name, result: 'FAIL', error: failures.join('\n')} : {name, result: 'PASS'})
  if (!failures.length && rendererScenarios && segments.length) scenarios.push({name, segments})
}
function declaration(prefix, source = renderer) {
  const start = source.indexOf(prefix)
  assert(start >= 0, prefix)
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(start))
  let depth = 0
  while (scanner.scan() !== ts.SyntaxKind.EndOfFileToken) {
    if (scanner.getToken() === ts.SyntaxKind.OpenBraceToken) depth++
    if (scanner.getToken() === ts.SyntaxKind.CloseBraceToken && --depth === 0) return source.slice(start, start + scanner.getTextPos())
  }
  throw Error('Unclosed declaration: ' + prefix)
}
function devParameterProbe() {
  const source = fs.readFileSync(path.join(sourceRoot, 'entryability/EntryAbility.ets'), 'utf8')
  const method = declaration('  private extractDevParameters(', source)
  const extracts = [...method.matchAll(/this\.(extract\w+)\(want\)/g)].map(match => match[1])
  assert(extracts.includes('extractTrace'))
  const trace = declaration('  private extractTrace(', source)
  const compiled = ts.transpileModule('class Probe {\n' + method + '\n' + trace + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020}, reportDiagnostics: true})
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0, 'launch probe syntax')
  const toggles = [], calls = []
  const mocks = {...loadSource(path.join(sourceRoot, 'components/LaunchTrust.ets')), DOMAIN: 0,
    hilog: {info() {}, warn() {}}, StageTrace: {configure(enabled) { toggles.push(enabled); StageTrace.configure(enabled) }}}
  const Probe = new Function(...Object.keys(mocks), compiled.outputText + '\nreturn Probe')(...Object.values(mocks))
  const p = new Probe()
  for (const name of extracts) {
    const method = p[name]
    p[name] = function (want) {
      calls.push({name, want})
      if (name === 'extractTrace') return method.call(this, want)
    }
  }
  return {p, toggles, calls, extracts}
}
function probe(askBeforeCalls = false) {
  global.ObservedV2 = value => value
  global.Trace = () => {}
  const V = loadVera('VeraInterpreter'), U = loadVera('VeraUi')
  let now = 10000, handle = 0, paints = 0, p, frameEffects = []
  const calls = [], snapshots = [], saves = [], replies = [], loads = [], timers = new Map(), disk = new Map()
  const faults = {save: false, view: false, draw: false, media: false}
  const media = {matches: false, on(event, callback) { this.callback = callback }, off() {}}
  const surface = Object.assign(new U.VeraUiNode(), {kind: 'surface', action: 'step', label: 'draw', minimum: 100, maximum: 100, style: 'default'})
  const root = () => Object.assign(new U.VeraUiNode(), {kind: 'column', children: [surface], text: secret})
  const hosts = []
  class Host {
    constructor() { this.effectsAllowed = false; this.pendingEffects = []; hosts.push(this) }
  }
  class Machine {
    constructor(module, host) { this.host = host }
    execute(action, args = []) {
      calls.push({action, allowed: this.host.effectsAllowed, args})
      if (action === 'init') return new V.VeraStringValue(secret)
      if (action === 'view') { if (faults.view) throw Error('fixture view'); return [root()] }
      if (action === 'draw') { if (faults.draw) throw Error('fixture draw'); return [] }
      if (action === 'trap') { this.host.pendingEffects.push(effect()); throw Error('fixture trap') }
      if (action === 'step') { this.host.pendingEffects.push(...frameEffects); frameEffects = []; return args[0] }
      if (action === 'tick') return args[0]
      return args[1] || args[0]
    }
    stepsExecuted() { return 1 }
  }
  const platform = (...args) => new Promise((resolve, reject) => replies.push({args, resolve, reject}))
  const mocks = {StageTrace, consent: {has: () => false, remember() {}},
    paintGfx() { paints++ }, runRawIntent: platform, runSdkAdapter: platform,
    scheduleCardRefresh() {}, Date: {now: () => now}, console: {info() {}, warn() {}, error() {}},
    setInterval(callback, interval) { timers.set(++handle, {callback, interval}); return handle },
    clearInterval(id) { timers.delete(id) },
    store: {loadState(project, version) { loads.push([project, version]); return disk.get(project + '/' + version) || '' },
      saveState(project, version, stamp, encoded) {
        if (faults.save) throw Error('fixture save')
        disk.set(project + '/' + version, encoded); saves.push(encoded)
      }}}
  const dependencies = {
    '../vera/VeraInterpreter': {...V, VirtualMachine: Machine,
      deserializeVbc2: value => { if (value === 'broken') throw Error('fixture bytecode'); return {functions: []} }},
    '../vera/VeraUi': {UiHostEnvironment: Host, decodeVeraUi: value => value},
    '../vera/VeraGfx': {...loadVera('VeraGfx'), decodeGfx: value => value},
    '../vera/VeraStateCarry': loadVera('VeraStateCarry'), '../vera/ProjectStore': {store: mocks.store},
    './trace/StageTrace': {StageTrace}, '../vera/VeraConsentStore': {consent: mocks.consent},
    '../vera/VeraIntents': {runRawIntent: platform}, '../vera/VeraSdkBackend': {runSdkAdapter: platform}
  }
  const cache = new Map()
  function load(file) {
    file = path.resolve(file)
    if (cache.has(file)) return cache.get(file).exports
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}, reportDiagnostics: true})
    assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [], file)
    const mod = {exports: {}}
    cache.set(file, mod)
    new Function('require', 'module', 'exports', 'Date', 'console', compiled.outputText)(id => {
      if (Object.hasOwn(dependencies, id)) return dependencies[id]
      assert(id.startsWith('.'), 'unexpected runtime dependency ' + id)
      return load(path.resolve(path.dirname(file), id + '.ets'))
    }, mod, mod.exports, mocks.Date, mocks.console)
    return mod.exports
  }
  const {InProcessHost, HostOperationFailure} = load(path.join(sourceRoot, 'runtime/InProcessHost.ets'))
  const {HostEffectsBridge} = load(path.join(sourceRoot, 'runtime/HostEffectsBridge.ets'))
  const runtime = new InProcessHost(() => now)
  const made = createPreview({runtime, HostOperationFailure, HostEffectsBridge, mocks, askBeforeCalls})
  p = made.probe
  const createActor = runtime.createActor
  runtime.createActor = function(record) {
    p.traceOwner = record
    p.effectsBridge.options.traceOwner = record
    createActor.call(this, record)
    assert.strictEqual(record.actor.traceOwner, p.traceOwner)
    assert.strictEqual(p.effectsBridge.options.traceOwner, p.traceOwner)
  }
  Object.assign(p, {vbc2: 'fixture', persistKey: 'fixture/version', appForeground: true,
    stamp: () => 'fixture-stamp', onStateSnapshot: encoded => snapshots.push(encoded),
    partPoses: () => [], flushFields() {}, reconcileFields() {}, reconcileTheme() {},
    reconcileTimers() {}, reconcileSpin() {}, reconcileMotion() {},
    reconcileBackHandler() {}, reconcileSurfaces() {}, countFrame() {}, t: () => ({}),
    getUIContext: () => ({vp2px: value => value, getMediaQuery: () => ({matchMediaSync() {
      if (faults.media) throw Error('fixture media')
      return media
    }})})})
  const f = {p, runtime, calls, snapshots, saves, replies, loads, timers, disk, V, surface, faults, media,
    actor: () => runtime.registry.get(p.handle.appId).actor,
    host: () => hosts.at(-1), state: async () => V.decodeRuntimeValue(JSON.parse(await runtime.requestSnapshot(p.handle))),
    deliverEffects(effects) { seedEffects(p, effects) },
    frameEffects(effects) { frameEffects = effects },
    request: value => effectRequest(p, value),
    controller: () => p.effectsBridge.binding.controller,
    paints: () => paints,
    elapse(ms) { now += ms }, fire() { assert.equal(timers.size, 1); [...timers.values()][0].callback() }}
  fixtures.add(f)
  return f
}
function payload(value) {
  return {kind: typeof value === 'number' ? 'NUMBER' : 'STRING', num: typeof value === 'number' ? value : 0,
    str: typeof value === 'string' ? value : '', bool: false, phase: '', id: 0, x: 0, y: 0}
}
async function settled(p) {
  for (let turn = 0; turn < 100; turn++) {
    const operations = p.operations
    await operations
    await settle()
    if (operations === p.operations && !p.postDrain && !p.posting && !p.postingEffect &&
        p.inFlight === null && p.posts.length === 0 && !p.fieldActionsNeedResume &&
        p.effectsBridge?.binding?.flushing == null) return
  }
  throw Error('Preview lifecycle did not settle')
}
async function loaded(p) { p.load(); await settled(p) }
async function snapshot(p) { return p.runtime.requestSnapshot(p.handle) }
function effect(id = 1, target = secret) {
  return {id, kind: 'sdk', fn: 'call', rawTarget: target, rawMode: '', values: new Map([['body', secret]]), resultHandler: 'answer'}
}
const settle = () => new Promise(resolve => setImmediate(resolve))
async function main() {
  await test('disabled by default and disabled helpers neither hash nor traverse payloads', async () => {
    assert.equal(StageTrace.enabled(), false)
    const records = [], digest = StageTrace.digest
    let hashes = 0, accesses = 0
    const rejectAccess = () => { accesses++; throw Error('disabled payload traversed') }
    const owner = {}, inaccessible = new Proxy({}, {get: rejectAccess, ownKeys: rejectAccess, getOwnPropertyDescriptor: rejectAccess})
    StageTrace.configure(false, record => records.push(record))
    StageTrace.digest = () => { hashes++; throw Error('disabled digest called') }
    try {
      StageTrace.emit(owner, 'EXECUTE', inaccessible)
      StageTrace.snapshot(owner, secret)
      StageTrace.frame(owner, inaccessible, true)
      StageTrace.request(owner, 1, secret, inaccessible, 'answer')
      assert.equal(accesses, 0)
      assert.equal(hashes, 0)
      assert.deepEqual(records, [])
    } finally { StageTrace.digest = digest }
  })
  await test('records have stable per-preview sessions and toggles reset allocation', async () => {
    const records = capture(), a = {}, b = {}
    StageTrace.emit(a, 'EXECUTE')
    StageTrace.emit(b, 'EXECUTE')
    StageTrace.emit(a, 'SAVE', {id: 1})
    assert.equal(records.length, 3)
    assert.equal(records[0].session, records[2].session)
    assert.notEqual(records[0].session, records[1].session)
    assert.deepEqual(records[2].attributes, {id: 1})
    StageTrace.configure(false)
    const reset = capture()
    StageTrace.emit(b, 'EXECUTE')
    assert.equal(reset[0].session, records[0].session)
    assert.notEqual(reset[0].session, records[1].session)
  })
  await test('emit copies every declared attribute without mutating inputs and preserves falsy values', async () => {
    const records = capture(), owner = {}
    const attributes = Object.freeze({entry: '', kind: 'ACTION', action: 'tap', digest: 'state-hash', treeHash: 'tree-hash',
      result: 'OK', id: 0, rawTarget: 'target-hash', rawMode: 'mode-hash', generation: 0, params: 'params-hash',
      resultHandler: 'answer', outcome: 'OK', reason: 'BACKGROUND', tickerId: 'clock:private-ticker-82b6',
      class: 'CompileError', nodeId: 0, actions: Object.freeze(['step']), draws: Object.freeze(['draw']),
      save: 'NOT_DUE', reveal: false, changed: false})
    const parsed = ts.createSourceFile('StageTrace.ts', fs.readFileSync(traceFile, 'utf8'), ts.ScriptTarget.Latest, true)
    const declared = parsed.statements.find(node => ts.isInterfaceDeclaration(node) && node.name.text === 'StageTraceAttributes')
    assert(declared, 'StageTraceAttributes must exist')
    assert.deepEqual(Object.keys(attributes).sort(), declared.members.map(member => member.name.getText(parsed)).sort(),
      'the fixture must exercise every declared StageTrace attribute')
    const before = {...attributes}, expected = {...attributes, tickerId: StageTrace.digest(attributes.tickerId)}
    StageTrace.emit(owner, 'EXECUTE', attributes)
    assert.equal(records.length, 1)
    assert.notStrictEqual(records[0].attributes, attributes)
    assert.deepEqual(records[0].attributes, expected)
    assert.deepEqual(attributes, before)
    for (const [key, value] of Object.entries(attributes)) {
      const single = Object.freeze({[key]: value})
      StageTrace.emit(owner, 'EXECUTE', single)
      assert.deepEqual(records.at(-1).attributes, {[key]: expected[key]}, key)
      assert.notStrictEqual(records.at(-1).attributes, single)
      assert.deepEqual(single, {[key]: value})
    }
    assert.equal(records.length, Object.keys(attributes).length + 1)
    privateRecords(records, [attributes.tickerId])
  })
  await test('emit omits undefined optional attributes', async () => {
    const records = capture()
    const parsed = ts.createSourceFile('StageTrace.ts', fs.readFileSync(traceFile, 'utf8'), ts.ScriptTarget.Latest, true)
    const declared = parsed.statements.find(node => ts.isInterfaceDeclaration(node) && node.name.text === 'StageTraceAttributes')
    assert(declared, 'StageTraceAttributes must exist')
    const attributes = Object.freeze(Object.fromEntries(declared.members.map(member => [member.name.getText(parsed), undefined])))
    StageTrace.emit({}, 'EXECUTE', attributes)
    assert.equal(records.length, 1)
    assert.deepEqual(records[0].attributes, {})
    assert.notStrictEqual(records[0].attributes, attributes)
    assert(Object.values(attributes).every(value => value === undefined))
  })
  await test('snapshot/frame/request payloads are digested, deterministic and distinguish changes', async () => {
    const records = capture(), owner = {}, target = 'private-target-4e0d', key = 'private-key-6c91'
    const digest = StageTrace.digest(secret)
    assert.equal(typeof digest, 'string')
    assert(digest.length > 0 && digest !== secret)
    assert.equal(StageTrace.digest(secret), digest)
    assert.notEqual(StageTrace.digest(secret + '!'), digest)
    StageTrace.snapshot(owner, secret)
    StageTrace.frame(owner, {kind: 'text', text: secret, children: []}, true)
    StageTrace.frame(owner, null, false)
    StageTrace.request(owner, 7, target, new Map([[key, secret]]), 'answer')
    sequence(records, ['SNAPSHOT', 'FRAME', 'FRAME', 'EFFECT_REQUEST'])
    assert(JSON.stringify(records[0].attributes).includes(digest), 'snapshot digest missing')
    assert(JSON.stringify(records[3].attributes).includes(StageTrace.digest(target)), 'target digest missing')
    const before = JSON.stringify(records[3].attributes)
    StageTrace.request(owner, 7, target, new Map([[key, secret + '!']]), 'answer')
    assert.notEqual(JSON.stringify(records[4].attributes), before, 'request must distinguish parameter changes')
    StageTrace.frame(owner, {kind: 'text', text: secret, children: []}, true)
    assert.deepEqual(records[5].attributes, records[1].attributes, 'frame digest must be deterministic')
    StageTrace.frame(owner, {kind: 'text', text: secret + '!', children: []}, true)
    assert.notDeepEqual(records[6].attributes, records[1].attributes, 'frame must distinguish changed content')
    StageTrace.snapshot(owner, secret + '!')
    assert.notDeepEqual(records[7].attributes, records[0].attributes, 'snapshot must distinguish changed state')
    privateRecords(records, [secret, target, key])
  })
  await test('state-derived ticker IDs are hashed stably without mutating caller attributes', async () => {
    const records = capture(), owner = {}, state = Object.freeze({ticker: 'private-ticker-82b6'})
    const tickerId = 'clock:' + state.ticker
    const attributes = Object.freeze({tickerId, reason: 'BACKGROUND'})
    const before = {...attributes}
    StageTrace.emit(owner, 'TICK_SKIPPED', attributes)
    StageTrace.emit(owner, 'TICK_SKIPPED', attributes)
    StageTrace.emit(owner, 'TICK_DELIVERED', {tickerId, action: 'tick'})
    StageTrace.emit(owner, 'TICK_DELIVERED', {tickerId: tickerId + '!', action: 'tick'})
    assert.equal(records.length, 4)
    for (const record of records.slice(0, 3)) assert.equal(record.attributes.tickerId, StageTrace.digest(tickerId))
    assert.notEqual(records[3].attributes.tickerId, records[0].attributes.tickerId)
    assert.notStrictEqual(records[0].attributes, attributes)
    assert.deepEqual(attributes, before)
    assert.equal(state.ticker, 'private-ticker-82b6')
    privateRecords(records, [state.ticker, tickerId])
  })
  await test('request mode hashes distinguish modes and preserve request generations and inputs', async () => {
    const records = capture(), owner = {}, target = 'private-target-4e0d', mode = 'private-mode-9d52'
    const values = new Map([['private-key-6c91', secret]])
    const before = [...values]
    StageTrace.request(owner, 7, target, values, 'answer', mode, 23)
    StageTrace.request(owner, 7, target, values, 'answer', mode, 23)
    StageTrace.request(owner, 7, target, values, 'answer', mode + '!', 23)
    StageTrace.request(owner, 7, target, values, 'answer', mode, 24)
    StageTrace.request(owner, 7, target, values, 'answer')
    assert.equal(records.length, 5)
    const expected = {id: 7, rawTarget: StageTrace.digest(target), params: StageTrace.digest(JSON.stringify(before)),
      resultHandler: 'answer', rawMode: StageTrace.digest(mode), generation: 23}
    assert.deepEqual(records[0].attributes, expected)
    assert.deepEqual(records[1].attributes, expected)
    assert.deepEqual(records[2].attributes, {...expected, rawMode: StageTrace.digest(mode + '!')})
    assert.notEqual(records[2].attributes.rawMode, expected.rawMode)
    assert.deepEqual(records[3].attributes, {...expected, generation: 24})
    assert.deepEqual(records[4].attributes, {...expected, rawMode: StageTrace.digest(''), generation: 0})
    assert.deepEqual([...values], before)
    privateRecords(records, [secret, target, mode, ...values.keys()])
  })
  await test('native stageTrace string flags toggle tracing through extractDevParameters', async () => {
    const {p, toggles, calls, extracts} = devParameterProbe()
    for (const identity of [{}, {'ohos.aafwk.param.callerNativeName': 'shell'},
      {'ohos.aafwk.param.callerUid': 0}, {'ohos.aafwk.param.callerUid': '2000'}]) {
      for (const [flag, enabled] of [['1', true], ['0', false]]) {
        StageTrace.configure(!enabled)
        toggles.length = 0; calls.length = 0
        const want = Object.freeze({parameters: Object.freeze({...identity, stageTrace: flag})})
        p.extractDevParameters(want)
        assert.deepEqual(toggles, [enabled])
        assert.equal(StageTrace.enabled(), enabled)
        assert.deepEqual(calls.map(call => call.name), extracts)
        assert(calls.every(call => call.want === want))
      }
    }
  })
  await test('app callers cannot enable or disable stageTrace even with a native name', async () => {
    const {p, toggles, calls} = devParameterProbe()
    for (const identity of [{'ohos.aafwk.param.callerBundleName': 'fixture.app'},
      {'ohos.aafwk.param.callerAppId': 'fixture-id'}, {'ohos.aafwk.param.callerUid': 10000},
      {'ohos.aafwk.param.callerUid': '20000001'}]) {
      for (const enabled of [false, true]) for (const flag of ['1', '0']) {
        StageTrace.configure(enabled)
        const want = {parameters: {...identity, 'ohos.aafwk.param.callerNativeName': 'shell', stageTrace: flag}}
        p.extractDevParameters(want)
        assert.equal(StageTrace.enabled(), enabled)
        assert.deepEqual(toggles, [])
        assert.deepEqual(calls, [])
      }
    }
  })
  await test('absent or invalid native stageTrace flags leave tracing configuration unchanged', async () => {
    const {p, toggles, calls, extracts} = devParameterProbe()
    const wants = [{}, {parameters: undefined}, {parameters: null}, {parameters: {}},
      ...[undefined, null, '', 'true', 'false', ' 1', '0 ', '2', 1, 0, true, false, {}, ['1']]
        .map(stageTrace => ({parameters: {stageTrace}}))]
    for (const enabled of [false, true]) for (const want of wants) {
      const records = []
      StageTrace.configure(enabled, record => records.push(record))
      calls.length = 0
      p.extractDevParameters(want)
      assert.equal(StageTrace.enabled(), enabled)
      assert.deepEqual(toggles, [])
      assert.deepEqual(calls.map(call => call.name), want.parameters == null ? [] : extracts)
      StageTrace.emit({}, 'EXECUTE')
      assert.equal(records.length, enabled ? 1 : 0)
    }
  })
  await test('a throwing sink cannot escape any public emission helper', async () => {
    const owner = {}
    let calls = 0
    StageTrace.configure(true, () => { calls++; throw Error('fixture sink') })
    for (const emit of [() => StageTrace.emit(owner, 'EXECUTE'), () => StageTrace.snapshot(owner, secret),
      () => StageTrace.frame(owner, {kind: 'text', text: secret, children: []}, false),
      () => StageTrace.request(owner, 1, secret, new Map([['body', secret]]), 'answer')]) assert.doesNotThrow(emit)
    assert.equal(calls, 4)
  })
  observed.clear()
  rendererScenarios = true
  await test('real renderer load/action order, reveal and payload privacy', async () => {
    const records = capture(), f = probe(), {p, V} = f
    await loaded(p)
    assert.equal(p.error, '')
    sequence(records, ['EXECUTE', 'SNAPSHOT', 'FRAME'])
    assert.equal(f.snapshots.length, 1)
    records.length = 0
    p.dispatch('tap', payload(secret))
    await settled(p)
    assert.equal(p.error, '')
    sequence(records, ['EXECUTE', 'INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE'])
    assert.equal(f.saves.length, 1)
    assert.equal(f.calls.find(call => call.action === 'tap').allowed, true)
    assert(f.calls.filter(call => call.action === 'view').every(call => !call.allowed))
    assert(records.find(record => record.event === 'FRAME').attributes.reveal === true)
    assert.equal(new Set(records.map(record => record.session)).size, 1)
    privateRecords(records)
  })
  await test('real previews have independent sessions and disabled rendering never hashes', async () => {
    const records = capture(), first = probe(), second = probe()
    await loaded(first.p)
    const split = records.length
    await loaded(second.p)
    const firstSessions = new Set(records.slice(0, split).map(record => record.session))
    const secondSessions = new Set(records.slice(split).map(record => record.session))
    assert.equal(firstSessions.size, 2)
    assert.equal(secondSessions.size, 2)
    assert([...firstSessions].every(session => !secondSessions.has(session)))
    for (const group of [records.slice(0, split), records.slice(split)]) {
      assert.equal(new Set(group.filter(record => record.event !== 'TIMERS_STOPPED').map(record => record.session)).size, 1)
    }
    StageTrace.configure(false)
    const digest = StageTrace.digest, count = records.length
    let hashes = 0
    StageTrace.digest = () => { hashes++; throw Error('disabled renderer digest called') }
    try {
      await loaded(first.p)
      first.p.dispatch('tap', payload(secret))
      await settled(first.p)
      assert.equal(first.p.error, '')
      assert.equal(first.saves.length, 1)
      assert.equal(hashes, 0)
      assert.equal(records.length, count)
    } finally { StageTrace.digest = digest }
  })
  await test('real renderer traps clear effects, stop timers and never commit input', async () => {
    const records = capture(), f = probe(), {p, V, replies, saves} = f
    await loaded(p); records.length = 0
    const state = await snapshot(p)
    p.dispatch('trap', payload(secret))
    await settled(p)
    assert.match(p.error, /Action error: fixture trap/)
    assert.equal(await snapshot(p), state)
    assert.equal(f.host().effectsAllowed, false)
    assert.deepEqual(f.host().pendingEffects, [])
    assert.deepEqual(replies, [])
    assert.deepEqual(saves, [])
    sequence(records, ['EXECUTE', 'ERROR', 'TIMERS_STOPPED'])
    for (const event of ['INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE', 'EFFECT_REQUEST']) assert(!events(records).includes(event), event)
    p.vbc2 = 'broken'; records.length = 0; await loaded(p)
    assert.equal(p.error, 'ACTOR_NOT_READY')
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'INIT'))
    privateRecords(records)
  })
  await test('real field-action queue blocks composition, applies in order and drops stale actions', async () => {
    const records = capture(), {p, V, calls} = probe()
    await loaded(p); records.length = 0; calls.length = 0
    const field = {}, edit = {composing: true}
    p.fieldEdits.set(field, edit)
    p.dispatchFieldAction('tap', payload(secret), true, null, 'HANDLER')
    sequence(records, ['FIELD_ACTION_ENQUEUE'])
    assert.equal(calls.length, 0)
    edit.composing = false
    p.fieldEdits.clear(); p.resumeFieldActions()
    await settled(p)
    sequence(records, ['FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_APPLY', 'EXECUTE', 'INPUT_APPLIED'])
    records.length = 0
    p.fieldEdits.set(field, {composing: true})
    p.dispatchFieldAction('stale', payload(secret))
    p.effectGeneration++; p.fieldEdits.clear(); p.resumeFieldActions()
    sequence(records, ['FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_DROP'])
    assert(!calls.some(call => call.action === 'stale'))
    privateRecords(records)
  })
  await test('real ticker gates preserve elapsed time and trace delivered/skipped ticks', async () => {
    const records = capture(), f = probe(), {p, calls} = f
    await loaded(p); calls.length = 0; records.length = 0
    const state = await f.state(), tickerId = 'clock:' + state.value
    const config = Object.freeze({interval: 1000, action: 'tick'})
    p.startTimer(tickerId, config)
    p.appForeground = false; f.elapse(1000); f.fire()
    assert(!calls.some(call => call.action === 'tick'))
    assert(events(records).includes('TICK_SKIPPED'))
    p.appForeground = true; f.elapse(1000); f.fire()
    await settled(p)
    sequence(records, ['TICK_SKIPPED', 'TICK_DELIVERED', 'EXECUTE', 'INPUT_APPLIED'])
    assert.equal(calls.find(call => call.action === 'tick').args[1].value, 2000)
    for (const event of ['TICK_SKIPPED', 'TICK_DELIVERED']) {
      assert.equal(records.find(record => record.event === event).attributes.tickerId, StageTrace.digest(tickerId))
    }
    records.length = 0; calls.length = 0
    p.fieldEdits.set({}, {composing: true}); f.fire()
    assert(events(records).includes('TICK_SKIPPED')); assert.equal(calls.length, 0)
    const ticks = records.filter(record => record.event === 'TICK_SKIPPED' || record.event === 'TICK_DELIVERED')
    assert(ticks.length > 0)
    assert(ticks.every(record => record.attributes.tickerId === StageTrace.digest(tickerId)))
    assert.deepEqual([...p.timerConfigs], [[tickerId, config]])
    assert.strictEqual(p.timerConfigs.get(tickerId), config)
    assert.equal(state.value, secret)
    assert.deepEqual(config, {interval: 1000, action: 'tick'})
    privateRecords(captured, [secret, tickerId])
    p.fieldEdits.clear(); p.stopAllTimers('RELEASE')
    assert.equal(f.timers.size, 0)
    assert(events(records).includes('TIMERS_STOPPED'))
    privateRecords(records)
  })
  await test('real surface gates, frame execution and draw keep effects fenced', async () => {
    const records = capture(), f = probe(), {p, calls, surface} = f
    await loaded(p); p.liveSurfaces = [surface]
    p.surfaces.set(surface, {ready: true, visible: true, width: 100, height: 100, ctx: {}})
    records.length = 0; calls.length = 0
    p.pageHidden = true; p.surfaceFrame()
    assert(events(records).includes('SURFACE_SKIPPED')); assert.equal(calls.length, 0)
    p.pageHidden = false; p.fieldEdits.set({}, {composing: true}); p.surfaceFrame()
    assert.equal(calls.length, 0)
    p.fieldEdits.clear(); records.length = 0; f.elapse(16); p.surfaceFrame()
    await settled(p)
    sequence(records, ['EXECUTE', 'DRAW', 'SURFACE_FRAME'])
    assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
      {actions: ['step'], draws: ['draw'], save: 'DONE'})
    assert.equal(p.error, '')
    assert.equal(calls.find(call => call.action === 'step').allowed, true)
    assert.equal(calls.find(call => call.action === 'draw').allowed, false)
    assert.equal(f.paints(), 1)
    surface.action = 'trap'; records.length = 0; p.surfaceFrame()
    await settled(p)
    sequence(records, ['ERROR', 'TIMERS_STOPPED'])
    assert.equal(p.posting, false); assert.equal(p.postDrain, false)
    assert.equal(f.host().effectsAllowed, false)
    privateRecords(records)
  })
  await test('real effect requests/results route current replies and gate stale callbacks', async () => {
    const records = capture(), f = probe(), {p, V, replies, calls} = f
    await loaded(p); records.length = 0
    f.deliverEffects([effect()])
    assert.equal(replies.length, 1)
    assert(events(records).includes('EFFECT_REQUEST'))
    replies[0].resolve(secret); await settled(p)
    sequence(records, ['EFFECT_REQUEST', 'EFFECT_RESULT', 'EXECUTE', 'INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE'])
    assert(calls.find(call => call.action === 'answer').args[1] instanceof V.VeraStringValue)
    assert.equal(new Set(records.map(record => record.session)).size, 1)
    privateRecords(records)
    records.length = 0
    f.deliverEffects([effect(2)]); replies.at(-1).reject(Error(secret)); await settled(p)
    sequence(records, ['EFFECT_REQUEST', 'EFFECT_RESULT', 'INPUT_APPLIED'])
    assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.generation, p.frameVmGeneration)
    assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.outcome, 'ERROR')
    assert.equal(calls.filter(call => call.action === 'answer').at(-1).args[1].value, 'error: ' + secret)
    privateRecords(records)
    for (const gate of ['generation', 'disposed']) for (const rejected of [false, true]) {
      const stale = probe(), q = stale.p
      await loaded(q)
      stale.deliverEffects([effect()])
      const reply = stale.replies[0], count = stale.calls.filter(call => call.action === 'answer').length
      const generation = q.frameVmGeneration
      records.length = 0
      if (gate === 'generation') { q.vbc2 = 'replacement'; await loaded(q) }
      else { q.aboutToDisappear(); await q.operations }
      if (rejected) reply.reject(Error(secret)); else reply.resolve(secret)
      await settled(q)
      assert.equal(stale.calls.filter(call => call.action === 'answer').length, count)
      assert(!events(records).includes('INPUT_APPLIED'))
      const terminals = records.filter(record => record.event === 'EFFECT_RESULT')
      assert.equal(terminals.length, 1)
      assert.equal(terminals[0].attributes.generation, generation)
      assert.equal(terminals[0].attributes.outcome, 'DROPPED_STALE')
      privateRecords(records)
    }
  })
  await test('resume reports both reload decisions without extra store loads', async () => {
    const records = capture(), {p, V, disk, loads} = probe()
    await loaded(p)
    p.dispatch('tap', payload(secret)); await settled(p)
    records.length = 0; loads.length = 0
    p.onResume(); await settled(p)
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, false)
    assert.equal(loads.length, 1)
    records.length = 0; loads.length = 0
    disk.set('fixture/version', JSON.stringify(V.encodeRuntimeValue(new V.VeraStringValue(secret + '!'))))
    p.onResume(); await settled(p)
    sequence(records, ['RESUME_STATE_RELOAD', 'FRAME'])
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, true)
    assert.equal(loads.length, 2)
    assert.equal(V.decodeRuntimeValue(JSON.parse(await snapshot(p))).value, secret + '!')
    p.persistKey = ''; p.onPreviewOnlyChanged(); await settled(p)
    records.length = 0; loads.length = 0; p.onResume(); await settled(p)
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, false)
    assert.equal(loads.length, 0)
    privateRecords(records)
  })
  await test('surface summaries follow actual save gates and executed draws after effects and view', async () => {
    for (const pendingBefore of [false, true]) {
      const records = capture(), f = probe(), {p, surface, saves, calls} = f
      await loaded(p); p.liveSurfaces = [surface]
      p.surfaces.set(surface, {ready: true, visible: true, width: 100, height: 100, ctx: {}})
      p.startSurfaceLoop()
      const loopStartedAt = p.surfaceLoopStartedAt
      assert.equal(typeof loopStartedAt, 'number')
      const field = {}
      if (pendingBefore) p.fieldEdits.set(field, {composing: false})
      f.frameEffects([effect()])
      const receive = p.subscriber.onEffectRequest.bind(p.subscriber)
      p.subscriber.onEffectRequest = request => {
        receive(request)
        p.surfaces.get(surface).visible = false
        if (pendingBefore) p.fieldEdits.clear()
        else p.fieldEdits.set(field, {composing: false})
        p.syncEditGate()
      }
      p.reconcileSurfaces = () => { p.liveSurfaces = [] }
      records.length = 0; calls.length = 0; f.elapse(5000); p.surfaceFrame(); await settled(p)
      assert.equal(p.surfaceLoopStartedAt, undefined)
      assert.equal(p.error, '')
      assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
        {actions: ['step'], draws: ['draw'], save: pendingBefore ? 'DONE' : 'DEFERRED'})
      assert.equal(saves.length, pendingBefore ? 1 : 0)
      assert.equal(f.actor().lastSurfaceSave, loopStartedAt + (pendingBefore ? 5000 : 0))
      assert(calls.some(call => call.action === 'draw'))
      sequence(records, ['EFFECT_REQUEST', 'DRAW', 'EXECUTE', 'FRAME', 'SURFACE_FRAME'])
      assert.equal(records.at(-1).event, 'SURFACE_FRAME')
      assert.equal(p.liveSurfaces.length, 0)
      p.liveSurfaces = [surface]
      p.reconcileSurfaces = () => {}
      p.fieldEdits.clear(); p.syncEditGate(); records.length = 0
      if (!pendingBefore) {
        p.surfaceFrame(); await settled(p)
        assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
          {actions: ['step'], draws: [], save: 'DONE'})
        records.length = 0
      }
      f.elapse(16); p.surfaceFrame(); await settled(p)
      assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
        {actions: ['step'], draws: [], save: 'NOT_DUE'})
      assert.equal(saves.length, 1)
    }
    const records = capture(), {p, surface} = probe()
    await loaded(p); p.liveSurfaces = [surface]; surface.action = 'trap'; records.length = 0; p.surfaceFrame(); await settled(p)
    assert(!events(records).includes('SURFACE_FRAME'))
    sequence(records, ['EXECUTE', 'ERROR', 'TIMERS_STOPPED'])
  })
  await test('effect requests forward raw mode and generation through consent and direct calls', async () => {
    const request = StageTrace.request, forwarded = []
    StageTrace.request = function (...args) { forwarded.push(args); return request.apply(this, args) }
    try {
      for (const allow of [true, false]) {
        const records = capture(), f = probe(true), {p, replies} = f
        await loaded(p); records.length = 0; forwarded.length = 0
        const value = effect(); value.rawMode = 'foreground'
        f.deliverEffects([value])
        assert.equal(forwarded.length, 1)
        assert.deepEqual(forwarded[0].slice(5), ['foreground', p.frameVmGeneration])
        const requestAttributes = records.find(record => record.event === 'EFFECT_REQUEST').attributes
        assert.equal(requestAttributes.rawMode, StageTrace.digest(value.rawMode))
        assert.equal(requestAttributes.generation, p.frameVmGeneration)
        assert.equal(replies.length, 0)
        const generation = p.frameVmGeneration
        if (allow) { p.allowPending(); replies[0].resolve('ok') }
        else p.refusePending()
        await settled(p)
        assert.equal(forwarded.length, 1)
        const result = records.find(record => record.event === 'EFFECT_RESULT').attributes
        assert.equal(result.generation, generation)
        assert.equal(result.outcome, allow ? 'OK' : 'DECLINED')
        assert(records.some(record => record.event === 'EXECUTE' && record.attributes.kind === 'EFFECT_RESULT'))
      }
      const records = capture(), f = probe(), {p, replies} = f
      await loaded(p); records.length = 0; forwarded.length = 0
      const value = effect(); value.rawMode = 'background'
      f.deliverEffects([value])
      const generation = p.frameVmGeneration
      assert.deepEqual(forwarded[0].slice(5), ['background', generation])
      const requestAttributes = records.find(record => record.event === 'EFFECT_REQUEST').attributes
      assert.equal(requestAttributes.rawMode, StageTrace.digest(value.rawMode))
      assert.equal(requestAttributes.generation, generation)
      p.vbc2 = 'replacement'; await loaded(p)
      assert(p.frameVmGeneration > generation)
      replies[0].resolve('ok'); await settled(p)
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.generation, generation)
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.outcome, 'DROPPED_STALE')
    } finally { StageTrace.request = request }
  })
  await test('field cancellation traces only removed actions with the existing reasons', async () => {
    const records = capture(), {p, V} = probe()
    await loaded(p)
    const field = {kind: 'field', fieldCancellation: 0, fieldIssue: '', touched: false}
    const other = {kind: 'field', fieldCancellation: 0}
    p.fieldEdits.set(field, {composing: true, timer: -1})
    const dependent = p.captureFieldAction('dependent', payload(0))
    dependent.unknownDependencies = false; dependent.dependencies = [field]; dependent.dependencyCancellations = [0]
    const unrelated = p.captureFieldAction('unrelated', payload(0))
    unrelated.unknownDependencies = false; unrelated.dependencies = [other]; unrelated.dependencyCancellations = [0]
    const unknown = p.captureFieldAction('unknown', payload(0))
    p.fieldActions = [dependent, unrelated, unknown]; records.length = 0
    p.cancelField(field)
    assert.deepEqual(p.fieldActions, [unrelated])
    assert.deepEqual(records.filter(record => record.event === 'FIELD_ACTION_DROP').map(record => record.attributes),
      [{action: 'dependent', reason: 'fieldCancellation'}, {action: 'unknown', reason: 'fieldCancellation'}])
    assert.equal(field.fieldCancellation, 1)
    records.length = 0; p.cancelFields()
    assert.deepEqual(records.filter(record => record.event === 'FIELD_ACTION_DROP').map(record => record.attributes),
      [{action: 'unrelated', reason: 'effectGeneration'}])
    assert.equal(p.fieldActions.length, 0)
    records.length = 0; p.cancelFields(); assert.equal(records.length, 0)
  })
  await test('MOCKED fixed-step fast ticker defers pending edits and retains elapsed gap', async () => {
    const records = capture(), f = probe(), {p, calls} = f
    await loaded(p); calls.length = 0
    p.startTimer('fast-clock', {interval: 16, action: 'tick'})
    p.fieldEdits.set({}, {composing: false})
    for (let step = 0; step < 3; step++) { f.elapse(16); f.fire() }
    assert.deepEqual(records.filter(record => record.event === 'TICK_SKIPPED').map(record => record.attributes.reason),
      ['PENDING_EDIT', 'PENDING_EDIT', 'PENDING_EDIT'])
    assert(!calls.some(call => call.action === 'tick'))
    p.fieldEdits.clear(); f.elapse(16); f.fire(); await settled(p)
    assert.equal(calls.find(call => call.action === 'tick').args[1].value, 64)
    assert.equal(records.find(record => record.event === 'TICK_DELIVERED').attributes.class, 'fast')
    p.stopAllTimers('RELEASE')
  })
  await test('MOCKED preview-mode transitions and dark callbacks redraw without persistence', async () => {
    const records = capture(), {p, V, snapshots, saves, calls, media, faults} = probe()
    p.previewOnly = true; await loaded(p)
    assert.equal(snapshots.length, 0)
    p.dispatch('ignored', payload(secret))
    assert(!calls.some(call => call.action === 'ignored'))
    p.previewOnly = false; p.onPreviewOnlyChanged(); await settled(p)
    assert.equal(snapshots.length, 1)
    p.watchDarkMode(); const frames = records.filter(record => record.event === 'FRAME').length
    media.callback({matches: true}); await settled(p)
    assert.equal(p.dark, true)
    assert.equal(records.filter(record => record.event === 'FRAME').length, frames + 2)
    media.callback({matches: true}); await settled(p)
    p.disposed = true; media.callback({matches: false}); await settled(p)
    assert.equal(records.filter(record => record.event === 'FRAME').length, frames + 2)
    assert.equal(saves.length, 0)
    p.disposed = false; faults.media = true; p.watchDarkMode()
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'DARK_MODE'))
    p.previewOnly = true; p.onPreviewOnlyChanged(); await settled(p)
    assert.equal(snapshots.length, 1)
    p.previewOnly = false; p.onPreviewOnlyChanged(); await settled(p)
    p.dispatch('ephemeral', payload(secret), false); await settled(p)
    p.persistKey = ''; p.onPreviewOnlyChanged(); await settled(p)
    p.dispatch('unkeyed', payload(secret)); await settled(p)
    assert(calls.some(call => call.action === 'ephemeral'))
    assert(calls.some(call => call.action === 'unkeyed'))
    assert.equal(saves.length, 0)
  })
  await test('MOCKED consent queue blocks followers then routes out-of-order replies by effect identity', async () => {
    const records = capture(), f = probe(true), {p, replies, calls} = f
    await loaded(p)
    const first = effect(41), second = effect(90), third = effect(103)
    first.rawMode = 'foreground'; second.rawMode = 'background'
    second.resultHandler = 'secondAnswer'; third.resultHandler = 'thirdAnswer'
    f.deliverEffects([first, second, third])
    assert.deepEqual(p.pending, f.request(first)); assert.deepEqual(f.controller().heldEffects.map(work => work.effect), [second, third].map(value => f.request(value)))
    assert.equal(replies.length, 0)
    p.allowPending()
    assert.deepEqual(p.pending, f.request(second)); assert.equal(replies.length, 1)
    p.refusePending()
    assert.deepEqual(p.pending, f.request(third)); assert.equal(replies.length, 1)
    p.allowPending()
    assert.equal(p.pending, null); assert.equal(replies.length, 2)
    await settled(p)
    replies[1].resolve('ok'); await settled(p)
    replies[0].resolve('ok'); await settled(p)
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_REQUEST').map(record => record.attributes.id), [41, 90, 103])
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_RESULT').map(record => [record.attributes.id, record.attributes.outcome]),
      [[90, 'DECLINED'], [103, 'OK'], [41, 'OK']])
    assert.deepEqual(calls.filter(call => ['answer', 'secondAnswer', 'thirdAnswer'].includes(call.action)).map(call => call.action),
      ['secondAnswer', 'thirdAnswer', 'answer'])
  })
  await test('MOCKED failure policies preserve observed restore/save/view/draw behavior', async () => {
    const records = capture(), f = probe(), {p, V, disk, faults, saves, surface} = f
    disk.set('fixture/version', 'not-json'); await loaded(p)
    assert.equal(p.error, '')
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'RESTORE'))
    faults.save = true
    p.dispatch('tap', payload(secret + '!')); await settled(p)
    assert.equal(V.decodeRuntimeValue(JSON.parse(await snapshot(p))).value, secret + '!'); assert.equal(p.error, '')
    assert.equal(saves.length, 0)
    assert.equal(records.filter(record => record.event === 'SAVE').at(-1).attributes.result, 'ERROR')
    faults.save = false; faults.view = true
    p.dispatch('tap', payload(secret)); await settled(p)
    assert.equal(p.error, 'fixture view')
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'VIEW'))
    assert.equal(saves.length, 1, 'observed policy: view failure does not prevent dispatch save')
    faults.view = false; p.error = ''; faults.draw = true
    p.liveSurfaces = [surface]
    p.surfaces.set(surface, {ready: true, visible: true, width: 100, height: 100, ctx: {}})
    p.paintSurface(surface); await settled(p)
    assert.equal(records.filter(record => record.event === 'DRAW').at(-1).attributes.result, 'ERROR')
    assert.equal(f.host().effectsAllowed, false)
  })
  await test('MOCKED resolved effect failure strings retain classified outcomes and payload hashes', async () => {
    const records = capture(), f = probe(), {p, replies, calls} = f
    await loaded(p)
    for (const [index, text] of ['declined code=7', 'error 9: fixture', 'ok', '{"value":1}'].entries()) {
      f.deliverEffects([effect(51 + index)]); replies.at(-1).resolve(text); await settled(p)
      assert.equal(calls.filter(call => call.action === 'answer').at(-1).args[1].value, text)
    }
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_RESULT').map(record => record.attributes.outcome),
      ['DECLINED', 'ERROR', 'OK', 'OK'])
  })
  await test('throwing trace sink leaves renderer dispatch functional', async () => {
    const {p, V, saves} = probe()
    StageTrace.configure(true, () => { throw Error('fixture sink') })
    await loaded(p); p.dispatch('tap', payload(secret)); await settled(p)
    assert.equal(p.error, '')
    assert.equal(V.decodeRuntimeValue(JSON.parse(await snapshot(p))).value, secret)
    assert.equal(saves.length, 1)
  })
  await test('all required renderer event types were exercised', async () => {
    assert.deepEqual(required.filter(event => !observed.has(event)), [])
  })
  for (const result of results) {
    console.log(result.result + ' ' + result.name)
    if (result.error) console.error(result.error)
  }
  const failed = results.filter(result => result.result === 'FAIL').length
  console.log('stage-trace-check: ' + (results.length - failed) + ' passed, ' + failed + ' failed')
  console.log('MOCKED orchestration: current AppActor and extracted VeraPreview methods; fake VM, UI and platform boundaries')
  if (failed) { process.exitCode = 1; return }
  if (options) {
    const value = baseline.artifact(scenarios)
    if (options.mode === 'capture') baseline.captureFile(options.output, value)
    else baseline.compareFile(options.output, value)
    console.log('stage-trace-check: MOCKED ' + options.mode + ' ' + options.output + ' (' + scenarios.length + ' scenarios; full exact sequence)')
    for (const limitation of value.limitations) console.log('LIMITATION: ' + limitation)
  }
}
main().catch(error => { StageTrace.configure(false); console.error(error); process.exitCode = 1 })
