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
    const req=id=>{if(Object.hasOwn(stubs,id))return stubs[id];if(id.startsWith('./'))return load(id.slice(2));throw Error('Unexpected dependency '+id)}
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
   const start=preview.indexOf('private dispatch('), end=preview.indexOf('\n  private ',start+1), dispatch=preview.slice(start,end)
   assert(dispatch.includes('this.notifyStateSnapshot()'));const load=preview.slice(preview.indexOf('private load()'),preview.indexOf('private reconcileTimers('));assert(load.includes('this.notifyStateSnapshot()'))
   // Execute the renderer lifecycle around an actual compiled widget and VM.
   const {loadVera}=require('./source-loader'), C=loadVera('VeraCompiler'), V=loadVera('VeraInterpreter'), U=loadVera('VeraUi')
   function method(name){
     const start=preview.search(new RegExp('private (?:async )?'+name+'\\('));assert(start>=0)
     const scan=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,preview.slice(start));let depth=0,opened=false
     while(scan.scan()!==ts.SyntaxKind.EndOfFileToken){if(scan.getToken()===ts.SyntaxKind.OpenBraceToken){depth++;opened=true}if(scan.getToken()===ts.SyntaxKind.CloseBraceToken && --depth===0 && opened)return preview.slice(start,start+scan.getTextPos())}
     throw Error('Unclosed renderer method '+name)
   }
   const methods=['load','dispatch','stateKeys','stamp','seeded','restoreState','persistState','notifyStateSnapshot'].map(method).join('\n')
   const code=ts.transpileModule('class Controller { '+methods+' } module.exports=Controller;', {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText
   const values=new Map(), store={saveState(p,v,stamp,encoded){values.set(p+'/'+v,{stamp,encoded})},loadState(p,v,stamp){const value=values.get(p+'/'+v);return value&&value.stamp===stamp?value.encoded:''}}
   const globals={store,armReveal:()=>{},carryState:loadVera('VeraStateCarry').carryState,UiHostEnvironment:U.UiHostEnvironment,deserializeVbc2:V.deserializeVbc2,VirtualMachine:V.VirtualMachine,encodeRuntimeValue:V.encodeRuntimeValue,decodeRuntimeValue:V.decodeRuntimeValue}
   const mod={exports:{}};new Function('module',...Object.keys(globals),code)(mod,...Object.values(globals))
   const controller=new mod.exports(), snapshots=[], trees=[]
   controller.vbc2=C.compileVeraSource(fs.readFileSync(path.join(__dirname,'examples/visual-counter.vera'),'utf8')).vbc2
   controller.persistKey='chat-fixture/1';controller.seedState='';controller.revision=0;controller.stopAllTimers=()=>{};controller.drainEffects=()=>{}
   controller.onStateSnapshot=encoded=>snapshots.push(JSON.parse(encoded))
   controller.renderView=()=>{controller.host.effectsAllowed=false;trees.push(U.decodeVeraUi(controller.vm.execute('view',[controller.currentState])))}
   controller.load();assert.equal(controller.error,'');assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,7)
   controller.dispatch('change',new V.VeraNumberValue(1));assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)
   controller.load();assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)
   // A refined program (no saved state of its own) starts from the state it replaces.
   const seed=JSON.stringify(snapshots.at(-1));controller.persistKey='';controller.seedState=seed;controller.load()
   assert.equal(controller.error,'');assert.equal(V.decodeRuntimeValue(snapshots.at(-1)).fields.get('count').value,8)
   controller.seedState='';controller.persistKey='chat-fixture/1'
   trees.pop()
   assert(trees.every(tree=>tree[0].kind==='apptheme'));assert.equal(values.size,1)
   function walk(nodes){return nodes.flatMap(n=>[n,...walk(n.children||[])])}
   assert.deepEqual(trees.map(tree=>walk(tree).find(n=>n.kind==='numbertext').numberValue),[7,8,8])
   return {sharedInitialization:true,initialAndActionSnapshots:true,snapshots,decodedTrees:trees,savedKeys:[...values.keys()]}
 })
 const hashes={};for(const file of ['entry/src/main/ets/vera/VeraCapabilities.ets','entry/src/main/ets/vera/VeraSdkIndex.ets','entry/src/main/ets/vera/VeraIntentRegistry.ets','entry/src/main/ets/vera/VeraIntentIndex.ets','entry/src/main/ets/pages/GeneratePage.ets','entry/src/main/ets/components/VeraPreview.ets','tools/vera-harness/capability-check.js'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')
 const report={source_sha256:hashes,expected:'All capability and renderer lifecycle workflows PASS; current values are emitted without migrating state.',observed:checks.every(c=>c.status==='PASS')?'PASS':'FAIL',revision:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),command:process.argv.join(' '),inputs:'mocked native registry, SDK rawfile, download, embedding boundaries; 10000ms timeout accelerated to 20ms',checks}
 fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:checks.filter(c=>c.status==='PASS').length,failed:checks.filter(c=>c.status==='FAIL').length,output}));if(checks.some(c=>c.status==='FAIL'))process.exitCode=1
})()
