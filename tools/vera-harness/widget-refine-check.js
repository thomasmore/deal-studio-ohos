const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path')
const {loadVera} = require('./source-loader')
const {compileVeraSource, widgetRefinementError, spliceWidget} = loadVera('VeraCompiler')
const {smokeRun} = loadVera('VeraSmoke')
const {widgetRefinementPrompt, validateWidgetRefinement, widgetRepairNote, checkWidget} = loadVera('VeraWidgetRefine')
const {WidgetSession} = loadVera('VeraLiveWidget')
const source = fs.readFileSync(path.join(__dirname,'examples/widget-counter.vera'),'utf8')
// Standalone fullscreen base, not a view delegating to widget.
const base = source.replace('function widget(', 'function compact(').replace('return widget(state);','return compact(state);')
const addition = '\nfunction widget(state: AppState): ui.View { return compact(state); }'
const candidate = base + addition
const compiled = compileVeraSource(candidate)
assert.equal(widgetRefinementError(base,candidate), '')
assert.equal(widgetRefinementError(base,'// comment\n' + candidate.replace('count: 0','count : 0')), '')
for (const [from,to,name] of [['count: number','count: string','AppState'],['count: 0','count: 10','init'],['state.count + value','state.count - value','change'],['return compact(state);','return ui.Text("body", "changed");','view']]) {
  assert.match(widgetRefinementError(base,candidate.replace(from,to)),new RegExp(name))
}
assert.match(widgetRefinementError(base,base),/add function widget/)
assert.equal(validateWidgetRefinement(base,candidate,compiled.vbc2), '')
assert.equal(smokeRun(compiled),'')
for (const altered of [candidate.replace('function widget(state: AppState)', 'async function widget(state: AppState)'),candidate.replace('function widget(state: AppState)', 'function widget(state: number)'),candidate.replace('function widget(state: AppState): ui.View', 'function widget(state: AppState): AppState')]) {
  assert.throws(()=>compileVeraSource(altered),/E2115/)
}
// The signature error is at the widget's own line, not the whole program's.
{
  const altered = candidate.replace('function widget(state: AppState)', 'async function widget(state: AppState)')
  let diagnostics = []
  try { compileVeraSource(altered) } catch (e) { diagnostics = e.diagnostics }
  const d = diagnostics.find(x => x.code === 'E2115')
  assert(d, 'E2115'); assert.equal(d.span.start.line, altered.split('\n').findIndex(l => l.includes('async function widget')) + 1)
}
const unsafe = candidate.replace('return compact(state); }\nfunction widget','return compact(state); }\nfunction widget')
  .replace('function widget(state: AppState): ui.View { return compact(state); }','function widget(state: AppState): ui.View { return ui.Image("default", "url", "alt"); }')
assert.match(smokeRun(compileVeraSource(unsafe)),/home-screen widget [\s\S]*Not card-safe/)
const saved = new WidgetSession(compiled.vbc2,'v','')
let frame = saved.frame('p','App','')
saved.tap(frame,frame.token,'change',1)
assert.equal(validateWidgetRefinement(base,candidate,compiled.vbc2,saved.encodedState()),'')
const prompt = widgetRefinementPrompt(), {CATALOG} = loadVera('VeraUiCatalog')
for (const component of CATALOG) {
  assert.equal(prompt.includes('  ui.' + component.name + '('),component.card,component.name)
}
assert.match(prompt,/100000 VM steps/)
assert.match(prompt,/8000 UTF-16/)
// What a widget is: the same state, what the person asked for, only the few things that matter.
assert.match(prompt,/draws the very state view\(state\) draws/)
assert.match(prompt,/request says what it should show/)
assert.match(prompt,/one to three figures/)
assert.match(prompt,/at most two buttons/)
// The reply's rewrite of an existing declaration is not taken; its widget, new helpers and new imports are.
const rewritten = 'import * as math from "std/math"\n' + base.replace('state.count + value', 'state.count + value * 2') +
  '\nfunction twice(n: number): number { return n * 2; }' + addition
const spliced = spliceWidget(base, rewritten)
assert.equal(widgetRefinementError(base, spliced), '')
assert.match(spliced, /state\.count \+ value \}/)
assert.doesNotMatch(spliced, /value \* 2/)
assert.match(spliced, /function twice/)
assert.match(spliced, /^import \* as math from "std\/math"/)
assert.equal(validateWidgetRefinement(base, spliced, compileVeraSource(spliced).vbc2), '')
// A widget already there is replaced; a reply that does not parse is left for the compiler.
assert.equal((spliceWidget(candidate, base + '\nfunction widget(state: AppState): ui.View { return ui.Text("body", "new"); }').match(/function widget/g) || []).length, 1)
assert.equal(spliceWidget(base, 'not a program {'), 'not a program {')
// A missing field is explained: the app's state is kept as it is.
assert.match(widgetRepairNote('3:5 E2031 class AppState has no field doneToday'), /cannot add fields to the state/)
assert.equal(widgetRepairNote('3:5 E2036 expected 5 arguments, found 4'), '3:5 E2036 expected 5 arguments, found 4')
// widgetRefresh: its own signature (E2113); one that keeps changing the state is refused; it belongs to the widget.
const daily = fs.readFileSync(path.join(__dirname,'examples/widget-daily.vera'),'utf8')
const dailyBase = daily.replace(/function widget\(state[\s\S]*$/, '')
assert.equal(validateWidgetRefinement(dailyBase, daily, compileVeraSource(daily).vbc2), '')
assert.throws(() => compileVeraSource(daily.replace('function widgetRefresh(state: AppState): AppState', 'function widgetRefresh(state: AppState, v: number): AppState')), /E2113/)
const adds = daily.replace('return state; }', 'return {count: state.count + 1, day: state.day}; }')
assert.match(validateWidgetRefinement(dailyBase, adds, compileVeraSource(adds).vbc2), /changed the state again/)
assert.doesNotMatch(spliceWidget(daily, dailyBase + 'function widget(state: AppState): ui.View { return ui.Text("body", "x"); }'), /widgetRefresh/)
assert.match(prompt, /widgetRefresh/)
// A widget is a glance: a button per item is refused with the reason, for the next attempt.
const crowded = base + '\nfunction widget(state: AppState): ui.View { return ui.Column("default", [ui.Button("default", "+1", "change", 1, true), ' +
  'ui.Button("default", "+2", "change", 2, true), ui.Button("default", "+3", "change", 3, true)]); }'
assert.match(validateWidgetRefinement(base, crowded, compileVeraSource(crowded).vbc2), /3 buttons; a widget has at most 2/)
// An app whose own screen is drawn by widget(state) would change with a new widget: Make widget is refused for it, before and
// after the model answers.
{
  const {appUsesWidgetError} = loadVera('VeraCompiler')
  assert.match(appUsesWidgetError(source), /own view calls widget\(\)/)
  assert.equal(appUsesWidgetError(base), '')
  assert.equal(appUsesWidgetError(candidate), '', 'the widget calling its own helpers is the widget\'s business')
  const viaRefresh = base + '\nfunction widgetRefresh(state: AppState): AppState { return state; }\nfunction reset(state: AppState, v: number): AppState { return widgetRefresh(state); }'
  assert.match(appUsesWidgetError(viaRefresh), /own reset calls widgetRefresh\(\)/)
  assert.match(widgetRefinementError(source, source.replace('ui.Text("caption", "COUNTER"),', '')), /own view calls widget/)
}
console.log('PASS widget refinement: additive preservation, signature, catalogue prompt, smoke/repair diagnostics, saved-state validation, glance limits, splice, widgetRefresh')

// Make widget writes only the widget (agent/AgentWidget.ets): the program is shown, never written again; a failing answer goes
// back with its reason and the next one is taken.
;(async () => {
  const {AgentHost} = loadVera('agent/AgentHost')
  const W = loadVera('agent/AgentWidget')
  const only = widgetRefinementPrompt(false)
  assert.match(only, /Answer with only what the widget adds/)
  assert.doesNotMatch(only, /Return the complete program/)
  const asked = []
  const replies = [
    'function widget(state: AppState): ui.View { return ui.Column("default", [ui.Text("body", "Count"), ui.Button("default", "+", "change", 1, true), ' +
      'ui.Button("default", "+2", "change", 2, true), ui.Button("default", "+3", "change", 3, true)]); }',
    '```vera\nfunction widget(state: AppState): ui.View { return compact(state); }\n```'
  ]
  const host = new AgentHost()
  host.language = 'Language.\n{{UI_CATALOG}}\nVISUAL COMPOSITION\nfull screens\nClock -- time. rest'
  host.askCode = async (system, user, budget, think) => { asked.push({system, user, budget, think}); return replies.shift() }
  const made = await W.writeWidget(base, 'the count and a plus button', 'a counter', '', host)
  assert.equal(made.failed, ''); assert.equal(made.attempts, 2)
  assert.equal(made.source, spliceWidget(base, 'function widget(state: AppState): ui.View { return compact(state); }'))
  assert.equal(validateWidgetRefinement(base, made.source, made.vbc2), '')
  assert(asked[0].system.includes('ui.NumberText(') && !asked[0].system.includes('ui.Image('), 'only the card kinds are shown')
  assert(!asked[0].system.includes('full screens'), 'the advice on full screens is left out')
  assert(asked[0].budget <= W.WIDGET_TOKENS && !asked[0].think)
  assert.match(asked[0].user, /The home-screen widget should show: the count and a plus button/)
  assert.match(asked[1].user, /3 buttons; a widget has at most 2/)
  const none = new AgentHost(); none.language = host.language
  none.askCode = async () => 'function helper(): number { return 1; }'
  const refused = await W.writeWidget(base, 'x', 'a counter', '', none)
  assert.equal(refused.source, ''); assert.equal(refused.attempts, 3); assert.match(refused.failed, /no function widget/)
  console.log('PASS widget written alone: card kinds only, spliced into the program, failure fed back, three answers at most')
})().catch(e => { console.error(e); process.exit(1) })

// A program with a live source: widgetRefresh may ask for Vera.Source.fetch (and only that), its handler takes a failure and
// still draws; the address cannot be built from the state (E2114).
{
  const live = fs.readFileSync(path.join(__dirname, 'examples/widget-source.vera'), 'utf8')
  const c = compileVeraSource(live)
  assert.equal(smokeRun(c), '')
  assert.equal(checkWidget(c.vbc2), '')
  const other = live.replace('function widgetRefresh(state: AppState): AppState { return fetchNow(state, time.nowSeconds()); }',
    'function widgetRefresh(state: AppState): AppState { sdk.call("ohos.vibrator.startVibration", ["duration", "100"], "onSource"); return state; }')
  assert.notEqual(other, live)
  assert.match(checkWidget(compileVeraSource(other).vbc2), /phone action/)
  const built = live.replace('["url", "https://iss.moex.com', '["url", state.note + "https://iss.moex.com')
  assert.throws(() => compileVeraSource(built), /E2114/)
  assert.match(widgetRefinementPrompt(false), /Vera\.Source\.fetch/)
  console.log('PASS live source on a widget: widgetRefresh may fetch the source only, its address is literal')
}

// An import closed with a semicolon, as TypeScript writes one, is taken; any other answer that does not parse is sent back with
// the parser's own message, not a guess.
;(async () => {
  const {AgentHost} = loadVera('agent/AgentHost')
  const W = loadVera('agent/AgentWidget')
  const host = new AgentHost(), asked = []
  host.language = 'Language.\n{{UI_CATALOG}}\nVISUAL COMPOSITION\nClock -- time. rest'
  const replies = ['function widget(state: AppState): ui.View { return compact(state) }}',
    'import * as time from "std/time";\nfunction widget(state: AppState): ui.View { return compact(state); }']
  host.askCode = async (system, user) => { asked.push(user); return replies.shift() }
  const made = await W.writeWidget(base, 'the count', 'a counter', '', host)
  assert.equal(made.failed, ''); assert.equal(made.attempts, 2)
  assert.match(asked[1], /The answer does not parse: /)
  assert.doesNotMatch(asked[1], /has no function widget/)
  assert.match(made.source, /^import \* as time from "std\/time"$/m)
  console.log('PASS widget answers: an import with a semicolon is taken, a parse error is passed on as it is')
})().catch(e => { console.error(e); process.exit(1) })
