// E2E for fresh prompts, persisted semantic novelty, retries, and cancellation. No live provider participates.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const cp = require('node:child_process')
const crypto = require('node:crypto')
const {createPlayground} = require('./server')
async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vera-fresh-prompts-'))
  const nativeFetch = global.fetch
  const requests = [], pairs = [], plans = []
  const water = 'Help me track how much water I drink each day, with a daily goal and a log.'
  const plants = 'I need a small plant-care diary with watering dates and a note for each plant.'
  const bicycle = 'Keep a bicycle maintenance log with service dates, distance, and a next-service checklist.'
  const tools = 'Keep a woodworking tool inventory with blade sizes, storage locations, and maintenance notes.'
  const words = 'Give me a vocabulary practice app with word cards and a record of words I have learned.'
  const groceries = 'Track what is in my kitchen and make a shopping list when an ingredient runs low.'
  let candidates = [water], hold = false, holdNovelty=false, outage=false, noveltyFailures=0, held, gate, release, blockAt = Infinity
  global.fetch = async (url, options) => {
    if (url !== 'https://api.deepseek.com/chat/completions') return nativeFetch(url, options)
    const body = JSON.parse(options.body), user = JSON.parse(body.messages[1].content)
    requests.push({system:body.messages[0].content,user,at:Date.now()})
    const noveltyCall=body.messages[0].content.includes('semantic novelty')
    if ((hold&&!noveltyCall)||(holdNovelty&&noveltyCall)) return new Promise((resolve,reject) => {
      held = true
      options.signal.addEventListener('abort', () => reject(Object.assign(Error('cancelled'),{name:'AbortError'})), {once:true})
    })
    if (body.messages[0].content.includes('semantic novelty')) {
      if(user.candidate===bicycle&&noveltyFailures-->0)return new Response('verification unavailable',{status:503})
      assert.match(body.messages[0].content, /language|translation/i)
      const plantTask=/plant|растени/i.test(user.candidate)
      const waterTask=!plantTask&&/water|вод|水/i.test(user.candidate)
      const matching = user.previous.find(row => plantTask?/plant|растени/i.test(row.prompt):waterTask&&!/plant|растени/i.test(row.prompt)&&/water|вод|水/i.test(row.prompt))
      return Response.json({choices:[{message:{content:JSON.stringify({duplicate:Boolean(matching),matching_id:matching?.id || null,reason:matching?'Same core task, despite different wording or language.':'Different primary workflow.'})}}]})
    }
    if(outage)return new Response('provider unavailable',{status:503})
    const next = candidates.shift()
    assert.ok(next, 'test must supply every prompt generation attempt')
    if (next === 'HTTP503') return new Response('provider unavailable', {status:503})
    return Response.json({choices:[{message:{content:JSON.stringify({prompt:next})}}]})
  }
  const open = async (extra={}) => {
    const app = createPlayground({output:dir,retryBaseMs:5,retryMaxMs:20,...extra,credentials:()=>({ARKESTR_API_KEY:'fixture-offline'}),
      capturePlan:async prompt => {plans.push(prompt);return {status:'complete',sha256:'fixture-shared',planningCalls:1,ms:1}},
      runPath:async(kind,prompt,target)=>{
        pairs.push({kind,prompt})
        fs.mkdirSync(target,{recursive:true})
        if(kind==='cloud' && plans.length===blockAt) await new Promise(resolve=>{release=resolve;gate=true})
        return {status:kind==='local'?'uncertain':'complete',uncertainty:kind==='local'?['uncalibrated_model']:[],critical:false,planSha256:'fixture-shared',planningCalls:0}
      }})
    await new Promise(resolve=>app.server.listen(0,'127.0.0.1',resolve))
    const base='http://127.0.0.1:'+app.server.address().port
    const state=async()=>nativeFetch(base+'/api/state').then(res=>res.json())
    const initial=await state()
    const post=async(endpoint,body={})=>nativeFetch(base+endpoint,{method:'POST',headers:{'Content-Type':'application/json','X-Playground-Token':initial.token},body:JSON.stringify(body)})
    const until=async condition=>{for(let i=0;i<1000;i++){const s=await state();if(condition(s))return s;await new Promise(r=>setTimeout(r,10))}throw Error('workflow timeout')}
    return {app,base,state,post,until,close:async()=>{app.close();await new Promise(resolve=>app.server.close(resolve))}}
  }
  let client
  try {
    client=await open()
    assert.equal(requests.length,0,'page load must not call a provider')
    assert.equal((await client.post('/api/random')).status,202)
    let s=await client.until(s=>!s.busy)
    assert.equal(s.promptGeneration.prompt,water)
    assert.equal(plans.length,0,'Random must not plan or run a comparison')
    candidates=['Напомни мне пить воду и записывать выпитые стаканы каждый день.','每天记录饮水量，设置每日目标并查看喝水日志。',water,water,water,'HTTP503',plants]
    const before=requests.length
    await client.post('/api/random')
    s=await client.until(s=>!s.busy)
    assert.equal(s.promptGeneration.prompt,plants)
    assert.equal(s.promptGeneration.attemptCount,7,'duplicates and provider failures must recover beyond a fixed retry cap')
    assert.ok(requests.slice(before).filter(r=>r.system.includes('semantic novelty')).length>=2,'paraphrases require semantic checks')
    const retryCalls=requests.slice(before).filter(r=>!r.system.includes('semantic novelty'))
    assert.ok(retryCalls.slice(1).every((r,i)=>r.at-retryCalls[i].at>=4),'retries must wait instead of forming a tight loop')
    const generated=requests.filter(r=>!r.system.includes('semantic novelty'))
    assert.equal(new Set(generated.map(r=>r.user.seed)).size,generated.length,'each attempt needs a fresh diversity seed')
    assert.ok(generated.some((r,i)=>i>0&&r.user.language!==generated[i-1].user.language))
    const plantId=s.promptGeneration.id
    await client.close();client=await open()
    const startupCalls=requests.length
    await client.state();assert.equal(requests.length,startupCalls,'restart must not resume generation')
    candidates=['A plant watering diary with a note and last-watered date for every plant.',bicycle,tools];noveltyFailures=1
    await client.post('/api/random')
    s=await client.until(s=>!s.busy)
    assert.equal(s.promptGeneration.prompt,tools,'persisted duplicates and a novelty-provider failure must recover')
    assert.equal(s.promptGeneration.attemptCount,3)
    const persisted=JSON.parse(fs.readFileSync(path.join(dir,'prompt-generations',s.promptGeneration.id+'.json'),'utf8'))
    assert.ok(persisted.attempts[0].rejected,'a persisted unrun request must reject its paraphrase')
    assert.equal(persisted.attempts[1].error,'DeepSeek novelty HTTP 503')
    assert.ok(requests.slice(startupCalls).some(r=>r.user.previous?.some(p=>p.id.startsWith(plantId))))
    candidates=[words,groceries]
    blockAt=plans.length+2
    await client.post('/api/run',{auto:true})
    await client.until(()=>gate)
    await client.post('/api/stop')
    release()
    s=await client.until(s=>!s.busy)
    assert.equal(s.auto,false)
    assert.deepEqual(plans,[words,groceries])
    assert.deepEqual(pairs.map(p=>p.prompt),[words,words,groceries,groceries])
    assert.ok(s.history.every(row=>row.promptGeneration?.status==='complete'))
    assert.ok(s.history.every(row=>fs.existsSync(path.join(dir,row.id,'shared/prompt-generation.json'))))
    const used=s.history[0]
    assert.equal((await client.post('/api/run',{prompt:used.prompt,promptGenerationId:used.promptGeneration.id})).status,400,'a consumed provenance ID must retain its original comparison')
    const afterStop=requests.length
    await new Promise(r=>setTimeout(r,60));await client.state();assert.equal(requests.length,afterStop,'Stop prevents another iteration')
    hold=true;held=false
    await client.post('/api/random')
    await client.until(()=>held)
    assert.equal((await client.post('/api/run',{auto:true})).status,409,'prompt generation must not overlap another operation')
    await client.post('/api/stop')
    s=await client.until(s=>!s.busy)
    assert.equal(s.promptGeneration.status,'cancelled')
    const cancelledCalls=requests.length
    await new Promise(r=>setTimeout(r,60));assert.equal(requests.length,cancelledCalls,'cancelled generation must not retry')
    assert.equal(plans.length,2)
    await client.close();client=await open({retryBaseMs:10000,retryMaxMs:10000})
    hold=false;outage=true
    await client.post('/api/random')
    await client.until(s=>s.promptGeneration.status==='retrying')
    const beforeTimerStop=Date.now()
    await client.post('/api/stop')
    await client.until(s=>!s.busy)
    assert.ok(Date.now()-beforeTimerStop<2000,'Stop must cancel a ten-second retry delay promptly')
    const stoppedBackoff=requests.length
    await new Promise(r=>setTimeout(r,60));assert.equal(requests.length,stoppedBackoff,'Stop must cancel a retry timer')
    await client.close();client=await open()
    outage=false;holdNovelty=true;held=false;candidates=['Record scores for our board-game evenings, with player names and a season leaderboard.']
    await client.post('/api/random')
    await client.until(s=>held&&s.promptGeneration.status==='verifying')
    await client.post('/api/stop')
    s=await client.until(s=>!s.busy)
    assert.equal(s.promptGeneration.status,'cancelled','Stop must cancel semantic verification')
    const afterVerificationStop=requests.length
    await new Promise(r=>setTimeout(r,60));assert.equal(requests.length,afterVerificationStop)
    await client.close();client=await open({leaseMs:100})
    holdNovelty=false;hold=true;held=false
    await client.post('/api/random')
    await new Promise(r=>setTimeout(r,350))
    s=await client.state()
    assert.equal(s.busy,false,'heartbeat expiry must abort a pending provider call')
    assert.match(s.promptGeneration.error,/heartbeat expired/)
    await client.close();client=await open()
    const plansBeforeAutoCancel=plans.length
    held=false;hold=true;holdNovelty=false
    await client.post('/api/run',{auto:true})
    await client.until(()=>held)
    await client.post('/api/stop')
    s=await client.until(s=>!s.busy)
    assert.equal(s.auto,false)
    assert.equal(s.history[0].plan.status,'not-started')
    assert.equal(s.history[0].promptGeneration.status,'cancelled')
    assert.ok(Object.values(s.history[0].paths).every(value=>value.status==='interrupted'))
    assert.equal(plans.length,plansBeforeAutoCancel,'Auto Stop during generation must not plan a pair')
    await client.close();client=await open({leaseMs:100})
    held=false
    await client.post('/api/run',{auto:true})
    await new Promise(r=>setTimeout(r,350))
    s=await client.state()
    assert.equal(s.busy,false)
    assert.equal(s.auto,false)
    assert.equal(s.history[0].plan.status,'not-started')
    assert.equal(s.history[0].promptGeneration.status,'cancelled')
    assert.equal(held,true,'the Auto heartbeat test must hold a live provider call')
    assert.match(s.history[0].promptGeneration.error,/heartbeat expired/)
    assert.ok(Object.values(s.history[0].paths).every(value=>value.status==='interrupted'))
    assert.equal(plans.length,plansBeforeAutoCancel,'Auto heartbeat expiry must not plan a pair')
    await client.close()
    const interruptedId=String(Date.now())+'-abcdef01'
    const interrupted={id:interruptedId,prompt:'',startedAt:new Date().toISOString(),plan:{status:'pending'},promptGeneration:{id:interruptedId,status:'retrying',attemptCount:1},paths:{cloud:{status:'pending'},local:{status:'pending'}}}
    fs.mkdirSync(path.join(dir,interruptedId));fs.writeFileSync(path.join(dir,interruptedId,'comparison.json'),JSON.stringify(interrupted))
    fs.writeFileSync(path.join(dir,'prompt-generations',interruptedId+'.json'),JSON.stringify({id:interruptedId,mode:'auto',status:'retrying',attemptCount:1,attempts:[]}))
    const beforeRestart=requests.length
    client=await open();s=await client.state()
    assert.equal(requests.length,beforeRestart)
    assert.equal(s.history[0].promptGeneration.status,'interrupted')
    assert.equal(JSON.parse(fs.readFileSync(path.join(dir,interruptedId,'comparison.json'),'utf8')).promptGeneration.status,'interrupted')
    const report={revision:cp.execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),command:'node tools/vera-playground/prompt-check.js',
      inputs:'isolated DeepSeek candidates and semantic judgments, persisted generated-but-unrun history, duplicates in English/Russian/Chinese, HTTP 503, Auto, Stop, cancellation',
      expected:'fresh generation on each request/iteration, semantic duplicate rejection, retries without terminal cap, provider recovery, one shared plan per pair, no calls after Stop or on load',
      observed:{status:'pass',providerCalls:requests.length,plans,pairs,cancelled:true},artifactRoot:dir,
      scopedStatus:cp.execFileSync('git',['status','--porcelain','--','tools/vera-playground','tools/vera-harness/agent-run.js'],{encoding:'utf8'}),
      sourceHashes:Object.fromEntries(['server.js','public/app.js','public/index.html','public/style.css','README.md','check.js','pipeline-check.js','prompt-check.js','../vera-harness/agent-run.js'].map(file=>[file,crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,file))).digest('hex')]))}
    fs.writeFileSync(path.join(dir,'report.json'),JSON.stringify(report,null,2))
    console.log(JSON.stringify({status:'pass',artifact:path.join(dir,'report.json')}))
  } finally {global.fetch=nativeFetch;if(client)await client.close()}
}
main().catch(error=>{console.error(error);process.exitCode=1})
