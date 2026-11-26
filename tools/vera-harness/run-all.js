'use strict'
// Runs every *-check.js in this directory, sequentially by default, and reports
// pass/fail/skip with timing. Metadata (extra args, required env, platform skips,
// families) lives in manifest.js; everything else is discovered from disk.
//
//   node tools/vera-harness/run-all.js
//   node tools/vera-harness/run-all.js --list
//   node tools/vera-harness/run-all.js --family=runtime
//   node tools/vera-harness/run-all.js --filter=host --jobs=2 --json=/tmp/report.json
const fs = require('node:fs')
const path = require('node:path')
const {spawn} = require('node:child_process')
const manifest = require('./manifest')

const dir = __dirname
const root = path.resolve(dir, '../..')
const DEFAULT_TIMEOUT = 300000

function effectiveTimeout(entry, opts) {
  return opts.timeout != null ? opts.timeout : (entry.timeout || DEFAULT_TIMEOUT)
}

function usage() {
  console.log([
    'usage: node tools/vera-harness/run-all.js [options]',
    '',
    '  --list             list the checks that would run, with their family',
    '  --family=NAME      run one family (runtime, visual, widget, prompt, agent,',
    '                     composition, live, ui, compiler, other)',
    '  --filter=TEXT      run only checks whose file name contains TEXT',
    '  --jobs=N           run up to N checks at once (default 1; temp files may collide)',
    '  --timeout=MS       per-check timeout (overrides manifest, default 300000)',
    '  --fail-fast        stop after the first failure',
    '  --json=PATH        write a JSON report',
    '  --verbose          print each check\'s full output',
    '  --help             show this message',
    '',
    'Set VERA_TYPESCRIPT_PATH when TypeScript is not resolvable by Node.',
  ].join('\n'))
}

function parseArgs(argv) {
  const opts = {family: null, filter: null, list: false, failFast: false, jobs: 1, timeout: null, json: null, verbose: false}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--list') opts.list = true
    else if (a === '--fail-fast') opts.failFast = true
    else if (a === '--verbose') opts.verbose = true
    else if (a === '--help' || a === '-h') { usage(); process.exit(0) }
    else if (a.startsWith('--family=')) opts.family = a.slice('--family='.length)
    else if (a.startsWith('--filter=')) opts.filter = a.slice('--filter='.length)
    else if (a.startsWith('--jobs=')) opts.jobs = Math.max(1, parseInt(a.slice('--jobs='.length), 10) || 1)
    else if (a.startsWith('--timeout=')) opts.timeout = Math.max(1000, parseInt(a.slice('--timeout='.length), 10) || 300000)
    else if (a.startsWith('--json=')) opts.json = path.resolve(a.slice('--json='.length))
    else { console.error('unknown argument: ' + a); usage(); process.exit(2) }
  }
  return opts
}

function familyOf(name) {
  const override = manifest.overrides[name]
  if (override && override.family) return override.family
  for (const [prefix, family] of manifest.families) {
    if (name.startsWith(prefix)) return family
  }
  return 'other'
}

function discover() {
  return fs.readdirSync(dir)
    .filter(name => name.endsWith('-check.js') || name.endsWith('-suite.js'))
    .sort()
    .map(name => {
      const override = manifest.overrides[name] || {}
      return {
        name,
        family: familyOf(name),
        args: override.args || [],
        env: override.env || [],
        skipOn: override.skipOn || [],
        reason: override.reason || '',
        timeout: override.timeout || null,
      }
    })
}

function skipReason(entry) {
  if (entry.skipOn.includes(process.platform)) {
    return entry.reason || ('not supported on ' + process.platform)
  }
  for (const key of entry.env) {
    if (!process.env[key]) return 'set ' + key
  }
  return null
}

function runOne(entry, opts) {
  return new Promise(resolve => {
    const started = Date.now()
    const child = spawn(process.execPath, [path.join(dir, entry.name), ...entry.args], {
      cwd: root,
      env: {...process.env},
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let out = ''
    let err = ''
    let timedOut = false
    child.stdout.on('data', chunk => { out += chunk })
    child.stderr.on('data', chunk => { err += chunk })
    const timer = setTimeout(() => {
      timedOut = true
      child.kill('SIGKILL')
    }, effectiveTimeout(entry, opts))
    const done = (code, extra) => {
      clearTimeout(timer)
      resolve({name: entry.name, family: entry.family, code, ms: Date.now() - started, out, err: extra || err})
    }
    child.on('close', code => done(timedOut ? 'timeout' : code))
    child.on('error', error => done('spawn-error', String(error)))
  })
}

function tail(text, lines) {
  const all = text.split(/\r?\n/).filter(line => line.length > 0)
  return all.slice(-lines).join('\n')
}

function failureHint(result) {
  const text = result.err.trim() ? result.err : result.out
  const lines = text.split(/\r?\n/).filter(line => line.trim().length > 0)
  const at = lines.findIndex(line => /AssertionError|Error:|ReferenceError|TypeError|SyntaxError/.test(line))
  if (at >= 0) return lines.slice(at, at + 8).join('\n')
  return lines.slice(-5).join('\n')
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  let entries = discover()
  if (opts.family) entries = entries.filter(entry => entry.family === opts.family)
  if (opts.filter) entries = entries.filter(entry => entry.name.includes(opts.filter))

  if (entries.length === 0) {
    console.error('no checks matched')
    process.exit(2)
  }
  if (opts.list) {
    for (const entry of entries) console.log(entry.family.padEnd(12) + ' ' + entry.name)
    return
  }

  if (!process.env.VERA_TYPESCRIPT_PATH) {
    console.log('note: VERA_TYPESCRIPT_PATH is not set; checks must resolve TypeScript themselves')
  }
  console.log('running ' + entries.length + ' check(s), jobs=' + opts.jobs + ', timeout=' + (opts.timeout != null ? opts.timeout + 'ms (explicit)' : 'per-check (manifest or ' + DEFAULT_TIMEOUT + 'ms)'))

  const results = []
  let next = 0
  let stopped = false

  async function worker() {
    while (!stopped) {
      const index = next++
      if (index >= entries.length) return
      const entry = entries[index]
      const skip = skipReason(entry)
      if (skip !== null) {
        results.push({name: entry.name, family: entry.family, status: 'skipped', ms: 0, reason: skip})
        console.log('SKIP ' + entry.name + ' (' + skip + ')')
        continue
      }
      const result = await runOne(entry, opts)
      const failed = result.code !== 0
      results.push({
        name: entry.name,
        family: entry.family,
        status: failed ? 'failed' : 'passed',
        ms: result.ms,
        exit: result.code,
        output: failed ? tail(result.out, 40) : '',
        error: failed ? tail(result.err, 40) : '',
      })
      if (failed) {
        console.log('FAIL ' + entry.name + ' (' + result.ms + 'ms, exit ' + result.code + ')')
        if (opts.verbose) {
          if (result.out.trim()) console.log(result.out.trimEnd())
          if (result.err.trim()) console.log(result.err.trimEnd())
        } else {
          const hint = failureHint(result)
          if (hint) console.log('     ' + hint.replace(/\n/g, '\n     '))
        }
        if (opts.failFast) stopped = true
      } else {
        console.log('PASS ' + entry.name + ' (' + result.ms + 'ms)')
      }
    }
  }

  const workers = []
  for (let i = 0; i < Math.min(opts.jobs, entries.length); i++) workers.push(worker())
  await Promise.all(workers)

  const passed = results.filter(result => result.status === 'passed').length
  const failed = results.filter(result => result.status === 'failed').length
  const skipped = results.filter(result => result.status === 'skipped').length
  const totalMs = results.reduce((sum, result) => sum + result.ms, 0)
  console.log('')
  console.log('summary: ' + passed + ' passed, ' + failed + ' failed, ' + skipped + ' skipped, ' + (totalMs / 1000).toFixed(1) + 's')
  if (failed > 0) {
    console.log('failed: ' + results.filter(result => result.status === 'failed').map(result => result.name).join(', '))
  }

  if (opts.json) {
    fs.mkdirSync(path.dirname(opts.json), {recursive: true})
    fs.writeFileSync(opts.json, JSON.stringify({
      revision: process.env.VERA_REVISION || null,
      command: process.argv.join(' '),
      summary: {passed, failed, skipped, totalMs},
      results,
    }, null, 2) + '\n')
    console.log('report: ' + opts.json)
  }

  if (failed > 0) process.exitCode = 1
}

main().catch(error => {
  console.error(error)
  process.exit(1)
})
