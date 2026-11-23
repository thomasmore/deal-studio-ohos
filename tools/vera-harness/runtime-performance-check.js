#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const crypto = require('node:crypto')
const {canonical} = require('./runtime-baseline')
const {spawnSync} = require('node:child_process')
const P = require('./runtime-performance')
const posix = process.platform !== 'win32'

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-runtime-performance-check-'))
const cli = path.join(__dirname, 'runtime-performance.js')
const baselinePath = path.join(temporary, 'baseline.json')
const candidatePath = path.join(temporary, 'candidate.json')
const small = ['--warmup', '1', '--samples', '2', '--iterations', '2']
const clone = value => JSON.parse(JSON.stringify(value))
function run(args, status = 0, env = {}) {
  const result = spawnSync(process.execPath, [cli, ...args], {encoding: 'utf8', timeout: 120000,
    maxBuffer: 8 * 1024 * 1024, env: {...process.env, ...env}})
  assert.ifError(result.error)
  assert.equal(result.status, status, result.stdout + result.stderr)
  return result.stdout + result.stderr
}
function script(source, status = 0, env = {}) {
  const result = spawnSync(process.execPath, ['-e', source], {encoding: 'utf8', timeout: 120000,
    maxBuffer: 8 * 1024 * 1024, env: {...process.env, ...env}})
  assert.ifError(result.error)
  assert.equal(result.status, status, result.stdout + result.stderr)
  return result.stdout + result.stderr
}
function retime(report, samples, iterations = report.settings.iterations) {
  const result = clone(report)
  result.settings.samples = samples.length
  result.settings.iterations = iterations
  for (const workload of result.workloads) {
    workload.samplesMs = [...samples]
    workload.statistics = P.statistics(samples, iterations)
  }
  return result
}

try {
  const parsed = P.parseArgs(['--capture', '--output', baselinePath, ...small])
  assert.deepEqual(P.settings(parsed), {warmup: 1, samples: 2, iterations: 2})
  for (const args of [[], ['--capture'], ['--compare'], ['--capture', '--compare', '--output', baselinePath],
    ['--capture', '--output', baselinePath, '--output', candidatePath], ['--capture', '--output', baselinePath, '--corpus', temporary],
    ['--capture', '--output', baselinePath, '--fail-above-percent', '10'], ['--compare', '--baseline', baselinePath, '--output', candidatePath],
    ['--compare', '--baseline', baselinePath, '--candidate', candidatePath, '--warmup', '1'],
    ['--capture', '--output', baselinePath, '--iterations', '10000', '--samples', '100']]) assert.throws(() => P.parseArgs(args))
  for (const [option, values] of [['warmup', ['-1', '10001', '1.5', '01', 'NaN', 'Infinity', '1e2']],
    ['samples', ['0', '1', '101']], ['iterations', ['0', '10001', '9007199254740992']]]) {
    for (const value of values) assert.throws(() => P.parseArgs(['--capture', '--output', baselinePath, '--' + option, value]))
  }
  for (const value of ['0', '1001', '1.1', 'no']) assert.throws(() => P.parseArgs(['--compare', '--baseline', baselinePath, '--fail-above-percent', value]))
  assert.throws(() => P.statistics([], 1), /Invalid/)
  assert.throws(() => P.statistics([1, NaN], 1), /Invalid/)
  assert.throws(() => P.statistics([-1, 1], 1), /Invalid/)
  const math = P.statistics([4, 1, 3, 2], 10)
  assert.equal(math.avgMs, 2.5)
  assert.equal(math.p50Ms, 2)
  assert.equal(math.p95Ms, 4)
  assert.equal(math.minMs, 1)
  assert.equal(math.maxMs, 4)
  assert.equal(math.totalMeasuredMs, 100)
  assert.equal(math.operations, 40)
  assert.equal(math.operationsPerSecond, 400)
  assert.equal(math.stddevMs, Math.sqrt(1.25))
  assert.equal(P.statistics([0, 0], 1).operationsPerSecond, null)
  assert.equal(P.statistics(Array.from({length: 20}, (_, i) => i + 1), 1).p95Ms, 19)
  run(['--help'])
  run(['--capture', '--output', path.join(temporary, 'missing', 'report.json'), ...small], 1)
  run(['--capture', '--output', cli, ...small], 1)
  run(['--compare', '--baseline', baselinePath], 1)
  assert(!fs.existsSync(baselinePath))
  const controls = `
    const assert = require('node:assert/strict');
    const {performance} = require('node:perf_hooks');
    const {configureDeterminism} = require(${JSON.stringify(path.join(__dirname, 'runtime-baseline.js'))});
    const reset = configureDeterminism();
    const start = performance.now(), wall = Date.now();
    while (performance.now() - start < 2) {}
    assert.equal(Date.now(), wall);
    assert(performance.now() > start);
    assert.equal(new Date().getTimezoneOffset(), 0);
    const random = Math.random(); reset(); assert.equal(Math.random(), random);
    for (const action of [() => fetch('https://invalid.test'), () => globalThis.__veraHttp(), () => globalThis.__veraResolve(),
      () => require('node:http').get('http://invalid.test'), () => require('node:https').get('https://invalid.test'),
      () => require('node:net').connect(1), () => require('node:tls').connect(1), () => require('node:http2').connect('https://invalid.test'),
      () => require('node:dgram').createSocket('udp4'), () => require('node:dns').lookup('invalid.test'),
      () => require('node:dns').promises.lookup('invalid.test')]) assert.throws(action, /prohibited/);
  `
  script(controls, 0, {TZ: 'Pacific/Honolulu'})
  run(['--capture', '--output', baselinePath, ...small], 0, {TZ: 'Pacific/Honolulu'})
  const bytes = fs.readFileSync(baselinePath, 'utf8'), baseline = P.readReport(baselinePath)
  if (posix) assert.equal(fs.statSync(baselinePath).mode & 0o777, 0o600)
  assert.equal(baseline.workloads.length, 13)
  assert.equal(baseline.provenance.fixtures.length, 3)
  assert(baseline.provenance.sources.some(source => source.path.endsWith('VeraInterpreter.ets')))
  assert(baseline.provenance.sources.some(source => source.path.endsWith('VeraCompiler.ets')))
  assert(baseline.provenance.sources.every(source => /^[a-f0-9]{64}$/.test(source.sha256)))
  assert.equal(baseline.environment.timezone, 'UTC')
  assert(baseline.environment.cpuModels.length)
  assert(baseline.limitations.some(item => item.includes('not a phone')))
  assert(baseline.workloads.some(workload => workload.id === 'surface-catch/draw-decode'))
  assert(baseline.workloads.every(workload => workload.samplesMs.length === 2 && workload.statistics.operations === 4))
  P.atomicWrite(candidatePath, baseline)
  assert.equal(P.compareReports(baseline, baseline).failed, false)
  const comparison = JSON.parse(run(['--compare', '--baseline', baselinePath, '--candidate', candidatePath]))
  assert.equal(comparison.failed, false)
  assert(comparison.deltas.every(delta => delta.metrics.p50Ms.deltaPercent === 0))
  assert.equal(fs.readFileSync(baselinePath, 'utf8'), bytes)
  const fresh = JSON.parse(run(['--compare', '--baseline', baselinePath], 0, {TZ: 'Asia/Shanghai'}))
  assert.equal(fresh.compatible, true)
  assert.equal(fresh.failAbovePercent, null)
  assert.equal(fresh.phoneGate, false)
  assert.equal(fs.readFileSync(baselinePath, 'utf8'), bytes)
  for (const mutate of [r => { r.settings.warmup++ }, r => { r.environment.node = 'different' },
    r => { r.environment.cpuModels = [['different', 1]] }, r => { r.protocol.randomSeed++ },
    r => { r.workloads.reverse() }]) {
    const different = clone(baseline)
    mutate(different)
    assert.throws(() => P.compareReports(baseline, different), /Incompatible/)
  }
  const badSignature = clone(baseline)
  badSignature.workloads[0].descriptor.args.push(100)
  assert.throws(() => P.validateReport(badSignature), /signature/)
  badSignature.workloads[0].signature = crypto.createHash('sha256').update(JSON.stringify(canonical(badSignature.workloads[0].descriptor))).digest('hex')
  assert.throws(() => P.compareReports(baseline, badSignature), /workload signatures/)
  const invalidStatistics = clone(baseline)
  invalidStatistics.workloads[0].statistics.avgMs++
  assert.throws(() => P.validateReport(invalidStatistics), /statistics/)
  const invalidSamples = clone(baseline)
  invalidSamples.workloads[0].samplesMs.pop()
  assert.throws(() => P.validateReport(invalidSamples), /statistics/)
  const provenanceOnly = clone(baseline)
  provenanceOnly.provenance.revision = 'different-runtime-revision'
  assert.equal(P.compareReports(baseline, provenanceOnly).compatible, true)
  const one = retime(baseline, [1, 1]), slower = retime(baseline, [2, 2])
  const delta = P.compareReports(one, slower)
  assert.equal(delta.failed, false)
  assert.equal(delta.deltas[0].metrics.avgMs.deltaMs, 1)
  assert.equal(delta.deltas[0].metrics.p50Ms.deltaPercent, 100)
  assert.equal(P.compareReports(retime(baseline, [0, 0]), one).deltas[0].metrics.p50Ms.deltaPercent, null)
  assert.throws(() => P.compareReports(one, slower, 10), /Opt-in/)
  const gateBaseline = retime(baseline, Array(10).fill(1), 10)
  gateBaseline.settings.warmup = 20
  const gateSlower = retime(gateBaseline, Array(10).fill(2))
  assert.equal(P.compareReports(gateBaseline, gateSlower, 50).failed, true)
  assert.equal(P.compareReports(gateBaseline, gateSlower, 100).failed, false)
  P.atomicWrite(baselinePath, gateBaseline)
  P.atomicWrite(candidatePath, gateSlower)
  const gateBytes = fs.readFileSync(baselinePath, 'utf8'), candidateBytes = fs.readFileSync(candidatePath, 'utf8')
  run(['--compare', '--baseline', baselinePath, '--candidate', candidatePath])
  run(['--compare', '--baseline', baselinePath, '--candidate', candidatePath, '--fail-above-percent', '50'], 1)
  assert.equal(fs.readFileSync(baselinePath, 'utf8'), gateBytes)
  assert.equal(fs.readFileSync(candidatePath, 'utf8'), candidateBytes)
  const incompatible = clone(gateSlower)
  incompatible.environment.arch = 'different'
  P.atomicWrite(candidatePath, incompatible)
  assert.match(run(['--compare', '--baseline', baselinePath, '--candidate', candidatePath], 1), /Incompatible/)
  const unrelated = path.join(temporary, 'unrelated.json')
  fs.writeFileSync(unrelated, '{"keep":"untouched"}')
  assert.throws(() => P.atomicWrite(unrelated, baseline), /Unsupported/)
  assert.equal(fs.readFileSync(unrelated, 'utf8'), '{"keep":"untouched"}')
  const malformed = path.join(temporary, 'malformed.json')
  fs.writeFileSync(malformed, '{broken')
  run(['--compare', '--baseline', malformed, '--candidate', candidatePath], 1)
  assert.equal(fs.readFileSync(malformed, 'utf8'), '{broken')
  const oversized = path.join(temporary, 'oversized.json')
  fs.writeFileSync(oversized, ' '.repeat(8 * 1024 * 1024 + 1))
  assert.throws(() => P.readReport(oversized), /size limit/)
  for (const file of [path.join(__dirname, 'examples/hello.vera'), path.join(__dirname, 'source-loader.js'), path.join(__dirname, 'new-report.json')]) assert.throws(() => P.outputTarget(file), /repository/)
  if (posix) {
    const symlink = path.join(temporary, 'symlink.json'), dangling = path.join(temporary, 'dangling.json')
    fs.symlinkSync(baselinePath, symlink)
    fs.symlinkSync(path.join(temporary, 'absent.json'), dangling)
    for (const link of [symlink, dangling]) {
      assert.throws(() => P.atomicWrite(link, baseline), /Symlinks/)
      assert.throws(() => P.readReport(link), /Symlinks/)
      assert(fs.lstatSync(link).isSymbolicLink())
    }
    const linkDirectory = path.join(temporary, 'linked-directory')
    fs.symlinkSync(temporary, linkDirectory)
    assert.throws(() => P.atomicWrite(path.join(linkDirectory, 'escape.json'), baseline), /Symlinks/)
  }
  const hardlink = path.join(temporary, 'hardlink.json')
  fs.linkSync(baselinePath, hardlink)
  assert.throws(() => P.atomicWrite(hardlink, baseline), /hardlinks/)
  assert.throws(() => P.readReport(hardlink), /hardlinks/)
  fs.unlinkSync(hardlink)
  fs.chmodSync(candidatePath, 0o644)
  P.atomicWrite(candidatePath, baseline)
  if (posix) assert.equal(fs.statSync(candidatePath).mode & 0o777, 0o600)
  assert(!fs.readdirSync(temporary).some(name => name.endsWith('.tmp')))
  const originalRename = fs.renameSync
  try {
    fs.renameSync = () => { throw Error('synthetic atomic replacement failure') }
    assert.throws(() => P.atomicWrite(baselinePath, baseline), /synthetic/)
    assert.equal(fs.readFileSync(baselinePath, 'utf8'), gateBytes)
  } finally { fs.renameSync = originalRename }
  assert(!fs.readdirSync(temporary).some(name => name.endsWith('.tmp')))
  assert.match(run(['--capture', '--output', path.join(temporary, 'bad-ts.json'), ...small], 1,
    {VERA_TYPESCRIPT_PATH: path.join(temporary, 'missing-typescript')}), /Cannot find module/)
  assert(!fs.existsSync(path.join(temporary, 'bad-ts.json')))
  assert.match(run(['--capture', '--output', path.join(temporary, 'bad-root.json'), ...small], 1,
    {VERA_SOURCE_ROOT: temporary}), /current repository ETS/)
  script(`
    const assert = require('node:assert/strict');
    const P = require(${JSON.stringify(cli)});
    P.resolveTypeScript();
    const loader = require(${JSON.stringify(path.join(__dirname, 'source-loader.js'))});
    const C = loader.loadVera('VeraCompiler'), V = loader.loadVera('VeraInterpreter');
    let compilations = 0, deserializations = 0, constructions = 0;
    const compile = C.compileVeraSource, deserialize = V.deserializeVbc2, VM = V.VirtualMachine;
    C.compileVeraSource = (...args) => { compilations++; return compile(...args) };
    V.deserializeVbc2 = (...args) => { deserializations++; return deserialize(...args) };
    V.VirtualMachine = class extends VM { constructor(...args) { super(...args); constructions++ } };
    const first = P.collect({warmup: 0, samples: 2, iterations: 1});
    assert.equal(compilations, 3); assert.equal(deserializations, 3); assert.equal(constructions, 3);
    const second = P.collect({warmup: 0, samples: 2, iterations: 1});
    assert.equal(P.compareReports(first, second).compatible, true);
    assert(first.workloads.every(w => w.statistics.totalMeasuredMs >= 0));
  `)
  console.log('runtime-performance-check: ok; bounded CLI, timing math, compatibility/deltas/opt-in gate, offline controls, atomic 0600/path safety and actual current-ETS benchmark smoke')
} finally {
  fs.rmSync(temporary, {recursive: true, force: true})
}
