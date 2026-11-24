#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const {createPreview} = require('./preview-fixture')
const C = loadVera('VeraCompiler'), V = loadVera('VeraInterpreter')
global.ObservedV2 = c => c; global.Trace = () => {}
const L = loadSource(path.join(sourceRoot, 'components/VeraLiveTree.ets'))
const {InProcessHost, HostOperationFailure} = loadSource(path.join(sourceRoot, 'runtime/InProcessHost.ets'))
const {HostEffectsBridge} = loadSource(path.join(sourceRoot, 'runtime/HostEffectsBridge.ets'))
const src = `@jsonable class AppState { screen: string; count: number; text: string; }
function init(): AppState { return {screen: "a", count: 0, text: "same"}; }
function go(state: AppState, value: number): AppState { return {screen: "b", count: state.count, text: state.text}; }
function back(state: AppState, value: number): AppState { return {screen: "a", count: state.count, text: state.text}; }
function increment(state: AppState, value: number): AppState { return {screen: state.screen, count: state.count + 1, text: state.text}; }
function edit(state: AppState, value: string): AppState { return {screen: "b", count: state.count, text: value}; }
function tick(state: AppState, value: number): AppState { return {screen: state.screen, count: state.count + 1, text: state.text}; }
function screenA(state: AppState): ui.View { return ui.Screen("a", [ui.TextField("default", "Name", state.text, "edit"), ui.Button("primary", "Next", "go", 0, true),ui.Ticker("default","clock",33,true,"tick")]); }
function screenB(state: AppState): ui.View { return ui.Screen("b", [ui.TextField("default", "Name", state.text, "edit"),ui.Button("primary", "Next", "go", 0, true),ui.Ticker("default","clock",33,true,"tick"),ui.BackHandler("back")]); }
function view(state: AppState): ui.View { if (state.screen === "a") {return ui.AppTheme("clean","",[screenA(state),ui.Ticker("default","global-clock",33,true,"tick")]);} return ui.AppTheme("clean","",[screenB(state),ui.Ticker("default","global-clock",33,true,"tick")]); }`
const compiled = C.compileVeraSource(src)
const renderer = fs.readFileSync(path.join(sourceRoot, 'components/VeraPreview.ets'), 'utf8')
const number = num => ({kind:'NUMBER', num, str:'', bool:false, phase:'', id:0, x:0, y:0})
const stopped = [], started = [], cancelled = [], backSignals = []
const runtime = new InProcessHost()
const intervalCallbacks = []
const {probe:p} = createPreview({runtime, HostOperationFailure, HostEffectsBridge, mocks:{
  setInterval: callback => { intervalCallbacks.push(callback); return intervalCallbacks.length }, clearInterval() {}
}})
const realStartTimer = p.startTimer.bind(p)
p.vbc2 = compiled.vbc2
p.previewOnly = false
p.onBackHandlerChanged = value => backSignals.push(value)
const cancel = p.cancelField.bind(p)
p.cancelField = node => { cancelled.push(node); cancel(node) }
// Keep timer lifetime logic real, but do not let wall-clock callbacks fire during the test.
p.startTimer = (id, config) => { started.push(id); p.timers.set(id, 1); p.timerConfigs.set(id, config) }
p.stopTimer = id => { stopped.push(id); p.timers.delete(id); p.timerConfigs.delete(id); p.timerLastFire.delete(id) }
async function settle() {
  for (let i = 0; i < 40; i++) {
    const operations = p.operations
    await operations; await new Promise(resolve => setImmediate(resolve))
    if (operations === p.operations && p.inFlight === null && !p.postDrain && p.posts.length === 0 && p.fieldActions.length === 0) {
      assert.equal(p.error, ''); return
    }
  }
  assert.fail('preview work did not settle')
}
async function state() { return V.decodeRuntimeValue(JSON.parse(await runtime.requestSnapshot(p.handle))) }
async function apply(name, value = 0) { p.dispatchFieldAction(name, number(value)); await settle() }
function pendingNavigationEdit() {
  const node = p.liveRoot.children[0].children[0]
  p.changeField(node, node.fieldGeneration, node.value + '!', false)
}
;(async () => {
  try {
    p.aboutToAppear(); await settle(); assert(p.handle)
    const boundary = p.liveRoot.children[0], field = boundary.children[0], button = boundary.children[1]
    assert.equal(boundary.screenId, 'a'); field.touched = true; field.typed = 'unsaved'
    p.fieldController(field, field.fieldGeneration)
    const detached = L.cloneLiveTree(p.liveRoot)
    assert.equal(detached.children[0].screenId, 'a')
    const detachedField = detached.children[0].children[0]
    const cloneVm = new V.VirtualMachine(V.deserializeVbc2(compiled.vbc2), new (loadVera('VeraUi').UiHostEnvironment)())
    const cloneNext = loadVera('VeraUi').decodeVeraUi(cloneVm.execute('view', [cloneVm.execute('init')]))[0]
    L.reconcile(detached, cloneNext)
    assert.equal(detached.children[0].children[0], detachedField, 'clone/reconcile does not spuriously replace same-screen controls')
    const queued = p.captureFieldAction(button.action, number(0), true, button)
    assert(p.fieldActionCurrent(queued))
    await apply('increment')
    assert.equal(p.liveRoot.children[0].children[0], field, 'same-screen update keeps native field identity')
    assert.equal(field.touched, true); assert.equal(p.fieldInputs.size, 1)
    // Keep a composition draft pending so navigation tears it down rather than flushing it.
    p.changeField(field, field.fieldGeneration, 'unsaved', true)
    const surface = new L.LiveNode(); surface.kind = 'surface'; boundary.children.push(surface)
    p.surfaces.set(surface, {}); p.surfaceInputs.set(surface, new Map([[0, {}]]))
    const admission = runtime.postInput(p.handle, p.inputEvent(p.captureFieldAction('go', number(0))))
    assert.equal(admission.status, 'ACCEPTED'); await settle()
    assert.equal(p.surfaces.has(surface), false); assert.equal(p.surfaceInputs.has(surface), false)
    assert.equal(p.liveRoot.children[0], boundary, 'boundary itself stays observed')
    assert.notEqual(boundary.children[0], field, 'same-position same-value same-handler fields are replaced across screens')
    assert.equal(boundary.children[0].touched, false); assert.equal(p.fieldInputs.size, 0)
    assert.equal(p.fieldEdits.size, 0); assert(cancelled.includes(field))
    assert.equal(p.isLiveNode(field), false); assert.equal(p.fieldActionCurrent(queued), false)
    assert.equal((await state()).fields.get('count').value, 1, 'switch preserves shared state')
    assert.deepEqual(backSignals, [true]); assert.equal(p.backHandlerAction, 'back')
    assert.deepEqual(stopped, ['["a","clock"]'])
    assert.deepEqual(started, ['["a","clock"]', 'global-clock', '["b","clock"]'])
    await apply('back')
    assert.equal(p.backHandlerAction, ''); assert.deepEqual(backSignals, [true, false])
    assert.equal(p.fieldActionCurrent(queued), false, 'returning never resurrects stale controls')
    const timerId = '["a","clock"]', timerConfig = p.timerConfigs.get(timerId)
    const capturedTick = p.captureFieldAction('tick', number(1000))
    capturedTick.tickerId = timerId; capturedTick.tickerConfig = timerConfig
    await apply('increment')
    assert.equal(p.timerConfigs.get(timerId), timerConfig, 'ordinary redraw retains timer lifetime')
    assert(p.fieldActionCurrent(capturedTick))
    const before = (await state()).fields.get('count').value
    pendingNavigationEdit(); p.dispatchTickerAction(timerId, timerConfig, number(1000)); await settle()
    assert.equal((await state()).fields.get('screen').value, 'b')
    assert.equal((await state()).fields.get('count').value, before, 'outgoing tick cannot dispatch after a field navigates')
    assert.equal(p.fieldActions.length, 0)
    await apply('back')
    assert.equal(p.fieldActionCurrent(capturedTick), false, 'same ticker ID starts a new lifetime')
    pendingNavigationEdit(); p.dispatchFieldAction('tick', number(0)); await settle()
    assert.equal((await state()).fields.get('screen').value, 'b')
    assert.equal((await state()).fields.get('count').value, before + 1, 'application callback survives screen navigation')
    await apply('back')
    const globalConfig = p.timerConfigs.get('global-clock')
    pendingNavigationEdit(); p.dispatchTickerAction('global-clock', globalConfig, number(1000)); await settle()
    assert.equal(p.timerConfigs.get('global-clock'), globalConfig)
    assert.equal((await state()).fields.get('count').value, before + 2, 'application ticker survives screen navigation')
    await apply('back')
    const fastConfig = {interval:33, action:'tick'}
    p.stopTimer(timerId); realStartTimer(timerId, fastConfig)
    p.admissionBlocked = true
    p.dispatchFieldAction('go', number(0))
    intervalCallbacks.at(-1)()
    assert.equal(p.posts.length, 1, 'real fast timer callback queues a tick while navigation waits')
    assert.equal(p.posts[0].tickerConfig, fastConfig)
    const beforeFast = (await state()).fields.get('count').value
    p.admissionBlocked = false; p.resumeFieldActions(); await settle()
    assert.equal((await state()).fields.get('screen').value, 'b')
    assert.equal((await state()).fields.get('count').value, beforeFast, 'queued fast tick is dropped after screen exit')
    assert.equal(p.posts.length, 0)
    await apply('back')
    assert.notEqual(p.timerConfigs.get(timerId), fastConfig, 'return starts a new ticker lifetime')
    intervalCallbacks.at(-1)(); await settle()
    assert.equal((await state()).fields.get('count').value, beforeFast, 'old interval callback cannot revive on return')
    p.stopTimer('global-clock'); realStartTimer('global-clock', fastConfig)
    p.admissionBlocked = true; p.dispatchFieldAction('go', number(0)); intervalCallbacks.at(-1)()
    assert.equal(p.posts.length, 1); assert.equal(p.posts[0].key, 'global-clock')
    assert.equal(p.posts[0].tickerConfig, p.timerConfigs.get('global-clock'))
    p.admissionBlocked = false; p.resumeFieldActions(); await settle()
    assert.equal((await state()).fields.get('count').value, beforeFast + 1, 'global fast tick survives navigation')
    assert.match(renderer, /ForEach\(\[node.screenId\]/)
    assert.match(renderer, /rootScroller.scrollTo\(\{ xOffset: 0, yOffset: 0 \}\)/)
    assert.equal(loadVera('VeraSmoke').smokeRun(compiled), '')
    console.log('multiscreen-check: actor-backed shared state, native identity, stale controls/tickers, surface teardown and callbacks: ok')
  } finally { p.aboutToDisappear(); await settle() }
})().catch(error => { console.error(error); process.exitCode = 1 })
