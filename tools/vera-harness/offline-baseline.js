#!/usr/bin/env node
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const {spawnSync} = require('node:child_process')
const {isDeepStrictEqual} = require('node:util')

const ROOT = path.resolve(__dirname, '../..')
const FORMAT = 'vera-offline-baseline'
const VERSION = 1
const ARTIFACTS = ['runtime.json', 'orchestration.json', 'host-performance.json', 'runtime-input-traces.json']
const MAX_BYTES = 128 * 1024 * 1024
const POSIX = process.platform !== 'win32'
const USAGE = 'usage: node tools/vera-harness/offline-baseline.js (--capture | --compare) --output DIRECTORY [--corpus DIRECTORY]'
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const inside = (file, directory) => file === directory || file.startsWith(directory + path.sep)

function parseArgs(args) {
  const result = {}, seen = new Set()
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (seen.has(arg)) throw Error('Duplicate option')
    seen.add(arg)
    if (arg === '--capture' || arg === '--compare') {
      if (result.mode) throw Error(USAGE)
      result.mode = arg.slice(2)
    } else if (arg === '--output' || arg === '--corpus') {
      const value = args[++i]
      if (!value || value.startsWith('-')) throw Error(USAGE)
      result[arg.slice(2)] = path.resolve(value)
    } else throw Error(USAGE)
  }
  if (!result.mode || !result.output) throw Error(USAGE)
  return result
}
function checkedPath(file, missingLeaf = false) {
  const resolved = path.resolve(file)
  let current = path.parse(resolved).root
  const parts = resolved.slice(current.length).split(path.sep).filter(Boolean)
  for (let i = 0; i < parts.length; i++) {
    current = path.join(current, parts[i])
    const stat = fs.lstatSync(current, {throwIfNoEntry: false})
    if (!stat && missingLeaf && i === parts.length - 1) return null
    if (!stat) throw Error('Parent/input must already exist')
    if (stat.isSymbolicLink()) throw Error('Symlinks are prohibited')
    if (i < parts.length - 1 && !stat.isDirectory()) throw Error('Ancestor must be a directory')
    if (i === parts.length - 1) return stat
  }
  return fs.lstatSync(current)
}
function validatePaths(options) {
  const output = path.resolve(options.output)
  for (const root of [ROOT, fs.realpathSync(ROOT)]) {
    if (inside(output, root) || inside(root, output)) throw Error('Package must be outside the repository')
  }
  const stat = checkedPath(output, options.mode === 'capture')
  if (options.mode === 'capture' && stat) throw Error('Capture refuses an existing output')
  if (options.mode === 'compare' && (!stat || !stat.isDirectory())) throw Error('Package must be an existing directory')
  if (options.corpus) {
    const corpus = path.resolve(options.corpus)
    if (!checkedPath(corpus).isDirectory()) throw Error('Corpus must be an existing directory')
    if (inside(output, corpus) || inside(corpus, output)) throw Error('Package and corpus must not overlap')
  }
  return stat
}
function currentSources() {
  const current = fs.realpathSync(path.join(ROOT, 'entry/src/main/ets'))
  if (Object.hasOwn(process.env, 'VERA_SOURCE_ROOT') && (!process.env.VERA_SOURCE_ROOT || fs.realpathSync(process.env.VERA_SOURCE_ROOT) !== current)) {
    throw Error('VERA_SOURCE_ROOT must select current repository ETS')
  }
  return current
}
function git(args, input) {
  const result = spawnSync('git', args, {cwd: ROOT, input, encoding: 'utf8', timeout: 10000, maxBuffer: MAX_BYTES})
  if (result.error || result.status !== 0) throw Error('Git provenance collection failed')
  return result.stdout
}
function provenance(corpus) {
  const candidates = [...new Set(git(['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--',
    'entry/src/main/ets', 'tools/vera-harness', 'docs/examples', 'docs/demo-prompts.md', 'tool-paths.sh']).split('\0').filter(Boolean))].sort()
  const ignoredResult = spawnSync('git', ['check-ignore', '--no-index', '--stdin', '-z'], {
    cwd: ROOT, input: candidates.join('\0') + '\0', encoding: 'utf8', timeout: 10000, maxBuffer: MAX_BYTES})
  if (ignoredResult.error || ![0, 1].includes(ignoredResult.status)) throw Error('Git ignored-path collection failed')
  const ignored = new Set(ignoredResult.stdout.split('\0').filter(Boolean)), files = []
  for (const relative of candidates) {
    if (ignored.has(relative) || !(/\.(ets|js|ts|vera|json)$/.test(relative) || ['docs/demo-prompts.md', 'tool-paths.sh'].includes(relative))) continue
    const file = path.join(ROOT, relative)
    if (corpus && inside(file, path.resolve(corpus))) continue
    let stat
    try { stat = checkedPath(file) } catch (error) {
      if (!fs.existsSync(file)) continue
      throw error
    }
    if (!stat.isFile() || stat.nlink !== 1) throw Error('Provenance input must be a regular public file')
    const bytes = fs.readFileSync(file)
    files.push({path: relative, sha256: hash(bytes), sizeBytes: bytes.length})
  }
  const entries = git(['status', '--porcelain=v1', '-z', '--untracked-files=all']).split('\0').filter(Boolean), status = []
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i], record = {status: entry.slice(0, 2), path: entry.slice(3)}
    if (/[RC]/.test(record.status)) record.originalPath = entries[++i]
    status.push(record)
  }
  return {head: git(['rev-parse', 'HEAD']).trim(), status, files,
    scope: 'Non-ignored public ETS recursively, harness JS/TS/VERA/JSON recursively, docs/examples fixtures, demo heading inventory and tool-paths.sh; external/private corpus excluded. Paths and hashes only, no diff contents.'}
}
function commands(options) {
  const artifact = name => path.join(options.output, name)
  return [
    {role: 'runtime', executable: process.execPath, args: [path.join(__dirname, 'runtime-baseline.js'), '--' + options.mode, '--output', artifact('runtime.json'), ...(options.corpus ? ['--corpus', options.corpus] : [])], cwd: ROOT},
    {role: 'orchestration', executable: process.execPath, args: [path.join(__dirname, 'stage-trace-check.js'), '--' + options.mode, '--output', artifact('orchestration.json')], cwd: ROOT},
    {role: 'host-performance', executable: process.execPath, args: [path.join(__dirname, 'runtime-performance.js'), '--' + options.mode, options.mode === 'capture' ? '--output' : '--baseline', artifact('host-performance.json')], cwd: ROOT},
    {role: 'runtime-input-traces', executable: process.execPath, args: [path.join(__dirname, 'visual-check.js'), '--' + options.mode + '-runtime-traces', '--output', artifact('runtime-input-traces.json')], cwd: ROOT}
  ]
}
function runChild(command, env) {
  return spawnSync(command.executable, command.args, {cwd: command.cwd, env, encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'], timeout: 300000, maxBuffer: 32 * 1024 * 1024})
}
function childSummary(role, result, mode) {
  const diagnosticOnly = role === 'host-performance'
  const summary = {role, ok: !result.error && result.status === 0, diagnosticOnly,
    exitStatus: Number.isInteger(result.status) ? result.status : null, reason: 'OK', location: null}
  const text = String(result.stderr || '') + '\n' + String(result.stdout || '')
  if (result.error) summary.reason = result.error.code === 'ETIMEDOUT' ? 'TIMEOUT' : 'TOOL_EXECUTION_FAILED'
  else if (result.status !== 0) {
    summary.reason = result.signal ? 'TOOL_TERMINATED' : 'TOOL_FAILED'
    if (role === 'runtime') {
      const match = /Baseline mismatch at (\$(?:\[[^\r\n]*?\]|\.[A-Za-z0-9_]+)*); compare did not modify the baseline/.exec(text)
      if (match) {
        summary.reason = 'BASELINE_MISMATCH'
        const keys = new Set(['cases', 'coverage', 'summary', 'environment', 'status', 'id', 'kind', 'inputSha256',
          'bytecodeSha256', 'snapshots', 'state', 'views', 'restored', 'nodes', 'children', 'label', 'value', 'calls',
          'entry', 'steps', 'effects', 'effectsAllowed', 'error', 'diagnostics', 'message', 'code', 'phase', 'name',
          'gaps', 'corpusGaps', 'entries', 'parameters', 'surfaces', 'ops', 'dimension', 'draw', 'format', 'version'])
        summary.location = '$'
        const tokens = /\[(\d+|"(?:[^"\\]|\\.)*")\]|\.([A-Za-z0-9_]+)/g
        for (const token of match[1].matchAll(tokens)) {
          if (token[1] && /^\d+$/.test(token[1])) summary.location += '[' + token[1] + ']'
          else {
            let key
            try { key = token[2] || JSON.parse(token[1]) } catch { key = '' }
            summary.location += keys.has(key) ? '[' + JSON.stringify(key) + ']' : '["<redacted>"]'
          }
          if (summary.location.length > 512) { summary.location = summary.location.slice(0, 512) + '...'; break }
        }
      }
    } else if (['orchestration', 'runtime-input-traces'].includes(role) && text.includes('MOCKED full normalized trace mismatch')) summary.reason = 'TRACE_SEQUENCE_MISMATCH'
    else if (diagnosticOnly && text.includes('Incompatible performance reports:')) {
      summary.reason = 'HOST_TOOL_INCOMPATIBLE'
      const match = /Incompatible performance reports: (settings|environment|protocol|workload signatures\/order)(?:\r?\n|$)/.exec(text)
      if (match) summary.location = match[1]
    }
  }
  if (diagnosticOnly && mode === 'compare' && summary.ok) {
    try {
      const comparison = JSON.parse(result.stdout)
      if (comparison.format !== 'vera-runtime-performance-comparison' || comparison.version !== 1 || comparison.diagnosticOnly !== true || comparison.compatible !== true || !Array.isArray(comparison.deltas)) throw Error('Invalid comparison')
      summary.comparison = comparison
    } catch {
      summary.ok = false
      summary.reason = 'INVALID_HOST_COMPARISON'
    }
  }
  return summary
}
function readArtifact(directory, name, privateMode = true) {
  const file = path.join(directory, name), stat = checkedPath(file)
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_BYTES) throw Error('Invalid package regular file/size')
  if (privateMode && POSIX && (stat.mode & 0o777) !== 0o600) throw Error('Package files must have mode 0600')
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
  try {
    const opened = fs.fstatSync(fd)
    if (opened.dev !== stat.dev || opened.ino !== stat.ino || opened.nlink !== 1) throw Error('Package file changed while opening')
    const bytes = fs.readFileSync(fd)
    if (bytes.length > MAX_BYTES) throw Error('Package file exceeds size limit')
    return {bytes, sha256: hash(bytes), sizeBytes: bytes.length}
  } finally { fs.closeSync(fd) }
}
function readJson(directory, name) {
  try { return JSON.parse(readArtifact(directory, name).bytes.toString('utf8')) }
  catch { throw Error('Invalid package JSON or file: ' + name) }
}
function runtimeInputCoverage(directory) {
  const artifact = readJson(directory, 'runtime-input-traces.json')
  const environment = 'MOCKED_PLATFORM_REAL_VM'
  if (artifact.schema !== 'vera-stage-trace-baseline-v1' || artifact.environment !== environment || artifact.comparison !== 'FULL_EXACT_SEQUENCE' || !artifact.normalization || typeof artifact.normalization !== 'object' || !Array.isArray(artifact.limitations) || !artifact.limitations.length || artifact.limitations.some(item => typeof item !== 'string') || !Array.isArray(artifact.scenarios) || !artifact.scenarios.length) throw Error('Invalid runtime input trace schema/environment')
  let events = 0
  const scenarios = []
  for (const scenario of artifact.scenarios) {
    if (!scenario || typeof scenario.name !== 'string' || !scenario.name || scenarios.includes(scenario.name) || scenario.environment !== environment || !Array.isArray(scenario.segments) || !scenario.segments.length) throw Error('Invalid runtime input trace scenario')
    scenarios.push(scenario.name)
    for (const segment of scenario.segments) {
      if (!Array.isArray(segment) || !segment.length || segment.some(event => !event || typeof event.event !== 'string' || !event.event || typeof event.session !== 'string' || !/^session-[1-9]\d*$/.test(event.session) || event.at !== 0 || !event.attributes || typeof event.attributes !== 'object' || Array.isArray(event.attributes))) throw Error('Invalid runtime input trace events')
      events += segment.length
    }
  }
  return {environment, comparison: artifact.comparison, scenarios, events, limitations: artifact.limitations}
}
function coverage(directory, corpusIncluded = false) {
  const runtime = readJson(directory, 'runtime.json'), trace = readJson(directory, 'orchestration.json'), host = readJson(directory, 'host-performance.json')
  const runtimeInputTraces = runtimeInputCoverage(directory)
  if (!runtime.coverage || !runtime.coverage.summary || !Array.isArray(runtime.cases) || !Array.isArray(trace.scenarios) || !Array.isArray(host.workloads)) throw Error('Missing artifact coverage')
  const errors = runtime.cases.filter(item => item.status === 'error').map(item => ({case: item.id,
    phase: item.error?.phase || 'unknown', code: item.error?.code || item.error?.name || 'unknown',
    diagnosticsCount: Array.isArray(item.error?.diagnostics) ? item.error.diagnostics.length : 0}))
  const caseGaps = runtime.cases.filter(item => item.gaps?.length).map(item => ({case: item.id, gaps: item.gaps}))
  const corpusGaps = runtime.coverage.corpusGaps || []
  const externalCases = runtime.cases.filter(item => item.id.startsWith('corpus/'))
  const corpus = {included: corpusIncluded, status: corpusIncluded ? 'SELECTED_INPUTS_ONLY' : 'NOT_PROVIDED',
    inputs: runtime.coverage.summary.external || 0, recordedErrors: externalCases.filter(item => item.status === 'error').length,
    manifestGaps: corpusGaps.length, completeness: 'UNVERIFIED',
    note: corpusIncluded ? 'Manifest gaps count only reported missing bytecode; selected inputs do not prove a complete device catalogue.' : 'No saved/private corpus supplied; public fixtures do not establish saved-project coverage.'}
  const demo = fs.readFileSync(path.join(ROOT, 'docs/demo-prompts.md'), 'utf8').split(/\r?\n/)
  let fenced = false
  const headings = []
  for (const [index, line] of demo.entries()) {
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue }
    const match = !fenced && /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line)
    if (match) headings.push({line: index + 1, level: match[1].length, title: match[2]})
  }
  return {status: 'INCOMPLETE', corpus, runtime: {summary: runtime.coverage.summary, errors, caseGaps,
    diagnosticsCount: errors.reduce((count, item) => count + item.diagnosticsCount, 0),
    corpusGaps, limitations: runtime.coverage.limitations || []},
    orchestration: {environment: 'MOCKED', scenarios: trace.scenarios.map(item => item.name), limitations: trace.limitations || []},
    runtimeInputTraces,
    arkts: {status: 'NOT_RUN', note: 'This baseline performs host ETS transpilation only; prior builds are not baseline ArkTS/SDK validation.'},
    demoPrompts: {path: 'docs/demo-prompts.md', headings, status: 'INVENTORY_ONLY', generated: false,
      fixtureMapping: null, note: 'Headings only; no prompt execution, generation, or claimed prompt-to-fixture mapping.'},
    device: {status: 'DEFERRED', gaps: ['ArkTS/SDK validation', 'Native ArkUI geometry and painting', 'Platform effects and consent', 'Device lifecycle and scheduling']},
    performance: {device: 'DEFERRED', host: 'DIAGNOSTIC_ONLY', workloads: host.workloads.length,
      timings: host.workloads.map(item => ({id: item.id, p50Ms: item.statistics?.p50Ms, p95Ms: item.statistics?.p95Ms}))},
    gaps: ['Recorded runtime errors and corpusGaps are observations, not passing coverage.',
      'Only scripted public fixtures and explicitly selected corpus bytecode; no exhaustive handler coverage.',
       'Orchestration uses mocked host extraction, not end-to-end native execution.',
       'Runtime input traces execute the current compiler, VM, UI decoder and reconciliation with mocked platform APIs/storage and synthetic input; native platform integration remains unvalidated.',
       'No ArkTS/SDK check was run by this baseline; prior builds do not change this claim.',
      'Demo prompts are an unmapped headings inventory; no generation was attempted.',
      'Device validation and device performance are DEFERRED; host timings are diagnostic only.']}
}
function validateManifest(manifest) {
  if (!manifest || manifest.format !== FORMAT || manifest.version !== VERSION || manifest.complete !== true) throw Error('Unsupported or incomplete manifest')
  if (!manifest.artifacts || Object.keys(manifest.artifacts).sort().join(',') !== [...ARTIFACTS].sort().join(',')) throw Error('Manifest artifact inventory mismatch')
  for (const name of ARTIFACTS) {
    const item = manifest.artifacts[name]
    if (!item || !/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.sizeBytes) || item.sizeBytes < 1 || item.sizeBytes > MAX_BYTES) throw Error('Invalid manifest artifact digest/size')
  }
  if (!manifest.provenance || !/^[a-f0-9]{40,64}$/.test(manifest.provenance.head) || !Array.isArray(manifest.provenance.status) || !Array.isArray(manifest.provenance.files) || !Array.isArray(manifest.commands) || manifest.commands.length !== ARTIFACTS.length || manifest.coverage?.status !== 'INCOMPLETE') throw Error('Invalid manifest provenance/coverage/commands')
  for (const item of manifest.provenance.files) {
    if (!item || typeof item.path !== 'string' || path.isAbsolute(item.path) || item.path.split(/[\\/]/).includes('..') || !/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.sizeBytes) || item.sizeBytes < 0) throw Error('Invalid manifest source provenance')
  }
  const summary = manifest.coverage.runtime?.summary
  if (!summary || ['cases', 'ok', 'errors'].some(key => !Number.isSafeInteger(summary[key]) || summary[key] < 0) || !Array.isArray(manifest.coverage.orchestration?.scenarios) || manifest.coverage.performance?.host !== 'DIAGNOSTIC_ONLY' || manifest.coverage.performance?.device !== 'DEFERRED') throw Error('Invalid manifest coverage summary')
  const input = manifest.coverage.runtimeInputTraces
  if (manifest.coverage.orchestration.environment !== 'MOCKED' || manifest.coverage.arkts?.status !== 'NOT_RUN' || !input || input.environment !== 'MOCKED_PLATFORM_REAL_VM' || input.comparison !== 'FULL_EXACT_SEQUENCE' || !Array.isArray(input.scenarios) || !input.scenarios.length || input.scenarios.some(name => typeof name !== 'string' || !name) || new Set(input.scenarios).size !== input.scenarios.length || !Number.isSafeInteger(input.events) || input.events < input.scenarios.length || !Array.isArray(input.limitations) || !input.limitations.length || input.limitations.some(item => typeof item !== 'string')) throw Error('Invalid manifest runtime input/ArkTS coverage')
  for (const [index, command] of manifest.commands.entries()) {
    const role = ['runtime', 'orchestration', 'host-performance', 'runtime-input-traces'][index]
    const tool = ['runtime-baseline.js', 'stage-trace-check.js', 'runtime-performance.js', 'visual-check.js'][index]
    if (!command || command.role !== role || typeof command.executable !== 'string' || !path.isAbsolute(command.executable) || typeof command.cwd !== 'string' || !path.isAbsolute(command.cwd) || !Array.isArray(command.args) || command.args.some(arg => typeof arg !== 'string')) throw Error('Invalid manifest command')
    const args = command.args
    if (![4, ...(index === 0 ? [6] : [])].includes(args.length) || !path.isAbsolute(args[0]) || path.basename(args[0]) !== tool || args[1] !== (role === 'runtime-input-traces' ? '--capture-runtime-traces' : '--capture') || args[2] !== '--output' || !path.isAbsolute(args[3]) || path.basename(args[3]) !== ARTIFACTS[index] || (args.length === 6 && (args[4] !== '--corpus' || !path.isAbsolute(args[5])))) throw Error('Invalid manifest command arguments')
  }
  return manifest
}
function verifyPackage(directory) {
  const stat = checkedPath(directory)
  if (!stat.isDirectory() || (POSIX && (stat.mode & 0o777) !== 0o700)) throw Error('Package directory must have mode 0700')
  if (fs.readdirSync(directory).sort().join(',') !== [...ARTIFACTS, 'manifest.json'].sort().join(',')) throw Error('Package file inventory mismatch')
  const manifest = validateManifest(readJson(directory, 'manifest.json'))
  for (const name of ARTIFACTS) {
    const actual = readArtifact(directory, name), expected = manifest.artifacts[name]
    if (actual.sha256 !== expected.sha256 || actual.sizeBytes !== expected.sizeBytes) throw Error('Artifact integrity mismatch: ' + name)
  }
  if (!isDeepStrictEqual(manifest.coverage.runtimeInputTraces, runtimeInputCoverage(directory))) throw Error('Runtime input trace coverage mismatch')
  return manifest
}
function atomicManifest(directory, manifest) {
  validateManifest(manifest)
  const temporary = path.join(directory, '.manifest-' + crypto.randomBytes(16).toString('hex'))
  const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600)
  try {
    fs.fchmodSync(fd, 0o600)
    fs.writeFileSync(fd, JSON.stringify(manifest, null, 2) + '\n')
    fs.fsyncSync(fd)
  } finally { fs.closeSync(fd) }
  fs.renameSync(temporary, path.join(directory, 'manifest.json'))
  if (POSIX) {
    const dir = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW)
    try { fs.fsyncSync(dir) } finally { fs.closeSync(dir) }
  }
}
function sameDirectory(directory, original) {
  const current = checkedPath(directory)
  if (!current || current.dev !== original.dev || current.ino !== original.ino) throw Error('Package directory changed during operation')
}
function execute(options, dependencies = {}) {
  validatePaths(options)
  currentSources()
  const before = options.mode === 'compare' ? verifyPackage(options.output) : null
  const beforeManifest = before && readArtifact(options.output, 'manifest.json').sha256
  const resolveTS = dependencies.resolveTypeScript || require('./runtime-performance').resolveTypeScript
  let typescript
  try { typescript = resolveTS() }
  catch { throw Error('TypeScript resolution failed; configure VERA_TYPESCRIPT_PATH or HVIGORW using tool-paths.sh') }
  const env = {...process.env, TZ: 'UTC', LANG: 'C', LC_ALL: 'C'}
  if (process.env.VERA_TYPESCRIPT_PATH) env.VERA_TYPESCRIPT_PATH = require.resolve(process.env.VERA_TYPESCRIPT_PATH)
  const plan = commands(options), runner = dependencies.runChild || runChild
  let created, manifest
  try {
    if (options.mode === 'capture') {
      const source = (dependencies.provenance || provenance)(options.corpus)
      validatePaths(options)
      fs.mkdirSync(options.output, {mode: 0o700})
      created = fs.lstatSync(options.output)
      fs.chmodSync(options.output, 0o700)
      manifest = {format: FORMAT, version: VERSION, complete: true, createdAt: new Date().toISOString(),
        completionMeaning: 'All required artifacts were fully written and integrity recorded; not stage acceptance or complete coverage.',
        provenance: source, typescript, commands: plan, artifacts: {}, corpusIncluded: Boolean(options.corpus)}
    }
    const identity = created || fs.lstatSync(options.output), results = []
    for (const command of plan) {
      sameDirectory(options.output, identity)
      const result = runner(command, env)
      const summary = childSummary(command.role, result, options.mode)
      results.push(summary)
      if (options.mode === 'capture' && !summary.ok) throw Error(command.role + ' capture failed (' + summary.reason + '); incomplete package removed')
      if (options.mode === 'capture') {
        const name = ARTIFACTS[results.length - 1]
        readArtifact(options.output, name, false)
        fs.chmodSync(path.join(options.output, name), 0o600)
      }
    }
    sameDirectory(options.output, identity)
    if (options.mode === 'capture') {
      manifest.coverage = coverage(options.output, Boolean(options.corpus))
      for (const name of ARTIFACTS) {
        const {sha256, sizeBytes} = readArtifact(options.output, name)
        manifest.artifacts[name] = {sha256, sizeBytes}
      }
      atomicManifest(options.output, manifest)
      verifyPackage(options.output)
    } else {
      verifyPackage(options.output)
      if (readArtifact(options.output, 'manifest.json').sha256 !== beforeManifest) throw Error('Manifest changed during read-only comparison')
      manifest = before
    }
    return {mode: options.mode, ok: results.filter(item => !item.diagnosticOnly).every(item => item.ok), results, manifest,
      hostComparison: results.find(item => item.diagnosticOnly).comparison || null}
  } catch (error) {
    if (created) {
      sameDirectory(options.output, created)
      fs.rmSync(options.output, {recursive: true})
    }
    throw error
  }
}
function main(args) {
  if (args.length === 1 && args[0] === '--help') { console.log(USAGE); return }
  const result = execute(parseArgs(args)), summary = result.manifest.coverage.runtime.summary
  const host = result.results.find(item => item.diagnosticOnly)
  console.log(`offline-baseline: ${result.mode} ${result.ok ? 'ok' : 'MISMATCH'}; coverage INCOMPLETE; ${summary.cases} runtime cases, ${summary.errors} recorded errors; ${result.manifest.coverage.orchestration.scenarios.length} MOCKED orchestration scenarios; ${result.manifest.coverage.runtimeInputTraces.scenarios.length} MOCKED_PLATFORM_REAL_VM scenarios, ${result.manifest.coverage.runtimeInputTraces.events} events; ArkTS NOT_RUN; host ${host.ok ? 'diagnostic ok' : 'diagnostic unavailable (non-gating)'}; device/performance DEFERRED`)
  for (const item of result.results.filter(item => !item.ok)) {
    console.log(`offline-baseline: ${item.diagnosticOnly ? 'WARNING non-gating' : 'FAIL'} ${item.role}: ${item.reason}${item.location ? ' at ' + item.location : ''}`)
  }
  if (!result.ok) process.exitCode = 1
}
module.exports = {parseArgs, checkedPath, validatePaths, currentSources, provenance, commands, coverage, childSummary, validateManifest, verifyPackage, execute, main}
if (require.main === module) {
  try { main(process.argv.slice(2)) }
  catch (error) {
    const safe = error.code ? 'filesystem/tool configuration failure' : error.message
    console.error('offline-baseline: ' + safe)
    process.exitCode = 1
  }
}
