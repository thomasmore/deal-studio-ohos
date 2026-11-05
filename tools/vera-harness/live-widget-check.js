const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { loadVera } = require('./source-loader')
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
assert.match(card, /handler: node.action/)
assert.match(card, /node.key \+ this.token/)
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
console.log('PASS live counter: +/−, restore, stale/forged taps, fallback, unsafe kinds, depth/node/text caps, effects, transport, redraw, stamp')
