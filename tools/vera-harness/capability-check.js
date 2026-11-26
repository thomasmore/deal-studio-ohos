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
    assert.equal((result.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,
      file+': '+(result.diagnostics||[]).map(d=>{const at=d.file&&d.file.getLineAndCharacterOfPosition(d.start||0);return (at?`${at.line+1}:${at.character+1} `:'')+ts.flattenDiagnosticMessageText(d.messageText,'\n')}).join('\n'))
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
    assert(preview.includes('onStateSnapshot'));assert(preview.includes('private createSubscriber('))

    const {loadVera,loadSource,sourceRoot}=require('./source-loader'), C=loadVera('VeraCompiler'), V=loadVera('VeraInterpreter'), U=loadVera('VeraUi')
    const {StageTrace}=loadSource(path.join(sourceRoot,'runtime/trace/StageTrace.ets'))
    global.ObservedV2=c=>c;global.Trace=()=>{}
    const {createPreview,declaration}=require('./preview-fixture')
    assert(declaration(preview,'  private dispatch(').includes('this.dispatchFieldAction('))
    assert(declaration(preview,'  private async configure(').includes('await this.runtime.acquire('))
    assert(declaration(preview,'  private createSubscriber(').includes('this.onStateSnapshot(encoded)'))
    const values=new Map(), store={saveState(p,v,stamp,encoded){values.set(p+'/'+v,{stamp,encoded})},loadState(p,v,stamp){const value=values.get(p+'/'+v);return value&&value.stamp===stamp?value.encoded:''}}
    let tick, machines=0
    const actors=fixture({dependencies:{
      '../vera/ProjectStore':{store},
      '../vera/VeraInterpreter':{...V,VirtualMachine:class extends V.VirtualMachine {constructor(...args){super(...args);machines++}}},
      '../vera/VeraUi':U,
      '../vera/VeraGfx':loadVera('VeraGfx'),
      '../vera/VeraStateCarry':loadVera('VeraStateCarry'),
      '../vera/VeraConsentStore':{consent:{has:()=>false,remember(){}}},
      '../vera/VeraIntents':{runRawIntent:()=>{throw Error('Unexpected intent')}},
      '../vera/VeraSdkBackend':{runSdkAdapter:()=>{throw Error('Unexpected SDK call')}},
      './trace/StageTrace':{StageTrace}
    }})
    const {InProcessHost,HostOperationFailure}=actors.load('../runtime/InProcessHost')
    const {HostEffectsBridge}=actors.load('../runtime/HostEffectsBridge')
    const runtime=new InProcessHost(), errors=[]
    const {probe:controller}=createPreview({runtime,HostOperationFailure,HostEffectsBridge,mocks:{
      StageTrace,armReveal:()=>{},scheduleCardRefresh:()=>{},
      setInterval:fn=>{tick=fn;return 1},clearInterval:()=>{},
      console:{info(){},warn(){},error(...args){errors.push(args.join(' '))}}
    }})
    const snapshots=[], trees=[], render=controller.renderView.bind(controller)
    controller.renderView=(tree,...args)=>{render(tree,...args);trees.push([tree])}
    Object.assign(controller,{vbc2:C.compileVeraSource(fs.readFileSync(path.join(__dirname,'examples/visual-counter.vera'),'utf8')).vbc2,
      persistKey:'chat-fixture/1',onStateSnapshot:encoded=>snapshots.push(JSON.parse(encoded))})
    const snapshot=()=>runtime.requestSnapshot(controller.handle)
    const count=encoded=>V.decodeRuntimeValue(JSON.parse(encoded)).fields.get('count').value
    async function load(){controller.load();await controller.operations;assert.equal(controller.error,'');assert(controller.handle!==null)}
    try {
      await load();assert.equal(count(JSON.stringify(snapshots.at(-1))),7)
      controller.dispatch('change',{kind:'NUMBER',num:1,str:'',bool:false,phase:'',id:0,x:0,y:0})
      await pause();assert.equal(count(JSON.stringify(snapshots.at(-1))),8)
       const firstHandle=controller.handle, firstMachines=machines, treesBeforeReload=trees.length
       await load();assert.strictEqual(controller.handle,firstHandle);assert.equal(count(await snapshot()),8)
       assert.equal(machines,firstMachines);assert.equal(trees.length,treesBeforeReload+1)
      controller.aboutToDisappear();await controller.operations
      assert.deepEqual(errors,[]);assert.equal(controller.flushFailure,null)
      Object.assign(controller,{disposed:false,acquireGeneration:controller.acquireGeneration+1,activeProgram:'',persistKey:'',seedState:JSON.stringify(snapshots.at(-1))})
      await load();assert.equal(count(await snapshot()),8)
      assert(trees.every(tree=>tree[0].kind==='apptheme'));assert.equal(values.size,1)
      function walk(nodes){return nodes.flatMap(n=>[n,...walk(n.children||[])])}
       assert.deepEqual(trees.map(tree=>walk(tree).find(n=>n.kind==='numbertext').numberValue),[7,8,8,8])
      controller.persistKey='chat-fixture/1';controller.seedState='';await load()
      const extensionVm=new V.VirtualMachine(V.deserializeVbc2(controller.vbc2),new U.UiHostEnvironment())
      const external=extensionVm.execute('change',[V.decodeRuntimeValue(JSON.parse(await snapshot())),new V.VeraNumberValue(5)])
      store.saveState('chat-fixture','1',controller.stamp(),JSON.stringify(V.encodeRuntimeValue(external)))
      const handleBefore=controller.handle, machinesBefore=machines
      controller.onResume();await pause()
      assert.strictEqual(controller.handle,handleBefore);assert.equal(machines,machinesBefore)
      assert.equal(count(values.get('chat-fixture/1').encoded),13);assert.equal(count(await snapshot()),13)
      controller.startTimer('fixture',{interval:100,action:'change'});controller.appForeground=false
      const stateBefore=await snapshot(), snapshotsBefore=snapshots.length, lastFire=controller.timerLastFire.get('fixture')
      tick();await pause();assert.equal(await snapshot(),stateBefore);assert.equal(snapshots.length,snapshotsBefore);assert.equal(controller.timerLastFire.get('fixture'),lastFire)
      let stopped=0;const stopSurfaceLoop=controller.stopSurfaceLoop.bind(controller)
      controller.stopSurfaceLoop=(...args)=>{stopped++;return stopSurfaceLoop(...args)}
      const released=controller.handle
      controller.aboutToDisappear();await controller.operations
      assert.deepEqual(errors,[]);assert.equal(controller.flushFailure,null)
      assert.equal(stopped,1);assert.equal(controller.timers.size,0);assert.equal(controller.timerConfigs.size,0);assert.equal(controller.timerLastFire.size,0)
      assert.equal(controller.handle,null);await assert.rejects(runtime.requestSnapshot(released),/INVALID_HANDLE/)
    } finally {await runtime.dispose()}

   return {sharedInitialization:true,initialAndActionSnapshots:true,resumeExistingRunner:true,backgroundTicksSkipped:true,disappearTimersStopped:true,snapshots,decodedTrees:trees,savedKeys:[...values.keys()]}
 })
 const hashes={};for(const file of ['entry/src/main/ets/vera/VeraCapabilities.ets','entry/src/main/ets/vera/VeraSdkIndex.ets','entry/src/main/ets/vera/VeraIntentRegistry.ets','entry/src/main/ets/vera/VeraIntentIndex.ets','entry/src/main/ets/pages/GeneratePage.ets','entry/src/main/ets/components/VeraPreview.ets','entry/src/main/ets/runtime/AppActor.ets','entry/src/main/ets/runtime/InProcessHost.ets','entry/src/main/ets/runtime/HostEffectsBridge.ets','entry/src/main/ets/runtime/EffectController.ets','tools/vera-harness/capability-check.js'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')
 const report={source_sha256:hashes,expected:'All capability and renderer lifecycle workflows PASS; current values are emitted without migrating state.',observed:checks.every(c=>c.status==='PASS')?'PASS':'FAIL',revision:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),command:process.argv.join(' '),inputs:'mocked native registry, SDK rawfile, download, embedding boundaries; 10000ms timeout accelerated to 20ms',checks}
 fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:checks.filter(c=>c.status==='PASS').length,failed:checks.filter(c=>c.status==='FAIL').length,output}));if(checks.some(c=>c.status==='FAIL'))process.exitCode=1
})()
