'use strict'
// Template-block scenarios that share template-fixture.js. Each scenario keeps the
// assertions of the check it replaces; the suite reports per scenario and exits 1
// if any fails, so a single broken block is still identifiable.
const {
  assert, fragments, specOf, values, build, buildFromMaps, walk, nodes, texts, text, act, num, str, bool,
  composeProgram, composeFragments, bindPorts, readSectionPick, expandListRows, compileVeraSource,
  VirtualMachine, deserializeVbc2, UiHostEnvironment, decodeVeraUi, globals,
  FragmentSpec, StateFieldSpec, PortSpec,
} = require('./template-fixture')

function dueValues(items) {
  const spec = specOf('due_items'), m = new Map()
  spec.slots.forEach(s => m.set(s.token, s.values[0]))
  spec.contentFields.forEach(c => m.set(c.token, c.fallback))
  spec.listFields.forEach(l => m.set(l.token, items))
  return m
}

function dueItems() {
  const rows = (h, st) => nodes(h, st).filter(n => n.kind === 'listitem').map(n => [n.text, n.value, n.style])
  const stats = (h, st) => nodes(h, st).filter(n => n.kind === 'numberstat').map(n => [n.label, n.numberValue, n.style])
  const now = new Date()
  const today = Math.floor((now.getTime() - now.getTimezoneOffset() * 60000) / 86400000)
  {
    const h = buildFromMaps('due_items', [dueValues('{name: "Milk", inDays: 1, lifeDays: 0},\n    {name: "Water filter", inDays: 40, lifeDays: 90},\n    {name: "Bread", inDays: -2, lifeDays: 0}')])
    let st = h.vm.execute('init')
    assert.deepEqual(rows(h, st), [['Bread', 'Expired 2 days ago', 'danger'], ['Milk', 'Tomorrow', 'warning'], ['Water filter', 'In 40 days', 'default']])
    assert.deepEqual(stats(h, st), [['Expired', 1, 'danger'], ['Due soon', 1, 'warning']])
    assert.match(text(h, st), /every 90 days · 44% left/)
    const done = nodes(h, st).filter(n => n.kind === 'button'    && n.text === 'Done')
    assert.equal(done.length, 1)
    st = h.vm.execute('setName1', [st, str('  Yogurt ')])
    st = h.vm.execute('setDue1', [st, num(today + 3)])
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.deepEqual(rows(h, st).map(r => r[0]), ['Bread', 'Milk', 'Yogurt', 'Water filter'])
    assert.deepEqual(rows(h, st)[2], ['Yogurt', 'In 3 days', 'warning'])

    assert.deepEqual(stats(h, st), [['Expired', 1, 'danger'], ['Due soon', 2, 'warning']])
    assert.equal(h.vm.execute('soonNames1', [st]).value, 'Milk, Yogurt')
    assert.equal(h.vm.execute('soonCount1', [st]).value, 2)
    assert.equal(h.vm.execute('expiredCount1', [st]).value, 1)

    const before = rows(h, st).length
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.equal(rows(h, st).length, before)
    st = h.vm.execute('renew1', [st, num(1)])
    assert.deepEqual(rows(h, st)[3], ['Water filter', 'In 90 days', 'default'])
    assert.match(text(h, st), /every 90 days · 100% left/)

    const once = JSON.stringify(rows(h, st))
    st = h.vm.execute('renew1', [st, num(0)])
    assert.equal(JSON.stringify(rows(h, st)), once)
    st = h.vm.execute('removeItem1', [st, num(2)])
    assert.deepEqual(rows(h, st).map(r => r[0]), ['Milk', 'Yogurt', 'Water filter'])
    assert.deepEqual(stats(h, st)[0], ['Expired', 0, 'default'])

    st = h.vm.execute('setSoon1', [st, num(1)])
    assert.deepEqual(rows(h, st)[1], ['Yogurt', 'In 3 days', 'default'])
    assert.deepEqual(stats(h, st)[1], ['Due soon', 1, 'warning'])

    st = h.vm.execute('setName1', [st, str('Eggs')]); st = h.vm.execute('setDue1', [st, num(today)]); st = h.vm.execute('addItem1', [st, num(0)])
    assert.deepEqual(rows(h, st)[0], ['Eggs', 'Today', 'danger'])
    st = h.vm.execute('setName1', [st, str('Smoke alarm battery')]); st = h.vm.execute('setDue1', [st, num(today + 10)])
    st = h.vm.execute('setLife1', [st, str('365')]); st = h.vm.execute('addItem1', [st, num(0)])
    assert.match(text(h, st), /Smoke alarm battery/); assert.match(text(h, st), /every 365 days/)
  }
  {
    const h = buildFromMaps('due_items', [dueValues('')])
    const st = h.vm.execute('init')
    assert.deepEqual(rows(h, st), [])
    assert.deepEqual(stats(h, st), [])
    assert.match(text(h, st), /Nothing tracked yet/)
  }
  {
    const spec = specOf('due_items')
    assert.deepEqual(spec.ports.map(p => p.name), ['soon_count', 'expired_count', 'soon_names', 'count'])
    assert.ok(spec.owns.length > 0)
    const h = buildFromMaps('due_items', [dueValues('{name: "Spinach", inDays: 0, lifeDays: 0},\n    {name: "Eggs", inDays: 2, lifeDays: 0},\n    {name: "Rice", inDays: 200, lifeDays: 0}')])
    assert.match(h.src, /function soonNames1\(state: AppState\): string/)
  }
}

function readingStatus() {
  const FEVER = [['38', 'Normal', 'success', 'Keep an eye on it.'], ['39', 'Fever', 'warning', 'Fluids and light clothes.'],
    ['0', 'High fever', 'danger', 'Call a doctor.']]
  const C = {reading_label: 'Temperature', unit: '°C', unit_suffix: ' °C', decimals: '1'}
  function readingBuild(content = {}, bands = FEVER) {
    const spec = specOf('reading_status')
    const over = {}
    spec.contentFields.forEach(c => { if (content[c.key] !== undefined) over[c.token] = content[c.key] })
    return build('reading_status', {reading_status: over}, {reading_status: bands}, {smoke: true})
  }
  const big = (h, st) => { const t = nodes(h, st).find(n => n.kind === 'text' && n.style === 'display'); return t ? t.text : null }
  const status = (h, st) => { const card = nodes(h, st).find(n => n.kind === 'card'); if (!card) return null; let b = null; walk(card, n => { if (n.kind === 'badge') b = [n.text, n.style] }); return [card.style].concat(b) }
  const add = (h, st, typed) => h.vm.execute('addReading1', [h.vm.execute('setReadingDraft1', [st, str(typed)]), num(0)])
  {
    const h = readingBuild(Object.assign({first_reading: '37.5'}, C))
    const st = h.vm.execute('init')
    assert.equal(big(h, st), '37.5 °C')
    assert.deepEqual(status(h, st), ['success', 'Normal', 'success'])
    assert.ok(texts(h, st).includes('Keep an eye on it.'))
    assert.ok(texts(h, st).includes('Temperature (°C)'), 'the form names the unit')
    const guide = nodes(h, st).filter(n => n.kind === 'listitem' && ['Normal', 'Fever', 'High fever'].includes(n.text))
    assert.deepEqual(guide.map(n => n.value), ['Under 38.0 °C', '38.0 °C to 39.0 °C', '39.0 °C or more'])
    assert.equal(nodes(h, st).filter(n => n.kind === 'sparkline').length, 0, 'one reading: no line yet')
  }
  {
    const h = readingBuild(Object.assign({first_reading: ''}, C))
    let st = h.vm.execute('init')
    assert.equal(big(h, st), null)
    assert.ok(texts(h, st).includes('Add a reading to see what it means.'))
    assert.ok(!nodes(h, st).some(n => n.kind === 'emptystate'), 'no empty-state block')
    assert.equal(JSON.stringify(add(h, st, 'abc')), JSON.stringify(h.vm.execute('setReadingDraft1', [st, str('abc')])))
    st = add(h, st, '38.4')
    assert.equal(big(h, st), '38.4 °C')
    assert.deepEqual(status(h, st), ['warning', 'Fever', 'warning'])
    assert.equal(h.vm.execute('statusLevel1', [st]).value, 1)
    st = add(h, st, '39.2')
    assert.deepEqual(status(h, st), ['danger', 'High fever', 'danger'])
    assert.equal(h.vm.execute('statusLevel1', [st]).value, 2)
    assert.equal(h.vm.execute('latest1', [st]).value, 39.2)
    const line = nodes(h, st).find(n => n.kind === 'sparkline')
    assert.ok(line, 'two readings: a line')
    const rows = nodes(h, st).filter(n => n.kind === 'listitem' && /°C$/.test(n.text))
    assert.deepEqual(rows.map(n => [n.text, n.value]), [['39.2 °C', 'High fever'], ['38.4 °C', 'Fever']])
    st = h.vm.execute('removeReading1', [st, num(1)])
    assert.deepEqual(status(h, st), ['warning', 'Fever', 'warning'])
    assert.equal(nodes(h, st).filter(n => n.kind === 'sparkline').length, 0)
    st = add(h, st, '36.9')
    assert.deepEqual(status(h, st), ['success', 'Normal', 'success'])
    assert.equal(h.vm.execute('statusLevel1', [st]).value, 0)
  }
  {
    const h = readingBuild({reading_label: 'Pulse', unit: 'bpm', unit_suffix: ' bpm', decimals: '0', first_reading: '62'},
      [['70', 'Low', 'warning', 'Sit and rest.'], ['100', 'Normal', 'success', 'All fine.'], ['0', 'High', 'danger', 'Call a doctor.']])
    let st = h.vm.execute('init')
    assert.equal(big(h, st), '62 bpm')
    assert.deepEqual(status(h, st), ['warning', 'Low', 'warning'])
    st = add(h, st, '120')
    assert.deepEqual(status(h, st), ['danger', 'High', 'danger'])
  }
  {
    const spec = specOf('reading_status')
    assert.deepEqual(spec.ports.map(p => p.dir + ' ' + p.name), ['writes latest', 'writes status_level', 'writes count'])
    assert.ok(spec.owns.length > 0)
  }
}

function doseSchedule() {
  const RealDate = Date
  let now = new RealDate(2026, 10, 3, 7, 0, 0)
  global.Date = class extends RealDate { constructor(...a) { if (a.length === 0) { super(now.getTime()) } else { super(...a) } } }
  const at = (h, m, dayShift = 0) => { now = new RealDate(2026, 10, 3 + dayShift, h, m, 0) }
  const DOSES = [['Vitamin D', '08:00', 'with food'], ['Iron', '20:30', ''], ['Bad time', '99:99', '']]
  const doseBuild = (calendar, doses = DOSES) => build('dose_schedule', {dose_schedule: {__CALENDAR_IDX__: calendar}}, {dose_schedule: doses})
  const row = (h, st, name) => nodes(h, st).find(n => n.kind === 'listitem' && n.text === name)
  try {
    const h = doseBuild('false')
    at(7, 0)
    let st = h.vm.execute('init')
    let t = text(h, st)
    assert.match(t, /0 of 3 taken today/); assert.match(t, /Vitamin D\|08:00 - with food/); assert.match(t, /Iron\|20:30/)
    assert.match(t, /Bad time\|08:00/, 'a time that is not a time of day falls back to 08:00')
    assert.match(t, /0 days\|Streak/)
    at(9, 0)
    assert.equal(row(h, st, 'Vitamin D').style, 'warning'); assert.match(text(h, st), /Due 08:00 - late/)
    assert.equal(row(h, st, 'Iron').style, 'default')
    st = act(h, 'takeDose1', st, num(0)).st
    assert.equal(row(h, st, 'Vitamin D').style, 'success'); assert.equal(row(h, st, 'Vitamin D').value, 'Taken 09:00')
    assert.match(text(h, st), /1 of 3 taken today/); assert.match(text(h, st), /Undo/)
    st = act(h, 'takeDose1', st, num(0)).st
    assert.match(text(h, st), /0 of 3 taken today/); assert.equal(row(h, st, 'Vitamin D').style, 'warning')
    st = act(h, 'removeDose1', st, num(2)).st
    assert.doesNotMatch(text(h, st), /Bad time/)
    st = act(h, 'takeDose1', st, num(0)).st; at(21, 0); st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /2 of 2 taken today/); assert.match(text(h, st), /1 day\|Streak/)
    assert.equal(nodes(h, st).find(n => n.kind === 'progress').style, 'success')
    let undone = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, undone), /0 days\|Streak/)
    assert.match(text(h, act(h, 'takeDose1', undone, num(1)).st), /1 day\|Streak/)
    at(7, 0, 1)
    assert.match(text(h, st), /0 of 2 taken today/); assert.match(text(h, st), /1 day\|Streak/)
    st = act(h, 'takeDose1', st, num(0)).st; st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /2 days\|Streak/)
    at(7, 0, 3)
    assert.match(text(h, st), /0 days\|Streak/)
    st = act(h, 'takeDose1', st, num(0)).st; st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /1 day\|Streak/)
    assert.equal(text(h, act(h, 'addDose1', st, num(0)).st), text(h, st), 'no name adds nothing')
    let s2 = act(h, 'setDoseName1', st, str('Omega 3')).st; s2 = act(h, 'setDoseTime1', s2, num(13 * 60 + 15)).st
    s2 = act(h, 'addDose1', s2, num(0)).st
    assert.match(text(h, s2), /Omega 3\|13:15/); assert.match(text(h, s2), /2 of 3 taken today/)
    {
      const e = doseBuild('false', [])
      const s = e.vm.execute('init')
      assert.match(text(e, s), /No doses yet/); assert.ok(!nodes(e, s).some(n => n.kind === 'emptystate'))
    }
    {
      at(7, 0)
      const c = doseBuild('true', [['Vitamin D', '08:00', '']])
      let s = c.vm.execute('init')
      let r = act(c, 'calendarDose1', s, num(0))
      assert.equal(r.effects.length, 1); assert.equal(r.effects[0].rawTarget, 'CalendarKit.Calendar.addEvent'); assert.equal(r.effects[0].resultHandler, 'onDoseAdded1')
      assert.deepEqual(Object.fromEntries(r.effects[0].values), {title: 'Take Vitamin D', hour: '8', minute: '0', durationMinutes: '15', remindBefore: '0',
        repeat: 'daily', description: 'Daily dose'})
      assert.match(text(c, r.st), /sending to calendar/)
      assert.equal(act(c, 'calendarDose1', r.st, num(0)).effects.length, 0, 'one call at a time')
      s = act(c, 'onDoseAdded1', r.st, str('777')).st
      assert.match(text(c, s), /in calendar/)
      assert.equal(act(c, 'calendarDose1', s, num(0)).effects.length, 0, 'already in the calendar')
      let s3 = act(c, 'setDoseName1', s, str('Iron')).st
      r = act(c, 'addDose1', s3, num(0)); assert.equal(r.effects.length, 1); assert.equal(r.effects[0].values.get('hour'), '8')
      s3 = act(c, 'onDoseAdded1', r.st, str('declined code=201')).st
      assert.match(text(c, s3), /Iron\|08:00 - not in calendar/); assert.match(text(c, s3), /The calendar said no\|declined code=201/)
      r = act(c, 'removeDose1', s3, num(0))
      assert.equal(r.effects[0].rawTarget, 'CalendarKit.Calendar.deleteEvents'); assert.deepEqual(Object.fromEntries(r.effects[0].values), {ids: '777'})
    }
    {
      const o = doseBuild('false', [['A', '08:00', '']])
      const s = o.vm.execute('init')
      assert.ok(!nodes(o, s).some(n => n.kind === 'iconbutton' && n.icon === 'calendar'))
      let s4 = act(o, 'setDoseName1', s, str('B')).st
      assert.equal(act(o, 'addDose1', s4, num(0)).effects.length, 0)
    }
    assert.deepEqual(specOf('dose_schedule').ports.map(p => p.name), ['taken_today', 'doses', 'streak'])
    buildFromMaps(['dose_schedule', 'dose_schedule'], [
      values('dose_schedule', {__CALENDAR_IDX__: 'true'}, DOSES),
      values('dose_schedule', {__CALENDAR_IDX__: 'false'}, DOSES),
    ])
  } finally {
    global.Date = RealDate
  }
}

function quickLog() {
  const RealDate = Date
  let now = new RealDate(2026, 10, 3, 9, 0, 0)
  global.Date = class extends RealDate { constructor(...a) { if (a.length === 0) { super(now.getTime()) } else { super(...a) } } }
  const at = (h, m, dayShift = 0) => { now = new RealDate(2026, 10, 3 + dayShift, h, m, 0) }
  const water = {__BUTTON_IDX__: 'Add a glass', __AMOUNT_IDX__: '250', __UNIT_IDX__: 'ml', __GOAL_IDX__: '2000', __COUNT_LABEL_IDX__: 'Glasses'}
  const quickBuild = (over = {}, presets = undefined) => build('quick_log', {quick_log: over}, {quick_log: presets})
  try {
    const h = quickBuild(water)
    let st = h.vm.execute('init')
    let t = text(h, st)
    assert.match(t, /0 of 2,?000 ml/); assert.match(t, /0\|Glasses\|today/); assert.match(t, /nothing yet today/)
    assert.ok(nodes(h, st).some(n => n.kind === 'progressring'), 'a ring toward the goal')
    assert.ok(!nodes(h, st).some(n => n.kind === 'emptystate'), 'no empty state: the ring and the count say 0')
    assert.doesNotMatch(t, /Undo/, 'nothing to undo yet')
    const kinds = nodes(h, st).map(n => n.kind + ':' + (n.label || n.text || ''))
    assert.ok(kinds.findIndex(k => k.includes('Add a glass')) < kinds.findIndex(k => k.includes('Amount per tap (ml)')), 'button before settings')
    assert.ok(kinds.findIndex(k => k.includes('Daily goal (ml, 0 for none)')) > 0)
    at(9, 0); st = act(h, 'addTap1', st, num(0)).st
    at(9, 30); st = act(h, 'addTap1', st, num(0)).st
    at(10, 10); st = act(h, 'addTap1', st, num(0)).st
    at(10, 40); t = text(h, st)
    assert.match(t, /750 of 2,?000 ml/); assert.match(t, /3\|Glasses\|today/); assert.match(t, /30 min ago\|Last/)
    assert.match(t, /250 ml\|10:10.*250 ml\|09:30.*250 ml\|09:00/, 'newest first')
    assert.match(t, /Undo/)
    at(12, 0); assert.match(text(h, st), /1 h 50 min ago\|Last/)
    st = act(h, 'undoTap1', st, num(0)).st; t = text(h, st)
    assert.match(t, /500 of 2,?000 ml/); assert.doesNotMatch(t, /10:10/)
    st = act(h, 'removeTap1', st, num(0)).st; t = text(h, st)
    assert.match(t, /250 of 2,?000 ml/); assert.doesNotMatch(t, /09:00/); assert.match(t, /09:30/)
    assert.equal(text(h, act(h, 'removeTap1', st, num(9)).st), t, 'an index outside the list does nothing')
    st = act(h, 'setTapAmount1', st, str('330')).st; st = act(h, 'addTap1', st, num(0)).st
    assert.match(text(h, st), /580 of 2,?000 ml/)
    st = act(h, 'setTapGoal1', st, str('500')).st; assert.ok(nodes(h, st).some(n => n.kind === 'progressring' && n.style === 'success'), 'goal reached')
    st = act(h, 'setTapAmount1', st, str('nonsense')).st; st = act(h, 'addTap1', st, num(0)).st
    assert.match(text(h, st), /581 of 500 ml/, 'an amount that is not a number counts 1')
    at(8, 0, 1); t = text(h, st)
    assert.match(t, /0 of 500 ml/); assert.match(t, /0\|Glasses\|today/); assert.match(t, /Yesterday: 3, 581 ml/); assert.doesNotMatch(t, /Undo/)
    assert.equal(text(h, act(h, 'undoTap1', st, num(0)).st), t, 'undo on a new day before any tap changes nothing')
    {
      at(9, 0)
      const n = quickBuild({__BUTTON_IDX__: 'Log a nappy', __AMOUNT_IDX__: '1', __UNIT_IDX__: '', __GOAL_IDX__: '0', __COUNT_LABEL_IDX__: 'Nappies', __ENTRY_WORD_IDX__: 'Nappy change'})
      let s = n.vm.execute('init'); s = act(n, 'addTap1', s, num(0)).st; s = act(n, 'addTap1', s, num(0)).st
      const tt = text(n, s)
      assert.ok(!nodes(n, s).some(x => x.kind === 'progressring'), 'no goal: no ring')
      assert.match(tt, /2\|Nappies\|today/); assert.match(tt, /Nappy change\|09:00/); assert.doesNotMatch(tt, /Amount per tap/)
    }
    {
      at(9, 0)
      const p = quickBuild(water, [['Small', '150'], ['Large', '500']])
      let s = p.vm.execute('init')
      assert.match(text(p, s), /Add a glass\|.*Small.*Large/)
      s = act(p, 'addPreset1', s, num(1)).st; s = act(p, 'addPreset1', s, num(0)).st; s = act(p, 'addPreset1', s, num(7)).st
      assert.match(text(p, s), /650 of 2,?000 ml/)
    }
    {
      const ports = specOf('quick_log').ports.map(p => p.name)
      assert.deepEqual(ports, ['today_total', 'today_count', 'goal'])
    }
    buildFromMaps(['quick_log', 'quick_log'], [values('quick_log', water), values('quick_log', {})])
  } finally {
    global.Date = RealDate
  }
}

function itinerary() {
  const STOPS = [['The Bund', '90', '31.2397', '121.4900'], ['Yu Garden', '75', '31.2270', '121.4920'], ['Nanjing Road', '60', '310', 'abc']]
  const ON = {'__NAVIGATE_IDX__': 'true', '__CALENDAR_IDX__': 'true', '__START_PLACE_IDX__': 'Pudong Airport', '__START_LAT_IDX__': '31.1443', '__START_LON_IDX__': '121.8083'}

  function valuesFor(kind, over = {}) {
    const spec = specOf(kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, over[s.token] !== undefined ? over[s.token] : s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, over[c.token] !== undefined ? over[c.token] : c.fallback))
    spec.listFields.forEach(l => m.set(l.token, expandListRows(kind === 'itinerary' ? STOPS : undefined, l).text))
    return m
  }
  const buildAll = (kinds, over = {}) => buildFromMaps(kinds, kinds.map(k => valuesFor(k, k === 'itinerary' ? over : {})))
  const strings = (h, st) => {
    const out = []
    walk(decodeVeraUi(h.vm.execute('view', [st]))[0], n => out.push(n.text, n.label, n.value, ...(n.options || [])))
    return out.filter(Boolean)
  }
  const shown = (h, st) => strings(h, st).join('|')

  {
    const spec = specOf('itinerary').listFields[0]
    const out = expandListRows([['A', '90', '31.2397', '121.49'], ['B', '9999', '-95', '181'], ['C', '2', '31', 'x']], spec).text
    assert.match(out, /name: "A", minutes: 90, latitude: "31.2397", longitude: "121.49"/)
    assert.match(out, /name: "B", minutes: 60, latitude: "", longitude: ""/)
    assert.match(out, /name: "C", minutes: 60, latitude: "31", longitude: ""/)
  }

  const h = buildAll(['itinerary', 'progress_line'], ON)
  let st = h.vm.execute('init')
  let s = shown(h, st)
  assert.match(s, /09:00 - 10:30 \| 90 min(?!.*31\.2397)/); assert.match(s, /10:45 - 12:00 \| 75 min/); assert.match(s, /12:15 - 13:15 \| 60 min/)
  assert.match(s, /0 of 3/, 'progress_line reads done and total')
  assert.deepEqual(bindPorts(['itinerary', 'progress_line'])[1].get('__PORT_done__'), 'reachedCount1(state)')

  st = act(h, 'toggleStop1', st, num(0)).st; assert.match(shown(h, st), /1 of 3/)
  st = act(h, 'toggleStop1', st, num(1)).st; assert.match(shown(h, st), /2 of 3/)
  st = act(h, 'toggleStop1', st, num(1)).st; assert.match(shown(h, st), /1 of 3/)

  let r = act(h, 'navigate1', st, num(1))
  assert.equal(r.effects.length, 1); let e = r.effects[0]
  assert.equal(e.rawTarget, 'com.huawei.hmos.maps.app/entry/EntryAbility/StartNavigate'); assert.equal(e.rawMode, 'foreground'); assert.equal(e.resultHandler, 'onNavigated1')
  assert.deepEqual(Object.fromEntries(e.values), {'dstLocation.locationName': 'Yu Garden', 'dstLocation.latitude': '31.2270', 'dstLocation.longitude': '121.4920',
  'srcLocation.locationName': 'The Bund', 'srcLocation.latitude': '31.2397', 'srcLocation.longitude': '121.4900', trafficType: 'Drive'})
  r = act(h, 'navigate1', h.vm.execute('init'), num(0)); e = r.effects[0]
  assert.equal(e.values.get('srcLocation.locationName'), 'Pudong Airport'); assert.equal(e.values.get('srcLocation.latitude'), '31.1443')
  r = act(h, 'navigate1', h.vm.execute('init'), num(2)); e = r.effects[0]
  assert.equal(e.values.get('dstLocation.locationName'), 'Nanjing Road'); assert.equal(e.values.has('dstLocation.latitude'), false, 'no coordinates, name only')
  assert.equal(act(h, 'navigate1', st, num(9)).effects.length, 0, 'an index outside the list does nothing')
  assert.doesNotMatch(shown(h, act(h, 'onNavigated1', st, str('0')).st), /Last action/)
  assert.match(shown(h, act(h, 'onNavigated1', st, str('declined code=3')).st), /declined code=3/)

  let fresh = h.vm.execute('init')
  r = act(h, 'addEvent1', fresh, num(1)); e = r.effects[0]
  assert.equal(e.rawTarget, 'CalendarKit.Calendar.addEvent'); assert.equal(e.resultHandler, 'onAdded1')
  assert.deepEqual(Object.fromEntries(e.values), {title: 'Yu Garden', hour: '10', minute: '45', durationMinutes: '75', location: 'Yu Garden, 31.2270, 121.4920', remindBefore: '15', repeat: 'once'})
  let added = act(h, 'onAdded1', r.st, str('12')).st
  assert.equal((shown(h, added).match(/In calendar/g) || []).length, 1); assert.equal((shown(h, added).match(/Add to calendar/g) || []).length, 2)
  assert.match(shown(h, act(h, 'onAdded1', r.st, str('error 201: no permission')).st), /error 201: no permission/)
  assert.doesNotMatch(shown(h, act(h, 'onAdded1', r.st, str('error 201')).st), /In calendar/, 'a failure stores no id')
  assert.equal(act(h, 'addEvent1', fresh, num(-1)).effects.length, 0)

  r = act(h, 'wipeEvents1', fresh, num(0)); assert.equal(r.effects.length, 0); assert.match(text(h, r.st), /No events added by this app/)
  let two = act(h, 'onAdded1', act(h, 'addEvent1', added, num(2)).st, str('15')).st
  r = act(h, 'wipeEvents1', two, num(0)); e = r.effects[0]
  assert.equal(e.rawTarget, 'CalendarKit.Calendar.deleteEvents'); assert.equal(e.values.get('ids'), '12,15'); assert.equal(e.resultHandler, 'onWiped1')
  assert.equal((shown(h, act(h, 'onWiped1', two, str('ok')).st).match(/Add to calendar/g) || []).length, 3, 'ids cleared')
  assert.equal((shown(h, act(h, 'onWiped1', two, str('error 5: x')).st).match(/In calendar/g) || []).length, 2, 'ids kept on failure')

  r = act(h, 'openCalendar1', st, num(0)); e = r.effects[0]
  assert.equal(e.rawTarget, 'com.huawei.hmos.calendar/phone/MainAbility'); assert.equal(e.rawParams, '')

  {
    const off = buildAll(['itinerary'], {})
    const s0 = shown(off, off.vm.execute('init'))
    assert.doesNotMatch(s0, /Navigate|Add to calendar|Open calendar/); assert.match(s0, /The Bund/)
 }
 {
    const odd = buildAll(['itinerary'], Object.assign({}, ON, {'__START_TIME_IDX__': '99999', '__START_LAT_IDX__': '500'}))
    let o = odd.vm.execute('init'); assert.match(text(odd, o), /09:00 - 10:30/)
    const ev = act(odd, 'navigate1', o, num(0)).effects[0]
    assert.equal(ev.values.has('srcLocation.latitude'), false); assert.equal(ev.values.get('srcLocation.locationName'), 'Pudong Airport')
 }
 {
    const both = buildAll(['checklist', 'progress_line'])
    const b = both.vm.execute('init')
    assert.match(shown(both, b), /0 of 3/)
    assert.match(shown(both, act(both, 'toggle1', b, num(0)).st), /1 of 3/)
 }
 {
    const day = buildAll(['itinerary'], ON)
    const out = shown(day, day.vm.execute('init'))
    assert.match(out, /13:15\|Day ends\|after the last stop/)
    assert.match(out, /4 h 15 min\|Day length\|3 stops/)
    assert.match(out, /Day starts/)
 }
 {
    const form = new FragmentSpec('form', '', '', [new StateFieldSpec('dayAt', 'number')], '', 'dayAt: 600', '',
      '{ sections.push(ui.Section("content", "", "", [ui.TimeField("default", "Start time", state.dayAt, "setDay")])); }', [], [])
    form.functions = 'function setDay(state: AppState, v: number): AppState {\n  return {dayAt: v__PASSTHROUGH__};\n}'
    form.indexed = false
    form.ports = [new PortSpec('writes', 'start', 'number', 'dayAt')]
    const src = composeFragments([form, specOf('itinerary')], globals, [new Map(), valuesFor('itinerary', ON)])
    const compiled = compileVeraSource(src)
    const env = new UiHostEnvironment()
    const fh = {env, vm: new VirtualMachine(deserializeVbc2(compiled.vbc2 !== undefined ? compiled.vbc2 : compiled), env)}
    let fst = fh.vm.execute('init')
    let out = shown(fh, fst)
    assert.match(out, /10:00 - 11:30/)
    assert.match(out, /14:15\|Day ends/)
    assert.doesNotMatch(out, /Day starts/)
    fst = fh.vm.execute('setDay', [fst, num(480)])
    assert.match(shown(fh, fst), /08:00 - 09:30/)
    const ev = act(fh, 'addEvent2', fst, num(0)).effects[0]
    assert.ok([...ev.values.values()].some(v => String(v) === '8'), 'the event starts at 8 o\'clock')
 }
 {
    const dh = buildAll(['itinerary'])
    let dst = dh.vm.execute('init')
    const fields = []
    walk(decodeVeraUi(dh.vm.execute('view', [dst]))[0], n => { if (n.kind === 'numberfield') fields.push(n) })
    assert.equal(fields.length, 1); assert.equal(fields[0].step, 5, 'the gap steps by 5 minutes')
    assert.doesNotMatch(shown(dh, dst), /\+1 day/)
    dst = act(dh, 'setGap1', dst, num(180)).st
    assert.doesNotMatch(shown(dh, dst), /\+1 day/)
    dst = act(dh, 'setStart1', dst, num(1260)).st
    const t = text(dh, dst)
    assert.match(t, /21:00 - 22:30 \| 90 min/); assert.match(t, /01:30 - 02:45 \+1 day \| 75 min/)
    assert.match(t, /05:45 - 06:45 \+1 day \| 60 min/); assert.match(t, /the next day/)
  }
  {
    const withStops = (nav) => {
      const spec = specOf('itinerary'), m = new Map()
      spec.slots.forEach(x => m.set(x.token, x.token === '__NAVIGATE_IDX__' ? nav : x.values[0]))
      spec.contentFields.forEach(x => m.set(x.token, x.fallback))
      spec.listFields.forEach(l => m.set(l.token, expandListRows([['The Bund', '90', '31.2397', '121.4900'], ['Lunch', '60', '', ''],
        ['Yu Garden', '75', '', ''], ['Lunch at Nanxiang', '45', '31.2272', '121.4921']], l).text))
      const wh = buildFromMaps('itinerary', [m])
      const root = decodeVeraUi(wh.vm.execute('view', [wh.vm.execute('init')]))[0]
      const buttons = [], subtitles = []
      walk(root, n => { if (n.kind === 'iconbutton') buttons.push(n.icon + ':' + n.eventValue); if (n.kind === 'section') subtitles.push(n.label) })
      return {buttons, subtitles}
    }
    const on = withStops('true')
    assert.deepEqual(on.buttons, ['navigate:0', 'navigate:3'])
    assert.ok(on.subtitles.indexOf('Tap a stop when you reach it') >= 0, on.subtitles.join(' | '))
    const off = withStops('false')
    assert.deepEqual(off.buttons, ['check:0', 'check:1', 'check:2', 'check:3'])
    assert.ok(off.subtitles.indexOf('Tap a stop when you reach it') < 0)
  }
  {
    const src = 'import * as ui from "std/ui"\n@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 3}; }\n' +
      'function setN(state: AppState, value: number): AppState { return {n: value}; }\n' +
      'function view(state: AppState): ui.View { return ui.NumberField("default", "N", state.n, 0, 10, "setN"); }\n'
    const compiled = compileVeraSource(src)
    const vm = new VirtualMachine(deserializeVbc2(compiled.vbc2 !== undefined ? compiled.vbc2 : compiled), new UiHostEnvironment())
    assert.equal(decodeVeraUi(vm.execute('view', [vm.execute('init')]))[0].step, 1)
  }
}

function reminders() {
  const CAL = '__CALENDAR_IDX__'

  function valuesFor(kind, over = {}) {
    const spec = specOf(kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, over[s.token] !== undefined ? over[s.token] : s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, over[c.token] !== undefined ? over[c.token] : c.fallback))
    spec.listFields.forEach(l => m.set(l.token, ''))
    return m
  }
  const buildAll = (kinds, over = {}) => buildFromMaps(kinds, kinds.map(k => valuesFor(k, k == 'reminders' ? over : {})))
  const shown = (h, st) => texts(h, st).join('|')
  const fill = (h, st, title, hour, minute, daily) => {
    st = act(h, 'setTitle1', st, str(title)).st; st = act(h, 'setHour1', st, num(hour)).st
    st = act(h, 'setMinute1', st, num(minute)).st; return act(h, 'setDaily1', st, bool(daily)).st
  }

  const h = buildAll(['reminders'], {[CAL]: 'true', __EVENT_PREFIX_IDX__: 'Take ', __EVENT_NOTE_IDX__: 'Reminder from the app'})
  let st = h.vm.execute('init')
  assert.match(shown(h, st), /Nothing yet/); assert.equal(nodes(h, st).filter(n => n.kind === 'listitem').length, 0)
  let r = act(h, 'addReminder1', st, num(0)); assert.equal(r.effects.length, 0); assert.match(shown(h, r.st), /Nothing yet/, 'an empty title adds nothing')
  r = act(h, 'addReminder1', fill(h, st, '   ', 8, 0, true), num(0)); assert.equal(r.effects.length, 0, 'a blank title adds nothing')
  st = act(h, 'setHour1', st, num(25)).st; st = act(h, 'setHour1', st, num(23.9)).st
  assert.equal(act(h, 'addReminder1', fill(h, st, 'X', 25, 70, true), num(0)).effects[0].values.get('hour'), '23')
  assert.equal(act(h, 'addReminder1', fill(h, st, 'X', -3, 70, true), num(0)).effects[0].values.get('hour'), '0')
  assert.equal(act(h, 'addReminder1', fill(h, st, 'X', 9, 70, true), num(0)).effects[0].values.get('minute'), '59')
  assert.equal(act(h, 'addReminder1', fill(h, st, 'X', 9, -1, true), num(0)).effects[0].values.get('minute'), '0')

  {
    const fresh = h.vm.execute('init')
    assert.ok(nodes(h, fresh).some(n => n.kind === 'timefield'), 'the form has a time picker')
    assert.doesNotMatch(shown(h, fresh), /Hour \(0-23\)|Minute \(0-59\)/)
    let t = act(h, 'setTitle1', fresh, str('Vitamin')).st
    t = act(h, 'setTime1', t, num(21 * 60 + 15)).st
    const ev = act(h, 'addReminder1', t, num(0)).effects[0]
    assert.equal(ev.values.get('hour'), '21'); assert.equal(ev.values.get('minute'), '15')
  }

  st = fill(h, h.vm.execute('init'), 'Aspirin', 8, 30, true)
  r = act(h, 'addReminder1', st, num(0)); assert.equal(r.effects.length, 1)
  let e = r.effects[0]
  assert.equal(e.rawTarget, 'CalendarKit.Calendar.addEvent'); assert.equal(e.resultHandler, 'onAdded1')
  assert.deepEqual(Object.fromEntries(e.values), {title: 'Take Aspirin', hour: '8', minute: '30', durationMinutes: '15', remindBefore: '0', repeat: 'daily',
    description: 'Reminder from the app'})
  st = r.st; assert.match(shown(h, st), /Aspirin\|08:30 - every day\|sending\.\.\./, 'the row is pending until the calendar answers')
  assert.doesNotMatch(shown(h, st), /Nothing yet/)
  assert.equal(act(h, 'addReminder1', st, num(0)).effects.length, 0, 'the cleared title adds nothing again')
  st = act(h, 'onAdded1', st, str('4242')).st
  assert.match(shown(h, st), /Aspirin\|08:30 - every day\|in calendar/)
  st = fill(h, st, 'Dentist', 14, 5, false)
  r = act(h, 'addReminder1', st, num(0)); assert.equal(r.effects[0].values.get('repeat'), 'once'); assert.equal(r.effects[0].values.get('hour'), '14')
  st = act(h, 'onAdded1', r.st, str('declined code=201')).st
  assert.match(shown(h, st), /Dentist\|14:05\|not added/); assert.match(shown(h, st), /The calendar said no\|declined code=201/)
  {
    let s2 = act(h, 'addReminder1', fill(h, h.vm.execute('init'), 'A', 7, 0, false), num(0)).st
    s2 = act(h, 'onAdded1', s2, str('{"id":"9"}')).st; assert.match(shown(h, s2), /in calendar/)
    let s3 = act(h, 'addReminder1', fill(h, h.vm.execute('init'), 'A', 7, 0, false), num(0)).st
    s3 = act(h, 'onAdded1', s3, str('error 3: no calendar')).st; assert.match(shown(h, s3), /not added/)
  }
  assert.equal(shown(h, act(h, 'onAdded1', h.vm.execute('init'), str('7')).st), shown(h, h.vm.execute('init')))

  {
    const g = buildAll(['reminders', 'progress_line'], {[CAL]: 'true'})
    assert.deepEqual([bindPorts(['reminders', 'progress_line'])[1].get('__PORT_done__'), bindPorts(['reminders', 'progress_line'])[1].get('__PORT_total__')],
      ['scheduledCount1(state)', 'state.reminders1.length()'])
    let s = fill(g, g.vm.execute('init'), 'A', 7, 0, true); s = act(g, 'addReminder1', s, num(0)).st; s = act(g, 'onAdded1', s, str('1')).st
    s = fill(g, s, 'B', 9, 0, true); s = act(g, 'addReminder1', s, num(0)).st
    assert.match(shown(g, s), /1 of 2/, 'one scheduled of two')
 }

  const rm = act(h, 'removeReminder1', st, num(0))
  assert.equal(rm.effects.length, 1); assert.equal(rm.effects[0].rawTarget, 'CalendarKit.Calendar.deleteEvents'); assert.deepEqual(Object.fromEntries(rm.effects[0].values), {ids: '4242'})
  assert.doesNotMatch(shown(h, rm.st), /Aspirin/); assert.match(shown(h, rm.st), /Dentist/)
  assert.equal(act(h, 'removeReminder1', st, num(1)).effects.length, 0, 'a refused entry has no event to remove')
  assert.equal(act(h, 'removeReminder1', st, num(9)).effects.length, 0, 'an index outside the list does nothing')
  {
    let s = fill(h, h.vm.execute('init'), 'A', 7, 0, true); s = act(h, 'addReminder1', s, num(0)).st
    s = fill(h, s, 'B', 8, 0, true); s = act(h, 'addReminder1', s, num(0)).st
    s = act(h, 'removeReminder1', s, num(0)).st; s = act(h, 'onAdded1', s, str('55')).st
    assert.match(shown(h, s), /B\|08:00 - every day\|in calendar/); assert.doesNotMatch(shown(h, s), /\bA\|/)
  }
  assert.match(shown(h, act(h, 'onRemoved1', rm.st, str('error 9: nope')).st), /Last action\|error 9: nope/)
  assert.doesNotMatch(shown(h, act(h, 'onRemoved1', rm.st, str('ok')).st), /Last action/)
  r = act(h, 'openCalendar1', st, num(0)); assert.equal(r.effects[0].rawTarget, 'com.huawei.hmos.calendar/phone/MainAbility'); assert.equal(r.effects[0].resultHandler, 'onOpened1')

  {
    const l = buildAll(['reminders'], {[CAL]: 'false'})
    let s = fill(l, l.vm.execute('init'), 'Water', 10, 0, true); r = act(l, 'addReminder1', s, num(0))
    assert.equal(r.effects.length, 0); assert.match(shown(l, r.st), /Water\|10:00 - every day/); assert.doesNotMatch(shown(l, r.st), /sending|in calendar|Open calendar/)
    assert.equal(act(l, 'removeReminder1', r.st, num(0)).effects.length, 0)
  }

  compileVeraSource(composeProgram(['reminders', 'reminders'], globals, [valuesFor('reminders'), valuesFor('reminders')]))

 {
    const body = (slot, vetoes) => {
      const answers = {section1: {choice: 'reminders', confidence: 0.9}, 'section1.reminders.calendar': {noul: slot}}
      for (const k of ['needs_integration', 'needs_real_data', 'needs_search_or_form', 'needs_live_ticking', 'needs_multiple_counters', 'needs_multiple_series', 'needs_logic'])
        answers['veto.' + k] = {noul: vetoes[k] || 0}
      return JSON.stringify({answers})
    }
    let o = readSectionPick(body(0.9, {needs_integration: 0.8, needs_search_or_form: 0.95}))
    assert.equal(o.sections[0].slotValues.get(CAL), 'true'); assert.equal(o.needsLogic, false, 'calendar on: both vetoes are covered')
    o = readSectionPick(body(0.1, {needs_integration: 0.8, needs_search_or_form: 0.95}))
    assert.equal(o.sections[0].slotValues.get(CAL), 'false'); assert.equal(o.needsLogic, true, 'calendar off: an integration is still the model\'s'); assert.doesNotMatch(o.note, /needs_search_or_form/)
  }
}

function ledger() {
  const ALL = ['record_log', 'number_strip', 'breakdown_table', 'series_chart', 'settle_up']
  const names = ['Anna', 'Ben', 'Carol', 'Dan']

  function valuesFor(kind, over = {}) {
    const spec = specOf(kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, c.token === '__CURRENCY_IDX__' ? '$' : c.fallback))
    spec.listFields.forEach(l => m.set(l.token, kind === 'record_log' && over.labels !== undefined
      ? over.labels.map(n => '"' + n + '"').join(', ') : expandListRows(undefined, l).text))
    return m
  }
  const buildAll = (kinds, over = {}) => buildFromMaps(kinds, kinds.map(k => valuesFor(k, over)))
  const view = (h, st) => decodeVeraUi(h.vm.execute('view', [st]))[0]
  const strings = (h, st) => {
    const out = []
    walk(view(h, st), n => { out.push(n.text, n.label, n.value, ...(n.options || [])) })
    return out.filter(Boolean)
  }
  const nums = (h, st) => { const out = []; walk(view(h, st), n => { if (n.kind === 'numberstat') out.push(n.numberValue) }); return out }
  const series = (h, st) => { let s = null; walk(view(h, st), n => { if (n.kind === 'sparkline') s = n }); return s }

  {
    const h = buildAll(ALL, {labels: names})
    let st = h.vm.execute('init')
    assert.deepEqual(nums(h, st), [0, 0]); assert.match(strings(h, st).join('|'), /All settled up/)
    const add = (who, amount, note = '') => {
      st = h.vm.execute('setWho1', [st, num(who)]); st = h.vm.execute('setAmount1', [st, str(amount)])
      st = h.vm.execute('setNote1', [st, str(note)]); st = h.vm.execute('addRecord1', [st, num(0)])
    }
    add(0, '120', 'dinner'); add(2, '60', 'taxi')
    assert.deepEqual(nums(h, st), [180, 45], 'total and average')
    assert.deepEqual(Array.from(series(h, st).series), [120, 0, 60, 0]); assert.deepEqual(Array.from(series(h, st).categories), names)
    const s = strings(h, st).join('|')
    assert.match(s, /Ben pays Anna/); assert.match(s, /Dan pays Anna/); assert.match(s, /Dan pays Carol/)
    assert.doesNotMatch(s, /Anna pays|Carol pays|Ben pays Carol/)
    assert.match(s, /\+\$75\.00/); assert.match(s, /-\$45\.00/); assert.match(s, /\+\$15\.00/)
    assert.match(s, /\$45\.00/); assert.match(s, /dinner/); assert.match(s, /taxi/)
    let paid = 0; walk(view(h, st), n => { if (/ pays /.test(n.text || '')) paid += parseFloat(n.value.replace('$', '')) })
    assert.equal(paid, 90, 'creditors are owed 75 + 15')
    add(1, '10.10'); add(1, '5.05')
    assert.deepEqual(nums(h, st), [195.15, 48.79]); assert.equal(Array.from(series(h, st).series)[1], 15.15)
    const before = JSON.stringify([nums(h, st), Array.from(series(h, st).series)])
    add(1, ''); add(1, '0'); add(1, 'abc')
    assert.equal(JSON.stringify([nums(h, st), Array.from(series(h, st).series)]), before, 'blank, zero and text amounts are ignored')
    st = h.vm.execute('removeLastRecord1', [st, num(0)])
    assert.deepEqual(nums(h, st), [190.1, 47.53])
    st = h.vm.execute('clearRecords1', [st, num(0)])
    assert.deepEqual(nums(h, st), [0, 0]); assert.match(strings(h, st).join('|'), /All settled up/)
    st = h.vm.execute('clearRecords1', [st, num(0)])   // clearing nothing is fine
  }

  {
    const vals = ALL.map(k => valuesFor(k, {labels: names}))
    vals[1].set('__SHOW_COUNT_IDX__', 'true'); vals[3].set('__USE_BALANCES_IDX__', 'true')
    const h = buildFromMaps(ALL, vals)
    let st = h.vm.execute('init')
    st = h.vm.execute('setAmount1', [st, str('100')]); st = h.vm.execute('addRecord1', [st, num(0)])
    assert.deepEqual(nums(h, st), [100, 25, 1], 'count shown')
    assert.deepEqual(Array.from(series(h, st).series), [75, -25, -25, -25], 'balances, negative bars included')
  }

  {
    const vals = ALL.map(k => valuesFor(k, {labels: names}))
    vals[3].set('__USE_BALANCES_IDX__', 'true')
    const h = buildFromMaps(ALL, vals)
    let st = h.vm.execute('init')
    st = h.vm.execute('setAmount1', [st, str('120.50')]); st = h.vm.execute('addRecord1', [st, num(0)])
    const bals = Array.from(series(h, st).series)
    assert.deepEqual(bals, [90.37, -30.13, -30.12, -30.12]); assert.equal(Math.round(bals.reduce((a, b) => a + b, 0) * 100), 0, 'sum is zero')
    let paid = 0; walk(view(h, st), n => { if (/ pays /.test(n.text || '')) paid += Math.round(parseFloat(n.value.replace('$', '')) * 100) })
    assert.equal(paid, 9037, 'the transfers settle exactly')
  }

  {
    const h = buildAll(ALL, {labels: []})
    const st = h.vm.execute('init'); assert.deepEqual(nums(h, st), [0, 0]); view(h, st)
    for (const k of ALL.slice(1)) { const alone = buildAll([k]); view(alone, alone.vm.execute('init')) }
  }

  {
    const h = buildAll(['record_log', 'breakdown_table'], {labels: ['Red', 'Blue']})
    let st = h.vm.execute('init')
    st = h.vm.execute('setWho1', [st, num(1)]); st = h.vm.execute('setAmount1', [st, str('7')]); st = h.vm.execute('addRecord1', [st, num(0)])
    const s = strings(h, st).join('|')
    assert.match(s, /Blue/); assert.match(s, /\$7\.00/)
  }
  {
    const {readLogInCharts} = require('./source-loader').loadVera('VeraCompose')
    const comp = {blocks: ['bar_chart', 'record_log'], readyKinds: ['bar_chart'], dropped: []}
    readLogInCharts(comp)
    assert.deepEqual(comp.blocks, ['series_chart', 'record_log'])
    assert.deepEqual(comp.readyKinds, ['series_chart'])
    const table = {blocks: ['data_table', 'bar_chart', 'record_log'], readyKinds: ['data_table', 'bar_chart'], dropped: []}
    readLogInCharts(table)
    assert.deepEqual(table.blocks, ['breakdown_table', 'series_chart', 'record_log'])
    const alone = {blocks: ['bar_chart'], readyKinds: ['bar_chart'], dropped: []}
    readLogInCharts(alone)
    assert.deepEqual(alone.blocks, ['bar_chart'], 'with no log on the screen the chart draws what is written for it')
  }
  {
    const h = buildAll(['record_log', 'series_chart'])
    let st = h.vm.execute('init')
    const kinds = []; walk(view(h, st), n => kinds.push(n.kind))
    assert.ok(!kinds.includes('sparkline'), 'no chart of zeros')
    assert.match(strings(h, st).join('|'), /the bars appear once something is added/)
    st = h.vm.execute('setAmount1', [st, str('7')]); st = h.vm.execute('addRecord1', [st, num(0)])
    const after = []; walk(view(h, st), n => after.push(n.kind))
    assert.ok(after.includes('sparkline'), 'the chart once there is a record')
  }
}

function pointsLedger() {
  function valuesFor(kind, people) {
    const spec = specOf(kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, c.token === '__UNIT_IDX__' ? 'stars' : c.fallback))
    spec.listFields.forEach(l => m.set(l.token, l.token === '__PEOPLE_IDX__' && people !== undefined
      ? people.map(n => '"' + n + '"').join(', ') : expandListRows(undefined, l).text))
    return m
  }
  const buildAll = (kinds, people) => buildFromMaps(kinds, kinds.map(k => valuesFor(k, people)))
  const balances = (h, st) => nodes(h, st).filter(n => n.kind === 'numberstat').map(n => [n.label, n.numberValue])
  const item = (h, st, title) => nodes(h, st).find(n => n.kind === 'listitem' && n.text === title)
  const shown = (h, st) => texts(h, st).join('|')
  const button = (h, st, label) => nodes(h, st).find(n => n.kind === 'button' && n.text === label)

  {
    const h = buildAll(['points_ledger'], ['Mia', 'Leo'])
    let st = h.vm.execute('init')
    assert.deepEqual(balances(h, st), [['Mia', 0], ['Leo', 0]])
    assert.match(shown(h, st), /No points yet/)
    assert.equal(button(h, st, 'Undo last').enabled, false)
    assert.equal(item(h, st, 'Make the bed').value, '+1')
    assert.equal(item(h, st, 'Extra story').enabled, false)
    assert.equal(item(h, st, 'Extra story').label, 'needs 5 more')
    st = h.vm.execute('award1', [st, num(2)]); st = h.vm.execute('award1', [st, num(2)])
    assert.deepEqual(balances(h, st), [['Mia', 6], ['Leo', 0]])
    assert.equal(item(h, st, 'Extra story').enabled, true)
    assert.equal(item(h, st, 'Ice cream').label, 'needs 4 more')
    st = h.vm.execute('redeem1', [st, num(0)])
    assert.deepEqual(balances(h, st), [['Mia', 1], ['Leo', 0]])
    const before = JSON.stringify(balances(h, st))
    st = h.vm.execute('redeem1', [st, num(2)])
    assert.equal(JSON.stringify(balances(h, st)), before)
    const history = nodes(h, st).filter(n => n.kind === 'listitem' && / · /.test(n.text)).map(n => [n.text, n.value])
    assert.deepEqual(history, [['Mia · Extra story', '-5'], ['Mia · Homework done', '+3'], ['Mia · Homework done', '+3']])
    st = h.vm.execute('setWho1', [st, num(1)])
    st = h.vm.execute('award1', [st, num(1)])
    assert.deepEqual(balances(h, st), [['Mia', 1], ['Leo', 2]])
    assert.equal(item(h, st, 'Extra story').label, 'needs 3 more')
    st = h.vm.execute('undoLast1', [st, num(0)])
    assert.deepEqual(balances(h, st), [['Mia', 1], ['Leo', 0]])
    st = h.vm.execute('setName1', [st, str('Walk the dog')]); st = h.vm.execute('setPoints1', [st, num(4)]); st = h.vm.execute('addTask1', [st, num(0)])
    assert.equal(item(h, st, 'Walk the dog').value, '+4')
    st = h.vm.execute('setName1', [st, str('Late bedtime')]); st = h.vm.execute('setPoints1', [st, num(8)]); st = h.vm.execute('addReward1', [st, num(0)])
    assert.equal(item(h, st, 'Late bedtime').label, 'needs 8 more')
    const n = nodes(h, st).filter(x => x.kind === 'listitem').length
    st = h.vm.execute('addTask1', [st, num(0)])
    assert.equal(nodes(h, st).filter(x => x.kind === 'listitem').length, n)
    assert.deepEqual(h.vm.execute('points1', [st]).elements.map(v => v.value), [1, 0])
    assert.equal(h.vm.execute('pointsTotal1', [st]).value, 1)
  }

  {
    const h = buildAll(['points_ledger'], ['Sam'])
    let st = h.vm.execute('init')
    assert.equal(nodes(h, st).some(n => n.kind === 'select'), false)
    st = h.vm.execute('award1', [st, num(0)])
    assert.ok(item(h, st, 'Make the bed'))
    assert.deepEqual(balances(h, st), [['Sam', 1]])
  }

  {
    const spec = specOf('points_ledger')
    assert.deepEqual(spec.ports.map(p => p.name), ['labels', 'totals', 'total', 'count'])
    assert.ok(spec.owns.length > 0)
    const h = buildAll(['points_ledger', 'series_chart'], ['Mia', 'Leo'])
    let st = h.vm.execute('init')
    st = h.vm.execute('award1', [st, num(2)])
    st = h.vm.execute('setWho1', [st, num(1)]); st = h.vm.execute('award1', [st, num(0)])
    let chart = null
    walk(decodeVeraUi(h.vm.execute('view', [st]))[0], n => { if (n.kind === 'sparkline') chart = n })
    assert.ok(chart, 'series_chart draws the points')
    assert.deepEqual(Array.from(chart.series), [3, 1])
    assert.deepEqual(Array.from(chart.categories), ['Mia', 'Leo'])
  }
}

function trendChart() {
  const spec = specOf('trend_chart')
  const points = spec.listFields.find(l => l.key === 'points')
  function chart(raw) {
    const m = values('trend_chart')
    m.set(points.token, expandListRows(raw, points).text)
    const h = buildFromMaps('trend_chart', [m])
    return nodes(h, h.vm.execute('init'))
  }
  const spark = ns => ns.find(n => n.kind === 'sparkline')

  let s = spark(chart([['1896', '167'], ['1996', '176.5']]))
  assert.ok(s, 'a sparkline is drawn')
  assert.deepEqual(s.series, [167, 176.5], 'the fraction is kept, and only the two points given are drawn')
  assert.deepEqual(s.categories, ['1896', '1996'])
  assert.ok(s.maximum > 176.5 && s.minimum < 167 && s.minimum > 150, 'room above and below the data: ' + s.minimum + '..' + s.maximum)
  s = spark(chart([['1950', 102700000], ['1980', '139,000,000'], ['2000', '146.6 million'], ['2020', 144104100]]))
  assert.deepEqual(s.series, [102700000, 139000000, 146.6, 144104100], 'big numbers are not cut to six digits; a comma is dropped; a unit is ignored')
  s = spark(chart([['a', '-3'], ['b', '4'], ['c', 'x']]))
  assert.deepEqual(s.series, [-3, 4, 0], 'a negative number is kept, no number at all is 0')
  assert.equal(s.minimum < -3, true)
  s = spark(chart(Array.from({length: 20}, (_, i) => ['p' + i, String(i)])))
  assert.equal(s.series.length, 12, 'cut to 12 points')
  s = spark(chart(undefined))
  assert.deepEqual(s.series, [1, 2], 'no usable list: the default two points, drawn')
  assert.match(expandListRows(undefined, points).note, /default\(missing\)/, 'and the note says it was defaulted')
  assert.doesNotMatch(JSON.stringify(chart([['a', '1'], ['b', '2']])), /Demo banner|canned template/)
}

async function timer() {
  const {markedHole} = require('./source-loader').loadVera('VeraSectionCompose')
  const {holesOf, holeValues, fillHoles, buildHolePrompt} = require('./source-loader').loadVera('VeraHoles')
  const EGGS = [['Soft', '360'], ['Medium', '420'], ['Hard', '600']]
  const FINISH = '__FINISH_ACTION_IDX__'
  const VIBRATE = '  sdk.call("SensorServiceKit.vibrator.vibrate", ["duration", "1500"], "onFinishedAnswerIDX");\n  return 0;'

  function valuesFor(over = {}, rows) {
    const spec = specOf('timer'), m = new Map()
    spec.slots.forEach(s => m.set(s.token, over[s.token] !== undefined ? over[s.token] : s.values[0]))
    spec.contentFields.forEach(c => m.set(c.token, c.fallback))
    spec.listFields.forEach(l => m.set(l.token, expandListRows(rows, l).text))
    return m
  }
  function buildTimer(over = {}, rows, body) {
    const v = valuesFor(over, rows)
    if (body !== undefined) v.set('__HOLE_WHENFINISHED_IDX__', markedHole('whenFinished', '1', body))
    const src = composeProgram(['timer'], globals, [v])
    const compiled = compileVeraSource(src)
    const env = new UiHostEnvironment()
    return {src, env, vm: new VirtualMachine(deserializeVbc2(compiled.vbc2 !== undefined ? compiled.vbc2 : compiled), env)}
  }
  const timerTexts = (h, st) => nodes(h, st).flatMap(n => Object.values(n).filter(v => typeof v === 'string' && v !== '').concat(n.options || []))
  const left = (h, st) => nodes(h, st).find(n => n.kind === 'numbertext').numberValue

  {
    const spec = specOf('timer').listFields[0]
    const out = expandListRows([['A', '360'], ['B', '9'], ['C', '99999'], ['D', 'abc']], spec).text
    assert.match(out, /name: "A", seconds: 360/); assert.match(out, /name: "B", seconds: 9/)
    assert.match(out, /name: "C", seconds: 60/); assert.match(out, /name: "D", seconds: 60/)
  }

  {
    const h = buildTimer()
    let st = h.vm.execute('init')
    assert.equal(left(h, st), 1500, 'one preset of 1500 seconds')
    assert.equal(nodes(h, st).filter(n => n.kind === 'select').length, 0, 'one preset: no chooser')
  }

  const h = buildTimer({[FINISH]: 'false'}, EGGS)
  let st = h.vm.execute('init')
  assert.deepEqual(nodes(h, st).find(n => n.kind === 'select').options, ['Soft', 'Medium', 'Hard'])
  assert.equal(left(h, st), 360, 'the first preset: 360 s')
  st = act(h, 'choosePreset1', st, num(2)).st; assert.equal(left(h, st), 600, 'Hard: 600 s')
  st = act(h, 'toggleRunning1', st, bool(true)).st
  st = act(h, 'onTick1', st, num(1000)).st; assert.equal(left(h, st), 599, 'one tick of 1000 ms')
  st = act(h, 'onTick1', st, num(100000)).st; assert.equal(left(h, st), 499, 'a long tick')
  st = act(h, 'choosePreset1', st, num(1)).st; assert.equal(left(h, st), 420, 'choosing resets to the full time')
  let paused = act(h, 'onTick1', act(h, 'choosePreset1', st, num(1)).st, num(5000)).st
  assert.equal(left(h, paused), 420, 'paused: the clock does not move')

  st = act(h, 'toggleRunning1', act(h, 'choosePreset1', st, num(0)).st, bool(true)).st
  let r = act(h, 'onTick1', st, num(359000)); assert.equal(r.effects.length, 0); assert.equal(left(h, r.st), 1)
  r = act(h, 'onTick1', r.st, num(5000))
  assert.equal(r.effects.length, 0, 'default hole: no phone call'); assert.equal(left(h, r.st), 0, 'zero left')
  assert.ok(timerTexts(h, r.st).includes('Time is up'), 'the banner')
  assert.equal(act(h, 'onTick1', r.st, num(5000)).effects.length, 0, 'a stopped clock ignores ticks')
  const again = act(h, 'toggleRunning1', r.st, bool(true)).st
  assert.equal(left(h, again), 360, 'restart from the full time')

  const f = buildTimer({[FINISH]: 'true'}, EGGS, VIBRATE)
  let fs = act(f, 'toggleRunning1', f.vm.execute('init'), bool(true)).st
  r = act(f, 'onTick1', fs, num(359000)); assert.equal(r.effects.length, 0, 'not yet')
  assert.equal(act(f, 'onTick1', fs, num(360000)).effects.length, 1, 'a tick that lands exactly on the limit finishes it')
  r = act(f, 'onTick1', r.st, num(2000)); assert.equal(r.effects.length, 1, 'the phone is asked once')
  const e = r.effects[0]
  assert.equal(e.rawTarget, 'SensorServiceKit.vibrator.vibrate'); assert.equal(e.resultHandler, 'onFinishedAnswer1')
  assert.deepEqual(Object.fromEntries(e.values), {duration: '1500'})
  assert.equal(act(f, 'onTick1', r.st, num(1000)).effects.length, 0, 'once: the clock has stopped')
  const okNote = act(f, 'onFinishedAnswer1', r.st, str('ok')).st; assert.ok(!timerTexts(f, okNote).includes('The phone said no'))
  const json = act(f, 'onFinishedAnswer1', r.st, str('{"done":true}')).st; assert.ok(!timerTexts(f, json).includes('The phone said no'))
  const declined = act(f, 'onFinishedAnswer1', r.st, str('declined code=201')).st
  assert.ok(timerTexts(f, declined).includes('The phone said no') && timerTexts(f, declined).includes('declined code=201'))
  assert.ok(timerTexts(f, act(f, 'onFinishedAnswer1', r.st, str('error 5: no vibrator')).st).includes('The phone said no'))
  assert.ok(!timerTexts(f, act(f, 'resetTimer1', declined, num(0)).st).includes('The phone said no'))

  {
    const src = composeProgram(['timer', 'timer'], globals, [valuesFor({[FINISH]: 'true'}, EGGS), valuesFor({[FINISH]: 'true'}, EGGS)])
    assert.match(src, /function onFinishedAnswer1\(/); assert.match(src, /function onFinishedAnswer2\(/)
    compileVeraSource(src)
  }
  {
    const body = markedHole('whenFinished', '3', VIBRATE)
    assert.match(body, /"onFinishedAnswer3"/)
  }

  assert.equal(holesOf(['timer'], [new Map([[FINISH, 'false']])]).length, 0)
  assert.equal(holesOf(['timer'], [new Map([[FINISH, 'true']])]).length, 1)
  assert.equal(holesOf(['timer']).length, 1)
  assert.equal(holesOf(['timer'], [new Map()]).length, 0, 'no answer for the slot: not asked')

  {
    const hole = holesOf(['timer'], [new Map([[FINISH, 'true']])])
    const [system, user] = buildHolePrompt('Egg timer, vibrate when done', hole, '{"found":[{"call":"SensorServiceKit.vibrator.vibrate"}]}')
    assert.match(system, /sdk\.call\("<target>"/); assert.match(system, /never invent a target/)
    assert.match(user, /onFinishedAnswerIDX/); assert.match(user, /SDK functions found for this request/); assert.match(user, /SensorServiceKit\.vibrator\.vibrate/)
    const plain = buildHolePrompt('x', hole)
    assert.doesNotMatch(plain[1], /SDK functions found/, 'nothing found: no list')
  }

  globalThis.__sdkTargetHook = target => target === 'SensorServiceKit.vibrator.vibrate'
  const buildFor = bodies => composeProgram(['timer'], globals, [valuesFor({[FINISH]: 'true'}, EGGS)].map(v => { holeValues(['timer'], bodies)[0].forEach((x, k) => v.set(k, x)); return v }))
  let reply = JSON.stringify({holes: {whenFinished1: VIBRATE.replace(/^ {2}/gm, '')}})
  let fill = await fillHoles('egg timer, vibrate', ['timer'], async () => reply, buildFor, [new Map([[FINISH, 'true']])])
  assert.match(fill.note, /holes=filled\(1\)/); assert.match(fill.bodies.get('whenFinished1'), /SensorServiceKit\.vibrator\.vibrate/)
  reply = JSON.stringify({holes: {whenFinished1: 'sdk.call("Nonexistent.Kit.fn", ["a", "b"], "onFinishedAnswerIDX");\nreturn 0;'}})
  fill = await fillHoles('egg timer, vibrate', ['timer'], async () => reply, buildFor, [new Map([[FINISH, 'true']])])
  assert.match(fill.note, /holes=default\(/, 'a target that does not exist falls back to the default: ' + fill.note)
  assert.equal(fill.bodies.size, 0)
  let asked = 0
  fill = await fillHoles('countdown only', ['timer'], async () => { asked++; return reply }, buildFor, [new Map([[FINISH, 'false']])])
  assert.equal(asked, 0); assert.equal(fill.note, '')

  const body = (slot, vetoes = {}) => {
    const answers = {section1: {choice: 'timer', confidence: 0.9}, 'section1.timer.finish_action': {noul: slot}}
    for (const k of ['needs_integration', 'needs_real_data', 'needs_search_or_form', 'needs_live_ticking', 'needs_multiple_counters', 'needs_multiple_series', 'needs_logic'])
      answers['veto.' + k] = {noul: vetoes[k] || 0}
    return JSON.stringify({answers})
  }
  let o = readSectionPick(body(0.9, {needs_integration: 0.82}))
  assert.equal(o.sections[0].slotValues.get(FINISH), 'true'); assert.equal(o.needsLogic, false, 'a finish action is covered by the hole')
  o = readSectionPick(body(0.1, {needs_integration: 0.82}))
  assert.equal(o.sections[0].slotValues.get(FINISH), 'false'); assert.equal(o.needsLogic, true, 'an integration the block does not cover still goes to the model')
}

function intervalTimer() {
  function buildTimer(content = {}, signal = 'true') {
    const spec = specOf('interval_timer'), m = new Map()
    spec.slots.forEach(s => m.set(s.token, signal))
    spec.contentFields.forEach(c => m.set(c.token, content[c.key] !== undefined ? content[c.key] : c.fallback))
    return buildFromMaps('interval_timer', [m], {smoke: true})
  }
  const badge = (h, st) => nodes(h, st).find(n => n.kind === 'badge').text
  const clock = (h, st) => nodes(h, st).find(n => n.kind === 'text' && n.style === 'display').text
  const round = (h, st) => nodes(h, st).find(n => n.kind === 'progress').label
  const tick = (h, st, ms) => act(h, 'onCycleTick1', st, num(ms))

  {
    const h = buildTimer({work_seconds: '900', rest_seconds: '300', rounds: '2', work_label: 'Focus', rest_label: 'Break'})
    let st = h.vm.execute('init')
    assert.equal(badge(h, st), 'Focus')
    assert.equal(clock(h, st), '15:00')
    assert.equal(round(h, st), 'Round 1 of 2')
    assert.ok(texts(h, st).includes('Start'))
    assert.ok(texts(h, st).includes('Focus (minutes)'), 'the settings are in minutes')
    assert.equal(JSON.stringify(tick(h, st, 1000).st), JSON.stringify(st))
    st = act(h, 'toggleCycle1', st, num(0)).st
    assert.ok(texts(h, st).includes('Pause'))
    assert.equal(nodes(h, st).find(n => n.kind === 'ticker').checked, true, 'the ticker runs')
    let r = tick(h, st, 60000)
    st = r.st
    assert.equal(clock(h, st), '14:00')
    assert.equal(r.effects.length, 0, 'no signal mid-block')
    r = tick(h, st, 840000); st = r.st
    assert.equal(badge(h, st), 'Break')
    assert.equal(clock(h, st), '5:00')
    assert.equal(r.effects.length, 1)
    assert.equal(r.effects[0].rawTarget, 'SensorServiceKit.vibrator.vibrate')
    r = tick(h, st, 300000); st = r.st
    assert.equal(badge(h, st), 'Focus')
    assert.equal(round(h, st), 'Round 2 of 2')
    assert.equal(r.effects.length, 1)
    r = act(h, 'skipPhase1', st, num(0)); st = r.st
    r = tick(h, st, 1000); st = r.st
    assert.ok(texts(h, st).includes('All rounds done'))
    assert.equal(clock(h, st), '15:00', 'the focus time of the one block run to its end')
    assert.ok(texts(h, st).includes('Start again'))
    assert.equal(nodes(h, st).find(n => n.kind === 'ticker').checked, false, 'the ticker is off')
    st = act(h, 'toggleCycle1', st, num(0)).st
    assert.equal(round(h, st), 'Round 1 of 2')
    assert.ok(texts(h, st).includes('Pause'))
    st = act(h, 'resetCycle1', tick(h, st, 5000).st, num(0)).st
    assert.equal(clock(h, st), '15:00')
    assert.ok(texts(h, st).includes('Start'))
  }

  {
    const h = buildTimer({work_seconds: '30', rest_seconds: '10', rounds: '1'}, 'false')
    let st = h.vm.execute('init')
    assert.equal(clock(h, st), '0:30')
    assert.ok(texts(h, st).some(t => /\(seconds\)$/.test(t)), 'the settings are in seconds')
    st = act(h, 'toggleCycle1', st, num(0)).st
    const r = tick(h, st, 31000)
    assert.ok(texts(h, r.st).includes('All rounds done'), 'one round: no break after it')
    assert.equal(r.effects.length, 0, 'no vibration when the slot says no')
    st = act(h, 'setWork1', h.vm.execute('init'), num(45)).st
    assert.equal(clock(h, st), '0:45')
    st = act(h, 'setRounds1', st, num(3)).st
    assert.equal(round(h, st), 'Round 1 of 3')
  }

  {
    const h = buildTimer({work_seconds: '0', rest_seconds: '-5', rounds: '0'})
    const st = h.vm.execute('init')
    assert.equal(clock(h, st), '25:00')
    assert.equal(round(h, st), 'Round 1 of 4')
  }
}

function unreadFields() {
  globalThis.__sdkTargetHook = () => true
  const head = 'import * as ui from "std/ui"\n@jsonable\nclass AppState { shown: number; hidden: number; }\nfunction init(): AppState { return {shown: 1, hidden: 2}; }\n'
  const set = 'function set_hidden(state: AppState, v: number): AppState { return {shown: state.shown, hidden: v}; }\n'
  const view = body => 'function view(state: AppState): ui.View { ' + body + ' }\n'
  const input = 'ui.NumberField("default", "n", state.shown, 0, 9, "set_hidden")'
  const screen = (inner, pre = '') => pre + 'return ui.AppTheme("clean", "", [ui.Section("content", "", "", [' + inner + '])]);'

  assert.deepEqual(compileVeraSource(head + set + view(screen(input))).unreadFields, ['hidden'])
  assert.deepEqual(compileVeraSource(head + set + view(screen(input + ', ui.Text("body", "n is " + ui.numberToString(state.hidden))'))).unreadFields, [])
  assert.deepEqual(compileVeraSource(head + set + view(screen(input + ', ui.When(state.hidden > 3, ui.Text("body", "big"))'))).unreadFields, [])
  assert.deepEqual(compileVeraSource(head + set + 'function twice(state: AppState): number { return state.hidden * 2; }\n' +
    view(screen(input + ', ui.Text("body", ui.numberToString(twice(state)))'))).unreadFields, [])
  assert.deepEqual(compileVeraSource(head + set + 'function bump(state: AppState, v: number): AppState { return {shown: state.hidden + v, hidden: state.hidden}; }\n' +
    view(screen(input + ', ui.Button("primary", "go", "bump", 0, true)'))).unreadFields, [])
  assert.deepEqual(compileVeraSource(head + 'function nudge(state: AppState, v: number): AppState { return {shown: v, hidden: state.hidden}; }\n' +
    view(screen('ui.NumberField("default", "n", state.shown, 0, 9, "nudge")'))).unreadFields, ['hidden'])
  {
    const draft = 'import * as ui from "std/ui"\n@jsonable\nclass Item { title: string; done: boolean; }\n' +
      '@jsonable\nclass AppState { title: string; items: Item[]; }\n' +
      'function init(): AppState { let none: Item[] = []; return {title: "", items: none}; }\n' +
      'function set_title(state: AppState, v: string): AppState { return {title: v, items: state.items}; }\n' +
      'function add(state: AppState, v: number): AppState { let item: Item = {title: state.title, done: false}; let out: Item[] = []; ' +
      'for (let e: Item of state.items) { out.push(e); } out.push(item); return {title: "", items: out}; }\n'
    assert.deepEqual(compileVeraSource(draft + view(screen('ui.TextField("default", "t", "", "set_title"), ' +
      'ui.Button("primary", "Add", "add", 0, true), ui.Text("body", ui.numberToString(state.items.length()))'))).unreadFields, [])
  }
  assert.deepEqual(compileVeraSource(head + 'function swap(state: AppState, v: number): AppState { return {shown: state.hidden, hidden: v}; }\n' +
    view(screen('ui.NumberField("default", "n", state.shown, 0, 9, "swap")'))).unreadFields, [])

  const valuesFor = kind => {
    const spec = specOf(kind), m = new Map()
    spec.slots.forEach(s => m.set(s.token, s.values[0])); spec.contentFields.forEach(c => m.set(c.token, c.fallback))
    spec.listFields.forEach(l => m.set(l.token, expandListRows(undefined, l).text))
    return m
  }
  for (const f of fragments()) {
    assert.deepEqual(compileVeraSource(composeProgram([f.kind], globals, [valuesFor(f.kind)])).unreadFields, [], f.kind + ' keeps a field nothing reads')
  }
}

const scenarios = [
  ['due items', dueItems],
  ['reading status', readingStatus],
  ['dose schedule', doseSchedule],
  ['quick log', quickLog],
  ['itinerary', itinerary],
  ['reminders', reminders],
  ['ledger', ledger],
  ['points ledger', pointsLedger],
  ['trend chart', trendChart],
  ['timer', timer],
  ['interval timer', intervalTimer],
  ['unread fields', unreadFields],
]

async function main() {
  let failed = 0
  for (const [name, fn] of scenarios) {
    try {
      await fn()
      console.log('PASS ' + name)
    } catch (e) {
      failed++
      console.error('FAIL ' + name + ': ' + (e && e.message ? e.message : e))
      if (process.env.VERA_SUITE_STACK) console.error(e.stack)
    }
  }
  console.log('template-suite: ' + (scenarios.length - failed) + ' scenarios passed')
  if (failed > 0) process.exit(1)
}

main()
