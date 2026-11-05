#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const root = path.resolve(__dirname, '../..')
const file = path.join(root, 'entry/src/main/ets/vera/VeraCalendarSdk.ets')
const source = fs.readFileSync(file, 'utf8')
function sdkApiPath() {
  if (process.env.VERA_CALENDAR_SDK_PATH) return path.resolve(process.env.VERA_CALENDAR_SDK_PATH)
  let ancestor = path.dirname(require.resolve(process.env.VERA_TYPESCRIPT_PATH || 'typescript'))
  while (true) {
    const api = path.join(ancestor, 'api')
    if (fs.existsSync(path.join(api, '@ohos.calendarManager.d.ts'))) return api
    const parent = path.dirname(ancestor)
    if (parent === ancestor) throw Error('Set VERA_CALENDAR_SDK_PATH to the SDK ets/api directory')
    ancestor = parent
  }
}
const sdkRoot = sdkApiPath()
const kitsRoot = path.join(path.dirname(sdkRoot), 'kits')
const compiled = ts.transpileModule(source, {
  fileName: 'VeraCalendarSdk.ts',
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
  reportDiagnostics: true
})
assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0)
function typecheck() {
  const virtual = path.join(root, 'entry/src/main/ets/vera/VeraCalendarSdk.ts')
  const permission = path.join(root, 'entry/src/main/ets/vera/VeraPermissions.ts')
  const options = { strict: true, noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, moduleResolution: ts.ModuleResolutionKind.NodeJs }
  const host = ts.createCompilerHost(options)
  const originalRead = host.readFile.bind(host), originalExists = host.fileExists.bind(host)
  host.readFile = name => name === virtual ? source : name === permission ? 'export class AbilityContext { static value: import("@kit.AbilityKit").common.UIAbilityContext | null = null }' : originalRead(name)
  host.fileExists = name => name === virtual || name === permission || originalExists(name)
  host.resolveModuleNames = (names, containing) => names.map(name => {
    if (name === './VeraPermissions') return { resolvedFileName: permission, extension: ts.Extension.Ts }
    if (name.startsWith('@kit.')) return { resolvedFileName: path.join(kitsRoot, name + '.d.ts'), extension: ts.Extension.Dts }
    if (name.startsWith('@ohos.')) return { resolvedFileName: path.join(sdkRoot, name + '.d.ts'), extension: ts.Extension.Dts }
    return ts.resolveModuleName(name, containing, options, host).resolvedModule
  })
  const program = ts.createProgram([virtual], options, host)
  const errors = ts.getPreEmitDiagnostics(program).filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, ts.formatDiagnostics(errors, { getCurrentDirectory: () => root, getCanonicalFileName: f => f, getNewLine: () => '\n' }))
  const syntax = ts.createSourceFile(virtual, source, ts.ScriptTarget.Latest, true)
  function visit(node) {
    assert.notEqual(node.kind, ts.SyntaxKind.AnyKeyword, 'any is forbidden')
    assert.notEqual(node.kind, ts.SyntaxKind.UnknownKeyword, 'unknown is forbidden')
    assert.notEqual(node.kind, ts.SyntaxKind.ObjectLiteralExpression, 'typed classes required')
    if (node.kind === ts.SyntaxKind.ElementAccessExpression) assert.equal(node.argumentExpression.kind, ts.SyntaxKind.NumericLiteral, 'dynamic indexing forbidden')
    ts.forEachChild(node, visit)
  }
  visit(syntax)
}
function validId(id) { assert(Number.isInteger(id) && id > 0 && id <= 2147483647, 'native positive int32 id') }
function fixture(options = {}) {
  const calls = [], factories = [], calendars = new Map()
  const ability = { value: options.noContext ? null : { host: true } }
  let failure = null, nextId = 10, editResult = 77, calendarDeletionAttempted = false
  function call(name, ...args) {
    calls.push([name, ...args])
    if (failure && (failure.name === name || failure.name === '*')) throw Object.assign(new Error(failure.message), { code: failure.code })
  }
  function calendar(id, account) {
    const state = { config: { enableReminder: true, color: '#112233' }, events: new Map() }
    const cal = {
      id, state,
      getAccount() { call('getAccount', id); return { ...account, privateNative: 'omit' } },
      getConfig() { call('getConfig', id); return { ...state.config, privateNative: 'omit' } },
      async setConfig(value) { call('setConfig', id, value); state.config = { ...value } },
      async addEvent(event) { call('addEvent', id, event); const eventId = Object.hasOwn(options, 'addId') ? options.addId : nextId++; state.events.set(eventId, { ...event, id: eventId }); return eventId },
      async addEvents(events) { call('addEvents', id, events); for (const event of events) { const eventId = nextId++; state.events.set(eventId, { ...event, id: eventId }) } },
      async deleteEvent(eventId) { validId(eventId); call('deleteEvent', id, eventId); if (!options.voidNoop) state.events.delete(eventId) },
      async deleteEvents(ids) { assert(Array.isArray(ids)); ids.forEach(validId); call('deleteEvents', id, ids); if (!options.voidNoop) for (const eventId of ids) state.events.delete(eventId) },
      async updateEvent(event) {
        validId(event.id)
        call('updateEvent', id, event)
        if (!options.voidNoop) {
          const stored = { ...state.events.get(event.id), ...event }
          if (event.recurrenceRule === undefined) stored.recurrenceRule = state.events.get(event.id)?.recurrenceRule
          state.events.set(event.id, stored)
        }
      },
      async getEvents(...args) {
        assert(args.length <= 2, 'getEvents argument count')
        const [filter, keys] = args
        if (args.length >= 1) assert.equal(filter?.native, true, 'getEvents requires a native filter object, not undefined')
        if (args.length === 2) assert(Array.isArray(keys) && keys.every(k => typeof k === 'string'), 'getEvents requires keys array')
        call('getEvents', id, ...args)
        let result = [...state.events.values()]
        if (filter?.kind === 'id') result = result.filter(e => filter.ids.includes(e.id))
        if (filter?.kind === 'title') result = result.filter(e => e.title.includes(filter.title))
        if (filter?.kind === 'time') result = result.filter(e => e.startTime < filter.end && e.endTime > filter.start)
        return result.map(e => {
          if (keys) return Object.fromEntries(keys.filter(k => e[k] !== undefined).map(k => [k, e[k]]))
          const { recurrenceRule, isLunar, ...defaultFields } = e
          return defaultFields
        })
      },
      async queryEventInstances(...args) {
        assert(args.length >= 2 && args.length <= 4, 'queryEventInstances argument count')
        const [start, end, ids, keys] = args
        assert.equal(typeof start, 'number')
        assert.equal(typeof end, 'number')
        if (args.length >= 3) { assert(Array.isArray(ids), 'queryEventInstances requires IDs array'); ids.forEach(validId) }
        if (args.length === 4) assert(Array.isArray(keys) && keys.every(k => typeof k === 'string'), 'queryEventInstances requires keys array')
        call('queryEventInstances', id, ...args)
        return [...state.events.values()].filter(e => !ids || ids.length === 0 || ids.includes(e.id)).map(e => {
          const event = { ...e, instanceStartTime: start, instanceEndTime: end }
          return keys ? Object.fromEntries(keys.filter(k => event[k] !== undefined).map(k => [k, event[k]])) : event
        })
      }
    }
    if (!options.noOpen) cal.openEventEditPage = async eventId => { call('openEventEditPage', id, eventId) }
    calendars.set(id, cal)
    return cal
  }
  calendar(1, { name: 'default', type: 'local' })
  calendar(2, { name: 'work', type: 'email', displayName: 'Work' })
  const manager = {
    async getCalendar(account) { call('getCalendar', account); if (!account) return calendars.get(1); const found = [...calendars.values()].find(c => c.getAccount().name === account.name && c.getAccount().type === account.type); if (!found) throw Object.assign(new Error('account not found'), { code: 23900003 }); return found },
    async getAllCalendars() {
      call('getAllCalendars')
      if (calendarDeletionAttempted && options.emptyCalendarListingAfterDeletion) return []
      return [...calendars.values()]
    },
    async createCalendar(account) { call('createCalendar', account); return calendar(Object.hasOwn(options, 'createId') ? options.createId : 3, { ...account }) },
    async deleteCalendar(cal) {
      call('deleteCalendar', cal.id)
      calendarDeletionAttempted = true
      if (options.deleteCalendarNoop) return false
      calendars.delete(cal.id)
    },
    async editEvent(event) { call('editEvent', event); return editResult }
  }
  const sdk = {
    CalendarType: { LOCAL: 'local', EMAIL: 'email', BIRTHDAY: 'birthday', CALDAV: 'caldav', SUBSCRIBED: 'subscribed' },
    EventType: { NORMAL: 0, IMPORTANT: 1 },
    RecurrenceFrequency: { YEARLY: 0, MONTHLY: 1, WEEKLY: 2, DAILY: 3 },
    getCalendarManager(context) { assert.equal(context, ability.value); call('getCalendarManager'); return manager },
    EventFilter: {
      filterById(ids) { assert(Array.isArray(ids)); ids.forEach(validId); call('filterById', ids); factories.push('id'); return { native: true, kind: 'id', ids } },
      filterByTime(start, end) { call('filterByTime', start, end); factories.push('time'); return { native: true, kind: 'time', start, end } },
      filterByTitle(title) { call('filterByTitle', title); factories.push('title'); return { native: true, kind: 'title', title } }
    }
  }
  const mod = { exports: {} }
  new Function('require', 'module', 'exports', compiled.outputText)(name => {
    if (name === '@kit.CalendarKit') return { calendarManager: sdk }
    if (name === './VeraPermissions') return { AbilityContext: ability }
    throw Error('Unexpected import ' + name)
  }, mod, mod.exports)
  const coverage = new Set()
  return {
    api: mod.exports, calls, factories, calendars, manager, sdk, ability, coverage,
    backend() {
      const backendSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/vera/VeraSdkBackend.ets'), 'utf8')
      const result = ts.transpileModule(backendSource, { fileName: 'VeraSdkBackend.ts', compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true }, reportDiagnostics: true })
      assert.equal((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0)
      const backend = { exports: {} }
      const supports = new Set(['SystemCapability.FileManagement.StorageService.SpatialStatistics'])
      const canIUse = capability => supports.has(capability)
      new Function('require', 'module', 'exports', 'canIUse', result.outputText)(name => {
        if (name === './VeraCalendarSdk') return mod.exports
        if (name === './VeraPermissions') return { AbilityContext: ability }
        if (name === '@kit.CoreFileKit') return { storageStatistics: { getFreeSizeSync: () => 4096 } }
        if (name.startsWith('@kit.')) return {}
        throw Error('Unexpected backend import ' + name)
      }, backend, backend.exports, canIUse)
      return backend.exports
    },
    fail(name, code = 201, message = 'permission denied') { failure = { name, code, message } },
    clearFailure() { failure = null },
    editResult(value) { editResult = value },
    async run(target, params = {}) { const full = 'CalendarKit.' + target; coverage.add(full); return mod.exports.runCalendarSdkAdapter(full, new Map(Object.entries(params))) }
  }
}
const checks = []
async function test(name, fn) {
  try { await fn(); checks.push(name); console.log('PASS ' + name) }
  catch (error) { console.error('FAIL ' + name + '\n' + error.stack); process.exitCode = 1 }
}
function error(value, match = /^error: /) { assert.match(value, match) }
const epochEvent = { title: 'Planning', startTime: '1772974800000', endTime: '1772978400000' }
const legacy = { title: 'Legacy', hour: '9', minute: '30' }
async function nativeFailures(cases) {
  for (const { owner, method, target, params = {}, occurrence = 1, argCounts, deleted = false } of cases) {
    for (const mode of ['sync', 'async']) {
      for (const code of [undefined, 0, 201, 801, 23900004]) {
        const g = fixture()
        g.calendars.get(1).state.events.set(30, { id: 30, type: 0, ...epochEvent, startTime: Number(epochEvent.startTime), endTime: Number(epochEvent.endTime) })
        const snapshot = () => structuredClone([...g.calendars].map(([id, cal]) => [id, cal.state.config, [...cal.state.events]]))
        const before = snapshot()
        const native = owner === 'calendar' ? g.calendars.get(1) : owner === 'filter' ? g.sdk.EventFilter : g[owner]
        const original = native[method], attempts = []
        const message = method + ' ' + occurrence + ' ' + mode + ' native failure: exact message'
        const failure = new Error(message)
        let codeReads = 0
        Object.defineProperty(failure, 'code', { get() { assert.equal(this, failure); codeReads++; return code } })
        native[method] = function (...args) {
          attempts.push(args)
          if (attempts.length !== occurrence) return original.apply(this, args)
          g.calls.push([method, ...args])
          if (mode === 'async') return Promise.reject(failure)
          throw failure
        }
        if (['getCalendarManager', 'getAccount', 'getConfig', 'filterById', 'filterByTitle', 'filterByTime'].includes(method) && mode === 'async') continue
        const label = [target, method, occurrence, mode, code].join(' ')
        assert.equal(await g.run(target, params), 'error: ' + (code === undefined ? '' : code + ': ') + message, label)
        assert(codeReads > 0, label + ' preserves native error identity and code')
        assert.equal(attempts.length, occurrence, label + ' must reach the intended native failure')
        if (argCounts) assert.deepEqual(attempts.map(args => args.length), argCounts, label)
        assert.equal(g.calls.at(-1)[0], method, label + ' must stop at the failed native call')
        if (deleted) {
          assert(!g.calendars.has(2), label)
          assert(g.calendars.has(1), label)
        } else assert.deepEqual(snapshot(), before, label + ' must not mutate after failure')
      }
    }
  }
}
;(async () => {
  await test('strict SDK typecheck and ArkTS source restrictions', typecheck)
  const f = fixture()
  await test('all 20 catalogue targets and wire contracts', async () => {
    const index = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/sdk-index.json'), 'utf8'))
    const expected = index.filter(row => row.kit === 'CalendarKit').map(row => row.kit + '.' + row.module + '.' + row.name)
    assert.equal(expected.length, 20)
    assert.deepEqual([...f.api.calendarSdkTargets].sort(), expected.sort())
    for (const target of expected) {
      const contract = f.api.calendarSdkContract(target)
      assert(contract instanceof f.api.CalendarSdkContract)
      assert.equal(typeof contract.params, 'string')
      assert.equal(contract.returnType, 'string')
      assert.equal(typeof contract.description, 'string')
    }
    assert.equal(f.api.calendarSdkContract('CalendarKit.missing'), undefined)
    error(await f.run('missing'), /unsupported CalendarKit target/)
    assert.equal(await f.run('calendarManager.getCalendarManager'), 'vera-calendar-manager')
    assert.equal(await f.run('CalendarManager.getCalendar', { manager: 'vera-calendar-manager' }), '1')
    error(await f.run('CalendarManager.getCalendar', { manager: 'fake' }), /invalid manager token/)
  })
  await test('legacy today add, decimal IDs and delete ok', async () => {
    const id = await f.run('Calendar.addEvent', { ...legacy, durationMinutes: '45', remindBefore: '10', repeat: 'daily', location: 'Office' })
    assert.match(id, /^[0-9]+$/)
    const event = f.calendars.get(1).state.events.get(Number(id))
    const today = new Date(), date = new Date(event.startTime)
    assert.equal(date.getDate(), today.getDate())
    assert.equal(date.getMonth(), today.getMonth())
    assert.equal(date.getHours(), 9)
    assert.equal(date.getMinutes(), 30)
    assert.equal(event.endTime - event.startTime, 45 * 60000)
    assert.deepEqual(event.reminderTime, [10])
    assert.equal(event.recurrenceRule.recurrenceFrequency, 3)
    assert.equal(event.location.location, 'Office')
    assert.equal(await f.run('Calendar.deleteEvent', { id }), 'ok')
    const second = await f.run('Calendar.addEvent', legacy)
    assert.equal(f.calendars.get(1).state.events.get(Number(second)).endTime - f.calendars.get(1).state.events.get(Number(second)).startTime, 3600000)
    assert.equal(await f.run('Calendar.deleteEvents', { ids: second + ', 123' }), 'ok')
    const negative = await f.run('Calendar.addEvent', { ...legacy, remindBefore: '-1', repeat: 'none' })
    assert.equal(f.calendars.get(1).state.events.get(Number(negative)).reminderTime, undefined)
  })
  await test('strict IDs and full-number parsing fail before mutation', async () => {
    const before = f.calls.filter(c => ['deleteEvent', 'deleteEvents', 'addEvent'].includes(c[0])).length
    for (const id of ['1x', '1.1', '1e2', '0', '-1', '', ' 1', '9007199254740992', 'Infinity']) error(await f.run('Calendar.deleteEvent', { id }))
    for (const value of ['1,,2', '1,', '2junk', '', '0']) error(await f.run('Calendar.deleteEvents', { ids: value }))
    for (const field of ['hour', 'minute', 'durationMinutes', 'remindBefore']) error(await f.run('Calendar.addEvent', { ...legacy, [field]: '1junk' }))
    for (const value of ['TRUE', '1', 'falsejunk']) error(await f.run('Calendar.addEvent', { ...epochEvent, isAllDay: value }))
    error(await f.run('Calendar.addEvent', { ...epochEvent, startTime: '9007199254740992' }))
    error(await f.run('Calendar.addEvent', { ...epochEvent, endTime: epochEvent.startTime }))
    assert.equal(f.calls.filter(c => ['deleteEvent', 'deleteEvents', 'addEvent'].includes(c[0])).length, before)
  })
  await test('calendarId and account selection, persistent create and DTO list', async () => {
    assert.equal(await f.run('CalendarManager.getCalendar', { name: 'work', type: 'email' }), '2')
    assert.equal(await f.run('CalendarManager.getCalendar', { calendarId: '2' }), '2')
    error(await f.run('CalendarManager.getCalendar', { calendarId: '2', name: 'work' }), /conflicts/)
    error(await f.run('CalendarManager.getCalendar', { type: 'email' }))
    error(await f.run('CalendarManager.getCalendar', { name: 'work', type: 'bogus' }))
    error(await f.run('CalendarManager.getCalendar', { calendarId: '2x' }))
    error(await f.run('CalendarManager.getCalendar', { calendarId: '99' }), /not found/)
    error(await f.run('CalendarManager.createCalendar', { name: '' }))
    error(await f.run('CalendarManager.createCalendar', { name: 'test', displayName: 'x'.repeat(65) }))
    assert.equal(await f.run('CalendarManager.createCalendar', { manager: 'vera-calendar-manager', name: 'new', displayName: 'New' }), '3')
    assert.equal(await f.run('CalendarManager.getCalendar'), '1')
    assert.equal(await f.run('CalendarManager.getCalendar', { name: 'new' }), '3')
    const id = await f.run('Calendar.addEvent', { ...epochEvent, calendarId: '3' })
    assert(f.calendars.get(3).state.events.has(Number(id)))
    assert(!f.calendars.get(1).state.events.has(Number(id)))
    const listed = JSON.parse(await f.run('CalendarManager.getAllCalendars'))
    assert.deepEqual(listed, [{ id: '1', account: { name: 'default', type: 'local' } }, { id: '2', account: { name: 'work', type: 'email', displayName: 'Work' } }, { id: '3', account: { name: 'new', type: 'local', displayName: 'New' } }])
    assert.deepEqual(JSON.parse(await f.run('Calendar.getAccount', { calendarId: '2' })), { name: 'work', type: 'email', displayName: 'Work' })
  })
  await test('native permission, capability and other BusinessError codes are visible', async () => {
    for (const [method, target, params] of [['getCalendar', 'CalendarManager.getCalendar', {}], ['addEvent', 'Calendar.addEvent', legacy], ['getAllCalendars', 'CalendarManager.getAllCalendars', {}], ['getEvents', 'Calendar.getEvents', {}], ['deleteEvent', 'Calendar.deleteEvent', { id: '10' }], ['editEvent', 'CalendarManager.editEvent', legacy], ['filterById', 'EventFilter.filterById', { ids: '1' }], ['openEventEditPage', 'Calendar.openEventEditPage', { id: '10' }]]) {
      for (const code of [201, 801, 23900004]) {
        f.fail(method, code, 'native failure')
        assert.equal(await f.run(target, params), 'error: ' + code + ': native failure')
        f.clearFailure()
      }
    }
    const missing = fixture({ noContext: true })
    error(await missing.run('calendarManager.getCalendarManager'), /no ability context/)
    error(await missing.run('Calendar.addEvent', legacy), /no ability context/)
  })
  await test('selection native failures retain exact errors for ID, account and default fallback', async () => {
    await nativeFailures([
      { owner: 'manager', method: 'getAllCalendars', target: 'CalendarManager.getCalendar', params: { calendarId: '2' }, argCounts: [0] },
      { owner: 'manager', method: 'getCalendar', target: 'CalendarManager.getCalendar', params: { name: 'work', type: 'email' }, argCounts: [1] },
      { owner: 'manager', method: 'getCalendar', target: 'CalendarManager.getCalendar', params: { name: 'default' }, argCounts: [1] },
      { owner: 'manager', method: 'getCalendar', target: 'CalendarManager.getCalendar', argCounts: [0] },
      { owner: 'manager', method: 'getAllCalendars', target: 'Calendar.addEvent', params: { ...epochEvent, calendarId: '2' }, argCounts: [0] },
      { owner: 'manager', method: 'getCalendar', target: 'Calendar.addEvent', params: epochEvent, argCounts: [0] },
      { owner: 'manager', method: 'getAllCalendars', target: 'CalendarManager.deleteCalendar', params: { calendarId: '2', confirm: 'true' }, argCounts: [0] },
      { owner: 'manager', method: 'getCalendar', target: 'CalendarManager.deleteCalendar', params: { calendarId: '2', confirm: 'true' }, argCounts: [0] }
    ])
    const g = fixture()
    assert.equal(await g.run('CalendarManager.getCalendar', { name: 'missing' }), 'error: 23900003: account not found')
    assert.equal(await g.run('CalendarManager.getCalendar', { calendarId: '99' }), 'error: calendarId was not found among available calendars')
    assert.equal(await g.run('CalendarManager.getCalendar', { calendarId: '2', name: 'work' }), 'error: calendarId conflicts with account name/type')
  })
  await test('dispatch manager and CRUD native failures never become successful completions', async () => {
    await nativeFailures([
      { owner: 'sdk', method: 'getCalendarManager', target: 'calendarManager.getCalendarManager' },
      { owner: 'manager', method: 'createCalendar', target: 'CalendarManager.createCalendar', params: { name: 'new' } },
      { owner: 'manager', method: 'getAllCalendars', target: 'CalendarManager.getAllCalendars' },
      { owner: 'calendar', method: 'getAccount', target: 'CalendarManager.getAllCalendars' },
      { owner: 'manager', method: 'deleteCalendar', target: 'CalendarManager.deleteCalendar', params: { calendarId: '2', confirm: 'true' } },
      { owner: 'manager', method: 'getAllCalendars', target: 'CalendarManager.deleteCalendar', params: { calendarId: '2', confirm: 'true' }, occurrence: 2, argCounts: [0, 0], deleted: true },
      { owner: 'manager', method: 'editEvent', target: 'CalendarManager.editEvent', params: epochEvent },
      { owner: 'calendar', method: 'addEvent', target: 'Calendar.addEvent', params: epochEvent },
      { owner: 'calendar', method: 'addEvents', target: 'Calendar.addEvents', params: { events: JSON.stringify([epochEvent]) } },
      { owner: 'calendar', method: 'deleteEvent', target: 'Calendar.deleteEvent', params: { id: '30' } },
      { owner: 'calendar', method: 'deleteEvents', target: 'Calendar.deleteEvents', params: { ids: '30,31' } },
      { owner: 'filter', method: 'filterById', target: 'Calendar.updateEvent', params: { id: '30', title: 'Changed' } },
      { owner: 'calendar', method: 'getEvents', target: 'Calendar.updateEvent', params: { id: '30', title: 'Changed' }, argCounts: [2] },
      { owner: 'calendar', method: 'updateEvent', target: 'Calendar.updateEvent', params: { id: '30', title: 'Changed' } }
    ])
  })
  await test('dispatch query overload failures retain exact errors including keys-only refetch', async () => {
    await nativeFailures([
      ...[
        [{}, 1, [0]],
        [{ ids: '30' }, 1, [1]],
        [{ ids: '30', eventKey: 'id,title' }, 1, [2]],
        [{ eventKey: 'id,title' }, 1, [0]],
        [{ eventKey: 'id,title' }, 2, [0, 2]]
      ].map(([params, occurrence, argCounts]) => ({ owner: 'calendar', method: 'getEvents', target: 'Calendar.getEvents', params, occurrence, argCounts })),
      ...[
        [{}, 2],
        [{ ids: '30' }, 3],
        [{ ids: '30', eventKey: 'id' }, 4],
        [{ eventKey: 'id' }, 4]
      ].map(([params, count]) => ({ owner: 'calendar', method: 'queryEventInstances', target: 'Calendar.queryEventInstances', params: { start: '1000', end: '2000', ...params }, argCounts: [count] })),
      { owner: 'filter', method: 'filterById', target: 'Calendar.getEvents', params: { eventKey: 'id' } },
      ...[
        ['filterById', { ids: '30' }],
        ['filterByTitle', { title: 'Planning' }],
        ['filterByTime', { start: '1000', end: '2000' }]
      ].flatMap(([method, params]) => [
        { owner: 'filter', method, target: 'EventFilter.' + method, params },
        { owner: 'filter', method, target: 'Calendar.getEvents', params }
      ])
    ])
  })
  await test('dispatch config, account and open failures retain exact errors and stop writes', async () => {
    await nativeFailures([
      { owner: 'calendar', method: 'getConfig', target: 'Calendar.getConfig' },
      { owner: 'calendar', method: 'getConfig', target: 'Calendar.setConfig', params: { enableReminder: 'false' } },
      { owner: 'calendar', method: 'setConfig', target: 'Calendar.setConfig', params: { enableReminder: 'false' } },
      { owner: 'calendar', method: 'getAccount', target: 'Calendar.getAccount' },
      { owner: 'calendar', method: 'openEventEditPage', target: 'Calendar.openEventEditPage', params: { id: '30' } }
    ])
    assert.equal(await fixture({ noOpen: true }).run('Calendar.openEventEditPage', { id: '30' }), 'error: openEventEditPage requires API 26; unavailable on this device')
  })
  await test('filter descriptors reconstruct native factories and reject conflicts', async () => {
    await f.run('Calendar.addEvent', { ...epochEvent, calendarId: '2' })
    for (const [target, params, kind] of [['filterById', { ids: '14,15' }, 'id'], ['filterByTitle', { title: 'Planning' }, 'title'], ['filterByTime', { start: epochEvent.startTime, end: epochEvent.endTime }, 'time']]) {
      const before = f.factories.length
      const wire = await f.run('EventFilter.' + target, params)
      const descriptor = JSON.parse(wire)
      assert.equal(descriptor.kind, kind)
      assert(!wire.includes('native'))
      assert.equal(f.factories.length, before + 1)
      const events = await f.run('Calendar.getEvents', { calendarId: '2', eventFilter: wire })
      assert(Array.isArray(JSON.parse(events)))
      assert.equal(f.factories.length, before + 2)
      const last = f.calls.filter(c => c[0] === 'getEvents').at(-1)
      assert.equal(last[2].kind, kind)
      error(await f.run('Calendar.getEvents', { eventFilter: wire, title: 'Planning' }), /conflicts/)
    }
    for (const params of [{ ids: '1', title: 'x' }, { title: 'x', start: '1', end: '2' }, { start: '1' }, { start: '2', end: '1' }, { eventKey: 'id,bogus' }, { eventKey: '' }, { format: 'csv' }]) error(await f.run('Calendar.getEvents', params))
    for (const descriptor of [{ kind: 'id', ids: [1] }, { kind: 'id', ids: [] }, { kind: 'id', ids: ['1x'] }, { kind: 'id', ids: ['1'], title: 'x' }, { kind: 'title', title: 2 }, { kind: 'time', start: '1' }, { kind: 'time', start: '2', end: '1' }, { kind: 'evil' }, { kind: 'title', title: 'x', extra: 1 }, null, []]) error(await f.run('Calendar.getEvents', { eventFilter: JSON.stringify(descriptor) }))
    await f.run('Calendar.getEvents', { ids: '14' })
    await f.run('Calendar.getEvents', { title: 'Planning' })
    await f.run('Calendar.getEvents', { start: epochEvent.startTime, end: epochEvent.endTime })
  })
  await test('safe read DTOs, eventKey projection and instance query', async () => {
    const native = { id: 90, type: 0, title: 'Rich', startTime: 1772974800000, endTime: 1772978400000, identifier: 'wire', isAllDay: false, isLunar: false, description: 'Details', timeZone: 'UTC', location: { location: 'Here', latitude: 1.5, longitude: 2.5, secret: 1 }, recurrenceRule: { recurrenceFrequency: 2, expire: 1800000000000, excludedDates: [1790000000000], daysOfWeek: [1], private: true }, reminderTime: [5], attendee: [{ name: 'Person', email: 'person@example.test', role: 'participant', type: 1, status: 2, secret: 'omit' }], service: { type: 'Meeting', uri: 'meeting:test', description: 'Join', secret: 'omit' }, privateNative: 'omit' }
    f.calendars.get(2).state.events.set(90, native)
    const dto = JSON.parse(await f.run('Calendar.getEvents', { calendarId: '2', ids: '90', eventKey: 'id,type,title,startTime,endTime,identifier,isAllDay,isLunar,description,timeZone,location,recurrenceRule,reminderTime,attendee,service' }))[0]
    assert.equal(dto.id, '90')
    assert.equal(dto.startTime, epochEvent.startTime)
    assert.equal(dto.endTime, epochEvent.endTime)
    assert.equal(dto.recurrenceRule.expire, '1800000000000')
    assert.deepEqual(dto.recurrenceRule.excludedDates, ['1790000000000'])
    assert(!JSON.stringify(dto).includes('secret'))
    assert(!JSON.stringify(dto).includes('private'))
    assert.deepEqual(JSON.parse(await f.run('Calendar.getEvents', { calendarId: '2', ids: '90', eventKey: 'id,title', format: 'json' })), [{ id: '90', title: 'Rich' }])
    const instances = JSON.parse(await f.run('Calendar.queryEventInstances', { calendarId: '2', start: epochEvent.startTime, end: epochEvent.endTime, ids: '90', eventKey: 'id,instanceStartTime,instanceEndTime' }))
    assert.equal(instances.length, 1)
    assert.equal(instances[0].instanceStartTime, epochEvent.startTime)
    assert.equal(instances[0].instanceEndTime, epochEvent.endTime)
    assert.equal(f.calls.filter(c => c[0] === 'queryEventInstances').at(-1)[1], 2)
    await f.run('Calendar.queryEventInstances', { start: epochEvent.startTime, end: epochEvent.endTime })
    for (const params of [{ start: '2', end: '1' }, { start: '1' }, { start: '1x', end: '2' }, { start: '1', end: '2', ids: '1x' }, { start: '1', end: '2', eventKey: 'bogus' }]) error(await f.run('Calendar.queryEventInstances', params))
  })
  await test('JSON Event validation, recurrence and all-before-write batch', async () => {
    const event = { ...epochEvent, type: 1, isAllDay: true, isLunar: false, description: 'Full', identifier: 'full', timeZone: 'UTC', location: { location: 'Place', longitude: 12.5, latitude: -30 }, reminderTime: [10, -5], recurrenceRule: { recurrenceFrequency: 2, expire: '1800000000000', count: 5, interval: 1, excludedDates: ['1790000000000'], daysOfWeek: [1], daysOfMonth: [2], daysOfYear: [50], weeksOfMonth: [1], weeksOfYear: [3], monthsOfYear: [2] } }
    const id = await f.run('Calendar.addEvent', { calendarId: '2', event: JSON.stringify(event) })
    assert.match(id, /^[0-9]+$/)
    const written = f.calendars.get(2).state.events.get(Number(id))
    assert.equal(written.startTime, Number(event.startTime))
    assert.equal(written.recurrenceRule.expire, 1800000000000)
    assert.deepEqual(written.recurrenceRule.excludedDates, [1790000000000])
    assert.equal(await f.run('Calendar.addEvents', { calendarId: '2', events: JSON.stringify([epochEvent, event]) }), 'ok')
    const before = f.calls.filter(c => ['addEvent', 'addEvents'].includes(c[0])).length
    const bad = [null, [], {}, { ...epochEvent, id: '10' }, { ...epochEvent, startTime: 1772974800000 }, { ...epochEvent, type: 2 }, { ...epochEvent, isAllDay: 'true' }, { ...epochEvent, title: null }, { ...epochEvent, description: 1 }, { ...epochEvent, instanceStartTime: '1' }, { ...epochEvent, attendee: [] }, { ...epochEvent, service: {} }, { ...epochEvent, unsupported: true }, { ...epochEvent, location: 'Place' }, { ...epochEvent, location: { longitude: 181 } }, { ...epochEvent, location: { latitude: -91 } }, { ...epochEvent, location: { secret: 1 } }, { ...epochEvent, reminderTime: [1.2] }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 4 } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, expire: 1 } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, count: -1 } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, daysOfWeek: [0] } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, excludedDates: [1] } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, weeksOfMonth: [1, 2], daysOfWeek: [1] } }, { ...epochEvent, recurrenceRule: { recurrenceFrequency: 1, unsupported: 1 } }]
    for (const invalid of bad) {
      error(await f.run('Calendar.addEvent', { event: JSON.stringify(invalid) }))
      error(await f.run('Calendar.addEvents', { events: JSON.stringify([epochEvent, invalid]) }))
    }
    for (const value of ['[]', '{}', 'null', 'not-json']) error(await f.run('Calendar.addEvents', { events: value }))
    error(await f.run('Calendar.addEvent', { title: 'mixed', event: JSON.stringify(epochEvent) }), /conflicts/)
    assert.equal(f.calls.filter(c => ['addEvent', 'addEvents'].includes(c[0])).length, before)
  })
  await test('update fetch merge preserves every absent native field', async () => {
    const existing = f.calendars.get(2).state.events.get(90)
    const snapshot = structuredClone(existing)
    assert.equal(await f.run('Calendar.updateEvent', { calendarId: '2', id: '90', title: 'Changed' }), 'ok')
    const updated = f.calendars.get(2).state.events.get(90)
    for (const key of ['id', 'type', 'startTime', 'endTime', 'location', 'recurrenceRule', 'reminderTime', 'attendee', 'service', 'timeZone', 'description', 'identifier', 'isLunar', 'isAllDay']) assert.deepEqual(updated[key], snapshot[key], key)
    assert.equal(updated.title, 'Changed')
    assert.equal(await f.run('Calendar.updateEvent', { calendarId: '2', id: '90', event: JSON.stringify({ id: '90', description: 'Updated' }) }), 'ok')
    assert.equal(f.calendars.get(2).state.events.get(90).description, 'Updated')
    assert.equal(f.calendars.get(2).state.events.get(90).title, 'Changed')
    const before = f.calls.filter(c => c[0] === 'updateEvent').length
    error(await f.run('Calendar.updateEvent', { calendarId: '2', id: '90', endTime: '1' }))
    error(await f.run('Calendar.updateEvent', { calendarId: '2', id: '90', event: '{"id":"91","title":"x"}' }))
    error(await f.run('Calendar.updateEvent', { calendarId: '2', id: '999', title: 'x' }), /not found/)
    assert.equal(f.calls.filter(c => c[0] === 'updateEvent').length, before)
    for (const repeat of ['once', 'none', '']) error(await f.run('Calendar.updateEvent', { calendarId: '2', id: '90', repeat }), /clearing existing recurrence is unsupported/)
    assert.equal(f.calls.filter(c => c[0] === 'updateEvent').length, before)
    assert.deepEqual(f.calendars.get(2).state.events.get(90).recurrenceRule, snapshot.recurrenceRule)
  })
  await test('config typed DTO, strict validation and read-merge', async () => {
    assert.deepEqual(JSON.parse(await f.run('Calendar.getConfig', { calendarId: '2' })), { enableReminder: true, color: '#112233' })
    assert.equal(await f.run('Calendar.setConfig', { calendarId: '2', enableReminder: 'false' }), 'ok')
    assert.deepEqual(f.calendars.get(2).state.config, { enableReminder: false, color: '#112233' })
    assert.equal(await f.run('Calendar.setConfig', { calendarId: '2', config: '{"color":"#AABBCCDD"}' }), 'ok')
    assert.deepEqual(f.calendars.get(2).state.config, { enableReminder: false, color: '#AABBCCDD' })
    assert.equal(await f.run('Calendar.setConfig', { calendarId: '2', color: '4294967295' }), 'ok')
    assert.equal(f.calendars.get(2).state.config.color, 4294967295)
    assert.equal(await f.run('Calendar.setConfig', { calendarId: '2', config: '{"enableReminder":true,"color":123}' }), 'ok')
    const before = f.calls.filter(c => c[0] === 'setConfig').length
    for (const params of [{}, { enableReminder: 'TRUE' }, { color: '#abc' }, { color: '4294967296' }, { color: '2x' }, { config: '{}' }, { config: 'null' }, { config: '[]' }, { config: '{"color":null}' }, { config: '{"color":1.2}' }, { config: '{"enableReminder":"false"}' }, { config: '{"secret":1}' }, { config: '{"color":1}', color: '2' }]) error(await f.run('Calendar.setConfig', { calendarId: '2', ...params }))
    assert.equal(f.calls.filter(c => c[0] === 'setConfig').length, before)
  })
  await test('default calendar deletion refusal and explicit confirmation', async () => {
    const before = f.calls.filter(c => c[0] === 'deleteCalendar').length
    for (const params of [{}, { confirm: 'true' }, { calendarId: '2' }, { calendarId: '2', confirm: 'TRUE' }, { calendarId: '1', confirm: 'true' }, { calendarId: '2x', confirm: 'true' }]) error(await f.run('CalendarManager.deleteCalendar', params))
    assert.equal(f.calls.filter(c => c[0] === 'deleteCalendar').length, before)
    assert.equal(await f.run('CalendarManager.deleteCalendar', { manager: 'vera-calendar-manager', calendarId: '3', confirm: 'true' }), 'ok')
    assert(!f.calendars.has(3))
  })
  await test('calendar deletion verifies persistence and refuses unavailable listings', async () => {
    const noop = fixture({ deleteCalendarNoop: true })
    assert.equal(await noop.run('CalendarManager.deleteCalendar', { calendarId: '2', confirm: 'true' }), 'error: calendar deletion was not confirmed')
    assert(noop.calendars.has(2))
    assert.deepEqual(noop.calls.map(c => c[0]), ['getCalendarManager', 'getAllCalendars', 'getCalendar', 'deleteCalendar', 'getAllCalendars'])
    const unavailable = fixture({ emptyCalendarListingAfterDeletion: true })
    assert.equal(await unavailable.run('CalendarManager.deleteCalendar', { calendarId: '2', confirm: 'true' }), 'error: calendar deletion verification unavailable')
    assert(!unavailable.calendars.has(2))
    assert(unavailable.calendars.has(1))
    assert.deepEqual(unavailable.calls.map(c => c[0]), ['getCalendarManager', 'getAllCalendars', 'getCalendar', 'deleteCalendar', 'getAllCalendars'])
    const success = fixture()
    assert.equal(await success.run('CalendarManager.deleteCalendar', { calendarId: '2', confirm: 'true' }), 'ok')
    assert(!success.calendars.has(2))
    assert(success.calendars.has(1))
    assert.deepEqual(success.calls.map(c => c[0]), ['getCalendarManager', 'getAllCalendars', 'getCalendar', 'deleteCalendar', 'getAllCalendars'])
  })
  await test('edit creation cancellation/failure and API26 availability', async () => {
    for (const result of [-1, -10]) { f.editResult(result); assert.equal(await f.run('CalendarManager.editEvent', epochEvent), 'cancelled') }
    for (const result of [0, undefined, NaN, 1.5]) { f.editResult(result); error(await f.run('CalendarManager.editEvent', epochEvent)) }
    f.editResult(88)
    assert.equal(await f.run('CalendarManager.editEvent', { ...epochEvent, manager: 'vera-calendar-manager' }), '88')
    assert.equal(await f.run('Calendar.openEventEditPage', { calendarId: '2', id: '90' }), 'ok')
    assert.deepEqual(f.calls.filter(c => c[0] === 'openEventEditPage').at(-1), ['openEventEditPage', 2, 90])
    const unsupported = fixture({ noOpen: true })
    error(await unsupported.run('Calendar.openEventEditPage', { id: '1' }), /API 26.*unavailable/)
  })
  await test('strict local dates, leap years and DST setter semantics', async () => {
    const oldZone = process.env.TZ
    process.env.TZ = 'America/New_York'
    try {
      for (const date of ['2026-02-29', '2026-04-31', '2026-13-01', '2026-00-01', '2026-01-00', '2026-1-01', 'bad', '0000-01-01']) error(await f.run('Calendar.addEvent', { ...legacy, date }))
      error(await f.run('Calendar.addEvent', { ...legacy, date: '2026-03-08', hour: '2', minute: '30' }), /DST transition/)
      for (const date of ['2026-03-08', '2026-11-01', '2024-02-29']) {
        const id = await f.run('Calendar.addEvent', { ...legacy, date, hour: '9', minute: '15' })
        assert.match(id, /^[0-9]+$/)
        const event = f.calendars.get(1).state.events.get(Number(id)), start = new Date(event.startTime)
        assert.equal(start.getHours(), 9)
        assert.equal(start.getMinutes(), 15)
        assert.equal(start.getDate(), Number(date.slice(8)))
        assert.equal(event.endTime - event.startTime, 3600000)
      }
      for (const params of [{ ...legacy, hour: '24' }, { ...legacy, minute: '60' }, { ...legacy, durationMinutes: '0' }, { ...epochEvent, hour: '9' }, { title: 'x', startTime: '1' }]) error(await f.run('Calendar.addEvent', params))
    } finally { if (oldZone === undefined) delete process.env.TZ; else process.env.TZ = oldZone }
  })
  await test('positive int32 IDs on every selector and native ID result', async () => {
    const g = fixture()
    const before = g.calls.filter(c => ['deleteEvent', 'deleteEvents', 'updateEvent', 'openEventEditPage', 'filterById', 'addEvents'].includes(c[0])).length
    for (const id of ['2147483648', '4294967297', '9007199254740991']) {
      for (const target of ['Calendar.deleteEvent', 'Calendar.updateEvent', 'Calendar.openEventEditPage']) error(await g.run(target, { id }))
      for (const target of ['Calendar.deleteEvents', 'EventFilter.filterById', 'Calendar.getEvents']) error(await g.run(target, { ids: '1,' + id }))
      error(await g.run('Calendar.getEvents', { eventFilter: JSON.stringify({ kind: 'id', ids: [id] }) }))
      error(await g.run('Calendar.queryEventInstances', { start: '1', end: '2', ids: id }))
      error(await g.run('CalendarManager.getCalendar', { calendarId: id }))
      error(await g.run('CalendarManager.deleteCalendar', { calendarId: id, confirm: 'true' }))
      error(await g.run('Calendar.addEvent', { ...legacy, calendarId: id }))
      error(await g.run('Calendar.addEvents', { events: JSON.stringify([epochEvent, { ...epochEvent, id }]) }))
    }
    assert.equal(g.calls.filter(c => ['deleteEvent', 'deleteEvents', 'updateEvent', 'openEventEditPage', 'filterById', 'addEvents'].includes(c[0])).length, before)
    assert.equal(await g.run('Calendar.deleteEvent', { id: '2147483647' }), 'ok')
    const wire = JSON.parse(await g.run('EventFilter.filterById', { ids: '2147483647' }))
    assert.deepEqual(wire.ids, ['2147483647'])
    const last = g.calls.filter(c => c[0] === 'getCalendarManager').length
    error(await g.run('Calendar.addEvent', { event: JSON.stringify({ ...epochEvent, id: '2147483648' }) }))
    assert.equal(g.calls.filter(c => c[0] === 'getCalendarManager').length, last + 1)
    for (const result of [-1, 0, undefined, NaN, 1.5, 2147483648]) {
      error(await fixture({ addId: result }).run('Calendar.addEvent', legacy))
      error(await fixture({ createId: result }).run('CalendarManager.createCalendar', { name: 'new' }))
      if (!(result < 0)) { g.editResult(result); error(await g.run('CalendarManager.editEvent', legacy)) }
    }
    assert.equal(await fixture({ addId: 2147483647 }).run('Calendar.addEvent', legacy), '2147483647')
    assert.equal(await fixture({ createId: 2147483647 }).run('CalendarManager.createCalendar', { name: 'new' }), '2147483647')
  })
  await test('exact native query argument counts and key-only DTO projection', async () => {
    const g = fixture()
    g.calendars.get(1).state.events.set(30, { id: 30, type: 0, title: 'Full', startTime: 1000, endTime: 2000, description: 'Private field' })
    for (const [params, counts] of [[{}, [0]], [{ ids: '30' }, [1]], [{ ids: '30', eventKey: 'id,title' }, [2]], [{ eventKey: 'id,title' }, [0, 2]]]) {
      const before = g.calls.filter(c => c[0] === 'getEvents').length
      const output = JSON.parse(await g.run('Calendar.getEvents', params))
      const queries = g.calls.filter(c => c[0] === 'getEvents').slice(before)
      assert.deepEqual(queries.map(c => c.length - 2), counts)
      if (params.eventKey) assert.deepEqual(output, [{ id: '30', title: 'Full' }])
      if (counts.length === 2) {
        assert.deepEqual(queries[1][2], { native: true, kind: 'id', ids: [30] })
        assert.deepEqual(queries[1][3], ['id', 'title'])
      }
    }
    for (const [params, count] of [[{}, 2], [{ ids: '30' }, 3], [{ ids: '30', eventKey: 'id' }, 4], [{ eventKey: 'id' }, 4]]) {
      const output = JSON.parse(await g.run('Calendar.queryEventInstances', { start: '1000', end: '2000', ...params }))
      const call = g.calls.filter(c => c[0] === 'queryEventInstances').at(-1)
      assert.equal(call.length - 2, count)
      if (params.eventKey) assert.deepEqual(output, [{ id: '30' }])
      if (params.eventKey && !params.ids) assert.deepEqual(call[4], [])
    }
    await assert.rejects(g.calendars.get(1).getEvents(undefined, undefined), /native filter/)
    await assert.rejects(g.calendars.get(1).getEvents({ native: true }, undefined), /keys array/)
    await assert.rejects(g.calendars.get(1).queryEventInstances(1, 2, undefined, ['id']), /IDs array/)
  })
  await test('keys-only queries refetch recurrence and lunar fields excluded by native defaults', async () => {
    const g = fixture()
    const rule = { recurrenceFrequency: 2, daysOfWeek: [1, 3] }
    g.calendars.get(2).state.events.set(31, { id: 31, type: 0, title: 'Weekly', startTime: 1000, endTime: 2000, recurrenceRule: rule, isLunar: true })
    g.calendars.get(2).state.events.set(32, { id: 32, type: 0, title: 'Regular', startTime: 3000, endTime: 4000, isLunar: false })
    const defaults = JSON.parse(await g.run('Calendar.getEvents', { calendarId: '2' }))
    for (const dto of defaults) {
      assert(!Object.hasOwn(dto, 'recurrenceRule'))
      assert(!Object.hasOwn(dto, 'isLunar'))
    }
    const before = g.calls.filter(c => c[0] === 'getEvents').length
    const output = JSON.parse(await g.run('Calendar.getEvents', { calendarId: '2', eventKey: 'id,recurrenceRule,isLunar' }))
    assert.deepEqual(output, [{ id: '31', recurrenceRule: rule, isLunar: true }, { id: '32', isLunar: false }])
    const queries = g.calls.filter(c => c[0] === 'getEvents').slice(before)
    assert.deepEqual(queries.map(c => c.length - 2), [0, 2])
    assert.equal(queries[0][1], 2)
    assert.equal(queries[1][1], 2)
    assert.deepEqual(queries[1][2], { native: true, kind: 'id', ids: [31, 32] })
    assert.deepEqual(queries[1][3], ['id', 'recurrenceRule', 'isLunar'])
    assert.deepEqual(g.calls.filter(c => c[0] === 'filterById').at(-1), ['filterById', [31, 32]])
    const empty = fixture()
    assert.deepEqual(JSON.parse(await empty.run('Calendar.getEvents', { eventKey: 'recurrenceRule,isLunar' })), [])
    assert.deepEqual(empty.calls.filter(c => c[0] === 'getEvents').map(c => c.length - 2), [0])
    assert.equal(empty.factories.length, 0)
  })
  await test('native recurrence sentinel, empty recurrence arrays and untitled update', async () => {
    const g = fixture()
    for (const [id, title] of [[40, undefined], [41, ''], [42, '   ']]) {
      g.calendars.get(1).state.events.set(id, { id, type: 0, title, startTime: 1000, endTime: 2000, recurrenceRule: { recurrenceFrequency: -1, weeksOfMonth: [], monthsOfYear: [] } })
      assert.equal(await g.run('Calendar.updateEvent', { id: String(id), description: 'changed' }), 'ok')
      const written = g.calls.filter(c => c[0] === 'updateEvent').at(-1)[2]
      assert.equal(written.title, title)
      assert.equal(written.recurrenceRule, undefined)
      assert.equal(await g.run('Calendar.updateEvent', { id: String(id), event: '{"description":"json patch"}' }), 'ok')
      const dto = JSON.parse(await g.run('Calendar.getEvents', { ids: String(id), eventKey: 'id,recurrenceRule' }))[0]
      assert.equal(dto.recurrenceRule, undefined)
      error(await g.run('Calendar.updateEvent', { id: String(id), title: '' }))
      error(await g.run('Calendar.updateEvent', { id: String(id), event: '{"title":""}' }))
    }
    const rule = { recurrenceFrequency: 2, daysOfWeek: [1, 3], weeksOfMonth: [], monthsOfYear: [], daysOfMonth: [2] }
    g.calendars.get(1).state.events.set(43, { id: 43, type: 0, title: 'Weekly', startTime: 1000, endTime: 2000, recurrenceRule: rule })
    assert.equal(await g.run('Calendar.updateEvent', { id: '43', description: 'preserve weekly' }), 'ok')
    const written = g.calls.filter(c => c[0] === 'updateEvent').at(-1)[2]
    assert.deepEqual(written.recurrenceRule.daysOfWeek, [1, 3])
    assert.equal(written.recurrenceRule.weeksOfMonth, undefined)
    assert.equal(written.recurrenceRule.monthsOfYear, undefined)
    const before = g.calls.filter(c => c[0] === 'updateEvent').length
    for (const repeat of ['once', 'none']) error(await g.run('Calendar.updateEvent', { id: '43', repeat }), /unsupported/)
    error(await g.run('Calendar.updateEvent', { id: '43', event: '{"recurrenceRule":{"recurrenceFrequency":-1}}' }))
    assert.equal(g.calls.filter(c => c[0] === 'updateEvent').length, before)
    assert.equal(g.calls.filter(c => c[0] === 'addEvent').length, 0)
    error(await g.run('Calendar.addEvent', { event: JSON.stringify({ startTime: '1000', endTime: '2000' }) }))
  })
  await test('duration-only preserves seconds and second DST fold, location member merges', async () => {
    const g = fixture(), oldZone = process.env.TZ
    process.env.TZ = 'America/New_York'
    try {
      const start = new Date('2026-11-01T01:30:45.123-05:00').getTime()
      g.calendars.get(1).state.events.set(50, { id: 50, type: 0, title: 'Fold', startTime: start, endTime: start + 3600000, location: { location: 'Old', longitude: 12.5, latitude: -30 } })
      assert.equal(await g.run('Calendar.updateEvent', { id: '50', durationMinutes: '90' }), 'ok')
      let event = g.calendars.get(1).state.events.get(50)
      assert.equal(event.startTime, start)
      assert.equal(event.endTime, start + 90 * 60000)
      assert.equal(await g.run('Calendar.updateEvent', { id: '50', location: 'New' }), 'ok')
      event = g.calendars.get(1).state.events.get(50)
      assert.deepEqual({ ...event.location }, { location: 'New', longitude: 12.5, latitude: -30 })
      assert.equal(await g.run('Calendar.updateEvent', { id: '50', event: '{"location":{"latitude":10}}' }), 'ok')
      event = g.calendars.get(1).state.events.get(50)
      assert.deepEqual({ ...event.location }, { location: 'New', longitude: 12.5, latitude: 10 })
      assert.equal(await g.run('Calendar.updateEvent', { id: '50', event: '{"location":{"location":"JSON"}}' }), 'ok')
      event = g.calendars.get(1).state.events.get(50)
      assert.deepEqual({ ...event.location }, { location: 'JSON', longitude: 12.5, latitude: 10 })
      assert.equal(event.startTime, start)
      error(await g.run('Calendar.updateEvent', { id: '50', event: '{"location":{"longitude":181}}' }))
      assert.equal(await g.run('Calendar.updateEvent', { id: '50', hour: '9' }), 'ok')
      event = g.calendars.get(1).state.events.get(50)
      assert.equal(new Date(event.startTime).getHours(), 9)
      assert.equal(new Date(event.startTime).getSeconds(), 0)
      assert.equal(event.endTime - event.startTime, 90 * 60000)
    } finally { if (oldZone === undefined) delete process.env.TZ; else process.env.TZ = oldZone }
  })
  await test('void completion means ok without claiming verified native persistence', async () => {
    const g = fixture({ voidNoop: true })
    const event = { id: 60, type: 0, title: 'Unchanged', startTime: 1000, endTime: 2000 }
    g.calendars.get(1).state.events.set(60, event)
    assert.equal(await g.run('Calendar.deleteEvent', { id: '60' }), 'ok')
    assert.equal(await g.run('Calendar.updateEvent', { id: '60', title: 'Changed' }), 'ok')
    assert.deepEqual(g.calendars.get(1).state.events.get(60), event)
    assert.equal(g.calls.filter(c => c[0] === 'getEvents').length, 1)
  })
  await test('real public backend routes Calendar exports and leaves noncalendar dispatch intact', async () => {
    const g = fixture(), backend = g.backend()
    const run = (target, params = {}) => backend.runSdkAdapter(target, new Map(Object.entries(params)))
    for (const target of g.api.calendarSdkTargets) assert.equal(backend.isSdkTargetImplemented(target), true, target)
    assert.equal(backend.isSdkTargetImplemented('CalendarKit.missing'), false)
    assert.equal(await run('CalendarKit.missing'), 'error: sdk.call is not implemented yet')
    assert.equal(backend.isSdkTargetImplemented('Missing.target'), false)
    assert.equal(await run('Missing.target'), 'error: sdk.call is not implemented yet')
    assert.equal(backend.isSdkTargetImplemented('CoreFileKit.storageStatistics.getFreeSizeSync'), true)
    assert.equal(await run('CoreFileKit.storageStatistics.getFreeSizeSync'), '4096')
    assert.equal(await run('CalendarKit.CalendarManager.getCalendar'), '1')
    const id = await run('CalendarKit.Calendar.addEvent', epochEvent)
    assert.match(id, /^[0-9]+$/)
    const wire = await run('CalendarKit.EventFilter.filterById', { ids: id })
    assert.deepEqual(JSON.parse(wire), { kind: 'id', ids: [id] })
    assert.equal(JSON.parse(await run('CalendarKit.Calendar.getEvents', { eventFilter: wire }))[0].id, id)
    g.fail('getEvents', 201, 'native permission denied')
    assert.equal(await run('CalendarKit.Calendar.getEvents'), 'error: 201: native permission denied')
    g.clearFailure()
    assert.equal(await run('CalendarKit.Calendar.deleteEvent', { id }), 'ok')
    const cases = [
      ['calendarManager.getCalendarManager', {}, 'vera-calendar-manager'],
      ['CalendarManager.createCalendar', { name: 'backend' }, '3'],
      ['CalendarManager.getAllCalendars', {}, 'json'],
      ['CalendarManager.editEvent', epochEvent, '77'],
      ['Calendar.addEvents', { events: JSON.stringify([epochEvent]) }, 'ok'],
      ['Calendar.deleteEvents', { ids: '999' }, 'ok'],
      ['Calendar.queryEventInstances', { start: epochEvent.startTime, end: epochEvent.endTime, eventKey: 'id' }, 'json'],
      ['Calendar.getConfig', {}, 'json'],
      ['Calendar.setConfig', { enableReminder: 'false' }, 'ok'],
      ['Calendar.getAccount', {}, 'json'],
      ['Calendar.openEventEditPage', { id: '11' }, 'ok'],
      ['EventFilter.filterByTime', { start: epochEvent.startTime, end: epochEvent.endTime }, 'json'],
      ['EventFilter.filterByTitle', { title: 'Planning' }, 'json'],
      ['Calendar.updateEvent', { id: '11', title: 'Updated via backend' }, 'ok'],
      ['CalendarManager.deleteCalendar', { calendarId: '3', confirm: 'true' }, 'ok']
    ]
    for (const [target, params, expected] of cases) {
      const result = await run('CalendarKit.' + target, params)
      if (expected === 'json') assert.doesNotThrow(() => JSON.parse(result), result)
      else assert.equal(result, expected, target)
    }
  })
  await test('every target exercised and no out-of-scope integration edits needed', async () => {
    assert.deepEqual(f.api.calendarSdkTargets.filter(target => !f.coverage.has(target)), [])
    error(await f.run('Calendar.addEvent', { ...legacy, unrecognized: 'value' }), /unsupported parameter/)
  })
  console.log(checks.length + ' checks passed; ' + f.api.calendarSdkTargets.length + ' targets exercised')
})().catch(error => { console.error(error.stack); process.exitCode = 1 })
