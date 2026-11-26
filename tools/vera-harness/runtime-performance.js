#!/usr/bin/env node
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const crypto = require('node:crypto')
const {spawnSync} = require('node:child_process')
const {performance} = require('node:perf_hooks')
const {canonical, configureDeterminism} = require('./runtime-baseline')
const WallDate = Date

const ROOT = path.resolve(__dirname, '../..')
const FORMAT = 'vera-runtime-performance'
const VERSION = 1
const MAX_REPORT_BYTES = 8 * 1024 * 1024
const DEFAULTS = {warmup: 50, samples: 15, iterations: 50}
const FIXTURES = ['hello', 'visual-countdown', 'surface-catch']
const USAGE = 'usage: node tools/vera-harness/runtime-performance.js --capture --output FILE | --compare --baseline FILE [--candidate FILE] [--warmup 0..10000] [--samples 2..100] [--iterations 1..10000] [--fail-above-percent 1..1000 (compare only, opt-in host p50 gate)]\nCompare is read-only and prints JSON; candidate defaults to a fresh run. Capture output must be outside the repository. Host timing is diagnostic, never a phone gate.'
const LIMITATIONS = [
  'Host Node timing is diagnostic only, not a phone performance or compatibility gate.',
  'Current ETS via source-loader with platform stubs; no ArkTS typecheck, ArkUI layout, native painting, SDK, model, network or device execution.',
  'Only three fixed public examples and fixed in-memory states; no saved/private corpus, arbitrary handlers, persistence I/O, async scheduling or cold-start timing.',
  'Compilation, source loading, bytecode deserialization, VM construction and fixture setup are excluded from measurement; init measures VM entry execution only.',
  'View/decode and draw/decode include VM execution and data decoding, not native rendering. State roundtrip includes tagged encoding, JSON stringify/parse and tagged decoding.',
  'Fixed input per iteration and reused VM caches, sequential workloads, natural GC, no forced collection or loop-overhead subtraction. Warmup cannot guarantee stable JIT or host load.',
  'Compatibility requires matching workload signatures, protocol, options and recorded host environment, but cannot ensure equal thermals, CPU governor, background load or scheduling.',
  'Output path checks reject symlinks and hardlinks; use a trusted output directory, not one concurrently modified by another process.'
]
const hash = value => crypto.createHash('sha256').update(value).digest('hex')
const stable = value => JSON.stringify(canonical(value))
const same = (a, b) => stable(a) === stable(b)

function settings(options = {}) {
  const result = {}
  for (const [key, min, max] of [['warmup', 0, 10000], ['samples', 2, 100], ['iterations', 1, 10000]]) {
    const value = options[key] === undefined ? DEFAULTS[key] : options[key]
    if (!Number.isSafeInteger(value) || value < min || value > max) throw Error(`Invalid ${key}: expected integer ${min}..${max}`)
    result[key] = value
  }
  if (result.warmup + result.samples * result.iterations > 100000) throw Error('Work budget exceeds 100000 operations per workload')
  return result
}
function threshold(value) {
  if (value !== undefined && (!Number.isSafeInteger(value) || value < 1 || value > 1000)) throw Error('Invalid fail-above-percent: expected integer 1..1000')
  return value
}
function parseArgs(args) {
  const result = {}, seen = new Set()
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (seen.has(arg)) throw Error('Duplicate option: ' + arg)
    seen.add(arg)
    if (arg === '--capture' || arg === '--compare') {
      if (result.mode) throw Error(USAGE)
      result.mode = arg.slice(2)
    } else if (['--output', '--baseline', '--candidate', '--warmup', '--samples', '--iterations', '--fail-above-percent'].includes(arg)) {
      const value = args[++i]
      if (!value || value.startsWith('-')) throw Error('Missing value for ' + arg)
      if (['--output', '--baseline', '--candidate'].includes(arg)) result[arg.slice(2)] = path.resolve(value)
      else {
        if (!/^(0|[1-9][0-9]*)$/.test(value)) throw Error('Invalid integer for ' + arg)
        result[arg === '--fail-above-percent' ? 'failAbovePercent' : arg.slice(2)] = Number(value)
      }
    } else throw Error(USAGE)
  }
  settings(result)
  threshold(result.failAbovePercent)
  if (result.mode === 'capture') {
    if (!result.output || result.baseline || result.candidate || result.failAbovePercent !== undefined) throw Error(USAGE)
  } else if (result.mode === 'compare') {
    if (!result.baseline || result.output) throw Error(USAGE)
    if (result.candidate && ['warmup', 'samples', 'iterations'].some(k => result[k] !== undefined)) throw Error('Candidate reports already specify timing options')
  } else throw Error(USAGE)
  return result
}
function statistics(samplesMs, iterations) {
  if (!Array.isArray(samplesMs) || samplesMs.length < 2 || samplesMs.some(n => !Number.isFinite(n) || n < 0) || !Number.isSafeInteger(iterations) || iterations < 1) throw Error('Invalid timing samples')
  const sorted = [...samplesMs].sort((a, b) => a - b)
  const sum = samplesMs.reduce((a, b) => a + b, 0), avgMs = sum / samplesMs.length
  const stddevMs = Math.sqrt(samplesMs.reduce((n, x) => n + (x - avgMs) ** 2, 0) / samplesMs.length)
  return {samples: samplesMs.length, operations: samplesMs.length * iterations, totalMeasuredMs: sum * iterations,
    minMs: sorted[0], avgMs, p50Ms: sorted[Math.ceil(sorted.length * 0.5) - 1], p95Ms: sorted[Math.ceil(sorted.length * 0.95) - 1],
    maxMs: sorted[sorted.length - 1], stddevMs, coefficientOfVariationPercent: avgMs ? stddevMs / avgMs * 100 : null,
    operationsPerSecond: avgMs ? 1000 / avgMs : null}
}
function noSymlinks(file) {
  const resolved = path.resolve(file), root = path.parse(resolved).root
  const parts =  path.relative(root, resolved).split(path.sep).filter(Boolean)
  let current = root
  for (let i = 0; i < parts.length; i++) {
    current = path.join(current, parts[i])
    let stat
    try { stat = fs.lstatSync(current) } catch (e) {
      if (e.code === 'ENOENT' && i === parts.length - 1) return null
      throw e
    }
    if (stat.isSymbolicLink()) throw Error('Symlinks are prohibited: ' + current)
    if (i < parts.length - 1 && !stat.isDirectory()) throw Error('Parent must be an existing directory')
    if (i === parts.length - 1) return stat
  }
  throw Error('Expected a file path')
}
function regular(stat) {
  if (!stat || !stat.isFile() || stat.nlink !== 1) throw Error('Report must be a regular file with no hardlinks')
  if (stat.size > MAX_REPORT_BYTES) throw Error('Report exceeds size limit')
}
function readReport(file) {
  regular(noSymlinks(file))
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
  try {
    regular(fs.fstatSync(fd))
    return validateReport(JSON.parse(fs.readFileSync(fd, 'utf8')))
  } finally { fs.closeSync(fd) }
}
function outputTarget(file) {
  file = path.resolve(file)
  const stat = noSymlinks(file), realRoot = fs.realpathSync(ROOT)
  if (file === realRoot || file.startsWith(realRoot + path.sep) || file === ROOT || file.startsWith(ROOT + path.sep)) throw Error('Output must not overwrite repository or harness inputs; select a path outside the repository')
  if (stat) { regular(stat); readReport(file) }
  return {file, stat, parent: fs.statSync(path.dirname(file))}
}
function unchanged(a, b) {
  return a === null ? b === null : b !== null && a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs
}
function atomicWrite(file, report) {
  validateReport(report)
  const target = outputTarget(file), bytes = JSON.stringify(report, null, 2) + '\n'
  if (Buffer.byteLength(bytes) > MAX_REPORT_BYTES) throw Error('Report exceeds size limit')
  const temporary = path.join(path.dirname(target.file), '.vera-performance-' + crypto.randomBytes(16).toString('hex') + '.tmp')
  let fd
  try {
    fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600)
    fs.fchmodSync(fd, 0o600)
    fs.writeFileSync(fd, bytes)
    fs.fsyncSync(fd)
    fs.closeSync(fd)
    fd = undefined
    const current = outputTarget(target.file)
    if (!unchanged(target.stat, current.stat) || target.parent.dev !== current.parent.dev || target.parent.ino !== current.parent.ino) throw Error('Output changed during capture')
    if (target.stat) fs.renameSync(temporary, target.file)
    else fs.linkSync(temporary, target.file)
  } finally {
    if (fd !== undefined) fs.closeSync(fd)
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary)
  }
}
function resolveTypeScript() {
  const resolution = Object.hasOwn(process.env, 'VERA_TYPESCRIPT_PATH') ? 'VERA_TYPESCRIPT_PATH' : 'tool-paths.sh:dirname(HVIGORW)/../hvigor'
  let modulePath
  if (Object.hasOwn(process.env, 'VERA_TYPESCRIPT_PATH')) {
    if (!process.env.VERA_TYPESCRIPT_PATH) throw Error('VERA_TYPESCRIPT_PATH is explicitly empty')
    modulePath = require.resolve(process.env.VERA_TYPESCRIPT_PATH)
  } else {
    const found = spawnSync('bash', ['-c', 'source ./tool-paths.sh && vera_hvigorw'], {cwd: ROOT, encoding: 'utf8', timeout: 10000})
    if (found.error || found.status !== 0) throw Error((found.stderr || found.error?.message || 'Cannot resolve Hvigor').trim())
    const wrapper = found.stdout.trim()
    if (!path.isAbsolute(wrapper) || wrapper.includes('\n')) throw Error('Invalid Hvigor wrapper path')
    modulePath = require.resolve('typescript', {paths: [path.resolve(path.dirname(wrapper), '../hvigor')]})
    process.env.VERA_TYPESCRIPT_PATH = modulePath
  }
  const ts = require(modulePath)
  return {version: ts.version, moduleSha256: hash(fs.readFileSync(modulePath)), resolution}
}
function sourceProvenance(sourceRoot) {
  const files = new Map()
  function visit(file) {
    file = fs.realpathSync(file)
    if (files.has(file)) return
    if (!file.startsWith(ROOT + path.sep)) throw Error('Source dependency outside repository')
    const source = fs.readFileSync(file, 'utf8')
    files.set(file, {path: path.relative(ROOT, file).split(path.sep).join('/'), sha256: hash(source)})
    for (const match of source.matchAll(/\bfrom\s*['"]([^'"]+)['"]/g)) {
      if (match[1].endsWith('/VeraSdkIndex')) visit(path.join(__dirname, 'src/VeraSdkIndex.ts'))
      else if (match[1].startsWith('.')) visit(path.resolve(path.dirname(file), match[1] + '.ets'))
    }
  }
  for (const name of ['VeraCompiler', 'VeraInterpreter', 'VeraUi', 'VeraGfx']) visit(path.join(sourceRoot, 'vera', name + '.ets'))
  return [...files.values()].sort((a, b) => a.path.localeCompare(b.path))
}
function environment(typescript) {
  const cpus = os.cpus(), models = new Map()
  for (const cpu of cpus) models.set(cpu.model, (models.get(cpu.model) || 0) + 1)
  return {node: process.version, v8: process.versions.v8, typescript: {version: typescript.version, moduleSha256: typescript.moduleSha256},
    platform: process.platform, arch: process.arch, endianness: os.endianness(), osType: os.type(), osRelease: os.release(), osVersion: os.version(),
    cpuModels: [...models].sort(), logicalCpus: cpus.length, availableParallelism: os.availableParallelism ? os.availableParallelism() : cpus.length,
    totalMemoryBytes: os.totalmem(), execArgv: process.execArgv, nodeOptionsSha256: hash(process.env.NODE_OPTIONS || ''),
    timezone: 'UTC', locale: Intl.DateTimeFormat().resolvedOptions().locale}
}
function prepareWorkloads(loader, reset) {
  const C = loader.loadVera('VeraCompiler'), V = loader.loadVera('VeraInterpreter'), U = loader.loadVera('VeraUi'), G = loader.loadVera('VeraGfx')
  const workloads = [], fixtures = []
  for (const name of FIXTURES) {
    reset()
    const relative = 'tools/vera-harness/examples/' + name + '.vera'
    const source = fs.readFileSync(path.join(ROOT, relative), 'utf8'), bytecode = C.compileVeraSource(source).vbc2
    const host = new U.UiHostEnvironment(), vm = new V.VirtualMachine(V.deserializeVbc2(bytecode), host, 5000000)
    host.effectsAllowed = false
    let state = vm.execute('init', [])
    const setup = []
    if (name === 'surface-catch') {
      setup.push({entry: 'onPointer', pointer: ['down', 0, 180, 590]}, {entry: 'onFrame', value: 16, repeat: 40})
      state = vm.execute('onPointer', [state, G.pointerValue('down', 0, 180, 590)])
      for (let i = 0; i < 40; i++) state = vm.execute('onFrame', [state, new V.VeraNumberValue(16)])
    }
    const saved = stable(V.encodeRuntimeValue(state))
    fixtures.push({path: relative, sourceSha256: hash(source), bytecodeSha256: hash(bytecode), stateSha256: hash(saved), stateJsonBytes: Buffer.byteLength(saved), setup})
    const handler = name === 'hello' ? 'increment' : name === 'surface-catch' ? 'onFrame' : 'tick'
    const handlerValue = name === 'hello' ? 3 : name === 'surface-catch' ? 16 : 1000
    const stateArgs = [state], handlerArgs = [state, new V.VeraNumberValue(handlerValue)]
    const runtimeFingerprint = value => hash(stable(V.encodeRuntimeValue(value)))
    function add(operation, entry, args, run, fingerprint = value => hash(stable(value))) {
      const descriptor = {protocol: 1, fixture: relative, sourceSha256: hash(source), stateSha256: hash(saved), setup, operation, entry, args}
      const before = run(), outputSha256 = fingerprint(before)
      if (fingerprint(run()) !== outputSha256) throw Error('Nondeterministic workload: ' + name + '/' + operation)
      if (host.pendingEffects.length || stable(V.encodeRuntimeValue(state)) !== saved) throw Error('Workload must not mutate its fixed input or queue effects')
      descriptor.outputSha256 = outputSha256
      workloads.push({id: name + '/' + operation, descriptor, signature: hash(stable(descriptor)), run, fingerprint,
        verify() { if (host.pendingEffects.length || stable(V.encodeRuntimeValue(state)) !== saved) throw Error('Workload mutated input or queued effects') }})
    }
    add('init', 'init', [], () => vm.execute('init', []), runtimeFingerprint)
    add('handler', handler, [handlerValue], () => vm.execute(handler, handlerArgs), runtimeFingerprint)
    add('view-decode', 'view', [], () => U.decodeVeraUi(vm.execute('view', stateArgs)))
    if (name === 'surface-catch') add('draw-decode', 'draw', [], () => G.decodeGfx(vm.execute('draw', stateArgs)))
    add('state-roundtrip', null, [], () => V.decodeRuntimeValue(JSON.parse(JSON.stringify(V.encodeRuntimeValue(state)))), runtimeFingerprint)
  }
  return {workloads, fixtures}
}
function collect(options = {}) {
  const timing = settings(options), createdAt = new WallDate().toISOString()
  const typescript = resolveTypeScript()
  const expectedRoot = fs.realpathSync(path.join(ROOT, 'entry/src/main/ets'))
  if (process.env.VERA_SOURCE_ROOT && fs.realpathSync(process.env.VERA_SOURCE_ROOT) !== expectedRoot) throw Error('Performance tooling requires current repository ETS, not VERA_SOURCE_ROOT overrides')
  const reset = configureDeterminism(), loader = require('./source-loader')
  if (fs.realpathSync(loader.sourceRoot) !== expectedRoot) throw Error('source-loader is not using current repository ETS')
  const host = environment(typescript), sources = sourceProvenance(loader.sourceRoot)
  const {workloads, fixtures} = prepareWorkloads(loader, reset)
  const started = performance.now(), loadBefore = os.loadavg(), records = []
  for (const workload of workloads) {
    reset()
    let sink
    for (let i = 0; i < timing.warmup; i++) sink = workload.run()
    const samplesMs = []
    for (let sample = 0; sample < timing.samples; sample++) {
      if (performance.now() - started > 120000) throw Error('Performance suite exceeded 120 second measurement budget')
      reset()
      const start = performance.now()
      for (let i = 0; i < timing.iterations; i++) sink = workload.run()
      const elapsed = performance.now() - start
      samplesMs.push(elapsed / timing.iterations)
      if (workload.fingerprint(sink) !== workload.descriptor.outputSha256) throw Error('Workload output changed: ' + workload.id)
      workload.verify()
    }
    records.push({id: workload.id, signature: workload.signature, descriptor: workload.descriptor, samplesMs,
      statistics: statistics(samplesMs, timing.iterations)})
  }
  const revision = spawnSync('git', ['rev-parse', 'HEAD'], {cwd: ROOT, encoding: 'utf8', timeout: 10000})
  const dirty = spawnSync('git', ['status', '--porcelain', '--untracked-files=normal'], {cwd: ROOT, encoding: 'utf8', timeout: 10000})
  return validateReport({format: FORMAT, version: VERSION, diagnosticOnly: true, createdAt,
    protocol: {clock: 'node:perf_hooks.performance.now', units: 'milliseconds-per-operation', percentile: 'nearest-rank',
      input: 'fixed-per-iteration', vm: 'reused', gc: 'natural', maxStepsPerCall: 5000000, epochMillis: 1767268800000, randomSeed: 0x13579bdf,
      toolSha256: hash(fs.readFileSync(__filename)), sourceLoaderSha256: hash(fs.readFileSync(path.join(__dirname, 'source-loader.js'))),
      determinismSha256: hash(fs.readFileSync(path.join(__dirname, 'runtime-baseline.js')))},
    settings: timing, environment: host, provenance: {revision: revision.status === 0 ? revision.stdout.trim() : null,
      dirty: dirty.status === 0 ? Boolean(dirty.stdout.trim()) : null, typescriptResolution: typescript.resolution, sources, fixtures},
    observations: {loadAverageBefore: loadBefore, loadAverageAfter: os.loadavg(), elapsedMeasurementMs: performance.now() - started,
      cpuSpeedMHz: os.cpus().map(cpu => cpu.speed)}, limitations: LIMITATIONS, workloads: records})
}
function validateReport(report) {
  if (!report || report.format !== FORMAT || report.version !== VERSION || report.diagnosticOnly !== true) throw Error('Unsupported performance report format/version')
  if (!same(settings(report.settings), report.settings)) throw Error('Invalid report settings')
  if (!report.environment || typeof report.environment.node !== 'string' || !report.protocol || report.protocol.clock !== 'node:perf_hooks.performance.now' || !report.provenance || !Array.isArray(report.provenance.sources)) throw Error('Invalid report environment/provenance/protocol')
  if (!Array.isArray(report.workloads) || report.workloads.length !== 13) throw Error('Invalid report workload count')
  const ids = new Set()
  for (const workload of report.workloads) {
    if (!workload || typeof workload.id !== 'string' || ids.has(workload.id) || !workload.descriptor || workload.signature !== hash(stable(workload.descriptor))) throw Error('Invalid workload signature/id')
    ids.add(workload.id)
    if (!Array.isArray(workload.samplesMs) || workload.samplesMs.length !== report.settings.samples || !same(statistics(workload.samplesMs, report.settings.iterations), workload.statistics)) throw Error('Invalid workload timing statistics')
  }
  return report
}
function compareReports(baseline, candidate, failAbovePercent) {
  validateReport(baseline)
  validateReport(candidate)
  threshold(failAbovePercent)
  for (const key of ['settings', 'environment', 'protocol']) {
    if (!same(baseline[key], candidate[key])) throw Error('Incompatible performance reports: ' + key)
  }
  if (!same(baseline.workloads.map(w => [w.id, w.signature]), candidate.workloads.map(w => [w.id, w.signature]))) throw Error('Incompatible performance reports: workload signatures/order')
  if (failAbovePercent !== undefined && (baseline.settings.warmup < 20 || baseline.settings.samples < 10 || baseline.settings.iterations < 10 ||
    [...baseline.workloads, ...candidate.workloads].some(w => w.statistics.p50Ms * baseline.settings.iterations < 1))) throw Error('Opt-in host timing gate requires warmup >=20, samples >=10, iterations >=10 and median sample batches >=1ms')
  const deltas = baseline.workloads.map((before, i) => {
    const after = candidate.workloads[i]
    const metrics = {}
    for (const key of ['avgMs', 'p50Ms', 'p95Ms', 'maxMs']) {
      const a = before.statistics[key], b = after.statistics[key]
      metrics[key] = {baseline: a, candidate: b, deltaMs: b - a, deltaPercent: a === 0 ? null : (b - a) / a * 100}
    }
    return {id: before.id, signature: before.signature, metrics,
      exceedsExplicitHostThreshold: failAbovePercent !== undefined && metrics.p50Ms.deltaPercent > failAbovePercent}
  })
  return {format: 'vera-runtime-performance-comparison', version: 1, compatible: true, diagnosticOnly: true,
    phoneGate: false, failAbovePercent: failAbovePercent ?? null, gateMetric: failAbovePercent === undefined ? null : 'p50Ms',
    failed: deltas.some(d => d.exceedsExplicitHostThreshold), baselineProvenance: baseline.provenance, candidateProvenance: candidate.provenance,
    settings: candidate.settings, environment: candidate.environment, deltas,
    warning: 'Host timings are noisy diagnostics, not phone evidence. No timing failure unless an explicit host-only threshold was requested.'}
}
function main(args) {
  if (args.length === 1 && args[0] === '--help') { console.log(USAGE); return }
  const options = parseArgs(args)
  if (options.mode === 'capture') {
    outputTarget(options.output)
    const report = collect(options)
    atomicWrite(options.output, report)
    console.log(`runtime-performance: captured ${report.workloads.length} offline host workloads to ${options.output}; diagnostic only, not a phone gate`)
  } else {
    const baseline = readReport(options.baseline)
    const candidate = options.candidate ? readReport(options.candidate) : collect({...baseline.settings, ...options})
    const comparison = compareReports(baseline, candidate, options.failAbovePercent)
    console.log(JSON.stringify(comparison, null, 2))
    if (comparison.failed) process.exitCode = 1
  }
}
module.exports = {parseArgs, settings, statistics, validateReport, readReport, outputTarget, atomicWrite, compareReports, collect, resolveTypeScript}
if (require.main === module) {
  try { main(process.argv.slice(2)) }
  catch (error) { console.error('runtime-performance: ' + error.message); process.exitCode = 1 }
}
