#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const crypto = require('node:crypto')
const {spawnSync} = require('node:child_process')
const B = require('./offline-baseline')
const posix = process.platform !== 'win32'

const ROOT = path.resolve(__dirname, '../..')
const cli = path.join(__dirname, 'offline-baseline.js')
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-offline-baseline-check-'))
const names = ['runtime.json', 'orchestration.json', 'host-performance.json', 'runtime-input-traces.json', 'manifest.json']
const roles = ['runtime', 'orchestration', 'host-performance', 'runtime-input-traces']
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const clone = value => JSON.parse(JSON.stringify(value))
const secret = 'private-prompt-state-key-88c1'
const calls = []
const runtime = {coverage: {summary: {cases: 2, ok: 1, errors: 1, external: 0}, corpusGaps: ['Missing bytecode'], limitations: ['Headless only']},
  cases: [{id: 'public/ok', status: 'ok', gaps: ['Untested handler']},
    {id: 'public/error', status: 'error', error: {phase: 'compile', code: 'E001', message: secret,
      diagnostics: [{code: 'E001', message: secret}, {code: 'E002', message: secret}]}, gaps: []}]}
const trace = {scenarios: [{name: 'public-mocked-scenario'}], limitations: ['MOCKED only']}
const inputTraces = {schema: 'vera-stage-trace-baseline-v1', environment: 'MOCKED_PLATFORM_REAL_VM', comparison: 'FULL_EXACT_SEQUENCE',
  normalization: {timestamps: 'zero; order retained'}, limitations: ['Real current VM; mocked platform APIs/storage; synthetic input.'],
  scenarios: [{name: 'field/public-input', environment: 'MOCKED_PLATFORM_REAL_VM',
    segments: [[{session: 'session-1', event: 'HANDLER_START', at: 0, attributes: {}}]]}]}
const host = {workloads: [{id: 'public/init', statistics: {p50Ms: 0.1, p95Ms: 0.2}}]}
const hostComparison = {format: 'vera-runtime-performance-comparison', version: 1, compatible: true, diagnosticOnly: true,
  deltas: [{id: 'public/init', metrics: {p50Ms: {baseline: 0.1, candidate: 0.2, deltaMs: 0.1, deltaPercent: 100}}}]}
const source = {head: 'a'.repeat(40), status: [{status: ' M', path: 'public.ets'}],
  files: [{path: 'entry/src/main/ets/public.ets', sha256: 'b'.repeat(64), sizeBytes: 3}]}
function write(file, value) {
  fs.writeFileSync(file, typeof value === 'string' || Buffer.isBuffer(value) ? value : JSON.stringify(value), {mode: 0o600})
  fs.chmodSync(file, 0o600)
}
function read(directory, name = 'manifest.json') { return JSON.parse(fs.readFileSync(path.join(directory, name), 'utf8')) }
function snapshot(directory) {
  return {mode: fs.statSync(directory).mode, files: fs.readdirSync(directory).sort().map(name => {
    const stat = fs.statSync(path.join(directory, name))
    return {name, sha256: digest(fs.readFileSync(path.join(directory, name))), mode: stat.mode, mtimeMs: stat.mtimeMs, ctimeMs: stat.ctimeMs}
  })}
}
function command(args, status = 0, env = {}) {
  const result = spawnSync(process.execPath, [cli, ...args], {cwd: ROOT, encoding: 'utf8',
    timeout: 600000, maxBuffer: 1024 * 1024, env: {...process.env, ...env}})
  assert.ifError(result.error)
  assert.equal(result.status, status, result.stdout + result.stderr)
  assert(!result.stdout.includes(secret) && !result.stderr.includes(secret))
  return result.stdout + result.stderr
}
const dependencies = {resolveTypeScript: () => ({version: 'test', moduleSha256: 'c'.repeat(64), resolution: 'test'}),
  provenance: () => clone(source), runChild(command, env) {
    calls.push(command)
    assert.equal(env.TZ, 'UTC')
    if (command.args.includes('--capture') || command.args.includes('--capture-runtime-traces')) {
      const file = command.args[command.args.indexOf('--output') + 1]
      write(file, command.role === 'runtime' ? runtime : command.role === 'orchestration' ? trace : command.role === 'runtime-input-traces' ? inputTraces : host)
    }
    return {status: 0, stdout: command.role === 'host-performance' && command.args.includes('--compare') ? JSON.stringify(hostComparison) : secret, stderr: secret}
  }}
const options = (mode, output, corpus) => ({mode, output, ...(corpus ? {corpus} : {})})
function restoreManifest(directory, value) { write(path.join(directory, 'manifest.json'), value) }

try {
  const output = path.join(temporary, 'package')
  assert.deepEqual(B.parseArgs(['--capture', '--output', output]), options('capture', output))
  for (const args of [[], ['--capture'], ['--output', output], ['--capture', '--compare', '--output', output],
    ['--capture', '--capture', '--output', output], ['--capture', '--output', output, '--output', output],
    ['--capture', '--output', output, '--corpus'], ['--capture', '--output', output, '--corpus', temporary, '--corpus', temporary],
    ['--capture', '--output', '--corpus'], ['--capture', '--output', output, '--warmup', '0']]) assert.throws(() => B.parseArgs(args))
  command(['--help'])
  command([], 1)
  const missing = path.join(temporary, 'missing', 'package')
  assert.throws(() => B.execute(options('capture', missing), dependencies))
  assert(!fs.existsSync(path.dirname(missing)))
  for (const output of [ROOT, path.join(ROOT, 'offline-baseline-test-must-not-create'), path.dirname(ROOT)]) {
    assert.throws(() => B.execute(options('capture', output), dependencies), /repository/)
  }
  assert.throws(() => B.execute(options('compare', output), dependencies))
  const existing = path.join(temporary, 'existing')
  fs.mkdirSync(existing)
  write(path.join(existing, 'keep'), secret)
  assert.throws(() => B.execute(options('capture', existing), dependencies), /existing/)
  assert.equal(fs.readFileSync(path.join(existing, 'keep'), 'utf8'), secret)
  const file = path.join(temporary, 'file')
  write(file, secret)
  assert.throws(() => B.execute(options('capture', file), dependencies), /existing/)
  assert.throws(() => B.execute(options('compare', file), dependencies), /directory/)
  if (posix) {
    const link = path.join(temporary, 'link')
    fs.symlinkSync(existing, link)
    for (const target of [link, path.join(link, 'package')]) {
      assert.throws(() => B.execute(options('capture', target), dependencies), /Symlinks/)
      assert.throws(() => B.execute(options('compare', target), dependencies), /Symlinks/)
    }
    const dangling = path.join(temporary, 'dangling')
    fs.symlinkSync(path.join(temporary, 'absent'), dangling)
    assert.throws(() => B.execute(options('capture', dangling), dependencies), /Symlinks/)
    assert.throws(() => B.execute(options('capture', output, path.join(link, 'corpus')), dependencies), /Symlinks/)
  }
  const corpus = path.join(temporary, 'corpus')
  fs.mkdirSync(corpus)
  assert.throws(() => B.execute(options('capture', path.join(corpus, 'package'), corpus), dependencies), /overlap/)
  assert.throws(() => B.execute(options('capture', output, file), dependencies), /Corpus/)
  assert.throws(() => B.execute(options('capture', output, path.join(output, 'corpus')), dependencies))
  const previousRoot = process.env.VERA_SOURCE_ROOT
  try {
    process.env.VERA_SOURCE_ROOT = temporary
    assert.throws(() => B.execute(options('capture', output), dependencies), /VERA_SOURCE_ROOT/)
    process.env.VERA_SOURCE_ROOT = ''
    assert.throws(() => B.execute(options('capture', output), dependencies), /VERA_SOURCE_ROOT/)
    process.env.VERA_SOURCE_ROOT = path.join(ROOT, 'entry/src/main/ets')
    assert.equal(B.currentSources(), fs.realpathSync(process.env.VERA_SOURCE_ROOT))
  } finally {
    if (previousRoot === undefined) delete process.env.VERA_SOURCE_ROOT
    else process.env.VERA_SOURCE_ROOT = previousRoot
  }
  const failedTS = {...dependencies, resolveTypeScript() { throw Error('resolution failed') }}
  assert.throws(() => B.execute(options('capture', output), failedTS))
  assert(!fs.existsSync(output))
  for (const role of roles) {
    const failed = path.join(temporary, 'failed-' + role)
    assert.throws(() => B.execute(options('capture', failed), {...dependencies, runChild(command, env) {
      if (command.role === role) return {status: 1, stdout: secret, stderr: secret}
      return dependencies.runChild(command, env)
    }}), /capture failed/)
    assert(!fs.existsSync(failed))
  }
  const incomplete = path.join(temporary, 'incomplete')
  assert.throws(() => B.execute(options('capture', incomplete), {...dependencies, runChild() { return {status: 0} }}))
  assert(!fs.existsSync(incomplete))
  const invalid = path.join(temporary, 'invalid-artifact')
  assert.throws(() => B.execute(options('capture', invalid), {...dependencies, runChild(command, env) {
    const result = dependencies.runChild(command, env)
    if (command.role === 'runtime') write(path.join(invalid, 'runtime.json'), '{broken')
    return result
  }}), /JSON/)
   assert(!fs.existsSync(invalid))
   for (const mutate of [a => { a.schema = 'wrong' }, a => { a.environment = 'MOCKED' },
     a => { a.comparison = 'COUNTS_ONLY' }, a => { delete a.normalization }, a => { a.limitations = [] },
     a => { a.scenarios = [] }, a => { a.scenarios.push(clone(a.scenarios[0])) },
     a => { a.scenarios[0].environment = 'MOCKED' }, a => { a.scenarios[0].segments = [] },
     a => { a.scenarios[0].segments[0] = [] }, a => { a.scenarios[0].segments[0][0].at = 42 },
     a => { a.scenarios[0].segments[0][0].attributes = [] }]) {
     const invalidTrace = path.join(temporary, 'invalid-input-trace')
     assert.throws(() => B.execute(options('capture', invalidTrace), {...dependencies, runChild(command, env) {
       const result = dependencies.runChild(command, env)
       if (command.role === 'runtime-input-traces') {
         const changed = clone(inputTraces)
         mutate(changed)
         write(path.join(invalidTrace, 'runtime-input-traces.json'), changed)
       }
       return result
     }}), /runtime input trace/)
     assert(!fs.existsSync(invalidTrace))
   }
   calls.length = 0
  const captured = B.execute(options('capture', output, corpus), dependencies)
  assert(captured.ok)
  assert.equal(captured.manifest.coverage.status, 'INCOMPLETE')
  assert.deepEqual(captured.manifest.coverage.runtime.errors, [{case: 'public/error', phase: 'compile', code: 'E001', diagnosticsCount: 2}])
  assert.equal(captured.manifest.coverage.runtime.diagnosticsCount, 2)
  assert.deepEqual(captured.manifest.coverage.runtime.corpusGaps, ['Missing bytecode'])
  assert.equal(captured.manifest.coverage.corpus.included, true)
  assert.equal(captured.manifest.coverage.corpus.manifestGaps, 1)
  assert.equal(captured.manifest.coverage.corpus.completeness, 'UNVERIFIED')
  assert.equal(captured.manifest.complete, true)
  assert.match(captured.manifest.completionMeaning, /not stage acceptance/)
  const withoutCorpus = path.join(temporary, 'without-corpus')
  const noCorpus = B.execute(options('capture', withoutCorpus), dependencies)
  assert.equal(noCorpus.manifest.coverage.corpus.status, 'NOT_PROVIDED')
  assert.equal(noCorpus.manifest.coverage.corpus.included, false)
  assert.equal(captured.manifest.coverage.demoPrompts.fixtureMapping, null)
  assert.equal(captured.manifest.coverage.demoPrompts.generated, false)
  assert(captured.manifest.coverage.demoPrompts.headings.length > 3)
  assert.equal(captured.manifest.coverage.performance.device, 'DEFERRED')
  assert.equal(captured.manifest.coverage.performance.host, 'DIAGNOSTIC_ONLY')
  assert(!JSON.stringify(captured.manifest).includes(secret))
   assert.deepEqual(calls.slice(0, 4).map(c => c.role), roles)
   assert.deepEqual(calls.slice(0, 4), captured.manifest.commands)
   assert(calls[0].args.includes('--corpus'))
   assert(calls.slice(1, 4).every(c => !c.args.includes('--corpus')))
   assert(!calls[2].args.includes('--warmup'))
   assert.deepEqual(calls[3].args, [path.join(__dirname, 'visual-check.js'), '--capture-runtime-traces', '--output', path.join(output, 'runtime-input-traces.json')])
   assert.equal(captured.manifest.coverage.orchestration.environment, 'MOCKED')
   assert.deepEqual(captured.manifest.coverage.runtimeInputTraces, {environment: 'MOCKED_PLATFORM_REAL_VM', comparison: 'FULL_EXACT_SEQUENCE',
     scenarios: ['field/public-input'], events: 1, limitations: inputTraces.limitations})
   assert.equal(captured.manifest.coverage.arkts.status, 'NOT_RUN')
   assert.match(captured.manifest.coverage.arkts.note, /prior builds/)
   assert(captured.manifest.coverage.gaps.some(gap => /current compiler, VM/.test(gap) && /mocked platform/.test(gap)))
  assert.deepEqual(fs.readdirSync(output).sort(), [...names].sort())
  if (posix) {
    assert.equal(fs.statSync(output).mode & 0o777, 0o700)
    for (const name of names) assert.equal(fs.statSync(path.join(output, name)).mode & 0o777, 0o600)
  }
  const saved = snapshot(output), manifest = read(output)
  calls.length = 0
  const compared = B.execute(options('compare', output, corpus), dependencies)
  assert(compared.ok)
  assert.deepEqual(compared.hostComparison, hostComparison)
  assert.deepEqual(compared.results[2].comparison.deltas, hostComparison.deltas)
  assert.deepEqual(snapshot(output), saved)
   assert.deepEqual(calls.map(c => c.role), roles)
   assert(calls.slice(0, 3).every(c => c.args.includes('--compare')))
   assert(calls[2].args.includes('--baseline') && !calls[2].args.includes('--output'))
   assert.deepEqual(calls[3].args, [path.join(__dirname, 'visual-check.js'), '--compare-runtime-traces', '--output', path.join(output, 'runtime-input-traces.json')])
  const diagnostic = B.execute(options('compare', output, corpus), {...dependencies, runChild(command, env) {
    return command.role === 'host-performance' ? {status: 1, stderr: secret} : dependencies.runChild(command, env)
  }})
  assert(diagnostic.ok)
  assert(!diagnostic.results[2].ok)
  assert.equal(diagnostic.results[2].reason, 'TOOL_FAILED')
  assert.equal(diagnostic.hostComparison, null)
  const incompatible = B.childSummary('host-performance', {status: 1,
    stderr: 'runtime-performance: Incompatible performance reports: protocol\n' + secret}, 'compare')
  assert.equal(incompatible.reason, 'HOST_TOOL_INCOMPATIBLE')
  assert.equal(incompatible.location, 'protocol')
  assert(!JSON.stringify(incompatible).includes(secret))
  const invalidHost = B.execute(options('compare', output), {...dependencies, runChild(command, env) {
    return command.role === 'host-performance' ? {status: 0, stdout: secret} : dependencies.runChild(command, env)
  }})
  assert(invalidHost.ok)
  assert.equal(invalidHost.results[2].reason, 'INVALID_HOST_COMPARISON')
  const safeMismatch = B.childSummary('runtime', {status: 1, stderr:
    'Baseline mismatch at $["cases"][5]["snapshots"][0]["state"]["' + secret + '"]; compare did not modify the baseline\n' + secret}, 'compare')
  assert.equal(safeMismatch.reason, 'BASELINE_MISMATCH')
  assert.equal(safeMismatch.location, '$["cases"][5]["snapshots"][0]["state"]["<redacted>"]')
  assert(!JSON.stringify(safeMismatch).includes(secret))
   for (const role of ['orchestration', 'runtime-input-traces']) {
     const traceMismatch = B.childSummary(role, {status: 1, stderr: 'MOCKED full normalized trace mismatch\n' + secret}, 'compare')
     assert.equal(traceMismatch.reason, 'TRACE_SEQUENCE_MISMATCH')
     assert.equal(traceMismatch.diagnosticOnly, false)
     assert(!JSON.stringify(traceMismatch).includes(secret))
   }
   const inputMismatch = B.execute(options('compare', output, corpus), {...dependencies, runChild(command, env) {
     return command.role === 'runtime-input-traces' ? {status: 1, stderr: 'MOCKED full normalized trace mismatch\n' + secret} : dependencies.runChild(command, env)
   }})
   assert(!inputMismatch.ok)
   assert.equal(inputMismatch.results[3].reason, 'TRACE_SEQUENCE_MISMATCH')
   assert(!JSON.stringify(inputMismatch).includes(secret))
   assert.deepEqual(snapshot(output), saved)
  assert.equal(B.childSummary('runtime', {status: null, error: {code: 'ETIMEDOUT', message: secret}}, 'compare').reason, 'TIMEOUT')
  const mismatch = B.execute(options('compare', output, corpus), {...dependencies, runChild(command, env) {
    return command.role === 'runtime' ? {status: 1, stderr: secret} : dependencies.runChild(command, env)
  }})
  assert(!mismatch.ok)
  assert.deepEqual(snapshot(output), saved)
  for (const mutate of [m => { m.version++ }, m => { m.complete = false }, m => { delete m.provenance },
    m => { m.provenance.files[0].path = '../private' }, m => { m.commands = [] },
    m => { m.commands[0] = null }, m => { m.commands[0].args[1] = '--compare' },
    m => { m.commands[0].args[0] = '/tmp/untrusted.js' }, m => { delete m.coverage.runtime },
     m => { m.coverage.performance.host = 'DEVICE_GATE' },
     m => { m.coverage.arkts.status = 'PASSED' }, m => { delete m.coverage.arkts },
     m => { m.coverage.orchestration.environment = 'MOCKED_PLATFORM_REAL_VM' },
     m => { delete m.coverage.runtimeInputTraces }, m => { m.coverage.runtimeInputTraces.environment = 'MOCKED' },
     m => { m.coverage.runtimeInputTraces.comparison = 'COUNTS_ONLY' },
     m => { m.coverage.runtimeInputTraces.scenarios = [] }, m => { m.coverage.runtimeInputTraces.events++ },
     m => { m.coverage.runtimeInputTraces.scenarios[0] = 'false-coverage' },
     m => { m.coverage.runtimeInputTraces.limitations = [] },
     m => { m.commands[3].role = 'orchestration' }, m => { m.commands[3].args[1] = '--capture' },
     m => { m.commands[3].args[0] = '/tmp/stage-trace-check.js' },
     m => { m.commands[3].args[3] = '/tmp/orchestration.json' },
     m => { m.commands[3].args.push('--corpus', corpus) },
     m => { delete m.artifacts['runtime-input-traces.json'] },
    m => { m.artifacts['../escape'] = m.artifacts['runtime.json'] }, m => { delete m.artifacts['runtime.json'] },
    m => { m.artifacts['runtime.json'].sha256 = 'bad' }, m => { m.artifacts['runtime.json'].sizeBytes++ }]) {
    const changed = clone(manifest)
    mutate(changed)
    restoreManifest(output, changed)
    calls.length = 0
    assert.throws(() => B.execute(options('compare', output), dependencies))
    assert.equal(calls.length, 0)
    assert.deepEqual(read(output), changed)
    restoreManifest(output, manifest)
  }
   const outdated = clone(manifest)
   delete outdated.artifacts['runtime-input-traces.json']
   delete outdated.coverage.runtimeInputTraces
   outdated.commands.pop()
   restoreManifest(output, outdated)
   calls.length = 0
   assert.throws(() => B.execute(options('compare', output), dependencies), /inventory/)
   assert.equal(calls.length, 0)
   restoreManifest(output, manifest)
   const inputFile = path.join(output, 'runtime-input-traces.json'), inputBytes = fs.readFileSync(inputFile)
   fs.unlinkSync(inputFile)
   calls.length = 0
   assert.throws(() => B.execute(options('compare', output), dependencies), /inventory/)
   assert.equal(calls.length, 0)
   const invalidSchema = clone(inputTraces)
   invalidSchema.environment = 'MOCKED'
   write(inputFile, invalidSchema)
   const invalidSchemaManifest = clone(manifest), invalidSchemaBytes = fs.readFileSync(inputFile)
   invalidSchemaManifest.artifacts['runtime-input-traces.json'] = {sha256: digest(invalidSchemaBytes), sizeBytes: invalidSchemaBytes.length}
   restoreManifest(output, invalidSchemaManifest)
   assert.throws(() => B.execute(options('compare', output), dependencies), /schema\/environment/)
   assert.equal(calls.length, 0)
   write(inputFile, inputBytes)
   restoreManifest(output, manifest)
   const changedSource = clone(manifest)
   changedSource.provenance.files[0].sha256 = 'd'.repeat(64)
  restoreManifest(output, changedSource)
  assert(B.execute(options('compare', output), dependencies).ok)
  restoreManifest(output, manifest)
  for (const name of names) {
    const target = path.join(output, name), bytes = fs.readFileSync(target)
    write(target, Buffer.concat([bytes, Buffer.from(' ')]))
    calls.length = 0
    if (name === 'manifest.json') write(target, '{broken')
    assert.throws(() => B.execute(options('compare', output), dependencies))
    assert.equal(calls.length, 0)
    write(target, bytes)
    if (posix) {
      fs.unlinkSync(target)
      fs.symlinkSync(file, target)
      assert.throws(() => B.verifyPackage(output))
      assert.equal(fs.readFileSync(file, 'utf8'), secret)
      fs.unlinkSync(target)
      write(target, bytes)
    }
    const hardlink = path.join(temporary, 'hardlink')
    fs.linkSync(target, hardlink)
    assert.throws(() => B.verifyPackage(output), /JSON|regular/)
    fs.unlinkSync(hardlink)
    if (posix) {
      fs.chmodSync(target, 0o644)
      assert.throws(() => B.verifyPackage(output))
      fs.chmodSync(target, 0o600)
    }
  }
  if (posix) {
    fs.chmodSync(output, 0o755)
    assert.throws(() => B.verifyPackage(output), /0700/)
    fs.chmodSync(output, 0o700)
  }
  write(path.join(output, 'extra'), secret)
  assert.throws(() => B.verifyPackage(output), /inventory/)
  fs.unlinkSync(path.join(output, 'extra'))
  B.verifyPackage(output)
  const publicSource = B.provenance(corpus)
  assert(publicSource.files.some(f => f.path === 'entry/src/main/ets/vera/VeraInterpreter.ets'))
  assert(publicSource.files.some(f => f.path === 'tools/vera-harness/src/VeraSdkIndex.ts'))
  assert(publicSource.files.some(f => f.path === 'tools/vera-harness/compatibility/counter.json'))
  assert(publicSource.files.some(f => f.path === 'tools/vera-harness/examples/hello.vera'))
  assert(publicSource.files.every(f => !f.path.includes('/out/') && !f.path.includes('vera-src/')))
  assert(!JSON.stringify(publicSource).includes(secret))
   const beforeRefusal = snapshot(output)
   assert.match(command(['--capture', '--output', output], 1), /refuses an existing output/)
   assert.deepEqual(snapshot(output), beforeRefusal)
   command(['--capture', '--output', path.join(temporary, 'bad-ts')], 1, {VERA_TYPESCRIPT_PATH: path.join(temporary, secret)})
  assert(!fs.existsSync(path.join(temporary, 'bad-ts')))
  console.log('offline-baseline-check: ok; arguments, external/new paths, symlink/hardlink safety, private modes, failure cleanup, manifest mutations, artifact integrity, read-only comparison, non-gating host diagnostics, public provenance')
  if (process.argv.slice(2).length) {
    assert.deepEqual(process.argv.slice(2), ['--integration'])
    const realCorpus = path.join(temporary, 'public-corpus')
    fs.mkdirSync(realCorpus)
    const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'compatibility/counter.json'), 'utf8'))
    write(path.join(realCorpus, 'counter.vbc2'), fixture.bytecode)
    write(path.join(realCorpus, 'recorded-error.vbc2'), 'invalid public test bytecode')
    write(path.join(realCorpus, 'ignored.prompt.txt'), secret)
    write(path.join(realCorpus, 'ignored.state.json'), secret)
    write(path.join(realCorpus, 'manifest.json'), {tool: 'pull-vera-sources.sh', projects: [{versions: [{has_vbc2: false}]}]})
    const real = path.join(temporary, 'actual-package')
    const captureText = command(['--capture', '--output', real, '--corpus', realCorpus])
    assert.match(captureText, /capture ok; coverage INCOMPLETE/)
    const actual = B.verifyPackage(real)
    assert.equal(actual.coverage.runtime.summary.external, 2)
    const actualRuntime = read(real, 'runtime.json')
    assert.equal(actual.coverage.runtime.summary.cases, actualRuntime.cases.length)
    assert(actual.coverage.runtime.summary.cases > actual.coverage.runtime.summary.external)
    assert.equal(actual.coverage.runtime.summary.errors, actualRuntime.cases.filter(item => item.status === 'error').length)
    const documented = fs.readdirSync(path.join(ROOT, 'docs/examples')).filter(name => name.endsWith('.vera'))
    assert.equal(actualRuntime.cases.filter(item => item.kind === 'documented-source').length, documented.length)
    const knownError = actual.coverage.runtime.errors.find(item => item.case === 'docs/examples/shanghai-layover.vera')
    assert(knownError)
    assert.equal(knownError.phase, 'compile')
    assert(knownError.diagnosticsCount > 0)
    assert(actual.coverage.runtime.errors.some(item => item.case === 'corpus/recorded-error.vbc2'))
    assert.equal(actual.coverage.corpus.inputs, 2)
    assert.equal(actual.coverage.corpus.recordedErrors, 1)
    assert.equal(actual.coverage.corpus.manifestGaps, 1)
    const labels = id => actualRuntime.cases.find(item => item.id === id).snapshots.map(item => item.label)
    for (let index = 1; index <= 10; index++) {
      assert(labels('examples/hello.vera').includes('tap-' + index))
      assert(labels('examples/visual-countdown.vera').includes('tick-' + index))
    }
    for (const label of ['field-empty', 'field-invalid', 'field-valid']) assert(labels('examples/textfield-demo.vera').includes(label))
    for (const value of [0, 25, 75, 100]) assert(labels('examples/table-bars-slider-demo.vera').includes('slider-' + value))
    for (const value of [true, false]) {
      assert(labels('examples/widget-switch.vera').includes('toggle-' + value))
      assert(labels('examples/widget-switch.vera').includes('checkbox-' + value))
    }
     assert.equal(actual.coverage.orchestration.environment, 'MOCKED')
     assert.equal(actual.coverage.arkts.status, 'NOT_RUN')
     const actualInput = read(real, 'runtime-input-traces.json'), inputCoverage = actual.coverage.runtimeInputTraces
     assert.equal(actualInput.schema, 'vera-stage-trace-baseline-v1')
     assert.equal(actualInput.environment, 'MOCKED_PLATFORM_REAL_VM')
     assert.equal(inputCoverage.environment, 'MOCKED_PLATFORM_REAL_VM')
     assert.equal(inputCoverage.comparison, 'FULL_EXACT_SEQUENCE')
     assert.deepEqual(inputCoverage.scenarios, ['ticker/fast-pending-edit', 'surface/pending-edit-down-move-up',
       'field/stale-dependency-cancellation', 'field/ime-submit-final', 'field/ime-blur-final',
       'slider/pending-drafts-begin-move-end', 'ticker/slow-pending-flush', 'ticker/slow-composition-gate', 'field/debounce-400ms'])
     assert.equal(inputCoverage.events, 191)
     assert.deepEqual(inputCoverage.limitations, actualInput.limitations)
     assert(actualInput.scenarios.every(scenario => scenario.environment === 'MOCKED_PLATFORM_REAL_VM'))
     assert.equal(actualInput.scenarios.reduce((sum, scenario) => sum + scenario.segments.reduce((sum, segment) => sum + segment.length, 0), 0), 191)
     assert.match(actualInput.limitations.join('\n'), /Current ETS compiler, VM/)
     assert.match(actualInput.limitations.join('\n'), /platform APIs and persistence storage are mocked/)
     assert.deepEqual(fs.readdirSync(real).sort(), [...names].sort())
     assert.equal(actual.commands[3].args[1], '--capture-runtime-traces')
     assert.equal(actual.coverage.performance.workloads, 13)
    assert(actual.coverage.performance.timings.every(item => Number.isFinite(item.p50Ms) && Number.isFinite(item.p95Ms)))
    assert(!fs.readFileSync(path.join(real, 'runtime.json'), 'utf8').includes(secret))
    const before = snapshot(real)
    assert.match(command(['--compare', '--output', real, '--corpus', realCorpus]), /compare ok; coverage INCOMPLETE/)
     assert.deepEqual(snapshot(real), before)
     const realInputFile = path.join(real, 'runtime-input-traces.json'), realInputBytes = fs.readFileSync(realInputFile)
     const driftedInput = clone(actualInput)
     driftedInput.scenarios[0].segments[0][0].attributes.offlineTest = secret
     write(realInputFile, driftedInput)
     const driftedManifest = clone(actual), driftedBytes = fs.readFileSync(realInputFile)
     driftedManifest.artifacts['runtime-input-traces.json'] = {sha256: digest(driftedBytes), sizeBytes: driftedBytes.length}
     restoreManifest(real, driftedManifest)
     const driftedSnapshot = snapshot(real)
     assert.match(command(['--compare', '--output', real, '--corpus', realCorpus], 1), /FAIL runtime-input-traces: TRACE_SEQUENCE_MISMATCH/)
     assert.deepEqual(snapshot(real), driftedSnapshot)
     write(realInputFile, realInputBytes)
     restoreManifest(real, actual)
     const artifact = path.join(real, 'runtime.json')
    fs.appendFileSync(artifact, '\n')
    const mutated = snapshot(real)
    assert.match(command(['--compare', '--output', real, '--corpus', realCorpus], 1), /integrity mismatch/)
    assert.deepEqual(snapshot(real), mutated)
    console.log('offline-baseline-check: integration ok; four-artifact current-source capture/compare, 9 real-VM/mocked-platform scenarios / 191 events, public corpus and recorded error, 13 default host workloads, ArkTS NOT_RUN, trace drift/integrity rejection and read-only package')
  }
} finally {
  fs.rmSync(temporary, {recursive: true, force: true})
}
