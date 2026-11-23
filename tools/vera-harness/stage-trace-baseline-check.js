'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {spawnSync} = require('node:child_process')
const {normalize, artifact, compare, parseArgs, captureFile, compareFile} = require('./stage-trace-baseline')
const posix = process.platform !== 'win32'

const clone = value => JSON.parse(JSON.stringify(value))
const raw = [
  {session: 72, at: 100, event: 'EFFECT_REQUEST', attributes: {id: 91, generation: 8, rawTarget: 'target-hash', params: 'params-hash'}},
  {session: 72, at: 101, event: 'TICK_SKIPPED', attributes: {reason: 'PENDING_EDIT', tickerId: 'ticker-hash'}},
  {session: 72, at: 102, event: 'DRAW', attributes: {nodeId: 7, result: 'OK'}},
  {session: 72, at: 103, event: 'SNAPSHOT', attributes: {digest: 'state-hash'}},
  {session: 72, at: 104, event: 'EFFECT_RESULT', attributes: {id: 91, generation: 8, outcome: 'OK'}},
  {session: 72, at: 105, event: 'EFFECT_REQUEST', attributes: {id: 91, generation: 10}},
  {session: 99, at: 106, event: 'FRAME', attributes: {treeHash: 'tree-hash'}},
  {session: 72, at: 107, event: 'EXECUTE', attributes: {id: 42}}
]
const before = clone(raw), normalized = normalize(raw)
assert.deepEqual(raw, before)
assert.equal(normalized[0].attributes.id, normalized[4].attributes.id)
assert.equal(normalized[5].attributes.generation, 2)
assert.equal(normalized[2].attributes.nodeId, 7)
assert.equal(normalized[7].attributes.id, 42)
assert.equal(normalized[6].session, 'session-2')
assert(normalized.every(record => record.at === 0))
const shifted = raw.map(record => ({...record, session: record.session + 500, at: record.at + 3000,
  attributes: {...record.attributes, ...(record.attributes.generation !== undefined ? {generation: record.attributes.generation + 30} : {}),
    ...(/^EFFECT_/.test(record.event) ? {id: record.attributes.id + 800} : {})}}))
assert.deepEqual(normalize(shifted), normalized)
const expected = artifact([{name: 'fixture', segments: [raw]}])
for (const mutate of [
  events => { [events[1], events[2]] = [events[2], events[1]] },
  events => { events.splice(1, 1) },
  events => { events.push(clone(events[0])) },
  events => { events[1].attributes.reason = 'COMPOSING' },
  events => { events[3].attributes.digest = 'wrong-content' },
  events => { events[6].attributes.treeHash = 'wrong-tree' },
  events => { events[0].attributes.params = 'wrong-params' },
  events => { events[2].attributes.nodeId = 8 },
  events => { events[4].attributes.id = 'effect-2' },
  events => { events[5].attributes.generation = 1 }
]) {
  const actual = clone(expected)
  mutate(actual.scenarios[0].segments[0])
  assert.throws(() => compare(expected, actual), /full normalized trace mismatch/)
}
for (const mutate of [
  records => { [records[1], records[2]] = [records[2], records[1]] },
  records => { records.splice(1, 1) },
  records => { records[1].attributes.reason = 'COMPOSING' },
  records => { records[3].attributes.digest = 'wrong-content' },
  records => { records[4].attributes.id = 92 },
  records => { records[5].attributes.generation = 9 },
  records => { records[2].attributes.nodeId = 8 }
]) {
  const changed = clone(raw); mutate(changed)
  assert.throws(() => compare(expected, artifact([{name: 'fixture', segments: [changed]}])), /full normalized trace mismatch/)
}
const renamed = clone(expected); renamed.scenarios[0].name = 'wrong scenario'
assert.throws(() => compare(expected, renamed))
const alternate = artifact([{name: 'fixture', segments: [raw, raw]}])
assert.throws(() => compare(expected, alternate))
assert.equal(parseArgs([]), null)
assert.equal(parseArgs(['--capture', '--output', '/tmp/file']).mode, 'capture')
assert.equal(parseArgs(['--compare', '--output', '/tmp/file']).mode, 'compare')
for (const args of [['--output', '/tmp/file'], ['--capture'], ['--compare'], ['--capture', '--compare', '--output', '/tmp/file'],
  ['--capture', '--output', '/tmp/file', '--force'], ['--capture', '--output', '--compare']]) assert.throws(() => parseArgs(args), /usage:/)

const temporary = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'vera-stage-trace-test-'))
try {
  const file = path.join(temporary, 'baseline.json'), missing = path.join(temporary, 'missing.json')
  const link = fs.linkSync
  let published = false
  fs.linkSync = (source, target) => {
    assert(!fs.existsSync(target))
    if (posix) {assert.equal(fs.statSync(source).mode & 0o777, 0o600)}
    assert.deepEqual(JSON.parse(fs.readFileSync(source, 'utf8')), expected)
    published = true
    return link(source, target)
  }
  try { captureFile(file, expected) } finally { fs.linkSync = link }
  assert(published, 'publish only the fully written temporary file')
  const raced = path.join(temporary, 'raced.json')
  fs.linkSync = (source, target) => { fs.writeFileSync(target, 'competitor', {flag: 'wx'}); return link(source, target) }
  try { assert.throws(() => captureFile(raced, expected), /EEXIST/) } finally { fs.linkSync = link }
  assert.equal(fs.readFileSync(raced, 'utf8'), 'competitor')
  if (posix) assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  const bytes = fs.readFileSync(file), stat = fs.statSync(file)
  compareFile(file, clone(expected))
  assert.throws(() => compareFile(file, alternate))
  assert.deepEqual(fs.readFileSync(file), bytes)
  assert.equal(fs.statSync(file).mtimeMs, stat.mtimeMs)
  assert.equal(fs.statSync(file).ino, stat.ino)
  assert.throws(() => compareFile(missing, expected), /ENOENT/)
  assert(!fs.existsSync(missing))
  assert.throws(() => captureFile(file, alternate), /existing output/)
  const hardlink = path.join(temporary, 'hardlink.json')
  fs.linkSync(file, hardlink)
  assert.throws(() => captureFile(hardlink, alternate), /existing output/)
  assert.throws(() => captureFile(temporary, expected))
  assert.throws(() => captureFile(path.join(temporary, 'absent-parent', 'new.json'), expected), /ENOENT/)
  if (posix) {
  const symlink = path.join(temporary, 'link.json'), dangling = path.join(temporary, 'dangling.json')
    fs.symlinkSync(file, symlink); fs.symlinkSync(missing, dangling)
    for (const link of [symlink, dangling]) assert.throws(() => captureFile(link, expected), /existing output/)
    assert.throws(() => compareFile(symlink, expected))
    const directoryLink = path.join(temporary, 'directory-link')
    fs.symlinkSync(temporary, directoryLink)
    assert.throws(() => captureFile(path.join(directoryLink, 'new.json'), expected), /ancestor/)
    assert.throws(() => compareFile(path.join(directoryLink, 'baseline.json'), expected), /ancestor/)
  }
  for (const target of [__filename, path.join(__dirname, 'stage-trace-baseline.js'), path.join(__dirname, 'never-write.json'),
    path.resolve(__dirname, '../../CLAUDE.md')]) assert.throws(() => captureFile(target, expected), /outside repository/)
  assert.deepEqual(fs.readFileSync(file), bytes)
  assert(!fs.existsSync(missing))
  assert.throws(() => captureFile(path.join(temporary, 'not-created.json'), {invalid: 1n}))
  assert(!fs.existsSync(path.join(temporary, 'not-created.json')))
  assert(!fs.readdirSync(temporary).some(name => name.startsWith('.vera-stage-trace-')))
  const originalSourceRoot = process.env.VERA_SOURCE_ROOT
  process.env.VERA_SOURCE_ROOT = temporary
  try { assert.throws(() => captureFile(path.join(temporary, 'input.json'), expected), /outside repository and source inputs/) }
  finally {
    if (originalSourceRoot === undefined) delete process.env.VERA_SOURCE_ROOT
    else process.env.VERA_SOURCE_ROOT = originalSourceRoot
  }
  const run = args => {
    const result = spawnSync(process.execPath, [path.join(__dirname, 'stage-trace-check.js'), ...args],
      {encoding: 'utf8', maxBuffer: 4 * 1024 * 1024})
    assert.ifError(result.error)
    assert.equal(result.status, 0, result.stdout + result.stderr)
    return result
  }
  const first = path.join(temporary, 'first.json'), second = path.join(temporary, 'second.json')
  const filesBeforeDefault = fs.readdirSync(temporary)
  const defaultRun = run([])
  assert.match(defaultRun.stdout, /0 failed/)
  assert(!defaultRun.stdout.includes('MOCKED capture '))
  assert.deepEqual(fs.readdirSync(temporary), filesBeforeDefault)
  const implicit = spawnSync(process.execPath, [path.join(__dirname, 'stage-trace-check.js'), '--output', missing], {encoding: 'utf8'})
  assert.equal(implicit.status, 1); assert.match(implicit.stderr, /usage:/)
  assert(!fs.existsSync(missing))
  run(['--capture', '--output', first]); run(['--capture', '--output', second])
  assert.deepEqual(fs.readFileSync(first), fs.readFileSync(second), 'two independent runs must be byte-identical')
  const full = JSON.parse(fs.readFileSync(first, 'utf8'))
  assert.equal(full.environment, 'MOCKED')
  assert.equal(full.scenarios.length, 16)
  const rendererLoad = full.scenarios.find(scenario => scenario.name === 'real renderer load/action order, reveal and payload privacy')
  assert.equal(rendererLoad.segments[0][0].event, 'TIMERS_STOPPED', 'capture must include setup events even if check clears its local array')
  assert(rendererLoad.segments[0].some(record => record.event === 'SAVE'))
  const firstBytes = fs.readFileSync(first), firstStat = fs.statSync(first)
  if (posix) fs.chmodSync(first, 0o400)
  run(['--compare', '--output', first])
  assert.deepEqual(fs.readFileSync(first), firstBytes)
  assert.equal(fs.statSync(first).mtimeMs, firstStat.mtimeMs)
  if (posix) assert.equal(fs.statSync(first).mode & 0o777, 0o400)
  const corrupted = clone(full)
  const reasonRecord = corrupted.scenarios.flatMap(scenario => scenario.segments.flat()).find(record => record.attributes.reason === 'PENDING_EDIT')
  assert(reasonRecord); reasonRecord.attributes.reason = 'WRONG_REASON'
  const bad = path.join(temporary, 'bad.json'); captureFile(bad, corrupted)
  const failed = spawnSync(process.execPath, [path.join(__dirname, 'stage-trace-check.js'), '--compare', '--output', bad], {encoding: 'utf8'})
  assert.equal(failed.status, 1)
  assert.match(failed.stderr, /full normalized trace mismatch/)
  assert.deepEqual(JSON.parse(fs.readFileSync(bad, 'utf8')), corrupted)
  console.log('stage-trace-baseline-check: PASS normalization, full-sequence mutations, safe atomic 0600 capture, read-only compare, two-run MOCKED determinism (' + full.scenarios.length + ' scenarios)')
} finally { fs.rmSync(temporary, {recursive: true, force: true}) }
