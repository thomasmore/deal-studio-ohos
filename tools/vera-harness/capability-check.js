#!/usr/bin/env node
// Define failures before production edits: empty concurrent reads, missing chat
// initialization, blocked downloads, failed native indexes, and stale snapshots.
'use strict'
const fs = require('node:fs'), path = require('node:path'), cp = require('node:child_process'), crypto = require('node:crypto')
const assert = require('node:assert/strict')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const root = path.resolve(__dirname, '../..'), base = path.join(root, 'entry/src/main/ets/vera')
const output = path.resolve(process.argv[2] || '/tmp/vera-capability-verification.json')
const checks = []
const pause = () => new Promise(resolve => setImmediate(resolve))
function fixture(options = {}) {
  const events = [], cache = new Map(); let model = false, exists = !options.missingModel
  let release; const gate = new Promise(resolve => { release = resolve })
  const sdk = [{kit:'Kit',module:'camera',name:'setTorchMode',params:'enabled: boolean',returnType:'void',description:'Control flashlight',since:'1',file:'camera',permission:'',deprecated:false,systemapi:false}]
  const stubs = {
    ...options.dependencies,
    '@kit.PerformanceAnalysisKit': {hilog:{info(){},warn(){}}}, '@kit.CoreFileKit':{fileIo:{mkdirSync(){}}},
    '@kit.AbilityKit': {common:{},insightIntentDriver:{GetInsightIntentFlag:{GET_FULL_INSIGHT_INTENT:1}, async getAllInsightIntentInfo(){events.push('registry');if(options.delayed)await gate;if(options.indexFails)throw Error('registry unavailable');events.push('registry-done');return []}}},
    '@kit.BasicServicesKit': {request:{async downloadFile(){events.push('download');return {on(name,fn){if(name==='fail' && options.downloadFails)setImmediate(()=>fn(1));if(name==='complete' && !options.downloadFails)setImmediate(()=>{exists=true;fn()})}}}}},
    '@kit.LocalizationKit': {resourceManager:{}},
    './LlamaEngine': {async loadRawfileText(mgr,name){events.push('read:'+name);if(options.delayed)await gate;if(options.indexFails)throw Error('index unavailable');return name==='sdk-index.json'?JSON.stringify(sdk):'{}'}},
    './VeraIntentCatalog':{INTENT_CATALOG:[]},
    './VeraEmbeddings':{embedModelExists:()=>exists,embedModelPath:()=>'/test/model',EMBED_MODEL_URL:'https://example.test/model',async loadEmbeddingModel(){events.push('model');model=!options.modelFails;return model}},
    './VeraSdkEmbeddingCache':{async ensureSdkEmbeddings(){assert(model);assert(load('VeraSdkIndex').sdkIndexSize()>0 || options.indexFails);events.push('sdk-vectors')},sdkEmbeddingsReady:()=>events.includes('sdk-vectors')},
    './VeraIntentEmbeddingCache':{async ensureIntentEmbeddings(){assert(model);assert(events.includes('registry-done') || options.indexFails);events.push('intent-vectors')},intentEmbeddingsReady:()=>events.includes('intent-vectors')}
  }
  function load(name){
    if(cache.has(name))return cache.get(name).exports
    const file=path.join(base,name+'.ets'), source=fs.readFileSync(file,'utf8'), mod={exports:{}};cache.set(name,mod)
    const result=ts.transpileModule(source,{fileName:name+'.ts',compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,esModuleInterop:true},reportDiagnostics:true})
    assert.equal((result.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0)
    const req=id=>{if(Object.hasOwn(stubs,id))return stubs[id];if(id.startsWith('.'))return load(path.relative(base,path.resolve(path.dirname(file),id)));throw Error('Unexpected dependency '+id)}
    const timer=(fn,ms)=>setTimeout(fn,ms===10000?20:ms)
    const supports = new Set(['SystemCapability.Request.FileTransferAgent','SystemCapability.MiscServices.Download'])
    if(options.unsupported)supports.delete(options.unsupported)
    const canIUse = capability => supports.has(capability)
    new Function('require','module','exports','setTimeout','clearTimeout','canIUse',result.outputText)(req,mod,mod.exports,timer,clearTimeout,canIUse)
    return mod.exports
  }
  return {load,events,release,context:{filesDir:'/test',resourceManager:{}}}
}
async function test(name,fn){try{const observed=await fn();checks.push({name,status:'PASS',observed})}catch(e){checks.push({name,status:'FAIL',observed:String(e.stack||e)})}}
(async()=>{
 await test('Fresh chat and Generate share delayed initialization',async()=>{
   const f=fixture({delayed:true}), service=f.load('VeraCapabilities');let finished=false
   const first=service.ensureCapabilities(f.context).then(()=>{finished=true}), second=service.ensureCapabilities(f.context)
   await pause();assert.equal(finished,false);f.release();await Promise.all([first,second]);await pause()
   assert.equal(f.events.filter(x=>x==='read:sdk-index.json').length,1);assert.equal(f.events.filter(x=>x==='registry').length,1)
   assert(f.events.includes('intent-vectors'));assert(f.events.includes('sdk-vectors'));return f.events
 })
 await test('Concurrent direct index consumers await the same read',async()=>{
   const f=fixture({delayed:true}), sdk=f.load('VeraSdkIndex'), registry=f.load('VeraIntentRegistry');let done=0
   const reads=[sdk.loadSdkIndex({}),sdk.loadSdkIndex({}),registry.loadRegistry(),registry.loadRegistry()].map(p=>p.then(v=>{done++;return v}))
   await pause();assert.equal(done,0);f.release();const values=await Promise.all(reads);assert.deepEqual(values,[1,1,0,0]);return {values,events:f.events}
 })
 for(const options of [{missingModel:true,downloadFails:true},{modelFails:true},{indexFails:true}])await test('Unavailable capability boundary '+JSON.stringify(options),async()=>{
   const f=fixture(options);await f.load('VeraCapabilities').ensureCapabilities(f.context);await pause();await pause()
   if(options.downloadFails||options.modelFails)assert(!f.events.includes('intent-vectors'));return {fallbackAvailable:true,events:f.events}
 })
  for(const unsupported of ['SystemCapability.Request.FileTransferAgent','SystemCapability.MiscServices.Download'])await test('Unsupported download capability '+unsupported,async()=>{
    const f=fixture({missingModel:true,unsupported}), service=f.load('VeraCapabilities')
    await service.ensureCapabilities(f.context);await service.prepareCapabilityEmbeddings(f.context)
    assert(!f.events.includes('download'));assert(!f.events.includes('model'));assert(!f.events.includes('sdk-vectors'));assert(!f.events.includes('intent-vectors'))
    assert(f.load('VeraSdkIndex').sdkIndexSize()>0);return {fallbackAvailable:true,events:f.events}
  })
  await test('Index timeout is bounded; late indexes still prepare embeddings',async()=>{
   const f=fixture({delayed:true});await f.load('VeraCapabilities').ensureCapabilities(f.context)
   assert(!f.events.includes('intent-vectors'));f.release();await pause();await pause();assert(f.events.includes('intent-vectors'));return f.events
 })
 await test('Direct discovery and both screens share one initialization and one background download',async()=>{
   const f=fixture({missingModel:true}), discovery=f.load('VeraDiscovery'), service=f.load('VeraCapabilities')
   await Promise.all([discovery.loadDiscovery(f.context.filesDir,f.context.resourceManager),service.ensureCapabilities(f.context),service.ensureCapabilities(f.context)])
   await service.prepareCapabilityEmbeddings(f.context)
   for(const event of ['read:sdk-index.json','registry','download','model','sdk-vectors','intent-vectors'])assert.equal(f.events.filter(x=>x===event).length,1,event)
   return f.events
 })
 await test('Generate and renderer use the shared contracts',async()=>{
   const page=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/GeneratePage.ets'),'utf8')
   assert(page.includes('ensureCapabilities('));assert(page.includes('prepareCapabilityEmbeddings('))
   const preview=fs.readFileSync(path.join(root,'entry/src/main/ets/components/VeraPreview.ets'),'utf8')
   assert(preview.includes('onStateSnapshot'));assert(preview.includes('private notifyStateSnapshot('))
   const actorSource=fs.readFileSync(path.join(root,'entry/src/main/ets/runtime/AppActor.ets'),'utf8')
   const {loadVera,loadSource,sourceRoot}=require('./source-loader'), C=loadVera('VeraCompiler'), V=loadVera('VeraInterpreter'), U=loadVera('VeraUi')
   const {StageTrace}=loadSource(path.join(sourceRoot,'runtime/trace/StageTrace.ets'))
   function method(name,source=preview){
     const start=source.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(', 'm'));assert(start>=0,name)
     const scan=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,source.slice(start));let depth=0,opened=false
     while(scan.scan()!==ts.SyntaxKind.EndOfFileToken){if(scan.getToken()===ts.SyntaxKind.OpenBraceToken){depth++;opened=true}if(scan.getToken()===ts.SyntaxKind.CloseBraceToken && --depth===0 && opened)return source.slice(start,start+scan.getTextPos())}
     throw Error('Unclosed lifecycle method '+name)
   }
   assert(method('dispatch').includes('this.actor!.dispatch(action, payload, persist, kind)'))
   assert(method('load').includes('this.actor!.initialize(program, this.actorOptions())'))
   assert(method('createActor').includes('snapshot: (encoded: string): void => { this.onStateSnapshot(encoded) }'))
   assert(method('dispatch',actorSource).includes('this.notifyStateSnapshot()'))
   assert(method('initialize',actorSource).includes('this.notifyStateSnapshot()'))
   const methods=['load','dispatch','actorOptions','createActor','invalidateEffects','stamp','persistState','notifyStateSnapshot','onResume','startTimer','stopTimer','stopAllTimers','aboutToDisappear'].map(name=>method(name)).join('\n')
   const code=ts.transpileModule('class Controller { '+methods+' } module.exports=Controller;', {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText
   const values=new Map(), store={saveState(p,v,stamp,encoded){values.set(p+'/'+v,{stamp,encoded})},loadState(p,v,stamp){const value=values.get(p+'/'+v);return value&&value.stamp===stamp?value.encoded:''}}
   let tick, machines=0
   const actors=fixture({dependencies:{
     '../vera/ProjectStore':{store},
     '../vera/VeraInterpreter':{...V,VirtualMachine:class extends V.VirtualMachine {constructor(...args){super(...args);machines++}}},
     '../vera/VeraUi':U,
     '../vera/VeraGfx':loadVera('VeraGfx'),
     '../vera/VeraStateCarry':loadVera('VeraStateCarry'),
     './trace/StageTrace':{StageTrace}
   }})
   const {AppActor}=actors.load('../runtime/AppActor')
   const globals={AppActor,StageTrace,setInterval:fn=>{tick=fn;return 1},clearInterval:()=>{},SLOW_TICK_MS:500,VeraNumberValue:V.VeraNumberValue,armReveal:()=>{},veraStateStamp:loadVera('VeraStateStamp').veraStateStamp,scheduleCardRefresh:()=>{}}
   const mod={exports:{}};new Function('module',...Object.keys(globals),code)(mod,...Object.values(globals))
   const controller=new mod.exports(), snapshots=[], trees=[]
   controller.vbc2=C.compileVeraSource(fs.readFileSync(path.join(__dirname,'examples/visual-counter.vera'),'utf8')).vbc2
   controller.persistKey='chat-fixture/1';controller.seedState='';controller.revision=0;controller.acceptEffects=effects=>assert.deepEqual(effects,[])
   controller.actor=null;controller.traceOwner={};controller.previewOnly=false;controller.disposed=false;controller.effectGeneration=0;controller.liveGeneration=0;controller.liveRoot=null;controller.programId=0
   controller.cancelFields=()=>{};controller.flushFields=()=>{};controller.controller=null;controller.darkListener=null;controller.liveSurfaces=[];controller.stopPartsTimer=()=>{}
   controller.timers=new Map();controller.motionTriggers=new Map();controller.poseAnims=new Map();controller.sceneFrames=new Map();controller.stopSurfaceLoop=()=>{}
   controller.onStateSnapshot=encoded=>snapshots.push(JSON.parse(encoded))
   controller.renderView=()=>{const tree=controller.actor.view();trees.push(tree===null?[]:[tree])}
   controller.load();assert.equal(controller.error,'');assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,7)
   controller.dispatch('change',new V.VeraNumberValue(1));assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)
   controller.load();assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)

   const seed=JSON.stringify(snapshots.at(-1));controller.persistKey='';controller.seedState=seed;controller.load()
   assert.equal(controller.error,'');assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)
   controller.seedState='';controller.persistKey='chat-fixture/1'
   trees.pop()
   assert(trees.every(tree=>tree[0].kind==='apptheme'));assert.equal(values.size,1)
   function walk(nodes){return nodes.flatMap(n=>[n,...walk(n.children||[])])}
   assert.deepEqual(trees.map(tree=>walk(tree).find(n=>n.kind==='numbertext').numberValue),[7,8,8])
   controller.actor.promote(controller.actorOptions())
   const extensionVm=new V.VirtualMachine(V.deserializeVbc2(controller.vbc2),new U.UiHostEnvironment())
   const external=extensionVm.execute('change',[V.decodeRuntimeValue(JSON.parse(controller.actor.snapshot())),new V.VeraNumberValue(5)])
   store.saveState('chat-fixture','1',controller.stamp(),JSON.stringify(V.encodeRuntimeValue(external)))
   const actorBefore=controller.actor, machinesBefore=machines
   controller.onResume();assert.equal(controller.actor,actorBefore);assert.equal(machines,machinesBefore)
   assert.equal(V.decodeRuntimeValue(JSON.parse(values.get('chat-fixture/1').encoded)).fields.get('count').value,13)
   assert.equal(V.decodeRuntimeValue(JSON.parse(controller.actor.snapshot())).fields.get('count').value,13)
   controller.timerConfigs=new Map();controller.timerLastFire=new Map();controller.fieldEdits=new Map()
   controller.startTimer('fixture',{interval:100,action:'change'});controller.appForeground=false
   const stateBefore=controller.actor.snapshot(), snapshotsBefore=snapshots.length, lastFire=controller.timerLastFire.get('fixture')
   tick();assert.equal(controller.actor.snapshot(),stateBefore);assert.equal(snapshots.length,snapshotsBefore);assert.equal(controller.timerLastFire.get('fixture'),lastFire)
   let stopped=0;controller.stopSurfaceLoop=()=>stopped++
   const released=controller.actor
   controller.aboutToDisappear();assert.equal(stopped,1);assert.equal(controller.timers.size,0);assert.equal(controller.timerConfigs.size,0);assert.equal(controller.timerLastFire.size,0)
   assert.equal(controller.actor,null);assert.equal(released.ready(),false);assert.equal(released.snapshot(),'')
   return {sharedInitialization:true,initialAndActionSnapshots:true,resumeExistingRunner:true,backgroundTicksSkipped:true,disappearTimersStopped:true,snapshots,decodedTrees:trees,savedKeys:[...values.keys()]}
 })
 const hashes={};for(const file of ['entry/src/main/ets/vera/VeraCapabilities.ets','entry/src/main/ets/vera/VeraSdkIndex.ets','entry/src/main/ets/vera/VeraIntentRegistry.ets','entry/src/main/ets/vera/VeraIntentIndex.ets','entry/src/main/ets/pages/GeneratePage.ets','entry/src/main/ets/components/VeraPreview.ets','entry/src/main/ets/runtime/AppActor.ets','tools/vera-harness/capability-check.js'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')
 const report={source_sha256:hashes,expected:'All capability and renderer lifecycle workflows PASS; current values are emitted without migrating state.',observed:checks.every(c=>c.status==='PASS')?'PASS':'FAIL',revision:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),command:process.argv.join(' '),inputs:'mocked native registry, SDK rawfile, download, embedding boundaries; 10000ms timeout accelerated to 20ms',checks}
 fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:checks.filter(c=>c.status==='PASS').length,failed:checks.filter(c=>c.status==='FAIL').length,output}));if(checks.some(c=>c.status==='FAIL'))process.exitCode=1
})()
