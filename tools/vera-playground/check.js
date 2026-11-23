// Black-box workflows with isolated providers. No live service participates.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const cp = require('node:child_process')
const http = require('node:http')
const {createPlayground} = require('./server')

async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-playground-check-'))
  const seen = []
  let release
  let fail = false
  const app = createPlayground({output: dir, credentials: () => ({}), capturePlan: async () => ({status: 'complete', sha256: 'fixture', planningCalls: 1, ms: 1}), runPath: async (kind, prompt, target) => {
    seen.push({kind, prompt})
    if (release === undefined) await new Promise(resolve => { release = resolve })
    fs.mkdirSync(target, {recursive: true})
    fs.writeFileSync(path.join(target, 'program.vera'), '// retained test artifact')
    if (fail) return {status: 'failed', error: 'DeepSeek HTTP 503', critical: true}
    return {status: kind === 'local' ? 'uncertain' : 'complete', selectorMs: 7, totalMs: 20,
      note: kind === 'local' ? 'uncalibrated_model' : 'fixture', critical: false}
  }})
  await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${app.server.address().port}`
  const state = async () => (await fetch(base + '/api/state')).json()
  const initial = await state()
  const post = (endpoint, body) => fetch(base + endpoint, {method: 'POST', headers: {
    'Content-Type': 'application/json', 'X-Playground-Token': initial.token}, body: JSON.stringify(body)})
  const until = async condition => { for (let i = 0; i < 100; i++) { const s = await state(); if (condition(s)) return s; await new Promise(r => setTimeout(r, 20)) } throw Error('state timeout') }
  try {
    assert.equal(seen.length, 0, 'load must make no provider calls')
    assert.equal((await fetch(base + '/api/run', {method: 'POST', body: '{}'})).status, 403)
    assert.equal(await new Promise(resolve => { http.get(base + '/api/state', {headers: {Host: 'foreign.example'}}, res => { res.resume(); resolve(res.statusCode) }) }), 403)
    assert.equal((await post('/api/run', {prompt: ''})).status, 400)
    assert.equal((await post('/api/run', {prompt: 'An exact app request'})).status, 202)
    assert.equal((await post('/api/run', {prompt: 'overlap'})).status, 409)
    await until(() => typeof release === 'function')
    await post('/api/stop', {})
    release()
    const stopped = await until(s => !s.busy)
    assert.equal(stopped.auto, false)
    assert.deepEqual(seen.map(r => r.prompt), ['An exact app request', 'An exact app request'])
    assert.equal(stopped.history.length, 1)
    assert.equal(stopped.history[0].paths.local.status, 'uncertain')
    assert.equal((await fetch(base + `/artifacts/${stopped.history[0].id}/cloud/program.vera`)).status, 200)
    assert.equal((await fetch(base + `/artifacts/${stopped.history[0].id}/cloud/unknown.txt`)).status, 404)
    // Fresh automatic prompt generation and its retries have their own provider-isolated E2E workflow.
    const beforeFailure = (await state()).history.length
    fail = true
    assert.equal((await post('/api/run', {prompt:'A failed app request'})).status, 202)
    const failed = await until(s => !s.busy)
    assert.equal(failed.auto, false, 'failed paths retain their failure state')
    assert.equal(failed.history.length, beforeFailure + 1)
    assert.ok(failed.history[0].paths.cloud.error)
    assert.ok(fs.existsSync(path.join(dir, stopped.history[0].id, 'comparison.json')))
    const exact = '汉'.repeat(8000)
    const bytes = Buffer.from(JSON.stringify({prompt: exact}))
    const split = bytes.indexOf(Buffer.from('汉')) + 1
    const unicodeStatus = await new Promise(resolve => {
      const request = http.request(base + '/api/run', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Playground-Token': initial.token}}, res => { res.resume(); resolve(res.statusCode) })
      request.write(bytes.subarray(0, split))
      setImmediate(() => request.end(bytes.subarray(split)))
    })
    assert.equal(unicodeStatus, 202, 'a valid 8000-character CJK request must not hit the byte limit')
    const unicode = await until(s => !s.busy)
    assert.equal(unicode.history[0].prompt, exact, 'UTF-8 split across chunks must remain exact')
    const history = failed.history
    const report = {revision: cp.execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
      command: 'node tools/vera-playground/check.js', inputs: 'isolated runner, exact prompt, manual comparison, stop, transport failure',
      expected: 'no initial calls, no overlap, same prompt, stop before another pair, preserve artifacts, critical failure halts',
      observed: {status: 'pass', comparisons: history.length, calls: seen.length, exactCjk: unicode.history[0].prompt === exact}, artifactRoot: dir,
      scopedStatus: cp.execFileSync('git', ['status', '--porcelain', '--', 'tools/vera-playground', 'tools/vera-harness/agent-run.js'], {encoding: 'utf8'}),
      sourceHashes: Object.fromEntries(['server.js','check.js','pipeline-check.js','public/app.js','public/index.html','public/style.css','README.md'].map(file => [file, require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(__dirname, file))).digest('hex')]))}
    fs.writeFileSync(path.join(dir, 'report.json'), JSON.stringify(report, null, 2))
    console.log(JSON.stringify({status: 'pass', artifact: path.join(dir, 'report.json')}))
  } finally { app.close(); await new Promise(resolve => app.server.close(resolve)) }
}
main().catch(error => { console.error(error); process.exitCode = 1 })
