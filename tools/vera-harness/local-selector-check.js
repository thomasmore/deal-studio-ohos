// App-boundary tests: generation and structural edits, no keys, no real model/network.
'use strict'
const assert = require('node:assert/strict')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const trust = loadSource(require('node:path').join(sourceRoot,'components/LaunchTrust.ets'))
assert.ok(trust.DEV_PARAMETER_NAMES.includes('localJev'))
assert.ok(trust.startedByApp({parameters:{localJev:'1','ohos.aafwk.param.callerBundleName':'untrusted.app'}}))
assert.equal(trust.startedByApp({parameters:{localJev:'1','ohos.aafwk.param.callerNativeName':'aa'}}),false)
const {settings} = loadVera('SettingsStore')
const {localJev} = loadVera('LocalJev')
const {OperationController} = loadVera('OperationCancellation')
const C = loadVera('VeraComposition')
const {askJev} = loadVera('VeraCompose')
const {askSelector} = loadVera('VeraSelector')
const {installLocalSelector} = require('../local-jev/host-selector')
const seen = []
let queries = 0, network = 0, fail = false, release
const stream = {
  async warm() {}, close() {},
  async query(body) {
    queries++
    if (fail) throw Error('worker failed')
    if (release) await release.promise
    const request = JSON.parse(body)
    const answers = {}
    for (const [id,q] of Object.entries(request.questions)) {
      const choice = id === 'edit.op' ? C.OP_REMOVE : id === 'edit.target' ? 'note' :
        id === 'edit.kind' ? 'none' : Object.keys(q.criteria || {}).sort()[0]
      answers[id] = q.type === 'noul' ? {noul:0.03} : {choice,probabilities:{[choice]:1}}
    }
    return {response:{answers,local:{status:'diagnostic',diagnostic:true,productionAllowed:false,calibrated:false}},
      source:{id:'fixture'},timings:{},requestId:'fixture'}
  },
}
// Fake native load to test routing without any weights. Real worker integration is separate.
const adapter = installLocalSelector({loadVera,stream,onEvent:e=>seen.push(e)})
globalThis.__veraLocalJev.status = async () => JSON.stringify({ready:true,abi:1,productionAllowed:false})
globalThis.__veraHttp = () => ({destroy() {},on() {},async request() {
  network++
  return {responseCode:200,result:JSON.stringify({answers:{part:{choice:'cloud'}}})}
}})
settings.setSelectorKey('')
settings.setJevProxy('1') // Even a configured proxy cannot steal local requests.
const body = JSON.stringify({state:'A checklist',questions:{part:{type:'choice',instructions:'Choose',criteria:{a:'checklist',b:'timer'}}}})
;(async () => {
  assert.equal(settings.hasSelector(), false, 'not ready yet, despite proxy')
  await adapter.prepare()
  assert.equal(settings.hasSelector(), true)
  assert.equal(JSON.parse(await askJev(body,'' )).answers.part.choice,'a')
  assert.equal(network,0)
  const composition = new C.Composition()
  composition.blocks.push(new C.Block('checklist',new Map(),new Map()))
  composition.blocks.push(new C.Block('note',new Map(),new Map()))
  const edit = await C.selectEdit('Remove the note',composition,'')
  assert.equal(edit.op,C.OP_REMOVE)
  assert.equal(edit.target,'note')
  assert.equal(seen.length,2)
  assert.ok(seen[1].request.questions['edit.op'])
  assert.equal(network,0)

  fail=true
  const uncertain = JSON.parse(await askSelector(body,'even-with-cloud-key'))
  assert.deepEqual(uncertain.answers,{})
  assert.equal(uncertain.local.status,'uncertain')
  const declined = await C.selectEdit('Remove the note',composition,'')
  assert.equal(declined.op,C.OP_NONE)
  assert.equal(network,0,'failure must not use proxy or TypeSafe')
  fail=false

  const before = queries, controller = new OperationController()
  controller.cancel()
  await assert.rejects(askSelector(body,'',controller),{name:'OperationCancelledError'})
  assert.equal(queries,before)
  let resolve
  release={promise:new Promise(r=>{resolve=r})}
  const pendingController=new OperationController()
  const pending=askSelector(body,'',pendingController)
  await new Promise(r=>setImmediate(r))
  pendingController.cancel();resolve()
  await assert.rejects(pending,{name:'OperationCancelledError'})
  release=null

  settings.setLocalSelector(false)
  settings.setJevProxy('')
  assert.equal(await askSelector(body,''),'')
  assert.equal(JSON.parse(await askSelector(body,'cloud-key')).answers.part.choice,'cloud')
  assert.equal(network,1,'TypeSafe default preserved')
  adapter.close()
  // Independent failed-load instance: no inference or fallback on unavailable models.
  const {LocalJev} = loadVera('LocalJev')
  const unavailable = new LocalJev()
  let calledUnavailable = false
  globalThis.__veraLocalJev = {status:async()=>JSON.stringify({ready:false,reason:'archive_not_linked'}),
    experimentalDecisions:async()=>{calledUnavailable=true;throw Error('must not run')}}
  await unavailable.prepare()
  assert.equal(unavailable.isReady(),false)
  assert.equal(JSON.parse(await unavailable.ask(body)).local.reason,'archive_not_linked')
  assert.equal(calledUnavailable,false)
  delete globalThis.__veraLocalJev
  console.log('local-selector-check ok: generation, structural edit, readiness, uncertainty, cancellation, cloud defaults')
})().catch(error=>{adapter.close();console.error(error);process.exitCode=1})
