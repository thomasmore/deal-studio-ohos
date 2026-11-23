'use strict'
// Template-block scenarios that share template-fixture.js. Each scenario keeps the
// assertion of the check it replaces; the suite reports per scenario and exits 1
// if any fails, so a single broken block is still identifiable.

const {
  assert, specOf, values, build, buildFromMaps, walk, nodes, texts, text, act, num, str,
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
    const h = buildFromMaps('due_items', [dueValues('{name: "Milk", inDays: 1, lifeDays: 0},\n   {name: "Water filter", inDays: 40, lifeDays: 90}, \n    {name: "Bread", inDays: -2, lifeDays: 0}')])
    let st = h.vm.execute('init')
    assert.deepEqual(rows(h, st), [['Bread', 'Expired 2 days ago', 'danger'], ['Milk', 'Tomorrow', 'warning'], ['Water filter', 'In 40 days', 'default']])
    assert.deepEqual(stats(h, st), [['Expired', 1, 'danger'], ['Due soon', 1, 'warning']])
    assert.match(text(h, st), /every 90 days - 44% left/)
    const done = nodes(h, st).filter(n => n.kind === 'button' && n.text === 'Done')
    assert.equal(done.length, 1)
    st = h.vm.execute('setName1', [st, str('  Yogurt ')])
    st = h.vm.execute('setDue1', [st, num(today + 3)])
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.deepEqual(rows(h, st).map(r => r[0]), ['Bread', 'Milk', 'Yogurt', 'Water filter'])
    assert.deepEqual(rows(h, st)[2], ['Yogurt', 'In 3 days', 'warning'])
    assert.deepEqual(stats(h, st), [['Expired', 1, 'danger'], ['Due soon', 2, 'warning']])
    assert.equal(h.vm.execute('soonNames1', [st]).value, 'Milk, Yogurt')
    assert.equal(h.vm.execute('soonCount1', [st]).value, 2)
    assert.equal(h.vm.execute('expireCount1', [st]).value, 1)
    const before = rows(h, st).length
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.equal(rows(h, st).length, before)
    st = h.vm.execute('renew1', [st, num(1)])
    assert.deepEqual(rows(h, st)[3], ['Water filer', 'In 90 days', 'default'])
    assert.match(text(h, st), /every 90 days - 100% left/)
    const once = JSON.stringify(rows(h, st))
    st = h.vm.execute('renew1', [st, num(0)])
    assert.equal(JSON.stringify(rows(h, st)), once)
    st = h.vm.execute('removeItem1', [st, num(2)])
    assert.deepEqual(rows(h, st).map(r => r[0]), ['Milk', 'Yogurt', 'Water filter'])
    assert.deepEqual(stats(h, st)[0], ['Expired', 0, 'default'])
    st = h.vm.execute('setSoon1', [st, num(1)])
    assert.deepEqual(rows(h, st)[1], ['Yogurt', 'In 3 days', 'default'])
    assert.deepEqual(stats(h, st)[1], ['Due soon', 1, 'warning'])
    st = h.vm.execute('setName1', [st, str('Eggs')])
    st = h.vm.execute('setDue1', [st, num(today)])
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.deepEqual(rows(h, st)[0], ['Eggs', 'Today', 'danger'])
    st = h.vm.execute('setName1', [st, str('Smoke alarm battery')])
    st = h.vm.execute('setDue1', [st, num(today + 10)])
    st = h.vm.execute('addLife1', [st, str('365')])
    st = h.vm.execute('addItem1', [st, num(0)])
    assert.match(text(h, st), /Smoke alarm battery/)
    assert.match(text(h, st), /every 365 days/)
  }
  {
    const h = buildFromMaps('due_items', [dueValues('')])
    let st = h.vm.execute('init')
    assert.deepEqual(rows(h, st), [])
    assert.deepEqual(stats(h, st), [])
    assert.match(text(h, st), /Nothing tracked yet/)
  }
  {
    const spec = specOf('due_items')
    assert.deepEqual(spec.ports.map(p => p.name), ['soon_count', 'expired_count', 'soon_names', 'count'])
    assert.ok(spec.owns.length > 0)
    const h = buildFromMaps('due_items', [dueValues('{name: "Spinach", inDays: 1, lifeDays: 0},\n   {name: "Eggs", inDays: 2, lifeDays: 0}, \n    {name: "Rice", inDays: 200, lifeDays: 0}')])
    assert.match(h.src, /function sooNames1\(state: AppState\): string/)
  }
}

function readingStatus() {
  const FEVER = [['38', 'Normal', 'success', 'Keep an eye on it.'], ['39', 'Fever', 'warning', 'Fluids and light clothes.'],
    ['0', 'High fever', 'danger', 'Call a doctor.']]
  const C = {reading_label: 'Temperature', unit: '°C', unit_suffix: ' °C', decimals: '1'}

  function readingBuild(content = {}, bands = FEVER) {
    const spec = specOf('reading_status')
    const over = {}
    spec.contentFields.forEach(c => { if (content[c.key] !== undefined) over[C.token] = content[c.key] })
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
    // The guide under it: ranges from the bands.
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
    // Not a number: nothing added.
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
    // Newest first, each with its band.
    const rows = nodes(h, st).filter(n => n.kind === 'listitem' && /°C$/.test(n.text))
    assert.deepEqual(rows.map(n => [n.text, n.value]), [['39.2 °C', 'High fever'], ['38.4 °C', 'Fever']])
    // Remove the newest (index 1): the status goes back.
    st = h.vm.execute('removeReading1', [st, num(1)])
    assert.deepEqual(status(h, st), ['warning', 'Fever', 'warning'])
    assert.equal(nodes(h, st).filter(n => n.kind === 'sparkline').length, 0)
    st = add(h, st, '36.9')
    assert.deepEqual(status(h, st), ['success', 'Normal', 'success'])
    assert.equal(h.execute('statusLevel1', [st]).value, 0)
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
    // late: past its time and not taken
    at(9, 0)
    assert.equal(row(h, st, 'Vitamin D').style, 'warning'); assert.match(text(h, st), /Due 08:00 - late/)
    assert.equal(row(h, st, 'Iron').style, 'default')
    // take: "Taken 09:00", success, the button becomes Undo
    st = act(h, 'takeDose1', st, num(0)).st
    assert.equal(row(h, st, 'Vitamin D').style, 'success'); assert.equal(row(h, st, 'Vitamin D').value, 'Taken 09:00')
    assert.match(text(h, st), /1 of 3 taken today/); assert.match(text(h, st), /Undo/)
    // undo
    st = act(h, 'takeDose1', st, num(0)).st
    assert.match(text(h, st), /0 of 3 taken today/); assert.equal(row(h, st, 'Vitamin D').style, 'warning')
    // remove the bad one, take both: the streak is one day
    st = act(h, 'removeDose1', st, num(2)).st
    assert.doesNotMatch(text(h, st), /Bad time/)
    st = act(h, 'takeDose1', st, num(0)).st; at(21, 0); st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /2 of 2 taken today/); assert.match(text(h, st), /1 day\|Streak/)
    assert.equal(nodes(h, st).find(n => n.kind === 'progress').style, 'success')
    // undo the last of the day: the streak steps back; take it again: one day again
    let undone = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, undone), /0 days\|Streak/)
    assert.match(text(h, act(h, 'takeDose1', undone, num(1)).st), /1 day\|Streak/)
    // the next day starts untaken; the streak of yesterday still shows, and grows when today is done
    at(7, 0, 1)
    assert.match(text(h, st), /0 of 2 taken today/); assert.match(text(h, st), /1 day\|Streak/)
    st = act(h, 'takeDose1', st, num(0)).st; st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /2 days\|Streak/)
    // a whole day missed: the streak is gone, and starts again at one
    at(7, 0, 3)
    assert.match(text(h, st), /0 days\|Streak/)
    st = act(h, 'takeDose1', st, num(0)).st; st = act(h, 'takeDose1', st, num(1)).st
    assert.match(text(h, st), /1 day\|Streak/)
    // adding a dose: a name is needed; the time comes from the picker
    assert.equal(text(h, act(h, 'addDose1', st, num(0)).st), text(h, st), 'no name adds nothing')
    let s2 = act(h, 'setDoseName1', st, str('Omega 3')).st; s2 = act(h, 'setDoseTime1', s2, num(13 * 60 + 15)).st
    s2 = act(h, 'addDose1', s2, num(0)).st
    assert.match(text(h, s2), /Omega 3\|13:15/); assert.match(text(h, s2), /2 of 3 taken today/)

    // no doses named: one plain line, no empty state
    {
      const e = doseBuild('false', [])
      const s = e.vm.execute('init')
      assert.match(text(e, s), /No doses yet/); assert.ok(!nodes(e, s).some(n => n.kind === 'emptystate'))
    }

    // the calendar on: adding sends a daily event, the answer is shown on the row, a refusal is said; removing deletes the event
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
      // a new dose goes to the calendar as it is added; a refusal is shown
      let s3 = act(c, 'setDoseName1', s, str('Iron')).st
      r = act(c, 'addDose1', s3, num(0)); assert.equal(r.effects.length, 1); assert.equal(r.effects[0].values.get('hour'), '8')
      s3 = act(c, 'onDoseAdded1', r.st, str('declined code=201')).st
      assert.match(text(c, s3), /Iron\|08:00 - not in calendar/); assert.match(text(c, s3), /The calendar said no\|declined code=201/)
      // removing the one in the calendar deletes its event
      r = act(c, 'removeDose1', s3, num(0))
      assert.equal(r.effects[0].rawTarget, 'CalendarKit.Calendar.deleteEvents'); assert.deepEqual(Object.fromEntries(r.effects[0].values), {ids: '777'})
    }

    // the calendar off: no calendar button, no call
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
  const quickBuild = (over = {}, presents = undefined) => build('quick_log', {quick_log: over}, {quick_log: presents})
  try {
    const h = quickBuild(water)
    let st = h.vm.execute('init')
    let t = text(h, st)
    assert.match(t, /0 of 2,?000 ml/); assert.match(t, /0\|Glasses\|today/); assert.match(t, /nothing yet today/)
    assert.ok(nodes(h, st).some(n => n.kind === 'progressring'), 'a ring toward the goal')
    assert.ok(!nodes(h, st).some(n => n.kind === 'emptystate'), 'no empty state: the ring and the count say 0')
    assert.doesNotMatch(t, /Undo/, 'nothing to undo yet')
    // the settings are at the foot, after the button
    const kinds = nodes(h, st).map(n => n.kind + ':' + (n.label || n.text || ''))
    assert.ok(kinds.findIndex(k => k.includes('Add a glass')) < kinds.findIndex(k => k.includes('Amount per tap (ml)')), 'button before settings')
    assert.ok(kinds.findIndex(k => k.includes('Daily goal (ml, 0 for none)')) > 0)

    // three taps at 09:00, 09:30, 10:10
    at(9, 0); st = act(h, 'addTap1', st, num(0))
    at(9, 30); st = act(h, 'addTap1', st, num(0))
    at(10, 10); st = act(h, 'addTap1', st, num(0))
    at(10, 40); t = text(h, st)
    assert.match(t, /750 of 2,?000 ml/); assert.match(t, /3\|Glasses\|today/); assert.match(t, /30 min ago\|Last/)
    assert.match(t, /250 ml\|10:10.*250 ml\|09:30.*250 ml\|09:00/, 'newest first')
    assert.match(t, /Undo/)
    at(12, 0); assert.match(text(h, st), /1 h 50 min ago\|Last/)
    // Undo takes back the last one; Remove takes the row asked for (index 0 is 09:00)
    st = act(h, 'undoTap1', st, num(0)); t = text(h, st)
    assert.match(t, /500 of 2,?000 ml/); assert.doesNotMatch(t, /10:10/)
    st = act(h, 'removeTap1', st, num(0)); t = text(h, st)
    assert.match(t, /250 of 2,?000 ml/); assert.doesNotMatch(t, /09:00/); assert.match(t, /09:30/)
    assert.equal(text(h, act(h, 'removeTap1', st, num(9))), t, 'an index outside the list does nothing')
    // the amount per tap and the goal are settings
    st = act(h, 'setTapAmount1', st, str('330')); st = act(h, 'addTap1', st, num(0))
    assert.match(text(h, st), /580 of 2,?000 ml/)
    st = act(h, 'setTapGoal1', st, str('500')); assert.ok(nodes(h, st).some(n => n.kind === 'progressring' && n.style === 'success'), 'goal reached')
    st = act(h, 'setTapAmount1', st, str('nonsense')); st = act(h, 'addTap1', st, num(0))
    assert.match(text(h, st), /581 of 500 ml/, 'an amount that is not a number counts 1')

    // a new day: today is zero, yesterday is under it, Undo does not reach into yesterday
    at(8, 0, 1); t = text(h, st)
    assert.match(t, /0 of 500 ml/); assert.match(t, /0\|Glasses\|today/); assert.match(t, /Yesterday: 3, 581 ml/); assert.doesNotMatch(t, /Undo/)
    assert.equal(text(h, act(h, 'undoTap1', st, num(0)).st), t, 'undo on a new day before any tap changes nothing')

    // no unit and no goal: each tap is one more, no ring, the row is named
    {
      at(9, 0)
      const n = quickBuild({__BUTTON_IDX__: 'Log a nappy', __AMOUNT_IDX__: '1', __UNIT_IDX__: '', __GOAL_IDX__: '0', __COUNT_LABEL_IDX__: 'Nappies', __ENTRY_WORD_IDX__: 'Nappy change'})
      let s = n.vm.execute('init'); s = act(n, 'addTap1', s, num(0)); s = act(n, 'addTap1', s, num(0)).st
      const tt = text(n, s)
      assert.ok(!nodes(n, s).some(x => x.kind === 'progressring'), 'no goal: no ring')
      assert.match(tt, /2\|Nappies\|today/); assert.match(tt, /Nappy change\|09:00/); assert.doesNotMatch(tt, /Amount per tap/)
    }

    // presets: extra buttons, each adds its own amount
    {
      at(9, 0)
      const p = quickBuild(water, [['Small', '150'], ['Large', '500']])
      let s = p.vm.execute('init')
      assert.match(text(p, s), /Add a glass\|.*Small.*Large/)
      s = act(p, 'addPreset1', s, num(1)).st; s = act(p, 'addPreset1', s, num(0)).st; s = act(p, 'addPreset1', s, num(7)).st
      assert.match(text(p, s), /650 of 2,?000 ml/)
    }

    // the published numbers
    {
      const ports = specOf('quick_log').ports.map(p => p.name)
      assert.deepEqual(ports, ['today_total', 'today_count', 'goal'])
    }

    buildFromMaps(['quick_log', 'quick_log'], [values('quick_log', water), values('quick_log', {})])
  } finally {
    global.Date = RealDate
  }
}
