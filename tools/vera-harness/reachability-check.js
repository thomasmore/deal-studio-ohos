// No device or paid calls. With a .vera argument, check that program; otherwise run regressions.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {checkScreenReachability} = loadVera('VeraReachability')
const {smokeRun} = loadVera('VeraSmoke')
function check(source, screens) {
  screens ||= loadVera('VeraAppRefine').sourceScreenIds(source)
  return checkScreenReachability(compileVeraSource(source).vbc2, screens)
}
if (process.argv[2]) {
  const source = fs.readFileSync(process.argv[2], 'utf8')
  const screens = process.argv.slice(3)
  const result = check(source, screens.length ? screens : undefined)
  if (result.reached.length < 2 && result.missing.length === 0) throw Error('Specify at least two screen IDs or use generated c_view_<id> functions')
  console.log(JSON.stringify(result, null, 2))
  process.exitCode = result.diagnostic ? 1 : 0
} else {
  const source = `import * as ui from "std/ui"
@jsonable
class Record { id: string; title: string; }
@jsonable
class AppState { screen: string; records: Record[]; title: string; selected: string; }
function init(): AppState { return {screen: "list", records: [], title: "", selected: ""}; }
function typeTitle(s: AppState, v: string): AppState { return {screen:s.screen, records:s.records, title:v, selected:s.selected}; }
function add(s: AppState, v: number): AppState {
  if (strings.length(s.title) === 0) { return s; }
  let record: Record = {id:"record-1", title:s.title};
  return {screen:s.screen, records:[record], title:"", selected:s.selected};
}
function open(s: AppState, v: number): AppState {
  let id: string = ui.numberToString(v);
  for (let record: Record of s.records) {
    if (record.id === id) { return {screen:"detail", records:s.records, title:s.title, selected:id}; }
  }
  return s;
}
function back(s: AppState, v: number): AppState { return {screen:"list", records:s.records, title:s.title, selected:""}; }
function c_view_list(s: AppState): ui.View {
  let children: ui.View[] = [ui.TextField("default","Title",s.title,"typeTitle"), ui.Button("primary","Add","add",0,true)];
  for (let record: Record of s.records) { children.push(ui.ListItem("default",record.title,"","","open",strings.toNumber(record.id,0),true,"")); }
  return ui.Screen("list", children);
}
function c_view_detail(s: AppState): ui.View { return ui.Screen("detail:" + s.selected,[ui.Text("body","Detail"),ui.BackHandler("back")]); }
function view(s: AppState): ui.View {
  if (s.screen === "detail") { return ui.AppTheme("clean","",[c_view_detail(s)]); }
  return ui.AppTheme("clean","",[c_view_list(s)]);
}`
  let tests = 0
  const broken = check(source)
  assert.deepEqual(broken.reached, ['list']); assert.deepEqual(broken.missing, ['detail'])
  assert.match(broken.diagnostic, /open.*left state unchanged/); tests++
  assert.deepEqual(check(source), broken, 'same bytecode must produce identical diagnostics and counts'); tests++
  const fixed = source.replace('id:"record-1"', 'id:"1"')
  const passed = check(fixed)
  assert.equal(passed.diagnostic, ''); assert.deepEqual(passed.reached, ['list', 'detail'])
  assert.match(passed.paths[1], /fill\(typeTitle\).*add.*open/); tests++
  assert.match(smokeRun(compileVeraSource(source)), /Screen reachability check failed/)
  assert.equal(smokeRun(compileVeraSource(fixed)), ''); tests++
  // A directly callable view and handler are not evidence of a reachable control.
  const hidden = fixed.replace('strings.toNumber(record.id,0),true', 'strings.toNumber(record.id,0),false')
  assert.deepEqual(check(hidden).missing, ['detail']); tests++
  const whenHidden = fixed.replace('children.push(ui.ListItem(', 'children.push(ui.When(false,ui.ListItem(').replace('true,""));', 'true,"")));')
  assert.deepEqual(check(whenHidden).missing, ['detail']); tests++
  // Hidden tab children must not supply navigation controls.
  const tabHidden = fixed.replace('return ui.Screen("list", children);', 'return ui.Screen("list", [ui.Tabs("default", ["Visible", "Hidden"], 0, "", [ui.Text("body", "Visible"), ui.Column("default", children)])]);')
  assert.deepEqual(check(tabHidden).missing, ['detail']); tests++
  const tabEnabled = tabHidden.replace('0, "", [ui.Text', '0, "selectTab", [ui.Text').replace('function back(', 'function selectTab(s: AppState, v: number): AppState { return {screen:"detail", records:s.records, title:s.title, selected:""}; }\nfunction back(')
  assert.equal(check(tabEnabled).diagnostic, ''); tests++
  // Supported native numeric callbacks must be explored, with disabled controls excluded.
  for (const control of [
    'ui.IconButton("default", "plus", "Open", "open", strings.toNumber(record.id,0), true)',
    'ui.Timeline("default", "Events", [ui.TimelineItem("default", record.title, "", "", "open", strings.toNumber(record.id,0), true, "")])'
  ]) {
    const interactive = fixed.replace('ui.ListItem("default",record.title,"","","open",strings.toNumber(record.id,0),true,"")', control)
    assert.equal(check(interactive).diagnostic, ''); assert.equal(smokeRun(compileVeraSource(interactive)), ''); tests++
    const disabled = interactive.replace(control, control.replace(', true', ', false'))
    assert.deepEqual(check(disabled).missing, ['detail']); tests++
  }
  const endless = fixed.replace('return {screen:s.screen, records:[record], title:"", selected:s.selected};', 'while (true) { let x: number = 1; } return s;')
  const bounded = check(endless)
  assert.deepEqual(bounded.missing, ['detail']); assert.ok(bounded.actions <= 768); assert.ok(bounded.states <= 192); tests++
  const now = fixed.replace('function view(s: AppState): ui.View {', 'function view(s: AppState): ui.View {\n if (time.nowMillis() !== 1767268800000) { return ui.AppTheme("clean","",[ui.Screen("list",[ui.Text("body","Wrong clock")])]); }')
  assert.equal(check(now).diagnostic, ''); assert.deepEqual(check(now), check(now)); tests++
  const noButtonLabel = fixed.replace('return ui.Screen("list", children);', 'return ui.Screen("list", [ui.EmptyState("default", "Empty", "", "", "back", "")]);').replace('screen:"list", records:s.records, title:s.title, selected:""', 'screen:"detail", records:s.records, title:s.title, selected:""')
  assert.deepEqual(check(noButtonLabel).missing, ['detail']); tests++
  console.log(`reachability: ${tests} regressions passed (real compiler/VM, rendered payloads, no device/model calls)`)
}
