const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { loadVera, loadSource, sourceRoot } = require('./source-loader')
const { compileVeraSource } = loadVera('VeraCompiler')
const { WidgetSession } = loadVera('VeraLiveWidget')
const { veraStateStamp } = loadVera('VeraStateStamp')
const source = fs.readFileSync(path.join(__dirname, 'examples/widget-counter.vera'), 'utf8')
const code = compileVeraSource(source).vbc2
const session = new WidgetSession(code, 'v1', '')
const frame = s => s.frame('p1', 'Widget counter', '🔢')
const texts = nodes => nodes.flatMap(n => [n.text, ...texts(n.children)])
let first = frame(session)
assert(texts(first.nodes).includes('0'))
session.tap(first, first.token, 'change', 1)
assert(texts(frame(session).nodes).includes('1'))
assert.throws(() => session.tap(frame(session), first.token, 'change', 1), /changed/)
assert.throws(() => session.tap(frame(session), frame(session).token, 'arbitrary', 1), /not available/)
assert.throws(() => session.tap(frame(session), frame(session).token, 'change', 999), /not available/)
const restored = new WidgetSession(code, 'v1', session.encodedState())
assert(texts(frame(restored).nodes).includes('1'))
let next = frame(restored)
restored.tap(next, next.token, 'change', -1)
assert(texts(frame(restored).nodes).includes('0'))
assert.equal(veraStateStamp(code), code.length + ':' + code.substring(0,64))
const old = compileVeraSource(source.replace('function widget(', 'function compact(').replace('return widget(state);', 'return compact(state);')).vbc2
assert.equal(new WidgetSession(old, 'v2', '').frame('p1','Old','📱').live, false)
const unsafe = compileVeraSource(source.replace('ui.Text("caption", "COUNTER")', 'ui.Image("default", "https://example.com/test.png", "test")')).vbc2
assert.throws(() => frame(new WidgetSession(unsafe, 'v3', '')), /Not card-safe: image/)
const over = compileVeraSource(source.replace('ui.Text("caption", "COUNTER")', 'ui.Text("caption", "' + 'x'.repeat(257) + '")')).vbc2
assert.throws(() => frame(new WidgetSession(over, 'v4', '')), /256/)
const nested = source.replace('ui.Text("caption", "COUNTER")', 'ui.Column("default", [ui.Column("default", [ui.Column("default", [ui.Text("body", "deep")])])])')
assert.throws(() => frame(new WidgetSession(compileVeraSource(nested).vbc2, 'deep', '')), /depth/)
const many = source.replace('ui.Text("caption", "COUNTER")', Array(41).fill('ui.Text("body", "node")').join(','))
assert.throws(() => frame(new WidgetSession(compileVeraSource(many).vbc2, 'many', '')), /40 nodes/)
const effectSource = 'import * as sdk from "std/sdk"\n' + source.replace('return { count: state.count + value };',
  'sdk.call("fixture/phone/Ability/action", [], "answer", "foreground"); return { count: state.count + value };') +
  '\nfunction answer(state: AppState, result: string): AppState { return state; }'
const effect = new WidgetSession(compileVeraSource(effectSource).vbc2, 'effect', '')
const beforeEffect = effect.encodedState(), effectFrame = frame(effect)
assert.throws(() => effect.tap(effectFrame, effectFrame.token, 'change', 1), /phone action required/)
assert.equal(effect.encodedState(), beforeEffect)
// Dynamic repeated rows without extending the renderer subset. Payloads identify items, not positions.
const listSource = `
@jsonable class AppState { ids: number[]; }
function init(): AppState { return { ids: [11, 22, 33] }; }
function remove(state: AppState, value: number): AppState {
  let remaining: number[] = [];
  for (let id: number of state.ids) { if (id !== value) { remaining.push(id); } }
  return { ids: remaining };
}
function widget(state: AppState): ui.View {
  let rows: ui.View[] = [];
  for (let id: number of state.ids) {
    rows.push(ui.Row("default", [ui.NumberText("body", id, "Item ", "", 1), ui.Button("secondary", "Done", "remove", id, true)]));
  }
  return ui.Column("default", rows);
}
function view(state: AppState): ui.View { return widget(state); }
`
const listCode = compileVeraSource(listSource).vbc2, list = new WidgetSession(listCode,'list','')
const listBefore = frame(list)
list.tap(listBefore,listBefore.token,'remove',22)
const listAfter = frame(list)
assert.equal(listAfter.nodes[0].children.length,2)
assert.deepEqual(listAfter.nodes[0].children.map(row=>row.children[1].value),[11,33])
assert.throws(()=>list.tap(listAfter,listBefore.token,'remove',33),/changed/)
assert.throws(()=>list.tap(listAfter,listAfter.token,'remove',22),/not available/)
list.tap(listAfter,listAfter.token,'remove',33)
assert.deepEqual(frame(list).nodes[0].children.map(row=>row.children[1].value),[11])
const card = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/widget/pages/LiveCard.ets'), 'utf8')
const view = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/widget/CardView.ets'), 'utf8')
assert.match(card, /handler: action/, 'the card posts the handler a button or shape reports')
assert.match(card, /handler: handler, x: x, y: y/, 'and the point a picture reports')
assert.match(card, /frameKey: this.token \+ this.seq/, 'the nodes are made again for every frame: the token and seq are in their key')
assert.match(view, /node.key \+ this.frameKey/)
{
  const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
  const model = loadSource(path.join(sourceRoot, 'widget/CardModel.ets'))
  const { paintGfx, decodeGfxOps, encodeGfxOps, GfxOp } = loadVera('GfxPaint')
  const { resolveTheme } = loadVera('VeraTheme')
  const { createRecorder } = require('./gfx-svg')
  const start = view.indexOf('  private contexts:')
  const end = view.indexOf('  private pictureAt(', start)
  assert(start >= 0 && end > start)
  const compiled = ts.transpileModule('class PictureProbe {\n' + view.slice(start, end) + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  })
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [])
  const ready = [...view.matchAll(/\.onReady\(\(\) => \{ (this\.paintPicture\(node\)) \}\)/g)]
  assert.equal(ready.length, 2, 'plain and interactive pictures both paint on Canvas readiness')
  const sliceReady = [...view.matchAll(/\.onReady\(\(\) => \{ (this\.paintSlice\(node, k\)) \}\)/g)]
  assert.equal(sliceReady.length, 1, 'drift slices paint on Canvas readiness')
  for (const [density, uiContext] of [1, 3].flatMap(density =>
    ['absent', 'undefined', 'throwing'].map(uiContext => [density, uiContext]))) {
    const recorders = [], scales = []
    const dependencies = {
      ...model, PICTURE_WIDTH: model.cardSize(2).pictureMax, resolveTheme, decodeGfxOps,
      contexts: count => Array.from({ length: count }, () => {
        const recorder = createRecorder(100, 100)
        recorders.push(recorder)
        return recorder.ctx
      }),
      vp2px: value => value * density,
      paintGfx: (...args) => { scales.push(args[7]); paintGfx(...args) }
    }
    const PictureProbe = new Function(...Object.keys(dependencies), compiled.outputText + '\nreturn PictureProbe;')(...Object.values(dependencies))
    const probe = new PictureProbe()
    Object.assign(probe, { preset: 'clean', primary: '', dimension: 2, fill: false })
    if (uiContext === 'undefined') { probe.getUIContext = () => undefined }
    if (uiContext === 'throwing') { probe.getUIContext = () => { throw Error('component UI context unavailable in form host') } }
    const shape = new GfxOp()
    Object.assign(shape, { kind: 'rect', x: 10, y: 10, w: 60, h: 40, color: '#ff0000' })
    const node = new model.CardNode()
    Object.assign(node, { kind: 'surface', w: 100, h: 100, size: 100, pic: 0, ops: encodeGfxOps([shape]) })
    for (const [index, callback] of ready.entries()) {
      if (index === 1) { node.pointer = 'touch' }
      new Function('node', callback[1]).call(probe, node)
      assert.match(recorders[0].svg(), /fill="#ff0000"/, 'the card Canvas paints without a component UI context')
    }
    Object.assign(node, { style: 'left', value: 2 })
    for (const k of probe.sliceList(node)) {
      new Function('node', 'k', sliceReady[0][1]).call(probe, node, k)
      assert.match(recorders[probe.contexts.length + k].svg(), /fill="#ff0000"/, 'each drift slice paints without a component UI context')
    }
    assert.deepEqual(scales, Array(6).fill(density), 'plain, interactive and drift picture paths use the form density conversion')
  }
}
// The token does not grow with the app's data: a log of 400 entries still fits the card, and a different log is a different token.
{
  const log = 'import * as ui from "std/ui"\n@jsonable class Entry { note: string; amount: number; }\n' +
    '@jsonable class AppState { entries: Entry[]; }\n' +
    'function init(): AppState { let e: Entry[] = []; let i: number = 0; while (i < 400) { e.push({note: "coffee at the corner shop", amount: i}); i = i + 1; } return {entries: e}; }\n' +
    'function add(state: AppState, value: number): AppState { let e: Entry[] = []; for (let x: Entry of state.entries) { e.push(x); } e.push({note: "tea", amount: value}); return {entries: e}; }\n' +
    'function view(state: AppState): ui.View { return ui.Column("default", [ui.NumberText("metric", state.entries.length(), "", " entries", 1)]); }\n' +
    'function widget(state: AppState): ui.View { return ui.Column("default", [ui.NumberText("metric", state.entries.length(), "", " entries", 1), ui.Button("primary", "+", "add", 1, true)]); }\n'
  const big = new WidgetSession(compileVeraSource(log).vbc2, 'v1', '')
  assert(big.encodedState().length > 10000, 'the state alone is over the card budget')
  const before = frame(big)
  assert(before.live && before.token.length < 120, 'token ' + before.token.length)
  big.tap(before, before.token, 'add', 1)
  const after = frame(big)
  assert.notEqual(after.token, before.token)
  assert.throws(() => big.tap(after, before.token, 'add', 1), /changed/)
}
// A tappable shape: a drum on the card. Its path is carried to the card, a tap on it runs the handler, a plain one is refused.
{
  const drumSource = fs.readFileSync(path.join(__dirname, 'examples/widget-drum.vera'), 'utf8')
  const drum = new WidgetSession(compileVeraSource(drumSource).vbc2, 'drum', '')
  const f = frame(drum)
  const shape = f.nodes[0].children[0]
  assert.equal(shape.kind, 'path')
  assert(shape.commands.startsWith('M50 12'), 'path data reaches the card')
  assert.equal(shape.action, 'hit')
  assert(JSON.stringify(f).length < 2000, 'a drum is small: ' + JSON.stringify(f).length)
  drum.tap(f, f.token, 'hit', 1)
  assert(texts(frame(drum).nodes).includes('1 hits'))
  assert.throws(() => drum.tap(frame(drum), frame(drum).token, 'hit', 5), /not available/)
  const still = compileVeraSource(drumSource.replace('0, "hit", 1)', '0)')).vbc2
  const plain = new WidgetSession(still, 'plain', '')
  assert.equal(frame(plain).nodes[0].children[0].action, '')
  assert.throws(() => plain.tap(frame(plain), frame(plain).token, 'hit', 1), /not available/)
  const long = drumSource.replace('M50 12', 'M50 12 ' + 'L1 1 '.repeat(130))
  assert.throws(() => frame(new WidgetSession(compileVeraSource(long).vbc2, 'long', '')), /shape exceeds/)
}
// A Motion on the card: a drum that jumps when it is hit. The frame carries the preset and the trigger, the trigger moves with
// the count, a style a card cannot play, a second Motion and a Motion that is not a number are refused.
{
  const motionSource = fs.readFileSync(path.join(__dirname, 'examples/widget-drum-motion.vera'), 'utf8')
  const drum = new WidgetSession(compileVeraSource(motionSource).vbc2, 'drum-motion', '')
  const f = frame(drum)
  const motion = f.nodes[0].children[0]
  assert.equal(motion.kind, 'motion')
  assert.equal(motion.style, 'pop')
  assert.equal(motion.trigger, 0)
  assert.equal(motion.children[0].kind, 'path')
  assert.equal(motion.children[0].action, 'hit')
  drum.tap(f, f.token, 'hit', 1)
  const g = frame(drum)
  assert.equal(g.nodes[0].children[0].trigger, 1, 'the trigger follows the count')
  assert.notEqual(g.token, f.token)
  assert(JSON.stringify(g).length < 2000, 'a Motion drum is small: ' + JSON.stringify(g).length)
  for (const style of loadVera('VeraMotion').MOTION_PRESETS) {
    const ok = motionSource.replace('"pop"', '"' + style + '"')
    assert.equal(frame(new WidgetSession(compileVeraSource(ok).vbc2, 'ok', '')).nodes[0].children[0].style, style)
  }
  // Three Motions at most; each touch plays the Motion its node sits under (slot), not all of them.
  const widgetAt = motionSource.indexOf('function widget(')
  const withMotions = n => motionSource.substring(0, widgetAt) + motionSource.substring(widgetAt).replace('ui.NumberText("metric", state.hits, "", " hits", 1)',
    Array.from({length: n}, (_, i) => 'ui.Motion("fade", state.hits, [ui.Text("caption", "m' + i + '")])').join(', '))
  const three = frame(new WidgetSession(compileVeraSource(withMotions(2)).vbc2, 'three', ''))
  const slots = []
  const walk = (nodes) => nodes.forEach(n => { if (n.kind === 'motion') slots.push(n.slot); walk(n.children) })
  walk(three.nodes)
  assert.deepEqual(slots, [0, 1, 2], 'the drum and two more: slots in order')
  assert.equal(loadVera('VeraLiveWidget').LIVE_MAX_MOTIONS, 5, 'five Motions at most')
  const drumPath = three.nodes[0].children[0].children[0]
  assert.equal(drumPath.kind, 'path'); assert.equal(drumPath.slot, 0, 'the drum sits under Motion 0')
  assert.equal(three.nodes[0].children[1].children[0].slot, 1, 'a text under the second Motion carries its slot')
  assert.throws(() => frame(new WidgetSession(compileVeraSource(withMotions(5)).vbc2, 'four', '')), /at most 5 ui\.Motion/)
  const nested = motionSource.replace('ui.Path(', 'ui.Motion("fade", 0, [ui.Path(').replace(', 0, "hit", 1)', ', 0, "hit", 1)])')
  assert.throws(() => compileVeraSource(nested), /E2107/, 'the compiler refuses a Motion inside a Motion')
}
{
  const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
  const { CARD_MAX_MOTIONS } = loadSource(path.join(sourceRoot, 'widget/CardModel.ets'))
  const { motionStages, motionPivot, pivotPercent } = loadVera('VeraMotion')
  const start = view.indexOf('  @State settled:')
  const end = view.indexOf('  /** How the theme dressed', start)
  assert(start >= 0 && end > start, 'the CardView Motion fields and methods must exist')
  const motion = view.slice(start, end)
  const filled = view.slice(view.indexOf('function filled('), view.indexOf('function contexts('))
  const compiled = ts.transpileModule(filled + '\nclass MotionProbe {\n' + motion.replace(/@State /g, '') + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  })
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), [])
  const Curve = { Linear: 0, EaseOut: 1, EaseIn: 2, EaseInOut: 3 }
  const { gfxFit } = loadVera('GfxPaint')
  const { pictureCovers } = loadSource(path.join(sourceRoot, 'widget/CardModel.ets'))
  const MotionProbe = new Function('SLOTS', 'motionStages', 'motionPivot', 'pivotPercent', 'Curve', 'gfxFit', 'pictureCovers',
    compiled.outputText + '\nreturn MotionProbe;')(CARD_MAX_MOTIONS, motionStages, motionPivot, pivotPercent, Curve, gfxFit, pictureCovers)
  const stateFields = [...motion.matchAll(/@State (\w+):/g)].map(m => m[1])
  const pose = (probe, node) => [1, 2, 3, 4, 5, 6].map(i => probe.poseOf(node, i))
  const finish = (probe, node) => {
    const stages = motionStages(node.style)
    for (let at = 1; at < stages.length; at++) {
      assert.equal(probe.phase[node.slot], at, 'each stage starts in order')
      assert.deepEqual(pose(probe, node), stages[at].slice(1, 7), 'the stage uses the preset pose')
      const animation = probe.motionAnimation(node)
      assert.equal(animation.duration, stages[at][0])
      assert.equal(animation.curve, stages[at][7])
      animation.onFinish()
      const phase = probe.phase.slice()
      animation.onFinish()
      assert.deepEqual(probe.phase, phase, 'a duplicate completion cannot advance the chain')
    }
    assert.equal(probe.phase[node.slot], 0)
    assert.equal(probe.playing(node), false, 'completion settles both inputs')
    assert.deepEqual(pose(probe, node), stages[stages.length - 1].slice(1, 7))
  }
  const motionSource = fs.readFileSync(path.join(__dirname, 'examples/widget-drum-motion.vera'), 'utf8').replace('"pop"', '"bounce"')
  for (const delta of [-1, 0, 1]) {
    const drum = new WidgetSession(compileVeraSource(motionSource.replace('state.hits + value', 'state.hits + (' + delta + ')')).vbc2, 'motion-' + delta, '')
    const probe = new MotionProbe()
    let current = frame(drum)
    let node = current.nodes[0].children[0]
    const stages = motionStages(node.style), rest = stages[stages.length - 1].slice(1, 7)
    probe.frameKey = current.token + ':0'
    assert.equal(probe.playing(node), false, 'the first frame never plays')
    assert.deepEqual(pose(probe, node), rest, 'the first frame skips even a displaced starting pose')
    probe.begin(node)
    assert.equal(probe.phase[node.slot], 0)
    assert.equal(probe.playing(node), false)
    for (let tap = 1; tap <= 3; tap++) {
      const state = stateFields.map(name => probe[name]), values = state.map(value => value.slice())
      probe.touched(node.children[0])
      assert.deepEqual(stateFields.map(name => probe[name]), values, 'a touch does not change reactive state')
      stateFields.forEach((name, i) => assert.equal(probe[name], state[i], name + ' keeps its reference before redraw'))
      assert.deepEqual(pose(probe, node), rest, 'before the answer the old frame stays at rest')
      assert.equal(probe.phase[node.slot], 0)
      drum.tap(current, current.token, 'hit', 1)
      current = frame(drum)
      node = current.nodes[0].children[0]
      assert.equal(node.trigger, delta * tap)
      probe.frameKey = current.token + ':' + tap
      assert.equal(probe.playing(node), true, 'accepted tap plays with trigger delta ' + delta + ', tap ' + tap)
      assert.deepEqual(pose(probe, node), stages[0].slice(1, 7), 'the accepted redraw starts at the first pose')
      probe.begin(node)
      finish(probe, node)
      probe.frameKey += ':redraw'
      assert.equal(probe.playing(node), false, 'an unchanged redraw cannot replay a settled tap')
      probe.begin(node)
      assert.deepEqual(pose(probe, node), rest)
    }
    probe.touched(node.children[0])
    assert.throws(() => drum.tap(current, 'stale', 'hit', 1), /changed/)
    assert.deepEqual(pose(probe, node), rest, 'a refused tap has no new frame and stays at rest')
    assert.equal(probe.phase[node.slot], 0)
    probe.frameKey += ':next'
    probe.begin(node)
    finish(probe, node)
    for (const change of [-1, 1]) {
      node = { ...node, trigger: node.trigger + change }
      probe.frameKey += ':trigger'
      assert.equal(probe.playing(node), true, 'a trigger change alone still plays')
      probe.begin(node)
      finish(probe, node)
    }
  }
  const layers = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-layers.vera'), 'utf8')).vbc2, 'motion-layers', '')
  const scene = frame(layers).nodes[0].children[0]
  const probe = new MotionProbe()
  probe.frameKey = 'layers:0'
  scene.children.forEach(node => probe.begin(node))
  probe.touched(scene.children[0].children[0])
  assert.deepEqual(probe.touches.slice(0, 3), [1, 1, 0], 'layer links count all scene Motions, not other slots')
  scene.children.forEach(node => assert.equal(probe.phase[node.slot], 0, 'layer touches wait for a redraw'))
  probe.frameKey = 'layers:1'
  scene.children.forEach(node => {
    assert.equal(probe.playing(node), true)
    probe.begin(node)
  })
  const node = scene.children[0], stale = probe.motionAnimation(node)
  probe.frameKey = 'layers:2'
  scene.children.forEach(node => probe.begin(node))
  stale.onFinish()
  assert.equal(probe.phase[node.slot], 1, 'an older frame completion cannot advance the new chain')
  scene.children.forEach(node => finish(probe, node))
  // A moving part's pivot is where its picture is drawn in the box, not a share of the box: a square cover picture on a 2x4 card
  // (324 x 148 vp) is scaled by 3.24 and cut top and bottom, so a pivot at 15 of 100 units is 39.4 vp above the box (-26.62%).
  const pivotProbe = new MotionProbe()
  const part = (style, w, h, px, py) => ({ kind: 'motion', style: 'swing', px, py, children: [{ kind: 'surface', style, w, h }] })
  pivotProbe.pictureW = () => 324; pivotProbe.pictureH = () => 148
  const swing = part('cover clear', 100, 100, 0.5, 0.15)
  assert.equal(pivotProbe.pivotXOf(swing), '50%')
  assert.equal(pivotProbe.pivotOf(swing), '-26.62%', 'the pivot under cover-fit')
  // A tall picture is letterboxed sideways: 100 x 200 units in a 132 x 145.2 box is 72.6 vp wide, from 29.7 vp.
  pivotProbe.pictureW = () => 132; pivotProbe.pictureH = () => 145.2
  const tall = part('clear', 100, 200, 0.25, 0.5)
  assert.equal(pivotProbe.pivotXOf(tall), '36.25%', 'the pivot in a letterboxed picture')
  assert.equal(pivotProbe.pivotOf(tall), '50%')
  // A Motion around more than a picture keeps the share as it is.
  assert.equal(pivotProbe.pivotXOf({ kind: 'motion', style: 'swing', px: 0.25, children: [] }), '25%')
}
// A picture on the card: ui.Surface drawn once for the state, its shapes carried in the frame (a few hundred characters), a tap on it
// calling the pointer handler with the finger down and up at that point. No frame loop, one picture, a few dozen shapes.
{
  const { encodeGfxOps, decodeGfxOps, decodeGfx } = loadVera('VeraGfx')
  const pandaSource = fs.readFileSync(path.join(__dirname, 'examples/widget-panda.vera'), 'utf8')
  const panda = new WidgetSession(compileVeraSource(pandaSource).vbc2, 'panda', '')
  const f = frame(panda)
  const motion = f.nodes[0].children[0]
  const picture = motion.children[0]
  assert.equal(picture.kind, 'surface')
  assert.equal(picture.w, 100)
  assert.equal(picture.h, 100)
  assert.equal(picture.pointer, 'pandaTouch')
  assert.equal(picture.size, 80, 'one figure under it leaves room for the full picture')
  assert.equal(f.preset, 'playful')
  const shapes = decodeGfxOps(picture.ops)
  assert.equal(shapes.length, 9, 'the nine shapes the program drew')
  assert.equal(shapes[2].kind, 'circle'); assert.equal(shapes[2].r, 36); assert.equal(shapes[2].color, '#FFFFFF')
  assert.equal(shapes[8].kind, 'arc'); assert.equal(shapes[8].start, 110); assert.equal(shapes[8].sweep, 140)
  assert.equal(encodeGfxOps(shapes), picture.ops, 'what is carried is what was drawn')
  assert(JSON.stringify(f).length < 2500, 'a panda is small: ' + JSON.stringify(f).length)
  assert.deepEqual(decodeGfxOps('not json'), [])
  panda.tapSurface(f, f.token, 'pandaTouch', 50, 50)
  const g = frame(panda)
  assert.equal(g.nodes[0].children[0].trigger, 1, 'one tap is one hop: down counts, up does not')
  assert(texts(g.nodes).includes('1 hops'))
  assert.throws(() => panda.tapSurface(frame(panda), f.token, 'pandaTouch', 50, 50), /changed/, 'a tap from an older frame')
  assert.throws(() => panda.tapSurface(g, g.token, 'init', 50, 50), /not available/, 'only the picture\'s own handler')
  assert.throws(() => panda.tapSurface(g, g.token, 'pandaTouch', NaN, 5), /not available/)
  assert.throws(() => panda.tap(g, g.token, 'pandaTouch', 0), /not available/, 'a number tap is not a picture tap')
  // No frame loop on a card, one picture, a few dozen shapes.
  const looping = (pandaSource + 'function pandaTick(state: AppState, elapsedMs: number): AppState { return state; }')
    .replace('"panda", "", "pandaTouch"', '"panda", "pandaTick", "pandaTouch"')
  assert.throws(() => frame(new WidgetSession(compileVeraSource(looping).vbc2, 'loop', '')), /no frames/)
  // Three pictures at most; they are numbered, and pictures side by side share the card's width.
  const cut = pandaSource.indexOf('function widget(')
  const withPictures = (n, inRow) => {
    const extra = Array.from({length: n}, () => 'ui.Surface("default", 100, 100, "panda", "", "")').join(', ')
    return pandaSource.substring(0, cut) + pandaSource.substring(cut).replace('ui.NumberText("metric", state.hops, "", " hops", 1)',
      inRow ? 'ui.Row("default", [' + extra + '])' : extra)
  }
  const column = frame(new WidgetSession(compileVeraSource(withPictures(2, false)).vbc2, 'two', ''))
  const pics = []
  const gather = (nodes) => nodes.forEach(n => { if (n.kind === 'surface') pics.push(n); gather(n.children) })
  gather(column.nodes)
  assert.deepEqual(pics.map(n => n.pic), [0, 1, 2], 'the first is the panda, the others follow')
  const row = frame(new WidgetSession(compileVeraSource(withPictures(2, true)).vbc2, 'row', ''))
  const inRow = []
  const gatherRow = (nodes) => nodes.forEach(n => { if (n.kind === 'surface') inRow.push(n); gatherRow(n.children) })
  gatherRow(row.nodes)
  assert(inRow.every(n => n.size <= 59), 'two pictures in a row, and the one above, fit the width: ' + inRow.map(n => n.size))
  assert.throws(() => frame(new WidgetSession(compileVeraSource(withPictures(5, false)).vbc2, 'four', '')), /at most 5 ui\.Surface/)
  const many = pandaSource.replace('  return shapes;', '  shapes.push(gfx.circle(1, 50, 2, "#1F1F1F"));\n'.repeat(60) + '  return shapes;')
  assert.throws(() => frame(new WidgetSession(compileVeraSource(many).vbc2, 'many', '')), /at most 60 shapes/)
  // The picture takes the room the rest leaves: more text under it, a smaller picture (never under 40).
  const cutAt = pandaSource.indexOf('function widget(')
  const crowded = pandaSource.substring(0, cutAt) + pandaSource.substring(cutAt).replace('ui.NumberText("metric", state.hops, "", " hops", 1)',
    'ui.NumberText("metric", state.hops, "", " hops", 1), ui.Text("caption", "best"), ui.Text("caption", "more")')
  const smaller = frame(new WidgetSession(compileVeraSource(crowded).vbc2, 'crowded', '')).nodes[0].children[0].children[0]
  assert(smaller.size < 80 && smaller.size >= 40, 'a crowded card shrinks the picture: ' + smaller.size)
  const still = compileVeraSource(pandaSource.replace('"panda", "", "pandaTouch"', '"panda", "", ""')).vbc2
  const looked = new WidgetSession(still, 'still', '')
  assert.equal(frame(looked).nodes[0].children[0].children[0].pointer, '')
  assert.throws(() => looked.tapSurface(frame(looked), frame(looked).token, '', 5, 5), /not available/)
}
// Two pictures side by side, each under its own Motion (examples/widget-two-pictures.vera): each touch is counted for its own Motion's slot.
{
  const two = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-two-pictures.vera'), 'utf8')).vbc2, 'two-pictures', '')
  const f = frame(two)
  const [left, right] = f.nodes[0].children[0].children
  assert.deepEqual([left.slot, right.slot], [0, 1])
  assert.deepEqual([left.children[0].pic, right.children[0].pic], [0, 1])
  assert.deepEqual([left.children[0].pointer, right.children[0].pointer], ['touchLeft', 'touchRight'])
  assert(left.children[0].size <= 59 && right.children[0].size <= 59, 'side by side, each takes half the width')
  two.tapSurface(f, f.token, 'touchRight', 50, 50)
  assert(texts(frame(two).nodes).includes('1'), 'one touch counted')
}
// The theme's roles reach the card (CardStyle): sizes, weights, families, tones, panels, alignment, and only what differs from the default is in the frame.
{
  const styled = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-styles.vera'), 'utf8')).vbc2, 'styles', '')
  const f = frame(styled)
  const [eyebrow, title, panel, row] = f.nodes[0].children
  assert.equal(eyebrow.size, 10); assert.equal(eyebrow.spacing, 2); assert(eyebrow.weight >= 500, 'an eyebrow is not light')
  assert.equal(title.size, 22); assert.equal(title.weight, 700); assert.equal(title.family, 'Noto Serif', 'editorial headings are serif')
  assert.equal(panel.panel !== undefined, true); assert(panel.pad > 0 && panel.radius > 0, 'a panel has a fill, padding and a radius')
  assert.equal(row.align, 'split'); assert.equal(row.children[1].color, '#9B2226', 'danger is the theme\'s danger ink')
  assert.equal(row.children[0].weight, undefined, 'a body text at the default weight carries no weight')
  assert.equal(f.nodes[0].align, undefined, 'a centred column carries no alignment')
  assert(!JSON.stringify(f).includes('"gap"'), 'no gap in the frame when it is the default')
  assert(JSON.stringify(f).length < 2400, 'styles stay small: ' + JSON.stringify(f).length)
}
// Icons, badges, progress, stats and a sparkline on the card (examples/widget-water.vera, widget-metrics.vera).
{
  const { decodeGfxOps } = loadVera('VeraGfx')
  const water = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-water.vera'), 'utf8')).vbc2, 'water', '')
  const f = frame(water)
  const ring = f.nodes[0].children[0]
  assert.equal(ring.kind, 'ring'); assert.equal(ring.val, 3); assert.equal(ring.max, 8); assert.equal(ring.sub, '38%'); assert.equal(ring.text, 'Water')
  assert.equal(ring.size, 52); assert.match(ring.color, /^#[0-9A-Fa-f]{6}$/); assert.notEqual(ring.color, '#172033', 'the ring takes the theme\'s accent, not the default ink')
  const [minus, plus] = f.nodes[0].children[1].children
  assert.equal(minus.kind, 'iconbutton'); assert(minus.commands.length > 0, 'an icon button carries its icon\'s path')
  assert.notEqual(minus.fill, plus.fill, 'secondary and primary differ'); assert.equal(plus.color, '#FFFFFF', 'the ink on a primary button is the theme\'s onPrimary')
  water.tap(f, f.token, 'add', 1)
  assert.equal(frame(water).nodes[0].children[0].val, 4, 'an icon button runs its handler')
  assert.throws(() => water.tap(frame(water), frame(water).token, 'add', 5), /not available/)
  const metrics = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-metrics.vera'), 'utf8')).vbc2, 'metrics', '')
  const m = frame(metrics)
  const kinds = []; const walk = n => { kinds.push(n.kind); n.children.forEach(walk) }; m.nodes.forEach(walk)
  assert.deepEqual(kinds.slice(0, 4), ['column', 'row', 'badge', 'icon'])
  assert(kinds.includes('numbertext') && kinds.includes('surface'), 'a stat is a labelled figure; a sparkline is a picture')
  const chart = []; const find = n => { if (n.kind === 'surface') chart.push(n); n.children.forEach(find) }; m.nodes.forEach(find)
  const shapes = decodeGfxOps(chart[0].ops)
  assert(shapes.some(o => o.kind === 'polyline') && shapes.some(o => o.kind === 'circle'), 'a line and its last point')
  assert.equal(chart[0].pointer, '', 'a sparkline is not tappable'); assert.equal(chart[0].pic, 0)
  assert(JSON.stringify(m).length < 4200, 'the metrics widget stays small: ' + JSON.stringify(m).length)
  const unknownIcon = fs.readFileSync(path.join(__dirname, 'examples/widget-metrics.vera'), 'utf8').replace('"star"', '"nonesuch"')
  assert.throws(() => frame(new WidgetSession(compileVeraSource(unknownIcon).vbc2, 'bad-icon', '')), /unknown icon/)
}
// A timer that runs by itself (ui.Timer): the frame carries the moment and the direction, the platform's TextTimer does the ticking.
{
  const timerSource = fs.readFileSync(path.join(__dirname, 'examples/widget-timer.vera'), 'utf8')
  const timer = new WidgetSession(compileVeraSource(timerSource).vbc2, 'timer', '')
  const f = frame(timer)
  const [up, down] = f.nodes[0].children
  assert.equal(up.kind, 'timer'); assert.equal(up.max, 0, 'counts up'); assert.equal(up.pic, 0)
  assert.equal(down.kind, 'timer'); assert.equal(down.max, 1, 'counts down'); assert.equal(down.pic, 1)
  assert(Math.abs(up.val - Date.now()) < 60000, 'the moment is milliseconds since 1970: ' + up.val)
  assert(down.val - up.val > 5000000, 'the second one ends an hour and a half later')
  assert.equal(up.size, 30); assert.equal(down.size, 18); assert.equal(up.family, 'monospace', 'the technical theme\'s metric font')
  assert(!up.text, 'a timer carries no text: the platform draws it')
  const four = timerSource.replace('ui.Timer("heading", state.endsAt, true),', 'ui.Timer("heading", state.endsAt, true), ui.Timer("caption", state.endsAt, true), ui.Timer("caption", state.endsAt, true),')
  assert.throws(() => frame(new WidgetSession(compileVeraSource(four).vbc2, 'many-timers', '')), /at most 3 ui\.Timer/)
}
// The card's size: the frame is fitted to it, a widget that takes the size draws differently, and the limits grow with it.
{
  const { cardSize } = loadVera('VeraLiveWidget')
  assert.deepEqual([2, 3, 4].map(d => cardSize(d).label), ['2x2', '2x4', '4x4'])
  assert.deepEqual([2, 3, 4].map(d => cardSize(d).maxButtons), [2, 4, 6]); assert.deepEqual([cardSize(7).dimension, cardSize(0).label], [2, '2x2'], 'an unknown size is 2x2')
  const sized = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-sizes.vera'), 'utf8')).vbc2, 'sizes', '')
  assert.equal(sized.takesSize(), true)
  const counts = [2, 3, 4].map(d => { const f = sized.frame('p', 'A', '', d); assert.equal(f.dimension, d); let n = 0; const walk = x => { n++; x.children.forEach(walk) }; f.nodes.forEach(walk); return n })
  assert(counts[0] < counts[1] && counts[1] < counts[2], 'a bigger card, more on it: ' + counts)
  assert.equal(new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-counter.vera'), 'utf8')).vbc2, 'one', '').takesSize(), false)
  // The 41st node is refused on a 2x2 card and taken on a 4x4 one.
  const tens = n => Array.from({length: n}, (_, i) => 'ui.Text("body", "t' + i + '")').join(', ')
  const manyAt = (d) => { const src = fs.readFileSync(path.join(__dirname, 'examples/widget-sizes.vera'), 'utf8').replace('rows.push(ui.Text("title", "Plan"));', 'rows.push(ui.Column("default", [' + tens(5) + ']));'.repeat(1) + '\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));\n  rows.push(ui.Column("default", [' + tens(5) + ']));'); return new WidgetSession(compileVeraSource(src).vbc2, 'many', '').frame('p', 'A', '', d) }
  assert.throws(() => manyAt(2), /widget exceeds 40 nodes/)
  assert.equal(manyAt(4).live, true)
}
// The frame goes into the binding compact (only what differs from a default node) and the card gives the defaults back: the same nodes, in about half the characters.
{
  const { compactFrame, normalizeNodes } = loadVera('VeraLiveWidget')
  for (const name of ['widget-metrics', 'widget-styles', 'widget-panda', 'widget-water', 'widget-two-pictures']) {
    const f = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/' + name + '.vera'), 'utf8')).vbc2, name, '').frame('p', 'A', '')
    const compact = JSON.parse(JSON.stringify(compactFrame(f)))
    assert.deepEqual(JSON.parse(JSON.stringify(normalizeNodes(compact.nodes))), JSON.parse(JSON.stringify(f.nodes)), name + ': what the card restores is what was sent')
    assert(JSON.stringify(compact).length < JSON.stringify(f).length * 0.7, name + ' is smaller compact: ' + JSON.stringify(compact).length + ' of ' + JSON.stringify(f).length)
    assert.equal(compact.dimension, 2); assert.equal(compact.live, true)
  }
}
// Switches: a toggle and a checkbox are taps that say on or off; a stale token or an unknown handler is refused.
{
  const sw = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-switch.vera'), 'utf8')).vbc2, 'sw', '')
  const f0 = sw.frame('p', 'A', ''); const col = f0.nodes[0].children
  assert.deepEqual(col.slice(1).map(n => [n.kind, n.val, n.action]), [['toggle', 0, 'setFocus'], ['checkbox', 0, 'setDone']])
  assert(col[2].commands.length > 0, 'a checkbox carries its check mark')
  sw.tapSwitch(f0, f0.token, 'setFocus', true); sw.tapSwitch(f0, f0.token, 'setDone', true)
  const f1 = sw.frame('p', 'A', ''); assert.deepEqual(f1.nodes[0].children.slice(1).map(n => n.val), [1, 1])
  assert.throws(() => sw.tapSwitch(f1, 'stale', 'setFocus', false), /Widget changed/)
  assert.throws(() => sw.tapSwitch(f1, f1.token, 'nope', false), /not available/)
}
// Layers: parts one over another, each its own Motion and picture, all at one size.
{
  const lay = new WidgetSession(compileVeraSource(fs.readFileSync(path.join(__dirname, 'examples/widget-layers.vera'), 'utf8')).vbc2, 'lay', '')
  const f = lay.frame('p', 'A', ''); const box = f.nodes[0].children[0]
  assert.equal(box.kind, 'layers'); assert.deepEqual(box.children.map(c => [c.kind, c.style, c.slot]), [['motion', 'recoil', 0], ['motion', 'swing', 1]])
  const [a, b] = box.children.map(c => c.children[0]); assert.equal(a.size, b.size, 'the layers of a picture are drawn at one size')
  assert.notEqual(a.ops, b.ops, 'each layer draws its own part')
  assert.deepEqual(a.links, [0, 1]); assert.deepEqual(b.links, [0, 1], 'a touch on any layer plays every Motion of the scene')
  assert.equal(f.nodes[0].children[1].links, undefined, 'a node outside the layers has no links')
  assert.deepEqual(box.links, [0, 1], 'the scene carries its Motions: a touch no part takes lands on it')
  assert.deepEqual(lay.tap(f, f.token, '#touch', 0), [], 'a touch on a Motion with no handler runs nothing')
  // One Motion over a still picture: a touch on the still part plays it too.
  const one = fs.readFileSync(path.join(__dirname, 'examples/widget-layers.vera'), 'utf8')
    .replace('ui.Motion("recoil", 0, [ui.Surface("default", 100, 100, "drum", "", "hitDrum")])', 'ui.Surface("default", 100, 100, "drum", "", "hitDrum")')
  const fo = new WidgetSession(compileVeraSource(one).vbc2, 'one', '').frame('p', 'A', ''); const scene = fo.nodes[0].children[0]
  assert.equal(scene.children[0].kind, 'surface'); assert.deepEqual(scene.children[0].links, [0], 'a still layer plays the one Motion of its scene')
  assert.deepEqual(scene.links, [0])
  assert.throws(() => lay.tap(f, 'stale', '#touch', 0), /Widget changed/)
  const nested = fs.readFileSync(path.join(__dirname, 'examples/widget-layers.vera'), 'utf8').replace('ui.Layers("default", 100, 100, [', 'ui.Layers("default", 100, 100, [ui.Layers("default", 100, 100, []),')
  assert.throws(() => compileVeraSource(nested), /Layers/, 'a Layers inside a Layers is refused')
}
// ui.Timer is set on TextTimer the one way, in the app and on the card (CardModel.timerFace): TextTimer reads `count` only when it
// counts down, so a timer counting up starts from `startTime`, or it would start from 00:00 at every redraw.
{
  const M = loadSource(path.join(sourceRoot, 'widget/CardModel.ets'))
  const now = 1e12, minute = 60000
  const up = M.timerFace(now - 20 * minute, false, now)
  assert.deepEqual([up.countDown, up.startTime, up.count, up.format], [false, 20 * minute, -1, 'mm:ss'], 'counting up starts from the time already gone')
  const down = M.timerFace(now + 55 * minute, true, now)
  assert.deepEqual([down.countDown, down.count, down.format], [true, 55 * minute, 'mm:ss'], 'under an hour, no hours')
  assert.equal(M.timerFace(now + 60 * minute, true, now).format, 'HH:mm:ss', 'an hour shows hours')
  assert.equal(M.timerFace(now - 60 * minute, false, now).format, 'HH:mm:ss')
  assert.equal(M.timerFace(now + 3 * 1440 * minute, true, now).count, M.TEXT_TIMER_MAX_MS, 'a longer countdown starts from the longest TextTimer takes')
  assert.equal(M.timerFace(now - 5, true, now).count, 1, 'a countdown that is over is at zero: 1 ms, as TextTimer takes 0 for its default minute')
  assert.equal(M.timerFace(now, true, now).count, 1)
  const renderer = fs.readFileSync(path.join(sourceRoot, 'components/VeraPreview.ets'), 'utf8')
  for (const [name, text] of [['card', view], ['app', renderer]]) {
    assert.doesNotMatch(text, /3000000|3600000/, 'the ' + name + ' has no hour threshold of its own')
    assert.match(text, /startTime: this\.\w+\(node\)\.startTime/, 'the ' + name + ' sets where a timer counting up starts')
  }
  // The app keeps a timer's controller only while its node is drawn.
  assert.match(renderer, /this\.textTimers\.delete\(node\)/)
  // One limit for each thing a card carries: the widget is refused beyond it and the card keeps that many canvases, timers and Motion slots.
  const live = loadVera('VeraLiveWidget')
  assert.deepEqual([live.LIVE_MAX_SURFACES, live.LIVE_MAX_MOTIONS, live.LIVE_MAX_TIMERS, live.LIVE_MAX_SHAPES],
    [M.CARD_MAX_PICTURES, M.CARD_MAX_MOTIONS, M.CARD_MAX_TIMERS, M.CARD_MAX_SHAPES])
  assert.match(view, /contexts\(CARD_MAX_PICTURES\)/); assert.match(view, /timerControllers\(CARD_MAX_TIMERS\)/); assert.match(view, /SLOTS: number = CARD_MAX_MOTIONS/)
  assert.doesNotMatch(view, /ctx[0-9]|timer[0-9]\b|\[0, 0, 0, 0, 0\]/, 'no hand-written list of five or three')
  // Who takes a touch on the card: a shape without an action and a Motion around only a figure let it through to the card, which
  // opens the app; in a Layers a part with no handler lets it through to the parts under it.
  assert.doesNotMatch(view, /'#touch'/, 'the card posts TOUCH_ACTION, not a literal of its own')
  assert.match(view, /if \(node\.action\.length > 0\) \{\s*Shape\(\)/, 'a Path takes a tap only when it has an action')
  assert.equal((view.match(/if \(this\.touchPlays\(node\)\)/g) || []).length, 3, 'each builder level plays a Motion on touch only around a picture')
  assert.equal((view.match(/\.hitTestBehavior\(this\.layerHit\(child\)\)/g) || []).length, 6, 'each Layers part says whether it takes a touch')
  // A touch only counts: nothing is redrawn before the answer, so a touch whose answer never comes leaves no Motion in its starting pose.
  const touched = view.substring(view.indexOf('private touched('), view.indexOf('private playing('))
  assert.doesNotMatch(touched, /setPhase|this\.phase\b|this\.settled\b/, 'a touch changes no state')
  assert.match(view, /if \(this\.begun\[node\.slot\] !== this\.frameKey\) \{ return stages\[0\]\[index\] \}/, 'only a frame not yet begun shows the starting pose')
}
// Pictures side by side in a row share its width at any depth: two Sparklines (each a column holding a picture), or two Layers.
{
  const two = 'import * as ui from "std/ui"\n@jsonable class AppState { n: number; }\nfunction init(): AppState { return { n: 1 }; }\n' +
    'function view(state: AppState): ui.View { return ui.Text("body", "x"); }\n' +
    'function widget(state: AppState): ui.View { return ui.Row("default", [ui.Sparkline("default", [1, 2, 3], 3), ui.Sparkline("default", [3, 2, 1], 3)]); }\n'
  let f
  try { f = new WidgetSession(compileVeraSource(two).vbc2, 'two', '').frame('p', 'A', '') } catch (e) { throw new Error(e.message + JSON.stringify(e.diagnostics || [])) }
  const charts = []; const walk = n => { if (n.kind === 'surface') charts.push(n); n.children.forEach(walk) }; f.nodes.forEach(walk)
  assert.equal(charts.length, 2)
  for (const c of charts) assert(c.size <= Math.floor((126 - 8) / 2), 'two charts in a row fit the 2x2 card: ' + c.size)
}

// A cover picture (ui.Surface style "cover") is the card's background: it takes no room from the rest, the effects of its shapes ride in the
// frame, the card takes it out of the tree with its Motion (splitCover), and only one, outside rows and layers, is allowed.
{
  const { splitCover, coverScrim, compactFrame } = loadVera('../widget/CardModel')
  const { decodeGfxOps } = loadVera('GfxPaint')
  const rich = fs.readFileSync(path.join(__dirname, 'examples/widget-rich.vera'), 'utf8')
  const widgetPicture = 'ui.Surface("default", 100, 100, "scene", "", "onTouch"),\n      ui.Text'
  const coverSource = rich.replace(widgetPicture, 'ui.Surface("cover", 100, 100, "scene", "", "onTouch"),\n      ui.Text')
  assert.notEqual(coverSource, rich)
  const f = new WidgetSession(compileVeraSource(coverSource).vbc2, 'cover', '').frame('p1', 'Cover', '🌄')
  assert(JSON.stringify(compactFrame(f)).length <= 8000, 'a picture with gradients, effects and a moving part fits the frame budget')
  const surfacesOf = nodes => { const out = []; const walk = n => { if (n.kind === 'surface') out.push(n); n.children.forEach(walk) }; nodes.forEach(walk); return out }
  const pictures = surfacesOf(f.nodes)
  assert.deepEqual(pictures.map(p => p.style), ['cover', 'cover clear'], 'the cover picture and the layer of its moving part')
  assert(pictures.some(p => decodeGfxOps(p.ops).some(o => o.kind === 'fx' && o.fx === 'shadow')), 'the effects of the picture reach the card')
  const split = splitCover(f.nodes)
  assert(split.cover !== null && split.cover.kind === 'layers', 'the cover picture leaves the tree whole, its layers with it')
  assert.deepEqual(texts(split.rest).filter(Boolean), ['0 taps'], 'the rest is what lies over it')
  assert.equal(surfacesOf(f.nodes).length, 2, 'splitCover leaves the frame itself as it was')
  assert.equal(splitCover([]).cover, null)
  // A cover picture with no parts can still sit in a ui.Motion of its own: the card takes the Motion out with it.
  const plain = '@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 0}; }\n' +
    'function sky(state: AppState): gfx.Shape[] { return [gfx.rect(0, 0, 100, 100, "#123456"), gfx.circle(50, 50, 10, "accent")]; }\n' +
    'function view(state: AppState): ui.View { return ui.Text("body", "x"); }\n' +
    'function widget(state: AppState): ui.View { return ui.Column("center", [ui.Motion("pop", 0, [ui.Surface("cover", 100, 100, "sky", "", "")]), ui.Text("caption", "hi")]); }\n'
  const held = splitCover(new WidgetSession(compileVeraSource(plain).vbc2, 'plain', '').frame('p1', 'Plain', '🌄').nodes)
  assert(held.cover !== null && held.cover.kind === 'motion', 'a cover picture leaves the tree with its Motion')
  assert.deepEqual(coverScrim('#F8FAFC', 0).map(c => c[0]), ['#00F8FAFC', '#00F8FAFC'], 'no veil without a text over the picture')
  assert.equal(coverScrim('#F8FAFC', 0.3).slice(-1)[0][0], '#D9F8FAFC', 'a veil of the card colour under a text')
  // The veil lies under the text only, with a short edge above it: one over the bottom half whitened the ground a scene stands on.
  assert(f.veil > 0.1 && f.veil < 0.45, 'one line of text over the picture takes a small share of the card: ' + f.veil)
  const clearTo = coverScrim('#F8FAFC', f.veil)[1][1]
  assert(clearTo >= 0.4, 'the picture is clear down to ' + clearTo + ' of the card')
  assert.equal(held.cover !== null ? new WidgetSession(compileVeraSource(plain.replace(', ui.Text("caption", "hi")', '')).vbc2, 'bare', '').frame('p1', 'Bare', '🌄').veil : -1, 0,
    'no veil with nothing over the picture')
  const twoCovers = coverSource.replace(/(function widget[\s\S]*?ui\.Column\("center", \[)/, '$1\n      ui.Surface("cover", 100, 100, "scene", "", ""),')
  assert.throws(() => new WidgetSession(compileVeraSource(twoCovers).vbc2, 'two', '').frame('p1', 'Two', '🌄'), /at most one ui.Surface of style "cover"/)
  const inRow = plain.replace('ui.Motion("pop", 0, [ui.Surface("cover", 100, 100, "sky", "", "")])', 'ui.Row("default", [ui.Surface("cover", 100, 100, "sky", "", "")])')
  assert.notEqual(inRow, plain)
  assert.throws(() => new WidgetSession(compileVeraSource(inRow).vbc2, 'row', '').frame('p1', 'Row', '🌄'), /not in a row or a ui.Layers/)
  // A ui.Motion goes out with the cover only when the cover is all it holds: one around a column that holds it would leave the cover in
  // the tree, drawn in the column at a picture's size and not under the card, so it is refused.
  const motionColumn = plain.replace('ui.Motion("pop", 0, [ui.Surface("cover", 100, 100, "sky", "", "")])',
    'ui.Motion("pop", 0, [ui.Column("default", [ui.Surface("cover", 100, 100, "sky", "", ""), ui.Text("body", "x")])])')
  assert.notEqual(motionColumn, plain)
  assert.throws(() => new WidgetSession(compileVeraSource(motionColumn).vbc2, 'mc', '').frame('p1', 'MC', '🌄'), /alone in a ui.Motion/)
}

// Moving parts (gfx.moving): the card cannot move a part of one canvas, so the picture becomes layers of the same box -- what is still under
// the part, the part in a Motion that turns about its pivot, what is still over it -- with the pointer on the bottom layer and every part
// played by a touch anywhere on it.
{
  const { splitCover } = loadVera('../widget/CardModel')
  const { decodeGfxOps } = loadVera('GfxPaint')
  const pendulum = fs.readFileSync(path.join(__dirname, 'examples/widget-pendulum.vera'), 'utf8')
  const session = new WidgetSession(compileVeraSource(pendulum).vbc2, 'pendulum', '')
  const f = session.frame('p1', 'Pendulum', '🕰')
  const scene = f.nodes[0].children[0]
  assert.equal(scene.kind, 'layers'); assert.equal(scene.parts, true)
  assert.deepEqual(scene.children.map(c => c.kind), ['surface', 'motion', 'surface'], 'still under, the part, still over')
  const [under, motion, over] = scene.children
  assert.equal(under.pointer, 'onTouch', 'the bottom layer takes the picture\'s touches')
  assert.equal(under.style, 'default'); assert.equal(over.style, 'clear'); assert.equal(motion.children[0].style, 'clear')
  assert.equal(motion.style, 'swing'); assert.equal(motion.px, 0.5); assert.equal(motion.py, 0.16, 'the part turns about its own pivot')
  assert.equal(motion.trigger, 0)
  assert.deepEqual(decodeGfxOps(motion.children[0].ops).map(o => o.kind), ['line', 'circle'], 'the part\'s layer holds only its shapes')
  assert.equal(decodeGfxOps(under.ops).length, 3); assert.equal(decodeGfxOps(over.ops).length, 1)
  assert.deepEqual(scene.links, [motion.slot], 'a touch plays the part'); assert.deepEqual(under.links, [motion.slot])
  assert.deepEqual([under.pic, motion.children[0].pic, over.pic], [0, 1, 2], 'each layer is a picture of its own')
  assert(new Set([under.size, motion.children[0].size, over.size]).size === 1, 'the layers are drawn at one size, so they line up')
  // The trigger is the state's: a touch counts a swing, and the next frame carries it.
  const before = session.frame('p1', 'Pendulum', '🕰')
  session.tapSurface(before, before.token, 'onTouch', 50, 50)
  assert.equal(session.frame('p1', 'Pendulum', '🕰').nodes[0].children[0].children[1].trigger, 1)
  // As a cover picture the layers are the card's background: taken out whole, counted as one cover.
  const covered = pendulum.replace(/ui\.Column\("center", \[\n      ui\.Surface\("default"/, 'ui.Column("center", [\n      ui.Surface("cover"')
  assert.notEqual(covered, pendulum)
  const cf = new WidgetSession(compileVeraSource(covered).vbc2, 'pc', '').frame('p1', 'Pendulum', '🕰')
  const split = splitCover(cf.nodes)
  assert(split.cover !== null && split.cover.kind === 'layers' && split.cover.style === 'cover', 'the split cover picture is the background')
  assert.deepEqual(split.cover.children.map(c => c.kind === 'motion' ? c.children[0].style : c.style), ['cover', 'cover clear', 'cover clear'])
  // What the card cannot play is said so the model can fix it.
  const bad = (from, to, why, re) => {
    const src = pendulum.replace(from, to)
    assert.notEqual(src, pendulum, why)
    assert.throws(() => new WidgetSession(compileVeraSource(src).vbc2, 'bad', '').frame('p1', 'P', '🕰'), re, why)
  }
  const grouped = pendulum.replace('shapes.push(gfx.moving("swing", state.swings, 50, 16, [', 'shapes.push(gfx.group(0, 0, 0, 1, 1, [gfx.moving("swing", state.swings, 50, 16, [')
    .replace('["#fff3c4", "#e0b34a", "#8a5a14"]))\n  ]));', '["#fff3c4", "#e0b34a", "#8a5a14"]))\n  ])]));')
  assert.throws(() => new WidgetSession(compileVeraSource(grouped).vbc2, 'bad', '').frame('p1', 'P', '🕰'), /among the shapes the draw function returns/, 'a part inside a group')
  const four = 'shapes.push(gfx.moving("pop", 0, 1, 1, [gfx.circle(1, 1, 1, "ink")]));'
  bad('shapes.push(gfx.roundRect(28, 82, 44, 6, 3, "#00000033"));', four + four + four, 'four parts', /at most 3 gfx.moving parts/)
  // A ui.Motion around a picture with parts is dropped: the parts move by themselves, and the levels it took are the layers'.
  const wrapped = pendulum.replace('ui.Surface("default", 100, 100, "clock", "", "onTouch"),\n      ui.Text', 'ui.Motion("pop", 0, [ui.Surface("default", 100, 100, "clock", "", "onTouch")]),\n      ui.Text')
  assert.notEqual(wrapped, pendulum)
  const unwrapped = new WidgetSession(compileVeraSource(wrapped).vbc2, 'wrapped', '').frame('p1', 'P', '🕰').nodes[0].children[0]
  assert.equal(unwrapped.kind, 'layers'); assert.equal(unwrapped.parts, true)
  const deep = pendulum.replace('ui.Surface("default", 100, 100, "clock", "", "onTouch"),\n      ui.Text', 'ui.Column("default", [ui.Surface("default", 100, 100, "clock", "", "onTouch")]),\n      ui.Text')
  assert.notEqual(deep, pendulum)
  assert.throws(() => new WidgetSession(compileVeraSource(deep).vbc2, 'deep', '').frame('p1', 'P', '🕰'), /directly in the widget's column/)
}

// A tap finishes what it started: the card has no frames, so after a tap the app's frame handlers run until the state comes to rest -- a wheel
// stops on its prize and Spin comes back on, even when each tick asks for a vibration. A state that does not come to rest in 20 s stays as the tap left it.
{
  const wheel = fs.readFileSync(path.join(__dirname, 'examples/widget-wheel.vera'), 'utf8')
  const spinOf = src => {
    const s = new WidgetSession(compileVeraSource(src).vbc2, 'wheel', '')
    const f = s.frame('p1', 'Wheel', '🎡')
    s.tap(f, f.token, 'spin', 0)
    return s
  }
  const landed = spinOf(wheel)
  const after = landed.frame('p1', 'Wheel', '🎡')
  assert(texts(after.nodes).some(t => /^Won \d+$/.test(t)), 'the wheel stopped on a prize: ' + texts(after.nodes))
  const buttonsOf = nodes => { const out = []; const walk = n => { if (n.kind === 'button') out.push(n); n.children.forEach(walk) }; nodes.forEach(walk); return out }
  assert(buttonsOf(after.nodes)[0].enabled, 'and Spin is on again')
  // A tap on the picture finishes the same way.
  const touched = new WidgetSession(compileVeraSource(wheel).vbc2, 'wheel', '')
  const tf = touched.frame('p1', 'Wheel', '🎡')
  touched.tapSurface(tf, tf.token, 'onTouch', 50, 50)
  assert(texts(touched.frame('p1', 'Wheel', '🎡').nodes).some(t => /^Won/.test(t)), 'a touch on the wheel lands it too')
  // One that would take longer than 3 s is left spinning: the card does not play on for the person.
  const slow = spinOf(wheel.replace('let speed: number = state.speed - 900 * ms / 1000;', 'let speed: number = state.speed - 30 * ms / 1000;'))
  assert(texts(slow.frame('p1', 'Wheel', '🎡').nodes).includes('Spinning...'), 'a spin that does not stop in 20 s stays as the tap left it')
  // A frame that asks for the phone does not count either.
  const buzzing = 'import * as sdk from "std/sdk"\n' + wheel.replace('  if (state.speed <= 0) { return state; }', '  if (state.speed <= 0) { return state; }\n  sdk.call("fixture/phone/Ability/buzz", [], "buzzed", "foreground");') +
    '\nfunction buzzed(state: AppState, answer: string): AppState { return state; }\n'
  assert(texts(spinOf(buzzing).frame('p1', 'Wheel', '🎡').nodes).some(t => /^Won/.test(t)), 'what a frame asks of the phone (a vibration on each tick) is dropped and the wheel still lands')
  // The app's widget preview plays a tap the same way, in a worker (runPreviewTap): made again from the program and the state, the wheel lands.
  {
    const { runPreviewTap, PreviewTapRequest } = loadVera('VeraLiveWidget')
    const code = compileVeraSource(wheel).vbc2
    const shown = new WidgetSession(code, 'preview', '').frame('', 'Wheel', '')
    const request = Object.assign(new PreviewTapRequest(), {vbc2: code, state: '', title: 'Wheel', kind: 'button', token: shown.token, handler: 'spin', value: 0})
    const result = runPreviewTap(request)
    assert.equal(result.error, ''); assert.equal(result.rested, true)
    assert(texts(new WidgetSession(code, 'preview', result.state).frame('', 'Wheel', '').nodes).some(t => /^Won/.test(t)), 'the preview\'s tap lands the wheel')
    assert.match(runPreviewTap(Object.assign(new PreviewTapRequest(), request, {token: 'old'})).error, /changed/, 'a tap on an older frame is refused')
  }
  // Whether a tap comes to rest does not hang on the clock on the wall: a device so busy that every step takes a second still lands the
  // wheel, as the check in a worker saw it (a wall-clock limit left it spinning on a busy form extension).
  {
    const realNow = Date.now
    let fake = realNow()
    Date.now = () => (fake += 1000)
    try {
      assert(texts(spinOf(wheel).frame('p1', 'Wheel', '🎡').nodes).some(t => /^Won/.test(t)), 'a slow device lands the wheel too')
    } finally { Date.now = realNow }
    // And what settling may do is bounded by work, not time: a scene that never rests and is heavy to run stops at SETTLE_MAX_WORK.
    const { SETTLE_MAX_WORK } = loadVera('VeraLiveWidget')
    const heavy = wheel.replace('let speed: number = state.speed - 900 * ms / 1000;',
      'let k: number = 0; let junk: number = 0; while (k < 5000) { junk = junk + k; k = k + 1; }\n  let speed: number = state.speed - 0 * ms / 1000 + junk * 0;')
    assert.notEqual(heavy, wheel)
    const logs = []; const info = console.info; console.info = m => logs.push(String(m))
    let s
    try { s = spinOf(heavy) } finally { console.info = info }
    const line = logs.find(m => m.includes('VERA-WIDGET settle')) || ''
    const work = Number((/work=(\d+)/.exec(line) || [])[1])
    const steps = Number((/steps=(\d+)/.exec(line) || [])[1])
    assert(/left as tapped/.test(line) && steps < 600, 'a heavy scene stops on its work before its steps: ' + line)
    assert(work >= SETTLE_MAX_WORK && work < SETTLE_MAX_WORK * 1.2, 'within a step of the budget: ' + line)
    assert.equal(s.lastTapRested, false)
  }
}

// Drifts (gfx.drift) on a card: each a layer the card plays with the platform's Swiper in slices (CardView), sized with the picture, cover
// with it; a picture that starts with one still has a bottom layer for its touches; two at most, only among the shapes draw returns.
{
  const { splitCover, compactFrame } = loadVera('../widget/CardModel')
  const { decodeGfxOps } = loadVera('GfxPaint')
  const sky = fs.readFileSync(path.join(__dirname, 'examples/widget-sky.vera'), 'utf8')
  const f = new WidgetSession(compileVeraSource(sky).vbc2, 'sky', '').frame('p1', 'Sky', '🌌')
  assert(JSON.stringify(compactFrame(f)).length <= 8000, 'two drifts fit the frame budget')
  const split = splitCover(f.nodes)
  assert(split.cover !== null && split.cover.kind === 'layers', 'the sky is the card\'s background')
  assert.deepEqual(split.cover.children.map(c => c.kind), ['surface', 'drift', 'surface', 'drift', 'surface'], 'sky, stars, moon, clouds, haze')
  const [, stars, , clouds] = split.cover.children
  assert.deepEqual([stars.style, stars.value, stars.cover, stars.pic], ['left', 8, true, 0], 'slow stars to the left: eight slices')
  assert.deepEqual([clouds.style, clouds.value, clouds.pic], ['right', 4, 1], 'medium clouds to the right: four slices')
  assert.equal(decodeGfxOps(stars.ops)[0].kind, 'drift', 'a drift layer carries the drift, so its painter joins it up')
  assert.equal(split.cover.children[0].pointer, 'onWish', 'the bottom layer takes the touches')
  // A picture that starts with a drift gets an empty bottom layer to hold its touches.
  const first = sky.replace('  shapes.push(gfx.rect(0, 0, 100, 100, gfx.linear(0, 0, 0, 100, ["#0b1026", "#1e1b4b", "#4c1d95"])));\n', '')
    .replace('ui.Surface("cover", 100, 100, "sky", "", "onWish")', 'ui.Surface("default", 100, 100, "sky", "", "onWish")')
  const ff = new WidgetSession(compileVeraSource(first).vbc2, 'first', '').frame('p1', 'Sky', '🌌')
  const scene = ff.nodes[0].children[0]
  assert.equal(scene.children[0].kind, 'surface'); assert.equal(scene.children[0].pointer, 'onWish'); assert.equal(scene.children[1].kind, 'drift')
  assert.equal(new Set(scene.children.map(c => c.size)).size, 1, 'drift layers are drawn at the picture\'s size')
  // A drift alone keeps the ui.Motion around its picture (only moving parts move by themselves), and takes one level below the picture,
  // not two: in a row of the widget's column it fits.
  const hopping = sky.replace('ui.Surface("cover", 100, 100, "sky", "", "onWish")', 'ui.Motion("pop", state.wishes, [ui.Surface("default", 100, 100, "sky", "", "onWish")])')
  assert.notEqual(hopping, sky)
  const hf = new WidgetSession(compileVeraSource(hopping).vbc2, 'hop', '').frame('p1', 'Sky', '🌌')
  const hop = hf.nodes[0].children[0]
  assert.deepEqual([hop.kind, hop.style, hop.children[0].kind], ['motion', 'pop', 'layers'], 'the Motion around a drifting picture stays')
  const inRowSky = sky.replace('ui.Surface("cover", 100, 100, "sky", "", "onWish")', 'ui.Row("default", [ui.Surface("default", 100, 100, "sky", "", "onWish")])')
  assert.notEqual(inRowSky, sky)
  const rf = new WidgetSession(compileVeraSource(inRowSky).vbc2, 'row', '').frame('p1', 'Sky', '🌌')
  assert.equal(rf.nodes[0].children[0].children[0].kind, 'layers', 'a drifting picture in a row is drawn')
  // The draw function runs once a picture for each frame, not again to find out whether it has moving parts.
  {
    const s = new WidgetSession(compileVeraSource(hopping).vbc2, 'count', '')
    const seen = []; const run = s.vm.execute.bind(s.vm)
    s.vm.execute = (entry, args) => { if (entry === 'sky') seen.push(1); return run(entry, args) }
    s.frame('p1', 'Sky', '🌌')
    assert(seen.length <= 1, 'the draw function ran ' + seen.length + ' times for one frame')
  }
  const three = sky.replace('  return shapes;\n}\n\nfunction onWish', '  shapes.push(gfx.drift("up", "fast", [gfx.circle(5, 5, 1, "white")]));\n  return shapes;\n}\n\nfunction onWish')
  assert.notEqual(three, sky)
  assert.throws(() => new WidgetSession(compileVeraSource(three).vbc2, 'three', '').frame('p1', 'Sky', '🌌'), /at most 2 gfx.drift/)
}

// The app's tickers run too: a tap that starts a countdown (a ui.Ticker) whose end launches the rocket (frames) is finished on the card --
// the rocket of a generated app stood on its pad because only frames ran.
{
  const rocket = fs.readFileSync(path.join(__dirname, 'examples/widget-countdown-rocket.vera'), 'utf8')
  const s = new WidgetSession(compileVeraSource(rocket).vbc2, 'rocket', '')
  const f = s.frame('p1', 'Rocket', '🚀')
  s.tapSurface(f, f.token, 'onPad', 50, 50)
  assert(texts(s.frame('p1', 'Rocket', '🚀').nodes).includes('Liftoff!'), 'the countdown ran out and the rocket left: ' + texts(s.frame('p1', 'Rocket', '🚀').nodes))
}
// Many of the same: a 12 x 12 sheet of bubble wrap is one gfx.repeat, within a card picture's 60 shapes and the frame's 8000 characters;
// a tap pops the bubble under the finger. The same sheet as 144 shapes of its own is refused with a reason that names gfx.repeat, and a
// repeat that paints more than the card's 400 shapes is refused.
{
  const { compactFrame } = loadVera('../widget/CardModel')
  const { decodeGfxOps } = loadVera('GfxPaint')
  const bubbles = fs.readFileSync(path.join(__dirname, 'examples/widget-bubbles.vera'), 'utf8')
  const s = new WidgetSession(compileVeraSource(bubbles).vbc2, 'bubbles', '')
  const f = s.frame('p1', 'Bubbles', '🫧')
  const size = JSON.stringify(compactFrame(f)).length
  assert(size <= 2000, 'the sheet is a small frame: ' + size)
  const picture = f.nodes[0].children[0]
  assert.equal(picture.kind, 'surface')
  assert.equal(decodeGfxOps(picture.ops)[0].kind, 'repeat', 'the repeat rides in the frame as itself')
  assert(texts(f.nodes).includes('6 popped'))
  s.tapSurface(f, f.token, 'pop', 15, 15)
  assert(texts(s.frame('p1', 'Bubbles', '🫧').nodes).includes('7 popped'), 'a tap pops a bubble')
  const loose = bubbles.replace(/  shapes\.push\(gfx\.repeat\(12, 12, 10, 10, \[\n([\s\S]*?)\n  \]\)\);/,
    '  let k: number = 0;\n  while (k < 144) { shapes.push(gfx.circle((k % 12) * 10 + 5, math.floor(k / 12) * 10 + 5, 4.2, "#93c5fd")); k = k + 1; }')
  assert.notEqual(loose, bubbles)
  assert.throws(() => new WidgetSession(compileVeraSource(loose).vbc2, 'loose', '').frame('p1', 'Bubbles', '🫧'),
    /at most 60 shapes; this one has 150\. Many of the same .* is one gfx\.repeat\(columns, rows, dx, dy/)
  const heavy = bubbles.replace('gfx.repeat(12, 12, 10, 10, [', 'gfx.repeat(20, 20, 6, 6, [')
  assert.throws(() => new WidgetSession(compileVeraSource(heavy).vbc2, 'heavy', '').frame('p1', 'Bubbles', '🫧'),
    /paints at most 400 shapes, every copy of a gfx\.repeat counted; this one paints 807/)
}
// Review fixes on the rich pictures (PR #53).
{
  // Nesting too deep is said with what to flatten, not as a bare limit.
  const deep = 'import * as ui from "std/ui"\n@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 0}; }\n' +
    'function view(state: AppState): ui.View { return ui.Text("body", "x"); }\n' +
    'function widget(state: AppState): ui.View { return ui.Column("default", [ui.Row("default", [ui.Column("default", [ui.Row("default", ' +
    '[ui.Column("default", [ui.Text("body", "deep")])])])])]); }\n'
  assert.throws(() => new WidgetSession(compileVeraSource(deep).vbc2, 'deep', '').frame('p1', 'Deep', '🔧'),
    /widget exceeds depth 4 \((column|text) nested more than 4 levels[\s\S]*Flatten it/)
  // Two NumberStats with icons in a row of the widget's column (a fish tank's widget, refused on every answer): drawn, the icon left out.
  const stats = deep.replace(/function widget[\s\S]*$/, 'function widget(state: AppState): ui.View { return ui.AppTheme("soft", "", [ui.Column("default", [' +
    'ui.Row("split", [ui.NumberStat("accent", "Coins", state.n, "", "", 1, "", "star"), ui.NumberStat("default", "Fish", 2, "", "", 1, "", "")])])]); }\n')
  const sf = new WidgetSession(compileVeraSource(stats).vbc2, 'stats', '').frame('p1', 'Stats', '🔧')
  const kinds = []; const walk = n => { kinds.push(n.kind); n.children.forEach(walk) }; sf.nodes.forEach(walk)
  assert(!kinds.includes('icon') && texts(sf.nodes).includes('Coins'), 'the Stat keeps its caption without the icon: ' + kinds)
  // At the widget's top level it keeps its icon.
  const top = stats.replace('ui.Row("split", [', '').replace('"", 1, "", "")])])]); }', '"", 1, "", "")])]); }')
  assert.notEqual(top, stats)
  const tk = []; const walk2 = n => { tk.push(n.kind); n.children.forEach(walk2) }
  new WidgetSession(compileVeraSource(top).vbc2, 'top', '').frame('p1', 'Top', '🔧').nodes.forEach(walk2)
  assert(tk.includes('icon'), 'a Stat in the column keeps its icon')
}
{
  const { splitCover } = loadVera('../widget/CardModel')
  const { decodeGfxOps } = loadVera('GfxPaint')
  const base = (draw, widgetBody, extra = '') => 'import * as ui from "std/ui"\nimport * as gfx from "std/gfx"\n' +
    '@jsonable class AppState { n: number; z: number; ticks: number; on: boolean; }\n' +
    'function init(): AppState { return {n: 0, z: 0, ticks: 0, on: false}; }\n' +
    'function draw(state: AppState): gfx.Shape[] { return [' + draw + ']; }\n' +
    'function onTouch(state: AppState, p: gfx.Pointer): AppState { return state; }\n' + extra +
    'function view(state: AppState): ui.View { return ui.Text("body", "x"); }\n' +
    'function widget(state: AppState): ui.View { return ui.Column("center", [' + widgetBody + ']); }\n'
  const frameOf = src => new WidgetSession(compileVeraSource(src).vbc2, 'fix', '').frame('p1', 'Fix', '🔧')
  // A drawing that starts with a moving part keeps a still bottom layer: the part does not carry the background round with it.
  const wheel = 'gfx.moving("spin", state.n, 50, 50, [gfx.sector(50, 50, 40, 0, 90, "accent")]), gfx.polygon([48, 2, 52, 2, 50, 12], "ink")'
  const first = frameOf(base(wheel, 'ui.Surface("default", 100, 100, "draw", "", "onTouch")')).nodes[0].children[0]
  assert.equal(first.kind, 'layers')
  assert.deepEqual(first.children.map(c => c.kind), ['surface', 'motion', 'surface'], 'background, the part, what is over it')
  assert.equal(first.children[0].style, 'default'); assert.equal(decodeGfxOps(first.children[0].ops).length, 0)
  assert.equal(first.children[0].pointer, 'onTouch', 'the still bottom layer takes the touches')
  assert.equal(first.children[1].children[0].style, 'clear', 'the moving layer is see-through')
  assert.equal(first.children[1].children[0].pointer, '', 'and takes no touches of its own')
  // A trigger that is not a number (the square root of a negative) would play the part on every redraw: it is refused with a reason.
  assert.throws(() => frameOf('import * as math from "std/math"\n' + base(wheel.replace('state.n', 'math.sqrt(state.n - 1)'), 'ui.Surface("default", 100, 100, "draw", "", "onTouch")')),
    /gfx.moving trigger must be a number/)
  // A cover picture in a ui.Motion with more in it is not lifted out as the background, so it is refused like one in a row.
  const sky = 'gfx.rect(0, 0, 100, 100, "#123456"), gfx.circle(50, 50, 10, "accent")'
  assert.throws(() => frameOf(base(sky, 'ui.Motion("pop", 0, [ui.Surface("cover", 100, 100, "draw", "", ""), ui.Text("caption", "hi")])')),
    /alone in a ui.Motion/)
  const alone = frameOf(base(sky, 'ui.Motion("pop", 0, [ui.Surface("cover", 100, 100, "draw", "", "")]), ui.Text("caption", "hi")'))
  assert(splitCover(alone.nodes).cover !== null, 'alone in its Motion it is still the background')
  // A ticker runs at most every 16 ms in settle, as in the app: an interval of 0.01 is not 3300 ticks a step.
  const fast = 'import * as ui from "std/ui"\n@jsonable class AppState { n: number; ticks: number; on: boolean; }\n' +
    'function init(): AppState { return {n: 0, ticks: 0, on: false}; }\n' +
    'function go(state: AppState, value: number): AppState { return {n: 0, ticks: 0, on: true}; }\n' +
    'function tick(state: AppState, ms: number): AppState { if (state.ticks >= 100) { return {n: state.n, ticks: state.ticks, on: false}; } ' +
    'return {n: state.n + ms, ticks: state.ticks + 1, on: true}; }\n' +
    'function view(state: AppState): ui.View { return ui.Column("default", [ui.Ticker("default", "t", 0.01, state.on, "tick"), ui.Text("body", "x")]); }\n' +
    'function widget(state: AppState): ui.View { return ui.Column("center", [ui.NumberText("metric", state.n, "", " ms", 0), ui.Button("primary", "Go", "go", 0, true)]); }\n'
  const ts = new WidgetSession(compileVeraSource(fast).vbc2, 'fast', '')
  const tf = ts.frame('p1', 'Fast', '⏱')
  ts.tap(tf, tf.token, 'go', 0)
  assert(ts.lastTapRested, 'the hundred ticks came to rest')
  assert.deepEqual(texts(ts.frame('p1', 'Fast', '⏱').nodes).filter(t => / ms$/.test(t)), ['1600 ms'], 'each tick was told 16 ms')
}
console.log('PASS live counter: tickers in settle, drifts, settle after a tap, moving parts, cover, +/−, restore, stale/forged taps, fallback, unsafe kinds, depth/node/text caps, effects, transport, redraw, stamp')
