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
const http = {RequestMethod:{POST:'POST'}, createHttp(){
  let callback;
  return {on(event, fn){if(event==='dataReceive')callback=fn},off(){},destroy(){},
    async requestInStream(url,options){
      requests.push(JSON.parse(options.extraData));
      assert(responses.length, 'Missing deterministic HTTP response');
      const response=responses.shift(); const content=typeof response==='string'?response:response.content; const finish=typeof response==='string'?'stop':response.finish;
      const delta=typeof response==='object'&&response.toolCalls ? {tool_calls:response.toolCalls} : {content};
      const data='data: '+JSON.stringify({choices:[{delta,finish_reason:typeof response==='object'&&response.toolCalls?'tool_calls':finish}],usage:{prompt_tokens:1,completion_tokens:1}})+'\n\ndata: [DONE]\n\n';
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
    if(name==='@kit.ArkTS')return {util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}};
    if(name.startsWith('@kit.')||name==='libllama.so')return {};
    if(name.startsWith('.'))return load(path.join(path.dirname(file),name+'.ets'));
    throw Error('Unexpected dependency '+name);
  };
  new Function('require','module','exports',compiled.outputText)(requireLocal,mod,mod.exports);
  return mod.exports;
}
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8')}
function run(name,fn){try{const observed=fn();checks.push({name,status:'PASS',observed});return observed}catch(e){checks.push({name,status:'FAIL',observed:e.message});}}
async function runAsync(name,fn){try{const observed=await fn();checks.push({name,status:'PASS',observed});}catch(e){checks.push({name,status:'FAIL',observed:e.message});}}
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
  settings.getApiKey=()=> 'host-test-key';settings.hasApiKey=()=>true;
  settings.getModel=()=> 'test-model';settings.getBaseUrl=()=> 'https://host-test.invalid';
  function assertUniform(sent=requests){
    assert(sent.length>0,'No generation request');
    for(const body of sent){
      assert.equal(body.thinking.type,'enabled','Reasoning must be enabled');
      assert.equal(body.max_tokens,32768,'Uniform output-token limit');
      assert.equal(body.temperature,0.2,'Generation temperature preserved');
    }
  }
  function reset(){requests.length=0;responses.length=0;}
  function method(src,name){
    const start=src.search(new RegExp('private (?:async )?'+name+'(?:<[^>]*>)?\\('));assert(start>=0,'Method '+name);
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
  function page(){
    const src=read('entry/src/main/ets/pages/GeneratePage.ets');
    const prefix=src.slice(0,src.indexOf('@Entry')).replace(/^import .*$/gm,'');
    const code=prefix+'\nclass Controller { '+['hostContext','callModel','runAttempt','doRefine','traceEnd','closeRun','doGenerate','tryRoute','traceAgent','showAgent','settleQuestion','askPerson','startAttemptOne','tryStructuralEdit','fallBackToTemplate','refineWithModel','stopGeneration','originLabel','measuredTotal','addMetricUsage','metricWork','collectMetricSideCalls','beginMetricAttempt','recordMetricResult','finishMetrics','acceptRequest','copyMetrics','prepareRequest','ratePerMillion','modeLabel'].map(n=>method(src,n)).join('\n')+' } module.exports=Controller;';
    const compiled=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020},reportDiagnostics:true});
    assert.equal((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,'Extracted generation controller syntax');
    const globals={animateTo:(options,update)=>update(),Curve:{EaseInOut:0},ensureCapabilities:async()=>{},logStep:()=>{},logMark:()=>{},trace:(name,fields)=>{traces.push({name,fields});},
      composeEnabled:()=>side.compose,composePlanEnabled:()=>false,templateSelectEnabled:()=>true,
      buildScreen:(...a)=>tpl.build(...a),RouteRequest:route.RouteRequest,OUTCOME_AGENT:route.OUTCOME_AGENT,OUTCOME_CANCELLED:route.OUTCOME_CANCELLED,
      AgentRequest:agent.AgentRequest,appAgentHost:(status,preview,cancelled)=>Object.assign(new agentHost.AgentHost(),{status,preview,cancelled}),traceCompile:()=>{},...(({addStage,appMs,yourMs,WHO_MODEL,WHO_PHONE})=>({addStage,appMs,yourMs,WHO_MODEL,WHO_PHONE}))(load(path.join(base,'RunStages.ets'))),...(({serviceNotes,resetServiceHealth})=>({serviceNotes,resetServiceHealth}))(load(path.join(base,'ServiceHealth.ets'))),...(({toolCalls,resetToolLog})=>({toolCalls,resetToolLog}))(load(path.join(base,'ToolLog.ets'))),UI_SELECT_FULL:selection.UI_SELECT_FULL,UI_SELECT_PROMPT:selection.UI_SELECT_PROMPT,settings,deepseek:deep.deepseek,DEEPSEEK_GENERATION_MAX_TOKENS:deep.DEEPSEEK_GENERATION_MAX_TOKENS,
      GenerateRequest:llama.GenerateRequest,GenerateResult:llama.GenerateResult,compileVeraSource:compiler.compileVeraSource,CompileError:compiler.CompileError,
      repairPrompt:repairMod.repairPrompt,applyRepair:repairMod.applyRepair,smokeRun:load(path.join(base,'VeraSmoke.ets')).smokeRun,
      selectUiForPrompt:(...a)=>side.selectUi(...a),describeCatalogForPrompt:()=>'',UI_TOOL_NOTE:'',
      compositionFromJson:j=>j.length>0?{}:null,compositionToJson:()=>'EDITED-RECORD',editComposition:(...a)=>side.edit(...a),selectEdit:()=>null,
      VersionMetrics:class{constructor(){Object.assign(this,{provider:'',model:'',elapsedMs:0,runs:0,attempts:0,inputTokens:-1,cacheHitTokens:-1,outputTokens:-1,estimatedUsd:-1,partial:false});}},

      engine:{stop(){},generate(request){return {text:example,inputTokens:1,outputTokens:1,request}}}};
    const mod={exports:{}};new Function('module',...Object.keys(globals),compiled.outputText)(mod,...Object.values(globals));
    const c=new mod.exports();
    const host={filesDir:'/fixture',resourceManager:{}};
    c.getUIContext=()=>({getHostContext:()=>host});
    Object.assign(c,{lastRequest:'',questionText:'',questionOptions:[],questionFallback:0,answerQuestion:null,mode:'deepseek',attempt:1,systemPrompt:skill,uiSelected:[],grammar:'',previousSource:'',failedSource:'',
      attempts:[],compiledVbc2:'',cancelRequested:false,completionBase:'',completionBaseVbc2:'',completionComposition:'',compositionJson:'',templateKinds:[],modelWrote:false,runId:0,prompt:'',refinePrompt:'',repairByEdit:true,genStartTime:Date.now(),generatedSource:'',generating:true,
      metricTotals:{runs:0,attempts:0,elapsedMs:0,inputTokens:-1,cacheHitTokens:-1,outputTokens:-1,estimatedUsd:-1,partial:false},metricRunId:-1,metricMode:'',metricModel:'',metricPriced:false,metricRates:[0,0,0],metricSeenSideCalls:new Set(),metricPendingRuns:new Set(),metricStaleRuns:new Set(),
      requestHistory:'',pendingHistory:'',pendingRequest:'',acceptedRequest:'',acceptedComposition:'',acceptedOrigin:'',acceptedMetrics:null,compiledSource:'',totalMs:0,baseError:''});
    c.addToProgram=()=>{};c.currentRun=()=>null;c.startRun=()=>{};
    c.startAttemptOne=ask=>{c.pending=c.runAttempt(ask,'');};
    return c;
  }
  function compilerError(source){try{compiler.compileVeraSource(source);throw Error('Fixture compiled unexpectedly');}catch(e){assert(e instanceof compiler.CompileError);return e.message;}}
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
  await runAsync('Generate screen first candidate compiles with uniform settings and metrics',async()=>{
    reset();responses.push(example);const c=page();await c.runAttempt('An editable amount log.','');
    assert.equal(c.compiled,true);assert.equal(c.compiledSource,example);assert.equal(requests.length,1);assertUniform();
    assert.equal(c.attempts[0].thinking,true);assert.equal(c.attempts[0].success,true);
    return {attempts:1,thinking:requests[0].thinking.type,maxTokens:requests[0].max_tokens,metricsThinking:c.attempts[0].thinking};
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
    reset();responses.push(example);const c=page();c.compiledSource=example;c.refinePrompt='Change the amount to 30.';c.doRefine();await c.pending;
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
    reset();side.compose=true;const c=page();let finishOld,oldCancelled;
    tpl.build=(_r,host)=>{oldCancelled=host.cancelled;return new Promise(r=>{finishOld=r;});};
    c.prompt='first';c.doGenerate();c.stopGeneration();
    tpl.build=()=>new Promise(()=>{});c.prompt='second';c.doGenerate();side.compose=false;
    assert.equal(oldCancelled(),true,'the stopped run sees itself cancelled');
    finishOld(notBuilt());await settle(c);
    assert.equal(c.attempts.length,0,'the stopped run starts no attempt');assert.equal(c.generating,true);
    return {staleRunCancelled:true,newRunKept:true};
  });
  // A Stop followed by a new run resets cancelRequested, so each await below must see the old run as stale by its runId.
  function stopThenGenerate(c){c.stopGeneration();c.prompt='second';c.doGenerate();}
  await runAsync('Generate screen ignores a stopped UI selection after a new Generate',async()=>{
    reset();const c=page();c.skillText=skill;c.promptTemplate=skill;let finishOld,attempts=0;
    side.selectUi=()=>new Promise(r=>{finishOld=r;});c.runAttempt=async()=>{attempts++;};
    const old=Object.getPrototypeOf(c).startAttemptOne.call(c,'first');stopThenGenerate(c);
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
    responses.push('["editable numeric amount"]');
    const needs=await deep.deepseek.extractUiNeeds('An editable amount.');
    assert.deepEqual(needs,['editable numeric amount']);
    const sent=requests.at(-1);assert.equal(sent.messages.at(-1).content,'An editable amount.');assert.equal(sent.temperature,0);assert.equal(sent.thinking.type,'disabled');assert.equal(sent.max_tokens,300);
    return {phrases:needs.length,temperature:sent.temperature};
  });
  await runAsync('Chat marker streaming and description handoff',async()=>{
    const description='Use a calm soft theme with a violet accent. Split a bill of 187.40 with a 12% tip among four people; show currency and editable inputs. Show the verified image https://example.com/verified.jpg.';
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
