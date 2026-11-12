#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {spawnSync} = require('node:child_process')
const {canonical, json, difference, parseArgs, corpusInputs} = require('./runtime-baseline')

fs.mkdirSync('/tmp/vera', {recursive: true})
const temporary = fs.mkdtempSync('/tmp/vera/runtime-baseline-check-')
const cli = path.join(__dirname, 'runtime-baseline.js')
const output = path.join(temporary, 'golden.json')
function run(args, status = 0, env = {}) {
  const result = spawnSync(process.execPath, [cli, ...args], {encoding: 'utf8', env: {...process.env, ...env}, timeout: 120000, maxBuffer: 4 * 1024 * 1024})
  assert.ifError(result.error)
  assert.equal(result.status, status, result.stdout + result.stderr)
  return result.stdout + result.stderr
}
function write(file, value) { fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value)) }
function read(file = output) { return JSON.parse(fs.readFileSync(file, 'utf8')) }
function manifest(versions) { return {tool: 'pull-vera-sources.sh', projects: [{id: 'public-fixture', versions}]} }

try {
  assert.equal(json({z: 1, a: {y: 2, b: 3}}), json({a: {b: 3, y: 2}, z: 1}))
  assert.deepEqual(canonical([NaN, Infinity, -Infinity, -0]), [{$number: 'NaN'}, {$number: 'Infinity'}, {$number: '-Infinity'}, {$number: '-0'}])
  assert.deepEqual(canonical(new Map([['b', 'two'], ['a', 'one']])), [['b', 'two'], ['a', 'one']])
  assert.equal(difference([], [1]), '$[0]')
  assert.equal(difference([1], []), '$[0]')
  assert.equal(difference({a: 1}, {a: 2}), '$["a"]')
  assert.equal(difference({a: 1}, {a: 1}), null)
  assert.throws(() => parseArgs(['--capture']), /usage/)
  assert.throws(() => parseArgs(['--capture', '--compare', '--output', output]), /usage/)
  assert.throws(() => parseArgs(['--compare', '--output', output, '--output', output]), /usage/)
  run(['--help'])
  for (const args of [[], ['--output', output], ['--capture'], ['--compare', '--output', output, '--execute-effects'], ['--capture', '--compare', '--output', output]]) run(args, 1)
  run(['--compare', '--output', output], 1)
  assert(!fs.existsSync(output))
  run(['--capture', '--output', path.join(temporary, 'missing', 'golden.json')], 1)
  run(['--capture', '--output', cli], 1)

  const controls = spawnSync(process.execPath, ['-e', `const assert=require('node:assert/strict'); const {configureDeterminism}=require(${JSON.stringify(cli)}); const reset=configureDeterminism(); assert.equal(Date.now(),new Date().getTime()); assert.equal(new Date().getTimezoneOffset(),0); assert.equal(new Date('2020-01-01T00:00:00Z').getFullYear(),2020); const first=Math.random(); Math.random(); reset(); assert.equal(Math.random(),first); for(const action of [()=>fetch('https://invalid.test'),()=>globalThis.__veraHttp(),()=>globalThis.__veraResolve(),()=>require('node:https').get('https://invalid.test'),()=>require('node:net').connect(1),()=>require('node:dns').lookup('invalid.test'),()=>require('node:dns').promises.lookup('invalid.test')]) assert.throws(action,/prohibited/);`], {encoding: 'utf8', env: {...process.env, TZ: 'Pacific/Honolulu'}})
  assert.equal(controls.status, 0, controls.stderr)

  run(['--capture', '--output', output], 0, {TZ: 'Pacific/Honolulu'})
  const baselineBytes = fs.readFileSync(output, 'utf8'), baseline = read()
  assert.equal(baseline.coverage.summary.examples, fs.readdirSync(path.join(__dirname, 'examples')).filter(n => n.endsWith('.vera')).length)
  assert.equal(baseline.coverage.summary.compatibility, fs.readdirSync(path.join(__dirname, 'compatibility')).filter(n => n.endsWith('.json')).length * 2)
  assert.equal(baseline.coverage.summary.documented, fs.readdirSync(path.resolve(__dirname, '../../docs/examples')).filter(n => n.endsWith('.vera')).length)
  const knownErrors = ['docs/examples/shanghai-layover.vera']
  assert.deepEqual(baseline.cases.filter(c => c.status === 'error').map(c => c.id), knownErrors)
  assert.equal(baseline.coverage.summary.errors, knownErrors.length)
  assert.equal(baseline.coverage.summary.cases, baseline.cases.length)
  assert.equal(baseline.environment.repeats, 2)
  assert.equal(baseline.environment.timezone, 'UTC')
  assert(baseline.coverage.summary.gfxSurfaces > 0)
  assert(baseline.coverage.summary.effects > 0)
  assert(baseline.coverage.limitations.some(s => s.includes('docs/demo-prompts.md')))
  for (const item of baseline.cases) {
    if (knownErrors.includes(item.id)) {
      assert.equal(item.error.phase, 'compile')
      assert(item.error.diagnostics.length > 0)
      continue
    }
    assert.equal(item.snapshots[0].label, 'initial', item.id)
    for (const snapshot of item.snapshots) {
      assert.deepEqual(snapshot.state, snapshot.restored.state)
      assert.deepEqual(snapshot.views, snapshot.restored.views)
    }
  }
  const find = id => baseline.cases.find(c => c.id === 'examples/' + id + '.vera')
  const stateAt = (id, label) => find(id).snapshots.find(s => s.label === label).state
  assert.equal(find('hello').snapshots.filter(s => s.label.startsWith('tap-')).length, 10)
  assert.notDeepEqual(stateAt('hello', 'initial'), stateAt('hello', 'tap-10'))
  assert.equal(find('visual-countdown').snapshots.filter(s => /^tick-\d+$/.test(s.label)).length, 10)
  for (const [id, labels] of [['textfield-demo', ['field-empty', 'field-invalid', 'field-valid']],
    ['table-bars-slider-demo', ['slider-0', 'slider-25', 'slider-75', 'slider-100']],
    ['widget-switch', ['toggle-true', 'checkbox-true', 'toggle-false', 'checkbox-false']]]) {
    for (const label of labels) assert(stateAt(id, label), id + '/' + label)
  }
  assert.notDeepEqual(stateAt('textfield-demo', 'field-invalid'), stateAt('textfield-demo', 'field-valid'))
  assert.notDeepEqual(stateAt('table-bars-slider-demo', 'slider-0'), stateAt('table-bars-slider-demo', 'slider-100'))
  assert.notDeepEqual(stateAt('widget-switch', 'toggle-true'), stateAt('widget-switch', 'toggle-false'))
  const source = baseline.cases.find(c => c.id === 'examples/widget-source.vera')
  assert(source.snapshots.some(s => s.label === 'synthetic-source-ok'))
  assert(source.snapshots.some(s => s.label === 'synthetic-source-error'))
  const effect = source.calls.flatMap(c => c.effects)[0]
  assert.equal(effect.rawTarget, 'Vera.Source.fetch')
  assert.equal(effect.resultHandler, 'onSource')
  assert(Array.isArray(effect.values))
  const sized = baseline.cases.find(c => c.id === 'examples/widget-sizes.vera').snapshots[0]
  assert.deepEqual(sized.views.filter(v => v.entry === 'widget').map(v => v.dimension), [2, 3, 4])
  const game = baseline.cases.find(c => c.id === 'examples/surface-catch.vera')
  assert(game.snapshots.some(s => s.label === 'frame-40' && s.views.some(v => v.surfaces.some(g => g.ops.length > 0))))
  run(['--compare', '--output', output], 0, {TZ: 'Asia/Shanghai'})
  assert.equal(fs.readFileSync(output, 'utf8'), baselineBytes)

  const mutated = read()
  mutated.cases[0].snapshots[0].state = ['n', 123456]
  write(output, json(mutated))
  const changedBytes = fs.readFileSync(output, 'utf8')
  assert.match(run(['--compare', '--output', output], 1), /Baseline mismatch.*state/)
  assert.equal(fs.readFileSync(output, 'utf8'), changedBytes)
  run(['--output', output], 1)
  assert.equal(fs.readFileSync(output, 'utf8'), changedBytes)
  write(output, '{broken')
  run(['--compare', '--output', output], 1)
  assert.equal(fs.readFileSync(output, 'utf8'), '{broken')
  write(output, {format: 'unknown', version: 1})
  assert.match(run(['--compare', '--output', output], 1), /Unsupported baseline/)
  run(['--capture', '--output', output])
  assert.equal(fs.readFileSync(output, 'utf8'), baselineBytes)

  const link = path.join(temporary, 'link.json')
  try {
    fs.symlinkSync(output, link)
    run(['--capture', '--output', link], 1)
    assert.equal(fs.readFileSync(output, 'utf8'), baselineBytes)
  } catch (e) {
    if (e.code !== 'EPERM' && e.code !== 'EACCES') throw e
  }
  const preload = path.join(temporary, 'nondeterministic.cjs')
  write(preload, 'Math.sin = () => process.pid\n')
  assert.match(run(['--capture', '--output', output], 1, {NODE_OPTIONS: '--require=' + preload}), /Nondeterministic independent repeats/)
  assert.equal(fs.readFileSync(output, 'utf8'), baselineBytes)

  const corpus = path.join(temporary, 'corpus')
  fs.mkdirSync(corpus)
  const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'compatibility/counter.json'), 'utf8'))
  write(path.join(corpus, 'counter.vbc2'), fixture.bytecode)
  fs.mkdirSync(path.join(corpus, 'raw'))
  fs.mkdirSync(path.join(corpus, 'raw', 'p'))
  write(path.join(corpus, 'raw', 'p', 'string.json'), {vbc2: fixture.bytecode, source: 'ignored private source', prompt: 'ignored private prompt'})
  write(path.join(corpus, 'raw', 'p', 'array.json'), {vbc2: JSON.parse(fixture.bytecode)})
  write(path.join(corpus, 'raw', 'settings.json'), 'must not be parsed')
  write(path.join(corpus, 'raw', 'p', 'x.state.json'), 'must not be parsed')
  write(path.join(corpus, 'unused.vera'), 'must not be compiled')
  const versions = [{readable_files: ['counter.vbc2', 'unused.vera', 'unused.prompt.txt']},
    {phone_path: 'p/string.json', raw_path: 'raw/p/string.json'}, {phone_path: 'p/array.json', raw_path: 'raw/p/array.json'}, {has_vbc2: false}]
  write(path.join(corpus, 'manifest.json'), manifest(versions))
  assert.equal(corpusInputs(corpus).inputs.length, 3)
  const externalOutput = path.join(temporary, 'external.json')
  run(['--capture', '--output', externalOutput, '--corpus', corpus])
  const external = read(externalOutput)
  assert.equal(external.coverage.summary.external, 3)
  assert.equal(external.coverage.summary.errors, knownErrors.length)
  assert.equal(external.coverage.corpusGaps.length, 1)
  assert(!JSON.stringify(external).includes('ignored private'))
  run(['--compare', '--output', externalOutput, '--corpus', corpus])
  const externalBytes = fs.readFileSync(externalOutput, 'utf8')
  const bytecode = JSON.parse(fixture.bytecode)
  bytecode[2][0][4][0][1] = 17
  write(path.join(corpus, 'counter.vbc2'), JSON.stringify(bytecode))
  assert.match(run(['--compare', '--output', externalOutput, '--corpus', corpus], 1), /Baseline mismatch/)
  assert.equal(fs.readFileSync(externalOutput, 'utf8'), externalBytes)
  write(path.join(corpus, 'counter.vbc2'), 'malformed bytecode')
  run(['--capture', '--output', externalOutput, '--corpus', corpus])
  const trapped = read(externalOutput).cases.find(c => c.id === 'corpus/counter.vbc2')
  assert.equal(trapped.status, 'error')
  assert.equal(trapped.error.phase, 'deserialize')
  run(['--compare', '--output', externalOutput, '--corpus', corpus])
  run(['--capture', '--output', path.join(corpus, 'counter.vbc2'), '--corpus', corpus], 1)
  const prohibited = JSON.parse(fixture.bytecode)
  prohibited[2].find(f => f[0] === 'view')[4] = [
    ['load-external', 'std/sdk', 'call'], ['push-string', 'Vera.Source.fetch'],
    ['make-array', 0], ['push-string', ''], ['call', 3, false], ['return']
  ]
  write(path.join(corpus, 'counter.vbc2'), JSON.stringify(prohibited))
  run(['--capture', '--output', externalOutput, '--corpus', corpus])
  const forbidden = read(externalOutput).cases.find(c => c.id === 'corpus/counter.vbc2')
  assert.equal(forbidden.status, 'error')
  assert.equal(forbidden.error.code, 'R0026')
  assert.equal(forbidden.error.phase, 'view')
  assert.deepEqual(forbidden.calls.flatMap(c => c.effects), [])
  run(['--compare', '--output', externalOutput, '--corpus', corpus])

  write(path.join(corpus, 'manifest.json'), manifest([{readable_files: ['../golden.vbc2']}]))
  assert.throws(() => corpusInputs(corpus), /Unsafe/)
  write(path.join(corpus, 'manifest.json'), manifest([{raw_path: 'raw/p/x.state.json', phone_path: 'p/x.state.json'}]))
  assert.throws(() => corpusInputs(corpus), /Unsafe/)
  write(path.join(corpus, 'manifest.json'), manifest([{readable_files: ['missing.vbc2']}]))
  assert.throws(() => corpusInputs(corpus), /ENOENT/)
  const beforeFailure = fs.readFileSync(externalOutput, 'utf8')
  run(['--capture', '--output', externalOutput, '--corpus', corpus], 1)
  assert.equal(fs.readFileSync(externalOutput, 'utf8'), beforeFailure)
  try {
    fs.symlinkSync(output, path.join(corpus, 'escape.vbc2'))
    write(path.join(corpus, 'manifest.json'), manifest([{readable_files: ['escape.vbc2']}]))
    assert.throws(() => corpusInputs(corpus), /Unsafe/)
  } catch (e) {
    if (e.code !== 'EPERM' && e.code !== 'EACCES') throw e
  }
  write(path.join(corpus, 'manifest.json'), {projects: []})
  assert.throws(() => corpusInputs(corpus), /schema/)
  console.log('runtime-baseline-check: ok; CLI capture/compare, mutation, independent determinism, UTC/random, remote prohibition, compatibility/restore/GfxOp/effect coverage, external pull corpus and path safety')
} finally {
  fs.rmSync(temporary, {recursive: true, force: true})
}
