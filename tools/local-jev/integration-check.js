// Actual Rust/model through the application's host adapter. Cloud writer fixtures only.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {execFile} = require('node:child_process')
const {promisify} = require('node:util')
const {loadVera} = require('../vera-harness/source-loader')
const {installLocalSelector} = require('./host-selector')
const root = path.resolve(__dirname,'../..')
async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'local-jev-integration-'))
  const preload = path.join(dir,'providers.cjs'), input = path.join(dir,'input.json')
  fs.writeFileSync(input,JSON.stringify({prompt:'A tip calculator: bill, tip percent, people, total and share.'}))
  fs.writeFileSync(preload,`const fs=require('node:fs');
    const {asPlan}=require(${JSON.stringify(path.join(root,'tools/vera-harness/needs-lib.js'))});
    const fixture=name=>fs.readFileSync(${JSON.stringify(path.join(root,'tools/vera-harness/compose/tip/'))}+name,'utf8');
    global.fetch=async(url,options)=>{
      if(url!=='https://api.deepseek.com/chat/completions')throw Error('No selector network allowed');
      const body=JSON.parse(options.body);
      return Response.json({choices:[{message:{content:body.response_format?asPlan(fixture('sketch.json')):'No supported section can be written.'}}]});
    };`)
  await promisify(execFile)(process.execPath,['tools/vera-harness/agent-run.js','-s','local','-i',input,'-o',dir,'-j','1'],{
    cwd:root,timeout:600000,env:{...process.env,TYPESAFE_API_KEY:'',ARKESTR_API_KEY:'fixture',EXA_API_KEY:'',NODE_OPTIONS:'--require='+preload}})
  const events=fs.readFileSync(path.join(dir,'request/selector-events.jsonl'),'utf8').trim().split('\n').map(JSON.parse)
  assert.ok(events.some(e=>e.response?.scores && e.response.local.diagnostic))
  assert.ok(events.every(e=>!e.error))
  const result=JSON.parse(fs.readFileSync(path.join(dir,'request/result.json')))
  assert.equal(result.transportFailure,'')
  assert.ok(result.served,'fixture calculator renders with standalone local selection')

  const editEvents=[]
  const adapter=installLocalSelector({loadVera,onEvent:e=>editEvents.push(e)})
  try {
    await adapter.prepare()
    assert.ok(loadVera('SettingsStore').settings.hasSelector())
    const C=loadVera('VeraComposition'), c=new C.Composition()
    c.blocks.push(new C.Block('checklist',new Map(),new Map()))
    c.blocks.push(new C.Block('note',new Map(),new Map()))
    const edit=await C.selectEdit('Remove the note',c,'')
    assert.equal(editEvents.length,1)
    assert.ok(editEvents[0].request.questions['edit.op'])
    assert.equal(editEvents[0].response.local.productionAllowed,false)
    fs.writeFileSync(path.join(dir,'report.json'),JSON.stringify({passed:true,qualityEvidence:false,
      generation:result,events,edit,editEvents},null,2))
  } finally { adapter.close() }
  console.log(JSON.stringify({passed:true,report:path.join(dir,'report.json')}))
}
main().catch(error=>{console.error(error);process.exitCode=1})
