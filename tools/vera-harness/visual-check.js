#!/usr/bin/env node
// Failure cases defined before production changes: lost state/handlers, absent or
// malformed components, stale source copies, unreadable text, wrong typography,
// widget oversizing, unmeasured/narrow columns, order loss, and lost live widths.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const cp = require('node:child_process')
const {loadVera, loadSource, sourceRoot} = require('./source-loader')
async function main() {
const C = loadVera('VeraCompiler'), V = loadVera('VeraInterpreter'), U = loadVera('VeraUi')
const output = path.resolve(process.argv[2] || '/tmp/vera-visual-verification.json')
const baseline = process.argv.includes('--capture-baseline')
const cases = [['counter','change',1,'count',8], ['countdown','start',0,'running',true], ['expense','setBudget',140,'budget',140], ['reading','save',0,'saved',true], ['habit','complete',0,'days',4]]
const results = [], trees = {}, contrasts = []
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
function test(name, action) { try { action(); results.push({name, result:'PASS'}) } catch(e) { results.push({name, result:'FAIL', error:String(e.stack || e)}) } }
function vm(bytecode) { return new V.VirtualMachine(V.deserializeVbc2(bytecode), new U.UiHostEnvironment()) }
function walk(node) { return [node, ...(node.children || []).flatMap(walk)] }
for (const [name, handler, value, field, expected] of cases) {
 test(name + ': compile/init/render/handler/save/reload', () => {
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
 if (!baseline) test(name + ': pre-change bytecode and saved state', () => {
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
 test('countdown: elapsed time and terminal boundary', () => {
  const bytecode=C.compileVeraSource(fs.readFileSync(path.join(__dirname,'examples/visual-countdown.vera'),'utf8')).vbc2
  const m=vm(bytecode); const started=m.execute('start',[m.execute('init'),new V.VeraNumberValue(0)])
  const tick=m.execute('tick',[started,new V.VeraNumberValue(1000)])
  assert.equal(tick.fields.get('remaining').value,89000)
  const done=m.execute('tick',[tick,new V.VeraNumberValue(100000)])
  assert.equal(done.fields.get('remaining').value,0); assert.equal(done.fields.get('running').value,false)
 })
 test('new component signatures/styles/fields/empty/long text/order', () => {
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
  test(preset+': exact type, spacing and light anchors', () => {
   const t=T.resolveTheme(preset,'',false)
   assert.deepEqual([t.sizeDisplay,t.sizeMetric,t.sizeBody,t.gapSection,t.padCard,t.radiusCard,t.background,t.primary],target)
   assert.equal(t.surface,'#FFFFFF'); assert.equal(t.sizeTitle,24); assert.equal(t.sizeHeading,preset==='technical'?18:20); assert.equal(t.sizeCaption,13)
   assert.equal(t.fontFamily,''); assert.equal(t.headingFontFamily,{editorial:'Noto Serif'}[preset]||''); assert.equal(t.metricFontFamily,{editorial:'Noto Serif',technical:'monospace'}[preset]||'')
  })
  for(const dark of [false,true]) for(const seed of ['', '#FFFFFF','#000000','#FFCC00','#FF00FF','#00FFFF']) test(`${preset}/${dark?'dark':'light'}/${seed||'default'}: enabled color contrast`, () => {
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
 test('native semantic typography, widget caps and measured columns', () => {
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
  test('scoped renderer APIs preserve dark listener lifecycle and density', () => {
   const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
   assert(!/mediaquery\.matchMediaSync|TimePickerDialog\.show|(?<![\w.])vp2px\(/.test(renderer.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/[^\n]*/g,'')))
   assert(renderer.includes('private darkListener: mediaquery.MediaQueryListener | null'))
   assert(renderer.includes('this.getUIContext().showTimePickerDialog({'))
   assert(renderer.includes('x: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100, y: this.getUIContext().vp2px(this.canvasSide(node.style)) / 100'))
   const names=['watchDarkMode','sparklinePoint','sparklineCommands','sparklineAreaCommands','sparklineGridCommands']
   const body=names.map(n=>declaration(renderer,'  private '+n+'(').replace('  private ','')).join('\n')+'\n'+declaration(renderer,'  aboutToDisappear(')
   const code=ts.transpileModule('class Probe { static SPARKLINE_HEIGHT=200; static SPARKLINE_INSET=16; '+body+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText
   const Probe=new Function(code+'; const VeraPreview=Probe; return Probe')(), probe=new Probe(), queries=[], events=[]
   let change, renders=0, density=1
   const listener={matches:true,on(event,cb){events.push(event);change=cb},off(event){events.push('off:'+event)}}
   probe.getUIContext=()=>({getMediaQuery:()=>({matchMediaSync(query){queries.push(query);return listener}}),vp2px:value=>value*density})
   probe.renderView=()=>renders++;probe.stopAllTimers=()=>events.push('stop');probe.dark=false;probe.disposed=false;probe.liveSurfaces=[]
   probe.watchDarkMode();assert.deepEqual(queries,['(dark-mode: true)']);assert.equal(probe.dark,true);assert.equal(probe.darkListener,listener)
   change({matches:true});assert.equal(renders,0);change({matches:false});assert.equal(renders,1);assert.equal(probe.dark,false)
   for(density of [1,2,3.5]) {
    const low=(184*density).toFixed(2), high=(16*density).toFixed(2), x1=(25*density).toFixed(2), x2=(75*density).toFixed(2)
    assert.equal(probe.sparklineCommands([0,10],10,0,100),`M ${x1} ${low} L ${x2} ${high}`)
    assert.equal(probe.sparklineCommands([10],10,0,100),`M ${(50*density).toFixed(2)} ${high}`)
    assert.equal(probe.sparklineCommands([],10,0,100),'')
    assert.equal(probe.sparklineAreaCommands([0,10],10,0,100),`M ${x1} ${low} L ${x2} ${high} L ${x2} ${low} L ${x1} ${low} Z`)
    assert(probe.sparklineGridCommands(10,0,100).startsWith(`M 0 ${high} L ${(100*density).toFixed(2)} ${high}`))
   }
   probe.aboutToDisappear();assert.equal(probe.disposed,true);assert.equal(probe.darkListener,null);assert.deepEqual(events,['change','stop','off:change'])
   change({matches:true});assert.equal(renders,1)
  })
   function tickerProbe() {
    const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
    const timerConfig=declaration(renderer,'class TimerConfig')
    const fields=['timers','timerConfigs','timerLastFire','ticking'].map(name=>{
     const field=renderer.match(new RegExp('^  private '+name+':[^\\n]+','m'));assert(field,name)
     return field[0].replace('  private ','')
    }).join('\n')
    const methods=['reconcileTimers','collectTickers','startTimer','stopTimer','stopAllTimers'].map(name=>declaration(renderer,'  private '+name+'(').replace('  private ','')).join('\n')
    const compiled=ts.transpileModule(timerConfig+'\nclass Probe { '+fields+'\n'+methods+' }',{compilerOptions:{target:ts.ScriptTarget.ES2020},reportDiagnostics:true})
    assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,'ticker probe syntax')
    let now=10000, nextHandle=0, surfaceStops=0
    const scheduled=new Map(), starts=[], stops=[], calls=[]
    function schedule(callback,interval) {
     const handle=++nextHandle
     scheduled.set(handle,{callback,interval,nextAt:now+interval});starts.push(handle)
     return handle
    }
    function cancel(handle) { stops.push(handle);scheduled.delete(handle) }
    const Probe=new Function('setInterval','clearInterval','Date','VeraNumberValue',compiled.outputText+'; return Probe')(schedule,cancel,{now:()=>now},V.VeraNumberValue)
    const probe=new Probe()
    Object.assign(probe,{spinTimer:-1,spinPeriod:0,motionTimer:-1,motionTriggers:new Map(),poseAnims:new Map(),sceneFrames:new Map(),stopSurfaceLoop(){surfaceStops++},dispatch(action,value){assert(value instanceof V.VeraNumberValue);calls.push({action,elapsed:value.value,at:now})}})
    function advance(ms) {
     const end=now+ms
     while(true) {
      const due=[...scheduled.values()].filter(timer=>timer.nextAt<=end).sort((a,b)=>a.nextAt-b.nextAt)[0]
      if(!due)break
      now=due.nextAt;due.nextAt+=due.interval;due.callback()
     }
     now=end
    }
    return {probe,scheduled,starts,stops,calls,schedule,advance,elapse(ms){now+=ms},fire(handle){assert(scheduled.has(handle));scheduled.get(handle).callback()},surfaceStops:()=>surfaceStops}
   }
   function ticker(id='clock',interval=1000,action='old',checked=true) {
    return Object.assign(new U.VeraUiNode(),{kind:'ticker',tickerId:id,minimum:interval,action,checked,children:[]})
   }
   function tickerTree(children) { return Object.assign(new U.VeraUiNode(),{kind:'column',children}) }
   function assertNoTickers(probe) {
    for(const name of ['timers','timerConfigs','timerLastFire'])assert.equal(probe[name].size,0,name)
   }
   test('native tickers: handler replacement preserves handle, phase and last fire', () => {
    const {probe,scheduled,starts,stops,calls,advance}=tickerProbe()
    probe.reconcileTimers(ticker())
    const handle=probe.timers.get('clock')
    advance(1000);assert.deepEqual(calls,[{action:'old',elapsed:1000,at:11000}])
    advance(250);probe.reconcileTimers(ticker('clock',1000,'new'))
    assert.equal(probe.timers.get('clock'),handle);assert.deepEqual(starts,[handle]);assert.deepEqual(stops,[])
    assert.equal(scheduled.get(handle).nextAt,12000);assert.equal(probe.timerLastFire.get('clock'),11000)
    assert.equal(probe.timerConfigs.get('clock').interval,1000);assert.equal(probe.timerConfigs.get('clock').action,'new')
    advance(749);assert.equal(calls.length,1)
    advance(1);assert.deepEqual(calls[1],{action:'new',elapsed:1000,at:12000});assert.equal(probe.ticking,false)
   })
   test('native tickers: stable handler never restarts under repeated reconciliation', () => {
    const {probe,scheduled,starts,stops,calls,advance}=tickerProbe()
    probe.reconcileTimers(ticker())
    const handle=probe.timers.get('clock')
    for(let i=0;i<4;i++) {
     advance(200);probe.reconcileTimers(ticker())
     assert.equal(probe.timers.get('clock'),handle);assert.equal(probe.timerLastFire.get('clock'),10000)
     assert.equal(scheduled.get(handle).nextAt,11000)
    }
    assert.deepEqual(starts,[handle]);assert.deepEqual(stops,[]);assert.equal(calls.length,0)
    advance(200);assert.deepEqual(calls,[{action:'old',elapsed:1000,at:11000}])
   })
   test('native tickers: interval change restarts and dispatches the new action', () => {
    const {probe,scheduled,starts,stops,calls,advance}=tickerProbe()
    probe.reconcileTimers(ticker())
    const old=probe.timers.get('clock')
    advance(400);probe.reconcileTimers(ticker('clock',250,'faster'))
    const handle=probe.timers.get('clock')
    assert.notEqual(handle,old);assert.deepEqual(starts,[old,handle]);assert.deepEqual(stops,[old]);assert(!scheduled.has(old))
    assert.equal(probe.timerConfigs.get('clock').interval,250);assert.equal(probe.timerLastFire.get('clock'),10400)
    assert.equal(probe.timerConfigs.get('clock').action,'faster');assert.equal(scheduled.get(handle).nextAt,10650)
    advance(249);assert.equal(calls.length,0)
    advance(1);assert.deepEqual(calls,[{action:'faster',elapsed:250,at:10650}])
   })
   test('native tickers: removal and disable clear all maps and cancel callbacks', () => {
    for(const root of [null,tickerTree([]),ticker('clock',1000,'old',false)]) {
     const {probe,scheduled,stops,calls,advance}=tickerProbe()
     probe.reconcileTimers(ticker())
     const handle=probe.timers.get('clock')
     advance(400);probe.reconcileTimers(root)
     assertNoTickers(probe);assert.equal(scheduled.size,0);assert.deepEqual(stops,[handle])
     advance(2000);assert.equal(calls.length,0)
     probe.stopTimer('clock');assertNoTickers(probe);assert.deepEqual(stops,[handle])
    }
   })
   test('native tickers: readding an id starts a fresh phase and action', () => {
    const {probe,scheduled,starts,stops,calls,advance}=tickerProbe()
    probe.reconcileTimers(ticker())
    const old=probe.timers.get('clock')
    advance(400);probe.reconcileTimers(null);assertNoTickers(probe)
    advance(300);probe.reconcileTimers(ticker('clock',1000,'readded'))
    const handle=probe.timers.get('clock')
    assert.notEqual(handle,old);assert.deepEqual(starts,[old,handle]);assert.deepEqual(stops,[old])
    assert.equal(probe.timerLastFire.get('clock'),10700);assert.equal(scheduled.get(handle).nextAt,11700)
    assert.equal(probe.timerConfigs.get('clock').action,'readded')
    advance(999);assert.equal(calls.length,0)
    advance(1);assert.deepEqual(calls,[{action:'readded',elapsed:1000,at:11700}])
   })
   test('native tickers: collection visits nested nodes and rejects inactive or invalid tickers', () => {
    const {probe,scheduled,calls,advance}=tickerProbe()
    probe.reconcileTimers(tickerTree([tickerTree([ticker('nested',100,'nestedTick')]),ticker('disabled',100,'disabled',false),ticker('zero',0),ticker('negative',-1),ticker('',100),ticker('noAction',100,'')]))
    assert.deepEqual([...probe.timerConfigs].map(([id,config])=>[id,{interval:config.interval,action:config.action}]),[['nested',{interval:100,action:'nestedTick'}]]);assert.equal(scheduled.size,1)
    advance(100);assert.deepEqual(calls,[{action:'nestedTick',elapsed:100,at:10100}])
   })
   test('native tickers: real elapsed time, minimum interval, ticking and missing config guards', () => {
    const {probe,scheduled,calls,elapse,fire}=tickerProbe()
    probe.startTimer('direct',{interval:1,action:'fast'})
    const handle=probe.timers.get('direct')
    assert.equal(probe.timerConfigs.get('direct').action,'fast');assert.equal(probe.timerConfigs.get('direct').interval,1);assert.equal(scheduled.get(handle).interval,16)
    elapse(19.6);fire(handle);assert.deepEqual(calls,[{action:'fast',elapsed:20,at:10019.6}])
    const last=probe.timerLastFire.get('direct')
    probe.ticking=true;elapse(30);fire(handle)
    assert.equal(calls.length,1);assert.equal(probe.timerLastFire.get('direct'),last);assert.equal(probe.ticking,true)
    probe.ticking=false;elapse(10)
    const dispatch=probe.dispatch
    probe.dispatch=(action,value)=>{assert.equal(probe.ticking,true);fire(handle);dispatch(action,value)}
    fire(handle);assert.deepEqual(calls[1],{action:'fast',elapsed:40,at:10059.6});assert.equal(probe.ticking,false)
    probe.timerConfigs.delete('direct');elapse(20);fire(handle)
    assert.equal(calls.length,2);assert.equal(probe.ticking,false)
   })
   test('native tickers: stopAllTimers clears configs and other animation state', () => {
    const f=tickerProbe(), {probe,scheduled,stops,calls,advance}=f
    probe.reconcileTimers(tickerTree([ticker('one',1000,'oneTick'),ticker('two',1500,'twoTick')]))
    probe.spinTimer=f.schedule(()=>assert.fail('spin survived cleanup'),16);probe.spinPeriod=1000
    probe.motionTimer=f.schedule(()=>assert.fail('motion survived cleanup'),16)
    for(const name of ['motionTriggers','poseAnims','sceneFrames'])probe[name].set('fixture',{})
    probe.stopAllTimers();assertNoTickers(probe);assert.equal(scheduled.size,0);assert.equal(stops.length,4)
    assert.equal(probe.spinTimer,-1);assert.equal(probe.spinPeriod,0);assert.equal(probe.motionTimer,-1);assert.equal(f.surfaceStops(),1)
    for(const name of ['motionTriggers','poseAnims','sceneFrames'])assert.equal(probe[name].size,0,name)
    advance(3000);assert.equal(calls.length,0)
    probe.stopAllTimers();assertNoTickers(probe);assert.equal(stops.length,4);assert.equal(f.surfaceStops(),2)
   })
  test('native declarations match all nine C++ exports and local package wiring', () => {
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
  test('chat writes close once, preserve primary errors and keep save contract', () => {
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
  test('renderer measurement survives state reconciliation only', () => {
  global.ObservedV2=c=>c; global.Trace=()=>{};
  const L=loadSource(path.join(sourceRoot,'components/VeraLiveTree.ets'))
  const n=new U.VeraUiNode(); n.kind='adaptivecolumns'; n.minimum=240
  const live=L.toLive(n); assert.equal(live.layoutWidth,0); live.layoutWidth=600; L.reconcile(live,n); assert.equal(live.layoutWidth,600)
  n.kind='hero'; L.reconcile(live,n); assert.equal(live.layoutWidth,0); assert(!('layoutWidth' in n))
 })
 test('catalogue and visual prompt contracts', () => {
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
