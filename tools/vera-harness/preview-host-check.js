'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const root = path.resolve(process.env.VERA_SOURCE_ROOT || path.join(__dirname, '../../entry/src/main/ets'))
const previewFile = path.join(root, 'components/VeraPreview.ets')
const previewSource = fs.readFileSync(previewFile, 'utf8')
const cache = new Map()
const disk = new Map()
const timers = new Map()
const hosts = []
const previews = []
const logs = []
const adapterCalls = []
const callbackErrors = []
const unhandled = []
let now = 100000
let nextTimer = 0
let saveFailure = false
const quiet = Object.fromEntries(['info', 'warn', 'error', 'debug', 'log'].map(level => [level, (...args) => logs.push([level, ...args])]))
const clock = class extends Date { static now() { return now } }
const schedule = (callback, delay, interval = false) => {
  const id = ++nextTimer
  timers.set(id, { callback, delay, at: now + delay, interval })
  return id
}
const forbidden = name => new Proxy({}, { get(_target, key) { throw Error('Forbidden platform access: ' + name + '.' + String(key)) } })
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
    if (saveFailure) throw Error('fixture save failed')
    assert(disk.has(from))
    disk.set(to, disk.get(from))
    disk.delete(from)
  },
  unlinkSync(file) { disk.delete(file) },
  listFileSync(dir) { return [...disk.keys()].filter(file => path.dirname(file) === dir).map(file => path.basename(file)) }
}
class WorldBox {
  constructor() {
    this.key = ''
    this.theme = null
    this.camera = { yaw: 0 }
    this.retired = false
    this.applies = 0
    this.frames = 0
    this.advances = 0
    this.awake = 0
    this.writeMs = 0
    this.stepMs = 0
    this.mostContacts = 0
    this.events = []
  }
  apply(spec, theme) { this.spec = spec; this.theme = theme; this.applies++ }
  retire() { this.retired = true }
  needsFrames() { return !this.retired }
  frame() { this.frames++ }
  advance() { this.advances++ }
  bodyCount() { return this.spec.bodies.length }
  takeEvents(limit) { return this.events.splice(0, limit) }
}
class TextInputController {
  constructor() { this.text = '' }
  getText() { return this.text }
}
const platform = {
  ObservedV2: value => value,
  Trace() {},
  Scroller: class {},
  TextInputController,
  TextTimerController: class {},
  CanvasRenderingContext2D: class {},
  RenderingContextSettings: class {},
  TouchType: { Down: 0, Move: 1, Up: 2, Cancel: 3 },
  Date: clock,
  console: quiet,
  setTimeout: (callback, delay) => schedule(callback, delay),
  clearTimeout: id => timers.delete(id),
  setInterval: (callback, delay) => schedule(callback, delay, true),
  clearInterval: id => timers.delete(id)
}
function declaration(source, prefix) {
  const start = source.indexOf(prefix)
  assert(start >= 0, 'missing declaration: ' + prefix)
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(start))
  let depth = 0
  let opened = false
  while (scanner.scan() !== ts.SyntaxKind.EndOfFileToken) {
    if (scanner.getToken() === ts.SyntaxKind.OpenBraceToken) { depth++; opened = true }
    if (scanner.getToken() === ts.SyntaxKind.CloseBraceToken && --depth === 0 && opened) {
      return source.slice(start, start + scanner.getTextPos())
    }
  }
  throw Error('unterminated declaration: ' + prefix)
}
function extractPreview() {
  let source = previewSource.replace(/\r\n/g, '\n')
  source = source.replace(declaration(source, '  build()'), '')
  const builders = [...source.matchAll(/^  @LocalBuilder\s*\n  (\w+)\(/gm)].map(match => match[1])
  assert(builders.length > 0, 'must exclude ArkUI builders')
  for (const name of builders) source = source.replace('  @LocalBuilder\n' + declaration(source, '  ' + name + '('), '')
  source = source.replace('export struct VeraPreview', 'export class VeraPreview')
    .replace(/@(Watch|StorageProp)\([^)]*\)/g, '')
    .replace(/@(Component|ObservedV2|Trace|Prop|State)\b/g, '')
  return source
}
function load(file) {
  file = path.resolve(file)
  if (cache.has(file)) return cache.get(file).exports
  const source = file === previewFile ? extractPreview() : fs.readFileSync(file, 'utf8')
  const compiled = ts.transpileModule(source, {
    fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
    reportDiagnostics: true
  })
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, file + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'))
  const mod = { exports: {} }
  cache.set(file, mod)
  const importer = name => {
    if (name.endsWith('/VeraWorld3D')) return { WorldBox }
    if (name.endsWith('/FormUpdater')) return { scheduleCardRefresh() {} }
    if (name.endsWith('/VeraIntents')) return { runRawIntent: async (...args) => { adapterCalls.push(args); return 'ok' } }
    if (name.endsWith('/VeraSdkBackend')) return { runSdkAdapter: async (...args) => { adapterCalls.push(args); return 'ok' } }
    if (name.endsWith('/VeraConsentStore')) return { consent: { has: () => true, remember() {} } }
    if (name === '@kit.CoreFileKit') return { fileIo: filesystem }
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: forbidden('hilog') }
    if (name === '@kit.ArkUI') return { LengthMetrics: {}, mediaquery: {}, matrix4: forbidden('matrix4') }
    if (name === '@kit.ArkGraphics2D') return { displaySync: { create() { throw Error('fixture interval fallback') } } }
    if (name.startsWith('@kit.') || name === 'libllama.so') return forbidden(name)
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'))
    throw Error('Unsupported dependency: ' + name + ' from ' + file)
  }
  new Function('require', 'module', 'exports', ...Object.keys(platform), compiled.outputText)(importer, mod, mod.exports, ...Object.values(platform))
  return mod.exports
}
const { InProcessHost } = load(path.join(root, 'runtime/InProcessHost.ets'))
const { VeraPreview, VeraPreviewController } = load(previewFile)
const { compileVeraSource } = load(path.join(root, 'vera/VeraCompiler.ets'))
const { veraStateStamp } = load(path.join(root, 'vera/VeraStateStamp.ets'))
const { store } = load(path.join(root, 'vera/ProjectStore.ets'))
store.init('/preview-host-fixture')
function compile({ initial = 0, bad = false, viewTrapAfter = false, refreshTrap = false, ticker = 0, surface = false, animated = false, effect = false, world = false, worldUnchanged = false, hideWorldAfterEvent = false } = {}) {
  const source = `
@jsonable class AppState { n: number; text: string; order: string[]; seen: string[]; }
function init(): AppState { return {n: ${initial}, text: "initial", order: [], seen: []}; }
function edit(state: AppState, value: string): AppState {
  state.text = value; state.order.push("field"); return state;
}
function add(state: AppState, value: number): AppState {
  state.n = state.n + value; state.order.push("add"); state.seen.push(state.text); return state;
}
function tick(state: AppState, value: number): AppState {
  state.n = state.n + 1; state.order.push("tick"); state.seen.push(state.text); return state;
}
function pointer(state: AppState, value: gfx.Pointer): AppState {
  state.order.push(value.phase); state.seen.push(state.text); return state;
}
function draw(state: AppState): gfx.Shape[] { return []; }
${world ? 'function buildWorld(state: AppState): scene.Thing[] { return [scene.box("body", state.n, 2, 3, 1, 2, 3, "accent")]; } function worldEvent(state: AppState, event: scene.Event): AppState { ' + (worldUnchanged ? '' : 'state.n = state.n + 1; ') + 'return state; }' : ''}
function answered(state: AppState, value: string): AppState { state.order.push("answer"); return state; }
${effect || refreshTrap ? 'function widgetRefresh(state: AppState): AppState { ' + (refreshTrap ? 'state.n = 1; ' : '') + (effect ? 'sdk.call("Fixture.device.read", [], "answered"); ' : '') + 'return state; }' : ''}
function view(state: AppState): ui.View {
  ${bad ? 'let empty: number[] = []; state.n = empty[1];' : ''}
  ${viewTrapAfter ? 'if (state.n > 0) { let empty: number[] = []; state.n = empty[1]; }' : ''}
  ${hideWorldAfterEvent ? 'if (state.n > 0) { return ui.Column("default", [ui.TextField("default", "Text", state.text, "edit"), ui.Text("body", ui.numberToString(state.n))]); }' : ''}
  return ui.Column("default", [ui.TextField("default", "Text", state.text, "edit"),
    ui.Text("body", ui.numberToString(state.n))
    ${ticker ? ', ui.Ticker("default", "clock", ' + ticker + ', true, "tick")' : ''}
    ${surface ? ', ui.Surface("default", 100, 100, "draw", "' + (animated ? 'tick' : '') + '", "pointer")' : ''}
    ${world ? ', ui.World("default", 100, "buildWorld", "worldEvent")' : ''}]);
}`
  try {
    const { vbc2 } = compileVeraSource(source)
    return { vbc2, stamp: veraStateStamp(vbc2) }
  } catch (error) {
    if (error.diagnostics) error.message += '\n' + JSON.stringify(error.diagnostics)
    throw error
  }
}
const programs = { basic: compile(), newer: compile({ initial: 10 }), bad: compile({ bad: true }),
  slow: compile({ ticker: 1000 }), fast: compile({ ticker: 100 }), surface: compile({ ticker: 1000, surface: true }),
  effect: compile({ effect: true }) }
const unpack = value => value[0] === 'o' ? Object.fromEntries(value[2].map(([key, item]) => [key, unpack(item)])) :
  value[0] === 'a' ? value[1].map(unpack) : value[0] === 'z' ? null : value[1]
const decode = encoded => unpack(JSON.parse(encoded))
const walk = node => node ? [node, ...node.children.flatMap(walk)] : []
const field = p => walk(p.liveRoot).find(node => node.kind === 'field')
const text = p => walk(p.liveRoot).find(node => node.kind === 'text').text
const number = value => ({ kind: 'NUMBER', num: value, str: '', bool: false, phase: '', id: 0, x: 0, y: 0 })
const microtasks = async () => { for (let i = 0; i < 30; i++) await Promise.resolve() }
async function pump() {
  for (let turns = 0; turns < 1000; turns++) {
    await microtasks()
    const ready = [...timers].find(([, timer]) => !timer.interval && timer.at <= now)
    if (!ready) return
    timers.delete(ready[0])
    ready[1].callback()
  }
  throw Error('scheduler did not quiesce')
}
async function finish(promise) {
  let done = false
  let result
  let failure
  Promise.resolve(promise).then(value => { done = true; result = value }, error => { done = true; failure = error })
  await pump()
  assert(done, 'operation stalled with no runnable host turn')
  if (failure) throw failure
  return result
}
function pause(host) {
  assert.equal(host.draining, false)
  host.draining = true
  return () => { host.draining = false; host.drain() }
}
function fixture(program = programs.basic, config = {}) {
  const h = config.host || new InProcessHost(() => now)
  if (!hosts.includes(h)) hosts.push(h)
  const p = new VeraPreview()
  previews.push(p)
  p.runtime = h
  p.vbc2 = program.vbc2
  p.previewOnly = config.previewOnly || false
  p.persistKey = config.persistKey || ''
  p.controller = new VeraPreviewController()
  p.getUIContext = () => ({ getMediaQuery: () => ({ matchMediaSync: () => ({ matches: false, on() {}, off() {} }) }), vp2px: x => x })
  const events = []
  const frames = []
  const snapshots = []
  const createSubscriber = p.createSubscriber
  p.createSubscriber = function(...args) {
    const subscriber = createSubscriber.apply(this, args)
    for (const name of ['onViewFrame', 'onError', 'onStateSnapshot', 'onStateSaved', 'onEffectRequest', 'onMailboxWritable']) {
      const callback = subscriber[name]
      subscriber[name] = (...values) => {
        events.push({ type: name, handle: p.handle, transitioning: p.transitioning, values })
        try { return callback.apply(subscriber, values) } catch (error) {
          callbackErrors.push(error)
          throw error
        }
      }
    }
    return subscriber
  }
  p.onStateSnapshot = encoded => snapshots.push(encoded)
  const accept = p.acceptFrame
  p.acceptFrame = function(frame) {
    frames.push(frame)
    events.push({ type: 'frame', handle: this.handle, transitioning: this.transitioning, frame })
    return accept.call(this, frame)
  }
  const calls = []
  for (const name of ['acquire', 'replaceProgram', 'promote', 'release', 'postInput', 'postTick', 'requestSnapshot', 'requestView']) {
    if (h[name].observed) continue
    const original = h[name]
    h[name] = function(...args) {
      const call = { name, args }
      calls.push(call)
      const result = original.apply(this, args)
      call.result = result
      return result
    }
    h[name].observed = true
  }
  return { p, h, events, frames, snapshots, calls, mount: async () => {
    p.aboutToAppear()
    await finish(p.operations)
    assert.equal(p.error, '')
    assert(p.handle)
    assert.equal(p.activeProgram, program.vbc2)
    assert.equal(p.flushFailure, null)
  }, state: async () => decode(await finish(h.requestSnapshot(p.handle))) }
}
function draft(p, value, composing = false) {
  const node = field(p)
  assert(node)
  p.changeField(node, node.fieldGeneration, value, composing)
  return node
}
function fill(h, p) {
  for (let i = 0; i < 240; i++) {
    const result = h.postInput(p.handle, p.inputEvent(p.captureFieldAction('add', number(0))))
    assert.equal(result.status, 'ACCEPTED')
  }
  const record = h.registry.get(p.handle.appId)
  assert.equal(record.noncriticalSlots, 240)
}
const scenarios = []
function test(name, action) { scenarios.push({ name, action }) }

test('current source extraction and preview/VM boundary', async () => {
  const imports = previewSource.match(/^import[\s\S]*?from ['"][^'"]+['"]/gm) || []
  assert(imports.length > 0)
  for (const item of imports) assert(!/\b(AppActor|RuntimeValue)\b|VeraInterpreter/.test(item), item)
  for (const name of ['configure', 'captureFields', 'acceptFrame', 'renderView', 'changeField', 'flushPendingInputFor', 'surfaceTouch']) {
    assert.equal(typeof new VeraPreview()[name], 'function', name + ' must come from the current class')
  }
})

test('acquire delivers frame, snapshot and effects before its promise settles', async () => {
  const f = fixture(programs.effect)
  f.p.aboutToAppear()
  await finish(f.p.operations)
  for (const type of ['onViewFrame', 'onStateSnapshot', 'onEffectRequest']) {
    assert(f.events.some(event => event.type === type && event.handle === null && event.transitioning), type + ' must precede acquire settlement')
  }
  assert(f.snapshots.length > 0)
  assert.equal(f.p.error, '')
  await pump()
  assert.deepEqual((await f.state()).order, ['answer'])
  assert.equal(adapterCalls.length, 1)
  assert.equal(f.p.handle.appId, f.p.frameAppId)
  assert.equal(f.p.handle.vmGeneration, f.p.frameVmGeneration)
})

test('rapid program changes and promotion serialize lifecycle operations', async () => {
  const f = fixture(programs.basic, { previewOnly: true })
  await f.mount()
  const original = f.h.replaceProgram
  let unblock
  let active = 0
  let maximum = 0
  f.h.replaceProgram = async function(...args) {
    active++
    maximum = Math.max(maximum, active)
    const result = await original.apply(this, args)
    await new Promise(resolve => { unblock = resolve })
    active--
    return result
  }
  f.p.vbc2 = programs.newer.vbc2
  f.p.onProgramChanged()
  await microtasks()
  assert(unblock)
  f.p.previewOnly = false
  f.p.onPreviewOnlyChanged()
  f.p.vbc2 = programs.basic.vbc2
  f.p.onProgramChanged()
  await microtasks()
  assert.equal(f.calls.filter(call => call.name === 'replaceProgram').length, 1)
  f.h.replaceProgram = original
  unblock()
  await finish(f.p.operations)
  assert.equal(maximum, 1)
  assert.equal(f.p.activeProgram, programs.basic.vbc2)
  assert.equal(f.p.activeOptions.mode, 'LIVE_EPHEMERAL')
  assert.equal(text(f.p), '0')
  f.p.persistKey = 'rapid/version'
  f.p.load()
  await finish(f.p.operations)
  assert(f.calls.some(call => call.name === 'promote'))
  assert.equal(f.p.handle.appId, 'rapid/version')
  assert.equal(f.p.frameAppId, 'rapid/version')
})

test('disappear during pending acquire releases the late real lease', async () => {
  const f = fixture()
  const acquire = f.h.acquire
  let unblock
  let acquired
  f.h.acquire = async function(...args) {
    acquired = await acquire.apply(this, args)
    await new Promise(resolve => { unblock = resolve })
    return acquired
  }
  f.p.aboutToAppear()
  await microtasks()
  assert(acquired)
  assert.equal(f.h.leases.size, 1)
  f.p.aboutToDisappear()
  unblock()
  await finish(f.p.operations)
  assert.equal(f.h.leases.size, 0)
  assert.equal(f.p.handle, null)
  assert.equal(f.p.draining, false)
  assert(f.calls.some(call => call.name === 'release' && call.args[0] === acquired))
})

test('failed replacement retains the old VM, identity and usable input', async () => {
  const f = fixture()
  await f.mount()
  f.p.handleAction('add', 7)
  await pump()
  const old = f.p.handle
  f.p.vbc2 = programs.bad.vbc2
  f.p.onProgramChanged()
  await finish(f.p.operations)
  assert.equal(f.p.handle, old)
  assert.equal(f.p.activeProgram, programs.basic.vbc2)
  assert.equal(f.p.flushFailure, null)
  assert.match(f.p.error, /ACTOR_NOT_READY/)
  f.p.handleAction('add', 2)
  await pump()
  assert.equal((await f.state()).n, 9)
  assert.equal(text(f.p), '9')
})

test('failed world replacement retains boxes, camera and runnable world events', async () => {
  const program = compile({ world: true })
  const f = fixture(program)
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  const camera = box.camera
  camera.yaw = 42
  const old = f.p.handle
  const resume = pause(f.h)
  f.p.vbc2 = programs.bad.vbc2
  f.p.onProgramChanged()
  await microtasks()
  assert.equal(f.p.pendingWorldProgram, programs.bad.vbc2)
  assert.equal(f.p.worlds.get(node), box)
  assert.equal(box.retired, false)
  resume()
  await finish(f.p.operations)
  assert.equal(f.p.handle, old)
  assert.equal(f.p.activeProgram, program.vbc2)
  assert.equal(f.p.worldProgram, program.vbc2)
  assert.equal(f.p.pendingWorldProgram, null)
  assert.equal(f.p.worlds.get(node), box)
  assert.equal(box.retired, false)
  assert.equal(box.camera, camera)
  assert.equal(camera.yaw, 42)
  assert.equal(f.p.flushFailure, null)
  assert.match(f.p.error, /ACTOR_NOT_READY/)
  assert.equal(f.p.worldErrorBlocks(), false)
  assert(f.p.surfaceTimer >= 0)
  const applies = box.applies
  box.events.push({ kind: 'settled', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 0, bodies: [], values: [], kick: 0 })
  f.p.surfaceFrame()
  await pump()
  assert.equal((await f.state()).n, 1)
  assert.equal(f.p.worlds.get(node), box)
  assert(box.applies > applies)
  assert.match(f.p.error, /ACTOR_NOT_READY/)
  f.p.surfaceFrame()
  await pump()
  assert(box.advances > 0)
  f.p.subscriber.onError('WORLD', 'World error: fixture trap')
  assert.equal(f.p.worldErrorBlocks(), true)
  assert.equal(f.p.worldTransitionError, '')
  assert.equal(f.p.surfaceTimer, -1)
})

test('committed world replacement retires old boxes before applying its first frame', async () => {
  const program = compile({ world: true })
  const candidate = compile({ world: true, initial: 10 })
  const f = fixture(program)
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  box.camera.yaw = 42
  const replace = f.h.replaceProgram
  let unblock
  f.h.replaceProgram = async function(...args) {
    const next = await replace.apply(this, args)
    await new Promise(resolve => { unblock = resolve })
    return next
  }
  const render = f.p.renderView
  let committedFrame = false
  f.p.renderView = function(...args) {
    assert.equal(box.retired, true)
    assert.equal(this.worldProgram, candidate.vbc2)
    committedFrame = true
    return render.apply(this, args)
  }
  const resume = pause(f.h)
  f.p.vbc2 = candidate.vbc2
  f.p.onProgramChanged()
  await microtasks()
  assert.equal(box.retired, false)
  f.p.vbc2 = programs.bad.vbc2
  resume()
  await microtasks()
  assert(unblock)
  assert(committedFrame)
  assert.equal(f.p.transitioning, true)
  assert.equal(f.p.pendingWorldProgram, null)
  const nextNode = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const nextBox = f.p.worlds.get(nextNode)
  assert(nextBox)
  assert.notEqual(nextBox, box)
  assert.equal(nextBox.camera.yaw, 0)
  unblock()
  await finish(f.p.operations)
  assert.equal(f.p.worlds.get(nextNode), nextBox)
  assert.equal(nextBox.retired, false)
  assert.equal(text(f.p), '10')
})

test('same-program promotion retains world boxes and camera state', async () => {
  const program = compile({ world: true })
  const f = fixture(program)
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  box.camera.yaw = 42
  f.p.persistKey = 'world-promote/version'
  f.p.load()
  await finish(f.p.operations)
  assert.equal(f.p.worlds.get(node), box)
  assert.equal(box.retired, false)
  assert.equal(box.camera.yaw, 42)
  assert.equal(f.p.worldProgram, program.vbc2)
  assert.equal(f.p.pendingWorldProgram, null)
})

test('world steps collect, dispatch and apply before advancing after mailbox backpressure', async () => {
  const f = fixture(compile({ world: true }))
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  const order = []
  for (const [name, label] of [['frame', 'collect'], ['apply', 'apply'], ['advance', 'advance']]) {
    const original = box[name]
    box[name] = function(...args) {
      order.push(label)
      if (name === 'apply') assert.equal(args[0].bodies[0].position[0], 1)
      if (name === 'advance') assert.equal(this.spec.bodies[0].position[0], 1)
      return original.apply(this, args)
    }
  }
  const actor = f.h.registry.get(f.p.handle.appId).actor
  const dispatch = actor.dispatch
  actor.dispatch = function(action, ...args) {
    if (action === 'worldEvent') order.push('handler')
    return dispatch.call(this, action, ...args)
  }
  const resume = pause(f.h)
  try {
    fill(f.h, f.p)
    box.events.push({ kind: 'hit', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 1, bodies: [], values: [], kick: 0 })
    timers.get(f.p.surfaceTimer).callback()
    assert.equal(f.p.pendingWorldStep, true)
    assert.equal(f.p.admissionBlocked, true)
    assert.equal(f.p.fieldActions.length, 1)
    assert(f.calls.some(call => call.name === 'postInput' && call.args[1].kind === 'SCENE' && call.result.status === 'BACKPRESSURE'))
    for (let i = 0; i < 3; i++) timers.get(f.p.surfaceTimer).callback()
    assert.deepEqual(order, ['collect'])
    assert.equal(box.frames, 1)
    assert.equal(box.advances, 0)
    f.p.destinationHidden = true
    f.p.onDestinationHidden()
    assert.equal(f.p.surfaceTimer, -1)
  } finally {
    resume()
  }
  await pump()
  assert(f.events.some(event => event.type === 'onMailboxWritable'))
  assert.deepEqual(order, ['collect', 'handler', 'apply'])
  assert.equal(f.p.inFlight, null)
  assert.equal(f.p.admissionBlocked, false)
  assert.equal(f.p.posts.length, 0)
  assert.equal(f.p.postDrain, false)
  assert.equal(f.p.pendingWorldStep, true)
  box.needsFrames = () => false
  f.p.destinationHidden = false
  f.p.onDestinationHidden()
  assert(f.p.surfaceTimer >= 0, 'a pending world step must restart the display loop even when all bodies sleep')
  timers.get(f.p.surfaceTimer).callback()
  await pump()
  assert.deepEqual(order, ['collect', 'handler', 'apply', 'advance'])
  assert.equal(box.frames, 1)
  assert.equal(box.advances, 1)
  assert.equal(f.p.pendingWorldStep, false)
  assert.equal(f.p.surfaceTimer, -1)
  assert.equal((await f.state()).n, 1)
})

test('unchanged world handlers wait for the real snapshot barrier without requiring a view frame', async () => {
  const f = fixture(compile({ world: true, worldUnchanged: true }))
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  const before = f.frames.length
  const snapshot = f.h.requestSnapshot
  let unblock
  f.h.requestSnapshot = function(...args) {
    const barrier = snapshot.apply(this, args)
    if (f.p.inFlight?.nodeKind !== 'world') return barrier
    return barrier.then(value => new Promise(resolve => { unblock = () => resolve(value) }))
  }
  box.events.push({ kind: 'hit', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 1, bodies: [], values: [], kick: 0 })
  try {
    f.p.surfaceFrame()
    await microtasks()
    assert(unblock)
    assert.equal(f.frames.length, before)
    assert.equal(f.p.inFlight.nodeKind, 'world')
    assert.equal(f.p.inFlight.inputSeq > 0, true)
    const input = f.calls.find(call => call.name === 'postInput' && call.args[1].kind === 'SCENE')
    assert.equal(input.args[1].skipIfSame, true)
    assert.equal(input.result.status, 'ACCEPTED')
    for (let i = 0; i < 3; i++) f.p.surfaceFrame()
    assert.equal(box.frames, 1)
    assert.equal(box.advances, 0)
  } finally {
    if (unblock) unblock()
    f.h.requestSnapshot = snapshot
  }
  await pump()
  assert.equal(f.p.inFlight, null)
  assert.equal(f.p.pendingWorldStep, true)
  f.p.surfaceFrame()
  await pump()
  assert.equal(box.frames, 1)
  assert.equal(box.advances, 1)
  assert.equal(f.p.pendingWorldStep, false)
  assert.equal(f.frames.length, before)
  assert.equal((await f.state()).n, 0)
})

test('release saves dirty world state after the last world leaves the live tree', async () => {
  const f = fixture(compile({ world: true, hideWorldAfterEvent: true }), { persistKey: 'world-release/version' })
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  const actor = f.h.registry.get(f.p.handle.appId).actor
  const saved = f.events.filter(event => event.type === 'onStateSaved').length
  box.events.push({ kind: 'hit', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 1, bodies: [], values: [], kick: 0 })
  f.p.tickWorlds(now, 16)
  await pump()
  assert.equal(actor.worldDirty(), true)
  assert.equal(box.retired, true)
  assert.equal(f.p.worlds.size, 0)
  assert.equal(f.p.liveSurfaces.length, 0)
  assert.equal(walk(f.p.liveRoot).some(node => node.kind === 'world'), false)
  assert.equal(f.p.hadWorlds, true)
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, saved)
  f.p.aboutToDisappear()
  await finish(f.p.operations)
  const releases = f.calls.filter(call => call.name === 'release')
  assert.equal(releases.length, 1)
  assert.equal(releases[0].args[1].saveState, true)
  const file = [...disk.keys()].find(file => file.endsWith('/world-release/version.state.json'))
  assert(file)
  assert.equal(unpack(JSON.parse(disk.get(file)).value).n, 1)
  assert.equal(actor.worldDirty(), false)
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, saved + 1)
})

for (const reason of ['node-gone', 'handler-changed', 'node-generation', 'program-generation', 'field-edited']) test('queued world events reject stale ' + reason, async () => {
  const f = fixture(compile({ world: true }))
  await f.mount()
  const node = walk(f.p.liveRoot).find(node => node.kind === 'world')
  const box = f.p.worlds.get(node)
  box.events.push({ kind: 'settled', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 0, bodies: [], values: [], kick: 0 })
  f.p.renderingDepth++
  try {
    f.p.tickWorlds(now, 16)
    assert.equal(f.p.fieldActions.length, 1)
    const next = f.p.fieldActions[0]
    if (reason === 'node-gone') {
      f.p.liveRoot.children = f.p.liveRoot.children.filter(child => child !== node)
      f.p.liveGeneration++
      f.p.markLiveNodeGeneration(f.p.liveRoot)
      f.p.reconcileWorlds()
    } else if (reason === 'handler-changed') node.action = 'obsoleteWorldEvent'
    else if (reason === 'node-generation') node.fieldGeneration++
    else if (reason === 'program-generation') next.generation--
    else {
      assert(next.dependencies.length > 0)
      next.dependencies[0].fieldCancellation++
    }
    assert.equal(f.p.fieldActionCurrent(next), false)
    assert.equal(f.p.fieldActionStaleReason(next), reason)
  } finally {
    f.p.renderingDepth--
  }
  f.p.resumeFieldActions()
  await pump()
  assert.equal(f.p.fieldActions.length, 0)
  assert.equal(f.p.inFlight, null)
  assert.equal(f.calls.some(call => call.name === 'postInput' && call.args[1].kind === 'SCENE'), false)
  assert(logs.some(entry => entry.some(value => String(value).includes('event dropped kind=settled reason=' + reason))))
  assert.equal((await f.state()).n, 0)
  f.p.tickWorlds(now, 16)
  assert.equal(f.p.pendingWorldStep, false)
  assert.equal(box.frames, 1)
})

test('disappearance remaps an admitted world action and its dependencies to the cloned drain tree', async () => {
  const f = fixture(compile({ world: true }), { persistKey: 'world-clone/version' })
  await f.mount()
  const root = f.p.liveRoot
  const node = walk(root).find(node => node.kind === 'world')
  const originalField = field(f.p)
  const box = f.p.worlds.get(node)
  const resume = pause(f.h)
  try {
    box.events.push({ kind: 'hit', body: 'body', other: '', x: 0, y: 0, z: 0, speed: 1, bodies: [], values: [], kick: 0 })
    f.p.tickWorlds(now, 16)
    const next = f.p.inFlight
    assert(next)
    assert.equal(next.node, node)
    assert(next.dependencies.includes(originalField))
    f.p.aboutToDisappear()
    const cloned = walk(f.p.liveRoot).find(node => node.kind === 'world')
    assert(cloned)
    assert.notEqual(f.p.liveRoot, root)
    assert.notEqual(cloned, node)
    assert.equal(f.p.inFlight, next)
    assert.equal(next.node, cloned)
    assert.equal(next.nodeGeneration, cloned.fieldGeneration)
    assert(next.dependencies.includes(field(f.p)))
    assert.equal(next.dependencies.includes(originalField), false)
    assert.equal(box.retired, true)
    assert.equal(f.p.worlds.size, 0)
  } finally {
    resume()
  }
  await finish(f.p.operations)
  assert.equal(f.p.handle, null)
  assert.equal(f.p.liveRoot, null)
  assert.equal(f.p.inFlight, null)
  assert.equal(walk(root).find(node => node.kind === 'text').text, '0')
  const file = [...disk.keys()].find(file => file.endsWith('/world-clone/version.state.json'))
  assert(file)
  assert.equal(unpack(JSON.parse(disk.get(file)).value).n, 1)
  assert.equal(f.calls.filter(call => call.name === 'postInput' && call.args[1].kind === 'SCENE').length, 1)
  assert.equal(f.calls.find(call => call.name === 'release').args[1].saveState, true)
})

test('APP_ID_CONFLICT release/reacquire failure rolls back to the old runtime', async () => {
  const f = fixture()
  await f.mount()
  f.p.handleAction('add', 7)
  await pump()
  const old = f.p.handle
  const other = fixture(programs.newer, { host: f.h, persistKey: 'occupied/version' })
  await other.mount()
  f.p.persistKey = 'occupied/version'
  f.p.load()
  await finish(f.p.operations)
  assert(f.calls.some(call => call.name === 'release' && call.args[0] === old))
  assert(f.p.handle)
  assert.notEqual(f.p.handle, old)
  assert.equal(f.p.handle.appId, old.appId)
  assert.equal(f.p.activeOptions.mode, 'LIVE_EPHEMERAL')
  assert.equal(f.p.flushFailure, null)
  assert.match(f.p.error, /APP_ID_CONFLICT/)
  assert.equal((await f.state()).n, 7)
  assert.equal((await other.state()).n, 10)
  assert.equal(f.h.leases.size, 2)
})

test('snapshot flush waits asynchronously through actual mailbox backpressure', async () => {
  const f = fixture()
  await f.mount()
  const resume = pause(f.h)
  fill(f.h, f.p)
  const node = draft(f.p, 'snapshot draft')
  let done = false
  const before = f.calls.filter(call => call.name === 'requestSnapshot').length
  const captured = f.p.controller.flushAndSnapshot().then(value => { done = true; return value })
  await microtasks()
  assert.equal(done, false)
  assert.equal(f.p.admissionBlocked, true)
  assert.equal(f.p.fieldEdits.get(node).value, 'snapshot draft')
  assert.equal(f.calls.filter(call => call.name === 'requestSnapshot').length, before)
  assert(f.calls.some(call => call.name === 'postInput' && call.result.status === 'BACKPRESSURE'))
  resume()
  const state = decode(await finish(captured))
  assert.equal(state.text, 'snapshot draft')
  assert.equal(state.order.at(-1), 'field')
  assert.equal(field(f.p).value, 'snapshot draft')
  assert.equal(f.p.inFlight, null)
})

test('view trap preserves active UI timers, saved state and field-action completion', async () => {
  const f = fixture(compile({ ticker: 1000, surface: true, animated: true, viewTrapAfter: true }), { persistKey: 'view-trap/version' })
  await f.mount()
  const ticker = f.p.timers.get('clock')
  const surface = f.p.surfaceTimer
  const root = f.p.liveRoot
  const frames = f.frames.length
  const saved = () => f.events.filter(event => event.type === 'onStateSaved').length
  const before = saved()
  f.p.handleAction('add', 1)
  assert(f.events.some(event => event.type === 'onError' && event.values[0] === 'view' && typeof event.values[2] === 'number'))
  assert.equal(f.p.liveRoot, root)
  assert.equal(f.frames.length, frames)
  assert.equal(f.p.timers.get('clock'), ticker)
  assert.equal(f.p.surfaceTimer, surface)
  assert(timers.has(ticker))
  assert(timers.has(surface))
  assert.equal(f.p.inFlight, null)
  assert.equal(saved(), before + 1)
  f.p.handleAction('add', 2)
  assert.equal((await f.state()).n, 3)
  assert.deepEqual((await f.state()).order, ['add', 'add'])
  assert.equal(f.p.inFlight, null)
  assert.equal(f.p.fieldActions.length, 0)
  assert.equal(saved(), before + 2)
  assert.equal(f.p.flushFailure, null)
  assert.equal(decode(await finish(f.p.controller.flushAndSnapshot())).n, 3)
  await finish(f.p.operations)
  f.p.destinationHidden = true
  f.p.onDestinationHidden()
  f.p.destinationHidden = false
  f.p.onDestinationHidden()
  assert(f.p.surfaceTimer >= 0, 'VIEW error must not prevent restart')
  const restarted = f.p.surfaceTimer
  f.p.handleAction('add', -3)
  assert.equal(f.p.error, '')
  assert.equal(text(f.p), '0')
  assert.equal(f.p.surfaceTimer, restarted, 'successful VIEW must not stop/restart the running loop')
  assert(timers.has(restarted))
  f.p.subscriber.onError('draw', 'fixture draw trap')
  assert.equal(f.p.timers.size, 0)
  assert.equal(f.p.surfaceTimer, -1)
  assert(!timers.has(ticker))
  assert(!timers.has(surface))
})

test('refresh VIEW trap before acquire settlement preserves effects, capture and later recovery', async () => {
  const f = fixture(compile({ refreshTrap: true, viewTrapAfter: true, effect: true, surface: true, animated: true }))
  f.p.aboutToAppear()
  await finish(f.p.operations)
  await pump()
  assert(f.p.handle)
  assert(f.events.some(event => event.type === 'onError' && event.values[0] === 'view' && event.handle === null))
  assert.equal(adapterCalls.length, 1)
  assert.deepEqual((await f.state()).order, ['answer'])
  assert.equal(f.p.flushFailure, null)
  assert.equal(decode(await finish(f.p.controller.flushAndSnapshot())).n, 1)
  assert.equal(text(f.p), '0')
  const surface = f.p.surfaceTimer
  assert(timers.has(surface))
  f.p.handleAction('add', -1)
  assert.equal(f.p.error, '')
  assert.equal(f.p.surfaceTimer, surface)
  assert.equal(decode(await finish(f.p.controller.flushAndSnapshot())).n, 0)
})

test('retained admissions retry FIFO and finish only after frame reconciliation', async () => {
  const f = fixture()
  await f.mount()
  const resume = pause(f.h)
  fill(f.h, f.p)
  f.p.handleAction('add', 1)
  f.p.handleAction('add', 2)
  assert.deepEqual(f.p.fieldActions.map(action => action.payload.num), [1, 2])
  assert.equal(f.p.inFlight, null)
  let reconciled = 0
  const render = f.p.renderView
  f.p.renderView = function(...args) {
    const action = this.inFlight
    if (action && this.lastAppliedSeq >= action.inputSeq && action.inputSeq >= 0) {
      assert.equal(this.inFlight, action)
      render.apply(this, args)
      assert.equal(this.inFlight, action, 'reconciliation must precede completion')
      reconciled++
    } else render.apply(this, args)
  }
  resume()
  await pump()
  const state = await f.state()
  assert.equal(state.n, 3)
  assert.equal(reconciled, 2)
  assert.equal(text(f.p), '3')
  assert.equal(f.p.inFlight, null)
  assert.equal(f.p.fieldActions.length, 0)
  const accepted = f.calls.filter(call => call.name === 'postInput' && call.result.status === 'ACCEPTED').map(call => call.args[1].payload.num)
  assert.deepEqual(accepted.slice(-2), [1, 2])
})

test('synchronous host frame is deferred until admission returns and reconciles first', async () => {
  const f = fixture()
  await f.mount()
  const accept = f.p.acceptFrame
  let synchronous = false
  f.p.acceptFrame = function(frame) {
    if (this.inFlight?.posting) {
      synchronous = true
      const before = this.revision
      accept.call(this, frame)
      assert.equal(this.revision, before)
      assert(this.deferredFrames.includes(frame))
    } else accept.call(this, frame)
  }
  f.p.handleAction('add', 4)
  assert(synchronous)
  assert.equal(f.p.inFlight, null)
  assert.equal(f.p.deferredFrames.length, 0)
  assert.equal(text(f.p), '4')
  assert.equal((await f.state()).n, 4)
})

for (const fail of [false, true]) test('teardown flushes final composition and releases lease' + (fail ? ' despite save failure' : ''), async () => {
  const f = fixture(programs.surface, { persistKey: 'teardown/version' })
  await f.mount()
  const node = draft(f.p, 'composing', true)
  const controller = f.p.fieldController(node, node.fieldGeneration)
  controller.text = '你好'
  const visibleRoot = f.p.liveRoot
  saveFailure = fail
  f.p.aboutToDisappear()
  await finish(f.p.operations)
  saveFailure = false
  assert.equal(f.p.handle, null)
  assert.equal(f.p.draining, false)
  assert.equal(f.h.leases.size, 0)
  assert.equal(f.p.liveRoot, null)
  assert.equal(f.p.fieldEdits.size, 0)
  assert.equal(f.p.timers.size, 0)
  const edit = f.calls.find(call => call.name === 'postInput' && call.args[1].kind === 'FIELD')
  assert.equal(edit.args[1].payload.str, '你好')
  const release = f.calls.find(call => call.name === 'release')
  assert.equal(release.args[1].saveState, true)
  assert(f.calls.indexOf(edit) < f.calls.indexOf(release))
  assert.equal(walk(visibleRoot).find(item => item.kind === 'field').value, 'initial')
  const record = [...f.h.registry.values()][0]
  assert.equal(decode(record.actor.snapshot()).text, '你好')
  if (!fail) {
    const file = [...disk.keys()].find(file => file.endsWith('/teardown/version.state.json'))
    assert(file)
    assert.equal(unpack(JSON.parse(disk.get(file)).value).text, '你好')
  } else assert(logs.some(entry => entry.some(value => String(value).includes('release failed: fixture save failed'))))
})

for (const surface of [false, true]) test('snapshot waiting on composition drains independently on disappear' + (surface ? ' with surface release save' : ''), async () => {
  const f = fixture(surface ? programs.surface : programs.basic, { persistKey: 'capture-teardown/version' })
  await f.mount()
  const handle = f.p.handle
  const record = f.h.registry.get(handle.appId)
  const stale = f.p.subscriber
  const node = draft(f.p, 'unfinished composition', true)
  const generation = node.fieldGeneration
  const controller = f.p.fieldController(node, generation)
  let nativeReads = 0
  controller.getText = () => { nativeReads++; return controller.text }
  controller.text = '最终文本'
  const visibleRoot = f.p.liveRoot
  const staleTimer = surface ? timers.get(f.p.timers.get('clock')).callback : null
  let unblock
  f.p.operations = f.p.operations.then(() => new Promise(resolve => { unblock = resolve }))
  const before = f.calls.length
  let captureSettled = false
  const captured = f.p.controller.flushAndSnapshot()
  captured.then(() => { captureSettled = true }, () => { captureSettled = true })
  const captureOperations = f.p.operations
  let operationsSettled = false
  captureOperations.then(() => { operationsSettled = true })
  await microtasks()
  assert(unblock)
  assert.equal(f.p.waiters.length, 0, 'capture must wait for the existing operations chain')
  assert.equal(f.p.fieldEdits.get(node).commitRequested, false)
  assert.equal(captureSettled, false)
  unblock()
  await microtasks()
  assert.equal(f.p.waiters.length, 1, 'capture must be waiting for composition, not merely queued')
  assert.equal(f.p.fieldEdits.get(node).composing, true)
  assert.equal(f.p.fieldEdits.get(node).commitRequested, true)
  assert.equal(nativeReads, 0)
  assert.equal(captureSettled, false)
  assert.equal(operationsSettled, false)
  assert.equal(f.calls.length, before)
  f.p.aboutToDisappear()
  assert.equal(nativeReads, 1, 'disappearance must read native text synchronously')
  assert.equal(captureSettled, false)
  assert.equal(operationsSettled, false, 'final field admission must not wait behind the capture')
  const edits = f.calls.slice(before).filter(call => call.name === 'postInput' && call.args[1].kind === 'FIELD')
  assert.equal(edits.length, 1)
  assert.equal(edits[0].args[1].payload.str, '最终文本')
  assert.equal(edits[0].result.status, 'ACCEPTED')
  assert.equal(f.calls.slice(before).some(call => call.name === 'release'), false)
  assert.notEqual(f.p.liveRoot, visibleRoot)
  await finish(assert.rejects(captured, /Preview was released/))
  await finish(f.p.operations)
  assert.equal(operationsSettled, true)
  assert.equal(f.p.handle, null)
  assert.equal(f.p.draining, false)
  assert.equal(f.p.liveRoot, null)
  assert.equal(f.p.waiters.length, 0)
  assert.equal(f.p.fieldEdits.size, 0)
  assert.equal(f.p.inFlight, null)
  assert.equal(f.h.leases.size, 0)
  const releases = f.calls.slice(before).filter(call => call.name === 'release')
  assert.equal(releases.length, 1)
  assert.equal(releases[0].args[0], handle)
  assert.equal(releases[0].args[1].saveState, surface)
  assert(f.calls.indexOf(edits[0]) < f.calls.indexOf(releases[0]))
  assert.equal(f.calls.slice(before).some(call => call.name === 'requestSnapshot'), false)
  const state = decode(record.actor.snapshot())
  assert.equal(state.text, '最终文本')
  assert.deepEqual(state.order, ['field'])
  const file = [...disk.keys()].find(file => file.endsWith('/capture-teardown/version.state.json'))
  assert(file)
  assert.deepEqual(unpack(JSON.parse(disk.get(file)).value), state)
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, surface ? 2 : 1)
  assert.equal(walk(visibleRoot).find(item => item.kind === 'field').value, 'initial')
  const after = { calls: f.calls.length, revision: f.p.revision, snapshots: f.snapshots.length, error: f.p.error }
  f.p.admissionBlocked = true
  stale.onMailboxWritable()
  stale.onViewFrame({ ...f.frames.at(-1), frameSeq: 900, appliedSeq: 800 })
  stale.onStateSnapshot('stale')
  stale.onStateSaved('stale')
  stale.onError('handler', 'stale error', 800)
  stale.onEffectRequest({})
  f.p.changeField(node, generation, 'late composition', false)
  f.p.finishField(node, generation, 'late native text')
  if (staleTimer) staleTimer()
  await finish(assert.rejects(stale.flushPendingInputFor(handle.appId), /activation changed/))
  await finish(assert.rejects(f.p.controller.flushAndSnapshot(), /not attached/))
  await pump()
  assert.equal(f.p.admissionBlocked, true, 'stale callbacks must not resume admission')
  assert.equal(nativeReads, 1)
  assert.equal(f.p.fieldEdits.size, 0)
  assert.equal(f.p.fieldActions.length, 0)
  assert.equal(f.p.posts.length, 0)
  assert.deepEqual({ calls: f.calls.length, revision: f.p.revision, snapshots: f.snapshots.length, error: f.p.error }, after)
  assert.deepEqual(decode(record.actor.snapshot()), state)
  assert.deepEqual(unpack(JSON.parse(disk.get(file)).value), state)
  assert.equal(f.events.filter(event => event.type === 'onStateSaved' && event.values[0] !== 'stale').length, surface ? 2 : 1)
})

test('load cancels a snapshot waiting on composition and releases the operations chain', async () => {
  const f = fixture()
  await f.mount()
  const handle = f.p.handle
  const node = draft(f.p, 'cancelled composition', true)
  const generation = node.fieldGeneration
  const controller = f.p.fieldController(node, generation)
  let nativeReads = 0
  controller.getText = () => { nativeReads++; return 'must not be captured' }
  const before = f.calls.length
  let captureSettled = false
  const captured = f.p.controller.flushAndSnapshot()
  captured.then(() => { captureSettled = true }, () => { captureSettled = true })
  const captureOperations = f.p.operations
  let operationsSettled = false
  captureOperations.then(() => { operationsSettled = true })
  await microtasks()
  assert.equal(f.p.waiters.length, 1)
  assert.equal(f.p.fieldEdits.get(node).composing, true)
  assert.equal(f.p.fieldEdits.get(node).commitRequested, true)
  assert.equal(captureSettled, false)
  assert.equal(operationsSettled, false)
  assert.equal(f.calls.length, before)
  f.p.vbc2 = programs.newer.vbc2
  f.p.onProgramChanged()
  assert.equal(f.p.waiters.length, 0, 'load must synchronously reject the capture flush waiter')
  assert.equal(f.p.fieldEdits.size, 0)
  assert.equal(f.p.fieldInputs.size, 0)
  assert.equal(f.calls.length, before, 'replacement remains serialized behind capture settlement')
  await finish(assert.rejects(captured, /Preview activation changed/))
  await finish(f.p.operations)
  assert.equal(operationsSettled, true)
  assert.notEqual(f.p.handle, handle)
  assert.equal(f.p.activeProgram, programs.newer.vbc2)
  assert.equal(f.p.transitioning, false)
  assert.equal(f.p.flushFailure, null)
  assert.equal(f.p.error, '')
  assert.equal(f.h.leases.size, 1)
  assert.equal(f.calls.slice(before).filter(call => call.name === 'replaceProgram').length, 1)
  assert.equal(f.calls.slice(before).some(call => call.name === 'postInput'), false)
  assert.equal(f.calls.slice(before).some(call => call.name === 'requestSnapshot'), false)
  f.p.changeField(node, generation, 'stale edit', false)
  f.p.finishField(node, generation, 'stale final text')
  f.p.endFieldEditing(node, generation)
  await pump()
  assert.equal(nativeReads, 0)
  assert.equal(f.p.fieldEdits.size, 0)
  assert.equal(f.calls.slice(before).some(call => call.name === 'postInput'), false)
  assert.equal(field(f.p).value, 'initial')
  assert.equal(text(f.p), '10')
  draft(f.p, 'new activation edit')
  const state = decode(await finish(f.p.controller.flushAndSnapshot()))
  await finish(f.p.operations)
  assert.equal(state.n, 10)
  assert.equal(state.text, 'new activation edit')
  assert.deepEqual(state.order, ['field'])
  assert.equal(f.p.waiters.length, 0)
  assert.equal(f.p.inFlight, null)
})

test('superseded subscriber suppresses all stale callbacks', async () => {
  const f = fixture()
  await f.mount()
  const stale = f.p.subscriber
  f.p.subscriber = f.p.createSubscriber(f.p.acquireGeneration)
  const before = { error: f.p.error, revision: f.p.revision, snapshots: f.snapshots.length, applied: f.p.lastAppliedSeq }
  const frame = { ...f.frames.at(-1), frameSeq: 900, appliedSeq: 800 }
  stale.onViewFrame(frame)
  stale.onStateSnapshot('stale')
  stale.onStateSaved('stale')
  stale.onError('handler', 'stale error', 800)
  stale.onEffectRequest({})
  f.p.admissionBlocked = true
  stale.onMailboxWritable()
  await assert.rejects(stale.flushPendingInputFor(f.p.frameAppId), /activation changed/)
  assert.equal(f.p.admissionBlocked, true)
  f.p.admissionBlocked = false
  assert.deepEqual({ error: f.p.error, revision: f.p.revision, snapshots: f.snapshots.length, applied: f.p.lastAppliedSeq }, before)
  assert(!f.p.observedErrors.has(800))
})

test('frame generation/sequence identity and opaque handles survive replacement', async () => {
  const f = fixture()
  await f.mount()
  const old = f.p.handle
  const oldFrame = f.frames.at(-1)
  await assert.rejects(f.h.requestSnapshot({ ...old }), /INVALID_HANDLE/)
  f.p.vbc2 = programs.newer.vbc2
  f.p.onProgramChanged()
  await finish(f.p.operations)
  assert.notEqual(f.p.handle, old)
  assert.equal(f.p.frameVmGeneration, f.p.handle.vmGeneration)
  assert(f.p.frameVmGeneration > old.vmGeneration)
  const revision = f.p.revision
  const currentFrame = f.frames.at(-1)
  f.p.acceptFrame({ ...oldFrame, frameSeq: 10000 })
  f.p.acceptFrame(currentFrame)
  assert.equal(f.p.revision, revision)
  assert.equal(text(f.p), '10')
  await assert.rejects(f.h.requestSnapshot(old), /INVALID_HANDLE/)
  assert.equal((await f.state()).n, 10)
})

for (const slow of [true, false]) test((slow ? 'slow' : 'fast') + ' ticker ' + (slow ? 'flushes pending fields before VM input' : 'preserves pending field debounce'), async () => {
  const f = fixture(slow ? programs.slow : programs.fast)
  await f.mount()
  const timerId = f.p.timers.get('clock')
  const node = draft(f.p, 'ticker draft')
  const debounce = f.p.fieldEdits.get(node).timer
  const last = f.p.timerLastFire.get('clock')
  now += slow ? 1000 : 100
  timers.get(timerId).callback()
  await microtasks()
  if (slow) {
    assert.deepEqual((await f.state()).order, ['field', 'tick'])
    assert.deepEqual((await f.state()).seen, ['ticker draft'])
    assert.equal(f.p.fieldEdits.size, 0)
  } else {
    assert.equal(f.p.fieldEdits.get(node).timer, debounce)
    assert(timers.has(debounce))
    assert.equal(f.p.timerLastFire.get('clock'), last)
    assert.deepEqual((await f.state()).order, [])
    now += 300
    await pump()
    assert.deepEqual((await f.state()).order, ['field'])
  }
  assert.equal(f.p.timers.get('clock'), timerId)
})

test('animated surface start and destination restart reset the real actor save deadline', async () => {
  const started = now
  const f = fixture(compile({ surface: true, animated: true }), { persistKey: 'surface-clock/version' })
  await f.mount()
  assert.equal(f.p.surfaceLoopStartedAt, started)
  assert(f.p.surfaceTimer >= 0)
  const saves = () => f.events.filter(event => event.type === 'onStateSaved').length
  const before = saves()
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.p.surfaceLoopStartedAt, undefined)
  assert.equal(saves(), before)
  now = started + 4999
  f.p.surfaceFrame()
  await pump()
  assert.equal(saves(), before)
  now++
  f.p.surfaceFrame()
  await pump()
  assert.equal(saves(), before + 1)
  f.p.destinationHidden = true
  f.p.onDestinationHidden()
  assert.equal(f.p.surfaceTimer, -1)
  now += 9000
  f.p.destinationHidden = false
  f.p.onDestinationHidden()
  const restarted = now
  assert.equal(f.p.lastFrameAt, 0)
  assert.equal(f.p.surfaceLoopStartedAt, restarted)
  now += 2300
  f.p.surfaceFrame()
  await pump()
  assert.equal(saves(), before + 1)
  now = restarted + 4999
  f.p.surfaceFrame()
  await pump()
  assert.equal(saves(), before + 1)
  now++
  f.p.surfaceFrame()
  await pump()
  assert.equal(saves(), before + 2)
})

test('composition delays first surface frame without postponing the loop-start deadline', async () => {
  const started = now
  const f = fixture(compile({ surface: true, animated: true }), { persistKey: 'surface-composition/version' })
  await f.mount()
  const node = draft(f.p, 'composing', true)
  now += 6000
  f.p.surfaceFrame()
  assert.equal(f.p.surfaceLoopStartedAt, started)
  f.p.changeField(node, node.fieldGeneration, 'committed', false)
  await finish(f.p.controller.flushAndSnapshot())
  await finish(f.p.operations)
  const before = f.events.filter(event => event.type === 'onStateSaved').length
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, before + 1)
  assert.equal(f.p.surfaceLoopStartedAt, undefined)
})

for (const restart of [false, true]) test('backpressured preview coalescing preserves ' + (restart ? 'newest restart' : 'initial start') + ' marker', async () => {
  const f = fixture(compile({ surface: true, animated: true }), { persistKey: 'surface-pressure/version' })
  await f.mount()
  let started = now
  const resume = pause(f.h)
  fill(f.h, f.p)
  f.p.surfaceFrame()
  assert.equal(f.p.admissionBlocked, true)
  assert.equal(f.p.posts.length, 1)
  assert.equal(f.p.posts[0].surface.loopStartedAt, started)
  assert.equal(f.p.surfaceLoopStartedAt, undefined)
  now += 1000
  if (restart) {
    f.p.destinationHidden = true
    f.p.onDestinationHidden()
    f.p.destinationHidden = false
    f.p.onDestinationHidden()
    started = now
  }
  f.p.surfaceFrame()
  now += 1000
  f.p.surfaceFrame()
  assert.equal(f.p.posts.length, 1)
  assert.equal(f.p.posts[0].surface.loopStartedAt, started)
  resume()
  await pump()
  assert.equal(f.p.posts.length, 0)
  const before = f.events.filter(event => event.type === 'onStateSaved').length
  now = started + 4999
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, before)
  now++
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, before + 1)
})

test('replacement drops pending loop markers and starts a fresh deadline', async () => {
  const f = fixture(compile({ surface: true, animated: true }), { persistKey: 'surface-replace/version' })
  await f.mount()
  const old = f.p.surfaceLoopStartedAt
  now += 2000
  f.p.vbc2 = compile({ initial: 10, surface: true, animated: true }).vbc2
  f.p.onProgramChanged()
  await finish(f.p.operations)
  const started = now
  assert.notEqual(started, old)
  assert.equal(f.p.surfaceLoopStartedAt, started)
  const before = f.events.filter(event => event.type === 'onStateSaved').length
  now = old + 5000
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, before)
  now = started + 5000
  f.p.surfaceFrame()
  await pump()
  assert.equal(f.events.filter(event => event.type === 'onStateSaved').length, before + 1)
  f.p.aboutToDisappear()
  await finish(f.p.operations)
  assert.equal(f.p.surfaceLoopStartedAt, undefined)
})

test('surface down and move flush fields without stopping ticker timers', async () => {
  const f = fixture(programs.surface)
  await f.mount()
  const node = walk(f.p.liveRoot).find(item => item.kind === 'surface')
  f.p.surfaces.set(node, { width: 100, height: 100, ready: false, visible: true, touchedAt: 0 })
  const ticker = f.p.timers.get('clock')
  const touch = type => f.p.surfaceTouch(node, { type, changedTouches: [{ id: 1, x: 10, y: 20 }] })
  draft(f.p, 'before down')
  touch(platform.TouchType.Down)
  await pump()
  draft(f.p, 'before move')
  touch(platform.TouchType.Move)
  await pump()
  touch(platform.TouchType.Up)
  await pump()
  const state = await f.state()
  assert.deepEqual(state.order, ['field', 'down', 'field', 'move', 'up'])
  assert.deepEqual(state.seen, ['before down', 'before move', 'before move'])
  assert.equal(f.p.timers.get('clock'), ticker)
  assert(timers.has(ticker))
  assert.equal(f.p.surfaceInputs.size, 0)
  assert.equal(f.p.error, '')
})

async function cleanup() {
  saveFailure = false
  for (const p of previews.splice(0)) {
    p.aboutToDisappear()
    await finish(p.operations)
  }
  for (const host of hosts.splice(0)) {
    assert.equal(host.leases.size, 0, 'leaked preview lease')
    await finish(host.dispose())
  }
  assert.equal(timers.size, 0, 'leaked fixture timer')
  assert.deepEqual(callbackErrors, [])
}
async function main() {
  let failures = 0
  process.on('unhandledRejection', error => unhandled.push(error))
  for (const scenario of scenarios) {
    disk.clear()
    logs.length = 0
    adapterCalls.length = 0
    try {
      await scenario.action()
      await cleanup()
      console.log('PASS ' + scenario.name)
    } catch (error) {
      failures++
      console.error('FAIL ' + scenario.name + '\n' + error.stack)
      try { await cleanup() } catch (cleanupError) {
        console.error('CLEANUP ' + cleanupError.stack)
        for (const host of hosts.splice(0)) await host.dispose()
        previews.length = 0
        timers.clear()
      }
    }
  }
  await new Promise(resolve => setImmediate(resolve))
  if (unhandled.length) {
    failures++
    console.error('FAIL unhandled rejections: ' + unhandled.map(error => error.stack).join('\n'))
  }
  console.log('preview-host-check: ' + scenarios.length + ' scenarios, ' + failures + ' failures; current preview + real host/actor/compiler/VM; stubbed platform/storage/adapters, no device or ArkTS typecheck')
  process.exitCode = failures ? 1 : 0
}
main().catch(error => { console.error(error.stack); process.exitCode = 1 })
