#!/usr/bin/env node
'use strict'
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path')
const {loadVera,loadSource,sourceRoot}=require('./source-loader')
const ts=require(process.env.VERA_TYPESCRIPT_PATH||'typescript')
const C=loadVera('VeraCompiler'),V=loadVera('VeraInterpreter'),U=loadVera('VeraUi')
global.ObservedV2=c=>c;global.Trace=()=>{}
const L=loadSource(path.join(sourceRoot,'components/VeraLiveTree.ets'))
const src=`@jsonable class AppState { screen: string; count: number; text: string; }
function init(): AppState { return {screen: "a", count: 0, text: "same"}; }
function go(state: AppState, value: number): AppState { return {screen: "b", count: state.count, text: state.text}; }
function back(state: AppState, value: number): AppState { return {screen: "a", count: state.count, text: state.text}; }
function increment(state: AppState, value: number): AppState { return {screen: state.screen, count: state.count + 1, text: state.text}; }
function edit(state: AppState, value: string): AppState { return {screen: "b", count: state.count, text: value}; }
function tick(state: AppState, value: number): AppState { return state; }
function screenA(state: AppState): ui.View { return ui.Screen("a", [ui.TextField("default", "Name", state.text, "edit"), ui.Button("primary", "Next", "go", 0, true),ui.Ticker("default","clock",1000,true,"tick")]); }
function screenB(state: AppState): ui.View { return ui.Screen("b", [ui.TextField("default", "Name", state.text, "edit"),ui.Button("primary", "Next", "go", 0, true),ui.Ticker("default","clock",1000,true,"tick"),ui.BackHandler("back")]); }
function view(state: AppState): ui.View { if (state.screen === "a") {return ui.AppTheme("clean","",[screenA(state),ui.Ticker("default","global-clock",1000,true,"tick")]);} return ui.AppTheme("clean","",[screenB(state),ui.Ticker("default","global-clock",1000,true,"tick")]); }`
const compiled=C.compileVeraSource(src),host=new U.UiHostEnvironment(),vm=new V.VirtualMachine(V.deserializeVbc2(compiled.vbc2),host)
const renderer=fs.readFileSync(path.join(sourceRoot,'components/VeraPreview.ets'),'utf8')
function method(name) {
  // Parse only the requested method's balanced body, ignoring ArkUI elsewhere.
  const start=renderer.indexOf('  private '+name+'(');assert(start>=0,name)
  const tail=renderer.slice(start),brace=tail.indexOf('{');let depth=0,end=brace
  const scanner=ts.createScanner(ts.ScriptTarget.Latest,false,ts.LanguageVariant.Standard,tail.slice(brace))
  for(let token=scanner.scan();token!==ts.SyntaxKind.EndOfFileToken;token=scanner.scan()){
    if(token===ts.SyntaxKind.OpenBraceToken)depth++
    if(token===ts.SyntaxKind.CloseBraceToken&&--depth===0){end=brace+scanner.getTextPos();break}
  }
  return tail.slice(0,end).replace('  private ','')
}
const names=['renderView','markLiveNodeGeneration','isLiveNode','fieldCurrent','reconcileFields','fieldActionCurrent','fieldActionState','collectTickers','reconcileTimers','reconcileBackHandler','findBackHandlerAction','reconcileSurfaces','collectKind','captureFieldAction','collectFieldDependencies','dispatchFieldAction','dispatchTickerAction','enqueueFieldAction','resumeFieldActions','releaseSurfaceAction','flushFields','commitField','handleStringAction']
const actionClass=renderer.slice(renderer.indexOf('class FieldAction {'),renderer.indexOf('\nclass SurfaceInput {'))
const code=ts.transpileModule('class TimerConfig { constructor(public interval:number,public action:string){} }\n'+actionClass+'\nclass Probe {\n'+names.map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText
const mocks={decodeVeraUi:U.decodeVeraUi,toLive:L.toLive,reconcile:L.reconcile,markIconRoom:L.markIconRoom,VeraStringValue:V.VeraStringValue,console:{info(){}}}
const Probe=new Function(...Object.keys(mocks),code+';return Probe')(...Object.values(mocks))
const stopped=[],started=[],cancelled=[],backSignals=[]
const p=new Probe()
Object.assign(p,{vm,host,currentState:vm.execute('init'),liveRoot:null,hasRoot:false,liveGeneration:0,effectGeneration:1,disposed:false,previewOnly:false,error:'',revision:0,renderingDepth:0,fieldInputs:new Map(),fieldEdits:new Map(),surfaceInputs:new Map(),surfaces:new Map(),timers:new Map(),timerConfigs:new Map(),backHandlerAction:'',reconcileTheme(){},reconcileSpin(){},reconcileMotion(){},textTimers:new Map(),stopSurfaceLoop(){},startSurfaceLoop(){},paintSurfaces(){},refreshFieldIssues(){},scheduleFieldActions(){},onBackHandlerChanged(value){backSignals.push(value)},cancelField(n){cancelled.push(n);this.fieldEdits.delete(n)},startTimer(id,c){started.push(id);this.timers.set(id,1);this.timerConfigs.set(id,c)},stopTimer(id){stopped.push(id);this.timers.delete(id);this.timerConfigs.delete(id)}})
function apply(name,value=0){p.currentState=vm.execute(name,[p.currentState,new V.VeraNumberValue(value)]);p.renderView();assert.equal(p.error,'')}
p.renderView();assert.equal(p.error,'')
const boundary=p.liveRoot.children[0],field=boundary.children[0],button=boundary.children[1]
assert.equal(boundary.screenId,'a');field.touched=true;field.typed='unsaved'
p.fieldInputs.set(field,{generation:field.fieldGeneration});p.fieldEdits.set(field,{generation:field.fieldGeneration,action:field.action,base:field.value})
const queued={generation:1,dependencies:[],dependencyCancellations:[],node:button,nodeKind:button.kind,action:button.action,nodeGeneration:button.fieldGeneration,nodeState:p.fieldActionState(button),surfaceInput:null,tickerConfig:null}
assert(p.fieldActionCurrent(queued))
apply('increment');assert.equal(p.liveRoot.children[0].children[0],field,'same-screen update keeps native field identity')
assert.equal(field.touched,true);assert.equal(p.fieldInputs.size,1)
// A disappearing canvas may still have fingers down; screen teardown must
// discard those input records as well as the native canvas controller.
const surface=new L.LiveNode();surface.kind='surface';boundary.children.push(surface)
p.surfaces.set(surface,{});p.surfaceInputs.set(surface,new Map([[0,{}]]))
apply('go');assert.equal(p.surfaces.has(surface),false);assert.equal(p.surfaceInputs.has(surface),false)
assert.equal(p.liveRoot.children[0],boundary,'boundary itself stays observed')
assert.notEqual(boundary.children[0],field,'same-position same-value same-handler fields are replaced across screens')
assert.equal(boundary.children[0].touched,false);assert.equal(p.fieldInputs.size,0);assert.equal(p.fieldEdits.size,0);assert(cancelled.includes(field))
assert.equal(p.isLiveNode(field),false);assert.equal(p.fieldActionCurrent(queued),false)
assert.equal(p.currentState.fields.get('count').value,1,'switch preserves shared state')
assert.deepEqual(backSignals,[true]);assert.equal(p.backHandlerAction,'back')
assert.deepEqual(stopped,['["a","clock"]']);assert.deepEqual(started,['["a","clock"]','global-clock','["b","clock"]'])
apply('back');assert.equal(p.backHandlerAction,'');assert.deepEqual(backSignals,[true,false]);assert.equal(p.fieldActionCurrent(queued),false,'leaving and returning never resurrects stale actions')
assert.equal(p.currentState.fields.get('count').value,1)
// Regression: a slow tick flushes a ready edit whose handler navigates. The
// outgoing tick must not dispatch in the new screen; SDK callbacks still may.
const dispatches=[]
Object.assign(p,{fieldActions:[],fieldActionsNeedResume:false,resumingFieldActions:false,
  dispatch(name,payload){dispatches.push([name,this.currentState.fields.get('screen').value]);this.currentState=vm.execute(name,[this.currentState,payload]);this.renderView()}})
function pendingNavigationEdit(){const n=p.liveRoot.children[0].children[0];p.fieldEdits.set(n,{generation:n.fieldGeneration,action:n.action,base:n.value,value:n.value+'!',composing:false})}
let timerId='["a","clock"]',timerConfig=p.timerConfigs.get(timerId)
const capturedTick=p.captureFieldAction('tick',new V.VeraNumberValue(1000));capturedTick.tickerId=timerId;capturedTick.tickerConfig=timerConfig
apply('increment');assert.equal(p.timerConfigs.get(timerId),timerConfig,'ordinary redraw retains timer lifetime')
assert(p.fieldActionCurrent(capturedTick))
pendingNavigationEdit();p.dispatchTickerAction(timerId,timerConfig,new V.VeraNumberValue(1000))
assert.deepEqual(dispatches,[['edit','a']],'stopped outgoing ticker cannot dispatch after a field navigates')
assert.equal(p.currentState.fields.get('screen').value,'b');assert.equal(p.fieldActions.length,0)
apply('back');assert.equal(p.fieldActionCurrent(capturedTick),false,'returning to the same ID starts a new lifetime')
dispatches.length=0;pendingNavigationEdit();p.dispatchFieldAction('tick',new V.VeraNumberValue(0))
assert.deepEqual(dispatches,[['edit','a'],['tick','b']],'application-scoped callback survives screen change')
apply('back');dispatches.length=0;const globalConfig=p.timerConfigs.get('global-clock');pendingNavigationEdit()
p.dispatchTickerAction('global-clock',globalConfig,new V.VeraNumberValue(1000))
assert.equal(p.timerConfigs.get('global-clock'),globalConfig)
assert.deepEqual(dispatches,[['edit','a'],['tick','b']],'application-wide ticker remains live across screen navigation')
assert.match(renderer,/ForEach\(\[node.screenId\]/,'native subtree is keyed by screen identity')
assert.match(renderer,/rootScroller.scrollTo\(\{ xOffset: 0, yOffset: 0 \}\)/,'screen entry resets root scroll')
// Generic screen boundary must coexist with current compiler/UI compatibility fixtures.
assert.equal(loadVera('VeraSmoke').smokeRun(compiled),'')
console.log('multiscreen-check: shared state, same-screen retention, screen remount, stale inputs/actions, surface teardown, scoped/queued tickers, application callbacks and back: ok')
