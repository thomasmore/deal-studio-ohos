// Persistence/migration tests for the phone's explicit selector choice. No device or secrets.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/vera/SettingsStore.ets'), 'utf8')
const js = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText
let disk = '', ready = false
const platformFs = {mkdirSync(){}, statSync(){return {size:disk.length}}, readTextSync(){return disk},
  OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},openSync(){return {fd:1}},writeSync(_fd,text){disk=text},closeSync(){}}
function fresh() {
  const mod={exports:{}}
  new Function('require','module','exports',js)(name => {
    if(name==='@kit.CoreFileKit') return {fileIo:platformFs}
    if(name==='./LocalJev') return {localJev:{isReady:()=>ready}}
    throw Error(name)
  },mod,mod.exports)
  const store=new mod.exports.SettingsStore();store.init('/fake');return store
}
let s=fresh()
assert.equal(s.getSelectorMode(),'typesafe')
assert.equal(s.hasSelector(),false)
s.setSelectorKey('fixture-typesafe');assert.equal(s.hasSelector(),true)
for(const mode of ['llm','local','typesafe']) {
  s.setSelectorMode(mode);s=fresh()
  assert.equal(s.getSelectorMode(),mode)
  assert.equal(s.useLocalSelector(),mode==='local')
  assert.equal(s.useJevProxy(),mode==='llm')
}
s.setSelectorMode('llm')
assert.equal(s.hasSelector(),false,'TypeSafe key must not satisfy selected LLM credentials')
s.setApiKey('fixture-cloud');assert.equal(s.hasSelector(),true)
s.setSelectorMode('local');assert.equal(s.hasSelector(),false,'no fallback while model unavailable')
ready=true;assert.equal(s.hasSelector(),true)
s.setSelectorMode('invalid');assert.equal(s.getSelectorMode(),'local')
s.setJevProxy('1');assert.equal(s.getSelectorMode(),'local','legacy proxy cannot steal explicit local mode')
s.setLocalSelector(false);assert.equal(s.getSelectorMode(),'llm')
s.setJevProxy('');assert.equal(s.getSelectorMode(),'typesafe')
s.setLocalSelector(true);s=fresh();assert.equal(s.getSelectorMode(),'local')
disk=JSON.stringify({jevProxy:'1',apiKey:'fixture-cloud'})
s=fresh();assert.equal(s.getSelectorMode(),'llm','migrate legacy proxy');assert.equal(s.hasSelector(),true)
disk=JSON.stringify({jevProxy:'1',selectorMode:'typesafe'})
s=fresh();assert.equal(s.getSelectorMode(),'typesafe','explicit provider wins over stale legacy flag')
disk=JSON.stringify({selectorMode:'invalid'})
s=fresh();assert.equal(s.getSelectorMode(),'typesafe')
console.log('selector-settings-check ok: three providers, restart persistence, credential gating, migration, no fallback')
