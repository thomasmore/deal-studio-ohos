#!/usr/bin/env node
// Failure cases defined before production changes: lost state/handlers, absent or
// malformed components, stale source copies, unreadable text, wrong typography,
// widget oversizing, unmeasured/narrow columns, order loss, and lost live widths.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const cp = require('node:child_process')
async function main() {
const args=process.argv.slice(2), runtimeFlags=['--capture-runtime-traces','--compare-runtime-traces']
const runtimeMode=args.some(arg=>runtimeFlags.includes(arg))
let runtimeOptions
if(runtimeMode) {
 assert(args.length===3&&runtimeFlags.includes(args[0])&&args[1]==='--output'&&args[2]&&!args[2].startsWith('--'),
  'usage: visual-check.js [--capture-runtime-traces|--compare-runtime-traces --output FILE]; cannot combine with --capture-baseline or positional report output')
 runtimeOptions={mode:args[0]===runtimeFlags[0]?'capture':'compare',output:path.resolve(args[2])}
} else assert(!args.includes('--output'), '--output requires --capture-runtime-traces or --compare-runtime-traces')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
const fixture={exports:{}}, worldFile=path.join(sourceRoot,'components/VeraWorld3D.ets')
const worldMock={WorldBox:class { constructor(){throw Error('Unexpected World3D in non-world fixture')} },playerOf(){throw Error('Unexpected World3D player in non-world fixture')}}
new Function('require','module','exports',fs.readFileSync(require.resolve('./preview-fixture'),'utf8'))(name=>name==='./source-loader'?{
 sourceRoot,loadSource(file){return path.resolve(file)===worldFile?worldMock:loadSource(file)}
}:require(name),fixture,fixture.exports)
const {createPreview,effectRequest,seedEffects:injectEffects}=fixture.exports
const {StageTrace} = loadSource(path.join(sourceRoot,'runtime/trace/StageTrace.ets'))
const C = loadVera('VeraCompiler'), V = loadVera('VeraInterpreter'), U = loadVera('VeraUi')
const output = path.resolve(runtimeMode?'/tmp/opencode/vera-visual-verification.json':process.argv[2] || '/tmp/opencode/vera-visual-verification.json')
const baseline = !runtimeMode&&process.argv.includes('--capture-baseline')
const runtimeScenarios=[], runtimeNames=new Map([
 ['native fields: rapid input waits 400ms after latest, commits once without keystroke traces','field/debounce-400ms'],
 ['native fields: actual submit completes composition with "你好" and no final onChange','field/ime-submit-final'],
 ['native fields: actual blur completes composition with "你好" and no final onChange','field/ime-blur-final'],
 ['native slider: extracted callback flushes both latest drafts before VM and persists only drag end','slider/pending-drafts-begin-move-end'],
 ['native timer: slow callback flushes pending user fields','ticker/slow-pending-flush'],
 ['native timer: slow callback skips composing user fields','ticker/slow-composition-gate'],
 ['runtime traces: fast ticker preserves pending debounce','ticker/fast-pending-edit'],
 ['runtime traces: pointer down/move/up after pending edit','surface/pending-edit-down-move-up'],
 ['runtime traces: stale field dependency cancels queued slider','field/stale-dependency-cancellation']
])
const cases = [['counter','change',1,'count',8], ['countdown','start',0,'running',true], ['expense','setBudget',140,'budget',140], ['reading','save',0,'saved',true], ['habit','complete',0,'days',4]]
const results = [], trees = {}, contrasts = [], runtimes = new Set()
let fieldBytecode, syncBytecode
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
function declaration(source, prefix) {
 const start=source.indexOf(prefix); assert(start>=0,prefix)
 const scanner=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,source.slice(start))
 let depth=0
 while(scanner.scan()!==ts.SyntaxKind.EndOfFileToken) {
  if(scanner.getToken()===ts.SyntaxKind.OpenBraceToken)depth++
  if(scanner.getToken()===ts.SyntaxKind.CloseBraceToken&&--depth===0)return source.slice(start,start+scanner.getTextPos())
 }
 throw Error(prefix)
}
function hostModule(mocks={}, observe=()=>{}) {
 const cache=new Map()
 class Machine extends V.VirtualMachine {
  execute(action,args=[]) { const value=super.execute(action,args);observe(action,args,value);return value }
 }
 const dependencies={
  '../vera/ProjectStore':{store:mocks.store||{loadState:()=>'',saveState(){}}},
  '../vera/VeraInterpreter':{...V,VirtualMachine:Machine},'../vera/VeraUi':U,
  '../vera/VeraGfx':loadVera('VeraGfx'),'../vera/VeraStateCarry':loadVera('VeraStateCarry'),
  '../vera/VeraConsentStore':{consent:mocks.consent||{has:()=>false,remember(){}}},
  '../vera/VeraIntents':{runRawIntent:mocks.runRawIntent||(()=>{throw Error('Unexpected intent')})},
  '../vera/VeraSdkBackend':{runSdkAdapter:mocks.runSdkAdapter||(()=>{throw Error('Unexpected SDK call')})},
  './trace/StageTrace':{StageTrace}
 }
 function load(file) {
  file=path.resolve(file)
  if(cache.has(file))return cache.get(file).exports
  const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:file.replace(/\.ets$/,'.ts'),compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
  assert.deepEqual((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error),[],file)
  const mod={exports:{}};cache.set(file,mod)
  new Function('require','module','exports','Date','console',compiled.outputText)(name=>{
   if(Object.hasOwn(dependencies,name))return dependencies[name]
   assert(name.startsWith('.'),'Unexpected host dependency: '+name)
   return load(path.resolve(path.dirname(file),name+'.ets'))
  },mod,mod.exports,mocks.Date||Date,mocks.console||{info(){},warn(){},error(){}})
  return mod.exports
 }
 const {InProcessHost,HostOperationFailure}=load(path.join(sourceRoot,'runtime/InProcessHost.ets'))
 const {HostEffectsBridge}=load(path.join(sourceRoot,'runtime/HostEffectsBridge.ets'))
  const runtime=new InProcessHost()
  runtimes.add(runtime)

 return {runtime,InProcessHost:{get:()=>runtime},HostOperationFailure,HostEffectsBridge}
}
function scalarPayload(value) {
 return {kind:typeof value==='number'?'NUMBER':typeof value==='boolean'?'BOOLEAN':'STRING',num:typeof value==='number'?value:0,str:typeof value==='string'?value:'',bool:typeof value==='boolean'?value:false,phase:'',id:0,x:0,y:0}
}
function payloadValue(payload) {
 assert(['NUMBER','STRING','BOOLEAN'].includes(payload.kind),'scalar input payload')
 return payload.kind==='NUMBER'?payload.num:payload.kind==='STRING'?payload.str:payload.bool
}
const pause=()=>new Promise(resolve=>setImmediate(resolve))
async function settlePreview(probe) {
 let operations
 do { operations=probe.operations;await operations;await pause() } while(operations!==probe.operations)
}
function platformModule(name, mocks, suffix='') {
 const source=fs.readFileSync(path.join(sourceRoot,'vera',name+'.ets'),'utf8')+suffix
 const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,esModuleInterop:true},reportDiagnostics:true})
 assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,name+' syntax')
 const mod={exports:{}}
 new Function('require','module','exports',compiled.outputText)(name=>{
  if(Object.hasOwn(mocks,name))return mocks[name]
  if(name.startsWith('.'))return loadVera(name.slice(2))
  throw Error('Unexpected dependency: '+name)
 },mod,mod.exports)
 return mod.exports
}
async function test(name, action) {
 if(runtimeMode&&!runtimeNames.has(name))return
 const records=[]
  try {
   if(runtimeMode)StageTrace.configure(true,record=>records.push(record))
   let timeout
   try { await Promise.race([action(),new Promise((_,reject)=>{timeout=setTimeout(()=>reject(Error('Fixture did not settle: '+name)),2000)})]) }
   finally { clearTimeout(timeout) }

  if(runtimeMode) {
   assert(records.length>0,'empty runtime trace: '+name)
   runtimeScenarios.push({name:runtimeNames.get(name),segments:[records]})
  }
  results.push({name,result:'PASS'})
 } catch(e) { results.push({name,result:'FAIL',error:String(e.stack||e)}) }
  finally { if(runtimeMode)StageTrace.configure(false);for(const runtime of runtimes)await runtime.dispose();runtimes.clear() }
}
async function testAsync(name, action) { if(runtimeMode)return;await test(name,action) }
function finishRuntimeTraces() {
 const failures=results.filter(result=>result.result==='FAIL')
 assert.equal(failures.length,0,failures.map(result=>result.name+': '+result.error).join('\n'))
 assert.equal(runtimeScenarios.length,runtimeNames.size,'missing runtime trace scenarios')
 const traces=require('./stage-trace-baseline'), artifact=traces.artifact(runtimeScenarios)
 artifact.environment='MOCKED_PLATFORM_REAL_VM'
 for(const scenario of artifact.scenarios)scenario.environment=artifact.environment
 artifact.limitations=[
  'Current ETS compiler, VM, UI decoder, live-tree reconciliation, field flushing and StageTrace run on the host; platform APIs and persistence storage are mocked.',
  'Extracted VeraPreview methods and text/slider callbacks receive synthetic events; no native ArkUI, keyboard/IME integration, geometry, painting, SDK, filesystem persistence, network, model or device validation.',
  'Timeouts use an injected clock with the real 400-ms debounce; interval callbacks are manually invoked at fixed steps, not device scheduling or concurrency coverage.',
  'Composition is synthetic preview text completed through extracted submit/blur callbacks; this is not native IME validation.',
  'Trace timestamps are zeroed by the shared normalizer; elapsed-time and debounce deadlines are asserted by probes, not performance measurements.',
  'Only named deterministic field, slider, ticker and pointer scenarios are captured; surface frame/draw loops, full lifecycle, effects, navigation and exhaustive dependency branches are not included.',
  'Current ETS transpilation is not ArkTS typechecking, SDK validation or native layout verification.',
  'Observed behavior is a baseline, not a correctness oracle; production drift is not repaired by this harness.'
 ]
 if(runtimeOptions.mode==='capture')traces.captureFile(runtimeOptions.output,artifact)
 else traces.compareFile(runtimeOptions.output,artifact)
 const count=artifact.scenarios.reduce((sum,scenario)=>sum+scenario.segments.reduce((sum,segment)=>sum+segment.length,0),0)
 console.log(`${runtimeOptions.mode} runtime traces: ${artifact.scenarios.length} scenarios, ${count} records; MOCKED_PLATFORM_REAL_VM; ${runtimeOptions.output}`)
}
function vm(bytecode) { return new V.VirtualMachine(V.deserializeVbc2(bytecode), new U.UiHostEnvironment()) }
function walk(node) { return [node, ...(node.children || []).flatMap(walk)] }
for (const [name, handler, value, field, expected] of cases) {
 await test(name + ': compile/init/render/handler/save/reload', async () => {
  const file = baseline ? path.join(path.dirname(output), `baseline-${name}.vera`) : path.join(__dirname, 'examples', `visual-${name}.vera`)
  const source = fs.readFileSync(file,'utf8'), bytecode = C.compileVeraSource(source).vbc2
  const machine = vm(bytecode), initial = machine.execute('init')
  const tree = U.decodeVeraUi(machine.execute('view',[initial]))[0]
  assert.equal(tree.kind,'apptheme'); assert(walk(tree).some(n => n.kind === (baseline ? 'section' : 'hero')))
  const changed = machine.execute(handler,[initial,new V.VeraNumberValue(value)])
  assert.equal(changed.fields.get(field).value, expected)
  const saved = V.encodeRuntimeValue(changed), restored = V.decodeRuntimeValue(JSON.parse(JSON.stringify(saved)))
  assert.deepEqual(V.encodeRuntimeValue(restored),saved)
  const after = U.decodeVeraUi(vm(bytecode).execute('view',[restored]))[0]
  trees[name] = {initial:tree, after}
  if (baseline) fs.writeFileSync(path.join(__dirname,'compatibility',`${name}.json`),JSON.stringify({source,bytecode,saved,handler,value,field,expected},null,2)+'\n')
 })
 if (!baseline) await test(name + ': pre-change bytecode and saved state', async () => {
  const old = JSON.parse(fs.readFileSync(path.join(__dirname,'compatibility',`${name}.json`),'utf8'))
  const machine=vm(old.bytecode), state=V.decodeRuntimeValue(old.saved)
  assert.equal(state.fields.get(old.field).value,old.expected)
  const before = U.decodeVeraUi(machine.execute('view',[state]))[0]
  assert.equal(before.kind,'apptheme')
  const after=machine.execute(old.handler,[state,new V.VeraNumberValue(old.value)])
  const expectedNext=name==='counter'?9:name==='habit'?5:old.expected
  assert.equal(after.fields.get(old.field).value,expectedNext)
  trees[name] = {...trees[name], legacy:before}
 })
}
if (!baseline) {
 await test('countdown: elapsed time and terminal boundary', async () => {
  const bytecode=C.compileVeraSource(fs.readFileSync(path.join(__dirname,'examples/visual-countdown.vera'),'utf8')).vbc2
  const m=vm(bytecode); const started=m.execute('start',[m.execute('init'),new V.VeraNumberValue(0)])
  const tick=m.execute('tick',[started,new V.VeraNumberValue(1000)])
  assert.equal(tick.fields.get('remaining').value,89000)
  const done=m.execute('tick',[tick,new V.VeraNumberValue(100000)])
  assert.equal(done.fields.get('remaining').value,0); assert.equal(done.fields.get('running').value,false)
 })
 await test('new component signatures/styles/fields/empty/long text/order', async () => {
  for(const style of ['plain','accent']) for(const width of [-1,0,80,160,240]) {
   const source=`import * as ui from "std/ui"\nfunction view(): ui.View { return ui.Hero("${style}", "", "A very long title that must wrap without reducing body text", "Long supporting text stays readable", [ui.AdaptiveColumns("spacious", ${width}, [ui.Text("body", "first"), ui.Text("body", "second"), ui.Text("body", "third")]), ui.AdaptiveColumns("compact", 240, [])]); }`
   const root=U.decodeVeraUi(vm(C.compileVeraSource(source).vbc2).execute('view'))[0]
   assert.equal(root.kind,'hero'); assert.equal(root.style,style); assert.equal(root.label,''); assert(root.value.startsWith('Long'))
   const col=root.children[0]; assert.equal(col.kind,'adaptivecolumns'); assert.equal(col.minimum,width)
   assert.deepEqual(col.children.map(c=>c.text),['first','second','third']); assert.equal(root.children[1].children.length,0)
  }
 })
 const T=loadVera('VeraTheme')
 const targets={clean:[32,40,16,32,16,16,'#F8FAFC','#2563EB'],soft:[32,40,16,32,20,24,'#FAF7F2','#6D5BD0'],expressive:[36,44,16,36,20,20,'#F7F3FF','#7C3AED'],editorial:[38,42,16,36,20,4,'#FAFAF7','#27272A'],technical:[30,36,15,28,16,8,'#F3F7F7','#0F766E'],playful:[36,44,16,36,20,24,'#FFF7F4','#BE185D']}
 function luminance(hex) { return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255).map(c=>c<=0.04045?c/12.92:((c+0.055)/1.055)**2.4).reduce((a,c,i)=>a+c*[0.2126,0.7152,0.0722][i],0) }
 function ratio(a,b) { const x=luminance(a),y=luminance(b); return (Math.max(x,y)+0.05)/(Math.min(x,y)+0.05) }
 for(const [preset,target] of Object.entries(targets)) {
  await test(preset+': exact type, spacing and light anchors', async () => {
   const t=T.resolveTheme(preset,'',false)
   assert.deepEqual([t.sizeDisplay,t.sizeMetric,t.sizeBody,t.gapSection,t.padCard,t.radiusCard,t.background,t.primary],target)
   assert.equal(t.surface,'#FFFFFF'); assert.equal(t.sizeTitle,24); assert.equal(t.sizeHeading,preset==='technical'?18:20); assert.equal(t.sizeCaption,13)
   assert.equal(t.fontFamily,''); assert.equal(t.headingFontFamily,{editorial:'Noto Serif'}[preset]||''); assert.equal(t.metricFontFamily,{editorial:'Noto Serif',technical:'monospace'}[preset]||'')
  })
  for(const dark of [false,true]) for(const seed of ['', '#FFFFFF','#000000','#FFCC00','#FF00FF','#00FFFF']) await test(`${preset}/${dark?'dark':'light'}/${seed||'default'}: enabled color contrast`, async () => {
   const t=T.resolveTheme(preset,seed,dark)
   // These text roles occur on ordinary, raised, accent and status surfaces.
   const surfaces=['background','surface','surfaceRaised','primaryFill','secondaryFill','successFill','warningFill','dangerFill']
   for(const ink of ['ink','inkStrong','inkSoft','inkMuted','primaryInk','successInk','warningInk','dangerInk']) for(const surface of surfaces) {
    const observed=ratio(t[ink],t[surface]); contrasts.push({preset,dark,seed,ink,surface,ratio:observed})
    assert(observed>=4.5-1e-6,`${ink} ${t[ink]} on ${surface} ${t[surface]}: ${observed}`)
   }
   for(const style of ['primary','secondary','success','danger']) {
    const observed=ratio(T.buttonInk(t,style),T.buttonFill(t,style)); contrasts.push({preset,dark,seed,button:style,ratio:observed}); assert(observed>=4.5)
   }
  })
 }
 await test('native semantic typography, widget caps and measured columns', async () => {
  const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
  function method(name) { const start=renderer.indexOf('  private '+name+'('); assert(start>=0,name); const open=renderer.indexOf('{',start); let depth=1,end=open+1; while(depth&&end<renderer.length){if(renderer[end]==='{')depth++;if(renderer[end]==='}')depth--;end++}return renderer.slice(start,end).replace('  private ','') }
  const ts=process.env.VERA_TYPESCRIPT_PATH?require(process.env.VERA_TYPESCRIPT_PATH):require('typescript')
  const body=['textFamily','renderTextSize','adaptiveColumnsCount','adaptiveChildWidth'].map(method).join('\n')
  const code=ts.transpileModule('class Probe { '+body+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText
  const Probe=new Function('textSize','densityGap',code+'; return Probe')(T.textSize,T.densityGap)
  const probe=new Probe(); probe.t=()=>T.resolveTheme('technical','',false); probe.embedded=false
  assert.equal(probe.textFamily('metric'),'monospace'); assert.equal(probe.textFamily('body'),undefined)
  assert.equal(probe.renderTextSize('metric'),36); probe.embedded=true; assert.equal(probe.renderTextSize('metric'),32)
  probe.t=()=>T.resolveTheme('editorial','',false); assert.equal(probe.textFamily('title'),'Noto Serif'); assert.equal(probe.renderTextSize('display'),32)
  for(const minimum of [-1,0,80,160,240]) {
   const min=minimum<=0?240:Math.max(160,minimum), gap=T.densityGap(probe.t(),'default')
   const node={minimum,style:'default',layoutWidth:0}; assert.equal(probe.adaptiveColumnsCount(node),1)
   node.layoutWidth=min*2+gap-1; assert.equal(probe.adaptiveColumnsCount(node),1)
   node.layoutWidth=min*2+gap; assert.equal(probe.adaptiveColumnsCount(node),2); assert.equal(probe.adaptiveChildWidth(node),min)
   node.layoutWidth=320; assert.equal(probe.adaptiveColumnsCount(node),1)
  }
  assert(renderer.includes("node.kind === 'hero'")); assert(renderer.includes("node.kind === 'adaptivecolumns'")); assert(renderer.includes('node.layoutWidth ='))
 })
  await test('scoped renderer APIs preserve dark listener lifecycle and density', async () => {
   const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
   assert(!/mediaquery\.matchMediaSync|TimePickerDialog\.show|(?<![\w.])vp2px\(/.test(renderer.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/[^\n]*/g,'')))
   assert(renderer.includes('private darkListener: mediaquery.MediaQueryListener | null'))
   assert(renderer.includes('this.getUIContext().showTimePickerDialog({'))
   assert(renderer.includes('x: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100, y: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100'))
   const names=['watchDarkMode','sparklinePoint','sparklineCommands','sparklineAreaCommands','sparklineGridCommands']
    const body=names.map(n=>declaration(renderer,'  private '+n+'(').replace('  private ','')).join('\n')
    const code=ts.transpileModule(declaration(renderer,'class PreviewPost')+'\nclass Probe { static SPARKLINE_HEIGHT=200; static SPARKLINE_INSET=16; '+body+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText
    const Probe=new Function('StageTrace',code+'; const VeraPreview=Probe; return Probe')(StageTrace), f=await fieldProbe(), probe=f.probe, queries=[], events=[]
    for(const name of names)probe[name]=Probe.prototype[name]
   let change, renders=0, density=1
   const listener={matches:true,on(event,cb){events.push(event);change=cb},off(event){events.push('off:'+event)}}
   probe.getUIContext=()=>({getMediaQuery:()=>({matchMediaSync(query){queries.push(query);return listener}}),vp2px:value=>value*density})
    const render=probe.renderView.bind(probe), stop=probe.stopAllTimers.bind(probe)
    probe.renderView=(...args)=>{renders++;render(...args)};probe.stopAllTimers=()=>{events.push('stop');stop()};probe.retireWorlds=()=>{};probe.dark=false
   probe.watchDarkMode();assert.deepEqual(queries,['(dark-mode: true)']);assert.equal(probe.dark,true);assert.equal(probe.darkListener,listener)
   change({matches:true});await f.settle();assert.equal(renders,0);change({matches:false});await f.settle();assert.equal(renders,1);assert.equal(probe.dark,false)
   for(density of [1,2,3.5]) {
    const low=(184*density).toFixed(2), high=(16*density).toFixed(2), x1=(25*density).toFixed(2), x2=(75*density).toFixed(2)
    assert.equal(probe.sparklineCommands([0,10],10,0,100),`M ${x1} ${low} L ${x2} ${high}`)
    assert.equal(probe.sparklineCommands([10],10,0,100),`M ${(50*density).toFixed(2)} ${high}`)
    assert.equal(probe.sparklineCommands([],10,0,100),'')
    assert.equal(probe.sparklineAreaCommands([0,10],10,0,100),`M ${x1} ${low} L ${x2} ${high} L ${x2} ${low} L ${x1} ${low} Z`)
    assert(probe.sparklineGridCommands(10,0,100).startsWith(`M 0 ${high} L ${(100*density).toFixed(2)} ${high}`))
   }
   probe.aboutToDisappear();await settlePreview(probe);assert.equal(probe.disposed,true);assert.equal(probe.darkListener,null);assert.deepEqual(events,['change','stop','off:change'])
   change({matches:true});assert.equal(renders,1)
  })
    function effectProbe(askBeforeCalls=false) {
     global.ObservedV2=c=>c;global.Trace=()=>{}
     const platform=[], events=[], executions=[], delivered=[]
     let probe, platformHook=()=>{}, serial=0
     function call(kind,...args) {
      let resolve, reject
      const promise=new Promise((ok,fail)=>{resolve=ok;reject=fail})
      platform.push({kind,args,promise,resolve,reject});platformHook();return promise
     }
     const mocks={StageTrace,scheduleCardRefresh:project=>events.push(['persist',project]),runRawIntent:(...args)=>call('intent',...args),runSdkAdapter:(...args)=>call('sdk',...args),catalogKinds:()=>{events.push(['catalogue',probe.disposed]);return []},consent:{has:()=>false,remember:(...args)=>events.push(['remember',...args])},armReveal:value=>events.push(['reveal',value])}
     const host=hostModule(mocks,(action,args)=>executions.push({action,args}))
     const made=createPreview({...host,mocks,askBeforeCalls});probe=made.probe
     Object.assign(probe,{programId:7,retireWorlds(){},reconcileWorlds(){},worldsNeedFrames(){return false},tickWorlds(){},persistKey:'fixture/version',onStateSnapshot(){events.push(['snapshot'])},watchDarkMode(){events.push(['dark',this.disposed])}})
     const render=probe.renderView.bind(probe), stop=probe.stopAllTimers.bind(probe)
     probe.renderView=(...args)=>{events.push(['render']);render(...args)}
     probe.stopAllTimers=(...args)=>{events.push(['stop',probe.disposed,probe.effectGeneration]);stop(...args)}
     const source=`
@jsonable class AppState { count: number; }
function init(): AppState { return {count: 0}; }
function tap(state: AppState, value: number): AppState { return {count: state.count + value}; }
${[1,2,3,4].map(id=>'function answer'+id+'(state: AppState, value: string): AppState { return state; }').join('\n')}
function view(state: AppState): ui.View { return ui.Text("body", ui.numberToString(state.count)); }
`
     const bytecode=C.compileVeraSource(source).vbc2
     probe.acceptEffects=effects=>injectEffects(probe,effects)
     probe.localEffectRequest=effect=>effectRequest(probe,effect)
     probe.runEffect=effect=>probe.acceptEffects([effect])
     async function load() {
      probe.vbc2=C.compileVeraSource(source+'\nfunction fixtureRevision(): number { return '+(++serial)+'; }').vbc2
      probe.load();await settlePreview(probe)
     }
     function observeDispatch() {
      const post=host.runtime.postEffectResult.bind(host.runtime)
      host.runtime.postEffectResult=(handle,id,text)=>{
       const effect=host.runtime.registry.get(handle.appId)?.effects.get(id)
       const result=post(handle,id,text)
       if(result.status==='ACCEPTED')delivered.push([effect.handler,text])
       return result
      }
     }
     return {probe,...host,platform,events,executions,delivered,bytecode,load,observeDispatch,
      snapshot:()=>host.runtime.requestSnapshot(probe.handle),onPlatform(action){platformHook=action}}
    }
   function hostEffect(id=1,kind='sdk',rawTarget='fixture.read') { return {id,kind,fn:'call',rawTarget,rawMode:'foreground',values:new Map([['body','fixture payload'],['count','2']]),resultHandler:'answer'+id} }
    function effectController(probe) { return probe.effectsBridge?.binding?.controller }
    function heldRequests(probe) { const controller=effectController(probe);return controller?controller.heldEffects.slice(controller.heldIndex).map(work=>work.effect):[] }
   function seedEffects(probe) { probe.acceptEffects([hostEffect(3),hostEffect(2)]);assert.deepEqual(probe.pending,probe.localEffectRequest(hostEffect(3)));assert.deepEqual(heldRequests(probe),[probe.localEffectRequest(hostEffect(2))]) }
   async function settleEffect(call,rejected=false,text='answer') {
    if(rejected)call.reject(new Error(text));else call.resolve(text)
    await new Promise(resolve=>setImmediate(resolve))
   }
   for(const transition of ['load','disappear','reappear']) for(const rejected of [false,true]) await testAsync(`renderer effects: late ${rejected?'error':'answer'} ignored after ${transition}`, async () => {
    const f=effectProbe(), {probe,platform,delivered}=f
    await f.load();f.observeDispatch()
    const generation=probe.effectGeneration
    probe.acceptEffects([hostEffect()])
    assert.equal(platform.length,1);assert(platform[0].promise instanceof Promise)
    if(transition==='load')await f.load();else {
     probe.aboutToDisappear();await settlePreview(probe)
     if(transition==='reappear') { probe.aboutToAppear();await settlePreview(probe) }
    }
    assert(probe.effectGeneration>generation)
    if(transition==='reappear')assert.equal(probe.disposed,false)
    await settleEffect(platform[0],rejected,'old')
    assert.deepEqual(delivered,[])
    if(transition!=='disappear') {
     probe.acceptEffects([hostEffect(2)])
     await settleEffect(platform[1],rejected,'current')
     assert.deepEqual(delivered,[['answer2',rejected?'error: current':'current']])
    }
   })
   for(const rejected of [false,true]) await testAsync(`renderer effects: disposed callback drops current-generation ${rejected?'error':'answer'}`, async () => {
    const f=effectProbe();await f.load();f.observeDispatch()
    const generation=f.probe.effectGeneration
    f.probe.acceptEffects([hostEffect()]);f.probe.disposed=true
    await settleEffect(f.platform[0],rejected,'disposed')
    assert.equal(f.probe.effectGeneration,generation);assert.deepEqual(f.delivered,[])
   })
   for(const rejected of [false,true]) await testAsync(`renderer effects: current ${rejected?'error':'answer'} delivered through each platform route`, async () => {
    for(const [kind,target,route] of [['sdk','fixture/read','intent'],['sdk','fixture.read','sdk'],['other','fixture.read','sdk']]) {
     const f=effectProbe();await f.load();f.observeDispatch()
     const effect=hostEffect(1,kind,target), generation=f.probe.effectGeneration
     f.probe.runEffect(effect)
     assert.equal(f.platform.length,1);assert.equal(f.platform[0].kind,route)
     assert.equal(f.platform[0].args[0],target);assert.deepEqual(f.platform[0].args[1],effect.values);assert.equal(f.platform[0].args.length,route==='intent'?3:2);if(route==='intent')assert.equal(f.platform[0].args[2],effect.rawMode)
     await settleEffect(f.platform[0],rejected,'current')
     assert.deepEqual(f.delivered,[['answer1',rejected?'error: current':'current']]);assert.equal(f.probe.effectGeneration,generation)
    }
   })
   for(const rejected of [false,true]) await testAsync(`renderer effects: generation captured before platform ${rejected?'error':'answer'}`, async () => {
    const f=effectProbe();await f.load();f.observeDispatch()
    const generation=f.probe.effectGeneration
     let loading
     f.onPlatform(()=>{loading=f.load()})
     f.probe.acceptEffects([hostEffect()])
     await loading
     assert.equal(f.platform.length,1);assert.equal(f.probe.effectGeneration,generation+1)
    await settleEffect(f.platform[0],rejected,'reentrant')
    assert.deepEqual(f.delivered,[])
   })
   await testAsync('renderer effects: out-of-order replies in one generation are all delivered', async () => {
    const f=effectProbe();await f.load();f.observeDispatch()
    const generation=f.probe.effectGeneration
    for(let id=1;id<=3;id++)f.probe.acceptEffects([hostEffect(id)])
    assert.equal(f.platform.length,3)
    await settleEffect(f.platform[2],false,'third')
    await settleEffect(f.platform[0],true,'first')
    await settleEffect(f.platform[1],false,'second')
    assert.deepEqual(f.delivered,[['answer3','third'],['answer1','error: first'],['answer2','second']]);assert.equal(f.probe.effectGeneration,generation)
   })
   for(const mode of ['normal','empty','malformed','preview']) await test('renderer effects: '+mode+' load invalidates queues and preserves UI identity rules', async () => {
    const f=effectProbe(true), {probe}=f
     await f.load()

      const handle=probe.handle, state=await f.snapshot(), root=probe.liveRoot, generation=probe.effectGeneration, programId=probe.programId
      seedEffects(probe)
      const controller=effectController(probe)
      probe.previewOnly=mode==='preview'
      probe.vbc2=mode==='empty'?'':mode==='malformed'?'not valid bytecode':f.bytecode
      probe.stopAllTimers=()=>{
       assert.equal(probe.effectGeneration,generation+1);assert.deepEqual(controller.heldEffects,[]);assert.equal(controller.pending,null);assert.equal(probe.pending,null)
       assert.equal(probe.handle,handle)
      }
      probe.load();await settlePreview(probe)
      assert.equal(probe.effectGeneration,generation+1);assert.deepEqual(heldRequests(probe),[]);assert.equal(probe.pending,null)
      assert.equal(probe.programId,programId);assert.equal(probe.hasRoot,true);assert.equal(probe.liveRoot,root)
      assert(probe.handle)
       if(mode==='preview') {
        assert.equal(probe.liveRoot.text,'0');assert.equal(probe.activeOptions.persistKey,'');assert.equal(probe.activeOptions.seedState,'')
       } else assert.equal(await f.snapshot(),state)
      if(mode==='empty'||mode==='malformed') { assert.equal(probe.handle,handle);assert.match(probe.error,/ACTOR_NOT_READY/) }
      else { assert.notEqual(probe.handle,handle);assert.equal(probe.error,'');assert.equal(probe.activeOptions.mode,mode==='preview'?'PREVIEW':'LIVE_PERSISTENT') }
   })
   for(const mode of ['empty','malformed','preview']) for(const rejected of [false,true]) await testAsync(`renderer effects: ${mode} load rejects late ${rejected?'errors':'answers'}`, async () => {
    const f=effectProbe();await f.load();f.observeDispatch()
    const programId=f.probe.programId
    f.probe.acceptEffects([hostEffect()])
     f.probe.previewOnly=mode==='preview'
    f.probe.vbc2=mode==='empty'?'':mode==='malformed'?'not valid bytecode':f.bytecode
     f.probe.load();await settlePreview(f.probe)
     if(mode==='preview')assert.equal(f.probe.programId,programId)
    await settleEffect(f.platform[0],rejected,'stale')
    assert.deepEqual(f.delivered,[])
   })
   await test('renderer effects: invalidation works with no host and does not change UI identity', async () => {
    const {probe}=effectProbe(true), programId=probe.programId
    assert.equal(probe.effectGeneration,0);assert.equal(probe.disposed,false)
    for(let generation=1;generation<=2;generation++) {
      probe.invalidateEffects()
      assert.equal(probe.effectGeneration,generation);assert.deepEqual(heldRequests(probe),[]);assert.equal(probe.pending,null);assert.equal(probe.handle,null);assert.equal(probe.effectsBinding,null);assert.equal(probe.programId,programId)
    }
   })
    await test('renderer effects: disappear drains before invalidation and release after timer and listener cleanup', async () => {
     const f=effectProbe(true), {probe,events,runtime}=f
     await f.load();events.length=0
     const handle=probe.handle, generation=probe.effectGeneration, programId=probe.programId
     seedEffects(probe)
     const controller=effectController(probe)
     probe.darkListener={off:event=>events.push(['darkOff',event])};probe.liveSurfaces=[probe.liveRoot]
     probe.stopAllTimers=()=>{
      assert.equal(probe.disposed,true);assert.equal(probe.draining,true);assert.equal(probe.effectGeneration,generation);assert.equal(probe.handle,handle);assert(controller.pending);assert.equal(heldRequests(probe).length,1);events.push(['stop'])
     }
     probe.aboutToDisappear();await settlePreview(probe)
     assert.equal(probe.programId,programId);assert.equal(probe.darkListener,null)
     assert.equal(probe.handle,null);assert.equal(probe.draining,false);assert.equal(probe.effectGeneration,generation+1)
     assert.deepEqual(controller.heldEffects,[]);assert.equal(controller.pending,null);assert.equal(probe.effectsBinding,null)
     await assert.rejects(runtime.requestSnapshot(handle),/INVALID_HANDLE/)
     assert.deepEqual(events,[['stop'],['darkOff','change'],['persist','fixture']])
    })
   for(const method of ['dispatch','acceptEffects','runQueued','allowPending','refusePending']) await test('renderer effects: disposed '+method+' does no work', async () => {
    const f=effectProbe(true), {probe,events,executions,platform}=f
    await f.load();seedEffects(probe)
     const handle=probe.handle, controller=effectController(probe), pending=controller.pending, held=controller.heldEffects.slice(controller.heldIndex)
    const expectedHeld=[probe.localEffectRequest(hostEffect(2))]
    probe.aboutToDisappear();await settlePreview(probe);events.length=0;executions.length=0
    const effect=pending.effect, queued=[hostEffect(3)], generation=probe.effectGeneration
     probe.pending=effect;controller.pending=pending;controller.heldEffects=held;controller.heldIndex=0
     if(method==='dispatch')probe.dispatch('tap',scalarPayload(1));else if(method==='acceptEffects')probe.acceptEffects(queued);else if(method==='runQueued')controller.runQueued();else probe[method]()
     await settlePreview(probe)
     assert.deepEqual(executions,[]);assert.deepEqual(platform,[]);assert.deepEqual(events,[])
     assert.equal(probe.handle,null);await assert.rejects(f.runtime.requestSnapshot(handle),/INVALID_HANDLE/)
     assert.equal(probe.pending,effect);assert.equal(controller.pending,pending)
      assert.deepEqual(held.map(work=>work.effect),expectedHeld)
       assert.deepEqual(controller.heldEffects,held)
      assert.deepEqual(queued,[hostEffect(3)]);assert.equal(probe.effectGeneration,generation)
   })
   await test('renderer effects: active dispatch executes real actor VM and commits state', async () => {
    const f=effectProbe(), {probe,executions,events}=f
    await f.load();executions.length=0;events.length=0
      const state=V.decodeRuntimeValue(JSON.parse(await f.snapshot())), payload=scalarPayload(1)
      probe.dispatch('tap',payload);await settlePreview(probe)
      assert.deepEqual(executions.filter(call=>call.action!=='view'),[{action:'tap',args:[state,new V.VeraNumberValue(1)]}])
      assert.equal(V.decodeRuntimeValue(JSON.parse(await f.snapshot())).fields.get('count').value,1)
     assert.deepEqual(events,[['snapshot'],['persist','fixture'],['reveal',true],['render'],['reveal',false]]);assert.equal(probe.error,'')
   })
   await testAsync('renderer effects: active queues drain, allow and refuse without losing replies', async () => {
    const f=effectProbe(true), {probe,platform,delivered,events}=f
    await f.load();f.observeDispatch()
    const first=hostEffect(1,'other'), allowed=hostEffect(2), refused=hostEffect(3), last=hostEffect(4,'other')
    probe.acceptEffects([first,allowed,refused,last])
    assert.equal(platform.length,1);assert.deepEqual(probe.pending,probe.localEffectRequest(allowed));assert.deepEqual(heldRequests(probe),[refused,last].map(effect=>probe.localEffectRequest(effect)))
    probe.allowPending()
    assert.equal(platform.length,2);assert.deepEqual(probe.pending,probe.localEffectRequest(refused));assert.deepEqual(heldRequests(probe),[probe.localEffectRequest(last)]);assert.deepEqual(events.filter(event=>event[0]==='remember'),[['remember',probe.stamp(),allowed.rawTarget]])
    probe.refusePending();await settlePreview(probe)
    assert.equal(platform.length,3);assert.equal(probe.pending,null);assert.deepEqual(heldRequests(probe),[]);assert.deepEqual(delivered,[['answer3','declined by the person']])
    for(const [index,call] of platform.entries())await settleEffect(call,false,'reply'+index)
    assert.deepEqual(delivered,[['answer3','declined by the person'],['answer1','reply0'],['answer2','reply1'],['answer4','reply2']])
   })
   await test('renderer effects: reappearance resets disposed before catalogue, watchers and real load', async () => {
    const f=effectProbe(), {probe,events}=f
    await f.load();probe.aboutToDisappear();await settlePreview(probe);events.length=0
    const generation=probe.effectGeneration, load=probe.load
    probe.load=function() { events.push(['load',this.disposed]);assert.equal(this.disposed,false);return load.call(this) }
     probe.aboutToAppear();await settlePreview(probe)
     assert.deepEqual(events.slice(0,3),[['catalogue',false],['dark',false],['load',false]])
     assert.equal(probe.disposed,false);assert.equal(probe.effectGeneration,generation+1);assert(probe.handle);assert.equal(V.decodeRuntimeValue(JSON.parse(await f.snapshot())).fields.get('count').value,0)
   })
     async function surfaceProbe(route='displaySync') {
      let probe, nextHandle=0, observed=''
      const events=[], executions=[], syncs=[], scheduled=new Map()
      const bytecode=C.compileVeraSource(`
@jsonable class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function tick(state: AppState, elapsed: number): AppState { return {n: state.n + elapsed}; }
function draw(state: AppState): gfx.Shape[] { return []; }
function view(state: AppState): ui.View { return ui.Column("default", [ui.Surface("default", 100, 100, "draw", "tick", "")]); }
`).vbc2
      const f=await fieldProbe(false,null,10000,{
       bytecode,mount:false,fields:['lastFrameAt','frameCount','frameWork','frameWorst','frameReportAt'],
       methods:['onDestinationHidden','reconcileSurfaces','collectKind','startSurfaceLoop','stopSurfaceLoop','surfaceFrame'],constants:['SURFACE_MAX_ELAPSED_MS'],
       observe(action,args){if(action!=='init'&&action!=='view')executions.push({action,args})},
       mocks:{catalogKinds:()=>{events.push(['catalogue',probe.disposed,probe.pageHidden]);return []},displaySync:{create(){
        events.push(['create'])
        if(route==='interval')throw Error('fixture: no displaySync')
        const sync={callback:null,active:false,setExpectedFrameRateRange(range){assert.deepEqual(range,{expected:60,min:30,max:120})},on(event,callback){assert.equal(event,'frame');this.callback=callback},start(){this.active=true;events.push(['start'])},stop(){this.active=false;events.push(['stop'])},off(event){assert.equal(event,'frame');events.push(['off'])}}
        syncs.push(sync);return sync
       }},setInterval(callback,interval){assert.equal(interval,16);const handle=++nextHandle;scheduled.set(handle,callback);events.push(['start']);return handle},clearInterval(handle){assert(scheduled.delete(handle));events.push(['stop'])}},
       setup(p){
        probe=p;p.persistKey=''
        p.stopAllTimers=function(){events.push(['cleanup',this.disposed,this.pageHidden]);this.stopSurfaceLoop()}
        p.watchDarkMode=function(){events.push(['dark',this.disposed,this.pageHidden])}
        p.onStateSnapshot=encoded=>{observed=encoded;events.push(['snapshot'])}
        p.paintSurfaces=()=>events.push(['paint']);p.stopPartsTimer=()=>{};p.advanceParts=()=>{}
        const load=p.load.bind(p);p.load=function(){events.push(['load',this.disposed,this.pageHidden]);load()}
       }
      })
      function callback() { return route==='interval'?scheduled.get(probe.surfaceTimer):probe.surfaceSync?.callback }
      return {...f,events,executions,syncs,scheduled,callback,captureSnapshot:f.snapshot,snapshot:()=>observed,active(){return syncs.filter(sync=>sync.active).length+scheduled.size},transition(hidden){probe.destinationHidden=hidden;probe.onDestinationHidden()}}
     }
     function surfaceSnapshot(f) {
      const p=f.probe
      return {state:f.snapshot(),ready:p.handle!==null,lastFrameAt:p.lastFrameAt,frameSplit:[...p.frameSplit],events:[...f.events],executions:[...f.executions]}
     }
    for(const route of ['displaySync','interval']) {
     await test(`destination surfaces/${route}: initially hidden gate precedes watchers and real load`, async () => {
      const f=await surfaceProbe(route), {probe,events}=f
      probe.destinationHidden=true;probe.disposed=true;probe.aboutToAppear();await f.settle()
      assert.deepEqual(events.slice(0,4),[['catalogue',false,true],['dark',false,true],['load',false,true],['cleanup',false,true]])
      assert.equal(probe.pageHidden,true);assert.equal(probe.disposed,false);assert.equal(probe.liveSurfaces.length,1);assert.equal(f.active(),0)
      assert(!events.some(event=>event[0]==='create'||event[0]==='start'))
      f.transition(false);assert.equal(probe.pageHidden,false);assert.equal(f.active(),1)
      f.callback()();await f.settle();assert.equal(f.executions[0].action,'tick');assert.equal(f.executions[0].args[1].value,16);assert.equal(probe.error,'')
      probe.aboutToDisappear();await settlePreview(probe);assert.equal(f.active(),0)
     })
     await test(`destination surfaces/${route}: hidden program loads and rerenders never restart frames`, async () => {
      const f=await surfaceProbe(route), {probe,events}=f
      probe.aboutToAppear();await f.settle();f.transition(true)
      const starts=events.filter(event=>event[0]==='start').length
      for(let i=0;i<3;i++) {
       probe.onProgramChanged();await f.settle();assert.equal(f.runtime.requestView(probe.handle).status,'ACCEPTED');await f.settle()
       for(const previewOnly of [true,false]) {
        probe.previewOnly=previewOnly;probe.onPreviewOnlyChanged();await f.settle()
        assert.equal(probe.error,'');assert.equal(probe.pageHidden,true);assert.equal(f.active(),0);assert.equal(probe.liveSurfaces.length,1)
       }
      }
      assert.equal(events.filter(event=>event[0]==='start').length,starts)
      f.transition(false);assert.equal(f.active(),1);assert.equal(events.filter(event=>event[0]==='start').length,starts+1)
      probe.aboutToDisappear();await settlePreview(probe)
     })
     await test(`destination surfaces/${route}: repeated hide/show pauses, resumes and resets real loop elapsed`, async () => {
      const f=await surfaceProbe(route), {probe,events}=f
       probe.aboutToAppear();await f.settle()
       for(let i=0;i<3;i++) {
       const frame=f.callback(), starts=events.filter(event=>event[0]==='start').length
       frame();await f.settle();assert.equal(f.executions.filter(call=>call.action==='tick').at(-1).args[1].value,16)
       f.elapse(37);frame();await f.settle();assert.equal(f.executions.filter(call=>call.action==='tick').at(-1).args[1].value,37)
       const last=probe.lastFrameAt
       probe.reconcileSurfaces(false);assert.equal(f.callback(),frame);assert.equal(probe.lastFrameAt,last)
       f.transition(true);assert.equal(f.active(),0);assert.equal(probe.pageHidden,true)
       const stopped=events.length;f.transition(true);assert.equal(events.length,stopped)
       f.elapse(60000);const hidden=surfaceSnapshot(f);frame();assert.deepEqual(surfaceSnapshot(f),hidden)
       f.transition(false);assert.equal(f.active(),1);assert.equal(probe.pageHidden,false);assert.equal(probe.lastFrameAt,0)
       const resumed=events.length;f.transition(false);assert.equal(events.length,resumed);assert.equal(events.filter(event=>event[0]==='start').length,starts+1)
      }
      assert.equal(events.filter(event=>event[0]==='stop').length,3)
      if(route==='displaySync')assert.equal(events.filter(event=>event[0]==='off').length,3)
      f.callback()();await f.settle();assert.equal(f.executions.filter(call=>call.action==='tick').at(-1).args[1].value,16);assert.equal(probe.error,'')
      assert.equal(V.decodeRuntimeValue(JSON.parse(await f.captureSnapshot())).fields.get('n').value,175)
      probe.aboutToDisappear();await settlePreview(probe);assert.equal(f.active(),0)
     })
     for(const gate of ['hidden','disposed']) await test(`destination surfaces/${route}: late frame does no work while ${gate}`, async () => {
      const f=await surfaceProbe(route), {probe}=f
      probe.aboutToAppear();await f.settle();const frame=f.callback();frame();await f.settle()
      if(gate==='hidden')f.transition(true);else probe.aboutToDisappear();await settlePreview(probe)
      assert.equal(f.active(),0)
      f.elapse(60000);const before=surfaceSnapshot(f)
      frame();probe.surfaceFrame();assert.deepEqual(surfaceSnapshot(f),before);assert.equal(probe.error,'')
     })
     await test(`destination surfaces/${route}: disposed destination watcher is inert in both directions`, async () => {
      for(const hidden of [false,true]) {
       const f=await surfaceProbe(route), {probe}=f
       probe.destinationHidden=hidden;probe.aboutToAppear();await f.settle();probe.aboutToDisappear();await settlePreview(probe)
       const before=surfaceSnapshot(f)
       f.transition(!hidden);assert.equal(probe.pageHidden,hidden);assert.equal(f.active(),0);assert.deepEqual(surfaceSnapshot(f),before)
      }
     })
     for(const hidden of [false,true]) await test(`destination surfaces/${route}: reappearance refreshes ${hidden?'hidden':'visible'} gate before load`, async () => {
      const f=await surfaceProbe(route), {probe,events}=f
      probe.destinationHidden=!hidden;probe.aboutToAppear();await f.settle();probe.aboutToDisappear();await settlePreview(probe);events.length=0
probe.destinationHidden=hidden;probe.onDestinationHidden();assert.equal(probe.pageHidden,!hidden)
       probe.aboutToAppear();await f.settle()
      assert.deepEqual(events.slice(0,4),[['catalogue',false,hidden],['dark',false,hidden],['load',false,hidden],['cleanup',false,hidden]])
      assert.equal(probe.pageHidden,hidden);assert.equal(probe.disposed,false);assert.equal(f.active(),hidden?0:1)
      if(!hidden) { assert.equal(probe.lastFrameAt,0);f.callback()();await f.settle();assert.equal(f.executions[0].args[1].value,16) }
      probe.aboutToDisappear();await settlePreview(probe);assert.equal(f.active(),0)
     })
    }
    await test('destination visibility: Chat passes state through MessageBubble to VeraPreview', async () => {
     const chat=fs.readFileSync(path.join(sourceRoot,'pages/ChatPage.ets'),'utf8')
     const page=declaration(chat,'export struct ChatPage'), bubble=declaration(chat,'struct MessageBubble')
     assert.match(page,/@State\s+destinationHidden:\s*boolean\s*=\s*false/)
     assert.match(bubble,/@Prop\s+destinationHidden:\s*boolean\s*=\s*false/)
     for(const [source,component] of [[page,'MessageBubble'],[bubble,'VeraPreview']]) {
      const calls=[...source.matchAll(new RegExp('\\b'+component+'\\(\\{','g'))]
      assert(calls.length>0,component+' wiring')
      for(const call of calls)assert.match(declaration(source.slice(call.index),component+'('),/\bdestinationHidden:\s*this\.destinationHidden\b/)
     }
     const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
     assert.match(renderer,/@Prop\s+@Watch\('onDestinationHidden'\)\s+destinationHidden:\s*boolean\s*=\s*false/)
    })
    for(const page of ['Chat','Generate','Runner']) await test(`destination visibility: ${page} host onShown/onHidden and preview wiring`, async () => {
     const source=fs.readFileSync(path.join(sourceRoot,'pages/'+page+'Page.ets'),'utf8')
     assert.match(source,/@State\s+destinationHidden:\s*boolean\s*=\s*false/)
     assert.match(declaration(source,'.onHidden('),/\.onHidden\(\(\)\s*=>\s*\{\s*this\.destinationHidden\s*=\s*true\s*\}$/)
     assert.match(declaration(source,'.onShown('),page==='Runner'?/\.onShown\(\(\)\s*=>\s*\{\s*this\.destinationHidden\s*=\s*false\s*\}$/:/\.onShown\(\(\)\s*=>\s*\{\s*this\.destinationShown\(\)\s*\}$/)
     if(page!=='Chat') {
      const calls=[...source.matchAll(/\bVeraPreview\(\{/g)].map(call=>declaration(source.slice(call.index),'VeraPreview(')).filter(call=>! /previewOnly:\s*true\b/.test(call))
      assert(calls.length>0,'runnable previews')
      for(const call of calls)assert.match(call,/\bdestinationHidden:\s*this\.destinationHidden\b/)
     }
    })
    for(const page of ['Chat','Generate']) await test(`destination visibility: ${page} real destinationShown resumes only an active host`, async () => {
     const source=fs.readFileSync(path.join(sourceRoot,'pages/'+page+'Page.ets'),'utf8')
     const method=declaration(source,'  private destinationShown(').replace('  private ','')
     const compiled=ts.transpileModule('class Probe { '+method+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
     assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,page+' destinationShown syntax')
     const events=[], settings={getMode(){return 'cloud'},getModel(){events.push('model');return 'fixture'},hasApiKey(){events.push('configured');return true}}
     const Probe=new Function('settings','MODE_DEEPSEEK',compiled.outputText+';return Probe')(settings,'cloud'), probe=new Probe()
     Object.assign(probe,{disposed:true,destinationHidden:true,mode:'cloud',generating:false,status:'',selectedModel:'',checkDeepSeek(){events.push('check')}})
     probe.destinationShown();assert.equal(probe.destinationHidden,true);assert.deepEqual(events,[])
     probe.disposed=false;probe.destinationShown();assert.equal(probe.destinationHidden,false);assert(events.length>0)
     if(page==='Chat')assert.equal(probe.selectedModel,'fixture');else assert.deepEqual(events,['check'])
    })
       function previewController() {
        const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
        const source=declaration(renderer,'export class VeraPreviewController').replace('export class ','class ')
        const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText
        return new (new Function(code+'; return VeraPreviewController')())()
       }
        async function fieldProbe(sync=false,controller=null,clockStart=0,options={}) {
       global.ObservedV2=c=>c;global.Trace=()=>{}
      const L=loadSource(path.join(sourceRoot,'components/VeraLiveTree.ets'))
       let now=clockStart, nextHandle=0
       const scheduled=new Map(), history=new Map(), intervals=new Map(), calls=[], writes=[], saves=[], replies=[], snapshots=[]
       const TouchType={Down:0,Up:1,Move:2,Cancel:3}, SliderChangeMode={Begin:0,Moving:1,End:2,Click:3}
       const platform=options.platform||(()=>new Promise((resolve,reject)=>replies.push({resolve,reject})))
       class TextInputController {
        constructor() { this.text='';this.reads=0 }
        getText() { this.reads++;return this.text }
       }
        let persisted='', observed=''
        const store={loadState:()=>persisted,saveState(project,version,stamp,encoded){
         assert.equal(project,'fixture');assert.equal(version,'version');assert.equal(stamp,probe.stamp())
         const state=V.decodeRuntimeValue(JSON.parse(encoded))

         persisted=encoded
         saves.push(Object.fromEntries([...state.fields].map(([key,value])=>[key,value.value])))
        }}
         const host=hostModule({store,Date:{now:()=>now},consent:options.consent,runRawIntent:(...args)=>platform('intent',...args),runSdkAdapter:(...args)=>platform('sdk',...args)},(action,args=[])=>{
          if(options.observe)options.observe(action,args)
         if(action!=='view'&&action!=='init'&&!action.startsWith('fixture'))calls.push({action,value:args[1] instanceof V.VeraObjectValue?args[1].fields:args[1].value,at:now})
        })
        const mocks={StageTrace,...host,...V,...loadVera('VeraGfx'),...loadVera('VeraStateStamp'),TextInputController,TouchType,SliderChangeMode,scheduleCardRefresh(){},runRawIntent:platform,runSdkAdapter:platform,toLive:L.toLive,reconcile:L.reconcile,markIconRoom:L.markIconRoom,armReveal:L.armReveal,catalogKinds:()=>[],Date:{now:()=>now},console:{info(){},warn(){},error(){}},setInterval(callback,interval){
        const handle=++nextHandle;intervals.set(handle,{callback,interval});return handle
       },clearInterval(handle){intervals.delete(handle)},setTimeout(callback,delay){
       assert.equal(delay,400)
       const handle=++nextHandle, timer={callback,at:now+delay}
       scheduled.set(handle,timer);history.set(handle,timer);return handle
      },clearTimeout(handle){scheduled.delete(handle)}}
       Object.assign(mocks,options.mocks||{})
        const {probe,VeraPreview:Probe}=createPreview({...host,mocks,askBeforeCalls:!!options.askBeforeCalls})
        const render=probe.renderView.bind(probe)
        let renderedRoot=null
        probe.renderView=(root=renderedRoot,...args)=>{renderedRoot=root;return render(root,...args)}
        probe.acceptEffects=effects=>injectEffects(probe,effects)
        probe.localEffectRequest=effect=>effectRequest(probe,effect)
       Object.assign(probe,{previewOnly:false,programId:0,revision:0,liveRoot:null,hasRoot:false,error:'',pending:null,darkListener:null,liveSurfaces:[],destinationHidden:false,pageHidden:false,persistKey:'fixture/version',seedState:'',controller,
          onStateSnapshot(encoded){observed=encoded;snapshots.push(encoded)},frameSplit:[0,0,0,0],textTimers:new Map(),
        stopAllTimers(){for(const id of [...this.timers.keys()])this.stopTimer(id)},retireWorlds(){},reconcileWorlds(){},worldsNeedFrames(){return false},tickWorlds(){},watchDarkMode(){},reconcileTheme(){},reconcileTimers(){},reconcileSpin(){},reconcileMotion(){},onBackHandlerChanged(){},reconcileSurfaces(){},paintSurfaces(){},paintSurface(){}})
       const frameProps={kind:'field',style:'default',label:'',action:'',keyboardType:'',required:false,requiredMessage:'',minLength:0,minLengthMessage:'',maxLength:-1,maxLengthMessage:'',pattern:'',patternMessage:'',email:false,emailMessage:'',enabled:true}
       const frameView=`class FixtureField { type: string; value: string; text: string; ${Object.entries(frameProps).filter(([key])=>key!=='kind').map(([key,value])=>key+': '+typeof value+';').join(' ')} }
class FixtureRoot { type: string; style: string; children: FixtureField[]; }
function fixtureView(state: AppState): FixtureRoot {
 let fields: FixtureField[] = []; let descriptor: string = state.note;
 if (strings.split(descriptor, "\\t")[0] !== "fixtureFrame") {
  descriptor = ${JSON.stringify(['fixtureFrame',...['setFirst','setSecond'].flatMap((action,index)=>Object.values({...frameProps,label:index===0?'First':'Second',action}))].join('\t'))};
 }
 let parts: string[] = strings.split(descriptor, "\\t"); let i: number = 1;
 while (i < parts.length()) {
  let value: string = state.first; if (i > 1) { value = state.second; }
  let action: string = parts[i + 3]; if (state.note === "normalize" && i === 1) { action = "normalize"; }
  fields.push({text: "", type: parts[i], style: parts[i + 1], label: parts[i + 2], value: value, action: action, keyboardType: parts[i + 4], required: parts[i + 5] === "true", requiredMessage: parts[i + 6], minLength: strings.toNumber(parts[i + 7], 0), minLengthMessage: parts[i + 8], maxLength: strings.toNumber(parts[i + 9], -1), maxLengthMessage: parts[i + 10], pattern: parts[i + 11], patternMessage: parts[i + 12], email: parts[i + 13] === "true", emailMessage: parts[i + 14], enabled: parts[i + 15] === "true"});
  i = i + ${Object.keys(frameProps).length};
 }
 if (state.note !== descriptor) {
  fields.push({type: "text", style: "body", text: state.note, value: "", ${Object.entries(frameProps).filter(([key])=>key!=='kind'&&key!=='style').map(([key,value])=>key+': '+JSON.stringify(value)).join(', ')}});
 }
 return {type: "column", style: "default", children: fields};
}`
       if(!fieldBytecode)fieldBytecode=C.compileVeraSource(`
import * as ui from "std/ui"
import * as strings from "std/strings"
@jsonable class AppState { first: string; second: string; note: string; saved: string; }
function fixtureNote(state: AppState, value: string): AppState { return {first: state.first, second: state.second, note: value, saved: state.saved}; }
function init(): AppState { return {first: "base", second: "other", note: "initial", saved: ""}; }
function fixtureFirst(state: AppState, value: string): AppState { return {first: value, second: state.second, note: state.note, saved: state.saved}; }
function setFirst(state: AppState, value: string): AppState { return {first: value, second: state.second, note: state.note, saved: state.saved}; }
function setSecond(state: AppState, value: string): AppState { return {first: state.first, second: value, note: state.note, saved: state.saved}; }
function normalize(state: AppState, value: string): AppState { return {first: "normalized", second: state.second, note: state.note, saved: state.saved}; }
function save(state: AppState, value: number): AppState { return {first: state.first, second: state.second, note: state.note, saved: state.first + "/" + state.second}; }
function toggle(state: AppState, value: boolean): AppState { return {first: state.first, second: state.second, note: state.note, saved: state.first + "/" + state.second}; }
${frameView}
function view(state: AppState): FixtureRoot { return fixtureView(state); }
`).vbc2
       if(sync&&!syncBytecode) {
        const shape={first:'string',second:'string',note:'string',saved:'string',position:'number',log:'string',x:'number',y:'number',id:'number',phase:'string'}
        const record=overrides=>'{'+Object.keys(shape).map(key=>key+': '+(overrides[key]||'state.'+key)).join(', ')+'}'
        const handler=(name,type,overrides)=>`function ${name}(state: AppState, value: ${type}): AppState { return ${record(overrides)}; }`
        syncBytecode=C.compileVeraSource(`
import * as ui from "std/ui"
import * as gfx from "std/gfx"
@jsonable class AppState { ${Object.entries(shape).map(([key,type])=>key+': '+type+';').join(' ')} }
function init(): AppState { return {first: "base", second: "other", note: "initial", saved: "", position: 0, log: "", x: 0, y: 0, id: 0, phase: ""}; }
${handler('fixtureFirst','string',{first:'value'})}
${handler('setFirst','string',{first:'value'})}
${handler('setSecond','string',{second:'value'})}
${handler('slide','number',{position:'value',saved:'state.first + "/" + state.second',log:'state.log + "s" + ui.numberToString(value) + ";"'})}
${handler('slideOther','number',{position:'value',log:'state.log + "o" + ui.numberToString(value) + ";"'})}
${handler('save','number',{saved:'state.first + "/" + state.second',log:'state.log + "save;"'})}
${handler('back','number',{saved:'state.first + "/" + state.second',log:'state.log + "back;"'})}
${handler('tick','number',{saved:'state.first + "/" + state.second',log:'state.log + "tick;"'})}
${['old','replacement','faster','readded','nestedTick','fast','oneTick','twoTick'].map(name=>handler(name,'number',{})).join('\n')}
${handler('answer1','string',{saved:'state.first + "/" + state.second',log:'state.log + value + ";"'})}
${handler('pointer','gfx.Pointer',{saved:'state.first + "/" + state.second',log:'state.log + value.phase + ui.numberToString(value.id) + ";"',x:'value.x',y:'value.y',id:'value.id',phase:'value.phase'})}
function draw(state: AppState): gfx.Shape[] { return []; }
function view(state: AppState): ui.View { return ui.Column("default", [ui.TextField("default", "First", state.first, "setFirst"), ui.TextField("default", "Second", state.second, "setSecond"), ui.Text("body", state.note), ui.Slider("default", "Slider", state.position, 0, 100, "slide"), ui.Slider("default", "Other", state.position, 0, 100, "slideOther"), ui.Surface("default", 100, 100, "draw", "", "pointer"), ui.BackHandler("back")]); }
`).vbc2
       }
         let inputApplied=()=>{}
         const appliedInputs=new WeakSet(), completeInput=probe.completeInput.bind(probe)
         probe.completeInput=()=>{
          const next=probe.inFlight
          if(next!==null&&!next.posting&&next.inputSeq>=0&&!appliedInputs.has(next)&&(probe.lastAppliedSeq>=next.inputSeq||probe.observedErrors.has(next.inputSeq))) {
           appliedInputs.add(next)
           inputApplied(next.action,next.payload)
          }
          completeInput()
         }
        const createSubscriber=probe.createSubscriber.bind(probe)

       probe.createSubscriber=generation=>{
        const subscriber=createSubscriber(generation), snapshot=subscriber.onStateSnapshot.bind(subscriber)
        subscriber.onStateSnapshot=encoded=>{observed=encoded;snapshot(encoded)}
        return subscriber
       }
probe.vbc2=options.bytecode||(sync?syncBytecode:fieldBytecode)
         for(const name of options.methods||[])probe[name]=Probe.prototype[name]
         if(options.setup)options.setup(probe)
         if(options.mount!==false) {
          probe.aboutToAppear()
          await settlePreview(probe)
          assert.equal(probe.error,'');assert(probe.handle)
          observed=await host.runtime.requestSnapshot(probe.handle)
         }
         snapshots.length=0
        const first=probe.liveRoot?.children[0], second=probe.liveRoot?.children[1]
       for(const node of [first,second].filter(node=>node?.kind==='field')) {
       let value=node.fieldValue
       Object.defineProperty(node,'fieldValue',{get:()=>value,set(next){writes.push([node,next]);value=next},configurable:true})
      }
async function advance(ms) {
        await settlePreview(probe)
        const end=now+ms
       while(true) {
        const entry=[...scheduled].filter(([,timer])=>timer.at<=end).sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0]
        if(!entry)break
        const [handle,timer]=entry
        now=timer.at;scheduled.delete(handle);timer.callback();await settlePreview(probe)
       }
now=end
        await settlePreview(probe)
       }

       async function reload() { probe.vbc2+=' ';probe.load();await settlePreview(probe) }
        async function frame(overrides=[{},{}]) {
         const parts=['fixtureFrame',...overrides.flatMap((override,index)=>Object.values({...frameProps,action:index===0?'setFirst':'setSecond',...override}))]
          await inject('fixtureNote',parts.join('\t'))
      }
       function native(node=first,generation=node.fieldGeneration) {
        const controller=probe.fieldController(node,generation), submit=probe.nativeSubmit(node,generation), edit=probe.nativeEditChange(node,generation)
        return {controller,submit(text){submit(0,{text})},edit,blur(text){controller.text=text;edit(false)}}
       }
           async function inject(action,value) {
            const admission=host.runtime.postInput(probe.handle,{appId:probe.frameAppId,vmGeneration:probe.frameVmGeneration,kind:'HANDLER',action,payload:{kind:'STRING',num:0,str:value,bool:false,phase:'',id:0,x:0,y:0},persist:false,draws:[]})
            assert.equal(admission.status,'ACCEPTED')
            await settlePreview(probe)
            assert.equal(probe.error,'')
           }
          async function external(overrides) {
           for(const [key,value] of Object.entries(overrides))await inject(key==='note'?'fixtureNote':'fixtureFirst',value)
          }
        const slider=probe.liveRoot?.children[3], otherSlider=probe.liveRoot?.children[4], surface=probe.liveRoot?.children[5]
       if(sync)probe.surfaces.set(surface,{width:400,height:200})
       return {probe,runtime:host.runtime,first,second,slider,otherSlider,surface,scheduled,history,intervals,replies,calls,writes,saves,snapshots,advance,reload,frame,native,external,onInputApplied(callback){inputApplied=callback},elapse(ms){now+=ms},async setPersistence(key){probe.persistKey=key;probe.load();await settlePreview(probe);snapshots.length=0},async snapshot(){observed=await host.runtime.requestSnapshot(probe.handle);return observed},settle:()=>settlePreview(probe),dispose:()=>host.runtime.dispose(),
         remove(node){probe.liveGeneration++;probe.liveRoot.children=probe.liveRoot.children.filter(child=>child!==node);probe.markLiveNodeGeneration(probe.liveRoot)},
        slide(value,mode='Moving',node=slider){probe.sliderChange(node)(value,SliderChangeMode[mode])},
        touch(phase,touches=[{id:1,x:150,y:50}],node=surface){probe.surfaceTouch(node,{type:TouchType[phase],changedTouches:touches})},
        reconcile(node,overrides){const next=Object.assign(new U.VeraUiNode(),node,overrides);probe.liveGeneration++;L.reconcile(node,next);probe.markLiveNodeGeneration(probe.liveRoot);probe.reconcileFields()},
        change(node,value,composing=false,generation=node.fieldGeneration){if(runtimeMode)probe.nativeChange(node,generation)(value,composing?{value}:undefined);else probe.changeField(node,generation,value,composing)},finish(node,generation=node.fieldGeneration){probe.finishField(node,generation)},fire(handle){assert(history.has(handle));history.get(handle).callback()},state(name){return V.decodeRuntimeValue(JSON.parse(observed)).fields.get(name).value}}
     }
      if(runtimeMode) {
       await test('runtime traces: fast ticker preserves pending debounce', async () => {
        const f=await fieldProbe(true), {probe}=f
        probe.startTimer('fixture-fast',{interval:16,action:'tick'})
        const callback=f.intervals.get(probe.timers.get('fixture-fast')).callback
        f.change(f.first,'pending');const timer=probe.fieldEdits.get(f.first).timer
        await f.advance(16);callback()
        assert.deepEqual(f.calls,[]);assert.equal(probe.timerLastFire.get('fixture-fast'),0)
        assert.equal(probe.fieldEdits.get(f.first).timer,timer);assert.equal(f.scheduled.get(timer).at,400)
        await f.advance(383);callback();assert.deepEqual(f.calls,[])
        await f.advance(1);assert.deepEqual(f.calls,[{action:'setFirst',value:'pending',at:400}])
         callback();await f.settle()
         assert.deepEqual(f.calls,[{action:'setFirst',value:'pending',at:400},{action:'tick',value:400,at:400}])
        assert.equal(f.state('saved'),'pending/other');assert.equal(f.saves.length,2)
        probe.stopTimer('fixture-fast');f.fire(timer);await f.advance(400)
        assert.equal(f.calls.length,2);assert.equal(probe.fieldEdits.size,0);assert.equal(probe.error,'')
       })
       await test('runtime traces: pointer down/move/up after pending edit', async () => {
        const f=await fieldProbe(true), {probe}=f
        f.change(f.first,'pending');const timer=probe.fieldEdits.get(f.first).timer
        await f.advance(17);f.touch('Down');f.touch('Move',[{id:1,x:280,y:180}]);f.touch('Up');await f.settle()
        assert.deepEqual(f.calls.map(call=>call.action),['setFirst','pointer','pointer','pointer'])
        assert.equal(f.state('log'),'down1;move1;up1;');assert.equal(f.state('saved'),'pending/other')
        assert.deepEqual(f.saves.map(state=>state.phase),['','down','up'])
        assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.fieldEdits.size,0)
        f.fire(timer);await f.advance(1000);assert.equal(f.calls.length,4);assert.equal(f.saves.length,3);assert.equal(probe.error,'')
       })
       await test('runtime traces: stale field dependency cancels queued slider', async () => {
        const f=await fieldProbe(true), {probe,first}=f, native=f.native(), generation=first.fieldGeneration
        f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
        f.change(first,'composition',true);f.slide(10,'Begin');f.slide(30,'End')
        assert.deepEqual(f.calls,[]);assert.equal(probe.fieldActions.length,1)
        const queued=probe.fieldActions[0], cancellation=first.fieldCancellation
        assert(queued.dependencies.includes(first))
        await f.external({first:'external'})
        assert(first.fieldCancellation>cancellation);assert(first.fieldGeneration>generation)
        assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[])
        probe.enqueueFieldAction(queued)
        native.submit('stale');native.blur('stale');f.fire(timer);probe.resumeFieldActions();await f.advance(400)
        assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(native.controller.reads,0)
        f.change(first,'fresh');await f.advance(400)
        assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:800}])
        assert.equal(f.state('position'),0);assert.equal(f.state('saved'),'');assert.equal(f.saves.length,1)
        assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
       })
      }
       function generateFieldHost(controller,structural=false) {
        const source=fs.readFileSync(path.join(sourceRoot,'pages/GeneratePage.ets'),'utf8')
        const methods=['doRefine','setFullscreen','previewSnapshot','startNew','restoreBase'].map(name=>declaration(source,'  private '+(['doRefine','setFullscreen'].includes(name)?'async ':'')+name+'(').replace('  private ','')).join('\n')
        const code=ts.transpileModule('class Probe { '+methods+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
        assert.equal((code.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,'Generate field host syntax')
        const events=[], mocks={WIDGET_ASK:'widget: ',MODE_DEEPSEEK:'cloud',TAB_PREVIEW:'preview',templateSelectEnabled:()=>true,settings:{hasSelector:()=>true},VeraPreviewController:controller.constructor,VersionMetrics:loadVera('ProjectStore').VersionMetrics}
        const Probe=new Function(...Object.keys(mocks),code.outputText+';return Probe')(...Object.values(mocks)), host=new Probe()
        Object.assign(host,{previewController:controller,disposed:false,refinePrompt:'  keep the draft  ',compiledSource:'fixture',generating:false,baseError:'',makeWidget:false,compositionJson:structural?'record':'',mode:'cloud',liveState:'stale snapshot',carriedState:'previous carry',cornerHidden:true,tab:'source',composerHidden:true,fullscreen:false,snapshotting:false,snapshotRequestId:0,runId:1,projectId:'fixture',baseVersionId:'version',compiledVbc2:'fixture',
         refineWithModel(ask){events.push(['model',ask,this.carriedState])},tryStructuralEdit(ask){events.push(['structural',ask,this.carriedState])}})
         host.versionCount=()=>3
         return {host,events,onStateSnapshot:host.previewSnapshot(controller)}
       }
        function chatFieldHost() {
         const source=fs.readFileSync(path.join(sourceRoot,'pages/ChatPage.ets'),'utf8')
         const methods=['isPageActive','isRunActive','createRun','releaseRunIfIdle','cancelActiveRuns','stopChat','flushReferenceFields','referenceSnapshots','history','apply','startWidget','queueBuild'].map(name=>declaration(source,'  private '+(name==='flushReferenceFields'?'async ':'')+name+'(').replace('  private ',''))
         methods.push(declaration(source,'  private async send(').replace('  private ',''),declaration(source,'  aboutToDisappear('))
         const constants=source.match(/^const APP_\w+:[^\n]+/gm).join('\n')
         const bubble=declaration(source,'  private snapshotHandler(').replace('  private ','')
         const code=ts.transpileModule(constants+'\n'+declaration(source,'class ChatMessage')+'\n'+declaration(source,'class ChatRunContext')+'\nclass Host { '+methods.join('\n')+' }\nclass Bubble { '+bubble+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
         assert.equal((code.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,'Chat field host syntax')
         const requests=[], builds=[], snapshots=[], events=[], chat=loadVera('VeraChat')
         let capabilities=async()=>{}, reply='<<app: '+JSON.stringify({description:'Updated fields',mode:'refine',targetMessageId:2})+'>>'
         const mocks={...chat,...loadVera('VeraChatStats'),...loadVera('VeraWidgetContext'),VeraPreviewController:previewController().constructor,
          ensureCapabilities:()=>capabilities(),logMark(){},logStep(){},console:{info(){}},RouteRequest:class {},OUTCOME_AGENT:'agent',OUTCOME_NOT_BUILT:'not-built',
          appAgentHost:()=>({}),buildScreen:async()=>({kind:'fallback',agent:null}),buildMiniApp:async(_skill,context)=>{
           builds.push({...context});return Object.assign(new chat.MiniApp(),{source:'fresh source',vbc2:fieldBytecode,error:''})
          },chatReply:async(turns,onText,_status,_stats,_verified,run)=>{requests.push({turns,run});onText(reply);return reply}}
         const {Host,Bubble,ChatMessage}=new Function(...Object.keys(mocks),code.outputText+';return {Host,Bubble,ChatMessage}')(...Object.values(mocks)), host=new Host()
         Object.assign(host,{messages:[],draft:'  update the fields  ',busy:false,canStop:false,status:'idle',title:'',nextId:10,nextRunId:1,lifecycleGeneration:1,disposed:false,activeRuns:[],buildQueue:Promise.resolve(),resourcesLoaded:true,skillPrompt:'fixture',hostContext:()=>({}),scrollDown(){},persist(){},loadResources:async()=>{}})
         for(const name of ['createRun','referenceSnapshots']) {
          const method=host[name]
          host[name]=function(...args) { events.push(name);const value=method.apply(this,args);if(name==='referenceSnapshots')snapshots.push(value);return value }
         }
         return {host,requests,builds,snapshots,events,ChatMessage,
          waitForCapabilities(action){capabilities=action},reply(text){reply=text},
          message(id,role='assistant',appState='ready') {
           const msg=Object.assign(new ChatMessage(),{id,role,appState,source:'source '+id,originalRequest:'request '+id,appDescription:'fields '+id,latestState:'stale '+id})
           host.messages.push(msg);return msg
          },
           async bind(msg) {
           const f=await fieldProbe(false,msg.previewController), bubble=new Bubble();bubble.msg=msg
           await f.setPersistence('');f.probe.onStateSnapshot=bubble.snapshotHandler(msg.previewGeneration)
           return {...f,snapshotHandler:generation=>bubble.snapshotHandler(generation)}
          }}
        }
        await test('chat fields: each message owns a distinct controller wired to its bubble without state migration', async () => {
         const f=chatFieldHost(), a=f.message(2), b=f.message(4), user=f.message(6,'user')
         assert.notEqual(a.previewController,b.previewController);assert.notEqual(a.previewController,user.previewController)
         assert.equal(new f.ChatMessage().latestState,'')
         const source=fs.readFileSync(path.join(sourceRoot,'pages/ChatPage.ets'),'utf8'), bubble=declaration(source,'struct MessageBubble')
         assert.match(source,/import\s*\{[^}]*\bVeraPreviewController\b[^}]*\}\s*from '\.\.\/components\/VeraPreview'/)
         const previews=[...bubble.matchAll(/\bVeraPreview\(\{/g)].map(call=>declaration(bubble.slice(call.index),'VeraPreview('))
         assert.equal(previews.length,1)
         assert.match(previews[0],/controller:\s*this\.msg\.previewController\b/)
         assert.match(previews[0],/onStateSnapshot:\s*this\.snapshotHandler\(this\.msg\.previewGeneration\)/)
         assert(!/\bseedState\s*:/.test(previews[0]))
         const old=await f.bind(a), fresh=await f.bind(b)
         old.change(old.first,'old message draft');assert.equal(await a.previewController.flushAndSnapshot(),await old.snapshot())
         assert.equal(old.state('first'),'old message draft');assert.equal(fresh.state('first'),'base');assert.deepEqual(fresh.calls,[])
         assert.equal(b.latestState,'stale 4');assert.equal(old.probe.error,'');assert.equal(fresh.probe.error,'')
        })
        for(const elapsed of [0,17,399]) await testAsync(`chat fields: send at ${elapsed}ms captures all ready-message drafts as scalar references before capability wait`, async () => {
         const f=chatFieldHost(), {host}=f, a=f.message(2), b=f.message(4), first=await f.bind(a), second=await f.bind(b)
         let release
         f.waitForCapabilities(()=>new Promise(resolve=>{release=resolve}))
         first.change(first.first,'superseded');first.change(first.first,'latest first');first.change(first.second,'latest sibling')
         second.change(second.first,'second message');second.change(second.second,'')
         const timers=[...first.history.keys()], otherTimers=[...second.history.keys()]
          await first.advance(elapsed);await second.advance(elapsed)
         assert.deepEqual(first.calls,[]);assert.deepEqual(second.calls,[]);assert.equal(a.latestState,'stale 2');assert.equal(b.latestState,'stale 4')
          const sending=host.send()
          await pause()
          const references=f.snapshots[0]
          assert.deepEqual(f.events,['createRun','referenceSnapshots']);assert.equal(host.busy,true);assert.equal(host.draft,'');assert.equal(f.requests.length,0)
         assert.deepEqual(references.map(ref=>ref.messageId),[2,4])
         for(const [index,values,probe] of [[0,['latest first','latest sibling'],first],[1,['second message',''],second]]) {
          const ref=references[index], state=V.decodeRuntimeValue(JSON.parse(ref.latestState))
          assert.deepEqual([state.fields.get('first').value,state.fields.get('second').value],values)
          assert.deepEqual(Object.keys(ref).sort(),['brief','latestState','messageId','originalRequest','source'])
          assert(Object.values(ref).every(value=>['string','number'].includes(typeof value)))
          assert.deepEqual(probe.calls.map(call=>[call.action,call.value,call.at]),[['setFirst',values[0],elapsed],['setSecond',values[1],elapsed]])
          assert.equal(probe.scheduled.size,0);assert.deepEqual(probe.saves,[])
         }
         const captured=JSON.parse(JSON.stringify(references))
         a.source='later source';a.originalRequest='later request';a.appDescription='later brief'
          first.change(first.first,'after send');await a.previewController.flushAndSnapshot()
          second.change(second.first,'later second');await b.previewController.flushAndSnapshot()
         assert.deepEqual(JSON.parse(JSON.stringify(references)),captured)
         release();await sending;await host.buildQueue
         assert.equal(f.requests.length,1);assert.equal(f.builds.length,1)
         assert.equal(f.builds[0].source,captured[0].source);assert.equal(f.builds[0].latestState,captured[0].latestState);assert.equal(f.builds[0].originalRequest,captured[0].originalRequest)
         const revision=host.messages.at(-1)
         assert.equal(revision.appState,'ready');assert.equal(revision.parentMessageId,2);assert.equal(revision.latestState,'');assert.notEqual(revision.previewController,a.previewController)
         const fresh=await f.bind(revision)
         assert.equal(fresh.state('first'),'base');assert.equal(fresh.state('second'),'other');assert.deepEqual(fresh.calls,[])
         for(const timer of timers)first.fire(timer);for(const timer of otherTimers)second.fire(timer)
          await first.advance(1000);await second.advance(1000)
         assert.equal(first.calls.length,3);assert.equal(second.calls.length,3);assert.deepEqual(JSON.parse(JSON.stringify(references)),captured)
         assert.equal(host.busy,false);assert.equal(host.canStop,false);assert.deepEqual(host.activeRuns,[])
        })
         for(const [role,state] of [['assistant','building'],['assistant','failed'],['assistant','describing'],['assistant','none'],['user','ready']]) await testAsync(`chat fields: send skips ${role}/${state} controller`, async () => {
          const f=chatFieldHost(), eligible=f.message(2), ready=await f.bind(eligible), msg=f.message(4,role,state), probe=await f.bind(msg)
          probe.change(probe.first,'unfinished composition',true)
          msg.previewController.flushAndSnapshot=()=>assert.fail('ineligible controller flushed: '+role+'/'+state)
          ready.change(ready.first,'eligible draft');await f.host.send();await f.host.buildQueue
          assert.equal(f.requests.length,1);assert.deepEqual(f.snapshots[0].map(ref=>ref.messageId),[2])
          assert.equal(V.decodeRuntimeValue(JSON.parse(f.builds[0].latestState)).fields.get('first').value,'eligible draft')
          assert.equal(msg.latestState,'stale '+msg.id);assert.deepEqual(probe.calls,[]);assert.equal(probe.state('first'),'base')
          assert.equal(probe.probe.fieldEdits.get(probe.first).composing,true)
         })
         for(const event of ['submit','blur']) await testAsync(`chat fields: IME send waits for native ${event} before capturing references`, async () => {
          const f=chatFieldHost(), {host}=f, msg=f.message(2), composing=await f.bind(msg), later=f.message(4), sibling=await f.bind(later), native=composing.native()
          composing.change(composing.first,'n');const timer=composing.probe.fieldEdits.get(composing.first).timer
          composing.change(composing.first,'ni',true);sibling.change(sibling.first,'latest sibling')
          const edit=composing.probe.fieldEdits.get(composing.first), messages=host.messages, count=messages.length
           let settled=false
           const sending=host.send().finally(()=>{settled=true})
           await pause();composing.fire(timer);composing.elapse(1000);await pause()
           assert.equal(settled,false)
          assert.equal(host.draft,'  update the fields  ');assert.equal(host.messages,messages);assert.equal(messages.length,count)
          assert.deepEqual(f.requests,[]);assert.deepEqual(f.builds,[])
          assert.deepEqual(composing.calls,[]);assert.deepEqual(sibling.calls,[]);assert.equal(composing.probe.fieldEdits.get(composing.first),edit);assert.equal(edit.composing,true)
          assert.equal(msg.latestState,'stale 2');assert.equal(later.latestState,'stale 4')
          native[event]('你好')
          await sending;await host.buildQueue;await composing.snapshot()
          assert.equal(composing.state('first'),'你好');assert.equal(f.requests.length,1);assert.equal(host.draft,'');assert.equal(host.messages.length,count+2);assert.equal(host.nextRunId,2)
          assert.equal(V.decodeRuntimeValue(JSON.parse(f.snapshots[0][0].latestState)).fields.get('first').value,'你好')
          assert.equal(V.decodeRuntimeValue(JSON.parse(f.snapshots[0][1].latestState)).fields.get('first').value,'latest sibling')
          assert.equal(f.builds[0].latestState,f.snapshots[0][0].latestState);assert.equal(host.messages.at(-1).latestState,'')
          composing.fire(timer);await composing.advance(1000);assert.equal(composing.calls.length,1);assert.equal(sibling.calls.length,1);assert.equal(host.busy,false)
         })
        await testAsync('chat fields: disposal during controller capture prevents run creation and draft clearing', async () => {
         const f=chatFieldHost(), msg=f.message(2), probe=await f.bind(msg), capture=probe.probe.onStateSnapshot, messages=f.host.messages
         probe.change(probe.first,'departing draft')
          const count=messages.length, generation=f.host.lifecycleGeneration, previewGeneration=msg.previewGeneration
          probe.probe.onStateSnapshot=encoded=>{capture(encoded);f.host.aboutToDisappear()}
          await f.host.send();await f.host.buildQueue
          assert.equal(probe.state('first'),'departing draft');assert.equal(f.host.disposed,true);assert.equal(f.host.draft,'  update the fields  ')
          assert.equal(f.host.lifecycleGeneration,generation+1);assert.equal(msg.previewGeneration,previewGeneration+1)
          assert.equal(f.host.messages,messages);assert.equal(messages.length,count);assert.equal(f.host.nextRunId,2);assert.deepEqual(f.host.activeRuns,[])
           assert.deepEqual(f.events,['createRun','referenceSnapshots']);assert.deepEqual(f.requests,[]);assert.deepEqual(f.builds,[])
           assert.deepEqual(f.snapshots.map(refs=>refs.map(ref=>({messageId:ref.messageId,source:ref.source,latestState:ref.latestState}))),[[{messageId:2,source:'source 2',latestState:'stale 2'}]])
        })
        for(const transition of ['stop','disappear']) await test('chat fields: '+transition+' keeps stale snapshot generation fences intact', async () => {
         const f=chatFieldHost(), msg=f.message(2), probe=await f.bind(msg), callback=probe.probe.onStateSnapshot
         callback('current snapshot');assert.equal(msg.latestState,'current snapshot')
         probe.change(probe.first,'late draft');await probe.advance(399)
         const generation=msg.previewGeneration
         if(transition==='stop') { msg.appState='building';f.host.createRun();f.host.stopChat() } else f.host.aboutToDisappear()
         assert(msg.previewGeneration>generation)
         probe.probe.aboutToDisappear();await probe.settle();callback('stale snapshot')
         assert.equal(probe.state('first'),'late draft');assert.equal(msg.latestState,'current snapshot')
         probe.snapshotHandler(msg.previewGeneration)('fresh generation');assert.equal(msg.latestState,'fresh generation')
         callback('stale again');assert.equal(msg.latestState,'fresh generation')
        })
        await test('field lifecycle: controller and snapshot callbacks wire both interactive Generate previews', async () => {
        const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
        const source=fs.readFileSync(path.join(sourceRoot,'pages/GeneratePage.ets'),'utf8')
        assert.match(renderer,/export class VeraPreviewController\b/)
        assert.match(renderer,/^  controller: VeraPreviewController \| null = null$/m)
        assert.match(source,/private previewController: VeraPreviewController = new VeraPreviewController\(\)/)
        const previews=[...source.matchAll(/\bVeraPreview\(\{/g)].map(call=>declaration(source.slice(call.index),'VeraPreview(')).filter(call=>!/previewOnly:\s*true\b/.test(call))
        assert.equal(previews.length,2)
        for(const preview of previews) {
         assert.match(preview,/controller:\s*this\.previewController\b/)
         assert.match(preview,/seedState:\s*this\.carriedState\b/)
         assert.match(preview,/onStateSnapshot:\s*this\.previewSnapshot\(this\.previewController\)/)
        }
        const appear=declaration(renderer,'  aboutToAppear('), disappear=declaration(renderer,'  aboutToDisappear(')
        assert(appear.indexOf('this.load()')<appear.indexOf('this.controller!.attach(this.captureFields)'))
         const order=['this.controller!.detach(this.captureFields)','this.disposed = true','this.detachDrainTree()','await this.flushPendingInputFor(this.frameAppId)','this.invalidateEffects()'].map(part=>disappear.indexOf(part))
        assert(order.every(index=>index>=0));assert.deepEqual(order,[...order].sort((a,b)=>a-b))
       })
       for(const elapsed of [0,17,399]) for(const value of ['latest text','']) await test(`field lifecycle: disappear at ${elapsed}ms preserves ${JSON.stringify(value)} in VM and persistence without forwarding disposed snapshots`, async () => {
        const controller=previewController(), f=await fieldProbe(false,controller), {probe,first}=f, native=f.native()
        f.change(first,'superseded');f.change(first,value);const timers=[...f.history.keys()]
        await f.advance(elapsed);assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.deepEqual(f.snapshots,[])
        const states=[]
        probe.onStateSnapshot=encoded=>{assert.equal(probe.disposed,false);states.push(encoded);f.snapshots.push(encoded)}
        probe.aboutToDisappear();await settlePreview(probe)
        assert.equal(f.state('first'),value);assert.equal(probe.disposed,true);assert.equal(probe.fieldEdits.size,0);assert.equal(probe.fieldInputs.size,0);assert.equal(f.scheduled.size,0)
        assert.deepEqual(f.calls,[{action:'setFirst',value,at:elapsed}]);assert.equal(f.saves.length,1);assert.equal(f.saves[0].first,value)
         assert.equal(states.length,0)
         const snapshots=[...f.snapshots]
         await assert.rejects(controller.flushAndSnapshot(),/Preview is not attached/)
        native.submit('late');native.blur('late');for(const timer of timers)f.fire(timer);await f.advance(1000)
        assert.equal(native.controller.reads,0);assert.equal(f.calls.length,1);assert.equal(f.saves.length,1);assert.deepEqual(f.snapshots,snapshots);assert.equal(probe.error,'')
       })
       await test('field lifecycle: disappear commits native composition and pending sibling before release', async () => {
        const f=await fieldProbe(false,previewController()), {probe,first,second}=f, native=f.native()
        f.change(first,'n');const timer=probe.fieldEdits.get(first).timer
        f.change(first,'ni',true)
        f.change(second,'latest sibling');const sibling=probe.fieldEdits.get(second).timer
         native.controller.text='你好'
         await f.advance(37);probe.aboutToDisappear();await settlePreview(probe)
         assert.deepEqual(f.calls,[{action:'setFirst',value:'你好',at:37},{action:'setSecond',value:'latest sibling',at:37}]);assert.equal(f.state('first'),'你好');assert.equal(f.state('second'),'latest sibling');assert.equal(f.state('saved'),'')
         assert.equal(f.saves.length,2);assert.equal(f.saves.at(-1).first,'你好');assert.equal(f.saves.at(-1).second,'latest sibling');assert.equal(f.saves.at(-1).saved,'')
         assert.equal(f.snapshots.length,0);assert.equal(native.controller.reads,1)
        assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.scheduled.size,0)
        native.submit('你好');native.blur('你好');f.fire(timer);f.fire(sibling);probe.resumeFieldActions();await f.advance(1000)
         assert.equal(f.calls.length,2);assert.equal(f.saves.length,2);assert.equal(f.snapshots.length,0);assert.equal(native.controller.reads,1);assert.equal(probe.error,'')
       })
       for(const transition of ['refine','structural-refine','fullscreen-on','fullscreen-off']) await test('field lifecycle: controller captures latest text before '+transition+' carries state', async () => {
        const controller=previewController(), f=await fieldProbe(false,controller), {probe}=f, parent=generateFieldHost(controller,transition==='structural-refine'), {host}=parent
        await f.setPersistence('');probe.onStateSnapshot=encoded=>{f.snapshots.push(encoded);parent.onStateSnapshot(encoded)}
        host.fullscreen=transition==='fullscreen-off'
        f.change(f.first,'old');await f.advance(31);f.change(f.first,'latest text');f.change(f.second,'latest second');const timers=[...f.history.keys()]
        await f.advance(17);assert.equal(host.liveState,'stale snapshot');assert.equal(host.carriedState,'previous carry');assert.deepEqual(f.calls,[])
        let captured=false
         const capture=controller.flushAndSnapshot.bind(controller)
         controller.flushAndSnapshot=async()=>{const encoded=await capture();captured=V.decodeRuntimeValue(JSON.parse(encoded)).fields.get('second').value==='latest second';return encoded}
        let carried=host.carriedState
        Object.defineProperty(host,'carriedState',{get:()=>carried,set(value){assert(captured,'capture before carry');assert.equal(value,host.liveState);carried=value}})
         if(transition.endsWith('refine'))await host.doRefine();else await host.setFullscreen(transition==='fullscreen-on')
        assert.deepEqual(f.calls,[{action:'setFirst',value:'latest text',at:48},{action:'setSecond',value:'latest second',at:48}]);assert.deepEqual(f.saves,[])
        const restored=V.decodeRuntimeValue(JSON.parse(host.carriedState))
        assert.equal(restored.fields.get('first').value,'latest text');assert.equal(restored.fields.get('second').value,'latest second');assert.equal(host.carriedState,host.liveState)
        if(transition.endsWith('refine'))assert.deepEqual(parent.events,[[transition==='structural-refine'?'structural':'model','keep the draft',host.carriedState]])
        else { assert.equal(host.fullscreen,transition==='fullscreen-on');assert.equal(host.tab,'preview');assert.equal(host.composerHidden,false);assert.deepEqual(parent.events,[]) }
        const snapshots=f.snapshots.length
        probe.aboutToDisappear();await settlePreview(probe);for(const timer of timers)f.fire(timer);await f.advance(1000)
        assert.equal(f.calls.length,2);assert.equal(f.snapshots.length,snapshots);assert.deepEqual(f.saves,[]);assert.equal(probe.error,'')
       })
       for(const transition of ['refine','structural-refine','fullscreen-on','fullscreen-off']) await test('field lifecycle: composition blocks '+transition+' until native completion', async () => {
        const controller=previewController(), f=await fieldProbe(false,controller), {probe}=f, parent=generateFieldHost(controller,transition==='structural-refine'), {host}=parent, native=f.native()
        let snapshots=0
         probe.onStateSnapshot=encoded=>{snapshots++;parent.onStateSnapshot(encoded)};host.fullscreen=transition==='fullscreen-off'
        const invoke=()=>transition.endsWith('refine')?host.doRefine():host.setFullscreen(transition==='fullscreen-on')
        f.change(f.first,'n');const timer=probe.fieldEdits.get(f.first).timer
        f.change(f.first,'ni',true);const edit=probe.fieldEdits.get(f.first)

          let settled=false
          const pending=invoke().finally(()=>{settled=true}), duplicate=invoke()
          f.fire(timer);f.elapse(1000);await pause()
          assert.equal(settled,false)
        assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(snapshots,0);assert.equal(host.liveState,'stale snapshot');assert.equal(host.carriedState,'previous carry')
        assert.equal(host.fullscreen,transition==='fullscreen-off');assert.equal(host.tab,'source');assert.equal(host.composerHidden,true);assert.deepEqual(parent.events,[])
        assert.equal(probe.fieldEdits.get(f.first),edit);assert.equal(edit.composing,true);assert.deepEqual(probe.fieldActions,[])
         native.submit('你好')
          await pending;await duplicate;const snapshot=await f.snapshot()
          assert.equal(V.decodeRuntimeValue(JSON.parse(snapshot)).fields.get('first').value,'你好');assert.equal(f.state('first'),'你好')
         assert.equal(V.decodeRuntimeValue(JSON.parse(host.carriedState)).fields.get('first').value,'你好');assert.equal(host.carriedState,host.liveState)
        if(transition.endsWith('refine'))assert.equal(parent.events.length,1);else assert.equal(host.fullscreen,transition==='fullscreen-on')
         assert.equal(snapshots,1);assert.deepEqual(f.calls,[{action:'setFirst',value:'你好',at:1000}]);assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),[['你好','other','']])
        f.fire(timer);await f.advance(1000);assert.equal(f.calls.length,1);assert.equal(f.saves.length,1);assert.equal(probe.error,'')
       })
        for(const transition of ['startNew','restoreBase']) await test('field lifecycle: '+transition+' rotates snapshot identity before old disappearing draft can seed a new preview', async () => {
         const controller=previewController(), parent=generateFieldHost(controller), {host}=parent, old=await fieldProbe(false,controller)
         await old.setPersistence('');old.probe.onStateSnapshot=parent.onStateSnapshot
         old.change(old.first,'departing draft');const timer=old.probe.fieldEdits.get(old.first).timer
         await old.advance(399);assert.deepEqual(old.calls,[])
         let live=host.liveState, clears=0
         Object.defineProperty(host,'liveState',{get:()=>live,set(value){if(value===''){assert.notEqual(host.previewController,controller,'rotate before clearing live state');clears++}live=value}})
         const base={compiledSource:'',compiledVbc2:'',compositionJson:'',templateKinds:[],requestHistory:'',acceptedRequest:'',acceptedComposition:'',acceptedOrigin:'',acceptedMetrics:null,modelWrote:false,before:null}
         if(transition==='startNew')host.startNew();else host.restoreBase(base)
         assert.equal(clears,1);assert.notEqual(host.previewController,controller);assert.equal(host.liveState,'');assert.equal(host.carriedState,'');assert.equal(host.compiledSource,'');assert.equal(host.compiledVbc2,'')
         old.probe.aboutToDisappear();await old.settle()
         assert.deepEqual(old.calls,[{action:'setFirst',value:'departing draft',at:399}]);assert.equal(old.state('first'),'departing draft');assert.deepEqual(old.saves,[])
         assert.equal(host.liveState,'');assert.equal(host.carriedState,'')
         await host.setFullscreen(true);assert.equal(host.liveState,'');assert.equal(host.carriedState,'')
         const current=await fieldProbe(false,host.previewController), callback=host.previewSnapshot(host.previewController)
         await current.setPersistence('');current.probe.onStateSnapshot=callback
         current.change(current.first,'current draft');assert.equal(await host.previewController.flushAndSnapshot(),await current.snapshot())
         const accepted=host.liveState
         assert.equal(V.decodeRuntimeValue(JSON.parse(accepted)).fields.get('first').value,'current draft')
         parent.onStateSnapshot('stale after current');old.fire(timer);await old.advance(1000)
         assert.equal(host.liveState,accepted);assert.equal(old.calls.length,1)
         await host.setFullscreen(false);assert.equal(host.carriedState,accepted)
         host.disposed=true;callback('disposed current');parent.onStateSnapshot('disposed old')
         assert.equal(host.liveState,accepted);assert.equal(host.carriedState,accepted)
         host.disposed=false;callback('active current');assert.equal(host.liveState,'active current')
         parent.onStateSnapshot('late old');assert.equal(host.liveState,'active current');assert.equal(host.carriedState,accepted)
         assert.equal(old.probe.error,'');assert.equal(current.probe.error,'')
        })
        await test('field lifecycle: restoring a compiled base retains current snapshot identity and rejects disposed callbacks', async () => {
         const controller=previewController(), {host,onStateSnapshot}=generateFieldHost(controller)
         host.restoreBase({compiledSource:'restored source',compiledVbc2:'restored bytecode',compositionJson:'',templateKinds:[],requestHistory:'',acceptedRequest:'',acceptedComposition:'',acceptedOrigin:'',acceptedMetrics:null,modelWrote:false,before:null})
         assert.equal(host.previewController,controller);assert.equal(host.liveState,'stale snapshot');assert.equal(host.carriedState,'previous carry')
         onStateSnapshot('restored current');assert.equal(host.liveState,'restored current')
         host.disposed=true;onStateSnapshot('disposed current');assert.equal(host.liveState,'restored current')
         host.disposed=false;onStateSnapshot('active again');assert.equal(host.liveState,'active again');assert.equal(host.carriedState,'previous carry')
        })
        await test('field lifecycle: detached controller rejects without capturing the departed preview', async () => {
         const controller=previewController();await assert.rejects(controller.flushAndSnapshot(),/Preview is not attached/)
         const f=await fieldProbe(false,controller)
         assert.equal(await controller.flushAndSnapshot(),await f.snapshot());assert.equal(f.snapshots.length,0)
         f.probe.aboutToDisappear();await f.settle();await f.settle();const snapshots=f.snapshots.length
         await assert.rejects(controller.flushAndSnapshot(),/Preview is not attached/);assert.equal(f.snapshots.length,snapshots);assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[])
         await f.dispose()
       })
       await test('field lifecycle: old instance detach cannot detach newly attached preview', async () => {
        const controller=previewController(), old=await fieldProbe(false,controller), fresh=await fieldProbe(false,controller)
        old.change(old.first,'old pending');fresh.change(fresh.first,'new latest')
        const oldTimer=old.probe.fieldEdits.get(old.first).timer, newTimer=fresh.probe.fieldEdits.get(fresh.first).timer
        old.probe.aboutToDisappear();await old.settle();assert.equal(old.state('first'),'old pending');assert.equal(fresh.calls.length,0)
         assert.equal(await controller.flushAndSnapshot(),await fresh.snapshot());assert.equal(fresh.state('first'),'new latest');assert.equal(fresh.calls.length,1);assert.equal(fresh.saves.length,1);assert.equal(old.calls.length,1)
         assert.equal(fresh.snapshots.length,1);assert.equal(old.snapshots.length,0)
         old.probe.aboutToDisappear();await old.settle();fresh.change(fresh.first,'newer');assert.equal(await controller.flushAndSnapshot(),await fresh.snapshot());assert.equal(fresh.state('first'),'newer');assert.equal(fresh.calls.length,2)
         fresh.probe.aboutToDisappear();await fresh.settle();const snapshots=fresh.snapshots.length
         await assert.rejects(controller.flushAndSnapshot(),/Preview is not attached/);assert.equal(fresh.snapshots.length,snapshots)
        old.fire(oldTimer);fresh.fire(newTimer);await old.advance(1000);await fresh.advance(1000)
        assert.equal(old.calls.length,1);assert.equal(fresh.calls.length,2);assert.equal(fresh.saves.length,2);assert.equal(old.probe.error,'');assert.equal(fresh.probe.error,'')
       })
        for(const event of ['submit','blur']) for(const final of ['你好','ni','base','']) await test(`native fields: actual ${event} completes composition with ${JSON.stringify(final)} and no final onChange`, async () => {
        const f=await fieldProbe(), {probe,first}=f, native=f.native(), generation=first.fieldGeneration
        f.change(first,'n');const timer=probe.fieldEdits.get(first).timer
        await f.advance(17);f.change(first,'ni',true);const edit=probe.fieldEdits.get(first)
        native.controller.text='not the submit event'
        native.edit(true);assert.equal(native.controller.reads,0);assert.equal(probe.fieldEdits.get(first),edit);assert.deepEqual(f.calls,[])
        native[event](final);await f.settle()
        const expected=final==='base'?[]:[{action:'setFirst',value:final,at:17}]
        assert.deepEqual(f.calls,expected);assert.equal(f.state('first'),final);assert.equal(first.fieldValue,final);assert.equal(first.fieldGeneration,generation)
        assert.equal(edit.composing,false);assert.equal(edit.value,final);assert.equal(native.controller.reads,event==='blur'?1:0)
        assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.deepEqual(probe.fieldActions,[])
        assert.equal(f.saves.length,expected.length);if(expected.length)assert.equal(f.saves[0].first,final)
        native.submit(final);native.blur(final);native.submit(final);f.fire(timer);await f.advance(1000)
        assert.deepEqual(f.calls,expected);assert.equal(f.saves.length,expected.length)
        f.change(first,final);const echoTimer=probe.fieldEdits.get(first).timer
        await f.advance(400);native.submit(final);native.blur(final);f.fire(timer);f.fire(echoTimer)
        assert.deepEqual(f.calls,expected);assert.equal(f.saves.length,expected.length);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       })
       for(const event of ['submit','blur']) for(const otherComposing of [false,true]) await test(`native fields: actual ${event} resumes Save/toggle in order${otherComposing?' only after both native completions':''}`, async () => {
        const f=await fieldProbe(), {probe,first,second}=f, native=f.native(), other=f.native(second)
        f.change(first,'cached preview',true)
        if(otherComposing)f.change(second,'other preview',true)
        probe.handleAction('save',9);probe.handleBoolAction('toggle',false)
        const queued=[...probe.fieldActions]
        assert.deepEqual(queued.map(next=>[next.action,payloadValue(next.payload)]),[['save',9],['toggle',false]]);assert.deepEqual(f.calls,[])
        await f.advance(31);native[event]('native final');await f.settle()
        const expected=[{action:'setFirst',value:'native final',at:31}]
        if(otherComposing) {
         assert.deepEqual(f.calls,expected);assert.deepEqual(probe.fieldActions,queued);assert.equal(f.state('saved'),'')
         assert.equal(probe.fieldEdits.size,1);assert.equal(probe.fieldEdits.get(second).composing,true);assert.equal(probe.resumingFieldActions,false)
         native.submit('native final');native.blur('native final');await f.advance(19)
         assert.deepEqual(f.calls,expected);assert.deepEqual(probe.fieldActions,queued)
         other[event==='submit'?'blur':'submit']('second final');await f.settle();expected.push({action:'setSecond',value:'second final',at:50})
        }
        const at=otherComposing?50:31
        expected.push({action:'save',value:9,at},{action:'toggle',value:false,at})
        assert.deepEqual(f.calls,expected);assert.equal(f.state('saved'),otherComposing?'native final/second final':'native final/other')
        assert.deepEqual(f.saves.map(state=>state.saved),otherComposing?['','','native final/second final','native final/second final']:['','native final/other','native final/other'])
        assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false);assert.equal(f.scheduled.size,0)
        native.submit('native final');native.blur('native final');other.submit('second final');other.blur('second final');probe.resumeFieldActions();await f.advance(1000)
        assert.deepEqual(f.calls,expected);assert.equal(f.saves.length,expected.length);assert.equal(probe.error,'')
       })
       for(const event of ['submit','blur']) await test(`native fields: actual ${event} cancels preview back to base without losing queued actions`, async () => {
        const f=await fieldProbe(), {probe,first}=f, native=f.native()
        f.change(first,'cancelled preview',true);probe.handleAction('save',4);probe.handleBoolAction('toggle',true)
        native[event]('base');await f.settle()
        assert.deepEqual(f.calls,[{action:'save',value:4,at:0},{action:'toggle',value:true,at:0}]);assert.equal(f.state('first'),'base');assert.equal(f.state('saved'),'base/other')
        assert(f.saves.every(state=>state.first==='base'&&state.saved==='base/other'));assert.equal(f.saves.length,2)
        assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       })
       await test('native fields: stale actual submit/blur callbacks never read either controller or alter a fresh composing edit', async () => {
        const f=await fieldProbe(), {probe,first}=f, old=f.native(), generation=first.fieldGeneration
        f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
        await f.frame([{keyboardType:'email'},{}]);await f.frame()
        assert.equal(first.fieldGeneration,generation+2);assert.equal(probe.fieldInputs.size,0)
        const fresh=f.native();assert.notEqual(fresh.controller,old.controller);assert.equal(f.native().controller,fresh.controller)
        f.change(first,'fresh preview',true);const edit=probe.fieldEdits.get(first)
        probe.handleAction('save',5);const queued=[...probe.fieldActions]
        old.submit('stale final');old.blur('stale controller');f.fire(timer);await f.advance(1000)
        assert.equal(old.controller.reads,0);assert.equal(fresh.controller.reads,0);assert.equal(probe.fieldEdits.get(first),edit)
        assert.equal(edit.value,'fresh preview');assert.equal(edit.composing,true);assert.equal(edit.commitRequested,false);assert.deepEqual(probe.fieldActions,queued);assert.deepEqual(f.calls,[])
        fresh.blur('fresh final');await f.settle();assert.equal(fresh.controller.reads,1)
        assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh final',at:1000},{action:'save',value:5,at:1000}]);assert.equal(f.state('saved'),'fresh final/other');assert.equal(probe.error,'')
       })
       for(const invalid of ['missing-input','input-generation','node-generation','removed','disposed','previewOnly']) await test(`native fields: actual blur with ${invalid} never calls getText`, async () => {
        const f=await fieldProbe(), {probe,first}=f, native=f.native()
        f.change(first,'composition',true);const edit=probe.fieldEdits.get(first)
        if(invalid==='missing-input')probe.fieldInputs.delete(first)
        else if(invalid==='input-generation')probe.fieldInputs.get(first).generation++
        else if(invalid==='node-generation')first.fieldGeneration++
        else if(invalid==='removed')f.remove(f.first)
        else probe[invalid]=true
        native.blur('must not read')
        assert.equal(native.controller.reads,0);assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.composing,true);assert.equal(edit.value,'composition')
        assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(f.scheduled.size,0)
       })
       for(const transition of ['load','preview-load','disappear','reappear']) await test(`native fields: ${transition} drops controllers and rejects actual old callbacks`, async () => {
        const f=await fieldProbe(), {probe,first}=f, native=f.native()
         f.change(first,'old composition',true);native.controller.text='old final'
         const draining=transition==='disappear'||transition==='reappear'
         if(transition==='preview-load') { probe.previewOnly=true;probe.load();await f.settle();probe.previewOnly=false;probe.onPreviewOnlyChanged();await f.settle() }
         else if(draining) { probe.aboutToDisappear();await settlePreview(probe);if(transition==='reappear')probe.aboutToAppear() }
         else await f.reload()
          await f.settle()
         assert.equal(probe.fieldInputs.size,0);assert.equal(probe.fieldEdits.size,0)
         const expected=draining?[{action:'setFirst',value:'old final',at:0}]:[]
         assert.equal(native.controller.reads,draining?1:0);assert.deepEqual(f.calls,expected)
         assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),draining?[['old final','other','']]:[])
         const reads=native.controller.reads, calls=[...f.calls], saves=[...f.saves]
         native.submit('stale');native.blur('stale');await f.settle()
         assert.equal(native.controller.reads,reads);assert.deepEqual(f.calls,calls);assert.deepEqual(f.saves,saves)
         if(transition!=='disappear') {
          const node=probe.liveRoot.children[0], fresh=f.native(node)
          assert.notEqual(fresh.controller,native.controller);f.change(node,'new composition',true);fresh.blur('new final');await f.settle()
          assert.deepEqual(f.calls,[...expected,{action:'setFirst',value:'new final',at:0}]);assert.equal(f.state('first'),'new final')
          assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),[...saves.map(state=>[state.first,state.second,state.saved]),['new final','other','']])
         }
        assert.equal(probe.error,'')
       })
       for(const event of ['submit','blur']) await test(`native surface: actual ${event} completion permits only a fresh gesture after IME-rejected down`, async () => {
        const f=await fieldProbe(true), {probe,first}=f, native=f.native()
        f.change(first,'cached preview',true);f.touch('Down');f.touch('Move');f.touch('Up');await f.settle()
        assert.deepEqual(f.calls,[]);assert.equal(probe.surfaceInputs.size,0);assert.deepEqual(probe.fieldActions,[])
        native[event]('native final');f.touch('Move');f.touch('Up');await f.settle()
        assert.deepEqual(f.calls.map(call=>call.action),['setFirst']);assert.equal(f.saves.length,1);assert.equal(f.state('log'),'')
        f.touch('Down');f.touch('Move');f.touch('Up');await f.settle()
        assert.deepEqual(f.calls.map(call=>call.action),['setFirst','pointer','pointer','pointer']);assert.equal(f.state('saved'),'native final/other');assert.equal(f.state('log'),'down1;move1;up1;')
        assert.equal(f.saves.length,3);assert(f.saves.every(state=>state.first==='native final'));assert.equal(probe.surfaceInputs.size,0)
        native.submit('native final');native.blur('native final');await f.advance(1000);assert.equal(f.calls.length,4);assert.equal(f.saves.length,3);assert.equal(probe.error,'')
       })
       await test('native slider: extracted callback flushes both latest drafts before VM and persists only drag end', async () => {
       const f=await fieldProbe(true), {probe,first,second,slider}=f, generation=slider.fieldGeneration
       f.change(first,'old');f.change(first,'latest');f.change(second,'second');const timers=[...f.history.keys()]
       await f.advance(19);f.slide(10.6,'Begin');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'latest',at:19},{action:'setSecond',value:'second',at:19},{action:'slide',value:11,at:19}])
       assert.equal(f.state('saved'),'latest/second');assert.equal(f.state('position'),11);assert.equal(f.saves.length,2)
       assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.position]),[['latest','other',0],['latest','second',0]])
       f.slide(20.4);await f.settle();f.slide(21.7,'Click');await f.settle();assert.equal(f.saves.length,2)
       f.slide(30.6,'End');await f.settle();assert.equal(f.saves.length,3);assert.equal(f.saves.at(-1).position,31);assert.equal(f.saves.at(-1).saved,'latest/second')
       assert.equal(slider.fieldGeneration,generation);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
       for(const timer of timers)f.fire(timer)
       await f.advance(1000);assert.equal(f.calls.length,6);assert.equal(f.saves.length,3);assert.equal(probe.error,'')
      })
      await test('native slider: extracted callback with no action never flushes drafts or writes state', async () => {
       const f=await fieldProbe(true)
       f.change(f.first,'pending');f.reconcile(f.slider,{action:''});f.slide(40,'End')
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(f.scheduled.size,1)
       await f.advance(400);assert.deepEqual(f.calls.map(call=>call.action),['setFirst']);assert.equal(f.saves.length,1)
      })
      for(const ended of [false,true]) await test('native slider: IME coalesces adjacent events and '+(ended?'retains final persistence':'keeps moving events unsaved until end'), async () => {
       const f=await fieldProbe(true), {probe,first,slider}=f
       f.change(first,'composition',true)
       f.slide(1,'Begin');f.slide(2);f.slide(3);if(ended)f.slide(4.6,'End')
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(probe.fieldActions.length,1)
       const queued=probe.fieldActions[0]
       assert.equal(queued.node,slider);assert.equal(queued.nodeGeneration,slider.fieldGeneration);assert.equal(queued.generation,probe.effectGeneration)
       assert.equal(queued.persist,ended);assert.equal(payloadValue(queued.payload),ended?5:3)
       await f.advance(37);f.change(first,'final');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'final',at:37},{action:'slide',value:ended?5:3,at:37}])
       assert.equal(f.state('saved'),'final/other');assert.equal(f.saves.length,ended?2:1)
       assert.equal(f.saves[0].first,'final');assert.equal(f.saves[0].position,0)
       if(!ended)f.slide(9,'End')
        await f.settle()
       assert.equal(f.saves.length,2);assert.equal(f.saves[1].position,ended?5:9);assert.equal(f.saves[1].saved,'final/other')
       f.finish(first);probe.resumeFieldActions();await f.advance(1000)
       assert.equal(f.calls.length,ended?2:3);assert.equal(f.saves.length,2);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
      })
      await test('native slider: IME preserves intervening actions, other sliders and completed drag boundaries', async () => {
       const f=await fieldProbe(true), {probe,first,otherSlider}=f
       f.change(first,'composition',true)
       f.slide(1,'Begin');f.slide(2);probe.handleAction('save',7);f.slide(3);f.slide(4)
       f.slide(5,'Moving',otherSlider);f.slide(6);f.slide(7,'End');f.slide(8,'Begin');f.slide(9,'End')
       assert.deepEqual(probe.fieldActions.map(next=>[next.action,payloadValue(next.payload),next.persist]),[['slide',2,false],['save',7,true],['slide',4,false],['slideOther',5,false],['slide',7,true],['slide',9,true]])
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[])
       f.change(first,'final');await f.settle()
       assert.deepEqual(f.calls.map(call=>[call.action,call.value]),[['setFirst','final'],['slide',2],['save',7],['slide',4],['slideOther',5],['slide',7],['slide',9]])
       assert.equal(f.state('log'),'s2;save;s4;o5;s7;s9;')
       assert.deepEqual(f.saves.map(state=>[state.first,state.position,state.log]),[['final',0,''],['final',2,'s2;save;'],['final',7,'s2;save;s4;o5;s7;'],['final',9,'s2;save;s4;o5;s7;s9;']])
       assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
      })
      for(const transition of ['kind','action','enabled','node-generation','remove','effect-generation','load','preview-load','disappear','reappear']) await test('native slider: queued events reject '+transition+' without stale persistence', async () => {
       const f=await fieldProbe(true), {probe,first,slider}=f, generation=first.fieldGeneration
       f.change(first,'composition',true);f.slide(2);f.slide(3,'End')
       assert.equal(probe.fieldActions.length,1)
       if(['kind','action','enabled'].includes(transition))f.reconcile(slider,{[transition]:{kind:'text',action:'slideOther',enabled:false}[transition]})
       else if(transition==='node-generation')slider.fieldGeneration++
       else if(transition==='remove')f.remove(slider)
       else if(transition==='effect-generation')probe.effectGeneration++
       else if(transition==='load')await f.reload()
       else if(transition==='preview-load') { probe.previewOnly=true;probe.load();await f.settle();probe.previewOnly=false;probe.onPreviewOnlyChanged();await f.settle() }
        else { probe.aboutToDisappear();await settlePreview(probe);if(transition==='reappear')probe.aboutToAppear() }
        await f.settle()
        const draining=transition==='disappear'||transition==='reappear'
        const calls=[...f.calls], saves=[...f.saves]
        if(draining) {
         assert.deepEqual(calls,[{action:'setFirst',value:'composition',at:0}])
         assert.deepEqual(saves.map(state=>[state.first,state.second,state.position,state.saved,state.log]),[['composition','other',0,'','']])
        }
        f.change(first,'final',false,generation);probe.resumeFieldActions();await f.advance(400)
        if(draining) { assert.deepEqual(f.calls,calls);assert.deepEqual(f.saves,saves) }
        assert(!f.calls.some(call=>call.action==='slide'));assert(!f.saves.some(state=>state.position!==0))
        assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false);assert.equal(probe.error,'')
        assert.equal(f.saves.length,['load','preview-load'].includes(transition)?0:1)
      })
      for(const transition of ['kind','action','enabled','generation','remove']) await test('native slider: revalidates '+transition+' after flushing draft', async () => {
const f=await fieldProbe(true), {probe,slider}=f
        f.change(f.first,'latest')
        f.onInputApplied(action=>{
        if(action!=='setFirst')return
        if(transition==='generation')slider.fieldGeneration++
        else if(transition==='remove')f.remove(slider)
else f.reconcile(slider,{[transition]:{kind:'text',action:'slideOther',enabled:false}[transition]})
        })
        f.slide(8,'End');await f.settle()
       assert.deepEqual(f.calls.map(call=>call.action),['setFirst']);assert.equal(f.saves.length,1);assert.equal(f.saves[0].first,'latest');assert.equal(f.saves[0].position,0)
       assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
      })
      for(const input of ['slider','back','surface']) await test('native '+input+': load during field flush aborts captured user input', async () => {
const f=await fieldProbe(true), {probe}=f
        f.change(f.first,'latest');const timer=probe.fieldEdits.get(f.first).timer, generation=probe.effectGeneration
        let loading
        f.onInputApplied(action=>{if(action==='setFirst')loading=f.reload()})
       if(input==='slider')f.slide(7,'End');else if(input==='back')probe.onBackPressSignal();else f.touch('Down');await f.settle()
        await f.settle();assert(loading instanceof Promise);await loading;await f.settle()
       assert.equal(probe.effectGeneration,generation+1);assert.deepEqual(f.calls.map(call=>call.action),['setFirst'])
       assert.equal(f.saves.length,1);assert.equal(f.saves[0].first,'latest');assert.equal(f.saves[0].log,'');assert.equal(f.state('first'),'latest')
       f.fire(timer);f.touch('Move');f.touch('Up');assert.equal(f.calls.length,1);assert.equal(f.saves.length,1);assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
      await test('native back: real signal flushes pending drafts before handler and persists updated state', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'latest');f.change(f.second,'second');probe.onBackPressSignal();await f.settle()
       assert.deepEqual(f.calls.map(call=>[call.action,call.value]),[['setFirst','latest'],['setSecond','second'],['back',0]])
       assert.equal(f.state('saved'),'latest/second');assert.equal(f.saves.length,3);assert.equal(f.saves.at(-1).log,'back;');assert.equal(f.saves.at(-1).saved,'latest/second')
       await f.advance(1000);assert.equal(f.calls.length,3);assert.equal(f.saves.length,3);assert.equal(probe.error,'')
      })
      await test('native back: IME defers repeated signals in order with other user actions', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'composition',true);probe.onBackPressSignal();probe.handleAction('save',1);probe.onBackPressSignal()
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.deepEqual(probe.fieldActions.map(next=>next.action),['back','save','back'])
       f.change(f.first,'final');await f.settle()
       assert.deepEqual(f.calls.map(call=>call.action),['setFirst','back','save','back']);assert.equal(f.state('log'),'back;save;back;')
       assert.deepEqual(f.saves.map(state=>state.log),['','back;','back;save;','back;save;back;']);assert(f.saves.every(state=>state.first==='final'))
       assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
      })
      for(const gate of ['absent','disposed','previewOnly']) await test('native back: '+gate+' signal does not flush or persist', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'pending')
       if(gate==='absent')probe.backHandlerAction='';else probe[gate]=true
       probe.onBackPressSignal()
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(probe.fieldEdits.size,1);assert.equal(f.scheduled.size,1);assert.deepEqual(probe.fieldActions,[])
      })
      for(const transition of ['remove-field','invalidateEffects','load','disappear']) await test('native back: deferred signal canceled by '+transition, async () => {
       const f=await fieldProbe(true), {probe}=f, generation=f.first.fieldGeneration
       f.change(f.first,'composition',true);probe.onBackPressSignal()
       if(transition==='remove-field') { f.remove(f.first);probe.reconcileFields() }
       else if(transition==='disappear') { probe.aboutToDisappear();await settlePreview(probe) } else if(transition==='load')await f.reload()
        else probe[transition]()
        await f.settle()
        const expected=transition==='disappear'?[{action:'setFirst',value:'composition',at:0}]:[]
        assert.deepEqual(f.calls,expected)
        assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved,state.log]),transition==='disappear'?[['composition','other','','']]:[])
        const calls=[...f.calls], saves=[...f.saves]
        f.change(f.first,'late',false,generation);probe.resumeFieldActions();await f.advance(1000)
        assert.deepEqual(f.calls,calls);assert.deepEqual(f.saves,saves);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.error,'')
      })
      await test('native surface: down flushes both drafts before pointer VM and persists their latest values', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'latest');f.change(f.second,'second');const timers=[...f.history.keys()]
       f.touch('Down');await f.settle()
       assert.deepEqual(f.calls.map(call=>call.action),['setFirst','setSecond','pointer']);assert.equal(f.state('saved'),'latest/second')
       assert.equal(f.state('phase'),'down');assert.equal(f.state('x'),25);assert.equal(f.state('y'),25);assert.equal(f.state('id'),1)
       assert.equal(f.saves.length,3);assert.equal(f.saves.at(-1).saved,'latest/second');assert.equal(f.saves.at(-1).log,'down1;')
       assert.equal(probe.surfaceInputs.get(f.surface).size,1)
       for(const timer of timers)f.fire(timer)
       await f.advance(1000);assert.equal(f.calls.length,3);assert.equal(f.saves.length,3);assert.equal(probe.error,'')
      })
      for(const end of ['Up','Cancel']) await test('native surface: IME-rejected down never leaks move/'+end.toLowerCase()+' after final text', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'composition',true);f.touch('Down');await f.settle();f.touch('Move');await f.settle();f.touch(end);await f.settle()
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(probe.surfaceInputs.size,0);assert.deepEqual(probe.fieldActions,[])
       f.change(f.first,'final');f.touch('Move');f.touch(end)
       assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,1)
       await f.advance(400);f.touch('Move');f.touch(end)
       assert.deepEqual(f.calls.map(call=>call.action),['setFirst']);assert.equal(f.saves.length,1);assert.equal(f.saves[0].log,'')
       f.touch('Down');await f.settle();f.touch('Move');await f.settle();f.touch(end);await f.settle()
       assert.equal(f.state('log'),'down1;move1;'+end.toLowerCase()+'1;');assert.equal(f.saves.length,3);assert.equal(f.saves.at(-1).first,'final');assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
       await test('native surface: rejected repeated down forgets that finger and defers the accepted other finger cancel through composition', async () => {
       const f=await fieldProbe(true), {probe}=f, one={id:1,x:150,y:50}, two={id:2,x:200,y:100}
       f.touch('Down',[one,two]);await f.settle();assert.equal(probe.surfaceInputs.get(f.surface).size,2)
       f.change(f.first,'composition',true);f.touch('Down',[one]);f.touch('Move',[one]);f.touch('Up',[one])
       assert.equal(f.calls.length,2);assert.equal(f.saves.length,2);assert.equal(probe.surfaceInputs.get(f.surface).size,1)
        f.touch('Move',[two]);f.touch('Cancel',[two])
        assert.equal(f.state('log'),'down1;down2;');assert.equal(f.saves.length,2);assert.equal(probe.fieldEdits.size,1)
        assert.equal(probe.fieldActions.length,1);assert.equal(probe.fieldActions[0].surfaceId,2);assert.equal(probe.fieldActions[0].surfaceInput,probe.surfaceInputs.get(f.surface).get(2));assert.equal(probe.fieldActions[0].surfaceInput.ended,true)
         f.touch('Down',[two]);f.touch('Move',[two]);f.touch('Up',[two]);f.touch('Cancel',[two]);assert.equal(probe.fieldActions.length,1);assert.equal(probe.fieldActions[0].surfaceInput,probe.surfaceInputs.get(f.surface).get(2))
let terminalApplied=false
         f.onInputApplied((action,payload)=>{
          if(action==='pointer'&&payload.phase==='cancel') {
           assert.equal(probe.surfaceInputs.get(f.surface).get(2).ended,true)
           terminalApplied=true
          }
         })
        f.native().submit('final');probe.resumeFieldActions();await f.advance(400)
        assert.equal(terminalApplied,true)
         assert.deepEqual(f.calls.map(call=>call.action),['pointer','pointer','setFirst','pointer']);assert.equal(f.state('log'),'down1;down2;cancel2;');assert.equal(f.saves.length,4);assert.equal(f.saves.at(-1).saved,'final/other');assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
      await test('native surface: valid multitouch phases map coordinates and persist down/up/cancel, not moves', async () => {
       const f=await fieldProbe(true), {probe}=f, one={id:1,x:150,y:50}, two={id:2,x:300,y:150}, unknown={id:9,x:0,y:0}
       f.touch('Move',[one]);f.touch('Up',[one]);f.touch('Cancel',[one]);assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[])
       f.touch('Down',[one,two]);await f.settle();assert.equal(probe.surfaceInputs.get(f.surface).size,2);assert.equal(f.saves.length,2)
       f.touch('Move',[one,two,unknown]);await f.settle();assert.equal(f.saves.length,2);assert.equal(f.state('x'),100);assert.equal(f.state('y'),75)
       f.touch('Up',[one]);await f.settle();assert.equal(probe.surfaceInputs.get(f.surface).size,1);assert.equal(f.saves.length,3)
       f.touch('Move',[one,two]);await f.settle();assert.equal(f.saves.length,3);f.touch('Cancel',[two,unknown]);await f.settle();assert.equal(f.saves.length,4)
       assert.equal(f.state('log'),'down1;down2;move1;move2;up1;move2;cancel2;');assert.equal(probe.surfaceInputs.size,0)
       const pointers=f.calls.map(call=>call.value)
       assert(pointers.every(value=>value instanceof Map));assert.deepEqual(pointers.map(value=>value.get('id').value),[1,2,1,2,1,2,2])
       f.touch('Move',[one,two]);f.touch('Up',[one,two]);assert.equal(f.calls.length,7);assert.equal(f.saves.length,4);assert.equal(probe.error,'')
      })
       await test('native surface: continuing move/up flush edits begun after valid down', async () => {
        const f=await fieldProbe(true), {probe}=f
         f.touch('Down');await f.settle();f.change(f.first,'pending');const timer=probe.fieldEdits.get(f.first).timer
         f.touch('Move');await f.settle();await f.snapshot()
        assert.deepEqual(f.calls.map(call=>call.action),['pointer','setFirst','pointer']);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
        assert.equal(f.saves.length,2);assert.equal(f.saves.at(-1).first,'pending');assert.equal(f.state('saved'),'pending/other')
        f.change(f.first,'latest');const finalTimer=probe.fieldEdits.get(f.first).timer
        f.touch('Up');await f.settle()
        assert.deepEqual(f.calls.map(call=>call.action),['pointer','setFirst','pointer','setFirst','pointer']);assert.equal(f.saves.length,4);assert.equal(f.saves.at(-1).saved,'latest/other');assert.equal(f.state('log'),'down1;move1;up1;')
        assert.equal(probe.surfaceInputs.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
        f.fire(timer);f.fire(finalTimer);await f.advance(400);assert.equal(f.calls.length,5);assert.equal(f.saves.length,4);assert.equal(probe.error,'')
       })
      await test('native surface: mixed IME down flushes only ready fields and never queues a partial gesture', async () => {
       const f=await fieldProbe(true), {probe}=f
       f.change(f.first,'composition',true);f.change(f.second,'ready');f.touch('Down');await f.settle()
       assert.deepEqual(f.calls.map(call=>call.action),['setSecond']);assert.equal(f.saves.length,1);assert.equal(f.saves[0].second,'ready');assert.equal(f.saves[0].first,'base')
       assert.equal(probe.surfaceInputs.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,1)
       f.finish(f.first);f.change(f.first,'final');await f.settle();f.touch('Move');f.touch('Up');await f.settle()
       assert.deepEqual(f.calls.map(call=>call.action),['setSecond','setFirst']);assert.equal(f.saves.length,2);assert.equal(f.saves.at(-1).first,'final');assert.equal(f.saves.at(-1).log,'')
       f.touch('Down');await f.settle();assert.equal(f.saves.length,3);assert.equal(f.saves.at(-1).saved,'final/ready');assert.equal(probe.error,'')
      })
      await test('native surface: disappearance persists last unsaved move through real persistence and clears gesture', async () => {
       const f=await fieldProbe(true), {probe,surface}=f
        probe.liveSurfaces=[surface];f.touch('Down');await f.settle();f.touch('Move',[{id:1,x:280,y:180}]);await f.settle();await f.snapshot()
       assert.equal(f.saves.length,1);assert.equal(f.saves[0].phase,'down');assert.equal(f.state('phase'),'move')
       probe.aboutToDisappear();await settlePreview(probe)
       assert.equal(f.saves.length,2);assert.equal(f.saves[1].phase,'move');assert.equal(f.saves[1].x,90);assert.equal(f.saves[1].y,90)
       assert.equal(probe.surfaceInputs.size,0);f.touch('Up');assert.equal(f.calls.length,2);assert.equal(f.saves.length,2);assert.equal(probe.error,'')
      })
       for(const transition of ['node-generation','value','kind','remove','unmeasured','effect-generation','invalidateEffects','load','preview-load','disappear','reappear']) await test('native surface: '+transition+' rejects queued stale terminal and gesture continuation', async () => {
        const f=await fieldProbe(true), {probe,surface}=f, native=f.native()
        f.touch('Down');await f.settle();assert.equal(f.calls.length,1);assert.equal(f.saves.length,1)
         f.change(f.first,'composition',true);native.controller.text='native final';f.touch('Up');await f.settle()

        assert.equal(probe.fieldActions.length,1);assert.equal(probe.fieldActions[0].surfaceInput,probe.surfaceInputs.get(surface).get(1));assert.equal(probe.fieldActions[0].surfaceInput.ended,true)
        f.touch('Move');f.touch('Up');f.touch('Cancel');assert.equal(f.calls.length,1);assert.equal(f.saves.length,1);assert.equal(probe.fieldActions.length,1)
       if(transition==='node-generation')surface.fieldGeneration++
       else if(transition==='value') { f.reconcile(surface,{value:'answer1'});f.reconcile(surface,{value:'pointer'}) }
       else if(transition==='kind') { f.reconcile(surface,{kind:'text'});f.reconcile(surface,{kind:'surface'}) }
       else if(transition==='remove')f.remove(surface)
       else if(transition==='unmeasured')probe.surfaces.get(surface).width=0
       else if(transition==='effect-generation')probe.effectGeneration++
       else if(transition==='preview-load') { probe.previewOnly=true;probe.load();await f.settle();probe.previewOnly=false;probe.onPreviewOnlyChanged();await f.settle() }
       else if(transition==='disappear'||transition==='reappear') { probe.aboutToDisappear();await settlePreview(probe);if(transition==='reappear')probe.aboutToAppear() }
       else if(transition==='load')await f.reload()
        else probe[transition]()
        await f.settle()
         const draining=transition==='disappear'||transition==='reappear', commits=probe.fieldEdits.has(f.first)?1:0
         const calls=[...f.calls], saves=[...f.saves], reads=native.controller.reads
         if(draining) {
          assert.equal(reads,1);assert.deepEqual(calls.slice(1),[{action:'setFirst',value:'native final',at:0}])
          assert.deepEqual(saves.map(state=>[state.first,state.second,state.saved,state.log,state.phase]),[['base','other','base/other','down1;','down'],['native final','other','base/other','down1;','down']])
         }
         native.submit('final');probe.resumeFieldActions();probe.resumeFieldActions()
         f.touch('Move');f.touch('Up');f.touch('Cancel');await f.advance(1000)
         if(draining) { assert.equal(native.controller.reads,reads);assert.deepEqual(f.calls,calls);assert.deepEqual(f.saves,saves) }
         assert.deepEqual(f.calls.map(call=>call.action),draining||commits?['pointer','setFirst']:['pointer']);assert.equal(f.saves.length,1+(draining?1:commits));assert(f.saves.every(state=>state.log==='down1;'));assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
      for(const gate of ['disposed','previewOnly','noaction','removed','unmeasured']) await test('native surface: '+gate+' down cannot begin a gesture or persist', async () => {
       const f=await fieldProbe(true), {probe,surface}=f
       if(gate==='noaction')f.reconcile(surface,{value:''})
       else if(gate==='removed')f.remove(surface)
       else if(gate==='unmeasured')probe.surfaces.get(surface).height=0
       else probe[gate]=true
       f.touch('Down');f.touch('Move');f.touch('Up');await f.settle()
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.saves,[]);assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
       for(const transition of ['node-generation','value','kind','remove']) await test('native surface: continuation revalidates '+transition+' after field flush', async () => {
const f=await fieldProbe(true), {probe,surface}=f
         f.touch('Down');await f.settle();f.change(f.first,'latest')
        f.onInputApplied(action=>{
        if(action!=='setFirst')return
        if(transition==='node-generation')surface.fieldGeneration++
        else if(transition==='remove')f.remove(surface)
else f.reconcile(surface,{[transition]:transition==='kind'?'text':'answer1'})
        })
         f.touch('Move');f.touch('Up');await f.settle()
        assert.deepEqual(f.calls.map(call=>call.action),['pointer','setFirst']);assert.equal(f.saves.length,2);assert.equal(f.saves.at(-1).first,'latest');assert.equal(f.saves.at(-1).log,'down1;');assert.equal(probe.surfaceInputs.size,0);assert.equal(probe.error,'')
      })
      for(const composing of [false,true]) {
        await test('native timer: slow callback '+(composing?'skips composing':'flushes pending')+' user fields', async () => {
         const f=await fieldProbe(true), {probe}=f
         f.change(f.first,'draft',composing);const edit=probe.fieldEdits.get(f.first), timer=edit.timer
         probe.startTimer('fixture',{interval:1000,action:'tick'});const callback=f.intervals.get(probe.timers.get('fixture')).callback
         await f.advance(17);callback();await f.settle()
         assert.deepEqual(f.calls.map(call=>call.action),composing?[]:['setFirst','tick']);assert.equal(probe.fieldEdits.get(f.first),composing?edit:undefined);assert.equal(f.scheduled.size,0)
         assert.equal(probe.timerLastFire.get('fixture'),composing?0:17);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.saves.length,composing?0:2)
         if(!composing) { assert.equal(f.saves.at(-1).first,'draft');assert.equal(f.saves.at(-1).saved,'draft/other');f.fire(timer) }
         await f.advance(400);if(!composing)f.change(f.first,'final');f.native().submit('final');callback();await f.settle()
         assert.deepEqual(f.calls.map(call=>call.action),composing?['setFirst','tick']:['setFirst','tick','setFirst','tick']);assert.equal(f.calls.at(-1).value,composing?417:400)
         probe.stopTimer('fixture');await f.advance(400);assert.equal(f.saves.length,composing?2:4);assert.equal(f.saves.at(-1).saved,'final/other');assert.equal(probe.fieldEdits.size,0);assert.equal(probe.error,'')
        })
        await testAsync('native async: real effect reply '+(composing?'defers through composition':'flushes pending user fields'), async () => {
         const f=await fieldProbe(true), {probe}=f
         f.change(f.first,'draft',composing);const edit=probe.fieldEdits.get(f.first), timer=edit.timer
         probe.acceptEffects([hostEffect()]);assert.equal(f.replies.length,1);await settleEffect(f.replies[0],false,'reply')
         assert.deepEqual(f.calls.map(call=>call.action),composing?[]:['setFirst','answer1']);assert.equal(probe.fieldEdits.get(f.first),composing?edit:undefined);assert.equal(f.scheduled.size,0)
          assert.deepEqual(probe.fieldActions,[])
          assert.equal(probe.effectsBridge.binding.results.length,composing?1:0)
          if(composing) {
           const result=probe.effectsBridge.binding.results[0]
           assert.equal(result.effect.resultHandler,'answer1');assert.equal(result.text,'reply');assert.equal(result.current(),true)
          }
          assert.equal(f.saves.length,composing?0:2)
         if(!composing) { assert.equal(f.saves.at(-1).saved,'draft/other');f.fire(timer) }
          await f.advance(400);if(!composing)f.change(f.first,'final');f.native().submit('final');probe.resumeFieldActions();await f.advance(400)
         assert.deepEqual(f.calls.map(call=>call.action),composing?['setFirst','answer1']:['setFirst','answer1','setFirst']);assert.equal(f.saves.length,composing?2:3);assert.equal(f.saves.at(-1).first,'final')
         if(composing)assert.equal(f.saves.at(-1).saved,'final/other')
         assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(probe.error,'')
        })
      }
      await test('native fields: rapid input waits 400ms after latest, commits once without keystroke traces', async () => {
      const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
      f.change(first,'a');await f.advance(200);f.change(first,'ab');await f.advance(199);f.change(first,'latest')
      assert.equal(first.fieldValue,'base');assert.equal(first.value,'base');assert.equal(first.fieldGeneration,generation);assert.deepEqual(f.writes,[])
      assert.equal(probe.fieldEdits.size,1);assert.equal(probe.fieldEdits.get(first).base,'base');assert.equal(probe.fieldEdits.get(first).value,'latest')
      await f.advance(399);assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,1)
      await f.advance(1);assert.deepEqual(f.calls,[{action:'setFirst',value:'latest',at:799}]);assert.equal(f.state('first'),'latest');assert.equal(first.fieldValue,'latest')
      assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(first.fieldGeneration,generation);assert.equal(probe.error,'')
      await f.advance(1000);assert.equal(f.calls.length,1)
     })
      if(runtimeMode) { finishRuntimeTraces();return }
     await test('native fields: rescheduled and replaced edits reject captured stale one-shot callbacks', async () => {
      const f=await fieldProbe(), {probe,first}=f
      f.change(first,'old');const old=probe.fieldEdits.get(first).timer
      await f.advance(100);f.change(first,'new');const current=probe.fieldEdits.get(first).timer
      assert.notEqual(old,current);assert(!f.scheduled.has(old));f.fire(old)
      assert.deepEqual(f.calls,[]);assert.equal(probe.fieldEdits.get(first).timer,current);assert(f.scheduled.has(current))
      await f.advance(400);assert.deepEqual(f.calls,[{action:'setFirst',value:'new',at:500}])
      f.change(first,'replacement');const replacement=probe.fieldEdits.get(first)
      f.fire(old);f.fire(current);assert.equal(probe.fieldEdits.get(first),replacement);assert.equal(f.calls.length,1)
      await f.advance(400);assert.equal(f.calls.length,2);assert.equal(f.state('first'),'replacement')
     })
     for(const order of ['submit-blur','blur-submit']) await test('native fields: immediate '+order+' commits once and cancels debounce', async () => {
      const f=await fieldProbe(), {probe,first}=f
      f.change(first,'finished');const timer=probe.fieldEdits.get(first).timer
      await f.advance(17);f.finish(first);f.finish(first);f.fire(timer);await f.advance(1000)
      assert.deepEqual(f.calls,[{action:'setFirst',value:'finished',at:17}]);assert.equal(f.state('first'),'finished');assert.equal(first.fieldValue,'finished')
      assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
     })
      for(const event of ['submit','blur']) await test('native fields: plain '+event+' during IME requests final change with no debounce or form action', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       f.change(first,'n');const timer=probe.fieldEdits.get(first).timer
       await f.advance(17);f.change(first,'ni',true)
       const edit=probe.fieldEdits.get(first)
       assert.equal(edit.commitRequested,false);f.finish(first)
       assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.commitRequested,true);assert.equal(edit.composing,true)
       f.fire(timer);await f.advance(1000)
       assert.deepEqual(f.calls,[]);assert.deepEqual(f.writes,[]);assert.equal(first.fieldValue,'base');assert.equal(f.scheduled.size,0);assert.deepEqual(probe.fieldActions,[])
       f.change(first,'你好');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'你好',at:1017}]);assert.equal(f.state('first'),'你好');assert.equal(first.fieldValue,'你好');assert.equal(first.fieldGeneration,generation)
       assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(f.history.size,1);assert.deepEqual(probe.fieldActions,[])
       f.finish(first);f.fire(timer);await f.advance(1000)
       assert.equal(f.calls.length,1);assert.equal(probe.error,'')
      })
      await test('native fields: repeated IME finish and intermediate composition retain requested commit and dispatch once', async () => {
       const f=await fieldProbe(), {probe,first}=f
       f.change(first,'n');const timer=probe.fieldEdits.get(first).timer
       f.change(first,'ni',true);const edit=probe.fieldEdits.get(first)
       f.finish(first);f.finish(first)
       for(const value of ['你','你好','你好世']) {
        await f.advance(23);f.change(first,value,true)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,value);assert.equal(edit.composing,true);assert.equal(edit.commitRequested,true)
        f.finish(first);f.finish(first);f.fire(timer)
        assert.deepEqual(f.calls,[]);assert.deepEqual(f.writes,[]);assert.equal(f.scheduled.size,0);assert.deepEqual(probe.fieldActions,[])
       }
       f.change(first,'你好世界');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'你好世界',at:69}]);assert.equal(f.state('first'),'你好世界');assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(f.history.size,1)
       f.finish(first);f.finish(first);f.fire(timer);await f.advance(1000);assert.equal(f.calls.length,1)
       f.change(first,'next');const fresh=probe.fieldEdits.get(first)
       assert.notEqual(fresh,edit);assert.equal(fresh.commitRequested,false);assert(f.scheduled.has(fresh.timer))
       f.fire(timer);await f.advance(399);assert.equal(f.calls.length,1);assert.equal(probe.fieldEdits.get(first),fresh)
       await f.advance(1);assert.deepEqual(f.calls[1],{action:'setFirst',value:'next',at:1469});assert.equal(probe.error,'')
      })
      await test('native fields: requested IME finish leaves another field debounce deadline intact', async () => {
       const f=await fieldProbe(), {probe,first,second}=f
       f.change(first,'n');const stale=probe.fieldEdits.get(first).timer
       await f.advance(50);f.change(second,'independent');const edit=probe.fieldEdits.get(second), timer=edit.timer
       await f.advance(25);f.change(first,'ni',true);f.finish(first)
       assert.equal(probe.fieldEdits.get(first).commitRequested,true)
       await f.advance(75);f.change(first,'你好');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'你好',at:150}]);assert.equal(probe.fieldEdits.get(second),edit);assert.equal(edit.commitRequested,false);assert.equal(edit.base,'other');assert.equal(edit.timer,timer)
       assert.equal(f.scheduled.get(timer).at,450);assert.equal(f.scheduled.size,1)
       f.fire(stale);await f.advance(299);assert.equal(f.calls.length,1)
       await f.advance(1);assert.deepEqual(f.calls[1],{action:'setSecond',value:'independent',at:450});assert.equal(f.state('second'),'independent')
       f.fire(stale);f.fire(timer);await f.advance(1000);assert.equal(f.calls.length,2);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      for(const otherComposing of [false,true]) await test('native fields: requested finish resumes existing queued form actions'+(otherComposing?' after both composing fields finalize':''), async () => {
       const f=await fieldProbe(), {probe,first,second}=f
       f.change(first,'ni',true)
       if(otherComposing)f.change(second,'shi',true)
       probe.handleAction('save',6);probe.handleBoolAction('toggle',false)
       const queued=[...probe.fieldActions]
       assert.deepEqual(f.calls,[]);assert.deepEqual(queued.map(next=>[next.action,payloadValue(next.payload)]),[['save',6],['toggle',false]])
       f.finish(first);assert.equal(probe.fieldEdits.get(first).commitRequested,true)
       await f.advance(31);f.change(first,'你好');await f.settle()
       const expected=[{action:'setFirst',value:'你好',at:31}]
       if(otherComposing) {
        assert.deepEqual(f.calls,expected);assert.deepEqual(probe.fieldActions,queued);assert.equal(f.state('saved'),'');assert.equal(probe.fieldEdits.size,1);assert.equal(probe.resumingFieldActions,false)
        assert.equal(probe.fieldEdits.get(second).commitRequested,false);f.finish(second)
        assert.equal(probe.fieldEdits.get(second).commitRequested,true)
        await f.advance(19);f.change(second,'世界');await f.settle();expected.push({action:'setSecond',value:'世界',at:50})
       }
       const at=otherComposing?50:31
       expected.push({action:'save',value:6,at},{action:'toggle',value:false,at})
       assert.deepEqual(f.calls,expected);assert.equal(f.state('saved'),otherComposing?'你好/世界':'你好/other');assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false)
       assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(f.history.size,0)
       f.finish(first);f.finish(second);probe.resumeFieldActions();await f.advance(1000);assert.deepEqual(f.calls,expected);assert.equal(probe.error,'')
      })
      for(const transition of ['external','kind','action','enabled','remove','cancelField','cancelFields','invalidateEffects','load','preview-load','reappear']) await test('native fields: '+transition+' discards requested finish and stale callbacks cannot flag fresh composing edit', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
       f.change(first,'old composition',true);f.finish(first)
       const old=probe.fieldEdits.get(first)
       assert.equal(old.commitRequested,true);assert.equal(old.composing,true);assert.deepEqual(probe.fieldActions,[])
       await f.advance(13)
       if(transition==='external') { await f.external({first:'external'}) }
       else if(['kind','action','enabled'].includes(transition)) { await f.frame([{[transition]:{kind:'text',action:'normalize',enabled:false}[transition]},{}]);await f.frame() }
       else if(transition==='remove') { await f.frame([]);await f.frame() }
       else if(transition==='cancelField')probe.cancelField(first)
       else if(transition==='preview-load') { probe.previewOnly=true;probe.load();await f.settle();probe.previewOnly=false;probe.onPreviewOnlyChanged();await f.settle() }
       else if(transition==='reappear') { probe.aboutToDisappear();await settlePreview(probe);probe.aboutToAppear() }
       else if(transition==='load')await f.reload()
        else probe[transition]()
        await f.settle()
       assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.deepEqual(probe.fieldActions,[])
        const expected=transition==='reappear'?[{action:'setFirst',value:'old composition',at:13}]:[]
        assert.deepEqual(f.calls,expected)
        assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),transition==='reappear'?[['old composition','other','']]:[])
        const saves=[...f.saves]
        f.fire(timer);await f.settle();assert.deepEqual(f.calls,expected);assert.deepEqual(f.saves,saves)
        const fresh=probe.liveRoot.children[0]

       if(transition!=='cancelField') {
        f.change(first,'late',false,generation);f.finish(first,generation)
        assert.equal(probe.fieldEdits.size,0)
       }
       f.change(fresh,'fresh composition',true);const edit=probe.fieldEdits.get(fresh)
       assert.notEqual(edit,old);assert.equal(edit.commitRequested,false)
       if(transition!=='cancelField')f.finish(first,generation)
       f.fire(timer);f.change(fresh,'fresh intermediate',true)
        assert.equal(probe.fieldEdits.get(fresh),edit);assert.equal(edit.commitRequested,false);assert.equal(edit.composing,true);assert.deepEqual(f.calls,expected);assert.deepEqual(f.saves,saves);assert.equal(f.scheduled.size,0)
        f.change(fresh,'fresh final');const current=edit.timer
        assert.equal(edit.commitRequested,false);assert(f.scheduled.has(current));assert.equal(f.scheduled.get(current).at,413)
        f.fire(timer);await f.advance(399);assert.deepEqual(f.calls,expected);assert.deepEqual(f.saves,saves);assert.equal(probe.fieldEdits.get(fresh),edit)
        await f.advance(1);assert.deepEqual(f.calls,[...expected,{action:'setFirst',value:'fresh final',at:413}]);assert.equal(f.state('first'),'fresh final');assert.equal(f.state('saved'),'')
        assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),[...saves.map(state=>[state.first,state.second,state.saved]),['fresh final','other','']])
        f.fire(timer);f.fire(current);await f.advance(1000);assert.equal(f.calls.length,expected.length+1);assert.equal(f.saves.length,saves.length+1);assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      for(const invalid of ['base','generation']) await test('native fields: finish validates current '+invalid+' before requesting a composing commit', async () => {
       const f=await fieldProbe(), {probe,first}=f
       f.change(first,'composition',true);const edit=probe.fieldEdits.get(first), generation=first.fieldGeneration
       assert.equal(edit.commitRequested,false)
       if(invalid==='base')first.value='external';else first.fieldGeneration++
       f.finish(first,generation)
       assert.equal(edit.commitRequested,false);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.deepEqual(f.calls,[])
       probe.renderView();f.change(first,'fresh')
       assert.equal(probe.fieldEdits.get(first).commitRequested,false);await f.advance(399);assert.deepEqual(f.calls,[])
       await f.advance(1);assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:400}]);assert.equal(probe.error,'')
      })
     for(const mode of ['empty','equal','noaction']) await test('native fields: '+mode+' input has correct dispatch and display', async () => {
      const f=await fieldProbe(), {probe,first}=f
      if(mode==='noaction')await f.frame([{action:''},{}])
      const value=mode==='empty'?'':mode==='equal'?'base':'ignored'
      f.change(first,value);await f.advance(400);f.finish(first)
      assert.deepEqual(f.calls,mode==='empty'?[{action:'setFirst',value:'',at:400}]:[])
      assert.equal(f.state('first'),mode==='empty'?'':'base');assert.equal(first.fieldValue,mode==='empty'?'':'base')
      assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
     })
      await test('native fields: IME defers Save until final noncomposing change flushes immediately once', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       f.change(first,'n');const timer=probe.fieldEdits.get(first).timer
       await f.advance(100);f.change(first,'ni',true);f.fire(timer);await f.advance(1000)
       f.finish(first);probe.flushFields();assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,0)
       assert.equal(probe.fieldEdits.get(first).composing,true);assert.equal(first.fieldValue,'base');assert.deepEqual(f.writes,[])
       probe.handleAction('save',0);assert.deepEqual(f.calls,[]);assert.equal(f.state('saved'),'');assert.equal(probe.fieldActions.length,1)
       f.change(first,'你好',true);await f.advance(400);f.finish(first);probe.resumeFieldActions()
       assert.deepEqual(f.calls,[]);assert.equal(probe.fieldActions.length,1);assert.equal(f.scheduled.size,0)
       f.change(first,'你好');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'你好',at:1500},{action:'save',value:0,at:1500}]);assert.equal(f.state('saved'),'你好/other')
       assert.equal(first.fieldValue,'你好');assert.equal(first.fieldGeneration,generation);assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false);assert.equal(f.scheduled.size,0)
       f.finish(first);probe.resumeFieldActions();f.fire(timer);await f.advance(1000)
       assert.equal(f.calls.length,2);assert.equal(probe.error,'')
      })
             for(const [method,action,value,kind] of [['handleAction','save',7,'NUMBER'],['handleBoolAction','toggle',false,'BOOLEAN']]) await test('native fields: '+method+' preserves typed deferred payload and flushes other edits', async () => {
       const f=await fieldProbe(), {probe,first,second}=f
       f.change(first,'composing',true);f.change(second,'latest')
       const timer=probe.fieldEdits.get(second).timer
       await f.advance(23);probe[method](action,value);await f.settle()
       assert.deepEqual(f.calls,[{action:'setSecond',value:'latest',at:23}]);assert.equal(f.state('saved'),'');assert.equal(probe.fieldActions.length,1)
       const queued=probe.fieldActions[0]
       assert.equal(queued.action,action);assert.equal(queued.payload.kind,kind);assert.equal(payloadValue(queued.payload),value);assert.equal(queued.generation,probe.effectGeneration)
       assert.equal(probe.resumingFieldActions,false);assert.equal(f.scheduled.size,0)
       await f.advance(800);f.finish(first);assert.equal(f.calls.length,1)
       f.change(first,'final');await f.settle()
       assert.deepEqual(f.calls,[{action:'setSecond',value:'latest',at:23},{action:'setFirst',value:'final',at:823},{action,value,at:823}]);assert.equal(f.state('saved'),'final/latest')
       assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.resumingFieldActions,false)
       f.finish(first);f.fire(timer);probe.resumeFieldActions();await f.advance(1000);assert.equal(f.calls.length,3);assert.equal(probe.error,'')
      })
      await test('native fields: multiple composing fields hold queued numeric and boolean actions in order until both finalize', async () => {
       const f=await fieldProbe(), {probe,first,second}=f
       f.change(first,'one',true);f.change(second,'two',true)
       probe.handleAction('save',9);probe.handleBoolAction('toggle',true)
       assert.deepEqual(f.calls,[]);assert.deepEqual(probe.fieldActions.map(next=>[next.action,payloadValue(next.payload)]),[['save',9],['toggle',true]])
       await f.advance(40);f.change(first,'first final');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'first final',at:40}]);assert.equal(f.state('saved'),'');assert.equal(probe.fieldActions.length,2)
       assert.equal(probe.fieldEdits.size,1);assert.equal(probe.fieldEdits.get(second).composing,true);assert.equal(f.scheduled.size,0);assert.equal(probe.resumingFieldActions,false)
       f.finish(second);probe.resumeFieldActions();await f.advance(1000);assert.equal(f.calls.length,1)
       f.change(second,'second final');await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'first final',at:40},{action:'setSecond',value:'second final',at:1040},{action:'save',value:9,at:1040},{action:'toggle',value:true,at:1040}])
       assert.equal(f.state('saved'),'first final/second final');assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.resumingFieldActions,false)
       f.finish(first);f.finish(second);probe.resumeFieldActions();await f.advance(1000);assert.equal(f.calls.length,4);assert.equal(probe.error,'')
      })
     await test('native fields: independent fields retain their own debounce and pending base across dispatch', async () => {
      const f=await fieldProbe(), {probe,first,second}=f
      f.change(first,'one');await f.advance(100);f.change(second,'two')
      const secondEdit=probe.fieldEdits.get(second), timer=secondEdit.timer
      await f.advance(300);assert.deepEqual(f.calls,[{action:'setFirst',value:'one',at:400}])
      assert.equal(probe.fieldEdits.get(second),secondEdit);assert.equal(secondEdit.base,'other');assert.equal(secondEdit.timer,timer);assert(f.scheduled.has(timer))
      await f.advance(99);assert.equal(f.calls.length,1);await f.advance(1)
      assert.deepEqual(f.calls[1],{action:'setSecond',value:'two',at:500});assert.equal(f.state('first'),'one');assert.equal(f.state('second'),'two');assert.equal(probe.fieldEdits.size,0)
     })
     await test('native fields: unrelated real render/reconcile preserves edit, native text, identity and deadline', async () => {
      const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
      f.change(first,'pending');const edit=probe.fieldEdits.get(first), timer=edit.timer
      for(let i=0;i<3;i++) {
       await f.advance(100);await f.external({note:'frame'+i})
       assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation);assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.timer,timer);assert.equal(first.fieldValue,'base');assert.equal(first.value,'base');assert.equal(edit.base,'base')
      }
      assert.deepEqual(f.writes,[]);await f.advance(99);assert.deepEqual(f.calls,[]);await f.advance(1)
      assert.deepEqual(f.calls,[{action:'setFirst',value:'pending',at:400}]);assert.equal(probe.error,'')
     })
      const fieldSemanticAttrs={keyboardType:'email',required:true,minLength:2,maxLength:24,pattern:'^[a-z]+$',email:true}
      for(const [attr,value] of Object.entries(fieldSemanticAttrs)) {
       await test('native fields: '+attr+' change cancels debounce and rejects stale timer/onChange/finish', async () => {
        const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
        assert.equal(first[attr],new U.VeraUiNode()[attr]);assert.notEqual(first[attr],value)
        f.change(first,'stale');const old=probe.fieldEdits.get(first), timer=old.timer
        await f.advance(100);await f.frame([{[attr]:value},{}])
        assert.equal(probe.liveRoot.children[0],first);assert.equal(first[attr],value);assert.equal(first.fieldGeneration,generation+1)
        assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert(!f.scheduled.has(timer))
        f.fire(timer);f.change(first,'late',false,generation);f.change(first,'late composition',true,generation);f.finish(first,generation)
        assert.equal(probe.fieldEdits.size,0);assert.deepEqual(f.calls,[]);assert.deepEqual(f.writes,[])
        f.change(first,'fresh');const edit=probe.fieldEdits.get(first), current=edit.timer
        assert.notEqual(edit,old);assert.equal(edit.generation,generation+1);assert.equal(f.scheduled.get(current).at,500)
        f.fire(timer);f.change(first,'late',false,generation);f.finish(first,generation)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,'fresh');assert.equal(edit.timer,current);assert.equal(edit.commitRequested,false)
        assert.equal(f.scheduled.size,1);assert.equal(f.scheduled.get(current).at,500)
        await f.advance(399);assert.deepEqual(f.calls,[]);await f.advance(1)
        assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:500}]);assert.equal(f.state('first'),'fresh')
        f.fire(timer);f.fire(current);await f.advance(1000)
        assert.equal(f.calls.length,1);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       })
       await test('native fields: '+attr+' change cancels composing requested commit and queued form actions', async () => {
        const f=await fieldProbe(), {probe,first,second}=f, generation=first.fieldGeneration
        assert.notEqual(first[attr],value)
        f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
        f.change(first,'old composition',true);f.finish(first);const old=probe.fieldEdits.get(first)
        f.change(second,'independent composition',true);const other=probe.fieldEdits.get(second), otherGeneration=second.fieldGeneration
        probe.handleAction('save',5);probe.handleBoolAction('toggle',false)
        assert.equal(old.composing,true);assert.equal(old.commitRequested,true)
        assert.deepEqual(probe.fieldActions.map(next=>[next.action,payloadValue(next.payload)]),[['save',5],['toggle',false]])
        assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,0)
        await f.advance(13);await f.frame([{[attr]:value},{}])
        assert.equal(first[attr],value);assert.equal(first.fieldGeneration,generation+1);assert.equal(probe.liveRoot.children[0],first)
        assert(!probe.fieldEdits.has(first));assert.equal(probe.fieldEdits.get(second),other);assert.equal(second.fieldGeneration,otherGeneration)
        assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false)
        f.fire(timer);f.change(first,'late final',false,generation);f.finish(first,generation);probe.resumeFieldActions()
        assert(!probe.fieldEdits.has(first));assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,0)
        f.change(first,'fresh composition',true);const edit=probe.fieldEdits.get(first)
        assert.notEqual(edit,old);assert.equal(edit.commitRequested,false)
        f.finish(first,generation);f.change(first,'late composition',true,generation);f.fire(timer)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,'fresh composition');assert.equal(edit.composing,true);assert.equal(edit.commitRequested,false)
        f.change(first,'fresh final');f.change(second,'independent final')
        assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,2);assert.deepEqual(probe.fieldActions,[])
        await f.advance(399);assert.deepEqual(f.calls,[]);await f.advance(1)
        assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh final',at:413},{action:'setSecond',value:'independent final',at:413}])
        f.fire(timer);probe.resumeFieldActions();await f.advance(1000)
        assert.equal(f.calls.length,2);assert.equal(f.state('saved'),'');assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       })
       await test('native fields: '+attr+' roundtrip cannot revive callbacks from either old generation', async () => {
        const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration, original=first[attr]
        assert.notEqual(original,value)
        f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
        await f.frame([{[attr]:value},{}]);const intermediate=first.fieldGeneration
        assert.equal(intermediate,generation+1);assert.equal(first[attr],value)
        f.change(first,'intermediate');const intermediateTimer=probe.fieldEdits.get(first).timer
        await f.frame()
        assert.equal(first[attr],original);assert.equal(first.fieldGeneration,generation+2);assert.equal(probe.liveRoot.children[0],first)
        assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
        for(const stale of [generation,intermediate]) { f.change(first,'late',false,stale);f.finish(first,stale) }
        f.fire(timer);f.fire(intermediateTimer);assert.equal(probe.fieldEdits.size,0);assert.deepEqual(f.calls,[])
        f.change(first,'fresh composition',true);const edit=probe.fieldEdits.get(first)
        for(const stale of [generation,intermediate]) { f.change(first,'late composition',true,stale);f.finish(first,stale) }
        f.fire(timer);f.fire(intermediateTimer)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,'fresh composition');assert.equal(edit.commitRequested,false);assert.equal(edit.composing,true)
        await f.advance(23);f.change(first,'fresh');const current=edit.timer
        for(const stale of [generation,intermediate]) { f.change(first,'late',false,stale);f.finish(first,stale) }
        f.fire(timer);f.fire(intermediateTimer)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,'fresh');assert.equal(edit.timer,current);assert.equal(f.scheduled.get(current).at,423)
        await f.advance(399);assert.deepEqual(f.calls,[]);await f.advance(1)
        assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:423}]);assert.equal(f.state('first'),'fresh');assert.equal(first.fieldGeneration,generation+2)
        f.fire(timer);f.fire(intermediateTimer);f.fire(current);await f.advance(1000)
        assert.equal(f.calls.length,1);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       })
       await test('native fields: unchanged '+attr+' at default and nondefault preserves pending and composing edits', async () => {
        for(const unchanged of [new U.VeraUiNode()[attr],value]) {
         const f=await fieldProbe(), {probe,first}=f
         await f.frame([{[attr]:unchanged},{}]);const generation=first.fieldGeneration
         assert.equal(first[attr],unchanged)
         f.change(first,'pending');const edit=probe.fieldEdits.get(first), timer=edit.timer
         for(let i=0;i<3;i++) {
          await f.advance(100);await f.frame([{[attr]:unchanged},{}])
          assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation);assert.equal(probe.fieldEdits.get(first),edit)
          assert.equal(edit.value,'pending');assert.equal(edit.base,'base');assert.equal(edit.timer,timer);assert.equal(f.scheduled.size,1);assert.equal(f.scheduled.get(timer).at,400);assert.equal(first.fieldValue,'base');assert.equal(first.value,'base')
         }
         assert.deepEqual(f.calls,[]);assert.deepEqual(f.writes,[]);await f.advance(99);assert.deepEqual(f.calls,[]);await f.advance(1)
         assert.deepEqual(f.calls,[{action:'setFirst',value:'pending',at:400}]);assert.equal(f.state('first'),'pending');assert.equal(probe.fieldEdits.size,0)
         const g=await fieldProbe(), node=g.first, p=g.probe
         await g.frame([{[attr]:unchanged},{}]);const composingGeneration=node.fieldGeneration
         g.change(node,'composition',true);g.finish(node);p.handleAction('save',7);p.handleBoolAction('toggle',true)
         const composing=p.fieldEdits.get(node), queued=[...p.fieldActions]
         await g.advance(100);await g.frame([{[attr]:unchanged},{}])
          assert.equal(node.fieldGeneration,composingGeneration);assert.equal(p.fieldEdits.get(node),composing);assert.equal(composing.composing,true);assert.equal(composing.commitRequested,true);assert.equal(node.fieldValue,'base');assert.equal(node.value,'base');assert.equal(composing.base,'base');assert.deepEqual(g.writes,[])
         assert.deepEqual(p.fieldActions,queued);assert.equal(queued.length,2);assert.equal(g.scheduled.size,0);assert.deepEqual(g.calls,[])
         g.change(node,'final');await g.settle()
         assert.deepEqual(g.calls,[{action:'setFirst',value:'final',at:100},{action:'save',value:7,at:100},{action:'toggle',value:true,at:100}])
         assert.equal(g.state('saved'),'final/other');assert.equal(p.fieldEdits.size,0);assert.deepEqual(p.fieldActions,[]);assert.equal(g.scheduled.size,0);assert.equal(p.error,'')
        }
       })
      }
      for(const [attr,value] of Object.entries({label:'Updated label',style:'outlined',requiredMessage:'Required now',minLengthMessage:'Too short now',maxLengthMessage:'Too long now',patternMessage:'Invalid pattern now',emailMessage:'Invalid email now'})) await test('native fields: cosmetic '+attr+' change preserves generation, pending edit and deadline', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       assert.notEqual(first[attr],value)
       f.change(first,'pending');const edit=probe.fieldEdits.get(first), timer=edit.timer
       for(let i=0;i<3;i++) {
        const next=attr==='style'?['multiline','default','multiline'][i]:value+i;await f.advance(100);await f.frame([{[attr]:next},{}])
        assert.equal(first[attr],next);assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation)
        assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.value,'pending');assert.equal(edit.base,'base');assert.equal(edit.composing,false);assert.equal(edit.commitRequested,false)
        assert.equal(edit.timer,timer);assert.equal(f.scheduled.size,1);assert.equal(f.scheduled.get(timer).at,400);assert.equal(first.fieldValue,'base');assert.equal(first.value,'base')
       }
       assert.deepEqual(f.writes,[]);await f.advance(99);assert.deepEqual(f.calls,[]);await f.advance(1)
       assert.deepEqual(f.calls,[{action:'setFirst',value:'pending',at:400}]);assert.equal(f.state('first'),'pending');assert.equal(first.fieldGeneration,generation)
       f.fire(timer);await f.advance(1000);assert.equal(f.calls.length,1);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      for(const transition of ['external','kind','action','enabled','remove']) await test('native fields: '+transition+' reconciliation cancels pending and rejects old callbacks', async () => {
      const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
      f.change(first,'stale');const timer=probe.fieldEdits.get(first).timer
      await f.advance(100)
      if(transition==='external') { await f.external({first:'external'}) }
      else if(transition==='remove')await f.frame([])
      else await f.frame([{[transition]:{kind:'text',action:'normalize',enabled:false}[transition]},{}])
      assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert(!f.scheduled.has(timer))
       assert.equal(first.fieldGeneration,generation+(transition==='remove'?0:1))
       if(transition==='external') { assert.equal(first.value,'external');assert.equal(first.fieldValue,'external') }
       f.change(first,'late',false,generation);f.finish(first,generation)
       assert.equal(probe.fieldEdits.size,0)
      f.fire(timer);await f.advance(1000);assert.deepEqual(f.calls,[]);assert.equal(probe.error,'')
     })
      await test('native fields: external update without pending edit bumps generation and rejects stale native callbacks', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       assert.equal(probe.fieldEdits.size,0)
       await f.external({first:'external'})
       assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation+1);assert.equal(first.value,'external');assert.equal(first.fieldValue,'external')
       f.change(first,'stale',false,generation);f.finish(first,generation);await f.advance(1000)
       assert.deepEqual(f.calls,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(f.state('first'),'external')
       f.change(first,'fresh');const edit=probe.fieldEdits.get(first), timer=edit.timer
       f.change(first,'late',false,generation);f.finish(first,generation)
       assert.equal(probe.fieldEdits.get(first),edit);assert.equal(edit.timer,timer);assert(f.scheduled.has(timer))
       await f.advance(400);assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:1400}]);assert.equal(f.state('first'),'fresh');assert.equal(first.fieldGeneration,generation+1);assert.equal(probe.error,'')
      })
      for(const transition of ['external','kind','action','enabled','remove']) await test('native fields: '+transition+' invalidation of a composing field cancels queued actions', async () => {
       const f=await fieldProbe(), {probe,first,second}=f, generation=first.fieldGeneration
       f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
       f.change(first,'composing',true);f.change(second,'other composing',true)
       probe.handleAction('save',5);probe.handleBoolAction('toggle',false)
       assert.deepEqual(f.calls,[]);assert.equal(probe.fieldActions.length,2);assert.equal(f.scheduled.size,0)
       if(transition==='external') { await f.external({first:'external'}) }
       else if(transition==='remove')await f.frame([])
       else await f.frame([{[transition]:{kind:'text',action:'normalize',enabled:false}[transition]},{}])
       assert.equal(first.fieldGeneration,generation+(transition==='remove'?0:1));assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.resumingFieldActions,false)
       f.change(first,'stale',false,generation);f.finish(first,generation);f.fire(timer);probe.resumeFieldActions()
       assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,0)
       if(transition!=='remove') {
        f.change(second,'fresh second');assert.deepEqual(f.calls,[]);assert.equal(f.scheduled.size,1)
        await f.advance(400);assert.deepEqual(f.calls,[{action:'setSecond',value:'fresh second',at:400}]);assert.equal(f.state('second'),'fresh second')
       }
       await f.advance(1000);assert.equal(f.state('saved'),'');assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      await test('native fields: kind/action/enabled round trips cannot revive callbacks from the old generation', async () => {
      for(const key of ['kind','action','enabled']) {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
       await f.frame([{[key]:{kind:'text',action:'normalize',enabled:false}[key]},{}]);await f.frame()
       assert.equal(first.fieldGeneration,generation+2);assert.equal(probe.liveRoot.children[0],first)
       f.change(first,'stale',false,generation);f.finish(first,generation);assert.equal(probe.fieldEdits.size,0)
       f.change(first,'fresh');const edit=probe.fieldEdits.get(first)
       f.fire(timer);assert.equal(probe.fieldEdits.get(first),edit);assert.deepEqual(f.calls,[])
       await f.advance(400);assert.equal(f.state('first'),'fresh');assert.equal(f.calls.length,1)
      }
     })
     await test('native fields: stale-generation submit/blur cannot cancel a fresh edit on the retained node', async () => {
      const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
      f.change(first,'old');const oldTimer=probe.fieldEdits.get(first).timer
      await f.frame([{action:'normalize'},{}]);await f.frame()
      f.change(first,'fresh');const edit=probe.fieldEdits.get(first), timer=edit.timer
      f.finish(first,generation);f.change(first,'stale',false,generation);f.fire(oldTimer)
      assert.equal(probe.fieldEdits.get(first),edit,'old-generation finish must leave the current edit intact');assert.equal(edit.timer,timer);assert(f.scheduled.has(timer))
      await f.advance(400);assert.deepEqual(f.calls,[{action:'setFirst',value:'fresh',at:400}]);assert.equal(f.state('first'),'fresh')
     })
     for(const gate of ['previewOnly','disposed','removed']) await test('native fields: '+gate+' rejects new input and finish', async () => {
      const f=await fieldProbe(), {probe,first}=f
      if(gate==='removed')probe.liveRoot=null;else probe[gate]=true
      f.change(first,'ignored');f.finish(first);await f.advance(1000)
      assert.deepEqual(f.calls,[]);assert.deepEqual(f.writes,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
     })
      for(const transition of ['load','disappear','reappear']) await test('native fields: real '+transition+' '+(transition==='load'?'discards':'preserves')+' pending edits and rejects old callbacks', async () => {
       const f=await fieldProbe(), {probe,first,second}=f, generation=probe.effectGeneration, fieldGeneration=first.fieldGeneration
       f.change(first,'old');f.change(second,'older');const timers=[...probe.fieldEdits.values()].map(edit=>edit.timer)
       const expected=transition==='load'?[]:[{action:'setFirst',value:'old',at:0},{action:'setSecond',value:'older',at:0}]
       if(transition==='load')await f.reload();else {
        probe.aboutToDisappear();await settlePreview(probe);assert.equal(probe.disposed,true);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
        assert.equal(f.state('first'),'old');assert.equal(f.state('second'),'older')
        assert.deepEqual(f.saves.map(state=>[state.first,state.second]),[['old','other'],['old','older']])
        if(transition==='reappear') { probe.aboutToAppear();await settlePreview(probe) }
       }
       assert(probe.effectGeneration>generation);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
       for(const timer of timers)f.fire(timer)
        f.finish(first,fieldGeneration);f.change(first,'late',false,fieldGeneration);await f.advance(1000);assert.deepEqual(f.calls,expected)
       assert.equal(f.saves.length,expected.length)
       if(transition!=='disappear') {
        const fresh=probe.liveRoot.children[0]
        f.change(fresh,'new');const edit=probe.fieldEdits.get(fresh)
        for(const timer of timers)f.fire(timer)
        assert.equal(probe.fieldEdits.get(fresh),edit);await f.advance(400);assert.equal(f.state('first'),'new');assert.equal(f.calls.length,expected.length+1)
       }
       assert.equal(probe.error,'')
      })
      for(const transition of ['cancelField','cancelFields','invalidateEffects','load','disappear','reappear']) await test('native fields: queued actions are canceled by '+transition+' and never revived by fresh input', async () => {
       const f=await fieldProbe(), {probe,first,second}=f, generation=first.fieldGeneration, effectGeneration=probe.effectGeneration
       f.change(first,'old');const timer=probe.fieldEdits.get(first).timer
       f.change(first,'composing',true);f.change(second,'also composing',true)
       probe.handleAction('save',3);probe.handleBoolAction('toggle',true)
       assert.deepEqual(f.calls,[]);assert.equal(probe.fieldActions.length,2)
       if(transition==='cancelField') {
        probe.cancelField(first);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,1)
        probe.cancelField(second)
       }
       else if(transition==='disappear'||transition==='reappear') {
        probe.aboutToDisappear();await settlePreview(probe)
        if(transition==='reappear') { probe.aboutToAppear();await settlePreview(probe) }
       } else if(transition==='load')await f.reload()
        else probe[transition]()
        await f.settle()
       assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.resumingFieldActions,false)
        assert.equal(probe.effectGeneration>effectGeneration,!['cancelField','cancelFields'].includes(transition))
        const draining=transition==='disappear'||transition==='reappear'
        const expected=draining?[{action:'setFirst',value:'composing',at:0},{action:'setSecond',value:'also composing',at:0}]:[]
        assert.deepEqual(f.calls,expected)
        assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),draining?[['composing','other',''],['composing','also composing','']]:[])
        const saves=[...f.saves]
        if(transition!=='cancelField') {
         f.change(first,'stale',false,generation);f.finish(first,generation)
         assert.equal(probe.fieldEdits.size,0)
        }
        f.fire(timer);probe.resumeFieldActions();await f.advance(1000)
        assert.deepEqual(f.calls,expected);assert.deepEqual(f.saves,saves);assert.equal(f.state('saved'),'')
        if(transition!=='disappear') {
          const fresh=probe.liveRoot.children[0], restored=transition==='reappear'&&probe.activeOptions.mode==='LIVE_PERSISTENT'
          const secondValue=restored?'also composing':'other'
          assert.equal(fresh.value,restored?'composing':'base');assert.equal(fresh.fieldValue,fresh.value)
          assert.equal(probe.liveRoot.children[1].value,secondValue)
         assert.equal(V.decodeRuntimeValue(JSON.parse(await f.snapshot())).fields.get('second').value,secondValue)
         f.change(fresh,'fresh');assert.equal(f.scheduled.size,1);assert.deepEqual(f.calls,expected)
         await f.advance(400);assert.deepEqual(f.calls,[...expected,{action:'setFirst',value:'fresh',at:1400}]);assert.equal(f.state('saved'),'')
         probe.handleAction('save',8);await f.settle()
         assert.deepEqual(f.calls,[...expected,{action:'setFirst',value:'fresh',at:1400},{action:'save',value:8,at:1400}]);assert.equal(f.state('saved'),'fresh/'+secondValue)
         assert.deepEqual(f.saves.map(state=>[state.first,state.second,state.saved]),[...saves.map(state=>[state.first,state.second,state.saved]),['fresh',secondValue,''],['fresh',secondValue,'fresh/'+secondValue]])
        }
        const finalCalls=[...f.calls], finalSaves=[...f.saves]
        f.fire(timer);probe.resumeFieldActions();await f.advance(1000)
        assert.deepEqual(f.calls,finalCalls);assert.deepEqual(f.saves,finalSaves);assert.deepEqual(probe.fieldActions,[]);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      for(const method of ['handleAction','handleBoolAction']) await test('native fields: '+method+' flushes latest independent edits before action reads state', async () => {
      const f=await fieldProbe(), {probe,first,second}=f
      f.change(first,'one');f.change(first,'latest');f.change(second,'two')
      const timers=[...f.history.keys()]
      await f.advance(20);probe[method](method==='handleAction'?'save':'toggle',method==='handleAction'?7:true);await f.settle()
      assert.deepEqual(f.calls,[{action:'setFirst',value:'latest',at:20},{action:'setSecond',value:'two',at:20},{action:method==='handleAction'?'save':'toggle',value:method==='handleAction'?7:true,at:20}])
      assert.equal(f.state('saved'),'latest/two');assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
      for(const timer of timers)f.fire(timer)
      await f.advance(1000);assert.equal(f.calls.length,3);assert.equal(probe.error,'')
     })
     for(const method of ['handleAction','handleBoolAction']) await test('native fields: '+method+' aborts outer action if flushing changes program generation', async () => {
const f=await fieldProbe(), {probe,first}=f
       f.change(first,'new program')
       let loading
       f.onInputApplied(action=>{if(action==='setFirst')loading=f.reload()})
       probe[method](method==='handleAction'?'save':'toggle',method==='handleAction'?0:true)
       await f.settle();assert(loading instanceof Promise);await loading;await f.settle()
      assert.deepEqual(f.calls.map(call=>call.action),['setFirst']);assert.equal(f.state('saved'),'');assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
     })
      await test('native fields: normal accepted commits retain native generation across debounce, finish and action flush', async () => {
       const f=await fieldProbe(), {probe,first}=f, generation=first.fieldGeneration
       f.change(first,'debounced',false,generation);await f.advance(400)
       assert.equal(first.fieldGeneration,generation);assert.equal(first.fieldValue,'debounced')
       f.change(first,'finished',false,generation);f.finish(first,generation);await f.settle()
       assert.equal(first.fieldGeneration,generation);assert.equal(first.fieldValue,'finished')
       f.change(first,'flushed',false,generation);probe.handleAction('save',2);await f.settle()
       assert.deepEqual(f.calls,[{action:'setFirst',value:'debounced',at:400},{action:'setFirst',value:'finished',at:400},{action:'setFirst',value:'flushed',at:400},{action:'save',value:2,at:400}])
       assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation);assert.equal(first.fieldValue,'flushed');assert.equal(f.state('saved'),'flushed/other')
       for(const timer of f.history.keys())f.fire(timer)
       f.finish(first,generation);await f.advance(1000);assert.equal(f.calls.length,4);assert.equal(probe.fieldEdits.size,0);assert.deepEqual(probe.fieldActions,[]);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
      })
      await test('native fields: real handler normalization retains node identity but bumps native generation once', async () => {
       const f=await fieldProbe(), {probe,first}=f
       await f.external({note:'normalize'});const generation=first.fieldGeneration
       f.change(first,'raw value');assert.equal(first.fieldValue,'base');assert.deepEqual(f.writes,[])
       f.finish(first);await f.settle()
       assert.deepEqual(f.calls,[{action:'normalize',value:'raw value',at:0}]);assert.equal(f.state('first'),'normalized');assert.equal(first.value,'normalized');assert.equal(first.fieldValue,'normalized')
       assert.equal(probe.liveRoot.children[0],first);assert.equal(first.fieldGeneration,generation+1);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0);assert.equal(probe.error,'')
       f.change(first,'stale',false,generation);f.finish(first,generation);probe.renderView()
       for(const timer of f.history.keys())f.fire(timer)
       await f.advance(1000);assert.equal(f.calls.length,1);assert.equal(first.fieldGeneration,generation+1);assert.equal(probe.fieldEdits.size,0);assert.equal(f.scheduled.size,0)
      })
     await test('native fields: source wires generation identity, native composition and finish without global epoch or keystroke trace', async () => {
      const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8'), live=fs.readFileSync(path.join(sourceRoot,'components/VeraLiveTree.ets'),'utf8')
      const clean=source=>source.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/[^\n]*/g,'')
      assert(!/\bfieldEpoch\b|\bfieldDraft\b/.test(clean(renderer)+'\n'+clean(live)),'field builder must not use global fieldEpoch or traced fieldDraft')
      assert.match(live,/@Trace\s+fieldValue:\s*string\s*=\s*''/);assert.match(live,/@Trace\s+fieldGeneration:\s*number\s*=\s*0/)
      assert.match(renderer,/private fieldEdits:\s*Map<LiveNode,\s*FieldEdit>/)
      const change=declaration(renderer,'  private changeField(')
      assert(!/\bnode\.\w+\s*(?:=(?!=)|\+\+|--|\+=|-=)/.test(change),'changeField must not write traced node state')
      const field=renderer.slice(renderer.indexOf("} else if (node.kind === 'field') {"),renderer.indexOf("} else if (node.kind === 'toggle' || node.kind === 'checkbox') {"))
      assert(field.length>0,'field builder')
      assert.match(field,/ForEach\(\[node\.fieldGeneration\],\s*\(generation:\s*number\)\s*=>/)
      assert.match(field,/TextInput\(\{[^}]*\btext:\s*node\.fieldValue\s*,\s*controller:\s*this\.fieldController\(node,\s*generation\)\s*\}/)
      assert.match(renderer,/private fieldInputs:\s*Map<LiveNode,\s*FieldInput>/)
      assert.match(declaration(renderer,'class FieldInput'),/controller:\s*TextInputController\s*=\s*new TextInputController\(\)/)
      assert.match(declaration(field,'.onSubmit('),/this\.finishField\(node,\s*generation,\s*event\.text\)/)
      assert.match(declaration(field,'.onEditChange('),/if\s*\(!editing\)\s*\{\s*this\.endFieldEditing\(node,\s*generation\)/)
      const onChange=declaration(field,'.onChange(')
      assert.match(onChange,/this\.changeField\(node,\s*generation,\s*v,\s*previewText\s*!==\s*undefined\s*&&\s*previewText\.value\.length\s*>\s*0\)/)
      assert(!/\bnode\.\w+\s*=(?!=)/.test(onChange),'onChange must not write traced node state')
      assert.match(field,/\},\s*\(generation:\s*number\)\s*=>\s*generation\.toString\(\)\)/)
      const render=declaration(renderer,'  private renderView(')
      assert(render.indexOf('this.reconcileFields()')>render.indexOf('reconcile(this.liveRoot!, root!)'))
      assert.match(declaration(renderer,'  private invalidateEffects('),/this\.cancelFields\(\)/)
        for(const [name,payload] of [['handleAction','numberPayload'],['handleBoolAction','booleanPayload']]) {
         const method=declaration(renderer,'  private '+name+'(')
         assert.match(method,new RegExp('this\\.dispatchFieldAction\\(action, '+payload+'\\(value\\), true, node\\)'))
        }
        const resume=declaration(renderer,'  private resumeFieldActions(')
        assert(resume.indexOf('this.flushFields()')>=0&&resume.indexOf('this.flushFields()')<resume.indexOf('this.postAction('),'deferred action flush precedes host admission')
        assert.match(declaration(renderer,'  private postAction('),/this\.runtime\.postInput\(this\.handle!, this\.inputEvent\(next\)\)/)
        assert(!/VeraNumberValue|VeraBooleanValue|VeraStringValue/.test(clean(renderer)),'renderer payloads stay at the DTO boundary')
     })
      async function tickerProbe() {
     const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8'), f=await fieldProbe(true,null,10000), probe=f.probe
      const methods=['reconcileTimers','collectTickers','stopAllTimers','stopPartsTimer'].map(name=>declaration(renderer,'  private '+name+'(')).join('\n')
     const compiled=ts.transpileModule(declaration(renderer,'class TimerConfig')+'\nclass Probe { '+methods+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
     assert.deepEqual((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error),[])
     const Probe=new Function('StageTrace','clearInterval',compiled.outputText+';return Probe')(StageTrace,id=>{stops.push(id);f.intervals.delete(id)})
     let now=10000, surfaceStops=0
     const starts=[], stops=[], calls=[], scheduled=f.intervals
      for(const name of ['reconcileTimers','collectTickers','stopAllTimers','stopPartsTimer'])probe[name]=Probe.prototype[name]
      Object.assign(probe,{spinTimer:-1,spinPeriod:0,motionTimer:-1,partsTimer:-1,motionTriggers:new Map(),poseAnims:new Map(),stopSurfaceLoop(){surfaceStops++}})
     function syncTimers() {
      for(const [id,timer] of scheduled)if(timer.nextAt===undefined){timer.nextAt=now+timer.interval;starts.push(id)}
      for(const id of starts)if(!scheduled.has(id)&&!stops.includes(id))stops.push(id)
     }
     function collect() {
      calls.splice(0,calls.length,...f.calls.map(call=>({action:call.action,elapsed:call.value,at:call.at})))
      assert.equal(probe.error,'')
     }
     async function advance(ms) {
      const end=now+ms
      syncTimers()
      while(true) {
       const due=[...scheduled.values()].filter(timer=>timer.nextAt<=end).sort((a,b)=>a.nextAt-b.nextAt)[0]
       if(!due)break
       f.elapse(due.nextAt-now);now=due.nextAt;due.nextAt+=due.interval;due.callback();await f.settle();collect();syncTimers()
      }
      f.elapse(end-now);now=end;await f.settle();collect()
     }
     const reconcile=probe.reconcileTimers.bind(probe), stop=probe.stopTimer.bind(probe)
     let wanted=null
     probe.reconcileTimers=root=>{if(root===null||root.kind==='ticker'||!root.children.some(node=>node.kind==='field'))wanted=root;reconcile(wanted);syncTimers()}
     probe.startTimer=((start)=> (id,config)=>{start(id,config);syncTimers()})(probe.startTimer.bind(probe))
     probe.stopTimer=id=>{stop(id);syncTimers()}
     function schedule(callback,interval) {const id=Math.max(0,...scheduled.keys(),...starts)+1;scheduled.set(id,{callback,interval,nextAt:now+interval});starts.push(id);return id}
     return {probe,scheduled,starts,stops,calls,schedule,advance,elapse(ms){now+=ms;f.elapse(ms)},async fire(handle){assert(scheduled.has(handle));scheduled.get(handle).callback();await f.settle();collect()},surfaceStops:()=>surfaceStops}
    }
   function ticker(id='clock',interval=1000,action='old',checked=true) {
    return Object.assign(new U.VeraUiNode(),{kind:'ticker',tickerId:id,minimum:interval,action,checked,children:[]})
   }
   function tickerTree(children) { return Object.assign(new U.VeraUiNode(),{kind:'column',children}) }
   function assertNoTickers(probe) {
    for(const name of ['timers','timerConfigs','timerLastFire'])assert.equal(probe[name].size,0,name)
   }
   await test('native tickers: handler replacement preserves handle, phase and last fire', async () => {
    const {probe,scheduled,starts,stops,calls,advance}=await tickerProbe()
    probe.reconcileTimers(ticker())
    const handle=probe.timers.get('clock')
         await advance(1000);assert.deepEqual(calls,[{action:'old',elapsed:1000,at:11000}])
         await advance(250);probe.reconcileTimers(ticker('clock',1000,'replacement'))
    assert.equal(probe.timers.get('clock'),handle);assert.deepEqual(starts,[handle]);assert.deepEqual(stops,[])
    assert.equal(scheduled.get(handle).nextAt,12000);assert.equal(probe.timerLastFire.get('clock'),11000)
    assert.equal(probe.timerConfigs.get('clock').interval,1000);assert.equal(probe.timerConfigs.get('clock').action,'replacement')
         await advance(749);assert.equal(calls.length,1)
         await advance(1);assert.deepEqual(calls[1],{action:'replacement',elapsed:1000,at:12000});assert.equal(probe.inFlight,null)
   })
   await test('native tickers: in the background a tick is skipped, not stopped, and the next one carries the gap', async () => {
    const {probe,calls,advance}=await tickerProbe()
    probe.reconcileTimers(ticker())
         await advance(1000);assert.equal(calls.length,1)
    probe.appForeground=false;await advance(5000);assert.equal(calls.length,1,'nothing runs while the app is away')
    probe.appForeground=true;await advance(1000)
    assert.equal(calls.length,2);assert.equal(calls[1].elapsed,6000,'the first tick back counts the time away')
   })
   await test('native tickers: stable handler never restarts under repeated reconciliation', async () => {
    const {probe,scheduled,starts,stops,calls,advance}=await tickerProbe()
    probe.reconcileTimers(ticker())
    const handle=probe.timers.get('clock')
    for(let i=0;i<4;i++) {
     await advance(200);probe.reconcileTimers(ticker())
     assert.equal(probe.timers.get('clock'),handle);assert.equal(probe.timerLastFire.get('clock'),10000)
     assert.equal(scheduled.get(handle).nextAt,11000)
    }
    assert.deepEqual(starts,[handle]);assert.deepEqual(stops,[]);assert.equal(calls.length,0)
         await advance(200);assert.deepEqual(calls,[{action:'old',elapsed:1000,at:11000}])
   })
   await test('native tickers: interval change restarts and dispatches the new action', async () => {
    const {probe,scheduled,starts,stops,calls,advance}=await tickerProbe()
    probe.reconcileTimers(ticker())
    const old=probe.timers.get('clock')
         await advance(400);probe.reconcileTimers(ticker('clock',250,'faster'))
    const handle=probe.timers.get('clock')
    assert.notEqual(handle,old);assert.deepEqual(starts,[old,handle]);assert.deepEqual(stops,[old]);assert(!scheduled.has(old))
    assert.equal(probe.timerConfigs.get('clock').interval,250);assert.equal(probe.timerLastFire.get('clock'),10400)
    assert.equal(probe.timerConfigs.get('clock').action,'faster');assert.equal(scheduled.get(handle).nextAt,10650)
         await advance(249);assert.equal(calls.length,0)
         await advance(1);assert.deepEqual(calls,[{action:'faster',elapsed:250,at:10650}])
   })
   await test('native tickers: removal and disable clear all maps and cancel callbacks', async () => {
    for(const root of [null,tickerTree([]),ticker('clock',1000,'old',false)]) {
     const {probe,scheduled,stops,calls,advance}=await tickerProbe()
     probe.reconcileTimers(ticker())
     const handle=probe.timers.get('clock')
     await advance(400);probe.reconcileTimers(root)
     assertNoTickers(probe);assert.equal(scheduled.size,0);assert.deepEqual(stops,[handle])
     await advance(2000);assert.equal(calls.length,0)
     probe.stopTimer('clock');assertNoTickers(probe);assert.deepEqual(stops,[handle])
    }
   })
   await test('native tickers: readding an id starts a fresh phase and action', async () => {
    const {probe,scheduled,starts,stops,calls,advance}=await tickerProbe()
    probe.reconcileTimers(ticker())
    const old=probe.timers.get('clock')
         await advance(400);probe.reconcileTimers(null);assertNoTickers(probe)
         await advance(300);probe.reconcileTimers(ticker('clock',1000,'readded'))
    const handle=probe.timers.get('clock')
    assert.notEqual(handle,old);assert.deepEqual(starts,[old,handle]);assert.deepEqual(stops,[old])
    assert.equal(probe.timerLastFire.get('clock'),10700);assert.equal(scheduled.get(handle).nextAt,11700)
    assert.equal(probe.timerConfigs.get('clock').action,'readded')
         await advance(999);assert.equal(calls.length,0)
         await advance(1);assert.deepEqual(calls,[{action:'readded',elapsed:1000,at:11700}])
   })
   await test('native tickers: collection visits nested nodes and rejects inactive or invalid tickers', async () => {
    const {probe,scheduled,calls,advance}=await tickerProbe()
    probe.reconcileTimers(tickerTree([tickerTree([ticker('nested',100,'nestedTick')]),ticker('disabled',100,'disabled',false),ticker('zero',0),ticker('negative',-1),ticker('',100),ticker('noAction',100,'')]))
    assert.deepEqual([...probe.timerConfigs].map(([id,config])=>[id,{interval:config.interval,action:config.action}]),[['nested',{interval:100,action:'nestedTick'}]]);assert.equal(scheduled.size,1)
         await advance(100);assert.deepEqual(calls,[{action:'nestedTick',elapsed:100,at:10100}])
   })
    await test('native tickers: real elapsed time, minimum interval, transition and missing config guards', async () => {
     const {probe,scheduled,calls,elapse,fire}=await tickerProbe()
      probe.reconcileTimers(ticker('direct',1,'fast'))
     const handle=probe.timers.get('direct')
     assert.equal(probe.timerConfigs.get('direct').action,'fast');assert.equal(probe.timerConfigs.get('direct').interval,1);assert.equal(scheduled.get(handle).interval,16)
     elapse(19.6);await fire(handle);assert.deepEqual(calls,[{action:'fast',elapsed:20,at:10019.6}])
     const last=probe.timerLastFire.get('direct')
     probe.transitioning=true;elapse(30);await fire(handle)
     assert.equal(calls.length,1);assert.equal(probe.timerLastFire.get('direct'),last);assert.equal(probe.transitioning,true)
     probe.transitioning=false;elapse(10)
     await fire(handle);assert.deepEqual(calls[1],{action:'fast',elapsed:40,at:10059.6});assert.equal(probe.inFlight,null)
     probe.timerConfigs.delete('direct');elapse(20);await fire(handle)
     assert.equal(calls.length,2);assert.equal(probe.inFlight,null)
    })
   await test('native tickers: stopAllTimers clears configs and other animation state', async () => {
    const f=await tickerProbe(), {probe,scheduled,stops,calls,advance}=f
    probe.reconcileTimers(tickerTree([ticker('one',1000,'oneTick'),ticker('two',1500,'twoTick')]))
    probe.spinTimer=f.schedule(()=>assert.fail('spin survived cleanup'),16);probe.spinPeriod=1000
     probe.motionTimer=f.schedule(()=>assert.fail('motion survived cleanup'),16)
     probe.partsTimer=f.schedule(()=>assert.fail('parts survived cleanup'),16)
     for(const name of ['motionTriggers','poseAnims'])probe[name].set('fixture',{})
     probe.stopAllTimers();assertNoTickers(probe);assert.equal(scheduled.size,0);assert.equal(stops.length,5)
     assert.equal(probe.spinTimer,-1);assert.equal(probe.spinPeriod,0);assert.equal(probe.motionTimer,-1);assert.equal(probe.partsTimer,-1);assert.equal(f.surfaceStops(),1)
     for(const name of ['motionTriggers','poseAnims'])assert.equal(probe[name].size,0,name)
          await advance(3000);assert.equal(calls.length,0)
     probe.stopAllTimers();assertNoTickers(probe);assert.equal(stops.length,5);assert.equal(f.surfaceStops(),2)
   })
  await test('native declarations match all nine C++ exports and local package wiring', async () => {
   const root=path.resolve(sourceRoot,'../../../..'), nativeDir=path.join(root,'entry/src/main/cpp/types/libllama')
   const cpp=fs.readFileSync(path.join(root,'entry/src/main/cpp/napi_llama.cpp'),'utf8')
   const typings=fs.readFileSync(path.join(nativeDir,'index.d.ts'),'utf8')
   const nativeNames=[...cpp.matchAll(/\{"(llama\w+)", nullptr,/g)].map(m=>m[1]).sort()
   assert.equal(nativeNames.length,9)
   assert.deepEqual([...typings.matchAll(/export const (llama\w+):/g)].map(m=>m[1]).sort(),nativeNames)
   const pkg=JSON.parse(fs.readFileSync(path.join(nativeDir,'oh-package.json5'),'utf8'))
   assert.equal(pkg.name,'libllama.so');assert.equal(pkg.types,'./index.d.ts')
   assert.equal(JSON.parse(fs.readFileSync(path.join(root,'entry/oh-package.json5'),'utf8')).dependencies[pkg.name],'file:./src/main/cpp/types/libllama')
   const engine=fs.readFileSync(path.join(sourceRoot,'vera/LlamaEngine.ets'),'utf8')
   assert.equal((engine.match(/^import .* from 'libllama.so'$/gm)||[]).length,1)
   assert(!engine.includes('interface NativeLlama'));assert(!engine.includes('interface NativeGenerateResult'));assert(!engine.includes('getNative()'))
   const calls=[], mock=Object.fromEntries(nativeNames.map(name=>[name,(...args)=>{calls.push([name,...args]);return name==='llamaBuildInfo'?'fixture':name==='llamaEmbedInit'?true:name==='llamaEmbedBatch'?[[1]]:new Float32Array([.5])}]))
   const L=platformModule('LlamaEngine',{'@kit.CoreFileKit':{fileIo:{}},'@kit.ArkTS':{util:{}},'libllama.so':mock})
   assert.equal(L.nativeEmbedInit('{}'),true);assert.deepEqual(L.nativeEmbedBatch(['a']),[[1]])
   const query=[1],corpus=new Float32Array([2]);assert.deepEqual(L.nativeScanCorpus(query,corpus,1,1),new Float32Array([.5]));L.nativeEmbedFree();assert.equal(L.nativeBuildInfo(),'fixture')
   assert.deepEqual(calls.map(c=>c[0]),['llamaEmbedInit','llamaEmbedBatch','llamaScanCorpus','llamaEmbedFree','llamaBuildInfo'])
   assert.equal(calls[2][1],query);assert.equal(calls[2][2],corpus)
   mock.llamaBuildInfo=()=>{throw Error('old native module')};assert.equal(L.nativeBuildInfo(),'unknown')
  })
  await test('chat writes close once, preserve primary errors and keep save contract', async () => {
   const failure={open:new Error('open failed'),write:new Error('write failed'),close:new Error('close failed')}
   for(const mode of ['ok','open','write','close','write+close']) {
    const calls=[], file={fd:42}, logs=[]
    const disk={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},mkdirSync(){},openSync(p,flags){calls.push(['open',p,flags]);if(mode==='open')throw failure.open;return file},writeSync(fd,text){calls.push(['write',fd,text]);if(mode.includes('write'))throw failure.write},closeSync(f){calls.push(['close',f]);if(mode.includes('close'))throw failure.close}}
    const S=platformModule('ChatStore',{'@kit.CoreFileKit':{fileIo:disk}},'\nexport { writeText }')
    const original=mode==='open'?failure.open:mode.includes('write')?failure.write:failure.close
    if(mode==='ok')S.writeText('/chat','你好 café');else assert.throws(()=>S.writeText('/chat','content'),e=>e===original)
    assert.equal(calls.filter(c=>c[0]==='close').length,mode==='open'?0:1)
    if(mode!=='open')assert.equal(calls.at(-1)[1],file)
    calls.length=0
    const store=new S.ChatStore(),chat=new S.StoredChat();store.init('/fixture');chat.id='saved';chat.title='你好';chat.messages=[new S.StoredMessage()]
    const error=console.error;console.error=text=>logs.push(text)
    try { assert.equal(store.save(chat),undefined) } finally { console.error=error }
    assert(chat.updatedAt>0);assert.equal(logs.length,mode==='ok'?0:1)
    if(logs.length)assert.equal(logs[0],'VERA-CHAT save failed: '+original.message)
    if(mode==='ok')assert.deepEqual(JSON.parse(calls.find(c=>c[0]==='write')[2]),JSON.parse(JSON.stringify(chat)))
    assert.equal(calls.filter(c=>c[0]==='close').length,mode==='open'?0:1)
   }
  })
  try {
   const L=platformModule('LlamaEngine',{'@kit.CoreFileKit':{fileIo:{}},'libllama.so':{},'@kit.ArkTS':{util:{TextDecoder:{create(encoding){assert.equal(encoding,'utf-8');return{decodeToString:bytes=>new TextDecoder(encoding).decode(bytes)}}}}}})
   for(const text of ['', 'plain ASCII', '你好 — café'])assert.equal(await L.loadRawfileText({getRawFileContent:async name=>{assert.equal(name,'fixture');return new Uint8Array(Buffer.from(text))}},'fixture'),text)
   for(const sync of [true,false]) {
    const error=new Error(sync?'SDK synchronous throw':'SDK rejection')
    await assert.rejects(()=>L.loadRawfileText({getRawFileContent(){if(sync)throw error;return Promise.reject(error)}},'fixture'),e=>e===error)
   }
   results.push({name:'rawfile UTF-8 decoding and original SDK errors',result:'PASS'})
  } catch(e) { results.push({name:'rawfile UTF-8 decoding and original SDK errors',result:'FAIL',error:String(e.stack||e)}) }
  await test('renderer measurement survives state reconciliation only', async () => {
  global.ObservedV2=c=>c; global.Trace=()=>{};
  const L=loadSource(path.join(sourceRoot,'components/VeraLiveTree.ets'))
  const n=new U.VeraUiNode(); n.kind='adaptivecolumns'; n.minimum=240
  const live=L.toLive(n); assert.equal(live.layoutWidth,0); live.layoutWidth=600; L.reconcile(live,n); assert.equal(live.layoutWidth,600)
  n.kind='hero'; L.reconcile(live,n); assert.equal(live.layoutWidth,0); assert(!('layoutWidth' in n))
 })
 await test('catalogue and visual prompt contracts', async () => {
  const cat=loadVera('VeraUiCatalog'); const full=cat.describeCatalogForPrompt(); assert(full.includes('Hero'));assert(full.includes('AdaptiveColumns'))
  const selected=cat.describeCatalogForPrompt(new Set(['Hero','AdaptiveColumns'])); assert(selected.includes('Hero'));assert(selected.includes('AdaptiveColumns'))
  const skill=fs.readFileSync(path.join(sourceRoot,'../resources/rawfile/vera-skill.txt'),'utf8')
  const widget=fs.readFileSync(path.join(sourceRoot,'../resources/rawfile/vera-widget.txt'),'utf8')
  const chat=fs.readFileSync(path.join(sourceRoot,'vera/VeraChat.ets'),'utf8')
  assert(/focal/i.test(skill)&&/hierarchy/i.test(skill)&&/density/i.test(skill)&&/grouping/i.test(skill))
  assert(/preserve.*visual|visual.*preserve/i.test(skill));assert(/repair/i.test(skill));assert(/Hero/.test(widget)&&/AdaptiveColumns/.test(widget));assert(/visual preferences|visual direction|style preferences/i.test(chat))
 })
}
const report={expected:'All workflows and compatibility checks pass. New components decode correctly. Theme targets match the plan. Enabled text and button contrast is at least 4.5:1. Adaptive columns use one column before measurement and two only when both fit. Widget display and metric roles are capped at 32 vp.',revision:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:path.join(__dirname,'../..'),encoding:'utf8'}).trim(), command:process.argv.join(' '), sourceRoot, baseline, results, trees, contrasts, native:'Not run: host-only verification requested. ArkUI and native module calls are mocked; this does not replace an ArkTS build or device validation.'}
fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n')
console.log(`${results.filter(r=>r.result==='PASS').length}/${results.length} PASS; report ${output}`)
for(const r of results.filter(r=>r.result==='FAIL'))console.error(r.name+': '+r.error.split('\n')[0])
process.exitCode=results.some(r=>r.result==='FAIL')?1:0
}
main().catch(e=>{console.error(e);process.exitCode=1})
