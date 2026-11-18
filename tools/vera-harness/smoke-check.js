// VeraSmoke: the first run of a program before it is served, and the runtime errors it reports.
//
//   node tools/vera-harness/smoke-check.js
'use strict'
const assert = require('node:assert')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {smokeRun} = loadVera('VeraSmoke')
const {VirtualMachine, deserializeVbc2} = loadVera('VeraInterpreter')
const {quoteDiagnostics} = loadVera('VeraRepair')

const program = (handlers, rows) => `@jsonable
class AppState {
  items: string[];
  name: string;
}

function init(): AppState {
  let none: string[] = [];
  return {items: none, name: ""};
}

function setName(state: AppState, value: string): AppState {
  return {items: state.items, name: value};
}

function add(state: AppState, ignored: number): AppState {
  let out: string[] = [];
  for (let s: string of state.items) { out.push(s); }
  out.push(state.name);
  return {items: out, name: ""};
}
${handlers}
function view(state: AppState): ui.View {
  let rows: ui.View[] = [];
  let i: number = state.items.length() - 1;
  while (i >= 0) {
    rows.push(ui.Text("default", state.items[i]));
${rows}
  }
  return ui.AppTheme("clean", "", [ui.Column("default", rows)]);
}
`

// A list loop that never counts down: fine while empty, stuck at the first item -- found, with both lines.
{
  const source = program('', '')
  const found = smokeRun(compileVeraSource(source))
  const loop = source.split('\n').findIndex(l => l.includes('while (i >= 0)')) + 1
  assert.ok(found.startsWith(`${loop + 1}:1 R0022 The program compiled, but stopped drawing the screen after setName, add: array length limit reached`), found)
  assert.ok(found.includes(`inside the loop at line ${loop}, which never stopped`), found)
  assert.ok(found.endsWith(`\n${loop}:1 R0022 the loop it was in`), found)
  assert.match(quoteDiagnostics(source, found), new RegExp(`${loop} \\|   while \\(i >= 0\\) \\{`))
}

// The same loop counting down runs; a handler that traps on the made-up value (an index the list lacks) is set aside.
{
  const pick = `
function pick(state: AppState, index: number): AppState {
  return {items: state.items, name: state.items[index]};
}
`
  assert.equal(smokeRun(compileVeraSource(program(pick, '    i = i - 1;'))), '')
}

// A handler that never ends is reported where it runs.
{
  const spin = `
function spin(state: AppState, ignored: number): AppState {
  let n: number = 0;
  while (n < 1) { n = n * 2; }
  return state;
}
`
  assert.match(smokeRun(compileVeraSource(program(spin, '    i = i - 1;'))), /R0017 The program compiled, but stopped in spin after .*: execution exceeded .* inside the loop at line \d+, which never stopped or does too much work/)
}

// A program whose expect(state) returns false at the initial state is sent back as a repair.
{
  const src = `@jsonable
class AppState { bmi: number; }

function init(): AppState { return {bmi: -68.3}; }

function expect(state: AppState): boolean { return state.bmi > 0 && state.bmi < 60; }

function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [ui.Column("default", [ui.Text("default", "BMI")])]);
}
`
  const found = smokeRun(compileVeraSource(src))
  assert.ok(found.startsWith('The program compiled, but its own expectation was not met at the initial state (function expect returned false)'), found)
}

// The same program with a correct initial value passes: expect must not false-fail.
{
  const src = `@jsonable
class AppState { bmi: number; }

function init(): AppState { return {bmi: 24.2}; }

function expect(state: AppState): boolean { return state.bmi > 0 && state.bmi < 60; }

function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [ui.Column("default", [ui.Text("default", "BMI")])]);
}
`
  assert.equal(smokeRun(compileVeraSource(src)), '')
}

// Bytecode from before lines were kept still runs, and its traps say what they did without a line.
{
  const vbc2 = JSON.parse(compileVeraSource(program('', '')).vbc2)
  for (const fn of vbc2[2]) fn.length = 5
  const vm = new VirtualMachine(deserializeVbc2(JSON.stringify(vbc2)))
  assert.ok(vm.execute('init'))
}

console.log('smoke-check: ok')
