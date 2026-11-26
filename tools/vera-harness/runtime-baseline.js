#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const {fork} = require('node:child_process')

const EPOCH = 1767268800000
const SEED = 0x13579bdf
const USAGE = 'usage: node tools/vera-harness/runtime-baseline.js (--capture | --compare) --output FILE [--corpus DIRECTORY]'
const LIMITATIONS = [
  'docs/demo-prompts.md contains generation/chat prompts, not executable VERA source; no prompt generation is attempted.',
  'Headless VM/decoded UI/GfxOp data only; no VeraPreview, ArkUI geometry, native painting, runtime/trace, form lifecycle or device validation.',
  'All effects are queued data only. Scripted replies are synthetic; no SDK, intent, remote source, model, network or device execution.',
  'Only named representative scripts run; arbitrary handlers, long-running timers, all input branches and asynchronous scheduling are not exhaustively covered.',
  'Restore uses tagged JSON in memory and a fresh VM, not platform persistence. External saved state, prompts, settings and unlisted raw files are not loaded.',
  'Current ETS is transpiled through source-loader with its platform/SDK-index stubs; this is not ArkTS typechecking or SDK target validation.',
  'Time is frozen in UTC and random is seeded per case; other timezones, advancing wall time and cross-engine floating-point differences are not tested.'
]

function canonical(value) {
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Object.is(value, -0)) return {$number: Object.is(value, -0) ? '-0' : String(value)}
    return value
  }
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (Array.isArray(value)) return value.map(canonical)
  if (value instanceof Map) return [...value].map(canonical)
  if (typeof value !== 'object') throw Error('Non-JSON baseline value: ' + typeof value)
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
}
function json(value) { return JSON.stringify(canonical(value), null, 2) + '\n' }
function hash(value) { return crypto.createHash('sha256').update(value).digest('hex') }
function difference(a, b, at = '$') {
  if (Object.is(a, b)) return null
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return at
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()
  for (const key of keys) {
    const next = Array.isArray(a) ? `${at}[${key}]` : `${at}[${JSON.stringify(key)}]`
    if (!Object.hasOwn(a, key) || !Object.hasOwn(b, key)) return next
    const found = difference(a[key], b[key], next)
    if (found) return found
  }
  return null
}
function parseArgs(args) {
  const options = {}
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '--capture' || arg === '--compare') {
      if (options.mode) throw Error(USAGE)
      options.mode = arg.slice(2)
    } else if (arg === '--output' || arg === '--corpus') {
      const key = arg.slice(2), value = args[++i]
      if (options[key] || !value || value.startsWith('--')) throw Error(USAGE)
      options[key] = path.resolve(value)
    } else throw Error(USAGE)
  }
  if (!options.mode || !options.output) throw Error(USAGE)
  return options
}
function configureDeterminism() {
  process.env.TZ = 'UTC'
  const RealDate = Date
  function FixedDate(...args) {
    if (!new.target) return new RealDate(EPOCH).toString()
    return Reflect.construct(RealDate, args.length ? args : [EPOCH], new.target)
  }
  Object.setPrototypeOf(FixedDate, RealDate)
  FixedDate.prototype = RealDate.prototype
  FixedDate.now = () => EPOCH
  globalThis.Date = FixedDate
  let seed = SEED
  Math.random = () => {
    seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5
    return (seed >>> 0) / 4294967296
  }
  const blocked = () => { throw Error('Remote execution is prohibited by runtime-baseline') }
  globalThis.fetch = blocked
  globalThis.__veraHttp = blocked
  globalThis.__veraResolve = blocked
  for (const name of ['node:net', 'node:tls', 'node:http', 'node:https', 'node:http2', 'node:dgram', 'node:dns']) {
    const mod = require(name)
    for (const key of ['connect', 'createConnection', 'request', 'get', 'createSocket', 'lookup', 'resolve', 'resolve4', 'resolve6']) {
      if (typeof mod[key] === 'function') mod[key] = blocked
      if (mod.promises && typeof mod.promises[key] === 'function') mod.promises[key] = blocked
    }
  }
  return () => { seed = SEED }
}
function corpusInputs(directory) {
  const root = fs.realpathSync(directory)
  if (!fs.statSync(root).isDirectory()) throw Error('--corpus must be a directory')
  function file(relative) {
    if (typeof relative !== 'string' || path.isAbsolute(relative) || relative.split(/[\\/]/).includes('..')) throw Error('Unsafe corpus path')
    const resolved = fs.realpathSync(path.resolve(root, relative))
    if (!resolved.startsWith(root + path.sep) || !fs.statSync(resolved).isFile()) throw Error('Unsafe corpus file')
    return resolved
  }
  const selected = new Set(fs.readdirSync(root, {withFileTypes: true}).filter(e => e.isFile() && e.name.endsWith('.vbc2')).map(e => e.name))
  const raw = new Set(), gaps = []
  if (fs.existsSync(path.join(root, 'manifest.json'))) {
    const manifest = JSON.parse(fs.readFileSync(file('manifest.json'), 'utf8'))
    if (manifest.tool !== 'pull-vera-sources.sh' || !Array.isArray(manifest.projects)) throw Error('Unsupported pull manifest schema')
    for (const project of manifest.projects) {
      if (!Array.isArray(project.versions)) throw Error('Invalid pull manifest versions')
      for (const version of project.versions) {
        const readable = version.readable_files || []
        if (!Array.isArray(readable) || readable.some(f => typeof f !== 'string')) throw Error('Invalid readable_files')
        const bytecode = readable.filter(f => f.endsWith('.vbc2'))
        if (bytecode.length) for (const name of bytecode) selected.add(name)
        else if (version.raw_path) {
          if (!/^raw\/[^/\\]+\/[^/\\]+\.json$/.test(version.raw_path) || version.raw_path.endsWith('.state.json') || version.raw_path !== 'raw/' + version.phone_path) throw Error('Unsafe raw Version path')
          raw.add(version.raw_path)
        } else gaps.push('Manifest version has no readable bytecode or raw Version.vbc2')
      }
    }
  }
  const inputs = [...selected].sort().map(name => ({id: 'corpus/' + name, kind: 'external-vbc2', bytecode: fs.readFileSync(file(name), 'utf8')}))
  for (const name of [...raw].sort()) {
    const version = JSON.parse(fs.readFileSync(file(name), 'utf8'))
    if (typeof version.vbc2 === 'string' || Array.isArray(version.vbc2)) inputs.push({id: 'corpus/' + name, kind: 'external-version', bytecode: typeof version.vbc2 === 'string' ? version.vbc2 : JSON.stringify(version.vbc2)})
    else gaps.push('Raw Version has no vbc2: ' + name)
  }
  if (!inputs.length) throw Error('--corpus contains no bytecode inputs')
  return {inputs, gaps}
}
function collect(corpus) {
  const reset = configureDeterminism()
  const {loadVera} = require('./source-loader')
  const C = loadVera('VeraCompiler'), V = loadVera('VeraInterpreter'), U = loadVera('VeraUi'), G = loadVera('VeraGfx')
  const inputs = []
  for (const name of fs.readdirSync(path.join(__dirname, 'examples')).filter(n => n.endsWith('.vera')).sort()) {
    inputs.push({id: 'examples/' + name, kind: 'source', source: fs.readFileSync(path.join(__dirname, 'examples', name), 'utf8')})
  }
  for (const name of fs.readdirSync(path.join(__dirname, 'compatibility')).filter(n => n.endsWith('.json')).sort()) {
    const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'compatibility', name), 'utf8'))
    inputs.push({id: 'compatibility/' + name + '/current-source', kind: 'compat-source', source: fixture.source, fixture})
    inputs.push({id: 'compatibility/' + name + '/stored-bytecode', kind: 'compat-vbc2', bytecode: fixture.bytecode, fixture})
  }
  const docs = path.resolve(__dirname, '../../docs/examples')
  for (const name of fs.readdirSync(docs).filter(n => n.endsWith('.vera')).sort()) {
    inputs.push({id: 'docs/examples/' + name, kind: 'documented-source', source: fs.readFileSync(path.join(docs, name), 'utf8')})
  }
  const external = corpus ? corpusInputs(corpus) : {inputs: [], gaps: []}
  inputs.push(...external.inputs)
  const cases = []
  for (const input of inputs) {
    reset()
    const record = {id: input.id, kind: input.kind, inputSha256: hash(input.source === undefined ? input.bytecode : input.source), status: 'ok', snapshots: [], calls: [], gaps: []}
    cases.push(record)
    let phase = 'compile'
    try {
      const bytecode = input.source === undefined ? input.bytecode : C.compileVeraSource(input.source).vbc2
      record.bytecodeSha256 = hash(bytecode)
      phase = 'deserialize'
      const module = V.deserializeVbc2(bytecode), functions = new Map(module.functions.map(f => [f.name, f.parameterCount]))
      record.entries = [...functions].map(([name, parameters]) => ({name, parameters}))
      function machine() {
        const host = new U.UiHostEnvironment()
        return {host, vm: new V.VirtualMachine(V.deserializeVbc2(bytecode), host)}
      }
      function execute(session, name, args, effectsAllowed = false) {
        phase = name
        session.host.effectsAllowed = effectsAllowed
        try { return session.vm.execute(name, args) } finally {
          record.calls.push({entry: name, steps: session.vm.stepsExecuted(), effectsAllowed, effects: canonical(session.host.pendingEffects.splice(0))})
          session.host.effectsAllowed = false
        }
      }
      function render(session, state) {
        const views = []
        for (const name of ['view', 'widget']) {
          if (!functions.has(name)) continue
          const arity = functions.get(name)
          if (arity > (name === 'widget' ? 2 : 1)) throw Error('Unsupported entry arity: ' + name)
          for (const dimension of name === 'widget' && arity === 2 ? [2, 3, 4] : [null]) {
            const args = arity ? [state] : []
            if (dimension !== null) args.push(new V.VeraNumberValue(dimension))
            const nodes = U.decodeVeraUi(execute(session, name, args)), surfaces = []
            function walk(node) {
              if (node.kind === 'surface') {
                const ops = G.decodeGfx(execute(session, node.label, [state]))
                surfaces.push({id: node.id, draw: node.label, ops: canonical(ops)})
              }
              for (const child of node.children) walk(child)
            }
            nodes.forEach(walk)
            views.push({entry: name, dimension, nodes: canonical(nodes), surfaces})
          }
        }
        return views
      }
      function snapshot(session, state, label) {
        phase = 'encode-state'
        const saved = V.encodeRuntimeValue(state), stateJson = JSON.stringify(saved)
        assert.deepEqual(JSON.parse(stateJson), saved, 'State is not lossless JSON')
        const views = render(session, state)
        assert.deepEqual(V.encodeRuntimeValue(state), saved, 'Rendering mutated state')
        phase = 'restore-state'
        const restored = V.decodeRuntimeValue(JSON.parse(stateJson)), fresh = machine()
        assert.deepEqual(V.encodeRuntimeValue(restored), saved, 'State restore mismatch')
        const restoredViews = render(fresh, restored)
        assert.deepEqual(restoredViews, views, 'Fresh VM restore render mismatch')
        record.snapshots.push({label, state: canonical(saved), views, restored: {state: canonical(V.encodeRuntimeValue(restored)), views: restoredViews}})
      }
      let session = machine()
      if (!functions.has('view') && !functions.has('widget')) throw Error('No view or widget entry')
      if (!functions.has('view')) record.gaps.push('No view entry')
      if (!functions.has('init')) {
        record.gaps.push('No init entry; only zero-argument view/widget can run')
        if (['view', 'widget'].some(n => functions.has(n) && functions.get(n) > 0)) throw Error('Stateful entry requires init')
      }
      let state = functions.has('init') ? execute(session, 'init', []) : V.NULL_VALUE
      snapshot(session, state, 'initial')
      function step(name, value, label = name) {
        state = execute(session, name, functions.get(name) === 1 ? [state] : [state, value], true)
        snapshot(session, state, label)
      }
      if (input.fixture) {
        const f = input.fixture
        step(f.handler, new V.VeraNumberValue(f.value), 'fixture-handler-from-init')
        assert.equal(state.fields.get(f.field).value, f.expected, 'Compatibility fixture expectation')
        assert.deepEqual(V.encodeRuntimeValue(state), f.saved, 'Compatibility fixture saved state')
        state = V.decodeRuntimeValue(f.saved)
        session = machine()
        snapshot(session, state, 'fixture-saved')
        step(f.handler, new V.VeraNumberValue(f.value), 'fixture-handler-after-saved')
      }
      if (input.id === 'examples/hello.vera') {
        for (let press = 1; press <= 10; press++) step('increment', new V.VeraNumberValue(1), 'tap-' + press)
        step('pick', new V.VeraNumberValue(5))
      }
      if (input.id === 'examples/textfield-demo.vera') {
        step('setEmail', new V.VeraStringValue(''), 'field-empty')
        step('setEmail', new V.VeraStringValue('not-an-email'), 'field-invalid')
        step('setEmail', new V.VeraStringValue('tester@example.test'), 'field-valid')
      }
      if (input.id === 'examples/table-bars-slider-demo.vera') {
        for (const value of [0, 25, 75, 100]) step('setBudget', new V.VeraNumberValue(value), 'slider-' + value)
      }
      if (input.id === 'examples/widget-switch.vera') {
        for (const value of [true, false]) {
          step('setFocus', new V.VeraBooleanValue(value), 'toggle-' + value)
          step('setDone', new V.VeraBooleanValue(value), 'checkbox-' + value)
        }
      }
      if (input.id === 'examples/feedback-demo.vera') {
        step('save', new V.VeraNumberValue(0))
        step('dismiss', new V.VeraNumberValue(0))
      }
      if (input.id === 'examples/visual-countdown.vera') {
        step('start', new V.VeraNumberValue(0))
        for (let tick = 1; tick <= 10; tick++) step('tick', new V.VeraNumberValue(1000), 'tick-' + tick)
        step('tick', new V.VeraNumberValue(100000), 'tick-terminal')
      }
      if (input.id === 'examples/surface-catch.vera') {
        step('onPointer', G.pointerValue('down', 0, 180, 590), 'pointer-down')
        for (let frame = 0; frame < 40; frame++) state = execute(session, 'onFrame', [state, new V.VeraNumberValue(16)], true)
        snapshot(session, state, 'frame-40')
        step('onPointer', G.pointerValue('move', 0, 240, 590), 'pointer-move')
        step('onPointer', G.pointerValue('up', 0, 240, 590), 'pointer-up')
      }
      if (functions.has('widgetRefresh')) step('widgetRefresh', new V.VeraNumberValue(0))
      if (input.id === 'examples/widget-source.vera') {
        const queued = record.calls.flatMap(c => c.effects).find(e => e.rawTarget === 'Vera.Source.fetch')
        assert(queued, 'Source effect must be queued, never executed')
        step(queued.resultHandler, new V.VeraStringValue('ok\n2500.00\n\n\n\nasof\t2026-01-01'), 'synthetic-source-ok')
        step('refresh', new V.VeraNumberValue(0), 'refresh-throttled')
        step(queued.resultHandler, new V.VeraStringValue('error: offline fixture'), 'synthetic-source-error')
      }
    } catch (error) {
      record.status = 'error'
      record.error = {phase, name: error.name || 'Error', code: error.trapCode || '', message: error.message, diagnostics: canonical(error.diagnostics || [])}
    }
  }
  const summary = {cases: cases.length, ok: cases.filter(c => c.status === 'ok').length, errors: cases.filter(c => c.status === 'error').length,
    examples: inputs.filter(i => i.kind === 'source').length, documented: inputs.filter(i => i.kind === 'documented-source').length,
    compatibility: inputs.filter(i => i.kind.startsWith('compat-')).length, external: external.inputs.length,
    snapshots: cases.reduce((n, c) => n + c.snapshots.length, 0), restores: cases.reduce((n, c) => n + c.snapshots.length, 0),
    gfxSurfaces: cases.reduce((n, c) => n + c.snapshots.reduce((m, s) => m + s.views.reduce((k, v) => k + v.surfaces.length, 0), 0), 0),
    effects: cases.reduce((n, c) => n + c.calls.reduce((m, call) => m + call.effects.length, 0), 0)}
  return canonical({format: 'vera-runtime-baseline', version: 1, environment: {epochMillis: EPOCH, timezone: 'UTC', randomSeed: SEED, repeats: 2, maxStepsPerCall: 5000000},
    coverage: {summary, corpusGaps: external.gaps, limitations: LIMITATIONS}, cases})
}
function repeat(corpus) {
  return new Promise((resolve, reject) => {
    const child = fork(__filename, ['--baseline-worker'], {env: {...process.env, TZ: 'UTC', LANG: 'C', LC_ALL: 'C'}, stdio: ['ignore', 'ignore', 'pipe', 'ipc']})
    let result, failure, stderr = ''
    const timer = setTimeout(() => { failure = Error('Baseline worker timed out'); child.kill('SIGKILL') }, 120000)
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-2000) })
    child.on('message', message => { if (message.error) failure = Error(message.error); else result = message.result })
    child.on('error', error => { failure = error })
    child.on('exit', code => {
      clearTimeout(timer)
      if (failure || code !== 0 || !result) reject(failure || Error('Baseline worker failed: ' + (stderr || code)))
      else resolve(result)
    })
    child.send({corpus})
  })
}
async function buildBaseline(corpus) {
  const first = await repeat(corpus), second = await repeat(corpus)
  const changed = difference(first, second)
  if (changed) throw Error('Nondeterministic independent repeats at ' + changed)
  return first
}
async function main(args) {
  if (args.length === 1 && args[0] === '--help') { console.log(USAGE); return }
  const options = parseArgs(args)
  const parent = fs.statSync(path.dirname(options.output))
  if (!parent.isDirectory()) throw Error('Output parent must be an existing directory')
  if (fs.existsSync(options.output) && !fs.lstatSync(options.output).isFile()) throw Error('Output must be a regular file, not a symlink')
  const protectedRoots = [__dirname, ...(options.corpus ? [fs.realpathSync(options.corpus)] : [])]
  const realOutput = path.join(fs.realpathSync(path.dirname(options.output)), path.basename(options.output))
  if (protectedRoots.some(root => realOutput === root || realOutput.startsWith(root + path.sep))) throw Error('Output must not overwrite harness or corpus inputs')
  let expected
  if (options.mode === 'compare') {
    expected = JSON.parse(fs.readFileSync(options.output, 'utf8'))
    if (expected.format !== 'vera-runtime-baseline' || expected.version !== 1) throw Error('Unsupported baseline format/version')
  }
  const actual = await buildBaseline(options.corpus)
  if (options.mode === 'capture') {
    const temporary = options.output + '.' + crypto.randomBytes(8).toString('hex') + '.tmp'
    try { fs.writeFileSync(temporary, json(actual), {flag: 'wx', mode: 0o600}); fs.renameSync(temporary, options.output) }
    finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary) }
  } else {
    const changed = difference(expected, actual)
    if (changed) throw Error('Baseline mismatch at ' + changed + '; compare did not modify the baseline')
  }
  const s = actual.coverage.summary
  console.log(`runtime-baseline: ${options.mode} ok; ${s.cases} cases, ${s.ok} ok, ${s.errors} recorded errors, ${s.snapshots} restores, ${s.gfxSurfaces} GfxOp surfaces, ${s.effects} queued effects; two independent repeats matched`)
  for (const c of actual.cases.filter(c => c.status === 'error')) console.log(`recorded gap: ${c.id} (${c.error.phase}, ${c.error.code || c.error.name})`)
  console.log('coverage/limitations are in the JSON; demo-prompts.md prompts were not executed')
}

module.exports = {canonical, json, difference, parseArgs, corpusInputs, buildBaseline, configureDeterminism}
if (require.main === module) {
  if (process.argv[2] === '--baseline-worker' && process.send) {
    process.once('message', ({corpus}) => {
      try { process.send({result: collect(corpus)}, () => process.disconnect()) }
      catch (error) { process.send({error: error.message}, () => { process.disconnect(); process.exitCode = 1 }) }
    })
  } else main(process.argv.slice(2)).catch(error => { console.error('runtime-baseline: ' + error.message); process.exitCode = 1 })
}
