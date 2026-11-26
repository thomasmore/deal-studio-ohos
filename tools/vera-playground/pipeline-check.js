// E2E: isolated provider replies -> actual app route -> Rust CLI -> compiler/VM -> SVG.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const cp = require('node:child_process')
const {once} = require('node:events')
const {specification} = require('./local-selector')
async function main() {
  const root = path.resolve(__dirname, '../..')
  const spec = specification()
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-playground-pipeline-'))
  const preload = path.join(dir, 'providers.cjs')
  const scenarioFile = path.join(dir, 'scenario.json')
  fs.writeFileSync(scenarioFile, '{}')
  fs.writeFileSync(preload, `
const fs = require('node:fs')
const scenario = () => JSON.parse(fs.readFileSync(${JSON.stringify(scenarioFile)}, 'utf8'))
const cp = require('node:child_process'), original = cp.execFile
cp.execFile = (file, args, options, callback) => {
  const test = scenario()
  if (args.includes('--shared-plan') && test.tamper) {
    const sharedFile=args[args.indexOf('--shared-plan')+1],shared=JSON.parse(fs.readFileSync(sharedFile,'utf8'))
    shared.plan+=' ';fs.writeFileSync(sharedFile,JSON.stringify(shared))
  }
  if (args.includes('--shared-plan') && test.replan) options={...options,env:{...options.env,AGENT_ANSWER:'other'}}
  if (args.includes('--shared-plan') && test.exaFailure) options={...options,env:{...options.env,EXA_API_KEY:'fixture-offline'}}
  if (args.includes('--shared-plan') && test.hold) return original(process.execPath, ['-e', 'require("node:fs").writeFileSync(' + JSON.stringify(${JSON.stringify(path.join(dir,'held-child.pid'))}) + ',String(process.pid));setInterval(()=>{},1000)'], options, callback)
  if (args.includes('--shared-plan') && test.crash) {
    const out = args[args.indexOf('-o') + 1]
    const source = "const fs=require('node:fs'),path=require('node:path'),dir=path.join(process.argv[1],'request');fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'program.vera'),'// partial artifact');fs.writeFileSync(path.join(dir,'result.json'),'{');fs.writeFileSync(path.join(dir,'selector-events.jsonl'),JSON.stringify({ms:3,response:{answers:{}},error:''})+'\\\\n');process.exit(1)"
    return original(process.execPath, ['-e', source, out], options, callback)
  }
  return original(file, args, options, callback)
}
const {asPlan} = require(${JSON.stringify(path.join(root, 'tools/vera-harness/needs-lib.js'))})
const fixture = file => fs.readFileSync(${JSON.stringify(path.join(root, 'tools/vera-harness/compose/tip/'))} + file, 'utf8')
global.fetch = async (url, options) => {
  if (url === 'https://api.exa.ai/search') {
    fs.appendFileSync(${JSON.stringify(path.join(dir,'search-calls.jsonl'))}, 'attempt\\n')
    return new Response('upstream unavailable',{status:503})
  }
  if (url === 'https://api.typesafe.ai/v1/systemone') {
    fs.appendFileSync(${JSON.stringify(path.join(dir, 'cloud-requests.jsonl'))}, JSON.stringify(options.body) + '\\n')
    const test = scenario()
    if (test.replayFailure && !process.argv.includes('--shared-plan')) return new Response('upstream unavailable', {status:503})
    const questions=JSON.parse(options.body).questions
    if (questions['blocking.0']) return Response.json({answers:{'blocking.0':{choice:'ask',probabilities:{ask:1,skip:0}}}})
    if (test.reason === 'option_token_budget') await new Promise(resolve => setTimeout(resolve, 300))
    if (test.exaFailure || test.diverged) {
      const answers=JSON.parse(fixture('jev-answer.json')).answers
      for (const key of Object.keys(questions)) {
        const choice=key==='real_data'?(test.diverged?'false':'true'):key.startsWith('whose.')?'written':key.startsWith('ready.')?(test.diverged?'itinerary':'key_facts'):null
        if(choice) answers[key]={type:'choice',choice,confidence:1,probabilities:{[choice]:1}}
        if(questions[key].type==='noul') answers[key]=key.endsWith('.navigate')?{type:'choice',noul:0.8}:{noul:0.8}
      }
      if (test.diverged && questions['ready.0']) {
        delete answers['ready.0'].type
        answers.real_data.type = 'noul'
      }
      return Response.json({answers})
    }
    return new Response(fixture('jev-answer.json'))
  }
  if (url !== 'https://api.deepseek.com/chat/completions') throw Error('Unexpected test provider')
  const body = JSON.parse(options.body)
  if(body.messages[0].content.includes('mini-app request generator')) return Response.json({choices:[{message:{content:JSON.stringify({prompt:scenario().replayFailure?'Game night tip calculator: the bill amount, a tip percent slider and the number of people; show the tip, the total and what each person pays. Give it the name Crew Tip.':'A tip calculator for a different dinner group. Keep the bill, tip percent, people, total and share. Session '+JSON.parse(body.messages[1].content).seed})}}]})
  if(body.messages[0].content.includes('semantic novelty')) return Response.json({choices:[{message:{content:JSON.stringify({duplicate:false,matching_id:null,reason:'Isolated transport scenario accepts this fixture.'})}}]})
  if (body.response_format) fs.appendFileSync(${JSON.stringify(path.join(dir, 'planning-calls.jsonl'))}, JSON.stringify({user:body.messages[1].content}) + '\\n')
  if (scenario().httpFailure || scenario().failPrompt === body.messages[1].content) return new Response('upstream unavailable', {status:503})
  const plan=JSON.parse(asPlan(fixture('sketch.json')))
  if (scenario().exaFailure || scenario().diverged) plan.needs.push({type:'content',what:'Current local information for the bill and tip',from:'Tip calculator'})
  if (scenario().questions || scenario().replan) plan.questions=[{id:'style',ask:'Which style?',options:['Simple','Detailed'],default:0}]
  const content = body.response_format ? scenario().badPlan ? 'not a usable plan' : JSON.stringify(plan) : 'No supported section can be written.'
  return Response.json({choices: [{message: {content}}]})
}
`)
  const boot = path.join(dir, 'boot.cjs')
  fs.writeFileSync(boot, `const fs = require('node:fs');
  const {LayaStream} = require(${JSON.stringify(path.join(__dirname, 'laya-stream.js'))});
  const query = LayaStream.prototype.query;
  LayaStream.prototype.query = async function (...args) {
    const test = JSON.parse(fs.readFileSync(${JSON.stringify(scenarioFile)}, 'utf8'));
    if (test.reason) return {response:{answers:{},local:{status:'uncertain',reason:test.reason}},timings:{cold:false,totalMs:1,warmInferenceMs:1,roundtripMs:1}};
    if (test.killPid) {
      this.state.child.stdin.write = () => {
        process.kill(test.killPid, 'SIGTERM');
        return true;
      };
    }
    return query.apply(this, args);
  };
  const app = require(${JSON.stringify(path.join(__dirname, 'server.js'))}).createPlayground({output:${JSON.stringify(dir)}}); app.server.listen(0, '127.0.0.1', () => console.log(app.server.address().port)); process.on('SIGTERM',()=>{app.close();app.server.close()})`)
  const env = Object.fromEntries(['PATH', 'HOME', 'TMPDIR', 'VERA_TYPESCRIPT_PATH', 'VERA_LAYA_CLI', 'VERA_LAYA_MANIFEST'].filter(name => process.env[name]).map(name => [name, process.env[name]]))
  Object.assign(env, {DEEPSEEK_API_KEY: 'fixture-offline', TYPESAFE_API_KEY: 'fixture-offline', NODE_OPTIONS: '--require=' + preload})
  const child = cp.spawn(process.execPath, [boot], {cwd: root, env, stdio: ['ignore', 'pipe', 'pipe']})
  const exited = once(child, 'exit')
  let startupError = ''
  child.stderr.on('data', chunk => { startupError += chunk })
  try {
    const [chunk] = await Promise.race([once(child.stdout, 'data'), exited.then(() => { throw Error(`Fixture server exited before listening. ${startupError}`) })])
    const base = 'http://127.0.0.1:' + String(chunk).trim()
    const state = async () => (await fetch(base + '/api/state')).json()
    const initial = await state()
    assert.equal(initial.localSelector.available, true, 'the selected Rust bundle is available')
    assert.equal(initial.localSelector.id, spec.id)
    const prompt = 'Game night tip calculator: the bill amount, a tip percent slider and the number of people; show the tip, the total and what each person pays.\nPreserve this exact line.'
    const res = await fetch(base + '/api/run', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Playground-Token': initial.token}, body: JSON.stringify({prompt})})
    assert.equal(res.status, 202)
    let completed
    for (let i = 0; i < 2400; i++) { const s = await state(); if (!s.busy && s.history.length) { completed = s.history[0]; break } await new Promise(r => setTimeout(r, 100)) }
    assert.ok(completed, 'comparison must finish')
    assert.equal(completed.prompt, prompt)
    assert.equal(completed.paths.cloud.status, 'complete', JSON.stringify(completed.paths.cloud))
    assert.equal(completed.localModel, spec.id)
    assert.equal(completed.paths.local.status, 'diagnostic', JSON.stringify(completed.paths.local))
    assert.equal(completed.paths.local.selectorSource.model, spec.model)
    assert.equal(completed.paths.local.selectorSource.calibrated, false)
    assert.equal(completed.paths.local.selectorSource.productionAllowed, false)
    assert.match(completed.paths.local.selectorSource.quantization, spec.laya ? /Q4_0/ : /Q8/)
    const assetBytes = spec.assets
      .reduce((bytes, name) => bytes + fs.statSync(path.join(spec.bundle, name)).size, fs.statSync(spec.manifestFile).size)
    assert.equal(completed.paths.local.selectorSource.bundleBytes, assetBytes)
    assert.equal(completed.plan.planningCalls, 1)
    assert.equal(fs.readFileSync(path.join(dir, 'planning-calls.jsonl'), 'utf8').trim().split('\n').length, 1, 'exactly one DeepSeek planning call')
    const cloudPlan = JSON.parse(fs.readFileSync(path.join(dir, completed.id, 'cloud/plan-use.json'), 'utf8'))
    const localPlan = JSON.parse(fs.readFileSync(path.join(dir, completed.id, 'local/plan-use.json'), 'utf8'))
    assert.equal(cloudPlan.plan, localPlan.plan, 'both paths consume byte-identical shared plan text')
    assert.equal(cloudPlan.sha256, completed.plan.sha256)
    assert.equal(localPlan.sha256, completed.plan.sha256)
    assert.equal(cloudPlan.planningCalls + localPlan.planningCalls, 0, 'neither path makes a hidden planning call')
    for (const kind of ['cloud', 'local']) {
      assert.ok(completed.paths[kind].selectorCalls > 0)
      assert.ok(completed.paths[kind].selectorMs >= 0)
      const input = JSON.parse(fs.readFileSync(path.join(dir, completed.id, kind, 'input.json'), 'utf8'))
      assert.equal(input.prompt, prompt)
    }
    const eventsFor = (row, kind) => fs.readFileSync(path.join(dir, row.id, kind, 'selector-events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse)
    const events = eventsFor(completed, 'local')
    const rustPid = events[0].timings.pid
    assert.ok(rustPid > 0)
    assert.ok(events.every(e => e.timings.pid === rustPid && e.timings.modelStartupMs > 0 && e.timings.warmInferenceMs > 0 && e.ms > 0))
    assert.ok(events.some(e => e.response.local.diagnostic && Object.keys(e.response.answers).length))
    const readComparison = async row => {
      const res = await fetch(base + `/artifacts/${row.id}/shared/selector-comparison.json`)
      assert.equal(res.status, 200)
      return res.json()
    }
    const compared = await readComparison(completed)
    const bodies = new Set([...eventsFor(completed, 'cloud'), ...events].map(e => e.body))
    assert.deepEqual(new Set(compared.requests.map(r => r.body)), bodies)
    assert.equal(compared.summary.requests, bodies.size)
    assert.ok(compared.summary.paired > 0)
    assert.ok(compared.summary.choice.compared > 0)
    assert.equal(compared.summary.timing, null, 'incomplete Cloud replies do not enter matched warm timing')
    for (const entry of compared.requests) {
      for (const kind of ['cloud', 'local']) {
        assert.equal(entry[kind].source, eventsFor(completed, kind).some(e => e.body === entry.body) ? 'build' : 'replay')
      }
    }
    assert.equal(fs.readFileSync(path.join(dir, 'cloud-requests.jsonl'), 'utf8').trim().split('\n').length,
      eventsFor(completed, 'cloud').length + compared.summary.replays.cloud, 'cloud replays only missing counterparts')
    async function checkPreviews(row) {
      for (const kind of ['cloud', 'local']) {
        assert.equal(row.paths[kind].preview, true, `${kind} preview is available`)
        const response = await fetch(base + `/artifacts/${row.id}/${kind}/preview.svg`)
        assert.equal(response.status, 200)
        const svg = await response.text()
        assert.match(svg, /<svg/)
        assert.match(svg, /Tip/)
      }
    }
    await checkPreviews(completed)
    const scenarios = []
    async function another(test, auto = true) {
      fs.writeFileSync(scenarioFile, JSON.stringify(test))
      const beforeCalls = fs.readFileSync(path.join(dir, 'planning-calls.jsonl'), 'utf8').trim().split('\n').length
      const response = await fetch(base + '/api/run', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Playground-Token': initial.token}, body: JSON.stringify(auto?{auto:true}:{prompt})})
      assert.equal(response.status, 202)
      for (let i = 0; i < 2400; i++) {
        const current = await state()
        if (!current.busy && !current.auto) {
          assert.equal(fs.readFileSync(path.join(dir, 'planning-calls.jsonl'), 'utf8').trim().split('\n').length - beforeCalls, 1)
          scenarios.push({input:test, observed:current.history[0], notice:current.notice}); return current.history[0]
        }
        await new Promise(r => setTimeout(r, 100))
      }
      throw Error('failure scenario did not stop Auto mode')
    }
    const repeated = await another({}, false)
    await checkPreviews(repeated)
    assert.ok(eventsFor(repeated, 'local').every(e => e.timings.pid === rustPid), 'a second pair reuses the Rust process')
    const interrupted = await another({killPid:rustPid}, false)
    assert.equal(interrupted.paths.local.error, spec.laya ? 'Laya process exited' : 'Rust selector process exited')
    assert.equal(interrupted.paths.local.selectorCalls, 1)
    assert.equal(interrupted.selectorComparison.replays.local, 0, 'the failed Rust call must not replay')
    const restarted = await another({}, false)
    await checkPreviews(restarted)
    const restartedPid = eventsFor(restarted, 'local')[0].timings.pid
    assert.notEqual(restartedPid, rustPid, 'a later pair restarts after worker exit')
    for (const reason of ['model_unavailable', 'unknown_future_failure']) {
      const result = await another({reason})
      assert.equal(result.paths.local.status, 'failed')
      assert.equal(result.paths.local.error, reason)
      assert.equal(result.paths.local.critical, true)
    }
    const budget = await another({reason:'option_token_budget'}, false)
    const budgetComparison = await readComparison(budget)
    assert.equal(budget.paths.local.status, 'uncertain')
    assert.equal(budget.paths.local.critical, false)
    assert.equal(budgetComparison.summary.paired, 1)
    assert.equal(budgetComparison.summary.choice.compared, 0)
    assert.equal(budgetComparison.summary.timing, null, 'a 1 ms refusal is not comparable to a 300 ms answer')
    const question = await another({questions:true}, false)
    await checkPreviews(question)
    assert.equal(question.paths.cloud.status, 'complete', 'default answers must not request replanning')
    assert.equal(question.paths.cloud.planSha256, question.paths.local.planSha256)
    assert.ok(eventsFor(question, 'local').every(e => e.timings.pid === restartedPid))
    assert.equal(question.selectorComparison.timing.paired, 1, 'a complete request counts when Cloud omits the answer type')
    const cloudRequests = () => fs.readFileSync(path.join(dir, 'cloud-requests.jsonl'), 'utf8').trim().split('\n').map(JSON.parse)
    const beforeDivergence = cloudRequests().length
    const different = await another({diverged:true}, false)
    const diverged = await readComparison(different)
    assert.ok(diverged.summary.replays.cloud > 0 && diverged.summary.replays.local > 0, JSON.stringify(diverged.summary))
    const cases = diverged.requests.flatMap(row => Object.entries(JSON.parse(row.body).questions)
      .filter(([, question]) => question.type === 'choice')
      .map(([key, question]) => ({criteria: question.criteria, cloud: row.cloud.response?.answers[key],
        local: row.local.response?.answers[key]})))
    assert.ok(cases.some(({cloud, local}) => cloud?.type === 'noul' && local), 'fixture supplies a contradictory type')
    assert.ok(cases.some(({cloud, local}) => cloud && !Object.hasOwn(cloud, 'type') && local), 'fixture supplies an omitted type')
    assert.equal(diverged.summary.choice.eligible, cases.length)
    const validPairs = cases.filter(({criteria, cloud, local}) =>
      cloud?.type !== 'noul' && Object.hasOwn(criteria, cloud?.choice) && Object.hasOwn(criteria, local?.choice))
    assert.equal(diverged.summary.choice.compared, validPairs.length, 'a contradictory choice type is excluded and an absent type is accepted')
    assert.equal(diverged.summary.noul.eligible, 2)
    assert.equal(diverged.summary.noul.compared, 1, 'a contradictory noul type is excluded')
    const calendar = diverged.requests.find(row => row.cloud.response.answers['section1.itinerary.calendar'])
    assert.equal(diverged.summary.noul.meanAbsoluteDelta, Math.abs(0.8 - calendar.local.response.answers['section1.itinerary.calendar'].noul))
    assert.deepEqual(cloudRequests().slice(beforeDivergence), [...eventsFor(different, 'cloud').map(e => e.body),
      ...diverged.requests.filter(r => r.cloud.source === 'replay').map(r => r.body)])
    const localReplays = diverged.requests.filter(row => row.local.source === 'replay')
    assert.equal(localReplays.length, diverged.summary.replays.local)
    assert.ok(localReplays.every(row => row.local.timings.pid === restartedPid && row.local.selectorSource.id === spec.id))
    const replayFailure = await another({diverged:true,replayFailure:true})
    assert.equal(replayFailure.paths.cloud.critical, false)
    assert.equal(replayFailure.paths.local.critical, false)
    assert.equal(replayFailure.selectorComparison.status, 'partial')
    assert.match(replayFailure.selectorComparison.error, /Jev HTTP 503/)
    assert.match(scenarios.at(-1).notice, /Auto mode stopped after a selector replay failed/)
    const replan = await another({replan:true})
    assert.equal(replan.paths.cloud.status, 'failed')
    assert.match(replan.paths.cloud.error, /requires replanning/)
    const tamper = await another({tamper:true})
    assert.equal(tamper.paths.cloud.status, 'failed')
    assert.match(tamper.paths.cloud.error, /provenance check failed/)
    const partial = await another({crash:true})
    assert.equal(partial.paths.cloud.selectorCalls, 1, 'partial selector events survive a process failure')
    assert.equal(partial.paths.cloud.selectorMs, 3)
    assert.equal((await fetch(base + '/artifacts/' + partial.id + '/cloud/program.vera')).status, 200)
    const bad = await another({badPlan:true})
    assert.equal(bad.plan.planningCalls, 1, 'an invalid plan must not trigger a hidden retry')
    assert.equal(bad.paths.cloud.selectorCalls, 0)
    assert.match(bad.plan.error, /unusable shared plan/)
    const httpFailure = await another({httpFailure:true})
    assert.equal(httpFailure.plan.error, 'DeepSeek HTTP 503')
    assert.equal(httpFailure.plan.planningCalls, 1)
    assert.equal(httpFailure.paths.cloud.selectorCalls, 0, 'a prior DeepSeek failure is not a selector call')
    const exa = await another({exaFailure:true})
    assert.equal(exa.paths.cloud.error, 'Exa HTTP 503')
    assert.ok(fs.readFileSync(path.join(dir,'search-calls.jsonl'),'utf8').length>0)
    const failedPrompt = 'Tip calculator with a mocked planning failure.'
    const healthyPrompt = prompt.split('\n')[0].replace('Game night', 'Dinner')
    const promptFile = path.join(dir, 'isolated-labels.tsv')
    fs.writeFileSync(promptFile, `failed\t${failedPrompt}\nhealthy\t${healthyPrompt}\n`)
    fs.writeFileSync(scenarioFile, JSON.stringify({failPrompt: failedPrompt}))
    const isolatedLabels = []
    for (const jobs of [1, 2]) {
      const output = path.join(dir, 'isolated-labels-' + jobs)
      const callLog = path.join(dir, 'planning-calls.jsonl')
      const before = fs.statSync(callLog).size
      cp.execFileSync(process.execPath, ['tools/vera-harness/agent-run.js', '-r', '-s', 'cloud', '-j', String(jobs), '-p', promptFile, '-o', output],
        {cwd: root, env: {...env, ARKESTR_API_KEY: 'fixture-offline'}, stdio: 'pipe'})
      const readResult = label => JSON.parse(fs.readFileSync(path.join(output, label, 'result.json'), 'utf8'))
      const failed = readResult('failed'), healthy = readResult('healthy')
      const planned = fs.readFileSync(callLog).subarray(before).toString().trim().split('\n').map(line => JSON.parse(line).user)
      assert.equal(failed.transportFailure, 'DeepSeek HTTP 503')
      assert.equal(fs.existsSync(path.join(output, 'failed', 'selector-events.jsonl')), false)
      assert.deepEqual(planned.sort(), [failedPrompt, healthyPrompt].sort(), `both labels plan with -j ${jobs}`)
      assert.equal(healthy.transportFailure, '')
      assert.equal(healthy.served, true)
      isolatedLabels.push({jobs, planned, failed, healthy})
    }
    fs.writeFileSync(scenarioFile, '{}')
    const localOnlyEnv = {...env, ARKESTR_API_KEY: 'fixture-offline'}; delete localOnlyEnv.TYPESAFE_API_KEY
    cp.execFileSync(process.execPath, ['tools/vera-harness/agent-run.js','-r','-s','local','-i',path.join(dir,completed.id,'local/input.json'),'-o',path.join(dir,'local-without-typesafe'),'--shared-plan',path.join(dir,completed.id,'shared/shared-plan.json')], {cwd:root,env:localOnlyEnv})
    assert.ok(fs.readFileSync(path.join(dir,'local-without-typesafe/request/selector-events.jsonl'),'utf8').includes('playground_uncalibrated_logits'))
    fs.writeFileSync(scenarioFile, JSON.stringify({hold:true}))
    assert.equal((await fetch(base+'/api/run',{method:'POST',headers:{'Content-Type':'application/json','X-Playground-Token':initial.token},body:JSON.stringify({prompt})})).status,202)
    for(let i=0;i<100&&!fs.existsSync(path.join(dir,'held-child.pid'));i++) await new Promise(r=>setTimeout(r,100))
    const heldPid=Number(fs.readFileSync(path.join(dir,'held-child.pid'),'utf8'))
    child.kill('SIGTERM');await exited
    let terminated=false
    for(let i=0;i<100;i++){try{process.kill(heldPid,0)}catch(error){if(error.code==='ESRCH'){terminated=true;break}}await new Promise(r=>setTimeout(r,20))}
    assert.equal(terminated,true,'server shutdown must terminate its active host child')
    assert.throws(() => process.kill(restartedPid, 0), {code: 'ESRCH'}, 'server shutdown must terminate the Rust worker')
    let wrongProfile
    if (spec.laya) {
      const probe = `const app = require(${JSON.stringify(path.join(__dirname, 'server.js'))}).createPlayground({output:${JSON.stringify(path.join(dir, 'profile-probe'))}});
        app.server.listen(0, '127.0.0.1', async () => {
          try { const state = await (await fetch('http://127.0.0.1:' + app.server.address().port + '/api/state')).json(); console.log(JSON.stringify(state.localSelector)); }
          finally { app.close(); app.server.close(); }
        });`
      const wrongBundle = path.join(dir, 'wrong-profile')
      fs.mkdirSync(wrongBundle)
      for (const name of ['laya-config.json', 'tokenizer.json', 'model.gguf']) {
        fs.symlinkSync(path.join(spec.bundle, name), path.join(wrongBundle, name))
      }
      const wrongManifest = path.join(wrongBundle, 'laya-manifest.json')
      fs.writeFileSync(wrongManifest, JSON.stringify({...spec.manifest,
        quantization: spec.manifest.quantization.replace('Q4_0 token embeddings', 'Q6K token embeddings')}))
      wrongProfile = JSON.parse(cp.execFileSync(process.execPath, ['-e', probe], {encoding:'utf8',timeout:10000,
        env:{...env,NODE_OPTIONS:'',VERA_LAYA_MANIFEST:wrongManifest}}))
      assert.equal(wrongProfile.available, false, 'a Q6 embedding bundle cannot be offered as Q4')
    }
    const report = {revision: cp.execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), command: 'node tools/vera-playground/pipeline-check.js',
      inputs: ['recorded tip plan and Jev answers', 'isolated DeepSeek and TypeSafe', spec.id, 'exact multiline prompt'],
      expected: 'One shared plan and two SVG previews per successful pair. Rust reuses its worker and restarts after exit. Complete warm replies count toward timing. Exact replay provenance survives. Operational replay failures stop Auto. Planning failures stay within each label. An explicit Laya Q6/Q4 profile is unavailable.', observed: completed, compared: compared.summary, scenarios, isolatedLabels, wrongProfile, status: 'pass',
      scopedStatus: cp.execFileSync('git', ['status', '--porcelain', '--', 'tools/vera-playground', 'tools/vera-harness/agent-run.js'], {encoding: 'utf8'}),
      sourceHashes: Object.fromEntries(['server.js','check.js','pipeline-check.js','laya-stream.js','local-selector.js','selector-comparison.js','public/app.js','public/index.html','public/style.css','README.md','../vera-harness/agent-run.js'].map(file => [file, require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(__dirname, file))).digest('hex')]))}
    fs.writeFileSync(path.join(dir, 'report.json'), JSON.stringify(report, null, 2))
    console.log(JSON.stringify({status: 'pass', artifact: path.join(dir, 'report.json')}))
  } finally { if(child.exitCode===null&&!child.signalCode) child.kill(); await exited }
}
main().catch(error => { console.error(error); process.exitCode = 1 })
