// std/time.atLocalTime through the real compiler/VM in explicit timezones. No device or model calls.
'use strict'
const assert = require('node:assert/strict')
const {spawnSync} = require('node:child_process')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VirtualMachine, deserializeVbc2, VeraNumberValue, VeraStringValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment} = loadVera('VeraUi')
const source = 'import * as time from "std/time"\n' +
  '@jsonable class AppState { day: number; }\n' +
  'function init(): AppState { return {day: time.daysSinceEpoch()}; }\n' +
  'function at(day: number, minute: number): number { return time.atLocalTime(day, minute); }'
const compiled = compileVeraSource(source)
const host = new UiHostEnvironment()
const vm = new VirtualMachine(deserializeVbc2(compiled.vbc2), host)
const num = n => new VeraNumberValue(n)
const at = (day, minute) => vm.execute('at', [num(day), num(minute)]).value
const dayOf = (y, m, d) => {
  const date = new Date(0); date.setUTCFullYear(y, m - 1, d); date.setUTCHours(0, 0, 0, 0)
  return date.getTime() / 86400000
}
const zones = ['UTC', 'America/New_York', 'Asia/Kathmandu', 'Australia/Lord_Howe', 'Pacific/Apia']
if (!process.argv.includes('--zone')) {
  for (const zone of zones) {
    const run = spawnSync(process.execPath, [__filename, '--zone'], {
      env: {...process.env, TZ: zone}, encoding: 'utf8', timeout: 30000
    })
    assert.equal(run.status, 0, zone + ': ' + run.stdout + run.stderr)
    process.stdout.write(run.stdout)
  }
  assert.throws(() => compileVeraSource(source.replace('time.atLocalTime(day, minute)', 'time.atLocalTime("today", minute)')),
    e => e.diagnostics && e.diagnostics.length > 0)
  assert.throws(() => compileVeraSource(source.replace('time.atLocalTime(day, minute)', 'time.atLocalTime(day)')),
    e => e.diagnostics && e.diagnostics.length > 0)
  for (const [day, minute] of [[0,-1],[0,1440],[1000001,0],[-1000001,0],[0.5,0],[0,1.5],[NaN,0],[0,Infinity]]) {
    assert.throws(() => at(day, minute), e => e.trapCode === 'R0009', JSON.stringify([day,minute]))
  }
  assert.throws(() => host.invoke('std/time', 'atLocalTime', [new VeraStringValue('today'), num(0)], false),
    e => e.trapCode === 'R0020')
  for (const day of [-1000000, 1000000]) assert(Number.isFinite(at(day, 1439)), 'inclusive day bound')
  console.log('local-date-time-check: compiler signatures, whole/range/type guards and five timezone processes: ok')
} else {
  const zone = process.env.TZ
  const offset = {UTC:0, 'America/New_York':300, 'Asia/Kathmandu':-345, 'Australia/Lord_Howe':-660, 'Pacific/Apia':-780}
  assert.equal(new Date('2026-01-15T12:00:00Z').getTimezoneOffset(), offset[zone], 'requested timezone must be active')
  for (const [y,m,d] of [[1970,1,1],[1969,12,31],[2024,2,29],[2026,3,7],[2026,3,8],[2026,3,9],
    [2026,11,1],[2026,11,2],[2026,4,5],[2026,10,4],[99,6,15],[0,1,1]]) {
    for (const minute of [0, 480, 1439]) {
      const stamp = at(dayOf(y,m,d), minute), local = new Date(stamp)
      assert.deepEqual([local.getFullYear(),local.getMonth()+1,local.getDate(),local.getHours(),local.getMinutes(),local.getSeconds(),local.getMilliseconds()],
        [y,m,d,Math.floor(minute/60),minute%60,0,0], zone + ': selected date/time round trip')
    }
  }
  if (zone === 'UTC') assert.equal(at(0,0), 0)
  if (zone === 'America/New_York') {
    assert.equal(at(dayOf(2026,3,8),150), Date.parse('2026-03-08T07:30:00Z'), '02:30 spring gap advances to 03:30')
    assert.equal(at(dayOf(2026,11,1),90), Date.parse('2026-11-01T05:30:00Z'), 'fall overlap chooses earlier 01:30')
    assert.equal(at(dayOf(2026,3,8),480)-at(dayOf(2026,3,7),480), 23*3600000)
    assert.equal(at(dayOf(2026,11,1),480)-at(dayOf(2026,10,31),480), 25*3600000)
  }
  if (zone === 'Asia/Kathmandu') assert.equal(at(dayOf(2026,1,15),480), Date.parse('2026-01-15T02:15:00Z'))
  if (zone === 'Australia/Lord_Howe') {
    assert.equal(at(dayOf(2026,10,4),135), Date.parse('2026-10-03T15:45:00Z'), 'half-hour gap: 02:15 becomes 02:45')
  }
  if (zone === 'Pacific/Apia') {
    assert.equal(at(dayOf(2011,12,30),480), Date.parse('2011-12-30T18:00:00Z'), 'skipped date advances by the 24-hour gap')
    const next = new Date(at(dayOf(2011,12,31),480))
    assert.equal(next.getDate(), 31, 'valid date after skipped date remains intact')
  }
  console.log('PASS ' + zone)
}
