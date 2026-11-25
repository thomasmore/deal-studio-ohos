// E2E: shared app plan -> actual local Rust scorer -> diagnostic replies -> real VM preview.
'use strict'
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process')
const {once}=require('node:events')
const {specification}=require('./local-selector')
async function main(){
 const spec=specification()
 const root=path.resolve(__dirname,'../..'),dir=fs.mkdtempSync(path.join(os.tmpdir(),'vera-laya-e2e-')),preload=path.join(dir,'providers.cjs')
 fs.writeFileSync(preload,`const fs=require('node:fs'); const {asPlan}=require(${JSON.stringify(path.join(root,'tools/vera-harness/needs-lib.js'))});
 const fixture=name=>fs.readFileSync(${JSON.stringify(path.join(root,'tools/vera-harness/compose/tip/'))}+name,'utf8');
 global.fetch=async(url,options)=>{
 if(url==='https://api.typesafe.ai/v1/systemone')return new Response(fixture('jev-answer.json'));
 if(url!=='https://api.deepseek.com/chat/completions')throw Error('Unexpected provider');
 const body=JSON.parse(options.body);return Response.json({choices:[{message:{content:body.response_format?asPlan(fixture('sketch.json')):'No supported section can be written.'}}]})
 }`)
 const boot=path.join(dir,'boot.cjs')
 fs.writeFileSync(boot,`const app=require(${JSON.stringify(path.join(__dirname,'server.js'))}).createPlayground({output:${JSON.stringify(dir)}});app.server.listen(0,'127.0.0.1',()=>console.log(app.server.address().port));process.on('SIGTERM',()=>{app.close();app.server.close()})`)
 const env={...process.env,NODE_OPTIONS:'--require='+preload,ARKESTR_API_KEY:'fixture',TYPESAFE_API_KEY:'fixture',EXA_API_KEY:''}
 const child=cp.spawn(process.execPath,[boot],{cwd:root,env,stdio:['ignore','pipe','pipe']});const exited=once(child,'exit')
 const checks=[]
 let stderr = ''
 child.stderr.on('data', chunk => { stderr += chunk })
 try{
 const [chunk]=await Promise.race([once(child.stdout,'data'),exited.then(()=>{throw Error('Fixture server exited before listening. '+stderr)})]),base='http://127.0.0.1:'+String(chunk).trim();const state=async()=> (await fetch(base+'/api/state')).json();const initial=await state()
 assert.equal(initial.busy,false);assert.equal(initial.localSelector.id,spec.id);assert.equal(initial.localSelector.available,true)
 for(const prompt of ['A tip calculator: bill, tip percent, people, total and share.', 'Split a restaurant bill and tip per person.']){
 const response=await fetch(base+'/api/run',{method:'POST',headers:{'Content-Type':'application/json','X-Playground-Token':initial.token},body:JSON.stringify({prompt})});assert.equal(response.status,202)
 let completed
 for(let i=0;i<2400;i++){const s=await state();if(!s.busy&&s.history[0]?.prompt===prompt){completed=s.history[0];break}await new Promise(r=>setTimeout(r,100))}
 assert.ok(completed,'mmBERT comparison completes');assert.equal(completed.plan.planningCalls,1);assert.equal(completed.paths.cloud.planSha256,completed.paths.local.planSha256)
 const events=fs.readFileSync(path.join(dir,completed.id,'local/selector-events.jsonl'),'utf8').trim().split('\n').map(JSON.parse)
 assert.ok(events.length);assert.ok(events.every(e=>e.source?.id===spec.id&&e.source.model===spec.model&&e.source.calibrated===false))
 assert.ok(events.some(e=>e.response.local.diagnostic),'At least one Rust call supplies diagnostic scores')
 for(const e of events.filter(e=>e.response.local.diagnostic)){assert.equal(e.response.local.productionAllowed,false);assert.equal(e.response.local.calibrated,false);assert.ok(Object.keys(e.response.answers).length)
   if(!spec.laya)assert.equal(e.response.local.productionReason,'shared_state_not_human_calibrated')
 }
 checks.push({prompt,comparison:completed,events})
 }
 assert.equal(new Set(checks.flatMap(check=>check.events.map(e=>e.timings.pid))).size,1)
 const files=['tools/vera-playground/local-selector.js','tools/vera-playground/laya-stream.js','tools/vera-playground/server.js','tools/vera-harness/agent-run.js']
 const sha=p=>require('node:crypto').createHash('sha256').update(fs.readFileSync(p)).digest('hex')
 fs.writeFileSync(path.join(dir,'report.json'),JSON.stringify({revision:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),command:process.argv,checks,sourceSha256:Object.fromEntries(files.map(p=>[p,sha(path.join(root,p))])),providerTransport:'fixture',localRunner:spec.id,qualityEvidence:false,passed:true},null,2))
 console.log(JSON.stringify({passed:true,report:path.join(dir,'report.json')}))
 }finally{child.kill('SIGTERM');await exited}
}
main().catch(e=>{console.error(e);process.exitCode=1})
