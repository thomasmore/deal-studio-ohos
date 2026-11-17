#!/usr/bin/env node
// Real VERA compiler/VM, deterministic clock and an in-memory calendar boundary.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), cp = require('node:child_process')
const {loadVera} = require('./source-loader')
const C = loadVera('VeraCompiler'), V = loadVera('VeraInterpreter'), U = loadVera('VeraUi')
const source = fs.readFileSync(path.join(__dirname, 'examples/pillpal.vera'), 'utf8')
const compiled = C.compileVeraSource(source)
const RealDate = Date
let now = new RealDate(2026, 9, 26, 7, 0).getTime()
global.Date = class extends RealDate {
  constructor(...args) { super(...(args.length ? args : [now])) }
  static now() { return now }
}
const value = v => v instanceof V.VeraObjectValue ? Object.fromEntries([...v.fields].map(([k,x]) => [k,value(x)])) : v instanceof V.VeraArrayValue ? v.elements.map(value) : v.value
const walk = n => [n, ...n.children.flatMap(walk)]
const out = path.resolve(process.argv[2] || '/tmp/vera-pillpal')
fs.mkdirSync(out, {recursive:true})
const checks = [], proofs = {}
function fixture() {
  const host = new U.UiHostEnvironment(), vm = new V.VirtualMachine(V.deserializeVbc2(compiled.vbc2), host)
  let state = vm.execute('init'), nextId = 100
  const calendar = new Map(), requests = []
  function act(name, payload = 0) {
    const before = JSON.stringify(V.encodeRuntimeValue(state)), old = state
    host.effectsAllowed = true
    try { state = vm.execute(name, [state, typeof payload === 'string' ? new V.VeraStringValue(payload) : typeof payload === 'boolean' ? new V.VeraBooleanValue(payload) : new V.VeraNumberValue(payload)]) }
    finally { host.effectsAllowed = false }
    assert.equal(JSON.stringify(V.encodeRuntimeValue(old)), before, name + ' mutated its input state')
    const tree = U.decodeVeraUi(vm.execute('view', [state]))[0]
    assert.equal(walk(tree).filter(n => n.kind === 'screen').length, 1, 'only active screen is constructed')
    return tree
  }
  function drain(fail = '') {
    let count = 0
    while (host.pendingEffects.length) {
      assert(++count < 1000, 'bounded calendar queue')
      const effect = host.pendingEffects.shift()
      assert.equal(effect.resultHandler, 'onCalendarAnswer')
      requests.push(effect)
      const target = effect.rawTarget, params = effect.values
      let reply = fail
      if (!reply && target === 'CalendarKit.Calendar.addEvent') {
        reply = String(nextId++)
        calendar.set(reply, Object.fromEntries(params))
      } else if (!reply && target === 'CalendarKit.Calendar.deleteEvent') {
        calendar.delete(params.get('id')); reply = 'ok'
      }
      assert(reply, 'known calendar target ' + target)
      act('onCalendarAnswer', reply)
      if (fail) break
    }
    return count
  }
  function capture(name) {
    const tree = U.decodeVeraUi(vm.execute('view', [state]))[0]
    proofs[name] = tree
    fs.writeFileSync(path.join(out, name + '.json'), JSON.stringify(tree, null, 2))
    const result = cp.spawnSync(process.execPath, [path.join(__dirname, 'proof-sheet.js'), '--width=360', '--label=' + name], {input: JSON.stringify(tree), encoding:'utf8'})
    assert.equal(result.status, 0, result.stderr)
    fs.writeFileSync(path.join(out, name + '.svg'), result.stdout)
  }
  return {host,vm,act,drain,capture,calendar,requests,get state(){return state},get data(){return value(state)}}
}
function test(name, fn) { fn(); checks.push(name); console.log('PASS ' + name) }
try {
  test('empty, editor validation and cancel do not modify shared records', () => {
    const f = fixture(); f.capture('today-empty'); f.act('goMedicines'); f.capture('medicines-empty')
    f.act('openNew'); f.capture('editor-new'); const invalidTree=f.act('saveMedicine')
    assert.match(f.data.error, /name/); assert.equal(f.host.pendingEffects.length, 0)
    const editor=walk(invalidTree).find(n=>n.kind==='screen')
    const banner=editor.children.findIndex(n=>n.kind==='banner'), firstSection=editor.children.findIndex(n=>n.kind==='section')
    assert(banner>=0 && firstSection>banner, 'validation is visible before the long form')
    f.capture('editor-validation')
    f.act('setName', 'Unsaved'); f.act('toggleDay', 0); f.act('addTime'); f.act('cancelEdit')
    assert.equal(f.data.screen, 'medicines'); assert.deepEqual(f.data.medicines, [])
    f.act('openNew'); assert.equal(f.data.draft.name, ''); assert.deepEqual(f.data.draft.times, [480])
  })
  test('save, switch screens while calendar is pending, callbacks preserve navigation and draft', () => {
    const f = fixture(); f.act('openNew'); f.act('setName', 'Vitamin D'); f.act('setDosage', '1 tablet'); f.act('setNotes', 'With breakfast'); f.act('saveMedicine')
    assert.equal(f.data.busy, true); assert.equal(f.data.medicines.length, 1)
    f.act('goMedicines'); f.act('openEdit', 1); f.act('setName', 'Draft name')
    f.drain(); assert.equal(f.data.screen, 'edit'); assert.equal(f.data.draft.name, 'Draft name')
    assert.equal(f.calendar.size, 14); assert.equal(f.data.refs.length, 14)
    assert.equal(f.data.medicines[0].name, 'Vitamin D'); f.capture('editor-existing')
    f.act('cancelEdit'); assert.equal(f.data.screen, 'medicines'); f.capture('medicines-populated')
    f.act('goToday'); f.capture('today-populated')
    const count = f.requests.length; f.act('syncCalendar'); f.drain(); assert.equal(f.requests.length, count, 'sync is idempotent with saved event refs')
  })
  test('multiple times, weekdays, dates and the 14-day/48-occurrence horizon', () => {
    const f = fixture(); f.act('openNew'); f.act('setName', 'Course'); f.act('presetDays', 1)
    f.act('addTime'); f.act('setTime', 1200); f.act('setHasEnd', true); f.act('saveMedicine'); f.drain()
    const expected = []
    for (let offset = 0; offset < 14; offset++) {
      const date = new RealDate(2026, 9, 26 + offset)
      if (date.getDay() === 0 || date.getDay() === 6) continue
      for (const minute of [480,1200]) expected.push(new RealDate(date.getFullYear(),date.getMonth(),date.getDate(),Math.floor(minute/60),minute%60).getTime())
    }
    assert.deepEqual(f.data.refs.map(r=>r.start), expected)
    assert.equal(f.calendar.size, 20)
    f.act('openEdit', 1); f.act('setName', 'Discard'); f.act('cancelEdit')
    assert.equal(f.data.medicines[0].name, 'Course')
    f.act('openEdit', 1); f.act('setEnd', f.data.day - 1); f.act('saveMedicine')
    assert.match(f.data.error, /End date/); assert.equal(f.host.pendingEffects.length, 0)
    f.act('setEnd', f.data.day + 13); f.act('setStart', f.data.day + 1); f.act('saveMedicine'); f.drain()
    assert.equal(f.data.refs.filter(r=>r.start>=now).length, 18)
    assert.equal(f.calendar.size, 18)
    const g=fixture(); g.act('openNew'); g.act('setName','Frequent')
    for(let i=0;i<5;i++){g.act('addTime');g.act('setTime',600+i*60)}
    g.act('saveMedicine');g.drain();assert.equal(g.calendar.size,48)
  })
  test('take, skip, undo, midnight and seven-day report use shared dose identities', () => {
    const f=fixture();f.act('openNew');f.act('setName','Daily');f.act('saveMedicine');f.drain()
    f.act('takeDose',1920);assert.equal(f.data.log[0].status,'taken')
    f.act('skipDose',1920);assert.equal(f.data.log.length,1);assert.equal(f.data.log[0].status,'skipped')
    f.act('undoDose',1920);assert.deepEqual(f.data.log,[])
    f.act('takeDose',1920);const previous=now;now+=86400000;f.act('refresh')
    assert.equal(f.vm.execute('doseStatus',[f.state,new V.VeraNumberValue(1),new V.VeraNumberValue(f.data.day),new V.VeraNumberValue(480)]).value,'')
    f.act('takeDose',1920);assert.equal(f.data.log.length,2);f.capture('today-two-days');now=previous
  })
  test('failures stay visible, retries retain successful refs, deletions are recoverable', () => {
    const f=fixture();f.act('openNew');f.act('setName','Retry');f.act('saveMedicine');f.drain('declined by the person')
    assert.equal(f.data.busy,false);assert.match(f.data.error,/declined/);assert.equal(f.data.medicines.length,1);f.capture('calendar-declined')
    f.act('syncCalendar');f.drain();assert.equal(f.calendar.size,14)
    f.act('openEdit',1);f.act('setDosage','2 tablets');f.act('saveMedicine');f.drain('error: delete failed')
    assert.equal(f.data.refs.length,14);assert.equal(f.calendar.size,14)
    f.act('syncCalendar');f.drain();assert.equal(f.calendar.size,14)
    assert([...f.calendar.values()].every(e=>e.description.includes('2 tablets')))
    f.act('takeDose',1920);f.act('askDelete',1);f.capture('delete-confirm');f.act('cancelDelete');assert.equal(f.data.medicines.length,1)
    f.act('askDelete',1);f.act('deleteMedicine');f.drain('error: deletion refused')
    assert.equal(f.data.medicines.length,0);assert.equal(f.data.log.length,0);assert.equal(f.data.refs.length,14)
    f.act('syncCalendar');f.drain();assert.equal(f.calendar.size,0);assert.deepEqual(f.data.refs,[])
  })
  test('serialized state restores every screen, saved records and stable identities in one module', () => {
    const f=fixture();f.act('openNew');f.act('setName','Saved');f.act('saveMedicine');f.drain();f.act('openEdit',1);f.act('setNotes','draft')
    const restored=V.decodeRuntimeValue(JSON.parse(JSON.stringify(V.encodeRuntimeValue(f.state))))
    const vm=new V.VirtualMachine(V.deserializeVbc2(compiled.vbc2),new U.UiHostEnvironment())
    assert.deepEqual(value(restored),f.data)
    assert.equal(walk(U.decodeVeraUi(vm.execute('view',[restored]))[0]).find(n=>n.kind==='screen').screenId,'edit-1')
    for(const fn of ['viewToday','viewMedicines','viewEditor','viewDelete']) assert(vm.execute(fn,[restored]))
  })
  test('interrupted requests are not automatically reissued',()=>{
    const f=fixture();f.act('openNew');f.act('setName','Interrupted');f.act('saveMedicine');f.host.pendingEffects=[]
    const old=now;now+=120000;f.act('refresh');assert.equal(f.data.busy,false);assert.match(f.data.error,/outcome is unknown/);assert.equal(f.host.pendingEffects.length,0);now=old
  })
  console.log('pillpal-check: ' + checks.length + ' scenarios; proofs: ' + out)
  fs.writeFileSync(path.join(out,'report.json'),JSON.stringify({checks,source:'tools/vera-harness/examples/pillpal.vera',calendar:'mocked boundary, not device verification',proofs:Object.keys(proofs)},null,2))
} finally { global.Date=RealDate }
