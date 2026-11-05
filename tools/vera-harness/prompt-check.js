const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const cp = require('node:child_process');
const ts = (process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript'));
const root = path.resolve(process.argv[2] || path.join(__dirname, '../..'));
const output = path.resolve(process.argv[3] || '/tmp/vera-prompt-verification.json');
const base = path.join(root, 'entry/src/main/ets/vera');
const requests = [], responses = [], cache = new Map(), checks = [];
const checkFilter = process.env.VERA_CHECK_FILTER ? new RegExp(process.env.VERA_CHECK_FILTER) : null;
let transportFactory = null;
const http = {RequestMethod:{POST:'POST'}, createHttp(){
  if(transportFactory)return transportFactory();
  let callback;
  return {on(event, fn){if(event==='dataReceive')callback=fn},off(){},destroy(){},
    async requestInStream(url,options){
      requests.push(JSON.parse(options.extraData));
      assert(responses.length, 'Missing deterministic HTTP response');
      const response=responses.shift(); const content=typeof response==='string'?response:response.content; const finish=typeof response==='string'?'stop':response.finish;
      const delta=typeof response==='object'&&response.toolCalls ? {tool_calls:response.toolCalls} : {content};
      const data='data: '+JSON.stringify({choices:[{delta,finish_reason:typeof response==='object'&&response.toolCalls?'tool_calls':finish}],usage:typeof response==='object'&&response.usage?response.usage:{prompt_tokens:1,completion_tokens:1}})+'\n\ndata: [DONE]\n\n';
      const bytes=Buffer.from(data); callback(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length));
      return 200;
    }
  };
}};
function load(file){
  file=path.resolve(file); if(cache.has(file))return cache.get(file).exports;
  let source=fs.readFileSync(file,'utf8');
  const mod={exports:{}}; cache.set(file,mod);
  const compiled=ts.transpileModule(source,{fileName:file.replace(/\.ets$/,'.ts'),compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,esModuleInterop:true},reportDiagnostics:true});
  assert.equal((compiled.diagnostics||[]).filter(x=>x.category===ts.DiagnosticCategory.Error).length,0,file+' TypeScript syntax');
  const requireLocal=name=>{
    if(name==='@kit.NetworkKit')return {http};
    if(name==='@ohos.net.http')return http;
    if(name==='@kit.ArkTS')return {util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}};
    if(name.startsWith('@kit.')||name==='libllama.so')return {};
    if(name.startsWith('.'))return load(path.join(path.dirname(file),name+'.ets'));
    throw Error('Unexpected dependency '+name);
  };
  new Function('require','module','exports',compiled.outputText)(requireLocal,mod,mod.exports);
  return mod.exports;
}
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8')}
function run(name,fn){if(checkFilter&&!checkFilter.test(name))return;try{const observed=fn();checks.push({name,status:'PASS',observed});return observed}catch(e){checks.push({name,status:'FAIL',observed:e.message});}}
async function runAsync(name,fn){if(checkFilter&&!checkFilter.test(name))return;let timer;try{const observed=await Promise.race([Promise.resolve().then(fn),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Check did not settle')),5000);})]);checks.push({name,status:'PASS',observed});}catch(e){checks.push({name,status:'FAIL',observed:e.message});}finally{clearTimeout(timer);}}
const skill=read('entry/src/main/resources/rawfile/vera-skill.txt');
const widget=read('entry/src/main/resources/rawfile/vera-widget.txt');
const compiler=load(path.join(base,'VeraCompiler.ets'));
const runtime=load(path.join(base,'VeraInterpreter.ets'));
const ui=load(path.join(base,'VeraUi.ets'));
const catalog=load(path.join(base,'VeraUiCatalog.ets'));
const selection=load(path.join(base,'VeraUiSelect.ets'));
const example=skill.slice(skill.indexOf('\n@jsonable', skill.lastIndexOf('\nExample'))+1).trim();
let machine,host,state,tree;
function render(current){host.effectsAllowed=false;const result=ui.decodeVeraUi(machine.execute('view',[current]));return result;}
function countNodes(nodes){return nodes.reduce((sum,n)=>sum+1+countNodes(n.children),0)}
run('Prompt template assembly: full, selected, widget',()=>{
  for(const [name,note,selected] of [['full','',null],['selected',selection.UI_TOOL_NOTE,new Set(['NumberField'])],['widget','',null]]){
    let text=skill.replace('{{UI_CATALOG}}',catalog.describeCatalogForPrompt(selected)).replace('{{UI_TOOL_NOTE}}\n',note)+(name==='widget'?widget:'');
    assert(!/\{\{UI_/.test(text),'Unresolved placeholder in '+name);
    assert(text.includes('ui.AppTheme'),'Root theme absent');
  }
  return {templateCharacters:skill.length,widgetCharacters:widget.length,modes:3};
});
run('Compile the complete prompt example',()=>{
  const compiled=compiler.compileVeraSource(example);
  host=new ui.UiHostEnvironment();machine=new runtime.VirtualMachine(runtime.deserializeVbc2(compiled.vbc2),host);
  state=machine.execute('init');return {bytecodeBytes:compiled.vbc2.length};
});
run('Render initial state through real VM and UI decoder',()=>{
  const snapshot=JSON.stringify(runtime.encodeRuntimeValue(state));tree=render(state);
  assert.equal(tree[0].kind,'apptheme');assert(countNodes(tree)<=80);
  assert.equal(JSON.stringify(runtime.encodeRuntimeValue(state)),snapshot);
  return {root:tree[0].kind,nodes:countNodes(tree),pendingEffects:host.pendingEffects.length};
});
run('Edit input and add entry without mutating earlier state',()=>{
  const before=JSON.stringify(runtime.encodeRuntimeValue(state));
  host.effectsAllowed=true;
  let adjusted=machine.execute('setSize',[state,new runtime.VeraNumberValue(30)]);
  let added=machine.execute('add',[adjusted,new runtime.VeraNumberValue(0)]);
  assert.equal(JSON.stringify(runtime.encodeRuntimeValue(state)),before,'Add handler mutated an earlier state');
  const raw=runtime.encodeRuntimeValue(added); assert(raw);
  assert.equal(added.fields.get('log').elements.length,1);
  const first=JSON.stringify(runtime.encodeRuntimeValue(added));
  let addedAgain=machine.execute('add',[added,new runtime.VeraNumberValue(0)]);
  assert.equal(JSON.stringify(runtime.encodeRuntimeValue(added)),first,'Second add mutated prior state');
  assert.equal(addedAgain.fields.get('log').elements.length,2);
  state=addedAgain;return {entries:2};
});
run('Persist, restore and render populated state',()=>{
  const encoded=JSON.parse(JSON.stringify(runtime.encodeRuntimeValue(state)));
  const restored=runtime.decodeRuntimeValue(encoded);
  const first=render(restored), second=render(restored);
  assert.deepEqual(first,second);assert(countNodes(first)<=80);
  return {root:first[0].kind,nodes:countNodes(first)};
});
run('Intent callback classification through compile, dispatch and render',()=>{
  const test=skill.match(/let failed: boolean = [^\n]+/);assert(test,'Intent result classification example missing');
  const source='import * as ui from "std/ui"\nimport * as strings from "std/strings"\n@jsonable class AppState { answer: string; failed: boolean; }\nfunction init(): AppState { return {answer: "Pending", failed: false}; }\nfunction onAnswer(state: AppState, value: string): AppState { '+test[0]+' return {answer: value, failed: failed}; }\nfunction view(state: AppState): ui.View { return ui.AppTheme("clean", "", [ui.Text("body", state.answer), ui.Text("caption", ui.booleanToString(state.failed))]); }';
  const h=new ui.UiHostEnvironment();const m=new runtime.VirtualMachine(runtime.deserializeVbc2(compiler.compileVeraSource(source).vbc2),h);
  const cases=[['ok',false],['{"accepted":true}',false],['declined by the person',true],['declined code=1',true],['error 5: unavailable',true]];
  for(const [answer,expected] of cases){let st=m.execute('onAnswer',[m.execute('init'),new runtime.VeraStringValue(answer)]);const nodes=ui.decodeVeraUi(m.execute('view',[st]));assert.equal(nodes[0].children[0].text,answer);assert.equal(nodes[0].children[1].text,String(expected));}
  return {cases:cases.length,rawAnswersPreserved:true};
});
run('Widget money guidance formats cents, rounding and negative amounts',()=>{
  // The widget prompt now tells the model to keep money as a number and let
  // ui.formatNumber / ui.NumberText write it, and to read typed amounts with
  // strings.toNumber. This runs exactly that path.
  assert(widget.includes('ui.formatNumber(amount, 2)')&&widget.includes('strings.toNumber(value, 0)'),'Money guidance missing');
  const source='import * as ui from "std/ui"\nimport * as math from "std/math"\nimport * as strings from "std/strings"\n@jsonable class AppState { typed: string; }\nfunction init(): AppState { return {typed: ""}; }\nfunction set(state: AppState, value: string): AppState { return {typed: value}; }\nfunction view(state: AppState): ui.View { let amount: number = strings.toNumber(state.typed, 0); let tip: number = math.round(amount * 0.12 * 100) / 100; return ui.AppTheme("technical", "", [ui.Text("body", "$" + ui.formatNumber(amount, 2)), ui.Text("body", ui.formatNumber(tip, 2))]); }';
  const h=new ui.UiHostEnvironment();const m=new runtime.VirtualMachine(runtime.deserializeVbc2(compiler.compileVeraSource(source).vbc2),h);
  const cases=[['','$0.00','0.00'],['187.40','$187.40','22.49'],['187,40','$187.40','22.49'],['-0.01','$-0.01','0.00'],['-1.05','$-1.05','-0.13'],['21474836.47','$21474836.47','2576980.38'],['abc','$0.00','0.00']];
  for(const [input,amount,tip] of cases){let st=m.execute('set',[m.execute('init'),new runtime.VeraStringValue(input)]);const nodes=ui.decodeVeraUi(m.execute('view',[st]));assert.equal(nodes[0].children[0].text,amount,'Amount for '+input);assert.equal(nodes[0].children[1].text,tip,'Tip for '+input);}
  return {cases:cases.length};
});
run('String escapes: \\uXXXX and \\u{...} as in TypeScript, malformed ones left as text',()=>{
  // The model wrote " · " for a middle dot; the backslash used to be
  // dropped and the egg timer read "Soft boiled u00b7 360 min".
  const literals=['"a \\u00b7 b"','"\\u{1F95A}"','"\\u00E9t\\u00e9"','"\\u12"','"\\u{}x"','"\\uZZZZ"','"tab\\tq\\"\\\\"','"\\u0041\\u0042"'];
  const want=['a · b','\u{1F95A}','été','u12','u{}x','uZZZZ','tab\tq"\\','AB'];
  const source='@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 0}; }\nfunction view(state: AppState): ui.View { return ui.AppTheme("clean", "", ['+literals.map(l=>'ui.Text("body", '+l+')').join(', ')+']); }';
  const h=new ui.UiHostEnvironment();const m=new runtime.VirtualMachine(runtime.deserializeVbc2(compiler.compileVeraSource(source).vbc2),h);
  const texts=ui.decodeVeraUi(m.execute('view',[m.execute('init')]))[0].children.map(n=>n.text);
  assert.deepEqual(texts,want);
  return {texts};
});
run('String case: s.toUpperCase(), s.toLowerCase() and the strings functions',()=>{
  // egg-3 wrote label.toUpperCase() and lost a repair round to E2033.
  const source='@jsonable class AppState { label: string; }\nfunction init(): AppState { return {label: "Soft Été"}; }\nfunction view(state: AppState): ui.View { let words: string[] = ["a", "b"]; return ui.AppTheme("clean", "", [ui.Text("body", state.label.toUpperCase() + " BOILED"), ui.Text("body", state.label.toLowerCase()), ui.Text("body", strings.toUpperCase("x") + strings.toLowerCase("Y")), ui.Text("body", ("ab" + "c").toUpperCase())]); }';
  const h=new ui.UiHostEnvironment();const m=new runtime.VirtualMachine(runtime.deserializeVbc2(compiler.compileVeraSource(source).vbc2),h);
  const texts=ui.decodeVeraUi(m.execute('view',[m.execute('init')]))[0].children.map(n=>n.text);
  assert.deepEqual(texts,['SOFT ÉTÉ BOILED','soft été','Xy','ABC']);
  let message='';try{compiler.compileVeraSource('@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 1}; }\nfunction view(state: AppState): ui.View { return ui.Text("body", state.n.toUpperCase()); }')}catch(e){message=e.message}
  assert(/E2033/.test(message),'A number has no toUpperCase');
  assert(skill.includes('strings.toUpperCase(s), strings.toLowerCase(s)'));
  return {texts};
});
run('Parser recovery: every syntax error in one compile, without cascades',()=>{
  // egg-2 had four ternaries in one view expression; the parser used to stop at
  // the first, and each edit repair then uncovered the next.
  const head='@jsonable class AppState { n: number; done: boolean; }\nfunction init(): AppState { return {n: 0, done: false}; }\n';
  function errors(src){try{compiler.compileVeraSource(src);return []}catch(e){assert(e instanceof compiler.CompileError);return e.diagnostics.map(d=>d.span.start.line+':'+d.span.start.column+' '+d.message)}}
  const view=head+'function view(state: AppState): ui.View {\n  return ui.AppTheme("clean", "", [\n    ui.Text("body", state.done ? "a" : "b"),\n    ui.Row("compact", [ui.Badge(state.done ? "success" : "default", "x", "check")]),\n    ui.Text("body", "Your " + (state.n === 0 ? "soft" : "hard") + " egg"),\n    ui.Text("body", "fine")\n  ]);\n}';
  assert.deepEqual(errors(view),['5:32 expected ), found ?','6:44 expected ), found ?','7:46 expected ), found ?']);
  const statements=head+'function f(state: AppState): AppState {\n  let from: number = 1;\n  let ok: number = 2;\n  let y: number = state.n ? 1 : 2;\n  return {n: state.done ? 1 : 2, done: false};\n}\nfunction view(state: AppState): ui.View { return ui.Text("body", "a"); }';
  assert.deepEqual(errors(statements),['4:7 expected name, found from','6:27 expected expression','7:25 expected }, found ?']);
  const brace=head+'function f(state: AppState): AppState {\n  if (state.done) {\n    return state;\n\nfunction view(state: AppState): ui.View { return ui.Text("body", "a"); }';
  assert.deepEqual(errors(brace),['7:1 expected }, found function']);
  assert.deepEqual(errors(head+'function view(state: AppState): ui.View { return ui.Text("body", "a"); }'),[]);
  return {view:errors(view),statements:errors(statements),brace:errors(brace)};
});
(async()=>{
  const llama=load(path.join(base,'LlamaEngine.ets'));
  const deep=load(path.join(base,'DeepSeekEngine.ets'));
  const chat=load(path.join(base,'VeraChat.ets'));
  const repairMod=load(path.join(base,'VeraRepair.ets'));
  const settings=load(path.join(base,'SettingsStore.ets')).settings;
  const {OperationController,throwIfCancelled,cancellationError}=load(path.join(base,'OperationCancellation.ets'));
  settings.getApiKey=()=> 'host-test-key';settings.hasApiKey=()=>true;
  settings.getModel=()=> 'test-model';settings.getBaseUrl=()=> 'https://host-test.invalid';settings.isDeepSeek=()=>true;
  function assertUniform(sent=requests){
    assert(sent.length>0,'No generation request');
    for(const body of sent){
      assert.equal(body.thinking.type,'enabled','Reasoning must be enabled');
      assert.equal(body.max_tokens,32768,'Uniform output-token limit');
      assert.equal(body.temperature,0.2,'Generation temperature preserved');
    }
  }
  function reset(){requests.length=0;responses.length=0;}
  async function promptly(promise){
    let timer;
    try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Workflow did not settle')),1000);})]);}
    finally{clearTimeout(timer);}
  }
  async function until(predicate){
    const deadline=Date.now()+1000;
    while(!predicate()){assert(Date.now()<deadline,'Workflow did not start');await new Promise(resolve=>setImmediate(resolve));}
  }
  async function patched(changes,fn){
    const originals=changes.map(([object,key])=>Object.getOwnPropertyDescriptor(object,key));
    changes.forEach(([object,key,value])=>{object[key]=value;});
    try{return await fn();}finally{changes.forEach(([object,key],i)=>{if(originals[i])Object.defineProperty(object,key,originals[i]);else delete object[key];});}
  }
  function transport(){
    let callback,queued,resolve;
    const pending=new Promise(done=>{resolve=done;});
    return {destroyed:0,detached:0,body:null,on(_event,fn){callback=queued=fn;},off(){this.detached++;callback=null;},destroy(){this.destroyed++;resolve(200);},
      requestInStream(_url,options){this.body=JSON.parse(options.extraData);requests.push(this.body);return pending;},
      emit(content,late=false){const bytes=Buffer.from('data: '+JSON.stringify({choices:[{delta:{content},finish_reason:'stop'}],usage:{prompt_tokens:9,completion_tokens:4,prompt_cache_hit_tokens:3}})+'\n\ndata: [DONE]\n\n');const fn=late?queued:callback;assert(fn,'Stream callback missing');fn(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length));},
      finish(){resolve(200);}};
  }
  function method(src,name){
    const start=src.search(new RegExp('^  (?:private )?(?:async )?'+name+'(?:<[^>]*>)?\\(','m'));assert(start>=0,'Method '+name);
    const scanner=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,src.slice(start));
    let depth=0,opened=false;
    while(scanner.scan()!==ts.SyntaxKind.EndOfFileToken){
      if(scanner.getToken()===ts.SyntaxKind.OpenBraceToken){opened=true;depth++;}
      if(scanner.getToken()===ts.SyntaxKind.CloseBraceToken&&--depth===0&&opened)return src.slice(start,start+scanner.getTextPos());
    }
    throw Error('Unclosed method '+name);
  }
  // The route and the trace are swapped per check: tpl.build answers buildScreen, traces collects trace().
  const tpl={build:async()=>{throw Error('No template build set')}},traces=[];
  const route=load(path.join(base,'agent','VeraBuildRoute.ets')),agent=load(path.join(base,'agent','VeraAgent.ets')),agentHost=load(path.join(base,'agent','AgentHost.ets'));
  // side.selectUi answers selectUiForPrompt and side.edit answers editComposition.
  const side={compose:false,selectUi:async()=>null,edit:async()=>{throw Error('No structural edit set')}};
  function notBuilt(){return Object.assign(new route.RouteOutcome(),{kind:route.OUTCOME_NOT_BUILT,reason:'test'});}
  async function settle(c){for(let i=0;i<5;i++)await new Promise(r=>setTimeout(r,0));if(c.pending)await c.pending;}
  function page(localEngine={stop(){},generate(request){return {text:example,inputTokens:1,outputTokens:1,request}}}){
    const src=read('entry/src/main/ets/pages/GeneratePage.ets');
    const icons=read('entry/src/main/ets/components/IconPicker.ets');
    const prefix=icons.slice(0,icons.indexOf('@Component')).replace(/^import .*$/gm,'').replace(/^export /gm,'')+'\n'+src.slice(0,src.indexOf('@Component')).replace(/^import .*$/gm,'');
    const code=prefix+'\nclass Controller { saveIcon = DEFAULT_APP_ICON; '+['beginOperation','resetRunMetrics','startFresh','startNew','doServerGenerate','aboutToDisappear','hostContext','callModel','runAttempt','doRefine','traceEnd','closeRun','doGenerate','tryLiveFigures','tryRoute','traceAgent','showAgent','settleQuestion','askPerson','startAttemptOne','tryStructuralEdit','refineWithModel','stopGeneration','originLabel','measuredTotal','addMetricUsage','metricWork','collectMetricSideCalls','beginMetricAttempt','recordMetricResult','finishMetrics','acceptRequest','copyMetrics','prepareRequest','currentBase','ratePerMillion','modeLabel','hasResult','doSave','confirmName','cancelName','afterSave','close','commitSave','versionCount','isSaved'].map(n=>method(src,n)).join('\n')+' } module.exports=Controller;';
    const compiled=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020},reportDiagnostics:true});
    assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,'Extracted generation controller syntax');
    const versions=[],projects=[],toasts=[],scrollEdges=[];
    const globals={AppRouteParams:load(path.join(base,'AppNavigation.ets')).AppRouteParams,
      ...load(path.join(base,'AppName.ets')),refreshForms:()=>{},
      store:{createProject(name,icon){const project={id:'project-'+(projects.length+1),name,icon};projects.push(project);return project;},
        createVersion(projectId,source,vbc2,note,prompt,origin,composition,lastPrompt,parentVersionId,metrics){const version={id:'version-'+(versions.length+1),projectId,source,vbc2,note,prompt,origin,composition,lastPrompt,parentVersionId,metrics};versions.push(version);return version;},
        listVersions:projectId=>versions.filter(version=>version.projectId===projectId)},
      animateTo:(options,update)=>update(),Curve:{EaseInOut:0},Edge:{Top:'top'},ensureCapabilities:async()=>{},logStep:()=>{},logMark:()=>{},trace:(name,fields)=>{traces.push({name,fields});},
      OperationController,throwIfCancelled,http,surfaceRouteEnabled:()=>false,drawsSurface:()=>false,
      composeEnabled:()=>side.compose,composePlanEnabled:()=>false,templateSelectEnabled:()=>true,
      buildScreen:(...a)=>tpl.build(...a),RouteRequest:route.RouteRequest,OUTCOME_AGENT:route.OUTCOME_AGENT,OUTCOME_CANCELLED:route.OUTCOME_CANCELLED,
      AgentRequest:agent.AgentRequest,appAgentHost:(status,preview,cancelled,language,surfaceGuide,cancellation)=>Object.assign(new agentHost.AgentHost(),{status,preview,language,surfaceGuide,cancellation,cancelled:()=>cancelled()||cancellation.isCancelled()}),traceCompile:()=>{},...(({addStage,appMs,yourMs,WHO_MODEL,WHO_PHONE})=>({addStage,appMs,yourMs,WHO_MODEL,WHO_PHONE}))(load(path.join(base,'RunStages.ets'))),...(({serviceNotes,serviceTrouble,resetServiceHealth})=>({serviceNotes,serviceTrouble,resetServiceHealth}))(load(path.join(base,'ServiceHealth.ets'))),...(({toolCalls,resetToolLog})=>({toolCalls,resetToolLog}))(load(path.join(base,'ToolLog.ets'))),UI_SELECT_FULL:selection.UI_SELECT_FULL,UI_SELECT_PROMPT:selection.UI_SELECT_PROMPT,settings,deepseek:deep.deepseek,DEEPSEEK_GENERATION_MAX_TOKENS:deep.DEEPSEEK_GENERATION_MAX_TOKENS,
      GenerateRequest:llama.GenerateRequest,GenerateResult:llama.GenerateResult,compileVeraSource:compiler.compileVeraSource,CompileError:compiler.CompileError,
      repairPrompt:repairMod.repairPrompt,applyRepair:repairMod.applyRepair,smokeRun:load(path.join(base,'VeraSmoke.ets')).smokeRun,
      selectUiForPrompt:(...a)=>side.selectUi(...a),describeCatalogForPrompt:()=>'',UI_TOOL_NOTE:'',
      compositionFromJson:j=>j.length>0?{}:null,compositionToJson:()=>'EDITED-RECORD',editComposition:(...a)=>side.edit(...a),selectEdit:()=>null,
      VersionMetrics:class{constructor(){Object.assign(this,{provider:'',model:'',elapsedMs:0,runs:0,attempts:0,inputTokens:-1,cacheHitTokens:-1,outputTokens:-1,estimatedUsd:-1,partial:false});}},

      engine:localEngine};
    const mod={exports:{}};new Function('module',...Object.keys(globals),compiled.outputText)(mod,...Object.values(globals));
    const c=new mod.exports();
    const host={filesDir:'/fixture',resourceManager:{}};
    c.getUIContext=()=>({getHostContext:()=>host,animateTo:(options,update)=>update(),getPromptAction:()=>({showToast:toast=>toasts.push(toast)})});
    Object.assign(c,{resourcesLoaded:true,runOnOpen:false,projectId:'',baseVersionId:'',baseVersionNumber:0,nextVersionNumber:1,savedVbc2:'',naming:false,saveName:'',iconsOpen:false,leaveAfterSave:false,closing:false,pendingBase:null,acceptedBase:null,versions,projects,toasts,scrollEdges,scroller:{scrollEdge:edge=>scrollEdges.push(edge)},pathStack:{pop(){}},activeOperation:new OperationController(),activeServerAbort:null,activeServerAbortRun:-1,modelReady:true,skillText:'',promptTemplate:skill,surfaceGuide:'',liveState:'',stages:[],sideCalls:[],disposed:false,keyboardWindow:null,lastRequest:'',questionText:'',questionOptions:[],questionFallback:0,answerQuestion:null,mode:'deepseek',attempt:1,systemPrompt:skill,uiSelected:[],grammar:'',previousSource:'',failedSource:'',
      attempts:[],compiledVbc2:'',cancelRequested:false,completionBase:'',completionBaseVbc2:'',completionComposition:'',compositionJson:'',templateKinds:[],modelWrote:false,runId:0,prompt:'',refinePrompt:'',repairByEdit:true,genStartTime:Date.now(),generatedSource:'',generating:true,
      metricTotals:{runs:0,attempts:0,elapsedMs:0,inputTokens:-1,cacheHitTokens:-1,outputTokens:-1,estimatedUsd:-1,partial:false},metricRunId:-1,metricMode:'',metricModel:'',metricPriced:false,metricRates:[0,0,0],metricSeenSideCalls:new Set(),metricPendingRuns:new Set(),metricStaleRuns:new Set(),
      requestHistory:'',pendingHistory:'',pendingRequest:'',acceptedRequest:'',acceptedComposition:'',acceptedOrigin:'',acceptedMetrics:null,compiledSource:'',totalMs:0,baseError:''});
    c.addToProgram=()=>{};c.currentRun=()=>null;c.startRun=()=>{};
    const runAttempt=c.runAttempt,callModel=c.callModel;
    c.runAttempt=(ask,feedback,operation=c.activeOperation)=>runAttempt.call(c,ask,feedback,operation);
    c.callModel=(request,onToken,run=c.runId,operation=c.activeOperation)=>callModel.call(c,request,onToken,run,operation);
    c.startAttemptOne=(ask,operation)=>{c.pending=c.runAttempt(ask,'',operation);};
    return c;
  }
  function compilerError(source){try{compiler.compileVeraSource(source);throw Error('Fixture compiled unexpectedly');}catch(e){assert(e instanceof compiler.CompileError);return e.message;}}
  const serviceHealth=load(path.join(base,'ServiceHealth.ets')),toolLog=load(path.join(base,'ToolLog.ets'));
  function staleRunMetrics(c){
    serviceHealth.resetServiceHealth();toolLog.resetToolLog();
    serviceHealth.noteService(serviceHealth.SERVICE_JEV,false,'stale service failure');
    toolLog.noteTool('find_sdk_function','stale lookup',37,false,'stale tool failure');
    Object.assign(c,{attempt:3,attempts:[{attempt:3,success:false}],totalMs:9876,sideCalls:[{inputTokens:71}],stages:[{name:'stale stage',ms:123}],
      services:serviceHealth.serviceNotes(),troubleNote:serviceHealth.serviceTrouble(),tools:toolLog.toolCalls()});
    for(const key of ['attempts','sideCalls','stages','services','tools'])assert.equal(c[key].length,1);
    assert(c.troubleNote.length>0);
  }
  function assertRunMetricsCleared(c){
    assert.equal(c.attempt,1);assert.equal(c.totalMs,0);assert.equal(c.troubleNote,'');
    for(const key of ['attempts','sideCalls','stages','services','tools'])assert.deepEqual(c[key],[],key);
    assert.deepEqual(serviceHealth.serviceNotes(),[]);assert.equal(serviceHealth.serviceTrouble(),'');assert.deepEqual(toolLog.toolCalls(),[]);
  }
  function acceptedState(c){
    const keys=['compiledSource','compiledVbc2','requestHistory','acceptedRequest','acceptedBase','acceptedComposition','acceptedOrigin','acceptedMetrics'];
    return Object.fromEntries(keys.map(key=>[key,c[key]]));
  }
  function staleAcceptedState(c){
    Object.assign(c,{compiledSource:example,compiledVbc2:'accepted bytecode',requestHistory:'Original request',acceptedRequest:'Accepted request',
      acceptedBase:{compiledSource:'Earlier source'},acceptedComposition:'accepted composition',acceptedOrigin:'accepted origin',
      acceptedMetrics:{provider:'DeepSeek',model:'test-model',runs:2,attempts:4,elapsedMs:3456,inputTokens:101,cacheHitTokens:61,outputTokens:23,estimatedUsd:0.25,partial:false}});
    Object.assign(c.metricTotals,c.acceptedMetrics);
  }
  await runAsync('Generate resetRunMetrics clears snapshots and real logs idempotently without resetting cumulative or accepted state',async()=>{
    reset();const c=page();staleRunMetrics(c);staleAcceptedState(c);
    c.metricRunId=17;c.metricSeenSideCalls.add(c.sideCalls[0]);c.metricPendingRuns.add(17);c.metricStaleRuns.add(16);
    c.program={runs:2,attempts:4,ms:3456,llmMs:3000,compileMs:456,inputTokens:101,cacheHitTokens:61,outputTokens:23};c.runs=[{request:'Accepted run'}];
    const totals=c.metricTotals,accepted=structuredClone(acceptedState(c)),program=structuredClone(c.program),runs=structuredClone(c.runs);
    const tracked={metricRunId:c.metricRunId,metricMode:c.metricMode,metricModel:c.metricModel,metricPriced:c.metricPriced,metricRates:[...c.metricRates],
      metricSeenSideCalls:[...c.metricSeenSideCalls],metricPendingRuns:[...c.metricPendingRuns],metricStaleRuns:[...c.metricStaleRuns]};
    const before=structuredClone(totals),owner=c.activeOperation,run=c.runId;
    for(let i=0;i<2;i++){
      c.resetRunMetrics();assertRunMetricsCleared(c);assert.equal(c.metricTotals,totals);assert.deepEqual(c.metricTotals,before);
      assert.deepEqual(acceptedState(c),accepted);assert.deepEqual(c.program,program);assert.deepEqual(c.runs,runs);assert.equal(c.activeOperation,owner);assert.equal(c.runId,run);
      for(const [key,value] of Object.entries(tracked))assert.deepEqual(c[key] instanceof Set?[...c[key]]:c[key],value,key);
    }
    assert.equal(requests.length,0);return {resets:2,realLogsCleared:true,cumulativeAndAcceptedStatePreserved:true};
  });
  await runAsync('Generate New clears stale run metrics and saved project state through actual startFresh and startNew before any generation',async()=>{
    reset();const c=page();c.generating=false;staleRunMetrics(c);staleAcceptedState(c);
    Object.assign(c,{projectId:'saved-project',savedVbc2:'saved bytecode',historyOpen:true,liveState:'live',carriedState:'carried',baseVersionId:'saved-version',baseVersionNumber:5,
      baseError:'stale error',previousSource:'previous source',pendingHistory:'pending history',pendingRequest:'pending request',pendingBase:{compiledSource:'pending base'},rewriting:true,
      generatedSource:'generated source',compositionJson:'composition',templateKinds:['chart'],modelWrote:true,previewVbc2:'preview bytecode',previewNote:'preview',compiled:true,
      compileErrors:'old errors',prompt:'old prompt',refinePrompt:'old refinement',lastRequest:'last request',status:'Old status',draft:'old draft',fullscreen:true,requestOpen:true,
      runs:[{request:'old run'}],program:{runs:2,attempts:4,ms:3456,inputTokens:101},metricRunId:17});
    c.metricSeenSideCalls.add(c.sideCalls[0]);
    c.projects.push({id:'saved-project',name:'Saved app'});c.versions.push({id:'saved-version',projectId:'saved-project'});
    let starts=0,generations=0,transports=0,resets=0;
    const startNew=c.startNew,resetMetrics=c.resetRunMetrics,originalFactory=transportFactory,owner=c.activeOperation,run=c.runId;
    c.startNew=()=>{starts++;return startNew.call(c);};c.resetRunMetrics=()=>{resets++;return resetMetrics.call(c);};
    const unexpected=()=>{generations++;throw Error('New must not generate');};
    c.doGenerate=c.doServerGenerate=c.refineWithModel=c.startAttemptOne=c.runAttempt=c.callModel=unexpected;
    transportFactory=()=>{transports++;throw Error('New must not create a transport');};
    try{
      for(let i=0;i<2;i++){
        c.startFresh();assertRunMetricsCleared(c);
        for(const key of ['projectId','savedVbc2','liveState','carriedState','baseVersionId','baseError','previousSource','requestHistory','pendingHistory','pendingRequest','acceptedRequest',
          'acceptedComposition','acceptedOrigin','compiledSource','compiledVbc2','generatedSource','compositionJson','previewVbc2','previewNote','compileErrors','prompt','refinePrompt','lastRequest','status','draft'])assert.equal(c[key],'',key);
        for(const key of ['pendingBase','acceptedBase','acceptedMetrics'])assert.equal(c[key],null,key);
        for(const key of ['historyOpen','rewriting','modelWrote','compiled','fullscreen','requestOpen','composerOpen','generating'])assert.equal(c[key],false,key);
        assert.deepEqual(c.templateKinds,[]);assert.deepEqual(c.runs,[]);
        assert.deepEqual({...c.program},{runs:0,attempts:0,ms:0,llmMs:0,compileMs:0,inputTokens:0,cacheHitTokens:0,outputTokens:0});
        assert.deepEqual({...c.metricTotals},{provider:'',model:'',elapsedMs:0,runs:0,attempts:0,inputTokens:-1,cacheHitTokens:-1,outputTokens:-1,estimatedUsd:-1,partial:false});
        assert.equal(c.metricRunId,-1);assert.equal(c.metricSeenSideCalls.size,0);assert.equal(c.baseVersionNumber,0);assert.equal(c.nextVersionNumber,1);assert.equal(c.tab,'preview');
        assert.equal(c.activeOperation,owner);assert.equal(owner.isCancelled(),false);assert.equal(c.runId,run);
      }
      assert.equal(starts,2);assert.equal(resets,2);assert.deepEqual(c.scrollEdges,['top','top']);
      assert.equal(generations,0);assert.equal(transports,0);assert.equal(requests.length,0);assert.equal(c.projects.length,1);assert.equal(c.versions.length,1);
    }finally{transportFactory=originalFactory;}
    return {actualStartNewCalls:starts,resets,realLogsCleared:true,generations,transports,savedDataNotDeleted:true};
  });
  await runAsync('Generate entry points share resetRunMetrics while held transports preserve cumulative and accepted metrics',async()=>{
    let scenarios=0;
    for(const action of ['doGenerate','doServerGenerate','refineWithModel']){
      reset();const c=page(),clients=[],originalFactory=transportFactory;staleRunMetrics(c);staleAcceptedState(c);c.generating=false;
      c.mode=action==='doServerGenerate'?'server':'deepseek';c.prompt='A new request';
      const totals=c.metricTotals,before=structuredClone(totals),accepted=structuredClone(acceptedState(c)),resetMetrics=c.resetRunMetrics;
      let resets=0,pending;
      c.resetRunMetrics=()=>{
        const cumulative=structuredClone(c.metricTotals);resets++;resetMetrics.call(c);assertRunMetricsCleared(c);
        assert.equal(c.metricTotals,totals);assert.deepEqual(c.metricTotals,cumulative);assert.deepEqual(acceptedState(c),accepted);
      };
      transportFactory=()=>{
        assert.equal(resets,1,action+' must use the common reset once');assertRunMetricsCleared(c);
        if(action!=='doServerGenerate'){const client=transport();clients.push(client);return client;}
        let finish;const held=new Promise(resolve=>{finish=resolve;});
        const client={destroyed:0,request(url,options){assert.equal(url,'https://server-test.invalid/compile');requests.push(options.extraData);return held;},
          destroy(){this.destroyed++;},finish(){finish({responseCode:503,result:'held server response'});}};
        clients.push(client);return client;
      };
      try{
        await patched([[settings,'getServerUrl',()=> 'https://server-test.invalid']],async()=>{
          if(action==='doServerGenerate')pending=c.doServerGenerate('A server change');
          else {c[action](...(action==='refineWithModel'?['A model change']:[]));pending=c.pending;}
          await until(()=>requests.length===1);assertRunMetricsCleared(c);assert.equal(resets,1);assert.equal(c.generating,true);
          assert.equal(c.metricTotals,totals);assert.deepEqual(acceptedState(c),accepted);
          assert.equal(c.metricTotals.runs,before.runs+1);assert.equal(c.metricTotals.attempts,before.attempts+1);
          for(const key of ['elapsedMs','inputTokens','cacheHitTokens','outputTokens','estimatedUsd'])assert.equal(c.metricTotals[key],before[key],action+' '+key);
          c.stopGeneration();clients.forEach(client=>client.finish());await promptly(pending);
          assert.deepEqual(acceptedState(c),accepted);assert.equal(clients[0].destroyed,1);scenarios++;
        });
      }finally{c.activeOperation.cancel();clients.forEach(client=>client.finish());if(pending)await pending;transportFactory=originalFactory;}
    }
    return {scenarios,commonResetCalls:scenarios,heldTransports:true,cumulativeAndAcceptedMetricsPreserved:true};
  });
  await runAsync('Shared generation token limit is 32768',async()=>{
    assert.equal(deep.DEEPSEEK_GENERATION_MAX_TOKENS,32768);return {maxTokens:32768};
  });
  await runAsync('Generate screen uses scoped host context and reports its absence',async()=>{
    reset();const c=page();assert.equal(c.hostContext().filesDir,'/fixture');
    c.getUIContext=()=>({getHostContext:()=>undefined});
    await assert.rejects(c.callModel(new llama.GenerateRequest(),()=>{}),/Generate host context is unavailable/);
    assert.equal(c.status,'Generate host context is unavailable');assert.equal(requests.length,0);
    return {scopedContext:true,missingContextReported:true,modelRequests:0};
  });
  await runAsync('Generate lifecycle Stop and disappearance cancel only their owner and scoped transports',async()=>{
    const originalStop=deep.deepseek.stop;
    let localStops=0,cloudStops=0,serverAborts=0,ownerCancels=0;
    deep.deepseek.stop=()=>{cloudStops++;};
    try{
      for(const action of ['stopGeneration','aboutToDisappear']){
        for(const mode of ['local','deepseek','server']){
          const c=page({stop(){localStops++;},generate(){c[action]();return new llama.GenerateResult();}});
          c.mode=mode;c.runId=7;c.metricPendingRuns.add(7);
          const owner=c.activeOperation;owner.onCancel(()=>{ownerCancels++;});
          let local;
          if(mode==='server'){c.activeServerAbort=()=>{serverAborts++;};c.activeServerAbortRun=7;}
          let answer='pending',detached=0;c.answerQuestion=value=>{answer=value;};
          c.keyboardListener=()=>{};
          c.keyboardWindow={off(event,listener){assert.equal(event,'keyboardHeightChange');assert.equal(listener,c.keyboardListener);detached++;}};
          const before=[localStops,cloudStops,serverAborts,ownerCancels];
          if(mode==='local')local=c.callModel(new llama.GenerateRequest(),()=>{});else c[action]();
          const expected=[before[0]+(mode==='local'?1:0),before[1],before[2]+(mode==='server'?1:0),before[3]+1];
          assert.deepEqual([localStops,cloudStops,serverAborts,ownerCancels],expected);
          assert.equal(owner.isCancelled(),true);assert.equal(c.cancelRequested,true);assert.equal(c.generating,false);
          assert.equal(c.runId,8);assert.equal(c.metricTotals.partial,true);assert(c.metricStaleRuns.has(7));
          assert.equal(answer,null);assert.equal(c.activeServerAbort,null);
          c.aboutToDisappear();c.aboutToDisappear();assert.equal(detached,1);assert.equal(c.keyboardWindow,null);
          assert.deepEqual([localStops,cloudStops,serverAborts,ownerCancels],expected);
          if(local)await local;
        }
      }
      for(const mode of ['local','deepseek','server']){
        const c=page({stop(){localStops++;}});c.mode=mode;c.generating=false;
        let answer='pending';c.answerQuestion=value=>{answer=value;};
        const before=[localStops,cloudStops,serverAborts],run=c.runId;c.aboutToDisappear();
        assert.deepEqual([localStops,cloudStops,serverAborts],before,'Idle disposal must not stop another consumer');
        assert.equal(c.activeOperation.isCancelled(),true);assert.equal(c.disposed,true);
        assert.equal(c.runId,run+1);assert.equal(answer,null);
      }
    }finally{deep.deepseek.stop=originalStop;}
    return {localStops,cloudStops,serverAborts,ownerCancels,idleDisposalSafe:true};
  });
  await runAsync('Generate server cancellation preserves a replacement run abort hook and local isolation',async()=>{
    reset();const clients=[],originalFactory=transportFactory;
    let localStops=0,globalStops=0;
    const c=page({stop(){localStops++;}});c.mode='server';
    transportFactory=()=>{
      let resolve;
      const pending=new Promise(done=>{resolve=done;});
      const client={destroyed:0,request(url,options){assert.equal(url,'https://server-test.invalid/compile');assert.equal(options.extraData,c.pendingHistory);return pending;},destroy(){this.destroyed++;},finish(){resolve({responseCode:200,result:'stale server response'});}};
      clients.push(client);return client;
    };
    let old,next;
    try{
      await patched([[settings,'getServerUrl',()=> 'https://server-test.invalid'],[deep.deepseek,'stop',()=>{globalStops++;}]],async()=>{
        old=c.doServerGenerate('First server request');const owner=c.activeOperation;
        assert.equal(clients.length,1);c.stopGeneration();assert.equal(owner.isCancelled(),true);assert.equal(clients[0].destroyed,1);
        next=c.doServerGenerate('Replacement server request');const nextOwner=c.activeOperation,abort=c.activeServerAbort,run=c.runId;
        clients[0].finish();await promptly(old);
        assert.equal(c.activeServerAbort,abort);assert.equal(c.activeServerAbortRun,run);assert.equal(clients[1].destroyed,0);
        assert.equal(nextOwner.isCancelled(),false);assert.equal(c.generating,true);assert.equal(c.compiledSource,'');
        c.aboutToDisappear();assert.equal(nextOwner.isCancelled(),true);assert.equal(clients[1].destroyed,1);
        clients[1].finish();await promptly(next);c.aboutToDisappear();
        assert.equal(c.activeServerAbort,null);assert.equal(c.attempts.length,0);assert.equal(c.compiledSource,'');
        assert.deepEqual(clients.map(client=>client.destroyed),[1,1]);assert.equal(localStops,0);assert.equal(globalStops,0);
      });
    }finally{
      c.activeOperation.cancel();clients.forEach(client=>client.finish());await Promise.all([old,next]);transportFactory=originalFactory;
    }
    return {staleServerIgnored:true,replacementAbortPreserved:true,localStops,globalStops};
  });
  await runAsync('Generate disappearance rejects a late model result',async()=>{
    reset();const c=page();let finishOld;
    c.callModel=()=>new Promise(resolve=>{finishOld=resolve;});
    const pending=c.runAttempt('first','');
    for(let i=0;i<5&&!finishOld;i++)await new Promise(resolve=>setTimeout(resolve,0));
    assert(finishOld,'Model call must have started');c.aboutToDisappear();
    finishOld(Object.assign(new llama.GenerateResult(),{text:example}));await pending;
    assert.notEqual(c.compiledSource,example);assert.equal(c.attempts.length,0);assert.equal(c.generating,false);
    return {staleResultIgnored:true};
  });
  await runAsync('Generate screen first candidate compiles with uniform settings and metrics',async()=>{
    reset();responses.push(example);const c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assert.equal(c.compiledSource,example);assert.equal(requests.length,1);assertUniform();
    assert.equal(c.attempts[0].thinking,true);assert.equal(c.attempts[0].success,true);
    return {attempts:1,thinking:requests[0].thinking.type,maxTokens:requests[0].max_tokens,metricsThinking:c.attempts[0].thinking};
  });
  await runAsync('Generate Save names a new app and keeps accepted source, history, metrics and version ancestry',async()=>{
    reset();responses.push(example);const c=page();
    c.prepareRequest('An editable amount log.');c.runId++;
    await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assertUniform();
    const accepted=c.currentBase();c.generatedSource='function broken(';
    c.doSave();assert.equal(c.naming,true);assert.equal(c.projects.length,0);assert.equal(c.versions.length,0);
    assert.equal(c.saveName,load(path.join(base,'AppName.ets')).suggestAppName(example,c.acceptedRequest));
    assert(c.saveIcon.length>0);c.cancelName();assert.equal(c.naming,false);assert.equal(c.projects.length,0);
    c.doSave();c.saveName='Amount log';c.confirmName();
    assert.equal(c.projects.length,1);assert.equal(c.projects[0].name,'Amount log');assert.equal(c.projects[0].icon,c.saveIcon);
    assert.equal(c.versions.length,1);const saved=c.versions[0];
    assert.deepEqual([saved.source,saved.vbc2,saved.prompt,saved.lastPrompt,saved.origin,saved.composition,saved.metrics],
      [accepted.compiledSource,accepted.compiledVbc2,accepted.requestHistory,accepted.acceptedRequest,accepted.acceptedOrigin,accepted.acceptedComposition,accepted.acceptedMetrics]);
    assert.equal(saved.parentVersionId,'');assert.equal(c.baseVersionId,saved.id);assert.equal(c.baseVersionNumber,1);
    assert.equal(c.nextVersionNumber,2);assert.equal(c.isSaved(),true);assert.equal(c.naming,false);
    c.doSave();assert.equal(c.projects.length,1);assert.equal(c.versions.length,2);
    assert.equal(c.versions[1].parentVersionId,saved.id);assert.equal(c.baseVersionNumber,2);assert.equal(c.nextVersionNumber,3);
    assert.equal(c.toasts.length,2);return {namedProjects:1,savedVersions:2,acceptedPairPreserved:true,versionAncestry:true};
  });
  await runAsync('Generate screen cancellation during capability wait sends no model request',async()=>{
    reset();const c=page();const pending=c.runAttempt('A counter.','');c.cancelRequested=true;await pending;
    assert.equal(requests.length,0);assert.equal(c.status,'Stopped');assert.equal(c.generating,false);
    return {modelRequests:0,status:c.status};
  });
  await runAsync('Generate screen compiler retry retains exact source and diagnostics',async()=>{
    reset();const broken='function broken(';const diagnostic=compilerError(broken);responses.push(broken,example);
    const c=page();await c.runAttempt('An editable amount log.','');assert.equal(c.compiled,true);assert.equal(c.attempt,2);assertUniform();
    assert.equal(requests[1].messages[1].content,broken);assert(requests[1].messages.at(-1).content.includes(diagnostic));
    assert(c.attempts.every(m=>m.thinking));assert.equal(c.attempts[0].success,false);assert.equal(c.attempts[1].success,true);
    return {attempts:2,exactFailedSource:true,exactCompilerDiagnostics:true,allMetricsThinking:true};
  });
  await runAsync('Generate screen refinement first attempt retains current compiled source',async()=>{
    reset();responses.push(example);const c=page();c.generating=false;c.compiledSource=example;c.refinePrompt='Change the amount to 30.';c.doRefine();await c.pending;
    assert.equal(c.compiled,true);assertUniform();assert.equal(requests[0].messages[1].content,example);
    assert(requests[0].messages.at(-1).content.includes(c.refinePrompt||'Change the amount to 30.'));
    assert.equal(c.attempts[0].thinking,true);return {attempts:1,currentSourcePreserved:true};
  });
  await runAsync('Generate screen all three compiler attempts use uniform settings',async()=>{
    reset();responses.push('function broken(','function broken(','function broken(');const c=page();await c.runAttempt('An amount log.','');
    assert.equal(c.attempts.length,3);assert.equal(c.generating,false);assert(c.compileErrors.length>0);assertUniform();
    return {attempts:3,terminalFailure:true};
  });
  settings.hasSelectorKey=()=>true;
  await runAsync('Generate screen ignores a stopped route run after a new Generate',async()=>{
    reset();side.compose=true;const c=page();c.generating=false;let finishOld,oldCancelled;
    tpl.build=(_r,host)=>{oldCancelled=host.cancelled;return new Promise(r=>{finishOld=r;});};
    c.prompt='first';c.doGenerate();c.stopGeneration();
    tpl.build=()=>new Promise(()=>{});c.prompt='second';c.doGenerate();side.compose=false;
    assert.equal(oldCancelled(),true,'the stopped run sees itself cancelled');
    finishOld(notBuilt());await settle(c);
    assert.equal(c.attempts.length,0,'the stopped run starts no attempt');assert.equal(c.generating,true);
    return {staleRunCancelled:true,newRunKept:true};
  });
  // A Stop followed by a new run resets cancelRequested, so each await below must see the old run as stale by its runId.
  function stopThenGenerate(c){c.stopGeneration();c.startAttemptOne=()=>{};c.prompt='second';c.doGenerate();}
  await runAsync('Generate screen ignores a stopped UI selection after a new Generate',async()=>{
    reset();const c=page();c.skillText=skill;c.promptTemplate=skill;let finishOld,attempts=0;
    side.selectUi=()=>new Promise(r=>{finishOld=r;});c.runAttempt=async()=>{attempts++;};
    const old=Object.getPrototypeOf(c).startAttemptOne.call(c,'first',c.activeOperation);stopThenGenerate(c);
    finishOld(new Set(['Text']));await old;
    assert.deepEqual(c.uiSelected,[]);assert.equal(attempts,0,'the stopped run makes no attempt');assert.equal(c.generating,true);
    return {staleRunIgnored:true};
  });
  await runAsync('Generate screen ignores a stopped model answer after a new Generate',async()=>{
    reset();const c=page();let finishOld;
    c.callModel=()=>new Promise(r=>{finishOld=r;});
    const old=c.runAttempt('first','');stopThenGenerate(c);
    finishOld(Object.assign(new llama.GenerateResult(),{text:example}));await old;
    assert.notEqual(c.compiledSource,example);assert.equal(c.attempts.length,0);assert.equal(c.generating,true);
    return {staleRunIgnored:true};
  });
  await runAsync('Generate screen ignores a stopped structural edit after a new Generate',async()=>{
    reset();const c=page();c.compositionJson='{"blocks":1}';let finishOld;
    side.edit=()=>new Promise(r=>{finishOld=r;});
    const old=c.tryStructuralEdit('add a chart');stopThenGenerate(c);
    finishOld({applied:true,note:'n',source:'EDITED',vbc2:'v',composition:{kinds:()=>['chart']}});await old;
    assert.notEqual(c.compiledSource,'EDITED');assert.equal(c.generating,true);
    return {staleRunIgnored:true};
  });
  await runAsync('Generate stale structural edit cancellation is swallowed after Stop or a new owner',async()=>{
    for(const restart of [false,true]){
      reset();const c=page();c.compositionJson='{"blocks":1}';let rejectOld,owner;
      side.edit=(_ask,_record,_mode,_select,operation)=>{owner=operation;return new Promise((_,reject)=>{rejectOld=reject;});};
      const old=c.tryStructuralEdit('add a chart');assert.equal(owner,c.activeOperation);
      if(restart)stopThenGenerate(c);else c.stopGeneration();
      const snapshot=[c.status,c.generating,c.runId,c.compiledSource,c.lastTemplatePick];
      assert.equal(owner.isCancelled(),true);rejectOld(cancellationError());await promptly(old);
      assert.deepEqual([c.status,c.generating,c.runId,c.compiledSource,c.lastTemplatePick],snapshot);
      if(restart)assert.notEqual(c.activeOperation,owner);
    }
    return {cancelledRejectionsSwallowed:2,newRunUntouched:true};
  });
  await runAsync('Generate beginOperation replaces only its owner and settles its question',async()=>{
    const c=page(),old=c.activeOperation,independent=new OperationController();let cancelled=0,answered=0;
    old.onCancel(()=>{cancelled++;});c.answerQuestion=value=>{assert.equal(value,null);answered++;};
    const next=c.beginOperation();assert.equal(old.isCancelled(),true);assert.equal(next,c.activeOperation);
    assert.notEqual(next,old);assert.equal(next.isCancelled(),false);assert.equal(independent.isCancelled(),false);
    assert.equal(cancelled,1);assert.equal(answered,1);assert.equal(c.answerQuestion,null);
    return {oldOwnerCancelled:true,newOwnerActive:true,questionSettledOnce:true};
  });
  async function ownership(cancelGenerate){
    let scenarios=0;
    for(const kind of ['widget','reply']){
      for(const action of ['stopGeneration','aboutToDisappear']){
        reset();const clients=[],c=page(),chatOwner=new OperationController();
        const originalFactory=transportFactory,originalStop=deep.deepseek.stop;
        let globalStops=0;
        deep.deepseek.stop=()=>{globalStops++;};transportFactory=()=>{const client=transport();clients.push(client);return client;};
        const observe=promise=>promise.then(value=>({value}),error=>({error}));
        let generation,conversation;
        try{
          generation=observe(c.runAttempt('An editable amount log.',''));
          await until(()=>clients[0]?.body);
          conversation=observe(kind==='widget'?
            chat.buildMiniApp(skill+widget,'An editable amount log.',()=>{},'',()=>{},()=>{},chatOwner):
            chat.chatReply([{role:'assistant',text:'Continue.'}],()=>{},()=>{},new (load(path.join(base,'VeraChatStats.ets')).ReplyStats)(),()=>{},chatOwner));
          await until(()=>clients[1]?.body);
          assert.equal(clients[0].body.thinking.type,'enabled');
          if(cancelGenerate){
            c[action]();assert.equal(c.activeOperation.isCancelled(),true);await promptly(generation);
            assert.equal(clients[0].destroyed,1);assert.equal(clients[1].destroyed,0);assert.equal(chatOwner.isCancelled(),false);
            clients[0].emit('stale Generate',true);clients[0].finish();
            clients[1].emit(kind==='widget'?example:'Independent chat answer');clients[1].finish();
            const result=await promptly(conversation);assert.equal(result.error,undefined);
            if(kind==='widget'){assert.equal(result.value.error,'');assert.equal(result.value.source,example);}
            else assert.equal(result.value,'Independent chat answer');
            assert.equal(c.status,'Stopped');assert.equal(c.compiledSource,'');assert.equal(c.attempts.length,0);
          }else{
            chatOwner.cancel();const result=await promptly(conversation);assert.equal(result.error?.name,'OperationCancelledError');
            assert.equal(clients[1].destroyed,kind==='reply'?2:1);assert.equal(clients[0].destroyed,0);assert.equal(c.activeOperation.isCancelled(),false);
            clients[1].emit('stale Chat',true);clients[1].finish();clients[0].emit(example);clients[0].finish();await promptly(generation);
            assert.equal(c.compiled,true);assert.equal(c.compiledSource,example);assert.equal(c.attempts.length,1);
          }
          assert.equal(globalStops,0,'Controller cancellation must never call global deepseek.stop');
          for(const [index,client] of clients.entries()){assert.equal(client.destroyed,index===1&&!cancelGenerate&&kind==='reply'?2:1);assert.equal(client.detached,1);}
          scenarios++;
        }finally{
          c.activeOperation.cancel();chatOwner.cancel();clients.forEach(client=>client.finish());
          await Promise.all([generation,conversation]);transportFactory=originalFactory;deep.deepseek.stop=originalStop;
        }
      }
    }
    return {scenarios,globalStops:0,independentOwners:true};
  }
  await runAsync('Generate Stop and lifecycle disposal preserve independent Chat engine ownership',()=>ownership(true));
  await runAsync('Chat owner cancellation preserves independent Generate engine ownership',()=>ownership(false));
  await runAsync('Generate metadata uses per-result usage and timing despite different singleton metrics',async()=>{
    reset();const c=page();c.prepareRequest('An editable amount log.');c.runId++;
    const result=Object.assign(new llama.GenerateResult(),{text:example,inputTokens:101,outputTokens:23,cacheHitTokens:61,finishReason:'stop',prefillMs:37,thinkMs:83,toolRounds:2});
    await patched(['lastCacheHitTokens','lastFinishReason','lastPrefillMs','lastThinkMs','lastToolRounds'].map(name=>[deep.deepseek,name,()=>{throw Error('Singleton metadata read: '+name);}]),async()=>{
      c.callModel=async()=>result;await c.runAttempt('An editable amount log.','');
    });
    assert.equal(c.compiled,true);const metric=c.attempts[0];
    assert.deepEqual([metric.inputTokens,metric.outputTokens,metric.cacheHitTokens,metric.finishReason,metric.ttftMs,metric.thinkMs],[101,23,61,'stop',37,83]);
    assert.deepEqual([c.acceptedMetrics.inputTokens,c.acceptedMetrics.outputTokens,c.acceptedMetrics.cacheHitTokens,c.acceptedMetrics.attempts],[101,23,61,1]);
    return {perResultUsage:true,perResultTiming:true,singletonReads:0};
  });
  await runAsync('Generate per-result finish reason length selects rewrite repair despite singleton stop',async()=>{
    for(const finish of ['length','stop']){
      reset();const c=page(),sent=[];const broken='function incomplete(';
      c.callModel=async request=>{sent.push(request);return Object.assign(new llama.GenerateResult(),{text:sent.length===1?broken:example,finishReason:sent.length===1?finish:'stop'});};
      await patched([[deep.deepseek,'lastFinishReason',()=>finish==='length'?'stop':'length']],()=>c.runAttempt('An editable amount log.',''));
      assert.equal(c.compiled,true);assert.equal(sent.length,2);assert.equal(sent[1].previousSource,broken);
      assert.equal(sent[1].repairByEdit,finish!=='length');assert.equal(sent[1].userPrompt.includes('<<<<<<< SEARCH'),finish!=='length');
      assert.equal(/cut off at the output token limit/.test(sent[1].userPrompt),finish==='length');
      assert.equal(c.attempts[0].finishReason,finish);
    }
    return {lengthRewrites:true,stopEdits:true,singletonDisagrees:true};
  });
  await runAsync('Generate controller metrics collect only owner scoped side-call metadata once',async()=>{
    reset();deep.deepseek.clearSideCalls();const c=page(),independent=new OperationController();
    c.prepareRequest('Owner metrics');c.runId++;
    for(const [owner,input,cached,out] of [[c.activeOperation,17,7,5],[independent,91,81,51]]){
      responses.push({content:'{"title":"ok"}',finish:'stop',usage:{prompt_tokens:input,prompt_cache_hit_tokens:cached,completion_tokens:out}});
      await deep.deepseek.extractTemplateContent('system','template',100,'Text',false,owner);
    }
    c.collectMetricSideCalls(c.runId);c.collectMetricSideCalls(c.runId);c.closeRun(false,0);
    assert.deepEqual([c.metricTotals.inputTokens,c.metricTotals.cacheHitTokens,c.metricTotals.outputTokens],[17,7,5]);
    assert.equal(c.sideCalls.length,1);assert.equal(c.sideCalls[0].inputTokens,17);assert.equal(deep.deepseek.getSideCalls(independent).length,1);
    return {ownerSideCalls:1,independentSideCalls:1,doubleCounted:false};
  });
  await runAsync('Widget first candidate compiles with uniform settings',async()=>{
    reset();responses.push(example);const result=await chat.buildMiniApp(skill+widget,'An editable amount log.',()=>{});
    assert.equal(result.error,'');assert.equal(result.attempts,1);assert.equal(result.source,example);assertUniform();
    return {attempts:1,thinking:requests[0].thinking.type,maxTokens:requests[0].max_tokens};
  });
  await runAsync('Widget all three compiler attempts use uniform settings',async()=>{
    reset();responses.push('function broken(','function broken(','function broken(');
    const result=await chat.buildMiniApp(skill+widget,'An amount log.',()=>{});assert.equal(result.attempts,3);assert(result.error.length>0);assertUniform();
    return {attempts:3,terminalFailure:true};
  });
  const lookup={toolCalls:[{index:0,id:'lookup',type:'function',function:{name:'find_sdk_function',arguments:'{"need":"battery level"}'}}]};
  load(path.join(base,'VeraSdkEmbeddingCache.ets')).findSdkFunctionByEmbedding=async()=>[];
  await runAsync('Generate screen tool continuation retains uniform settings',async()=>{
    reset();responses.push(lookup,example);const c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assert.equal(requests.length,2);assertUniform();
    assert(requests[1].messages.some(m=>m.role==='tool'));return {requests:2,toolResultDelivered:true};
  });
  await runAsync('Widget forced final tool round retains uniform settings',async()=>{
    reset();responses.push(lookup,lookup,lookup,lookup,example);
    const result=await chat.buildMiniApp(skill+widget,'An editable amount log.',()=>{});assert.equal(result.error,'');assert.equal(result.attempts,1);
    assert.equal(requests.length,5);assertUniform();
    // The final round keeps the tools defined but not callable, and says why.
    const last=requests.at(-1);assert(Array.isArray(last.tools)&&last.tools.length>0);assert.equal(last.tool_choice,'none');
    assert(last.messages.at(-1).role==='user'&&/lookup budget is used up/.test(last.messages.at(-1).content));
    return {requests:5,finalToolChoice:'none'};
  });
  await runAsync('Local generation keeps its original token budget',async()=>{
    reset();const c=page();c.mode='local';const request=new llama.GenerateRequest();request.maxTokens=2048;
    const result=await c.callModel(request,()=>{});assert.equal(result.request.maxTokens,2048);assert.equal(requests.length,0);
    return {maxTokens:2048,httpRequests:0};
  });
  await runAsync('Cloud and local refinement transport preserve source and request',async()=>{
    const request=new llama.GenerateRequest();request.systemPrompt=skill;request.previousSource=example;request.userPrompt='Change the amount to 30.';
    responses.push(example);const result=await deep.deepseek.generate(request,()=>{});
    const sent=requests.at(-1).messages;
    assert.equal(sent[0].role,'system');assert.equal(sent[1].content,example);assert(sent[2].content.includes(request.userPrompt));
    assert.equal(result.text,example);
    const local=new llama.LlamaEngine().buildPrompt(request);
    assert(local.includes(example));assert(local.includes(request.userPrompt));return {providers:2,sourcePreserved:true};
  });
  await runAsync('Widget compile-repair workflow uses failed source and original goal',async()=>{
    requests.length=0;responses.push('function broken(',example);
    const result=await chat.buildMiniApp(skill+widget,'A log with an editable amount.',()=>{});
    assert.equal(result.error,'');assert.equal(result.attempts,2);assert(result.vbc2.startsWith('["VBC2"'));assertUniform();
    const repair=requests[1].messages;
    assert.equal(repair[1].content,'function broken(');assert(repair[2].content.includes('A log with an editable amount.'));assert(repair[2].content.includes(compilerError('function broken(')));
    assert(repair[2].content.includes('<<<<<<< SEARCH')&&repair[2].content.includes('>>>>>>> REPLACE'),'Repair asks for edits');
    return {attempts:result.attempts,failedSourceReplayed:true};
  });
  await runAsync('Truncated widget generation repairs a complete replacement',async()=>{
    requests.length=0;responses.push({content:'function incomplete(',finish:'length'},example);
    const result=await chat.buildMiniApp(skill+widget,'An editable amount log.',()=>{});
    assert.equal(result.error,'');assert.equal(result.attempts,2);assertUniform();
    const repair=requests[1].messages.at(-1).content;
    assert(/cut off|truncat/i.test(repair));assert(repair.includes('An editable amount log.'));
    return {attempts:2,truncationFeedback:true};
  });
  // A compile error one edit away from the prompt example, and the edit that fixes it.
  const exampleLine=example.split('\n').find(l=>l.includes('ui.numberToString('));
  const brokenExample=example.replace(exampleLine,exampleLine.replace('ui.numberToString(','ui.numberToStrin('));
  // Copied without its indentation, as the model often does: matched in place.
  const fixEdit='<<<<<<< SEARCH\n'+exampleLine.replace('ui.numberToString(','ui.numberToStrin(').trim()+'\n=======\n'+exampleLine.trim()+'\n>>>>>>> REPLACE';
  await runAsync('Widget repair by edit applies SEARCH/REPLACE to the failed source',async()=>{
    requests.length=0;responses.push(brokenExample,fixEdit);
    const result=await chat.buildMiniApp(skill+widget,'A log with an editable amount.',()=>{});
    assert.equal(result.error,'');assert.equal(result.attempts,2);assert.equal(result.source,example.trim());assertUniform();
    assert.equal(requests[1].messages[1].content,brokenExample);assert(requests[1].messages.at(-1).content.includes('<<<<<<< SEARCH'));
    assert(requests[1].messages.at(-1).content.includes(' | '+exampleLine.replace('ui.numberToString(','ui.numberToStrin(')),'Diagnostic quotes its source line');
    assert(!/Return a complete replacement of the program above/.test(requests[1].messages.at(-1).content),'Edit repair is not wrapped as a rewrite');
    assert(Array.isArray(requests[1].tools)&&requests[1].tools.length>0&&requests[1].tool_choice==='none','Edit repair keeps tools defined but not callable');
    assert.notEqual(requests[0].tool_choice,'none');
    return {attempts:2,editApplied:true};
  });
  await runAsync('Widget edit that does not apply falls back to a full rewrite of the same failed source',async()=>{
    requests.length=0;responses.push(brokenExample,'<<<<<<< SEARCH\nlet nothing = 1\n=======\nlet nothing = 2\n>>>>>>> REPLACE',example);
    const result=await chat.buildMiniApp(skill+widget,'A log with an editable amount.',()=>{});
    assert.equal(result.error,'');assert.equal(result.attempts,3);assert.equal(result.stats[1].verdict,'edit not applied');
    const last=requests[2].messages;assert.equal(last[1].content,brokenExample);
    assert(/complete replacement/i.test(last.at(-1).content)&&!last.at(-1).content.includes('<<<<<<< SEARCH'));
    return {attempts:3,fallback:'rewrite'};
  });
  await runAsync('Truncated widget repair is a rewrite, not an edit',async()=>{
    requests.length=0;responses.push({content:'function incomplete(',finish:'length'},example);
    await chat.buildMiniApp(skill+widget,'An editable amount log.',()=>{});
    const repair=requests[1].messages.at(-1).content;assert(!repair.includes('<<<<<<< SEARCH'));assert(/complete replacement/i.test(repair));
    return {rewrite:true};
  });
  await runAsync('Generate screen repair by edit, then rewrite when an edit does not apply',async()=>{
    reset();responses.push(brokenExample,fixEdit);let c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assert.equal(c.attempt,2);assert.equal(c.compiledSource,example.trim());
    assert(requests[1].messages.at(-1).content.includes('<<<<<<< SEARCH'));
    reset();responses.push(brokenExample,'<<<<<<< SEARCH\nnot in it\n=======\nx\n>>>>>>> REPLACE',example);c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assert.equal(c.attempt,3);assert.equal(c.attempts[1].failLayer,'edit');
    assert.equal(requests[2].messages[1].content,brokenExample);assert(/complete replacement/i.test(requests[2].messages.at(-1).content));
    return {editAttempts:2,fallbackAttempts:3};
  });
  run('Repair diagnostics quote the line they point at, with a caret under the column',()=>{
    const src='let a = 1\nlet b = "x"\nlet c = a + b';
    const q=repairMod.quoteDiagnostics(src,'3:13 E2028 arithmetic operands must have identical types\nnot a located diagnostic');
    assert.equal(q,'3:13 E2028 arithmetic operands must have identical types\n    2 | let b = "x"\n    3 | let c = a + b\n'+' '.repeat(8+12)+'^\nnot a located diagnostic');
    assert(repairMod.repairPrompt('Goal.','1:1 E1001 x',true,'bad line').includes('    1 | bad line'));
    assert.equal(repairMod.quoteDiagnostics('','1:1 E1 x'),'1:1 E1 x');
    return {quoted:true};
  });
  run('applyRepair: indentation-tolerant, unique matches only, fences and whole programs',()=>{
    const src='function a(): number {\n  return 1;\n}\nfunction b(): number {\n  return 1;\n}';
    const ok=repairMod.applyRepair(src,'```\n<<<<<<< SEARCH\nfunction b(): number {\nreturn 1;\n=======\nfunction b(): number {\n  return 2;\n>>>>>>> REPLACE\n```');
    assert.equal(ok.source,'function a(): number {\n  return 1;\n}\nfunction b(): number {\n  return 2;\n}');assert.equal(ok.edits,1);
    const ambiguous=repairMod.applyRepair(src,'<<<<<<< SEARCH\n  return 1;\n=======\n  return 3;\n>>>>>>> REPLACE');
    assert.equal(ambiguous.source,'');assert(/exactly once/.test(ambiguous.error));
    const open=repairMod.applyRepair(src,'<<<<<<< SEARCH\nfunction a(): number {\n=======\nx');assert.equal(open.source,'');assert(/not closed/.test(open.error));
    const whole=repairMod.applyRepair(src,'```vera\nfunction c(): number { return 0; }\n```');assert.equal(whole.source,'function c(): number { return 0; }');assert.equal(whole.edits,0);
    return {cases:4};
  });
  await runAsync('One round of tool calls runs together and answers in call order',async()=>{
    reset();
    const two={toolCalls:[{index:0,id:'first',type:'function',function:{name:'find_sdk_function',arguments:'{"need":"battery level"}'}},{index:1,id:'second',type:'function',function:{name:'find_intent_function',arguments:'{"need":"open maps"}'}}]};
    responses.push(two,example);const c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);const tools=requests[1].messages.filter(m=>m.role==='tool').map(m=>m.tool_call_id);
    assert.deepEqual(tools,['first','second']);
    const engine=read('entry/src/main/ets/vera/DeepSeekEngine.ets');assert(/Promise\.all\(pendingResults\)/.test(engine));
    return {order:tools};
  });
  await runAsync('UI needs parser accepts one requirement without padding',async()=>{
    reset();responses.push('["editable numeric amount"]');
    const needs=await deep.deepseek.extractUiNeeds('An editable amount.');
    assert.deepEqual(needs,['editable numeric amount']);
    const sent=requests.at(-1);assert.equal(sent.messages.at(-1).content,'An editable amount.');assert.equal(sent.temperature,0);assert.equal(sent.thinking.type,'disabled');assert.equal(sent.max_tokens,300);
    return {phrases:needs.length,temperature:sent.temperature};
  });
  await runAsync('Chat marker streaming and description handoff',async()=>{
    reset();const description='Use a calm soft theme with a violet accent. Split a bill of 187.40 with a 12% tip among four people; show currency and editable inputs. Show the verified image https://example.com/verified.jpg.';
    const reply='Here is an editable split.\n<<app: '+description+'>>\nEach person pays 52.47.';
    responses.push(reply);let streamed='';await chat.chatReply([{role:'user',text:'Split 187.40 plus 12% tip among four people.'}],text=>{streamed=text},()=>{},new (load(path.join(base,'VeraChatStats.ets')).ReplyStats)());
    assert.equal(streamed,reply);
    const parsed=chat.parseReply(reply);assert.equal(parsed.appDescription,description);assert(parsed.appDescription.includes('calm soft theme with a violet accent'));assert(parsed.appDescription.includes('https://example.com/verified.jpg'));
    assert.equal(parsed.before,'Here is an editable split.');assert.equal(parsed.after,'Each person pays 52.47.');
    const partial=chat.parseReply('Here is the split.\n<<app: '+description);assert.equal(partial.describing,true);assert.equal(partial.appDescription,'');
    const sent=requests.at(-1).messages[0].content;
    assert(sent.includes('<<app:'));assert(/visual preferences|visual direction|style preferences/i.test(sent));assert.equal(requests.at(-1).thinking.type,'disabled');assert.equal(requests.at(-1).max_tokens,1024);return {completeMarker:true,partialMarkerHeld:true};
  });
  const revision=cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim();
  const scope=['entry/src/main/resources/rawfile/vera-skill.txt','entry/src/main/resources/rawfile/vera-widget.txt','entry/src/main/ets/vera/VeraChat.ets','entry/src/main/ets/vera/DeepSeekEngine.ets','entry/src/main/ets/pages/GeneratePage.ets','docs/prompt-evaluation.md'];
  const hashes=Object.fromEntries(scope.map(p=>[p,crypto.createHash('sha256').update(read(p)).digest('hex')]));
  const diff=cp.execFileSync('git',['diff','HEAD','--',...scope],{cwd:root,encoding:'utf8'});
  const report={revision,harness_sha256:crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex'),source_sha256:hashes,uncommitted_diff_sha256:crypto.createHash('sha256').update(diff).digest('hex'),command:'node '+__filename+' '+root+' '+output,inputs:'Checked-in prompt assets and deterministic mocked HTTP replies. Actual application compiler, VM, UI decoder and prompt transport execute on host.',expected:'All prompt and generation workflow checks PASS; DeepSeek application generation uses enabled reasoning and 32768 output tokens on every attempt.',observed:checks.some(c=>c.status==='FAIL')?'FAIL':'PASS',checks,limits:['HTTP and native imports are mocked. No real model or HarmonyOS device run. Generate screen methods execute from actual source with UI bookkeeping mocked. TypeScript transpilation is not an ArkTS SDK build.']};
  fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));process.exitCode=report.observed==='PASS'?0:1;
})().catch(e=>{console.error(e);process.exitCode=1});
