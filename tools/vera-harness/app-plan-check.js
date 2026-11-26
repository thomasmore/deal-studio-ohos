// The multi-screen handoff and shared writer. Real compiler/VM, mocked model/selector/SDK lookups: no paid calls.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const np = loadVera('NeedsPlan')
const {AgentHost} = loadVera('agent/AgentHost')
const {AgentRequest} = loadVera('agent/VeraAgent')
const {RouteRequest, buildScreen} = loadVera('agent/VeraBuildRoute')
const {compileVeraSource} = loadVera('VeraCompiler')
const {smokeRun} = loadVera('VeraSmoke')
const {VirtualMachine, deserializeVbc2, VeraNumberValue, VeraStringValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi')
const good = fs.readFileSync(path.join(__dirname, 'fixtures/app-plan/notes-section.txt'), 'utf8')
function plan() {
  return {title: 'Notes', inputs: [], constants: [], needs: [
    {id: 'notes', type: 'entries', label: 'Notes', fields: [{id: 'text', label: 'Note', kind: 'text'}]},
    {id: 'overview', type: 'other', what: 'Overview of the same notes, then open the notes list', uses: ['notes']},
    {id: 'editor', type: 'other', what: 'An isolated editor draft with Save, Cancel and Back', uses: ['notes']}
  ], screens: [{id: 'home', needs: ['overview']}, {id: 'notes', needs: ['notes']}, {id: 'editor', needs: ['editor']}],
  startScreen: 'home', transitions: [{from: 'home', to: 'notes', on: 'Open notes'},
    {from: 'notes', to: 'editor', on: 'Add or edit', record: 'notes.id'}, {from: 'editor', to: 'notes', on: 'Save, Cancel or Back'}]}
}
function parse(p) { return np.parseNeedsPlan(JSON.stringify(p)) }
function hostFor(p = plan(), code = good) {
  const host = new AgentHost(), seen = {plans: [], code: [], choices: [], lookups: [], fills: 0, holes: 0}
  host.language = 'VERA language fixture'
  host.askPlan = async (_system, user, onText) => { seen.plans.push(user); const json = JSON.stringify(typeof p === 'function' ? p(seen.plans.length) : p); onText(json); return json }
  host.askJev = async body => { const q = JSON.parse(body).questions; seen.choices.push(Object.keys(q)); assert.ok(Object.keys(q).every(k => /^(does|blocking)\./.test(k)), 'must not choose flat parts'); return '' }
  host.askCode = async (system, user, budget, think) => { seen.code.push({system, user, budget, think}); return typeof code === 'function' ? code(seen.code.length) : code }
  host.lookup = async need => { seen.lookups.push(need); return '' }
  host.fillBlocks = async () => { seen.fills++; throw Error('must not fill flat sections') }
  host.onHole = () => { seen.holes++ }
  return {host, seen}
}
async function run(host, prompt = 'Notes with a home overview, a notes list and an editor with Save and Cancel') {
  return buildScreen(Object.assign(new RouteRequest(), {agent: Object.assign(new AgentRequest(), {prompt})}), host)
}
async function main() {
  let checks = 0
  const parsed = parse(plan()); assert.ok(parsed); assert.equal(parsed.screens.length, 3); assert.deepEqual(parsed.needs[1].uses, ['notes']); checks++
  const legacy = parse({title: 'Simple', needs: [{type: 'entries', label: 'Items'}]}); assert.ok(legacy); assert.equal(legacy.screens.length, 0); assert.equal(legacy.needs[0].id, 'need0'); checks++
  for (const mutate of [
    p => p.screens.push(p.screens[0]), p => p.needs.push(p.needs[0]), p => delete p.needs[0].id,
    p => p.screens[0].id = 'bad-id', p => p.screens[0].needs = ['missing'], p => p.startScreen = 'missing',
    p => p.transitions[0].to = 'missing', p => p.transitions[1].record = 'missing.id',
    p => p.transitions[1].record = 7,
    p => p.transitions = [], p => p.needs[1].uses = ['missing'], p => p.needs[1].uses = [3],
    p => p.needs[1].uses = ['overview'], p => p.screens = 'home', p => p.needs = null
  ]) { const p = plan(); mutate(p); assert.equal(parse(p), null); checks++ }
  for (const screens of [[], [{id:'main', needs:['missing']}]] ) {
    const single = parse({title:'Timer', screens, startScreen:'missing', transitions:'ignored', presentation:'ignored',
      needs:[{type:'countdown',label:'Countdown',uses:['missing']}]})
    assert.ok(single); assert.equal(single.screens.length, 0); assert.deepEqual(single.needs[0].uses, []); checks++
  }
  for (const [mutate, expected] of [
    [p => delete p.needs[0].id, /missing\/invalid id/],
    [p => p.needs[1].uses = ['missing'], /dangling\/self uses reference: missing/]
  ]) {
    const invalid = plan(); mutate(invalid); const problems = []
    assert.equal(np.parseNeedsPlan(JSON.stringify(invalid), problems), null); assert.match(problems.join(';'), expected); checks++
  }
  const bare = plan(); bare.transitions[1].record = 'notes'; assert.equal(parse(bare).transitions[1].record, 'notes.id'); checks++
  const badRecord = plan(); badRecord.transitions[1].record = 'notes.title'; assert.equal(parse(badRecord), null); checks++
  const multiple = plan(); multiple.needs.push({id: 'tasks', type: 'entries', label: 'Tasks', fields: []}); multiple.screens[0].needs.push('tasks')
  const full = parse(multiple); assert.equal(full.needs.filter(n => n.type === 'entries').length, 2); assert.equal(np.planningSketch(full).list, null); checks++
  const withExtra = plan(); withExtra.needs.push({id: 'extra', type: 'content', what: 'Unasked advice', from: 'a quote nobody asked for'}); withExtra.screens[0].needs.push('extra'); withExtra.needs[1].uses.push('extra')
  const filtered = parse(withExtra); assert.equal(np.dropUnasked(filtered, 'Notes with an editor').length, 1); assert.ok(!filtered.screens[0].needs.includes('extra')); assert.deepEqual(filtered.needs[1].uses, ['notes']); checks++
  const {host, seen} = hostFor(); const built = await run(host); assert.equal(built.kind, 'agent', built.reason); assert.ok(built.agent.vbc2, built.agent.errors); assert.equal(seen.plans.length, 1); assert.equal(seen.code.length, 1); assert.equal(seen.holes, 1); assert.equal(seen.fills, 0); assert.equal(built.agent.record, null); assert.equal(built.agent.composed.parsed, null); assert.equal(built.agent.blocks.length, 0); assert.equal(built.agent.composed.appPlan.screens.length, 3); checks++
  assert.match(seen.code[0].system, /Declaring a handler is not enough/); assert.match(seen.code[0].system, /Screen\(/); assert.match(seen.code[0].system, /BackHandler/); assert.match(seen.code[0].user, /"uses":\["notes"\]/); assert.doesNotMatch(seen.code[0].system, /no second view/); assert.ok(seen.code[0].budget < 3 * 8000); checks++
  assert.match(seen.code[0].system, /date drafts start at time\.daysSinceEpoch\(\)/)
  assert.match(seen.code[0].system, /reset to time\.daysSinceEpoch\(\) after Add\/Save\/reset/)
  assert.match(seen.code[0].system, /Editing copies the saved date unchanged/); checks++
  const recipes = hostFor()
  assert.equal((await run(recipes.host, 'Scandinavian recipes with a home overview, a notes list and an editor')).kind, 'agent')
  assert.equal(recipes.seen.plans.length, 1); checks++
  const cameraWriter = good.replace('ui.Text("heading", "Edit note"),',
    'ui.Text("heading", "Edit note"), ui.Camera("default", "c_type", "back", "Capture"),')
  const cameraHost = hostFor(attempt => {
    const draft = plan()
    if (attempt > 1) { draft.needs.push({id: 'photo', type: 'other', what: 'Photograph a page with a live camera preview'}) }
    if (attempt > 2) { draft.screens[2].needs.push('photo') }
    return draft
  }, cameraWriter)
  const cameraBuilt = await run(cameraHost.host, 'Notes with a home overview, a notes list and an editor to photograph a page')
  assert.equal(cameraBuilt.kind, 'agent', cameraBuilt.reason)
  assert.equal(cameraHost.seen.plans.length, 3)
  assert.match(cameraHost.seen.plans[1], /camera need.*screen/)
  assert.deepEqual(cameraBuilt.agent.composed.appPlan.screens[2].needs, ['editor', 'photo'])
  assert.match(cameraHost.seen.code[0].user, /Photograph a page with a live camera preview/); checks++
  const cameraVm = new VirtualMachine(deserializeVbc2(cameraBuilt.agent.vbc2), new UiHostEnvironment())
  const cameraCount = node => (node.kind === 'camera' ? 1 : 0) + node.children.reduce((count, child) => count + cameraCount(child), 0)
  const cameraCountOn = state => decodeVeraUi(cameraVm.execute('view', [state])).reduce((count, node) => count + cameraCount(node), 0)
  const cameraHome = cameraVm.execute('init')
  const cameraList = cameraVm.execute('c_list', [cameraHome, new VeraNumberValue(0)])
  const cameraEditor = cameraVm.execute('c_edit', [cameraList, new VeraNumberValue(0)])
  assert.deepEqual([cameraCountOn(cameraHome), cameraCountOn(cameraList), cameraCountOn(cameraEditor)], [0, 0, 1]); checks++
  const compiled = compileVeraSource(built.agent.source); assert.equal(smokeRun(compiled), ''); const env = new UiHostEnvironment(); const vm = new VirtualMachine(deserializeVbc2(compiled.vbc2), env); let state = vm.execute('init')
  const field = key => state.fields.get('c_' + key)
  const tap = (handler, value = 0) => { state = vm.execute(handler, [state, typeof value === 'string' ? new VeraStringValue(value) : new VeraNumberValue(value)]) }
  tap('c_edit'); tap('c_type', 'first'); const beforeSave = state; assert.equal(field('notes').elements.length, 0); tap('c_save'); assert.equal(field('notes').elements.length, 1); assert.equal(beforeSave.fields.get('c_notes').elements.length, 0); assert.equal(field('notes').elements[0].fields.get('text').value, 'first'); checks++
  tap('c_edit', 1); tap('c_type', 'discard me'); assert.equal(field('notes').elements[0].fields.get('text').value, 'first'); tap('c_cancel'); tap('c_edit', 1); assert.equal(field('draft').value, 'first'); checks++
  tap('c_cancel'); tap('c_edit'); assert.equal(field('draft').value, ''); tap('c_type', 'second'); tap('c_save'); tap('c_remove', 1); tap('c_edit', 2); tap('c_type', 'changed'); tap('c_save'); assert.equal(field('notes').elements[0].fields.get('id').value, 2); assert.equal(field('notes').elements[0].fields.get('text').value, 'changed'); checks++
  tap('c_edit', 2); tap('c_remove', 2); tap('c_save'); assert.equal(field('notes').elements.length, 0); for (const id of ['home', 'notes', 'editor']) assert.equal(decodeVeraUi(vm.execute('c_view_' + id, [state]))[0].kind, 'screen'); checks++
  const bad = good.replaceAll('c_view_editor', 'c_view_missing'); const failedHost = hostFor(plan(), bad); const failed = await run(failedHost.host); assert.equal(failed.kind, 'not-built'); assert.equal(failedHost.seen.plans.length, 1); assert.equal(failedHost.seen.code.length, 3); assert.equal(failed.agent.whole, null); assert.match(failed.reason, /Missing planned screen function/); checks++
  const invalid = plan(); invalid.screens[0].needs = ['missing']; const invalidHost = hostFor(invalid); const unplanned = await run(invalidHost.host); assert.equal(unplanned.kind, 'not-built'); assert.equal(invalidHost.seen.plans.length, 3); assert.equal(invalidHost.seen.code.length, 0); assert.equal(unplanned.agent.composed.appPlanFailed, true); checks++
  const trap = good.replace('ui.TextField("default", "Note", state.c_draft, "c_type")', 'ui.Text("body", state.c_notes[0].text)'); const trapped = await run(hostFor(plan(), trap).host); assert.equal(trapped.kind, 'not-built'); assert.match(trapped.reason, /empty\/missing selection/); checks++
  const emptyActive = good.replace('function c_view_editor(state: AppState): ui.View {', 'function c_view_editor(state: AppState): ui.View {\n  if (state.c_screen === "editor") { return ui.Screen("editor", []); }')
  const empty = await run(hostFor(plan(), emptyActive).host); assert.equal(empty.kind, 'not-built'); assert.match(empty.reason, /active planned screen is empty/i); checks++
  const refine = loadVera('VeraAppRefine')
  const flattened = built.agent.source.replace(/function c_view_notes[\s\S]*?(?=function c_view_editor)/, '').replace(/function c_view_editor[\s\S]*?(?=function view)/, '').replace(/if \(state.c_screen === "notes"\)[\s\S]*?else \{ sections.push\(c_view_home\(state\)\); \}/, 'sections.push(c_view_home(state));')
  const flat = compileVeraSource(flattened)
  assert.deepEqual(refine.removedAppScreens(built.agent.source, flat), ['notes', 'editor'])
  assert.match(refine.smokeRefinement(flat, built.agent.source), /Missing planned screen function/); checks++
  assert.equal(refine.smokeRefinement(flat, built.agent.source, ['notes', 'editor']), ''); assert.match(refine.appRefinementNote(built.agent.source), /c_view_editor/); checks++
  for (const separator of [' ', ' // declaration separator\n']) {
    const sameLine = built.agent.source.replace(/}\s*function /g, '}' + separator + 'function ')
    assert.deepEqual(refine.sourceScreenIds(sameLine), ['home', 'notes', 'editor'])
    assert.deepEqual(refine.removedAppScreens(sameLine, flat), ['notes', 'editor'])
    assert.match(refine.smokeRefinement(flat, sameLine), /Missing planned screen function/); checks++
  }
  const fakeDeclarations = built.agent.source + '\n// function c_view_fake(s: AppState): ui.View {}\n'
  assert.deepEqual(refine.sourceScreenIds(fakeDeclarations), ['home', 'notes', 'editor']); checks++
  assert.deepEqual(refine.sourceScreenIds('function view( version-skew syntax'), [])
  assert.equal(refine.appRefinementNote('function view( version-skew syntax'), '')
  assert.deepEqual(refine.removedAppScreens('function view( version-skew syntax', flat), [])
  assert.equal(refine.smokeRefinement(flat, 'function view( version-skew syntax'), ''); checks++
  const iconCode = good.replace('ui.Button("primary", "Notes", "c_list", 0, true)', 'ui.IconButton("default", "plus", "Notes", "c_list", 0, true)')
  const iconHost = hostFor(plan(), iconCode); const iconBuilt = await run(iconHost.host)
  assert.equal(iconBuilt.kind, 'agent', iconBuilt.reason); assert.equal(iconHost.seen.code.length, 1); checks++
  const unbound = good.replace('    children.push(ui.Button("secondary", "Remove", "c_remove", note.id, true));', '')
  assert.notEqual(unbound, good)
  const dead = await run(hostFor(plan(), unbound).host); assert.equal(dead.kind, 'not-built'); assert.match(dead.reason, /c_remove has no control or caller reference/); checks++
  const retryHost = hostFor(plan(), n => n === 1 ? unbound : good); const retried = await run(retryHost.host); assert.equal(retried.kind, 'agent', retried.reason); assert.equal(retryHost.seen.code.length, 2); checks++
  const custom = loadVera('agent/AgentCustom'); const verification = new custom.CustomRequest(); verification.appPlan = parse(plan()); verification.needs = ['Delete a record']; assert.match(JSON.parse(custom.verifyRequest(verification, good)).state, /local AppState changes/); checks++
  const blockedNavigation = good.replace('"Notes", "c_list", 0, true', '"Notes", "c_list", 0, false')
  const reachRetry = hostFor(plan(), n => n === 1 ? blockedNavigation : good)
  const reachRepaired = await run(reachRetry.host)
  assert.equal(reachRepaired.kind, 'agent', reachRepaired.reason); assert.equal(reachRetry.seen.code.length, 2)
  assert.match(reachRetry.seen.code[1].user, /Screen reachability check failed/)
  assert.match(reachRetry.seen.code[1].user, /notes, editor/); checks++
  // Same shared writer and gate in Chat; presentation does not create another store or pipeline.
  const chatHost = hostFor()
  const chatBuilt = await buildScreen(Object.assign(new RouteRequest(), {agent: Object.assign(new AgentRequest(), {prompt:'Notes with overview and editor', widget:true})}), chatHost.host)
  assert.equal(chatBuilt.kind, 'agent', chatBuilt.reason); assert.ok(chatBuilt.agent.vbc2)
  assert.equal(chatBuilt.agent.screen.widget, true); assert.equal(chatBuilt.agent.composed.appPlan.compact, true)
  assert.match(chatHost.seen.code[0].system, /compact Chat widget/); assert.equal(chatHost.seen.code.length, 1); checks++
  const flatPlan = {title:'Books', needs:[{type:'entries',id:'books',label:'Books',fields:[]},{type:'content',id:'details',what:'Tapping a book opens its detail screen where the borrower is edited',from:'open a book'}]}
  assert.match(np.navigationPlanProblem(parse(flatPlan)), /no multi-view metadata/)
  assert.equal(np.navigationPlanProblem(parse({title:'Inline',needs:[{type:'entries',label:'Books',fields:[]},{type:'content',what:'Edit the borrower inline'}]})), ''); checks++
  const external = {title:'Settings', needs:[{id:'settings', type:'action', when:'Tap Settings', what:"Open the phone's settings screen", on:'button', asked:true, from:'Open settings'}]}
  assert.equal(np.navigationPlanProblem(parse(external)), '')
  let externalPlans = 0
  const externalResult = await loadVera('NeedsChoose').composeNeeds('Open settings', async () => { externalPlans++; return JSON.stringify(external) }, async () => '')
  assert.equal(externalPlans, 1); assert.equal(externalResult.appPlanFailed, false); assert.equal(externalResult.appPlan, null); checks++
  const plannedAgain = hostFor(n => n === 1 ? flatPlan : plan())
  const afterPlanRepair = await run(plannedAgain.host, 'open a book')
  assert.equal(afterPlanRepair.kind, 'agent', afterPlanRepair.reason); assert.equal(plannedAgain.seen.plans.length, 2)
  assert.match(plannedAgain.seen.plans[1], /no multi-view metadata/); checks++
  let flatCalls = 0
  const flatFallback = await loadVera('NeedsChoose').composeNeeds('open a book', async () => { flatCalls++; return JSON.stringify(flatPlan) }, async () => '')
  assert.equal(flatCalls, 3); assert.equal(flatFallback.appPlanFailed, false, 'a prose heuristic alone cannot disable the ordinary fallback'); checks++
  for (const words of ['when the countdown ends the alarm goes off and the view flashes', 'open eyes and view the breathing rhythm']) {
    const single = {title:'Timer', needs:[{type:'other',what:words}]}
    assert.equal(np.navigationPlanProblem(parse(single)), '')
    let calls = 0
    const composed = await loadVera('NeedsChoose').composeNeeds(words, async () => { calls++; return JSON.stringify(single) }, async () => '')
    assert.equal(calls, 1); assert.equal(composed.appPlanFailed, false); checks++
  }
  // Tabs use the SAME named screens, active-only construction and reachability gate.
  const tabPlan = plan(); tabPlan.presentation = 'tabs'
  const tabCode = good.replace(/if \(state.c_screen === "notes"\)[\s\S]*?(?=<\/view>)/, `let panes: ui.View[] = [];
let selected: number = 0;
if (state.c_screen === "notes") { selected = 1; }
if (state.c_screen === "editor") { selected = 2; }
if (selected === 0) { panes.push(c_view_home(state)); } else { panes.push(ui.Column("default", [])); }
if (selected === 1) { panes.push(c_view_notes(state)); } else { panes.push(ui.Column("default", [])); }
if (selected === 2) { panes.push(c_view_editor(state)); } else { panes.push(ui.Column("default", [])); }
sections.push(ui.Tabs("default", ["Overview", "Notes", "Editor"], selected, "c_tab", panes));
`).replace('</functions>', `function c_tab(state: AppState, value: number): AppState {
if (value === 1) { return {c_screen:"notes"__PASSTHROUGH__}; }
if (value === 2) { return {c_screen:"editor"__PASSTHROUGH__}; }
return {c_screen:"home"__PASSTHROUGH__};
}\n</functions>`)
  const tabHost = hostFor(tabPlan, tabCode)
  const tabBuilt = await buildScreen(Object.assign(new RouteRequest(), {agent:Object.assign(new AgentRequest(),{prompt:'Notes with peer tabs',widget:true})}),tabHost.host)
  assert.equal(tabBuilt.kind,'agent',tabBuilt.reason); assert.match(tabHost.seen.code[0].system,/Use one ui.Tabs/)
  assert.equal(smokeRun(compileVeraSource(tabBuilt.agent.source)), ''); checks++
  const invalidPresentation = plan(); invalidPresentation.presentation = 'invented'; assert.equal(parse(invalidPresentation),null); checks++
  const qPlan = n => Object.assign(plan(), n === 1 ? {questions: [{id: 'subject', ask: 'Which notes?', options: ['Work', 'Home'], default: 0}]} : {})
  const clarified = hostFor(qPlan); clarified.host.askJev = async body => JSON.parse(body).questions['blocking.0'] ? '{"answers":{"blocking.0":{"probabilities":{"ask":1,"skip":0}}}}' : ''; clarified.host.ask = async () => 1
  const q = await run(clarified.host); assert.equal(q.kind, 'agent', q.reason); assert.equal(clarified.seen.plans.length, 2); assert.match(clarified.seen.code[0].user, /Which notes\? Home/); assert.equal(q.agent.asked.length, 1); checks++
  const defaultResult = await loadVera('NeedsChoose').composeNeeds('Notes', async () => JSON.stringify(Object.assign(plan(), {
    questions:[{id:'currency',ask:'Which currency?',options:['USD','EUR'],default:1}]
  })), async () => '', () => {}, false, async () => '')
  assert.match(defaultResult.appPlan.request, /Which currency\? EUR/); checks++
  assert.match(invalidHost.seen.plans[1], /Screen home needs must reference declared need ids/); checks++
  const cancel = hostFor(); let cancelled = false; cancel.host.cancelled = () => cancelled; cancel.host.lookup = async () => { cancelled = true; return '' }; const stopped = await run(cancel.host); assert.equal(stopped.kind, 'cancelled'); assert.equal(cancel.seen.code.length, 0); checks++
  console.log(`app-plan: ${checks} checks passed (real compiler/VM; model, selector and phone effects mocked)`)
}
main().catch(e => { console.error(e.stack); process.exitCode = 1 })
