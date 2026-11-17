// Runs every fragment (and a 4-section composition) through the real VM: init(), view(), decode. Then drives
// record_log' handlers (type a note and an amount, add, remove) and checks the numbers on screen change.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const {fragments} = loadVera('VeraTemplates')
const {expandListRows} = loadVera('VeraTemplateContent')
const {composeProgram} = loadVera('VeraSectionCompose')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VirtualMachine, deserializeVbc2, decodeRuntimeValue} = loadVera('VeraInterpreter')
// Handler arguments are VM values, in the same tagged form run.js takes for a state.
const str = v => decodeRuntimeValue(['s', v])
const int = v => decodeRuntimeValue(['n', v])
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi')

const globals = new Map([['__THEME__', 'clean'], ['__HEADER_STYLE__', 'default'], ['__BANNER_SECTION__', 'hide'], ['__TITLE__', 'Check']])
function values(kind) {
  const spec = fragments().find(f => f.kind === kind), m = new Map()
  spec.slots.forEach(s => m.set(s.token, s.values[0]))
  spec.contentFields.forEach(c => m.set(c.token, c.fallback))
  spec.listFields.forEach(l => m.set(l.token, expandListRows(undefined, l).text))
  return m
}
function build(kinds) {
  const src = composeProgram(kinds, globals, kinds.map(values))
  const result = compileVeraSource(src)
  const vm = new VirtualMachine(deserializeVbc2(result.vbc2 !== undefined ? result.vbc2 : result), new UiHostEnvironment())
  return vm
}
const view = (vm, state) => decodeVeraUi(vm.execute('view', [state]))[0]
const texts = node => [node.text, node.label, node.value].filter(Boolean).concat((node.children || []).flatMap(texts))
const kindsIn = node => [node.kind].concat((node.children || []).flatMap(kindsIn))

for (const f of fragments()) {
  const vm = build([f.kind])
  const tree = view(vm, vm.execute('init'))
  assert.ok(tree && (tree.children || []).length > 0, f.kind + ': empty tree')
}
const all = build(['record_log', 'bar_chart', 'checklist', 'timeline'])
const t0 = view(all, all.execute('init'))
assert.ok(kindsIn(t0).includes('sparkline') && kindsIn(t0).includes('timeline'))

// record_log with one label and no currency: the plain running list log_entries used to be (a note and an amount, one total)
const plainValues = (() => {
  const m = values('record_log'), spec = fragments().find(f => f.kind === 'record_log')
  m.set(spec.listFields[0].token, '"Entry"'); m.set('__CURRENCY_IDX__', '')
  return m
})()
const vm = (() => {
  const result = compileVeraSource(composeProgram(['record_log'], globals, [plainValues]))
  return new VirtualMachine(deserializeVbc2(result.vbc2 !== undefined ? result.vbc2 : result), new UiHostEnvironment())
})()
let state = vm.execute('init')
const call = (name, ...args) => { state = vm.execute(name, [state, ...args]) }
const names = (() => { const t = view(vm, state); return texts(t).join('|') })()
assert.match(names, /Nothing yet/)
assert.doesNotMatch(names, /Who/, 'one label: no chooser')
call('setNote1', str('Lunch')); call('setAmount1', str('12')); call('addRecord1', int(0))
call('setNote1', str('Taxi')); call('setAmount1', str('30')); call('addRecord1', int(0))
let shown = texts(view(vm, state)).join('|')
assert.match(shown, /\|42\|/, 'total 42: ' + shown); assert.match(shown, /Taxi/); assert.match(shown, /Lunch/)
assert.ok(shown.indexOf('Taxi') < shown.indexOf('Lunch'), 'newest first')
call('removeLastRecord1', int(0))
shown = texts(view(vm, state)).join('|')
assert.match(shown, /\|12\|/); assert.doesNotMatch(shown, /Taxi/)
// smokeRun: every fragment starts, draws something and survives every handler tapped; a program that traps in view(), or
// draws nothing, does not pass
const {smokeRun} = loadVera('VeraSmoke')
for (const f of fragments()) {
  const src = composeProgram([f.kind], globals, [values(f.kind)])
  const r = smokeRun(compileVeraSource(src))
  assert.equal(r, '', f.kind + ': ' + r)
}
const trap = `import * as ui from "std/ui"

@jsonable
class AppState {
  items: number[];
}

function init(): AppState {
  let empty: number[] = [];
  return {items: empty};
}

function view(state: AppState): ui.View {
  let v: number = state.items[3];
  return ui.Column("default", [ui.Text("body", ui.numberToString(v))]);
}`
const bad = smokeRun(compileVeraSource(trap))
assert.ok(bad.length > 0)
const empty = `import * as ui from "std/ui"

@jsonable
class AppState {
  n: number;
}

function init(): AppState {
  return {n: 0};
}

function view(state: AppState): ui.View {
  return ui.Column("default", []);
}`
assert.match(smokeRun(compileVeraSource(empty)), /drew an empty screen/)
console.log('template-run-check: ok (' + fragments().length + ' fragments)')

// A record_log in a widget (the global __WIDGET__) is the same program with a smaller form: no note, no clear-all; it still adds and removes.
{
  const widgetGlobals = new Map(globals); widgetGlobals.set('__WIDGET__', 'true')
  const run = g => {
    const result = compileVeraSource(composeProgram(['record_log'], g, [values('record_log')]))
    return new VirtualMachine(deserializeVbc2(result.vbc2 !== undefined ? result.vbc2 : result), new UiHostEnvironment())
  }
  const full = run(globals), small = run(widgetGlobals)
  const fullText = texts(view(full, full.execute('init'))).join('|'), smallText = texts(view(small, small.execute('init'))).join('|')
  assert.match(fullText, /Note/); assert.match(fullText, /Start over/)
  assert.doesNotMatch(smallText, /Note/, 'a widget form has no note'); assert.doesNotMatch(smallText, /Start over/)
  assert.match(smallText, /Add/); assert.match(smallText, /Remove last/)
  let s = small.execute('init')
  s = small.execute('setAmount1', [s, str('12')]); s = small.execute('addRecord1', [s, int(0)])
  assert.match(texts(view(small, s)).join('|'), /12/, 'a widget still adds a record')
}
console.log('template-run: record_log widget view ok')

// A widget with more than one block in it is one window of tabs: only the open pane is drawn, and the handler opens another.
{
  const widgetGlobals = new Map(globals); widgetGlobals.set('__WIDGET__', 'true'); widgetGlobals.set('__HEADER_STYLE__', 'none')
  const kinds = ['record_log', 'checklist', 'bar_chart']
  const tabSource = composeProgram(kinds, widgetGlobals, kinds.map(values))
  const result = compileVeraSource(tabSource)
  const vm = new VirtualMachine(deserializeVbc2(result.vbc2 !== undefined ? result.vbc2 : result), new UiHostEnvironment())
  let state = vm.execute('init')
  const tabs = node => node.kind === 'tabs' ? node : (node.children || []).map(tabs).find(Boolean)
  const t = tabs(view(vm, state))
  assert.ok(t, 'the widget is a ui.Tabs')
  assert.deepEqual(t.options, ['Record log', 'Checklist', 'Bar chart'])
  assert.equal(t.eventValue, 0); assert.equal(t.children.length, 3)
  assert.equal(t.children[0].kind, 'screen'); assert.equal(t.children[0].screenId, 'tabPane0')
  assert.equal(t.children[1].children.length, 0, 'inactive panes are not constructed')
  assert.equal(smokeRun(result), '', 'legacy Chat tabs use the same named-view reachability gate')
  const stuckTabs = compileVeraSource(tabSource.replace('return {paneTab: index', 'return {paneTab: state.paneTab'))
  assert.match(smokeRun(stuckTabs), /No executed UI path reached: tabPane1, tabPane2/, 'broken legacy tab navigation is rejected')
  state = vm.execute('setPaneTab', [state, int(1)])
  assert.equal(tabs(view(vm, state)).eventValue, 1, 'the handler opens another pane')
  state = vm.execute('addRecord1', [vm.execute('setAmount1', [state, str('12')]), int(0)])
  assert.equal(tabs(view(vm, state)).eventValue, 1, 'a handler of a block keeps the pane open')
  // One block alone is not tabbed.
  const one = compileVeraSource(composeProgram(['record_log'], widgetGlobals, [values('record_log')]))
  const vm1 = new VirtualMachine(deserializeVbc2(one.vbc2 !== undefined ? one.vbc2 : one), new UiHostEnvironment())
  assert.ok(!tabs(view(vm1, vm1.execute('init'))), 'one block: no tabs')
}
console.log('template-run: widget tabs ok')

// An itinerary has its own start time (hours and minutes) and gap; changing them moves the stops' windows.
{
  const vm = build(['itinerary'])
  let s = vm.execute('init')
  const find = (node, kind) => node.kind === kind ? node : (node.children || []).map(c => find(c, kind)).find(Boolean)
  const t0 = view(vm, s)
  assert.ok(find(t0, 'timefield'), 'the day has a start time field')
  const before = texts(t0).join('|')
  s = vm.execute('setStart1', [s, int(600)])
  const after = texts(view(vm, s)).join('|')
  assert.notEqual(before, after, 'a later start moves the stops')
  assert.match(after, /10:00/)
}
console.log('template-run: itinerary start time ok')
