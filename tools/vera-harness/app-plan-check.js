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
  const bare = plan(); bare.transitions[1].record = 'notes'; assert.equal(parse(bare).transitions[1].record, 'notes.id'); checks++
  const badRecord = plan(); badRecord.transitions[1].record = 'notes.title'; assert.equal(parse(badRecord), null); checks++
  const multiple = plan(); multiple.needs.push({id: 'tasks', type: 'entries', label: 'Tasks', fields: []}); multiple.screens[0].needs.push('tasks')
  const full = parse(multiple); assert.equal(full.needs.filter(n => n.type === 'entries').length, 2); assert.equal(np.planningSketch(full).list, null); checks++
  const withExtra = plan(); withExtra.needs.push({id: 'extra', type: 'content', what: 'Unasked advice', from: 'a quote nobody asked for'}); withExtra.screens[0].needs.push('extra'); withExtra.needs[1].uses.push('extra')
  const filtered = parse(withExtra); assert.equal(np.dropUnasked(filtered, 'Notes with an editor').length, 1); assert.ok(!filtered.screens[0].needs.includes('extra')); assert.deepEqual(filtered.needs[1].uses, ['notes']); checks++
  const {host, seen} = hostFor(); const built = await run(host); assert.equal(built.kind, 'agent', built.reason); assert.ok(built.agent.vbc2, built.agent.errors); assert.equal(seen.plans.length, 1); assert.equal(seen.code.length, 1); assert.equal(seen.holes, 1); assert.equal(seen.fills, 0); assert.equal(built.agent.record, null); assert.equal(built.agent.composed.parsed, null); assert.equal(built.agent.blocks.length, 0); assert.equal(built.agent.composed.appPlan.screens.length, 3); checks++
  assert.match(seen.code[0].system, /Declaring a handler is not enough/); assert.match(seen.code[0].system, /Screen\(/); assert.match(seen.code[0].system, /BackHandler/); assert.match(seen.code[0].user, /"uses":\["notes"\]/); assert.doesNotMatch(seen.code[0].system, /no second view/); assert.ok(seen.code[0].budget < 3 * 8000); checks++
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
  const unbound = good.replace('    children.push(ui.Button("secondary", "Remove", "c_remove", note.id, true));', '')
  assert.notEqual(unbound, good)
  const dead = await run(hostFor(plan(), unbound).host); assert.equal(dead.kind, 'not-built'); assert.match(dead.reason, /c_remove has no control or caller reference/); checks++
  const retryHost = hostFor(plan(), n => n === 1 ? unbound : good); const retried = await run(retryHost.host); assert.equal(retried.kind, 'agent', retried.reason); assert.equal(retryHost.seen.code.length, 2); checks++
  const custom = loadVera('agent/AgentCustom'); const verification = new custom.CustomRequest(); verification.appPlan = parse(plan()); verification.needs = ['Delete a record']; assert.match(JSON.parse(custom.verifyRequest(verification, good)).state, /local AppState changes/); checks++
  const qPlan = n => Object.assign(plan(), n === 1 ? {questions: [{id: 'subject', ask: 'Which notes?', options: ['Work', 'Home'], default: 0}]} : {})
  const clarified = hostFor(qPlan); clarified.host.askJev = async body => JSON.parse(body).questions['blocking.0'] ? '{"answers":{"blocking.0":{"probabilities":{"ask":1,"skip":0}}}}' : ''; clarified.host.ask = async () => 1
  const q = await run(clarified.host); assert.equal(q.kind, 'agent', q.reason); assert.equal(clarified.seen.plans.length, 2); assert.match(clarified.seen.code[0].user, /Which notes\? Home/); assert.equal(q.agent.asked.length, 1); checks++
  const cancel = hostFor(); let cancelled = false; cancel.host.cancelled = () => cancelled; cancel.host.lookup = async () => { cancelled = true; return '' }; const stopped = await run(cancel.host); assert.equal(stopped.kind, 'cancelled'); assert.equal(cancel.seen.code.length, 0); checks++
  console.log(`app-plan: ${checks} checks passed (real compiler/VM; model, selector and phone effects mocked)`)
}
main().catch(e => { console.error(e.stack); process.exitCode = 1 })
