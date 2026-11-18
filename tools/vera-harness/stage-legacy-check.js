// ui.Stage was removed from the language. Projects saved before that hold compiled bytecode (vbc2) that still names it:
// the old compiler (git cb5249f, else the checked-in .vbc2) builds a Stage + Transform die, the CURRENT VM and decoder must run it,
// the Stage must come out as a plain column, the current compiler must refuse ui.Stage, and the renderer must draw what comes out.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {execFileSync} = require('node:child_process')
const {loadVera, loadSource} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VirtualMachine, deserializeVbc2} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUi')

const repo = path.resolve(__dirname, '../..')
const source = fs.readFileSync(path.join(__dirname, 'examples/legacy-stage-die.vera'), 'utf8')
const vbc2File = path.join(__dirname, 'examples/legacy-stage-die.vbc2')
const OLD = 'cb5249f'

// 1. the old bytecode: from the old compiler when git has it, else the checked-in file
let vbc2, origin
try {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-old-'))
  const tar = execFileSync('git', ['-C', repo, 'archive', OLD, 'entry/src/main/ets'], {maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore']})
  execFileSync('tar', ['-x', '-C', tmp], {input: tar})
  const oldRoot = path.join(tmp, 'entry/src/main/ets')
  // a child process, so the old sources never share a require cache with the current ones
  const script = 'const {loadSource}=require(' + JSON.stringify(path.join(__dirname, 'source-loader.js')) + ');' +
    'const c=loadSource(' + JSON.stringify(path.join(oldRoot, 'vera/VeraCompiler.ets')) + ');' +
    'const r=c.compileVeraSource(require("fs").readFileSync(0,"utf8"));process.stdout.write(r.vbc2!==undefined?r.vbc2:r)'
  vbc2 = execFileSync(process.execPath, ['-e', script], {input: source, env: {...process.env, VERA_SOURCE_ROOT: oldRoot}, maxBuffer: 1 << 26}).toString()
  origin = 'old compiler at ' + OLD
  fs.rmSync(tmp, {recursive: true, force: true})
  if (!fs.existsSync(vbc2File)) fs.writeFileSync(vbc2File, vbc2)
} catch (e) {
  if (!fs.existsSync(vbc2File)) throw e
  vbc2 = fs.readFileSync(vbc2File, 'utf8'); origin = 'checked-in vbc2 (git/old compiler unavailable: ' + String(e.message).split('\n')[0] + ')'
}
assert.ok(vbc2.length > 0)

// 2. run the old bytecode with the current VM and decoder
const vm = new VirtualMachine(deserializeVbc2(vbc2), new UiHostEnvironment())
const flat = n => [n].concat(...(n.children || []).map(flat))
const decode = state => decodeVeraUi(vm.execute('view', [state]))[0]
const state = vm.execute('init')
const first = flat(decode(state))
const kinds = new Set(first.map(n => n.kind))
const stage = first.find(n => n.kind === 'column' && n.children.some(c => c.kind === 'transform'))
assert.ok(stage, 'the Stage became a column holding the Transform')
assert.equal(first.filter(n => n.kind === 'transform').length, 13, 'one cube, six turners and six inner layers are kept: ' + [...kinds])
assert.ok(first.some(n => n.kind === 'canvas') && first.some(n => n.kind === 'path') && first.some(n => n.kind === 'button'), 'faces and the button survive')
const after = vm.execute('onRoll', [state, 0])
const second = flat(decode(after))
assert.ok(second.some(n => n.kind === 'transform'), 'view after the button decodes')
const cube = n => flat(n).find(x => x.kind === 'transform')
assert.notDeepEqual(cube(stage).series, cube(second.find(n => n.kind === 'column' && n.children.some(c => c.kind === 'transform'))).series, 'the new pose reaches the cube')

// 3. the current compiler refuses ui.Stage
assert.throws(() => compileVeraSource(source), e => (e.diagnostics || []).length > 0 && /Stage/.test(JSON.stringify(e.diagnostics)), 'ui.Stage is refused by the current compiler')

// 4. the renderer draws every kind the decoder can emit here (the fallback emits a column; the rest are listed too)
const preview = fs.readFileSync(path.join(repo, 'entry/src/main/ets/components/VeraPreview.ets'), 'utf8')
const rendered = preview.match(/RENDERED: string\[\] = \[([^\]]*)\]/)[1].match(/'([^']+)'/g).map(s => s.slice(1, -1))
const uiSrc = fs.readFileSync(path.join(repo, 'entry/src/main/ets/vera/VeraUi.ets'), 'utf8')
const fallback = uiSrc.slice(uiSrc.indexOf("case 'Stage':"), uiSrc.indexOf("case 'Layers':"))
const emitted = [...fallback.matchAll(/viewNode\('([a-z]+)'/g)].map(m => m[1])
assert.ok(emitted.length > 0)
for (const k of new Set([...emitted, ...kinds])) assert.ok(rendered.includes(k), 'renderer draws ' + k)

console.log('stage-legacy-check ok: ' + origin + '; Stage -> column [' + [...kinds].join(',') + '], ' + first.length + ' nodes')
