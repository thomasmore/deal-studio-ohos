'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const baseline = require('./stage-trace-baseline')
const options = baseline.parseArgs(process.argv.slice(2))
const {loadSource, loadVera, sourceRoot} = require('./source-loader')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
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
    results.push({name, result: 'PASS'})
    if (rendererScenarios && segments.length) scenarios.push({name, segments})
  } catch (error) {
    results.push({name, result: 'FAIL', error: error.stack || String(error)})
  } finally {
    StageTrace.configure(false)
  }
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
function probe() {
  const V = loadVera('VeraInterpreter')
  const fields = ['effectGeneration', 'liveGeneration', 'disposed', 'heldEffects', 'vm', 'host', 'currentState', 'refreshes',
    'fieldEdits', 'fieldInputs', 'fieldMenus', 'fieldActions', 'surfaceInputs', 'resumingFieldActions', 'fieldActionsNeedResume', 'renderingDepth',
    'timers', 'timerConfigs', 'timerLastFire', 'ticking', 'surfaces', 'liveSurfaces', 'surfaceSync', 'surfaceTimer',
    'lastFrameAt', 'lastViewAt', 'lastSurfaceSave', 'framing', 'frameSplit', 'pageHidden', 'spinTimer', 'spinPeriod',
    'motionTimer', 'motionTriggers', 'poseAnims', 'sceneFrames'].map(name => {
    const field = renderer.match(new RegExp('^  private ' + name + ':[^\\n]+(?:\\n    [^\\n]+)*', 'm'))
    assert(field, name)
    return field[0]
  }).join('\n')
  const names = ['invalidateEffects', 'load', 'runWidgetRefresh', 'dispatch', 'renderView', 'notifyStateSnapshot',
    'persistState', 'stateKeys', 'restoreState', 'markLiveNodeGeneration', 'isLiveNode', 'collectFieldDependencies',
    'captureFieldAction', 'dispatchFieldAction', 'enqueueFieldAction', 'resumeFieldActions', 'fieldActionCurrent',
    'releaseSurfaceAction', 'scheduleFieldActions', 'startTimer', 'stopTimer', 'stopAllTimers', 'stopSurfaceLoop',
    'surfaceFrame', 'paintSurface', 'paintSurfaces', 'drainEffects', 'runQueued', 'runEffect', 'allowPending',
    'refusePending', 'cancelField', 'cancelFields', 'refreshFieldIssue', 'fieldActionState', 'watchDarkMode']
  const methods = names.map(name => declaration('  private ' + name + '('))
    .concat(declaration('  onResume('), declaration('  onPreviewOnlyChanged(')).join('\n')
  const constants = ['SURFACE_VIEW_MS', 'SURFACE_SAVE_MS', 'SURFACE_MAX_ELAPSED_MS', 'SLOW_TICK_MS'].map(name => {
    const constant = renderer.match(new RegExp('^const ' + name + ':[^\\n]+', 'm'))
    assert(constant, name)
    return constant[0]
  }).join('\n')
  const source = ['class FieldAction', 'class TimerConfig'].map(name => declaration(name)).join('\n') + '\n' + constants +
    '\nclass Probe { ' + fields + '\n' + methods + '\n}'
  const compiled = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2020}, reportDiagnostics: true})
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0, 'renderer probe syntax')
  let now = 10000, handle = 0, paints = 0, p
  const calls = [], snapshots = [], saves = [], replies = [], loads = [], timers = new Map(), disk = new Map()
  const faults = {save: false, view: false, draw: false, media: false}
  const media = {matches: false, on(event, callback) { this.callback = callback }}
  const surface = {kind: 'surface', action: 'step', label: 'draw', value: '', children: [], minimum: 100, maximum: 100, style: 'default'}
  const root = () => ({kind: 'column', children: [surface], text: secret})
  class Host {
    constructor() { this.effectsAllowed = false; this.pendingEffects = [] }
  }
  class Machine {
    constructor(module, host) { this.host = host }
    execute(action, args = []) {
      calls.push({action, allowed: this.host.effectsAllowed, args})
      if (action === 'init') return new V.VeraStringValue(secret)
      if (action === 'view') { if (faults.view) throw Error('fixture view'); return [root()] }
      if (action === 'draw') { if (faults.draw) throw Error('fixture draw'); return [] }
      if (action === 'trap') { this.host.pendingEffects.push(effect()); throw Error('fixture trap') }
      if (action === 'step') return args[0]
      return args[1] || args[0]
    }
    stepsExecuted() { return 1 }
  }
  const platform = (...args) => new Promise((resolve, reject) => replies.push({args, resolve, reject}))
  const mocks = {StageTrace, ...V, VirtualMachine: Machine, UiHostEnvironment: Host, consent: {remember() {}},
    deserializeVbc2: value => { if (value === 'broken') throw Error('fixture bytecode'); return {functions: []} },
    decodeVeraUi: value => value, toLive: node => ({...node, children: [...node.children]}),
    reconcile: (live, node) => Object.assign(live, node), markIconRoom() {}, armReveal() {},
    decodeGfx: value => value, paintGfx() { paints++ }, runRawIntent: platform, runSdkAdapter: platform,
    scheduleCardRefresh() {}, Date: {now: () => now}, console: {info() {}, warn() {}, error() {}},
    setInterval(callback, interval) { timers.set(++handle, {callback, interval}); return handle },
    clearInterval(id) { timers.delete(id) },
    store: {loadState(project, version) { loads.push([project, version]); return disk.get(project + '/' + version) || '' },
      saveState(project, version, stamp, encoded) {
        if (faults.save) throw Error('fixture save')
        disk.set(project + '/' + version, encoded); saves.push(encoded)
      }}}
  const Probe = new Function(...Object.keys(mocks), compiled.outputText + '\nconst VeraPreview = Probe; return Probe')(...Object.values(mocks))
  p = new Probe()
  Object.assign(p, {previewOnly: false, programId: 0, revision: 0, liveRoot: null, hasRoot: false, error: '',
    vbc2: 'fixture', persistKey: 'fixture/version', diskState: '', appForeground: true, pending: null,
    stamp: () => 'fixture-stamp', seeded: value => value, onStateSnapshot: encoded => snapshots.push(encoded),
    flushFields() {},
    reconcileTheme() {}, reconcileFields() {}, reconcileTimers() {}, reconcileSpin() {}, reconcileMotion() {},
    reconcileBackHandler() {}, reconcileSurfaces() {}, countFrame() {}, needsConsent: () => false,
    dark: false, darkListener: null, t: () => ({}),
    getUIContext: () => ({vp2px: value => value, getMediaQuery: () => ({matchMediaSync() {
      if (faults.media) throw Error('fixture media')
      return media
    }})})})
  return {p, calls, snapshots, saves, replies, loads, timers, disk, V, surface, faults, media, paints: () => paints,
    elapse(ms) { now += ms }, fire() { assert.equal(timers.size, 1); [...timers.values()][0].callback() }}
}
function effect(id = 1, target = secret) {
  return {id, kind: 'sdk', fn: 'call', rawTarget: target, rawMode: '', values: new Map([['body', secret]]), resultHandler: 'answer'}
}
const settle = () => new Promise(resolve => setImmediate(resolve))
async function main() {
  await test('disabled by default and disabled helpers neither hash nor traverse payloads', () => {
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
  await test('records have stable per-preview sessions and toggles reset allocation', () => {
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
  await test('emit copies every declared attribute without mutating inputs and preserves falsy values', () => {
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
  await test('emit omits undefined optional attributes', () => {
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
  await test('snapshot/frame/request payloads are digested, deterministic and distinguish changes', () => {
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
  await test('state-derived ticker IDs are hashed stably without mutating caller attributes', () => {
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
  await test('request mode hashes distinguish modes and preserve request generations and inputs', () => {
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
  await test('native stageTrace string flags toggle tracing through extractDevParameters', () => {
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
  await test('app callers cannot enable or disable stageTrace even with a native name', () => {
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
  await test('absent or invalid native stageTrace flags leave tracing configuration unchanged', () => {
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
  await test('a throwing sink cannot escape any public emission helper', () => {
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
  await test('real renderer load/action order, reveal and payload privacy', () => {
    const records = capture(), f = probe(), {p, V} = f
    p.load()
    assert.equal(p.error, '')
    sequence(records, ['EXECUTE', 'SNAPSHOT', 'FRAME'])
    assert.equal(f.snapshots.length, 1)
    records.length = 0
    p.dispatch('tap', new V.VeraStringValue(secret))
    assert.equal(p.error, '')
    sequence(records, ['EXECUTE', 'INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE'])
    assert.equal(f.saves.length, 1)
    assert.equal(f.calls.find(call => call.action === 'tap').allowed, true)
    assert(f.calls.filter(call => call.action === 'view').every(call => !call.allowed))
    assert(records.find(record => record.event === 'FRAME').attributes.reveal === true)
    assert.equal(new Set(records.map(record => record.session)).size, 1)
    privateRecords(records)
  })
  await test('real previews have independent sessions and disabled rendering never hashes', () => {
    const records = capture(), first = probe(), second = probe()
    first.p.load()
    const split = records.length
    second.p.load()
    assert.equal(new Set(records.slice(0, split).map(record => record.session)).size, 1)
    assert.equal(new Set(records.slice(split).map(record => record.session)).size, 1)
    assert.notEqual(records[0].session, records[split].session)
    StageTrace.configure(false)
    const digest = StageTrace.digest, count = records.length
    let hashes = 0
    StageTrace.digest = () => { hashes++; throw Error('disabled renderer digest called') }
    try {
      first.p.load()
      first.p.dispatch('tap', new first.V.VeraStringValue(secret))
      assert.equal(first.p.error, '')
      assert.equal(first.saves.length, 1)
      assert.equal(hashes, 0)
      assert.equal(records.length, count)
    } finally { StageTrace.digest = digest }
  })
  await test('real renderer traps clear effects, stop timers and never commit input', () => {
    const records = capture(), {p, V, replies, saves} = probe()
    p.load(); records.length = 0
    const state = p.currentState
    p.dispatch('trap', new V.VeraStringValue(secret))
    assert.match(p.error, /Action error: fixture trap/)
    assert.equal(p.currentState, state)
    assert.equal(p.host.effectsAllowed, false)
    assert.deepEqual(p.host.pendingEffects, [])
    assert.deepEqual(replies, [])
    assert.deepEqual(saves, [])
    sequence(records, ['EXECUTE', 'ERROR', 'TIMERS_STOPPED'])
    for (const event of ['INPUT_APPLIED', 'SNAPSHOT', 'FRAME', 'SAVE', 'EFFECT_REQUEST']) assert(!events(records).includes(event), event)
    p.vbc2 = 'broken'; records.length = 0; p.load()
    assert.match(p.error, /Init error:/)
    assert(events(records).includes('ERROR'))
    privateRecords(records)
  })
  await test('real field-action queue blocks composition, applies in order and drops stale actions', () => {
    const records = capture(), {p, V, calls} = probe()
    p.load(); records.length = 0; calls.length = 0
    const field = {}, edit = {composing: true}
    p.fieldEdits.set(field, edit)
    p.dispatchFieldAction('tap', new V.VeraStringValue(secret), true, null, 'HANDLER')
    sequence(records, ['FIELD_ACTION_ENQUEUE'])
    assert.equal(calls.length, 0)
    edit.composing = false
    p.fieldEdits.clear(); p.resumeFieldActions()
    sequence(records, ['FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_APPLY', 'EXECUTE', 'INPUT_APPLIED'])
    records.length = 0
    p.fieldEdits.set(field, {composing: true})
    p.dispatchFieldAction('stale', new V.VeraStringValue(secret))
    p.effectGeneration++; p.fieldEdits.clear(); p.resumeFieldActions()
    sequence(records, ['FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_DROP'])
    assert(!calls.some(call => call.action === 'stale'))
    privateRecords(records)
  })
  await test('real ticker gates preserve elapsed time and trace delivered/skipped ticks', () => {
    const records = capture(), f = probe(), {p, calls} = f
    p.load(); calls.length = 0; records.length = 0
    const state = p.currentState, tickerId = 'clock:' + state.value
    const config = Object.freeze({interval: 1000, action: 'tick'})
    p.startTimer(tickerId, config)
    p.appForeground = false; f.elapse(1000); f.fire()
    assert(!calls.some(call => call.action === 'tick'))
    assert(events(records).includes('TICK_SKIPPED'))
    p.appForeground = true; f.elapse(1000); f.fire()
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
  await test('real surface gates, frame execution and draw keep effects fenced', () => {
    const records = capture(), f = probe(), {p, calls, surface} = f
    p.load(); p.liveSurfaces = [surface]
    p.surfaces.set(surface, {ready: true, visible: true, width: 100, height: 100, ctx: {}})
    records.length = 0; calls.length = 0
    p.pageHidden = true; p.surfaceFrame()
    assert(events(records).includes('SURFACE_SKIPPED')); assert.equal(calls.length, 0)
    p.pageHidden = false; p.fieldEdits.set({}, {composing: true}); p.surfaceFrame()
    assert.equal(calls.length, 0)
    p.fieldEdits.clear(); records.length = 0; f.elapse(16); p.surfaceFrame()
    sequence(records, ['EXECUTE', 'DRAW', 'SURFACE_FRAME'])
    assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
      {actions: ['step'], draws: ['draw'], save: 'DONE'})
    assert.equal(p.error, '')
    assert.equal(calls.find(call => call.action === 'step').allowed, true)
    assert.equal(calls.find(call => call.action === 'draw').allowed, false)
    assert.equal(f.paints(), 1)
    surface.action = 'trap'; records.length = 0; p.surfaceFrame()
    sequence(records, ['ERROR', 'TIMERS_STOPPED'])
    assert.equal(p.framing, false); assert.equal(p.host.effectsAllowed, false)
    privateRecords(records)
  })
  await test('real effect requests/results route current replies and gate stale callbacks', async () => {
    const records = capture(), {p, V, replies, calls} = probe()
    p.load(); records.length = 0
    p.host.pendingEffects = [effect()]; p.drainEffects()
    assert.equal(replies.length, 1)
    assert(events(records).includes('EFFECT_REQUEST'))
    replies[0].resolve(secret); await settle()
    sequence(records, ['EFFECT_REQUEST', 'EFFECT_RESULT', 'FIELD_ACTION_ENQUEUE', 'FIELD_ACTION_APPLY', 'INPUT_APPLIED'])
    assert(calls.find(call => call.action === 'answer').args[1] instanceof V.VeraStringValue)
    privateRecords(records)
    records.length = 0
    p.runEffect(effect(2)); replies.at(-1).reject(Error(secret)); await settle()
    sequence(records, ['EFFECT_REQUEST', 'EFFECT_RESULT', 'INPUT_APPLIED'])
    assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.generation, p.effectGeneration)
    assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.outcome, 'ERROR')
    assert.equal(calls.filter(call => call.action === 'answer').at(-1).args[1].value, 'error: ' + secret)
    privateRecords(records)
    for (const gate of ['generation', 'disposed']) for (const rejected of [false, true]) {
      p.disposed = false; p.runEffect(effect(replies.length + 1))
      const reply = replies.at(-1), count = calls.filter(call => call.action === 'answer').length
      const generation = p.effectGeneration
      if (gate === 'generation') p.effectGeneration++; else p.disposed = true
      records.length = 0
      if (rejected) reply.reject(Error(secret)); else reply.resolve(secret)
      await settle()
      assert.equal(calls.filter(call => call.action === 'answer').length, count)
      assert(!events(records).includes('INPUT_APPLIED'))
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.generation, generation)
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.outcome, 'DROPPED_STALE')
      privateRecords(records)
    }
  })
  await test('resume reports both reload decisions without extra store loads', () => {
    const records = capture(), {p, V, disk, loads} = probe()
    p.load(); p.persistState(); records.length = 0; loads.length = 0
    p.onResume()
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, false)
    assert.equal(loads.length, 1)
    records.length = 0; loads.length = 0
    disk.set('fixture/version', JSON.stringify(V.encodeRuntimeValue(new V.VeraStringValue(secret + '!'))))
    p.onResume()
    sequence(records, ['RESUME_STATE_RELOAD', 'FRAME'])
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, true)
    assert.equal(loads.length, 2)
    assert.equal(p.currentState.value, secret + '!')
    p.persistKey = ''; records.length = 0; loads.length = 0; p.onResume()
    assert.equal(records.find(record => record.event === 'RESUME_STATE_RELOAD').attributes.changed, false)
    assert.equal(loads.length, 0)
    privateRecords(records)
  })
  await test('surface summaries follow actual save gates and executed draws after effects and view', () => {
    for (const pendingBefore of [false, true]) {
      const records = capture(), f = probe(), {p, surface, saves, calls} = f
      p.load(); p.liveSurfaces = [surface]
      p.surfaces.set(surface, {ready: true, visible: false, width: 100, height: 100, ctx: {}})
      const field = {}
      if (pendingBefore) p.fieldEdits.set(field, {composing: false})
      p.drainEffects = () => {
        p.surfaces.get(surface).visible = true
        if (pendingBefore) p.fieldEdits.clear()
        else p.fieldEdits.set(field, {composing: false})
      }
      p.reconcileSurfaces = () => { p.liveSurfaces = [] }
      records.length = 0; calls.length = 0; f.elapse(200); p.surfaceFrame()
      assert.equal(p.error, '')
      assert.deepEqual(records.find(record => record.event === 'SURFACE_FRAME').attributes,
        {actions: ['step'], draws: ['draw'], save: pendingBefore ? 'DONE' : 'DEFERRED'})
      assert.equal(saves.length, pendingBefore ? 1 : 0)
      assert(calls.some(call => call.action === 'draw'))
      assert.equal(records.at(-1).event, 'SURFACE_FRAME')
      assert.equal(p.liveSurfaces.length, 0)
      p.fieldEdits.clear(); p.drainEffects = () => {}; records.length = 0
      if (!pendingBefore) p.lastSurfaceSave = 10000
      f.elapse(16); p.surfaceFrame()
      assert.equal(records.find(record => record.event === 'SURFACE_FRAME').attributes.save, 'NOT_DUE')
    }
    const records = capture(), {p, surface} = probe()
    p.load(); p.liveSurfaces = [surface]; surface.action = 'trap'; records.length = 0; p.surfaceFrame()
    assert(!events(records).includes('SURFACE_FRAME'))
    sequence(records, ['EXECUTE', 'ERROR', 'TIMERS_STOPPED'])
  })
  await test('effect requests forward raw mode and generation through consent and direct calls', async () => {
    const request = StageTrace.request, forwarded = []
    StageTrace.request = function (...args) { forwarded.push(args); return request.apply(this, args) }
    try {
      for (const allow of [true, false]) {
        const records = capture(), {p, replies} = probe()
        p.load(); records.length = 0; forwarded.length = 0
        p.needsConsent = () => true; p.consentTitle = () => 'fixture'
        p.consentTarget = () => 'fixture'; p.consentKey = () => 'fixture'
        const value = effect(); value.rawMode = 'foreground'
        p.host.pendingEffects = [value]; p.drainEffects()
        assert.equal(forwarded.length, 1)
        assert.deepEqual(forwarded[0].slice(5), ['foreground', p.effectGeneration])
        const requestAttributes = records.find(record => record.event === 'EFFECT_REQUEST').attributes
        assert.equal(requestAttributes.rawMode, StageTrace.digest(value.rawMode))
        assert.equal(requestAttributes.generation, p.effectGeneration)
        assert.equal(replies.length, 0)
        const generation = p.effectGeneration
        if (allow) { p.allowPending(); replies[0].resolve('ok'); await settle() }
        else p.refusePending()
        assert.equal(forwarded.length, 1)
        const result = records.find(record => record.event === 'EFFECT_RESULT').attributes
        assert.equal(result.generation, generation)
        assert.equal(result.outcome, allow ? 'OK' : 'DECLINED')
        assert(records.some(record => record.event === 'EXECUTE' && record.attributes.kind === 'EFFECT_RESULT'))
      }
      const records = capture(), {p, replies} = probe()
      p.load(); records.length = 0; forwarded.length = 0
      const value = effect(); value.rawMode = 'background'
      p.runEffect(value)
      const generation = p.effectGeneration
      assert.deepEqual(forwarded[0].slice(5), ['background', generation])
      const requestAttributes = records.find(record => record.event === 'EFFECT_REQUEST').attributes
      assert.equal(requestAttributes.rawMode, StageTrace.digest(value.rawMode))
      assert.equal(requestAttributes.generation, generation)
      p.effectGeneration++; replies[0].resolve('ok'); await settle()
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.generation, generation)
      assert.equal(records.find(record => record.event === 'EFFECT_RESULT').attributes.outcome, 'DROPPED_STALE')
    } finally { StageTrace.request = request }
  })
  await test('field cancellation traces only removed actions with the existing reasons', () => {
    const records = capture(), {p, V} = probe()
    p.load()
    const field = {kind: 'field', fieldCancellation: 0, fieldIssue: '', touched: false}
    const other = {kind: 'field', fieldCancellation: 0}
    p.fieldEdits.set(field, {composing: true, timer: -1})
    const dependent = p.captureFieldAction('dependent', new V.VeraNumberValue(0))
    dependent.unknownDependencies = false; dependent.dependencies = [field]; dependent.dependencyCancellations = [0]
    const unrelated = p.captureFieldAction('unrelated', new V.VeraNumberValue(0))
    unrelated.unknownDependencies = false; unrelated.dependencies = [other]; unrelated.dependencyCancellations = [0]
    const unknown = p.captureFieldAction('unknown', new V.VeraNumberValue(0))
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
  await test('MOCKED fixed-step fast ticker defers pending edits and retains elapsed gap', () => {
    const records = capture(), f = probe(), {p, calls} = f
    p.load(); calls.length = 0
    p.startTimer('fast-clock', {interval: 16, action: 'tick'})
    p.fieldEdits.set({}, {composing: false})
    for (let step = 0; step < 3; step++) { f.elapse(16); f.fire() }
    assert.deepEqual(records.filter(record => record.event === 'TICK_SKIPPED').map(record => record.attributes.reason),
      ['PENDING_EDIT', 'PENDING_EDIT', 'PENDING_EDIT'])
    assert(!calls.some(call => call.action === 'tick'))
    p.fieldEdits.clear(); f.elapse(16); f.fire()
    assert.equal(calls.find(call => call.action === 'tick').args[1].value, 64)
    assert.equal(records.find(record => record.event === 'TICK_DELIVERED').attributes.class, 'fast')
    p.stopAllTimers('RELEASE')
  })
  await test('MOCKED preview-mode transitions and dark callbacks redraw without persistence', () => {
    const records = capture(), {p, V, snapshots, saves, calls, media, faults} = probe()
    p.previewOnly = true; p.load()
    assert.equal(snapshots.length, 0)
    p.dispatch('ignored', new V.VeraStringValue(secret))
    assert(!calls.some(call => call.action === 'ignored'))
    p.previewOnly = false; p.onPreviewOnlyChanged()
    assert.equal(snapshots.length, 1)
    p.watchDarkMode(); const frames = records.filter(record => record.event === 'FRAME').length
    media.callback({matches: true})
    assert.equal(p.dark, true)
    assert.equal(records.filter(record => record.event === 'FRAME').length, frames + 1)
    media.callback({matches: true})
    p.disposed = true; media.callback({matches: false})
    assert.equal(records.filter(record => record.event === 'FRAME').length, frames + 1)
    assert.equal(saves.length, 0)
    p.disposed = false; faults.media = true; p.watchDarkMode()
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'DARK_MODE'))
    p.previewOnly = true; p.onPreviewOnlyChanged()
    assert.equal(snapshots.length, 1)
    p.previewOnly = false
    p.dispatch('ephemeral', new V.VeraStringValue(secret), false)
    p.persistKey = ''; p.dispatch('unkeyed', new V.VeraStringValue(secret))
    assert.equal(saves.length, 0)
  })
  await test('MOCKED consent queue blocks followers then routes out-of-order replies by effect identity', async () => {
    const records = capture(), {p, replies, calls} = probe()
    p.load()
    p.needsConsent = () => true; p.consentTitle = () => 'fixture'
    p.consentTarget = () => 'fixture'; p.consentKey = () => 'fixture'
    const first = effect(41), second = effect(90), third = effect(103)
    first.rawMode = 'foreground'; second.rawMode = 'background'
    second.resultHandler = 'secondAnswer'; third.resultHandler = 'thirdAnswer'
    p.host.pendingEffects = [first, second, third]; p.drainEffects()
    assert.equal(p.pending, first); assert.deepEqual(p.heldEffects, [second, third])
    assert.equal(replies.length, 0)
    p.allowPending()
    assert.equal(p.pending, second); assert.equal(replies.length, 1)
    p.refusePending()
    assert.equal(p.pending, third); assert.equal(replies.length, 1)
    p.allowPending()
    assert.equal(p.pending, null); assert.equal(replies.length, 2)
    replies[1].resolve('ok'); await settle()
    replies[0].resolve('ok'); await settle()
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_REQUEST').map(record => record.attributes.id), [41, 90, 103])
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_RESULT').map(record => [record.attributes.id, record.attributes.outcome]),
      [[90, 'DECLINED'], [103, 'OK'], [41, 'OK']])
    assert.deepEqual(calls.filter(call => ['answer', 'secondAnswer', 'thirdAnswer'].includes(call.action)).map(call => call.action),
      ['secondAnswer', 'thirdAnswer', 'answer'])
  })
  await test('MOCKED failure policies preserve observed restore/save/view/draw behavior', () => {
    const records = capture(), {p, V, disk, faults, saves, surface} = probe()
    disk.set('fixture/version', 'not-json'); p.load()
    assert.equal(p.error, '')
    assert(records.some(record => record.event === 'ERROR' && record.attributes.kind === 'RESTORE'))
    faults.save = true
    p.dispatch('tap', new V.VeraStringValue(secret + '!'))
    assert.equal(p.currentState.value, secret + '!'); assert.equal(p.error, '')
    assert.equal(saves.length, 0)
    assert.equal(records.filter(record => record.event === 'SAVE').at(-1).attributes.result, 'ERROR')
    faults.save = false; faults.view = true
    p.dispatch('tap', new V.VeraStringValue(secret))
    assert.match(p.error, /View error:/)
    assert.equal(saves.length, 1, 'observed policy: view failure does not prevent dispatch save')
    faults.view = false; p.error = ''; faults.draw = true
    p.liveSurfaces = [surface]
    p.surfaces.set(surface, {ready: true, visible: true, width: 100, height: 100, ctx: {}})
    p.paintSurface(surface)
    assert.equal(records.filter(record => record.event === 'DRAW').at(-1).attributes.result, 'ERROR')
    assert.equal(p.host.effectsAllowed, false)
  })
  await test('MOCKED resolved effect failure strings retain classified outcomes and payload hashes', async () => {
    const records = capture(), {p, replies, calls} = probe()
    p.load()
    for (const [index, text] of ['declined code=7', 'error 9: fixture', 'ok', '{"value":1}'].entries()) {
      p.runEffect(effect(51 + index)); replies.at(-1).resolve(text); await settle()
      assert.equal(calls.filter(call => call.action === 'answer').at(-1).args[1].value, text)
    }
    assert.deepEqual(records.filter(record => record.event === 'EFFECT_RESULT').map(record => record.attributes.outcome),
      ['DECLINED', 'ERROR', 'OK', 'OK'])
  })
  await test('throwing trace sink leaves renderer dispatch functional', () => {
    const {p, V, saves} = probe()
    StageTrace.configure(true, () => { throw Error('fixture sink') })
    p.load(); p.dispatch('tap', new V.VeraStringValue(secret))
    assert.equal(p.error, '')
    assert.equal(p.currentState.value, secret)
    assert.equal(saves.length, 1)
  })
  await test('all required renderer event types were exercised', () => {
    assert.deepEqual(required.filter(event => !observed.has(event)), [])
  })
  for (const result of results) {
    console.log(result.result + ' ' + result.name)
    if (result.error) console.error(result.error)
  }
  const failed = results.filter(result => result.result === 'FAIL').length
  console.log('stage-trace-check: ' + (results.length - failed) + ' passed, ' + failed + ' failed')
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
