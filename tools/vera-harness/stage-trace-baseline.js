'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')

const repository = path.resolve(__dirname, '../..')
const limitations = [
  'MOCKED host extraction of current VeraPreview methods; no native ArkUI, device, SDK, filesystem or network coverage.',
  'VM execution, UI decoding/reconciliation, field flushing, persistence and platform effects are mocked; not end-to-end VERA execution.',
  'Timers are manually advanced fixed steps, not device scheduling, debounce, IME or concurrency coverage.',
  'Trace timestamps are zeroed; elapsed-time expectations are probe assertions, not timing/performance measurements.',
  'Widget-refresh programs, back navigation, move/motion/spin and full lifecycle teardown remain uncovered.',
  'Consent branches are forced in probes; this does not assert production consent is enabled.',
  'Dark-mode and preview-mode probes exercise callbacks, not native listeners or theme geometry.',
  'Only capture-sink renderer scenarios are included; disabled/throwing sinks and helper/launch checks remain default checks.',
  'Observed behavior is a baseline, not a correctness oracle; production drift is not repaired by this harness.'
]

function normalize(records) {
  const sessions = new Map(), generations = new Map(), effects = new Map()
  return records.map(record => {
    assert(Number.isFinite(record.at), 'invalid trace timestamp')
    assert(Number.isSafeInteger(record.session) && record.session > 0, 'invalid trace session')
    assert.equal(typeof record.event, 'string')
    if (!sessions.has(record.session)) sessions.set(record.session, 'session-' + (sessions.size + 1))
    const session = sessions.get(record.session), attributes = {...record.attributes}
    if (attributes.generation !== undefined) {
      assert(Number.isSafeInteger(attributes.generation), 'invalid trace generation')
      if (!generations.has(session)) generations.set(session, attributes.generation)
      attributes.generation -= generations.get(session)
    }
    if (/^EFFECT_(REQUEST|RESULT)$/.test(record.event) && attributes.id !== undefined) {
      const scope = session + '/' + attributes.generation
      if (!effects.has(scope)) effects.set(scope, new Map())
      const ids = effects.get(scope)
      if (!ids.has(attributes.id)) ids.set(attributes.id, 'effect-' + (ids.size + 1))
      attributes.id = ids.get(attributes.id)
    }
    return {session, event: record.event, at: 0, attributes}
  })
}

function artifact(scenarios) {
  assert(scenarios.length > 0, 'no renderer scenarios captured')
  assert.equal(new Set(scenarios.map(scenario => scenario.name)).size, scenarios.length, 'duplicate scenario')
  return {schema: 'vera-stage-trace-baseline-v1', environment: 'MOCKED', comparison: 'FULL_EXACT_SEQUENCE',
    normalization: {timestamps: 'zero; order retained', sessions: 'first-seen per capture segment',
      generations: 'offset from first observed per session; deltas retained',
      effectIds: 'first-seen per session and generation; non-effect id and semantic nodeId unchanged'},
    limitations, scenarios: scenarios.map(scenario => ({name: scenario.name, environment: 'MOCKED',
      segments: scenario.segments.map(records => normalize(records))}))}
}

function compare(expected, actual) {
  assert.deepEqual(actual, expected, 'MOCKED full normalized trace mismatch')
}

function parseArgs(args) {
  if (!args.length) return null
  assert(args.length === 3 && ['--capture', '--compare'].includes(args[0]) && args[1] === '--output' && args[2] && !args[2].startsWith('--'),
    'usage: stage-trace-check.js [--capture|--compare --output FILE]')
  return {mode: args[0].slice(2), output: path.resolve(args[2])}
}

function checkedPath(file) {
  const resolved = path.resolve(file)
  let current = path.parse(resolved).root
  for (const part of resolved.slice(current.length).split(path.sep).slice(0, -1)) {
    current = path.join(current, part)
    const stat = fs.lstatSync(current)
    assert(stat.isDirectory() && !stat.isSymbolicLink(), 'symlink/non-directory output ancestor: ' + current)
  }
  return resolved
}

function inside(file, directory) {
  const relative = path.relative(directory, file)
  return relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))
}

function captureFile(file, value) {
  const output = checkedPath(file)
  for (const directory of [repository, process.env.VERA_SOURCE_ROOT && path.resolve(process.env.VERA_SOURCE_ROOT)].filter(Boolean)) {
    assert(!inside(output, fs.realpathSync(directory)), 'capture must be outside repository and source inputs')
  }
  assert(!fs.existsSync(output) && !fs.lstatSync(output, {throwIfNoEntry: false}), 'capture refuses existing output (including symlinks)')
  const temporary = path.join(path.dirname(output), '.vera-stage-trace-' + crypto.randomBytes(16).toString('hex'))
  let fd
  try {
    fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600)
    fs.fchmodSync(fd, 0o600)
    fs.writeFileSync(fd, JSON.stringify(value, null, 2) + '\n')
    fs.fsyncSync(fd)
    fs.closeSync(fd); fd = undefined
    checkedPath(output)
    fs.linkSync(temporary, output)
  } finally {
    if (fd !== undefined) fs.closeSync(fd)
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary)
  }
}

function compareFile(file, actual) {
  const input = checkedPath(file)
  const fd = fs.openSync(input, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
  try {
    assert(fs.fstatSync(fd).isFile(), 'baseline must be a regular file')
    compare(JSON.parse(fs.readFileSync(fd, 'utf8')), actual)
  } finally { fs.closeSync(fd) }
}

module.exports = {normalize, artifact, compare, parseArgs, captureFile, compareFile}
