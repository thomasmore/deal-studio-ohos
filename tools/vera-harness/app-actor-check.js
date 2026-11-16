'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const root = path.resolve(__dirname, '../../entry/src/main/ets')
const cache = new Map()
const disk = new Map()
let records = []
let failure = ''
let now = 100000
const filesystem = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  mkdirSync() {},
  openSync(file) {
    if (failure === 'open') throw Error('fixture open failed')
    return { fd: file }
  },
  writeSync(file, value) {
    if (failure === 'write') throw Error('fixture write failed')
    disk.set(file, value)
  },
  closeSync() {
    if (failure === 'close') throw Error('fixture close failed')
  },
  statSync(file) {
    if (file.endsWith('.state.json')) records.push({ type: 'load-attempt', file })
    if (!disk.has(file)) throw Error('absent')
    return { size: disk.get(file).length }
  },
  readTextSync(file) {
    if (!disk.has(file)) throw Error('absent')
    if (file.endsWith('.state.json')) records.push({ type: 'load', file })
    return disk.get(file)
  },
  renameSync(from, to) {
    records.push({ type: 'save-attempt', file: to })
    if (failure === 'rename') throw Error('fixture rename failed')
    assert(disk.has(from))
    disk.set(to, disk.get(from))
    disk.delete(from)
    records.push({ type: 'save', file: to, payload: JSON.parse(disk.get(to)) })
  },
  unlinkSync(file) { disk.delete(file) },
  listFileSync(dir) { return [...disk.keys()].filter(file => path.dirname(file) === dir).map(file => path.basename(file)) }
}
const forbidden = name => new Proxy({}, { get(_target, key) {
  throw Error('Forbidden platform access: ' + name + '.' + String(key))
} })
function load(file) {
  file = path.resolve(file)
  if (cache.has(file)) return cache.get(file).exports
  const source = fs.readFileSync(file, 'utf8')
  const compiled = ts.transpileModule(source, {
    fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
    reportDiagnostics: true
  })
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, file + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'))
  const module = { exports: {} }
  cache.set(file, module)
  const importer = name => {
    if (name === '@kit.CoreFileKit') return { fileIo: filesystem }
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: forbidden('hilog') }
    if (name.startsWith('@kit.') || name === 'libllama.so') return forbidden(name)
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'))
    throw Error('Unsupported dependency: ' + name + ' from ' + file)
  }
  new Function('require', 'module', 'exports', compiled.outputText)(importer, module, module.exports)
  return module.exports
}
const vera = name => load(path.join(root, 'vera', name + '.ets'))
const { AppActor } = load(path.join(root, 'runtime/AppActor.ets'))
const { StageTrace } = load(path.join(root, 'runtime/trace/StageTrace.ets'))
const { compileVeraSource } = vera('VeraCompiler')
const { VeraNumberValue, VeraStringValue } = vera('VeraInterpreter')
const { pointerValue } = vera('VeraGfx')
const { WorldSpec, sceneEventValue } = vera('VeraScene')
const { store, ProjectStore } = vera('ProjectStore')
const { veraStateStamp } = vera('VeraStateStamp')
store.init('/actor-fixture')
const target = 'com.example.actor/entry/EntryAbility/Record'
const effect = label => `sdk.call("${target}", ["label", "${label}", "value", ui.numberToString(state.n)], "answered");`
const trap = 'let empty: number[] = []; state.n = empty[2];'
function fixture({ initial = 1, refresh = '', init = '', view = '', extraFields = '', extraInit = '' } = {}) {
  return `
@jsonable class AppState {
  n: number;
  calls: number;
  refreshes: number;
  marks: number[];
  badView: boolean;
  ${extraFields}
}
function init(): AppState {
  ${init}
  return {n: ${initial}, calls: 0, refreshes: 0, marks: [], badView: false${extraInit}};
}
function change(state: AppState, value: number): AppState {
  state.n = state.n + value;
  state.calls = state.calls + 1;
  state.marks.push(value);
  ${effect('change')}
  return state;
}
function fail(state: AppState, value: number): AppState {
  state.n = state.n + value;
  state.calls = state.calls + 1;
  state.marks.push(value);
  ${effect('fail')}
  ${trap}
  return state;
}
function breakView(state: AppState, value: number): AppState {
  state.n = state.n + value;
  state.calls = state.calls + 1;
  state.badView = true;
  ${effect('breakView')}
  return state;
}
function recover(state: AppState, value: number): AppState {
  state.badView = false;
  state.n = state.n + value;
  state.calls = state.calls + 1;
  return state;
}
function answered(state: AppState, answer: string): AppState {
  state.calls = state.calls + 1;
  state.n = state.n + answer.length();
  return state;
}
function frameA(state: AppState, ms: number): AppState {
  state.n = state.n * 10 + 1;
  state.calls = state.calls + 1;
  state.marks.push(ms);
  ${effect('frameA')}
  return state;
}
function frameB(state: AppState, ms: number): AppState {
  state.n = state.n * 10 + 2;
  state.calls = state.calls + 1;
  state.marks.push(ms);
  ${effect('frameB')}
  return state;
}
function pointer(state: AppState, p: gfx.Pointer): AppState {
  state.n = state.n + p.x + p.y + p.id;
  state.calls = state.calls + 1;
  ${effect('pointer')}
  return state;
}
function draw(state: AppState): gfx.Shape[] { return [gfx.circle(state.n, 2, 3, "ink")]; }
function drawTrap(state: AppState): gfx.Shape[] {
  let empty: number[] = [];
  return [gfx.circle(empty[2], 2, 3, "ink")];
}
function drawEffect(state: AppState): gfx.Shape[] {
  ${effect('draw')}
  return [gfx.circle(state.n, 2, 3, "ink")];
}
${refresh ? `function widgetRefresh(state: AppState): AppState { ${refresh} return state; }` : ''}
function view(state: AppState): ui.View {
  if (state.badView || state.n < 0) { ${trap} }
  ${view}
  return ui.Text("body", "n=" + ui.numberToString(state.n));
}
`
}
const refreshSuccess = `state.n = state.n + 10; state.refreshes = state.refreshes + 1; ${effect('refresh')}`
const refreshTrap = `state.n = state.n + 100; state.refreshes = state.refreshes + 1; ${effect('refresh-fail')} ${trap}`
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
  basic: compile(fixture()),
  refreshed: compile(fixture({ refresh: refreshSuccess })),
  refreshTrap: compile(fixture({ refresh: refreshTrap })),
  newer: compile(fixture({ initial: 5, refresh: refreshSuccess, extraFields: 'added: number;', extraInit: ', added: 42' })),
  initTrap: compile(fixture({ init: 'let empty: number[] = []; let n: number = empty[2];' })),
  initEffect: compile(fixture({ init: `sdk.call("${target}", [], "answered");` })),
  viewEffect: compile(fixture({ view: effect('view') })),
  world: compile(fixture() + `
function build(state: AppState): scene.Thing[] {
  return [scene.floor("ink"), scene.box("body", state.n, 2, 3, 1, 2, 3, "accent")];
}
function buildEffect(state: AppState): scene.Thing[] {
  ${effect('build')}
  return [];
}
function buildTrap(state: AppState): scene.Thing[] {
  let empty: number[] = [];
  return [scene.box("body", empty[2], 0, 0, 1, 1, 1, "ink")];
}
function buildInvalid(state: AppState): scene.Thing[] {
  return [scene.floor("ink"), scene.floor("accent")];
}
function worldEvent(state: AppState, e: scene.Event): AppState {
  if (e.kind === "hit" && e.speed > 0) {
    state.n = state.n + e.speed;
    state.calls = state.calls + 1;
  }
  ${effect('world')}
  return state;
}
function worldCopy(state: AppState, value: number): AppState {
  return {n: state.n, calls: state.calls, refreshes: state.refreshes, marks: state.marks, badView: state.badView};
}
`)
}
function unpack(value) {
  assert(Array.isArray(value), 'snapshot contains tagged tuples, not runtime objects')
  switch (value[0]) {
    case 'n': assert.equal(typeof value[1], 'number'); return value[1]
    case 's': assert.equal(typeof value[1], 'string'); return value[1]
    case 'b': assert.equal(typeof value[1], 'boolean'); return value[1]
    case 'z': return null
    case 'a': return value[1].map(unpack)
    case 'o':
      assert.equal(typeof value[1], 'string')
      return Object.fromEntries(value[2].map(([key, item]) => [key, unpack(item)]))
    default: assert.fail('unknown snapshot tag: ' + value[0])
  }
}
const stateOf = encoded => unpack(JSON.parse(encoded))
function edited(encoded, changes) {
  const tuple = JSON.parse(encoded)
  for (const [key, value] of Object.entries(changes)) {
    const pair = tuple[2].find(item => item[0] === key)
    assert(pair, key)
    pair[1] = typeof value === 'boolean' ? ['b', value] : typeof value === 'number' ? ['n', value] : ['s', value]
  }
  return JSON.stringify(tuple)
}
const options = (mode = 'LIVE_PERSISTENT', persistKey = 'project/version', seedState = '') => ({ mode, persistKey, seedState })
const stateFile = (key = 'project/version') => '/actor-fixture/vera/' + key.split('/')[0] + '/' + key.slice(key.indexOf('/') + 1) + '.state.json'
function saveExternal(program, encoded, key = 'project/version') {
  const slash = key.indexOf('/')
  store.saveState(key.slice(0, slash), key.slice(slash + 1), program.stamp, encoded)
}
function probe() {
  const events = []
  records = events
  const snapshots = [], frames = [], effects = []
  let actor
  function error(kind, message, stop = true) {
    events.push({ type: 'ui-error', kind, message })
    if (stop) events.push({ type: 'stop', kind })
  }
  const render = (paint = true, reveal = false) => {
    events.push({ type: 'render', paint, reveal })
    try {
      const root = actor.view()
      const frame = { type: 'frame', root: JSON.parse(JSON.stringify(root)), paint, reveal }
      frames.push(frame)
      events.push(frame)
    } catch (e) {
      error('VIEW', 'View error: ' + e.message, false)
    }
  }
  actor = new AppActor({
    render,
    snapshot(encoded) {
      assert.equal(typeof encoded, 'string')
      stateOf(encoded)
      snapshots.push(encoded)
      events.push({ type: 'snapshot', encoded })
    },
    saved(projectId) { events.push({ type: 'saved', projectId }) },
    effects(batch) {
      for (const item of batch) {
        const request = { type: 'effect', id: item.id, kind: item.kind, target: item.rawTarget,
          params: [...item.values], handler: item.resultHandler, mode: item.rawMode }
        effects.push(request)
        events.push(request)
      }
    },
    error(kind, message) { error(kind, message, kind !== 'INIT') }
  }, events)
  StageTrace.configure(true, record => {
    if (record.event === 'EXECUTE') events.push({ type: 'execute', entry: record.attributes.entry })
    if (record.event === 'RESUME_STATE_RELOAD') events.push({ type: 'reload', changed: record.attributes.changed })
  })
  return { actor, events, snapshots, frames, effects, render, error,
    reset() { events.length = 0; snapshots.length = 0; frames.length = 0; effects.length = 0 },
    state() { return stateOf(actor.snapshot()) },
    paint(entry = 'draw') {
      try {
        const ops = actor.draw(entry)
        events.push({ type: 'draw', entry, ops: JSON.parse(JSON.stringify(ops)) })
        return ops
      } catch (e) {
        error('DRAW', 'Draw error: ' + e.message)
        return null
      }
    }
  }
}
const sequence = p => p.events.filter(e => ['execute', 'snapshot', 'frame', 'save', 'saved', 'effect', 'ui-error', 'stop', 'draw', 'reload', 'load'].includes(e.type))
  .map(e => e.type === 'execute' ? e.entry : e.type === 'effect' ? 'effect:' + e.params[0][1] : e.type === 'ui-error' || e.type === 'stop' ? e.type + ':' + e.kind : e.type)
const entries = p => p.events.filter(e => e.type === 'execute').map(e => e.entry)
const count = (p, type) => p.events.filter(e => e.type === type).length
const noIo = p => assert.equal(p.events.filter(e => ['load-attempt', 'load', 'save-attempt', 'save', 'saved'].includes(e.type)).length, 0)
const noErrors = p => assert.equal(count(p, 'ui-error'), 0)
const number = n => new VeraNumberValue(n)
const tests = []
function test(name, run) { tests.push({ name, run }) }
let fresh

test('current-source identity and private ownership; preview has no second execution/state path', () => {
  assert.strictEqual(vera('ProjectStore').store, store)
  assert.strictEqual(load(path.join(root, 'runtime/../vera/VeraInterpreter.ets')), vera('VeraInterpreter'))
  const actorSource = fs.readFileSync(path.join(root, 'runtime/AppActor.ets'), 'utf8')
  const actorAst = ts.createSourceFile('AppActor.ts', actorSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
  const actorClass = actorAst.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'AppActor')
  for (const name of ['vm', 'host', 'currentState', 'diskState', 'mode', 'program', 'persistKey', 'seedState']) {
    const field = actorClass.members.find(member => member.name && member.name.getText(actorAst) === name)
    assert(field && field.modifiers.some(modifier => modifier.kind === ts.SyntaxKind.PrivateKeyword), name + ' is private')
  }
  const preview = fs.readFileSync(path.join(root, 'components/VeraPreview.ets'), 'utf8')
  assert.match(preview, /import\s*\{[^}]*AppActor[^}]*\}\s*from\s*['"]\.\.\/runtime\/AppActor['"]/m)
  assert(!/\bnew\s+(VirtualMachine|UiHostEnvironment)\b|\bvm!?\.execute\s*\(|\bcurrentState\b|\bcarryState\s*\(|\bstore\.(loadState|saveState)\s*\(/.test(preview))
  for (const method of ['initialize', 'view', 'dispatch', 'draw', 'move', 'frameHandlers']) assert(preview.includes('.' + method + '('), method + ' delegated')
  const gfx = fs.readFileSync(path.join(root, 'vera/GfxPaint.ets'), 'utf8')
  assert(!/from\s+['"](?:@kit\.|@ohos\.|.*VeraInterpreter)/.test(gfx))
  assert.match(gfx, /from ['"]\.\/VeraTheme['"]/)
  const facing = fs.readFileSync(path.join(root, 'vera/VeraGfx.ets'), 'utf8')
  assert.match(facing, /export\s*\{[^}]*paintGfx[^}]*\}\s*from ['"]\.\/GfxPaint['"]/m)
  assert.match(facing, /from ['"]\.\/GfxPaint['"]/)
  assert.match(facing, /from ['"]\.\/VeraInterpreter['"]/)
})

test('uninitialized and empty program readiness; real init trap and init effects never publish ready', () => {
  const p = probe()
  assert.equal(p.actor.ready(), false)
  assert.equal(p.actor.snapshot(), '')
  assert.equal(p.actor.view(), null)
  assert.deepEqual(p.actor.draw('draw'), [])
  p.actor.initialize({ vbc2: '', stamp: '' }, options())
  assert.equal(p.actor.ready(), false)
  assert.deepEqual(p.events, [])
  for (const program of [programs.initTrap, programs.initEffect, { vbc2: 'not bytecode', stamp: 'bad' }]) {
    p.reset()
    p.actor.replaceProgram(program, options())
    assert.equal(p.actor.ready(), false)
    assert.equal(p.actor.snapshot(), '')
    assert.equal(count(p, 'snapshot') + count(p, 'frame') + count(p, 'saved') + count(p, 'effect'), 0)
    assert.equal(count(p, 'ui-error'), 1)
    assert.equal(p.events.find(e => e.type === 'ui-error').kind, 'INIT')
    assert.equal(count(p, 'stop'), 0)
    assert.equal(count(p, 'save'), 0)
    p.actor.dispatch('change', number(5))
    assert.equal(count(p, 'ui-error'), 1)
  }
  p.reset()
  p.actor.replaceProgram(programs.basic, options('LIVE_EPHEMERAL', ''))
  assert(p.actor.ready())
  fresh = p.actor.snapshot()
  assert.deepEqual(p.state(), { n: 1, calls: 0, refreshes: 0, marks: [], badView: false })
  assert.deepEqual(sequence(p), ['init', 'snapshot', 'view', 'frame'])
})

test('persistent initialization order: snapshot/view precede refresh snapshot/view/save/effects', () => {
  const p = probe()
  p.actor.initialize(programs.refreshed, options())
  assert.deepEqual(sequence(p), ['init', 'snapshot', 'view', 'frame', 'widgetRefresh', 'snapshot', 'view', 'frame', 'save', 'saved', 'effect:refresh'])
  assert.deepEqual(p.snapshots.map(s => stateOf(s).n), [1, 11])
  assert.deepEqual(p.frames.map(f => f.root.text), ['n=1', 'n=11'])
  assert(p.frames.every(f => f.paint && !f.reveal))
  assert.equal(p.state().refreshes, 1)
  assert.equal(p.events.find(e => e.type === 'saved').projectId, 'project')
  assert.equal(store.loadState('project', 'version', programs.refreshed.stamp), p.actor.snapshot())
  assert.deepEqual(p.effects[0].params, [['label', 'refresh'], ['value', '11']])
  assert.equal(p.effects[0].target, target)
  assert.equal(p.effects[0].handler, 'answered')
  assert.equal(p.effects[0].mode, 'background')
  noErrors(p)
})

test('saved persistent state beats seed and init; mismatched stamp uses seed', () => {
  saveExternal(programs.basic, edited(fresh, { n: 40, calls: 6 }))
  const p = probe()
  p.actor.initialize(programs.basic, options('LIVE_PERSISTENT', 'project/version', edited(fresh, { n: 9 })))
  assert.equal(p.state().n, 40)
  assert.equal(p.state().calls, 6)
  assert.deepEqual(sequence(p), ['load', 'snapshot', 'view', 'frame'])
  assert.equal(count(p, 'save'), 0)
  p.reset()
  p.actor.replaceProgram(programs.newer, options('LIVE_PERSISTENT', 'project/version', edited(fresh, { n: 9 })))
  assert.deepEqual(sequence(p), ['load', 'init', 'view', 'snapshot', 'view', 'frame', 'widgetRefresh', 'snapshot', 'view', 'frame', 'save', 'saved', 'effect:refresh'])
  assert.equal(p.state().n, 19)
  assert.equal(p.state().added, 42)
})

test('malformed disk and seed fall back; carry view validation fails without a second init', () => {
  for (const stored of ['{broken', JSON.stringify({ stamp: programs.basic.stamp, value: ['unknown'] })]) {
    disk.set(stateFile(), stored)
    for (const seed of ['', '{broken', JSON.stringify(['unknown'])]) {
      const p = probe()
      p.actor.initialize(programs.basic, options('LIVE_PERSISTENT', 'project/version', seed))
      assert.equal(p.state().n, 1)
      assert.equal(entries(p).filter(e => e === 'init').length, 1)
      assert.equal(p.snapshots.length, 1)
      assert.equal(p.frames.length, 1)
      noErrors(p)
      assert.equal(count(p, 'save'), 0)
    }
  }
  disk.set(stateFile(), JSON.stringify({ stamp: programs.basic.stamp, value: ['unknown'] }))
  const p = probe()
  p.actor.initialize(programs.basic, options('LIVE_PERSISTENT', 'project/version', edited(fresh, { n: 8 })))
  assert.equal(p.state().n, 8)
  assert.deepEqual(entries(p), ['init', 'view', 'view'])
  const q = probe()
  q.actor.initialize(programs.basic, options('LIVE_EPHEMERAL', '', edited(fresh, { n: -4 })))
  assert.equal(q.state().n, 1)
  assert.deepEqual(entries(q), ['init', 'view', 'view'])
  assert.deepEqual(q.snapshots.map(stateOf).map(s => s.n), [1])
  assert(q.events.some(e => e.type === 'log-warn' && e.message.includes('could not carry')))
  noErrors(q)
})

test('carry uses new class shape and defaults, preserving compatible state only', () => {
  const p = probe()
  p.actor.initialize(programs.newer, options('LIVE_EPHEMERAL', '', edited(fresh, { n: 7, calls: 3 })))
  assert.equal(p.state().n, 17)
  assert.equal(p.state().calls, 3)
  assert.equal(p.state().added, 42)
  assert.equal(p.state().refreshes, 1)
  assert.deepEqual(entries(p), ['init', 'view', 'view', 'widgetRefresh', 'view'])
  noIo(p)
  noErrors(p)
})

test('preview ignores disk and seed; dispatch/move/frame/refresh/snapshot/save remain inert', () => {
  saveExternal(programs.refreshed, edited(fresh, { n: 80 }))
  for (const seed of [edited(fresh, { n: 99 }), '{broken']) {
    const p = probe()
    p.actor.initialize(programs.refreshed, options('PREVIEW', 'project/version', seed))
    assert(p.actor.ready())
    assert.deepEqual(sequence(p), ['init', 'view', 'frame'])
    assert.equal(p.frames[0].root.text, 'n=1')
    assert.equal(p.actor.snapshot(), '')
    p.reset()
    p.actor.dispatch('change', number(100))
    p.actor.dispatch('fail', number(100))
    p.actor.move('pointer', pointerValue('move', 1, 2, 3))
    p.actor.frameHandlers(['frameA', 'frameB'], 16)
    p.actor.runWidgetRefresh()
    p.actor.resume()
    p.actor.notifyStateSnapshot()
    p.actor.persistState()
    p.actor.beginSurfaceLoop(now)
    assert.equal(p.actor.surfaceSave(now + 6000, false), 'NOT_DUE')
    assert.deepEqual(p.events, [])
    p.render()
    assert.equal(p.frames[0].root.text, 'n=1')
    assert.deepEqual(entries(p), ['view'])
    noIo(p)
    noErrors(p)
  }
})

test('ephemeral seed/refresh/handlers/effect answers work without reading or writing disk', () => {
  const p = probe()
  p.actor.initialize(programs.refreshed, options('LIVE_EPHEMERAL', 'ignored/key', edited(fresh, { n: 4 })))
  assert.deepEqual(sequence(p), ['init', 'view', 'snapshot', 'view', 'frame', 'widgetRefresh', 'snapshot', 'view', 'frame', 'effect:refresh'])
  assert.equal(p.state().n, 14)
  p.reset()
  p.actor.dispatch('change', number(2))
  assert.deepEqual(sequence(p), ['change', 'snapshot', 'view', 'frame', 'effect:change'])
  assert.equal(p.state().n, 16)
  assert(p.frames[0].paint && p.frames[0].reveal)
  p.actor.dispatch('answered', new VeraStringValue('ok'), true, 'EFFECT_RESULT')
  assert.equal(p.state().n, 18)
  assert.equal(p.state().calls, 2)
  p.actor.persistState()
  p.actor.resume()
  assert.equal(p.state().n, 28)
  noIo(p)
  noErrors(p)
})

test('dispatch snapshot/view/save/effects order and persist=false suppresses only save', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.reset()
  p.actor.dispatch('change', number(2))
  assert.deepEqual(sequence(p), ['change', 'snapshot', 'view', 'frame', 'save', 'saved', 'effect:change'])
  assert.equal(stateOf(p.snapshots[0]).n, 3)
  assert.equal(p.frames[0].root.text, 'n=3')
  const saved = disk.get(stateFile())
  p.reset()
  p.actor.dispatch('change', number(4), false, 'TICK')
  assert.deepEqual(sequence(p), ['change', 'snapshot', 'view', 'frame', 'effect:change'])
  assert.equal(p.state().n, 7)
  assert.equal(disk.get(stateFile()), saved)
  p.reset()
  p.actor.dispatch('answered', new VeraStringValue('ok'), true, 'EFFECT_RESULT')
  assert.deepEqual(sequence(p), ['answered', 'snapshot', 'view', 'frame', 'save', 'saved'])
  assert.equal(p.state().n, 9)
  noErrors(p)
})

test('promotion preserves VM, state and effect sequence; no init, disk reload or refresh', () => {
  saveExternal(programs.refreshed, edited(fresh, { n: 90 }))
  const p = probe()
  p.actor.initialize(programs.refreshed, options('PREVIEW', 'project/version', edited(fresh, { n: 70 })))
  p.reset()
  const live = options('LIVE_PERSISTENT', 'project/version', edited(fresh, { n: 60 }))
  p.actor.promote(live)
  assert.deepEqual(sequence(p), ['snapshot', 'view', 'frame'])
  assert.equal(p.state().n, 1)
  assert.equal(p.state().refreshes, 0)
  p.actor.dispatch('change', number(3))
  const id = p.effects[0].id
  const snapshot = p.actor.snapshot()
  p.reset()
  p.actor.promote(live)
  assert.deepEqual(p.events, [])
  assert.equal(p.actor.snapshot(), snapshot)
  p.actor.promote(options('LIVE_EPHEMERAL', ''))
  assert.deepEqual(sequence(p), ['snapshot', 'view', 'frame'])
  assert.equal(p.actor.snapshot(), snapshot)
  p.reset()
  p.actor.dispatch('change', number(1))
  assert.equal(p.effects[0].id, id + 1)
  noIo(p)
  p.reset()
  p.actor.promote(options('PREVIEW', 'project/version'))
  assert.deepEqual(sequence(p), ['view', 'frame'])
  assert.equal(p.actor.snapshot(), '')
  p.reset()
  p.actor.dispatch('change', number(100))
  assert.deepEqual(p.events, [])
  p.actor.promote(live)
  assert.equal(p.state().n, 5)
  assert.equal(p.state().calls, 2)
  assert.equal(p.state().refreshes, 0)
})

test('both watcher orders replace with complete latest options and converge, with and without saved live state', () => {
  for (const stored of [false, true]) {
    const outcomes = []
    for (const order of ['promote-first', 'replace-first']) {
      disk.clear()
      if (stored) saveExternal(programs.newer, edited(fresh, { n: 70, calls: 8 }), 'latest/new-version')
      const p = probe()
      p.actor.initialize(programs.basic, options('PREVIEW', 'old/version', edited(fresh, { n: 99 })))
      p.reset()
      const latest = options('LIVE_PERSISTENT', 'latest/new-version', edited(fresh, { n: 20 }))
      if (order === 'promote-first') {
        p.actor.promote(latest)
        assert.equal(p.state().n, 1)
        assert(!entries(p).includes('widgetRefresh'))
        p.reset()
      }
      p.actor.replaceProgram(programs.newer, latest)
      assert.equal(p.state().n, stored ? 80 : 30)
      assert.equal(p.state().refreshes, 1)
      assert.equal(entries(p).filter(entry => entry === 'init').length, stored ? 0 : 1)
      assert.equal(p.frames[0].root.text, stored ? 'n=70' : 'n=20')
      assert.equal(p.events.find(e => e.type === 'save').file, stateFile('latest/new-version'))
      assert(p.events.filter(e => e.type === 'saved').every(e => e.projectId === 'latest'))
      const encoded = p.actor.snapshot()
      p.reset()
      p.actor.promote(latest)
      assert.deepEqual(p.events, [])
      assert.equal(store.loadState('latest', 'new-version', programs.newer.stamp), encoded)
      assert.equal(store.loadState('latest', 'new-version', programs.basic.stamp), '')
      outcomes.push(encoded)
      noErrors(p)
    }
    assert.equal(outcomes[0], outcomes[1])
  }
})

test('replacement resets old runtime and installs new mode, key and seed, including live-to-preview', () => {
  const p = probe()
  p.actor.initialize(programs.refreshed, options())
  p.actor.dispatch('change', number(2))
  p.reset()
  p.actor.replaceProgram(programs.newer, options('LIVE_EPHEMERAL', '', edited(fresh, { n: 8 })))
  assert.equal(p.state().n, 18)
  assert.equal(p.state().calls, 0)
  assert.equal(p.state().added, 42)
  noIo(p)
  p.reset()
  p.actor.replaceProgram(programs.refreshed, options('PREVIEW', 'new/project', edited(fresh, { n: 50 })))
  assert.deepEqual(sequence(p), ['init', 'view', 'frame'])
  assert.equal(p.actor.snapshot(), '')
  assert.equal(p.frames[0].root.text, 'n=1')
  p.actor.resume()
  p.actor.runWidgetRefresh()
  noIo(p)
})

test('resume adopts external Form state before view/refresh/save and does not roll back unsaved live state for identical disk', () => {
  const p = probe()
  p.actor.initialize(programs.refreshed, options())
  p.actor.dispatch('change', number(5), false)
  assert.equal(p.state().n, 16)
  p.reset()
  p.actor.resume()
  assert.deepEqual(sequence(p), ['load', 'reload', 'view', 'frame', 'widgetRefresh', 'snapshot', 'view', 'frame', 'save', 'saved', 'effect:refresh'])
  assert.equal(p.events.find(e => e.type === 'reload').changed, false)
  assert.equal(p.frames[0].root.text, 'n=16')
  assert.equal(p.state().n, 26)
  saveExternal(programs.refreshed, edited(p.actor.snapshot(), { n: 100, calls: 50 }))
  p.reset()
  p.actor.resume()
  assert.deepEqual(sequence(p), ['load', 'reload', 'load', 'view', 'frame', 'widgetRefresh', 'snapshot', 'view', 'frame', 'save', 'saved', 'effect:refresh'])
  assert.equal(p.events.find(e => e.type === 'reload').changed, true)
  assert.equal(p.frames[0].root.text, 'n=100')
  assert.equal(p.state().n, 110)
  assert.equal(p.state().calls, 50)
  assert.equal(stateOf(store.loadState('project', 'version', programs.refreshed.stamp)).n, 110)
  noErrors(p)
})

test('resume malformed or missing external state retains live state; no unconditional overwrite without refresh', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.actor.dispatch('change', number(2))
  p.actor.dispatch('change', number(3), false)
  for (const value of ['{broken', JSON.stringify({ stamp: programs.basic.stamp, value: ['unknown'] }), null]) {
    if (value === null) disk.delete(stateFile())
    else disk.set(stateFile(), value)
    p.reset()
    p.actor.resume()
    assert.equal(p.state().n, 6)
    assert.equal(p.frames[0].root.text, 'n=6')
    assert.equal(count(p, 'save') + count(p, 'snapshot'), 0)
    assert.equal(disk.get(stateFile()), value === null ? undefined : value)
    noErrors(p)
  }
})

test('handler traps retain partial in-place mutations, suppress queued effects and stop only after error', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.actor.persistState()
  const saved = disk.get(stateFile())
  p.reset()
  p.actor.dispatch('fail', number(7))
  assert.deepEqual(sequence(p), ['fail', 'ui-error:HANDLER', 'stop:HANDLER'])
  assert.match(p.events.find(e => e.type === 'ui-error').message, /^Action error:/)
  assert.deepEqual(p.state(), { n: 8, calls: 1, refreshes: 0, marks: [7], badView: false })
  assert.equal(disk.get(stateFile()), saved)
  assert.equal(p.snapshots.length + p.frames.length + p.effects.length, 0)
  p.reset()
  p.actor.dispatch('recover', number(1))
  assert.equal(p.state().n, 9)
  assert.equal(p.state().calls, 2)
  assert.equal(p.effects.length, 0)
  assert.deepEqual(entries(p), ['recover', 'view'])
  assert.equal(stateOf(store.loadState('project', 'version', programs.basic.stamp)).n, 9)
})

test('view trap after successful handler keeps last tree; snapshot/save/effects continue without rerun or timer stop', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  const lastFrame = p.frames[0]
  p.reset()
  p.actor.dispatch('breakView', number(4))
  assert.deepEqual(sequence(p), ['breakView', 'snapshot', 'view', 'ui-error:VIEW', 'save', 'saved', 'effect:breakView'])
  assert.equal(p.state().n, 5)
  assert.equal(p.state().calls, 1)
  assert.equal(p.frames.length, 0)
  assert.equal(lastFrame.root.text, 'n=1')
  assert.equal(count(p, 'stop'), 0)
  assert.equal(stateOf(p.snapshots[0]).n, 5)
  assert.equal(stateOf(store.loadState('project', 'version', programs.basic.stamp)).n, 5)
  p.reset()
  p.actor.dispatch('recover', number(1))
  assert.equal(p.frames[0].root.text, 'n=6')
  assert.equal(p.state().calls, 2)
  assert.deepEqual(entries(p), ['recover', 'view'])
})

test('view effects forbidden during initial render and after handlers without leaking effects', () => {
  const p = probe()
  p.actor.initialize(programs.viewEffect, options())
  assert(p.actor.ready())
  assert.deepEqual(sequence(p), ['init', 'snapshot', 'view', 'ui-error:VIEW'])
  assert.match(p.events.find(e => e.type === 'ui-error').message, /sdk.call may only be called from a handler/)
  p.reset()
  p.actor.dispatch('change', number(2))
  assert.deepEqual(sequence(p), ['change', 'snapshot', 'view', 'ui-error:VIEW', 'save', 'saved', 'effect:change'])
  assert.equal(p.state().calls, 1)
  assert.equal(count(p, 'stop'), 0)
})

test('draw effects forbidden; independent draw trap cannot rerun or undo completed handler/save/effects', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.reset()
  p.actor.dispatch('change', number(2))
  const snapshot = p.actor.snapshot()
  for (const entry of ['drawEffect', 'drawTrap']) {
    const before = p.events.length
    assert.equal(p.paint(entry), null)
    assert.deepEqual(sequence({ events: p.events.slice(before) }), [entry, 'ui-error:DRAW', 'stop:DRAW'])
    assert.equal(p.actor.snapshot(), snapshot)
  }
  assert.equal(entries(p).filter(e => e === 'change').length, 1)
  assert.equal(p.effects.length, 1)
  assert.equal(count(p, 'save'), 1)
  p.reset()
  const ops = p.paint()
  assert.equal(ops.length, 1)
  assert.equal(ops[0].x, 3)
  assert.deepEqual(p.actor.draw(''), [])
  p.actor.dispatch('recover', number(1))
  assert.equal(p.effects.length, 0)
  assert.equal(p.state().calls, 2)
})

test('save failures are log-only; successful handler snapshot/render/effects continue and retry saves current state', () => {
  for (const stage of ['open', 'write', 'close', 'rename']) {
    const p = probe()
    p.actor.initialize(programs.basic, options())
    p.actor.persistState()
    const saved = disk.get(stateFile())
    p.reset()
    failure = stage
    p.actor.dispatch('change', number(3))
    failure = ''
    assert.equal(p.state().n, 4)
    assert.equal(p.state().calls, 1)
    assert.equal(p.snapshots.length, 1)
    assert.equal(p.frames.length, 1)
    assert.equal(p.effects.length, 1)
    assert.equal(count(p, 'saved') + count(p, 'stop'), 0)
    assert.equal(disk.get(stateFile()), saved)
    assert(p.events.some(e => e.type === 'log-error' && e.message.includes('save failed')))
    noErrors(p)
    const at = p.events.findIndex(e => e.type === 'log-error' && e.message.includes('save failed'))
    assert(at > p.events.findIndex(e => e.type === 'frame'))
    assert(at < p.events.findIndex(e => e.type === 'effect'))
    assert(![...disk.keys()].some(file => file.endsWith('.tmp')))
    p.reset()
    p.actor.persistState()
    assert.deepEqual(sequence(p), ['save', 'saved'])
    assert.equal(stateOf(store.loadState('project', 'version', programs.basic.stamp)).n, 4)
    disk.clear()
  }
})

test('refresh traps are log-only, discard effects, retain mutations and create no snapshot/save/render', () => {
  const p = probe()
  p.actor.initialize(programs.refreshTrap, options())
  assert.deepEqual(sequence(p), ['init', 'snapshot', 'view', 'frame', 'widgetRefresh'])
  assert.equal(p.frames[0].root.text, 'n=1')
  assert.equal(stateOf(p.snapshots[0]).n, 1)
  assert.equal(p.state().n, 101)
  assert.equal(p.state().refreshes, 1)
  assert(p.events.some(e => e.type === 'log-warn' && e.message.includes('widgetRefresh failed')))
  assert.equal(count(p, 'save') + count(p, 'stop') + p.effects.length, 0)
  noErrors(p)
  p.reset()
  p.actor.runWidgetRefresh()
  assert.deepEqual(sequence(p), ['widgetRefresh'])
  assert.equal(p.state().n, 201)
  assert.equal(p.state().refreshes, 2)
  p.reset()
  p.actor.dispatch('recover', number(1))
  assert.equal(p.state().n, 202)
  assert.equal(p.effects.length, 0)
  assert.equal(stateOf(store.loadState('project', 'version', programs.refreshTrap.stamp)).n, 202)
})

test('refresh view failure still saves and delivers effects; no handler rerun or timer stop', () => {
  const p = probe()
  p.actor.initialize(programs.refreshed, options())
  p.actor.dispatch('breakView', number(1), false)
  p.reset()
  p.actor.runWidgetRefresh()
  assert.deepEqual(sequence(p), ['widgetRefresh', 'snapshot', 'view', 'ui-error:VIEW', 'save', 'saved', 'effect:refresh'])
  assert.equal(p.state().n, 22)
  assert.equal(p.state().refreshes, 2)
  assert.equal(count(p, 'stop'), 0)
})

const worldEvent = (kind, speed = 0) => sceneEventValue(kind, 'body', '', 0, 0, 0, speed, [], [])

test('world build decodes actor state with effects disabled, propagates traps and is inert when unavailable', () => {
  const p = probe()
  assert.deepEqual(p.actor.buildScene('build'), new WorldSpec())
  p.actor.initialize(programs.world, options())
  p.reset()
  const before = p.actor.snapshot()
  const scene = p.actor.buildScene('build')
  assert(scene instanceof WorldSpec)
  assert.deepEqual(scene.bodies[0].position, [1, 2, 3])
  assert.equal(scene.bodies[0].id, 'body')
  assert(scene.floor)
  assert.deepEqual(sequence(p), ['build'])
  assert.equal(p.actor.snapshot(), before)
  assert.throws(() => p.actor.buildScene('buildEffect'), /sdk.call may only be called from a handler/)
  assert.throws(() => p.actor.buildScene('buildTrap'))
  assert.throws(() => p.actor.buildScene('buildInvalid'), /at most one scene.floor/)
  assert.deepEqual(p.actor.buildScene(''), new WorldSpec())
  assert.equal(p.effects.length + p.frames.length + p.snapshots.length, 0)
  noIo(p)
  p.actor.dispatch('recover', number(1))
  assert.equal(p.effects.length, 0)
  assert.equal(p.actor.buildScene('build').bodies[0].position[0], 2)
  p.actor.initialize(programs.world, options('PREVIEW'))
  p.reset()
  assert.equal(p.actor.buildScene('build').bodies[0].position[0], 1)
  p.actor.dispatch('worldEvent', worldEvent('hit', 3), false, 'WORLD', true)
  assert.equal(p.actor.worldDirty(), false)
  assert.equal(p.actor.worldSave(now + 5000, false, true), 'NOT_DUE')
  p.actor.dispose()
  assert.deepEqual(p.actor.buildScene('build'), new WorldSpec())
})

test('unchanged world handlers drain effects without snapshot/render/save; encoded equality detects in-place changes', () => {
  const p = probe()
  p.actor.initialize(programs.world, options())
  p.reset()
  p.actor.dispatch('worldEvent', worldEvent('tap'), true, 'WORLD', true)
  assert.deepEqual(sequence(p), ['worldEvent', 'effect:world'])
  assert.equal(p.actor.worldDirty(), false)
  p.reset()
  p.actor.dispatch('worldCopy', number(0), true, 'WORLD', true)
  assert.deepEqual(sequence(p), ['worldCopy'])
  p.reset()
  p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
  assert.deepEqual(sequence(p), ['worldEvent', 'snapshot', 'view', 'frame', 'effect:world'])
  assert.equal(p.state().n, 3)
  assert.equal(p.actor.worldDirty(), true)
  noIo(p)
  p.reset()
  p.actor.dispatch('worldEvent', worldEvent('hit'), false, 'WORLD', true)
  assert.deepEqual(sequence(p), ['worldEvent', 'effect:world'])
  assert.equal(p.actor.worldDirty(), true)
  p.reset()
  p.actor.dispatch('worldEvent', worldEvent('settled'), true, 'WORLD', true)
  assert.deepEqual(sequence(p), ['worldEvent', 'save', 'saved', 'effect:world'])
  assert.equal(p.actor.worldDirty(), false)
  assert.equal(stateOf(store.loadState('project', 'version', programs.world.stamp)).n, 3)
  p.reset()
  p.actor.dispatch('worldCopy', number(0))
  assert.deepEqual(sequence(p), ['worldCopy', 'snapshot', 'view', 'frame', 'save', 'saved'])
  noErrors(p)
})

test('world save shares the 5000ms gate, defers drafts, bypasses time when stopping and never snapshots', () => {
  const p = probe()
  p.actor.initialize(programs.world, options())
  p.actor.beginSurfaceLoop(now)
  assert.equal(p.actor.worldSave(now + 6000, false, true), 'NOT_DUE')
  p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
  p.reset()
  assert.equal(p.actor.worldSave(now + 4999, false, false), 'NOT_DUE')
  assert.equal(p.actor.worldSave(now + 5000, true, false), 'DEFERRED')
  assert.equal(p.actor.worldSave(now + 5000, true, true), 'DEFERRED')
  assert.deepEqual(p.events, [])
  assert.equal(p.actor.worldDirty(), true)
  assert.equal(p.actor.worldSave(now + 5000, false, false), 'DONE')
  assert.deepEqual(sequence(p), ['save', 'saved'])
  assert.equal(p.actor.worldDirty(), false)
  p.actor.dispatch('worldEvent', worldEvent('hit', 3), false, 'WORLD', true)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 9999, false), 'NOT_DUE')
  assert.equal(p.actor.worldSave(now + 9999, false, false), 'NOT_DUE')
  assert.equal(p.actor.worldSave(now + 9999, false, true), 'DONE')
  assert.deepEqual(sequence(p), ['save', 'saved'])
  assert.equal(stateOf(store.loadState('project', 'version', programs.world.stamp)).n, 6)
  assert.equal(p.actor.worldDirty(), false)
})

test('failed world persistence retains dirty state and deadline for immediate retries and unchanged saving events', () => {
  for (const stage of ['open', 'write', 'close', 'rename']) {
    disk.clear()
    const p = probe()
    p.actor.initialize(programs.world, options())
    assert.equal(p.actor.persistState(), true)
    const saved = disk.get(stateFile())
    p.actor.beginSurfaceLoop(now)
    p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
    p.reset()
    failure = stage
    assert.equal(p.actor.worldSave(now + 5000, false, false), 'ERROR')
    assert.equal(p.actor.worldDirty(), true)
    assert.equal(disk.get(stateFile()), saved)
    assert.equal(p.snapshots.length + p.frames.length + count(p, 'saved'), 0)
    p.actor.dispatch('worldEvent', worldEvent('settled'), true, 'WORLD', true)
    assert.equal(p.actor.worldDirty(), true)
    assert.deepEqual(sequence(p), ['worldEvent', 'effect:world'])
    failure = ''
    p.reset()
    assert.equal(p.actor.worldSave(now + 5000, false, false), 'DONE')
    assert.equal(p.actor.worldDirty(), false)
    assert.deepEqual(sequence(p), ['save', 'saved'])
    noErrors(p)
  }
})

test('world dirty clears on any successful persist, initialization and dispose, but not on unavailable persistence', () => {
  const p = probe()
  assert.equal(p.actor.worldDirty(), false)
  assert.equal(p.actor.worldSave(now, false, true), 'NOT_DUE')
  assert.equal(p.actor.persistState(), false)
  for (const opts of [options('LIVE_EPHEMERAL', ''), options('LIVE_PERSISTENT', 'invalid')]) {
    p.actor.initialize(programs.world, opts)
    p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
    p.reset()
    assert.equal(p.actor.worldSave(now, false, true), 'ERROR')
    assert.equal(p.actor.worldDirty(), true)
    assert.equal(p.actor.persistState(), false)
    assert.equal(p.actor.worldDirty(), true)
    noIo(p)
  }
  p.actor.initialize(programs.world, options())
  assert.equal(p.actor.worldDirty(), false)
  p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
  assert.equal(p.actor.persistState(), true)
  assert.equal(p.actor.worldDirty(), false)
  p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
  p.actor.dispatch('recover', number(1))
  assert.equal(p.actor.worldDirty(), false)
  p.actor.dispatch('worldEvent', worldEvent('hit', 2), false, 'WORLD', true)
  p.actor.dispose()
  assert.equal(p.actor.worldDirty(), false)
  assert.equal(p.actor.worldSave(now + 6000, false, true), 'NOT_DUE')
})

test('surface frame handlers execute in caller order; effects precede explicit UI draw/view and periodic save/snapshot', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.actor.beginSurfaceLoop(now)
  p.reset()
  now += 5000
  p.actor.frameHandlers(['frameA', '', 'frameB'], 16)
  assert.deepEqual(sequence(p), ['frameA', 'frameB', 'effect:frameA', 'effect:frameB'])
  assert.equal(p.state().n, 112)
  assert.deepEqual(p.state().marks, [16, 16])
  assert.equal(p.snapshots.length + p.frames.length, 0)
  assert(p.actor.viewDue(now))
  assert.equal(p.paint()[0].x, 112)
  p.render(false)
  assert.equal(p.actor.surfaceSave(now, false), 'DONE')
  assert.deepEqual(sequence(p), ['frameA', 'frameB', 'effect:frameA', 'effect:frameB', 'draw', 'draw', 'view', 'frame', 'save', 'saved', 'snapshot'])
  assert(!p.frames[0].paint && !p.frames[0].reveal)
  assert.equal(stateOf(p.snapshots[0]).n, 112)
  noErrors(p)
})

test('surface move effects precede UI drawing, with no actor render, snapshot or durable save', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.reset()
  p.actor.move('pointer', pointerValue('move', 2, 3, 4))
  assert.deepEqual(sequence(p), ['pointer', 'effect:pointer'])
  assert.equal(p.state().n, 10)
  assert.equal(p.state().calls, 1)
  assert.equal(p.snapshots.length + p.frames.length, 0)
  noIo(p)
  p.paint()
  assert.deepEqual(sequence(p), ['pointer', 'effect:pointer', 'draw', 'draw'])
  now += 100
  assert(p.actor.viewDue(now))
  p.render(false)
  assert.equal(p.frames[0].root.text, 'n=10')
  noIo(p)
})

test('frame and move traps propagate for caller reporting, suppress effects and retain partial mutation', () => {
  for (const kind of ['FRAME', 'MOVE']) {
    disk.clear()
    const p = probe()
    p.actor.initialize(programs.basic, options())
    p.reset()
    let trapped
    try {
      if (kind === 'FRAME') p.actor.frameHandlers(['frameA', 'fail', 'frameB'], 4)
      else p.actor.move('fail', number(4))
    } catch (e) {
      trapped = e
      p.error(kind, e.message)
    }
    assert(trapped && trapped.trapCode)
    assert.deepEqual(entries(p), kind === 'FRAME' ? ['frameA', 'fail'] : ['fail'])
    assert.deepEqual(sequence(p).slice(-2), ['ui-error:' + kind, 'stop:' + kind])
    assert.equal(p.state().n, kind === 'FRAME' ? 15 : 5)
    assert.equal(p.state().calls, kind === 'FRAME' ? 2 : 1)
    assert.equal(p.snapshots.length + p.frames.length + p.effects.length + count(p, 'save'), 0)
    p.reset()
    p.actor.dispatch('recover', number(1))
    assert.equal(p.effects.length, 0)
  }
})

test('view cadence boundary and surface edit gate defer without advancing save deadline', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  assert.equal(p.actor.viewDue(now + 99), false)
  assert.equal(p.actor.viewDue(now + 100), true)
  now += 100
  p.render(false)
  assert.equal(p.actor.viewDue(now + 99), false)
  assert.equal(p.actor.viewDue(now + 100), true)
  p.actor.beginSurfaceLoop(now)
  p.reset()
  p.actor.frameHandlers(['frameA'], 16)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 4999, false), 'NOT_DUE')
  assert.equal(p.actor.surfaceSave(now + 5000, true), 'DEFERRED')
  assert.equal(p.actor.surfaceSave(now + 9000, true), 'DEFERRED')
  assert.deepEqual(p.events, [])
  assert.equal(p.actor.surfaceSave(now + 9000, false), 'DONE')
  assert.deepEqual(sequence(p), ['save', 'saved', 'snapshot'])
  assert.equal(stateOf(p.snapshots[0]).n, 11)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 13999, false), 'NOT_DUE')
  assert.equal(p.actor.surfaceSave(now + 14000, false), 'DONE')
  p.actor.beginSurfaceLoop(now + 15000)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 19999, false), 'NOT_DUE')
  assert.deepEqual(p.events, [])
  assert.equal(p.actor.surfaceSave(now + 20000, false), 'DONE')
})

test('failed surface save publishes no snapshot, retains deadline and retries immediately', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options())
  p.actor.persistState()
  const saved = disk.get(stateFile())
  p.actor.beginSurfaceLoop(now)
  p.actor.frameHandlers(['frameA'], 16)
  p.reset()
  failure = 'rename'
  assert.equal(p.actor.surfaceSave(now + 5000, false), 'NOT_SAVED')
  failure = ''
  assert.deepEqual(sequence(p), [])
  assert.equal(p.snapshots.length, 0)
  assert.equal(count(p, 'save-attempt'), 1)
  assert.equal(count(p, 'saved'), 0)
  assert.equal(disk.get(stateFile()), saved)
  assert(p.events.some(e => e.type === 'log-error' && e.message.includes('save failed')))
  noErrors(p)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 5000, false), 'DONE')
  assert.deepEqual(sequence(p), ['save', 'saved', 'snapshot'])
  assert.equal(stateOf(p.snapshots[0]).n, 11)
  assert.equal(stateOf(store.loadState('project', 'version', programs.basic.stamp)).n, 11)
  p.reset()
  assert.equal(p.actor.surfaceSave(now + 9999, false), 'NOT_DUE')
  assert.deepEqual(p.events, [])
  assert.equal(p.actor.surfaceSave(now + 10000, false), 'DONE')
  assert.deepEqual(sequence(p), ['save', 'saved', 'snapshot'])
})

test('ephemeral and malformed-key periodic saves return NOT_SAVED without snapshot or IO', () => {
  for (const opts of [options('LIVE_EPHEMERAL', ''), options('LIVE_PERSISTENT', ''), options('LIVE_PERSISTENT', 'invalid'), options('LIVE_PERSISTENT', '/version')]) {
    const p = probe()
    p.actor.initialize(programs.basic, opts)
    p.actor.beginSurfaceLoop(now)
    p.reset()
    p.actor.frameHandlers(['frameA'], 16)
    assert.equal(p.actor.surfaceSave(now + 5000, false), 'NOT_SAVED')
    assert.equal(p.actor.surfaceSave(now + 5000, false), 'NOT_SAVED')
    assert.equal(p.snapshots.length, 0)
    assert.equal(p.state().n, 11)
    noIo(p)
  }
})

test('real ProjectStore roundtrip retains legacy stamp/value object and failure leaves previous atomic record', () => {
  const other = new ProjectStore()
  other.init('/actor-fixture')
  const encoded = edited(fresh, { n: 23 })
  other.saveState('roundtrip', 'version', programs.basic.stamp, encoded)
  const file = stateFile('roundtrip/version')
  const payload = JSON.parse(disk.get(file))
  assert.deepEqual(Object.keys(payload).sort(), ['stamp', 'value'])
  assert(Array.isArray(payload.value))
  assert.deepEqual(payload.value, JSON.parse(encoded))
  assert.equal(payload.stamp, programs.basic.stamp)
  assert.equal(store.loadState('roundtrip', 'version', programs.basic.stamp), encoded)
  assert.equal(other.loadState('roundtrip', 'version', 'wrong-stamp'), '')
  const previous = disk.get(file)
  for (const stage of ['open', 'write', 'close', 'rename']) {
    failure = stage
    assert.throws(() => other.saveState('roundtrip', 'version', programs.basic.stamp, edited(fresh, { n: 99 })), /fixture .* failed/)
    failure = ''
    assert.equal(disk.get(file), previous)
    assert.equal(store.loadState('roundtrip', 'version', programs.basic.stamp), encoded)
    assert(![...disk.keys()].some(key => key.endsWith('.tmp')))
  }
  assert.throws(() => other.saveState('roundtrip', 'version', programs.basic.stamp, '{broken'), SyntaxError)
  assert.equal(disk.get(file), previous)
  other.clearState('roundtrip', 'version')
  assert.equal(other.loadState('roundtrip', 'version', programs.basic.stamp), '')
})

test('actors own independent real VM/state/host; dispose is idempotent and all execution becomes inert', () => {
  const p = probe()
  p.actor.initialize(programs.basic, options('LIVE_EPHEMERAL', ''))
  p.actor.dispatch('change', number(2))
  const q = probe()
  q.actor.initialize(programs.basic, options('LIVE_EPHEMERAL', ''))
  assert.equal(q.state().n, 1)
  q.actor.dispatch('change', number(8))
  assert.equal(p.state().n, 3)
  assert.equal(q.state().n, 9)
  assert.equal(p.effects[0].id, q.effects[0].id)
  p.actor.dispose()
  assert.equal(p.actor.ready(), false)
  p.reset()
  records = p.events
  p.actor.dispose()
  p.actor.initialize(programs.refreshed, options())
  p.actor.replaceProgram(programs.refreshed, options())
  p.actor.promote(options())
  p.actor.resume()
  p.actor.runWidgetRefresh()
  p.actor.dispatch('change', number(5))
  p.actor.move('pointer', pointerValue('move', 0, 1, 2))
  p.actor.frameHandlers(['frameA'], 16)
  p.actor.beginSurfaceLoop(now)
  p.actor.persistState()
  p.actor.notifyStateSnapshot()
  p.actor.clearEffects()
  assert.equal(p.actor.snapshot(), '')
  assert.equal(p.actor.view(), null)
  assert.deepEqual(p.actor.draw('draw'), [])
  assert.equal(p.actor.viewDue(now + 10000), false)
  assert.equal(p.actor.surfaceSave(now + 10000, false), 'NOT_DUE')
  assert.deepEqual(p.events, [])
  assert.equal(q.state().n, 9)
  q.actor.dispose()
})

const originalNow = Date.now
const originalConsole = Object.fromEntries(['info', 'warn', 'error'].map(level => [level, console[level]]))
let passed = 0
try {
  Date.now = () => now
  for (const level of ['info', 'warn', 'error']) console[level] = (...args) => records.push({ type: 'log-' + level, message: args.join(' ') })
  for (const { name, run } of tests) {
    disk.clear()
    records = []
    failure = ''
    now = 100000
    try {
      run()
      passed++
      console.log('PASS ' + name)
    } catch (error) {
      originalConsole.error('FAIL ' + name + '\n' + error.stack)
      process.exitCode = 1
    } finally {
      failure = ''
      StageTrace.configure(false)
    }
  }
} finally {
  Date.now = originalNow
  Object.assign(console, originalConsole)
}
console.log(`app-actor-check: ${passed}/${tests.length} focused actor scenarios passed`)
console.log('Scope: current AppActor public API, real compiler/VM/UI host/carry/ProjectStore, in-memory CoreFileKit; no InProcessHost/mailbox, ArkUI/device, network or model execution.')
