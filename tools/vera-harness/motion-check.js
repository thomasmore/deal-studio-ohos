// ui.Motion: the poses of every preset (VeraMotion.ets), and that a program using it compiles, validates its preset,
// refuses a nested Motion and decodes to a node carrying preset, trigger and children.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const {MOTION_PRESETS, MOTION_BUDGET_MS, motionStages, motionDuration, motionPose, MotionPose} = loadVera('VeraMotion')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VirtualMachine, deserializeVbc2} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi')
const {stylesFor} = loadVera('VeraUiCatalog')

assert.deepEqual(MOTION_PRESETS, stylesFor('motion'), 'the catalogue lists exactly the presets the renderer can play')
// launch leaves on purpose (a rocket goes out of sight and comes back from below): only it may go past the usual bounds, and it is unseen
// while it jumps from above to below.
{
  const {motionStages} = loadVera('VeraMotion')
  const stages = motionStages('launch')
  const jump = stages.findIndex((row, i) => i > 0 && row[2] > 0 && stages[i - 1][2] < 0)
  assert.ok(jump > 0 && stages[jump][6] === 0, 'launch is invisible while it moves from above to below')
  assert.ok(Math.min(...stages.map(r => r[2])) <= -150, 'launch goes out of sight')
}
const identity = JSON.stringify(new MotionPose())
for (const preset of MOTION_PRESETS) {
  assert.ok(motionDuration(preset) > 0 && motionDuration(preset) <= MOTION_BUDGET_MS, preset + ' has a short, fixed duration within the card budget')
  assert.equal(JSON.stringify(motionPose(preset, 1)), identity, preset + ' ends on the identity pose')
  assert.equal(JSON.stringify(motionPose(preset, 5)), identity, preset + ' past the end is still the identity')
  let moved = false
  for (let i = 0; i < 20; i++) {
    const p = motionPose(preset, i / 20)
    for (const k of Object.keys(p)) assert.ok(Number.isFinite(p[k]), preset + ' ' + k + ' is finite at ' + i)
    assert.ok(p.scale * p.scaleX > 0.01 && p.scale * p.scaleX < 1.6 && p.scale * p.scaleY > 0.01 && p.scale * p.scaleY < 1.6 && p.opacity >= 0 && p.opacity <= 1 && Math.abs(p.dx) <= 70 && Math.abs(p.dy) <= (preset === 'launch' ? 180 : 75), preset + ' stays in bounds')
    if (JSON.stringify(p) !== identity) moved = true
  }
  assert.ok(moved, preset + ' really moves')
}
assert.equal(JSON.stringify(motionPose('nonsense', 0.3)), identity, 'an unknown preset is the identity')
// The six the app draws by formula keep the lengths their curves were tuned for; every other preset plays as long as its stages.
assert.deepEqual(['tumble', 'flip', 'shake', 'bounce', 'pop', 'fade'].map(motionDuration), [900, 450, 450, 650, 350, 400])
assert.equal(motionDuration('jelly'), motionStages('jelly').slice(1).reduce((total, r) => total + r[0], 0))
// The app turns a preset about the pivot the card does: a swing hangs from its top edge, a wobble rocks on its base.
const {pivotPercent} = loadVera('VeraMotion')
assert.deepEqual(['swing', 'wobble', 'spin', 'shake'].map(p => pivotPercent(motionPose(p, 0.2).pivotY)), ['0%', '100%', '50%', '50%'])
// The table every preset is played from (a card plays it stage by stage): well formed, ends where it should rest, and different from the others.
const seen = new Set()
for (const preset of MOTION_PRESETS) {
  const st = motionStages(preset)
  assert.ok(st.length >= 2 && st[0][0] === 0 && st.every(r => r.length === 8 && r.every(Number.isFinite)), preset + ' is a table of 8-number rows')
  assert.ok(st.slice(1).every(r => r[0] > 0 && r[7] >= 0 && r[7] <= 3), preset + ' stages take time and name a curve')
  const last = st[st.length - 1]
  assert.deepEqual([last[1], last[2], last[3], last[4], last[5] % 360, last[6]], [0, 0, 1, 1, 0, 1], preset + ' rests where it started from at the end')
  const key = JSON.stringify(st); assert.ok(!seen.has(key), preset + ' is not a copy of another'); seen.add(key)
}
assert.equal(MOTION_PRESETS.length, 27); assert.deepEqual(motionStages('nonsense'), [])
assert.equal(JSON.stringify(motionPose('tumble', NaN)), JSON.stringify(motionPose('tumble', 0)), 'a NaN progress is the start')
assert.ok(motionPose('tumble', 0).angle > 360, 'a tumble starts well away from rest')

const program = (preset, inner) => `import * as ui from "std/ui"
import * as math from "std/math"

@jsonable
class AppState { roll: number; face: number; seed: number; }

function init(): AppState { return { roll: 0, face: 1, seed: 7 }; }

function onRoll(state: AppState, _v: number): AppState {
  let next: number = math.randomStep(state.seed);
  return { roll: state.roll + 1, face: math.randomBelow(next, 6) + 1, seed: next };
}

function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [
    ui.Column("spacious", [
      ${inner.replace('PRESET', preset)},
      ui.Button("primary", "Roll", "onRoll", 0, true)
    ])
  ]);
}`
const good = 'ui.Motion("PRESET", state.roll, [ui.Text("body", "face")])'
const run = src => {
  const r = compileVeraSource(src)
  const vm = new VirtualMachine(deserializeVbc2(r.vbc2 !== undefined ? r.vbc2 : r), new UiHostEnvironment())
  const out = []
  const walk = n => { out.push(n); (n.children || []).forEach(walk) }
  const state = vm.execute('init')
  walk(decodeVeraUi(vm.execute('view', [state]))[0])
  const again = vm.execute('onRoll', [state, 0])
  const second = []
  const walk2 = n => { second.push(n); (n.children || []).forEach(walk2) }
  walk2(decodeVeraUi(vm.execute('view', [again]))[0])
  return {out, second}
}
for (const preset of MOTION_PRESETS) {
  const {out, second} = run(program(preset, good))
  const m = out.find(n => n.kind === 'motion'), m2 = second.find(n => n.kind === 'motion')
  assert.ok(m, preset + ': a motion node is decoded')
  assert.equal(m.style, preset); assert.equal(m.numberValue, 0); assert.equal(m2.numberValue, 1, 'the trigger follows the state')
  assert.equal(m.children.length, 1)
}
// styles are not validated by the compiler (an unknown one decodes to the first of the list)
assert.equal(run(program('nonsense', good)).out.find(n => n.kind === 'motion').style, 'pop', 'an unknown preset falls back to the first, like any style')
assert.throws(() => compileVeraSource(program('tumble', 'ui.Motion("tumble", state.roll, [ui.Motion("pop", state.roll, [ui.Text("body", "x")])])')),
  e => (e.diagnostics || []).length > 0, 'a Motion inside a Motion is refused')

// ui.Transform: compile, decode with pose / duration / children, and the child rules; ui.Stage is refused
const scene = inner => `import * as ui from "std/ui"

@jsonable
class AppState { turn: number; }

function init(): AppState { return { turn: 0 }; }

function onTurn(state: AppState, _v: number): AppState { return { turn: state.turn + 180 }; }

function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [
    ui.Column("spacious", [
      ${inner},
      ui.Button("primary", "Turn", "onTurn", 0, true)
    ])
  ]);
}`
const decodeScene = src => {
  const r = compileVeraSource(src)
  const vm = new VirtualMachine(deserializeVbc2(r.vbc2 !== undefined ? r.vbc2 : r), new UiHostEnvironment())
  const all = []
  const walk = n => { all.push(n); (n.children || []).forEach(walk) }
  walk(decodeVeraUi(vm.execute('view', [vm.execute('init')]))[0])
  return all
}
let nodes = decodeScene(scene('ui.Transform("default", [0, state.turn], 500, 0, [ui.Text("body", "card")])'))
let t = nodes.find(n => n.kind === 'transform')
assert.deepEqual(t.series, [0, 0]); assert.equal(t.numberValue, 500); assert.equal(t.children.length, 1); assert.equal(t.style, 'default')
const refused = (inner, why) => assert.throws(() => compileVeraSource(scene(inner)), e => (e.diagnostics || []).length > 0, why)
refused('ui.Stage("default", 0, 0, [ui.Text("body", "x")])', 'ui.Stage is gone from the language')
refused('ui.Transform("default", [], 0, 0, [ui.Transform("default", [], 0, 0, [ui.Text("body", "x")])])', 'a Transform inside a Transform is refused')
{
  // a flip card: the front and the back by ui.When on the same state, turning on a handler
  const flip = `import * as ui from "std/ui"

@jsonable
class AppState { turn: number; }

function init(): AppState { return { turn: 0 }; }

function onFlip(state: AppState, _v: number): AppState { return { turn: state.turn + 180 }; }

function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [
    ui.Column("spacious", [
      ui.Transform("default", [0, state.turn], 500, 0, [
        ui.Card("default", [ui.Text("body", "Question")])
      ]),
      ui.Button("primary", "Flip", "onFlip", 0, true)
    ])
  ]);
}`
  const r = compileVeraSource(flip)
  const vm = new VirtualMachine(deserializeVbc2(r.vbc2 !== undefined ? r.vbc2 : r), new UiHostEnvironment())
  const all = []
  const walk = n => { all.push(n); (n.children || []).forEach(walk) }
  walk(decodeVeraUi(vm.execute('view', [vm.execute('onFlip', [vm.execute('init'), 0])]))[0])
  const card = all.find(n => n.kind === 'transform')
  assert.deepEqual(card.series, [0, 180]); assert.equal(card.numberValue, 500); assert.equal(card.children.length, 1)
}
console.log('motion-check ok')
