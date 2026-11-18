import {
  RuntimeValue,
  VeraNumberValue,
  VeraStringValue,
  VeraBooleanValue,
  VeraNullValue,
  VeraArrayValue,
  VeraObjectValue,
  NULL_VALUE,
  HostEnvironment,
  RuntimeTrap,
} from './VeraInterpreter'
import { resolveStyle } from './VeraUiCatalog'
import { invokeStdGfx } from './VeraGfx'
import { invokeStdScene } from './VeraScene'

export class VeraUiNode {
  id: number = 0
  kind: string = ''
  style: string = ''
  text: string = ''
  source: string = ''
  alt: string = ''
  action: string = ''
  eventValue: number = 0
  enabled: boolean = true
  commands: string = ''
  spinPeriodMs: number = 0
  label: string = ''
  tickerId: string = ''
  columns: number = 1
  value: string = ''
  checked: boolean = false
  minimum: number = 0
  maximum: number = 100
  options: string[] = []
  /** A chart's raw values, for ui.Sparkline -- the one number[] prop in the language. */
  series: number[] = []
  /** ui.Sparkline: draw series as separate bars instead of a connected line. */
  bars: boolean = false
  /** ui.Sparkline: a second line to compare against series; empty for a single-series chart. */
  series2: number[] = []
  /** ui.Sparkline: series2's tone, from the same style set as the chart itself. */
  series2Style: string = ''
  /** ui.Sparkline: legend text for series, shown only when series2 is non-empty. */
  seriesLabel: string = ''
  /** ui.Sparkline: legend text for series2. */
  series2Label: string = ''
  /** ui.Sparkline: x-axis labels, one per point; empty for a plain trend with no axis. */
  categories: string[] = []
  children: VeraUiNode[] = []

  /**
   * The typed numeric layer: the number itself and how to show it, formatted by
   * formatVeraNumber. `numberValue` is the number; `eventValue` stays the
   * payload of a tap, so a row can carry both. decimals -1 means "as it is".
   */
  numberValue: number = 0
  prefix: string = ''
  suffix: string = ''
  minimumDigits: number = 1
  decimals: number = -1
  /** How much one tap of a ui.NumberField's - or + changes it; 1 when the program leaves it off. */
  step: number = 1

  /** The name of an icon in VeraIcons; '' for none. */
  icon: string = ''

  /** ui.TextField validation; see VeraUiCatalog's guidance for the component. */
  keyboardType: string = ''
  required: boolean = false
  requiredMessage: string = ''
  minLength: number = 0
  minLengthMessage: string = ''
  maxLength: number = -1
  maxLengthMessage: string = ''
  pattern: string = ''
  patternMessage: string = ''
  email: boolean = false
  emailMessage: string = ''
}

/**
 * A number as text: `decimals` fixed places (-1: as it is, without binary
 * noise such as 0.30000000000000004), the whole part padded with zeros to
 * minimumDigits. Shared by ui.numberToString, ui.formatNumber and the
 * renderer's number components, so all three write numbers the same way.
 */
export function formatVeraNumber(n: number, decimals: number, minimumDigits: number): string {
  if (!isFinite(n)) { return n.toString() }
  let negative = n < 0
  let a = Math.abs(n)
  let text = decimals >= 0 ? a.toFixed(Math.min(Math.floor(decimals), 10))
    : (Number.isInteger(a) ? a.toString() : parseFloat(a.toFixed(9)).toString())
  let dot = text.indexOf('.')
  let whole = dot >= 0 ? text.substring(0, dot) : text
  let rest = dot >= 0 ? text.substring(dot) : ''
  while (whole.length < minimumDigits) { whole = '0' + whole }
  // -0.00 reads as a bug; a value that rounds to zero is just zero.
  let zero = parseFloat(whole + rest) === 0
  return (negative && !zero ? '-' : '') + whole + rest
}

/**
 * The unit after a shown number, as it reads after that number: " days" after 1 is " day", and the space
 * before a unit does not break, so "38 °C" never ends a line at "38". Only a unit that is one plain English word
 * in the plural is made singular; a symbol, an abbreviation or several words is left as the program wrote it.
 */
export function unitAfter(n: number, suffix: string): string {
  let text = suffix
  if (Math.abs(n) === 1) {
    let m = /^(\s*)([A-Za-z]+)$/.exec(text)
    if (m !== null && m[2].length > 2) {
      let word = m[2]
      let lower = word.toLowerCase()
      // "-ies" loses only its s: calories, cookies and minutes outnumber berries in what a tracker counts.
      if (/(ss|sh|ch|x|z)es$/.test(lower)) { word = word.substring(0, word.length - 2) }
      else if (/[^su]s$/.test(lower)) { word = word.substring(0, word.length - 1) }
      text = m[1] + word
    }
  }
  return text.length > 0 && text.charAt(0) === ' ' ? ' ' + text.substring(1) : text
}

/** Text with the space between a number and a degree or percent sign made unbreakable: "38 °C", never "38" then "°C". */
export function keepUnits(text: string): string {
  return text.replace(/(\d) (?=[°%])/g, '$1\u00A0')
}

/**
 * Minutes since midnight as HH:MM, wrapped into one day; what ui.ClockText
 * draws and ui.clockToString returns, so a time reads the same in both.
 */
export function formatVeraClock(total: number): string {
  let m = isFinite(total) && total > 0 ? Math.floor(total) % 1440 : 0
  let h = Math.floor(m / 60)
  let mm = m % 60
  return (h < 10 ? '0' : '') + h.toString() + ':' + (mm < 10 ? '0' : '') + mm.toString()
}

const MONTH_NAMES: string[] =
  ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/**
 * A local day number -- what time.daysSinceEpoch() returns and ui.DateField
 * holds -- as "30 Oct 2026": what the field draws and ui.dateToString returns.
 * Day first and the month as a word, so it cannot be misread either way round.
 */
export function formatVeraDate(day: number): string {
  let d = new Date((isFinite(day) ? Math.floor(day) : 0) * 86400000)
  return d.getUTCDate().toString() + ' ' + MONTH_NAMES[d.getUTCMonth()] + ' ' + d.getUTCFullYear().toString()
}

/**
 * A length of time in seconds as M:SS, or H:MM:SS from an hour up, fractions
 * dropped and negatives shown as 0:00: a countdown's "6:00", which ClockText
 * (a time of day) cannot show.
 */
export function formatVeraDuration(seconds: number): string {
  let s = isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0
  let h = Math.floor(s / 3600)
  let m = Math.floor((s % 3600) / 60)
  let ss = s % 60
  let tail = (ss < 10 ? ':0' : ':') + ss.toString()
  if (h === 0) { return m.toString() + tail }
  return h.toString() + (m < 10 ? ':0' : ':') + m.toString() + tail
}

function asString(v: RuntimeValue): string {
  if (v instanceof VeraStringValue) { return (v as VeraStringValue).value }
  throw new RuntimeTrap('R0020', 'expected string argument')
}

function asNum(v: RuntimeValue): number {
  if (v instanceof VeraNumberValue) { return (v as VeraNumberValue).value }
  throw new RuntimeTrap('R0020', 'expected number argument')
}

/** A number that has to be whole -- a position in a string -- or a trap saying so. */
function asWhole(v: RuntimeValue): number {
  let n = asNum(v)
  if (!Number.isInteger(n)) { throw new RuntimeTrap('R0009', 'expected a whole number, got ' + n.toString()) }
  return n
}

function asBool(v: RuntimeValue): boolean {
  if (v instanceof VeraBooleanValue) { return (v as VeraBooleanValue).value }
  throw new RuntimeTrap('R0020', 'expected boolean argument')
}

function asArray(v: RuntimeValue): VeraArrayValue {
  if (v instanceof VeraArrayValue) { return v as VeraArrayValue }
  throw new RuntimeTrap('R0020', 'expected array argument')
}

/**
 * Reading an argument that a saved program may not have passed.
 *
 * The VM hands `invoke` exactly the arguments the bytecode pushed, so the day a
 * component gains a property, every program compiled before that day calls it
 * one argument short and asString(undefined) traps. The programs are stored as
 * bytecode, not source, so they cannot be recompiled -- a saved app would simply
 * stop running.
 *
 * Reading past the end as "not given" is what makes the vocabulary extensible:
 * a property may be appended to any component for ever after, old programs keep
 * running with the default, and new ones still have to pass it because the
 * compiler checks arity (E2036) against the catalogue.
 */
function argString(args: RuntimeValue[], i: number, fallback: string = ''): string {
  if (i >= args.length) { return fallback }
  return asString(args[i])
}

function argNum(args: RuntimeValue[], i: number, fallback: number = 0): number {
  if (i >= args.length) { return fallback }
  return asNum(args[i])
}

function argBool(args: RuntimeValue[], i: number, fallback: boolean = true): boolean {
  if (i >= args.length) { return fallback }
  return asBool(args[i])
}

function argArray(args: RuntimeValue[], i: number): VeraArrayValue {
  if (i >= args.length) { return new VeraArrayValue([]) }
  return asArray(args[i])
}

function viewNode(type: string, fields: Array<[string, RuntimeValue]>): VeraObjectValue {
  let map = new Map<string, RuntimeValue>()
  map.set('type', new VeraStringValue(type))
  for (let pair of fields) {
    map.set(pair[0], pair[1])
  }
  return new VeraObjectValue('std/ui:View', map)
}

function containerNode(type: string, args: RuntimeValue[]): RuntimeValue {
  return viewNode(type, [
    ['style', new VeraStringValue(argString(args, 0))],
    ['children', argArray(args, 1)],
  ])
}

/**
 * The clock, as seen by a generated program. Local time, every value a number;
 * nowMillis is Unix milliseconds, exact in a double.
 * daysSinceEpoch is what makes "is this the same day as the last dose?"
 * expressible without any date arithmetic in the language.
 */
function invokeStdTime(name: string, args: RuntimeValue[]): RuntimeValue {
  let now = new Date()
  switch (name) {
    case 'nowMillis':
      return new VeraNumberValue(now.getTime())
    case 'nowSeconds':
      return new VeraNumberValue(Math.floor(now.getTime() / 1000))
    case 'daysSinceEpoch':
      // Local midnights, not UTC: a dose taken at 23:30 belongs to that day for
      // the person holding the phone.
      return new VeraNumberValue(Math.floor(
        (now.getTime() - now.getTimezoneOffset() * 60000) / 86400000))
    case 'millisOfDay':
      // Milliseconds since local midnight.
      return new VeraNumberValue(
        ((now.getHours() * 60 + now.getMinutes()) * 60 + now.getSeconds()) * 1000 +
        now.getMilliseconds())
    case 'hourOfDay': return new VeraNumberValue(now.getHours())
    case 'minuteOfHour': return new VeraNumberValue(now.getMinutes())
    case 'weekday': return new VeraNumberValue(now.getDay())
    // daysSinceEpoch can say "the same day" but not "which day". Anything read
    // back later -- a history row, a summary shown to another person -- needs
    // to name the date, so these three are the calendar.
    case 'dayOfMonth': return new VeraNumberValue(now.getDate())
    case 'monthOfYear': return new VeraNumberValue(now.getMonth() + 1)
    case 'year': return new VeraNumberValue(now.getFullYear())
    default:
      throw new RuntimeTrap('R0015', `unknown std/time function: ${name}`)
  }
}

function asNumberArg(v: RuntimeValue): number {
  if (v instanceof VeraNumberValue) { return (v as VeraNumberValue).value }
  throw new RuntimeTrap('R0020', 'expected number argument')
}

/**
 * Arithmetic the language cannot express, plus a deterministic generator.
 *
 * randomStep is xorshift32 done with JS bitwise operators, which wrap by
 * definition; its result is a whole number in the signed 32-bit range.
 */
function invokeStdMath(name: string, args: RuntimeValue[]): RuntimeValue {
  switch (name) {
    case 'pi': return new VeraNumberValue(Math.PI)
    case 'sqrt': return new VeraNumberValue(Math.sqrt(asNumberArg(args[0])))
    case 'sin': return new VeraNumberValue(Math.sin(asNumberArg(args[0])))
    case 'cos': return new VeraNumberValue(Math.cos(asNumberArg(args[0])))
    case 'atan2': return new VeraNumberValue(Math.atan2(asNumberArg(args[0]), asNumberArg(args[1])))
    case 'pow': return new VeraNumberValue(Math.pow(asNumberArg(args[0]), asNumberArg(args[1])))
    case 'floor': return new VeraNumberValue(Math.floor(asNumberArg(args[0])))
    case 'round': return new VeraNumberValue(Math.round(asNumberArg(args[0])))
    case 'ceil': return new VeraNumberValue(Math.ceil(asNumberArg(args[0])))
    case 'abs': return new VeraNumberValue(Math.abs(asNumberArg(args[0])))
    case 'min': return new VeraNumberValue(Math.min(asNumberArg(args[0]), asNumberArg(args[1])))
    case 'max': return new VeraNumberValue(Math.max(asNumberArg(args[0]), asNumberArg(args[1])))
    case 'randomStep': {
      let x = asNum(args[0]) | 0
      if (x === 0) { x = 0x2545F491 }
      x = x ^ (x << 13); x = x ^ (x >>> 17); x = x ^ (x << 5)
      return new VeraNumberValue(x | 0)
    }
    case 'randomBelow': {
      let seed = asNum(args[0]) | 0
      let bound = Math.floor(asNum(args[1]))
      if (bound <= 0) { throw new RuntimeTrap('R0026', 'randomBelow needs a positive bound') }
      return new VeraNumberValue(Math.abs(seed) % bound)
    }
    default:
      throw new RuntimeTrap('R0015', `unknown std/math function: ${name}`)
  }
}

/**
 * Text, per the `std/strings` library in VERA-L.md.
 *
 * The language gives a string only `+`, comparison, `.length()` and for-of over
 * its characters, so a program could assemble text but never take it apart.
 *
 * Positions here are Unicode scalar values, as the spec requires, not the
 * UTF-16 code units ArkTS counts -- hence the Array.from before any indexing.
 * The `.length()` intrinsic still counts code units, so it and strings.length
 * disagree on an emoji and agree on everything in the BMP; for-of over a string
 * already counts scalars, so this side is the one with two allies.
 */
function scalars(s: string): string[] {
  return Array.from(s)
}

/**
 * Unicode White_Space. ArkTS's own trim() follows the ECMAScript definition,
 * which omits U+0085, so the set is spelled out rather than delegated.
 */
function isSpace(ch: string): boolean {
  let c = ch.charCodeAt(0)
  if (c === 0x20 || (c >= 0x09 && c <= 0x0D)) { return true }
  if (c === 0x85 || c === 0xA0 || c === 0x1680) { return true }
  if (c >= 0x2000 && c <= 0x200A) { return true }
  return c === 0x2028 || c === 0x2029 || c === 0x202F || c === 0x205F || c === 0x3000
}

function invokeStdStrings(name: string, args: RuntimeValue[]): RuntimeValue {
  switch (name) {
    case 'length':
      return new VeraNumberValue(scalars(asString(args[0])).length)
    case 'substring': {
      let chars = scalars(asString(args[0]))
      let start = asWhole(args[1])
      let end = asWhole(args[2])
      // The spec raises rather than clamping: a bad range is a bug in the
      // program, and silently returning a shorter string hides it.
      if (start < 0 || end < start || end > chars.length) {
        throw new RuntimeTrap('R0009', 'string index out of bounds')
      }
      return new VeraStringValue(chars.slice(start, end).join(''))
    }
    case 'contains':
      return new VeraBooleanValue(asString(args[0]).indexOf(asString(args[1])) >= 0)
    case 'startsWith':
      return new VeraBooleanValue(asString(args[0]).startsWith(asString(args[1])))
    case 'endsWith':
      return new VeraBooleanValue(asString(args[0]).endsWith(asString(args[1])))
    case 'replace': {
      let text = asString(args[0])
      let from = asString(args[1])
      let to = asString(args[2])
      // An empty needle would match at every position forever.
      if (from.length === 0) { return new VeraStringValue(text) }
      let out = ''
      let i = 0
      while (i < text.length) {
        let hit = text.indexOf(from, i)
        if (hit < 0) { out += text.substring(i); break }
        out += text.substring(i, hit) + to
        i = hit + from.length
      }
      return new VeraStringValue(out)
    }
    case 'split': {
      let text = asString(args[0])
      let sep = asString(args[1])
      let parts: RuntimeValue[] = []
      if (sep.length === 0) {
        for (let ch of scalars(text)) { parts.push(new VeraStringValue(ch)) }
        return new VeraArrayValue(parts)
      }
      let i = 0
      while (true) {
        let hit = text.indexOf(sep, i)
        if (hit < 0) { parts.push(new VeraStringValue(text.substring(i))); break }
        parts.push(new VeraStringValue(text.substring(i, hit)))
        i = hit + sep.length
      }
      return new VeraArrayValue(parts)
    }
    case 'toNumber': {
      // Typed text as a number: spaces dropped, a decimal comma accepted, and
      // anything that is not a plain number gives the fallback.
      let text = asString(args[0]).replace(/\s/g, '')
      if (text.indexOf('.') < 0) { text = text.replace(',', '.') }
      if (!/^[+-]?(\d+\.?\d*|\.\d+)$/.test(text)) { return new VeraNumberValue(asNum(args[1])) }
      return new VeraNumberValue(parseFloat(text))
    }
    case 'toUpperCase':
      return new VeraStringValue(asString(args[0]).toUpperCase())
    case 'toLowerCase':
      return new VeraStringValue(asString(args[0]).toLowerCase())
    case 'trim': {
      let chars = scalars(asString(args[0]))
      let start = 0
      let end = chars.length
      while (start < end && isSpace(chars[start])) { start++ }
      while (end > start && isSpace(chars[end - 1])) { end-- }
      return new VeraStringValue(chars.slice(start, end).join(''))
    }
    default:
      throw new RuntimeTrap('R0015', `unknown std/strings function: ${name}`)
  }
}

/**
 * One sdk.call the program asked for, waiting to be run.
 *
 * The VM is synchronous -- invoke() has to return a value on the spot -- while
 * the platform answers with a promise. So the call does not run itself; it
 * records the request, and whoever drives the VM runs it afterwards and brings
 * the answer back through the ordinary handler path.
 */
export class HostEffect {
  id: number
  /** Which host the request is for; only 'sdk' exists now. */
  kind: string
  /** Which function of that host: always call. */
  fn: string
  values: Map<string, string>
  resultHandler: string
  /** The target as the program wrote it. */
  rawTarget: string = ''
  /** The parameter names, in the order the program wrote them. */
  rawParams: string = ''
  /** 'foreground' or 'background'; only an intent-style target uses it. */
  rawMode: string = ''
  constructor(id: number, kind: string, fn: string,
      values: Map<string, string>, resultHandler: string) {
    this.id = id; this.kind = kind; this.fn = fn
    this.values = values; this.resultHandler = resultHandler
  }
}

export class UiHostEnvironment extends HostEnvironment {
  /** Requests made during the handler that is running now. */
  pendingEffects: HostEffect[] = []
  /**
   * Whether an effect may be requested at all: true while a handler runs, false
   * while view() runs. view is a pure function of state and is re-run on every
   * change, so an intent call from there would start navigation on every
   * repaint.
   */
  effectsAllowed: boolean = false
  private nextEffectId: number = 1

  invoke(module: string, name: string, args: RuntimeValue[], awaited: boolean): RuntimeValue {
    if (module === 'std/time') { return invokeStdTime(name, args) }
    if (module === 'std/math') { return invokeStdMath(name, args) }
    if (module === 'std/strings') { return invokeStdStrings(name, args) }
    if (module === 'std/sdk') { return this.queueSdk(args) }
    if (module === 'std/gfx') { return invokeStdGfx(name, args) }
    if (module === 'std/scene') { return invokeStdScene(name, args) }
    if (module !== 'std/ui') {
      throw new RuntimeTrap('R0015', `external function unavailable: ${module}.${name}`)
    }
    switch (name) {
      case 'Column': return containerNode('column', args)
      case 'Row': return containerNode('row', args)
      case 'Card': return containerNode('card', args)
      case 'Scroll': return containerNode('scroll', args)
      case 'Canvas': return containerNode('canvas', args)
      case 'Transform':
        // The pose is the one array prop (series), the glide duration rides numberValue, the side of the layer minimum (as Skeleton's width).
        return viewNode('transform', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['series', argArray(args, 1)],
          ['numberValue', new VeraNumberValue(argNum(args, 2))],
          ['minimum', new VeraNumberValue(argNum(args, 3))],
          ['children', argArray(args, 4)],
        ])
      case 'Stage':
        // ui.Stage is gone (solid bodies are ui.World now); bytecode saved before that still names it: a plain column of its content.
        return viewNode('column', [
          ['style', new VeraStringValue('default')],
          ['children', argArray(args, 3)],
        ])
      case 'Layers':
        return viewNode('layers', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['minimum', new VeraNumberValue(argNum(args, 1))],
          ['maximum', new VeraNumberValue(argNum(args, 2))],
          ['children', argArray(args, 3)],
        ])
      case 'Motion':
        // The preset is the style; the trigger rides numberValue, as other components reuse an existing field.
        return viewNode('motion', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['numberValue', new VeraNumberValue(argNum(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'Text':
        return viewNode('text', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
        ])
      case 'Spacer':
        return viewNode('spacer', [
          ['style', new VeraStringValue(argString(args, 0))],
        ])
      case 'Image':
        return viewNode('image', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['src', new VeraStringValue(argString(args, 1))],
          ['alt', new VeraStringValue(argString(args, 2))],
        ])
      case 'Path':
        return viewNode('path', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['commands', new VeraStringValue(argString(args, 1))],
          ['spinPeriodMs', new VeraNumberValue(argNum(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
          ['value', new VeraNumberValue(argNum(args, 4))],
        ])
      case 'TextField':
        return viewNode('field', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['value', new VeraStringValue(argString(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
          ['keyboardType', new VeraStringValue(argString(args, 4))],
          ['required', new VeraBooleanValue(argBool(args, 5, false))],
          ['requiredMessage', new VeraStringValue(argString(args, 6))],
          ['minLength', new VeraNumberValue(argNum(args, 7, 0))],
          ['minLengthMessage', new VeraStringValue(argString(args, 8))],
          ['maxLength', new VeraNumberValue(argNum(args, 9, -1))],
          ['maxLengthMessage', new VeraStringValue(argString(args, 10))],
          ['pattern', new VeraStringValue(argString(args, 11))],
          ['patternMessage', new VeraStringValue(argString(args, 12))],
          ['email', new VeraBooleanValue(argBool(args, 13, false))],
          ['emailMessage', new VeraStringValue(argString(args, 14))],
        ])
      case 'Toggle':
      case 'Checkbox':
        return viewNode(name === 'Toggle' ? 'toggle' : 'checkbox', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['checked', new VeraBooleanValue(argBool(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
        ])
      case 'Slider':
        return viewNode('slider', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['value', new VeraNumberValue(argNum(args, 2))],
          ['minimum', new VeraNumberValue(argNum(args, 3))],
          ['maximum', new VeraNumberValue(argNum(args, 4))],
          ['action', new VeraStringValue(argString(args, 5))],
        ])
      case 'Select':
        return viewNode('select', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['options', argArray(args, 2)],
          ['value', new VeraNumberValue(argNum(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
        ])
      case 'Tabs':
        return viewNode('tabs', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['options', argArray(args, 1)],
          ['value', new VeraNumberValue(argNum(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
          ['children', argArray(args, 4)],
        ])
      case 'Grid':
        return viewNode('grid', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['columns', new VeraNumberValue(argNum(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'ListItem':
        return viewNode('listitem', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
          ['eventValue', new VeraNumberValue(argNum(args, 5))],
          ['enabled', new VeraBooleanValue(argBool(args, 6))],
          ['icon', new VeraStringValue(argString(args, 7))],
        ])
      case 'Surface':
        // The surface's own units ride minimum and maximum, the draw function label, the frame handler action and
        // the pointer handler value: VeraPreview reads them back under those names (see its surface branch).
        return viewNode('surface', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['minimum', new VeraNumberValue(argNum(args, 1))],
          ['maximum', new VeraNumberValue(argNum(args, 2))],
          ['label', new VeraStringValue(argString(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
          ['value', new VeraStringValue(argString(args, 5))],
        ])
      case 'World':
        // As a Surface: the height rides minimum, the build function label, the event handler action.
        return viewNode('world', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['minimum', new VeraNumberValue(argNum(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
        ])
      case 'Ticker':
        return viewNode('ticker', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['tickerId', new VeraStringValue(argString(args, 1))],
          ['minimum', new VeraNumberValue(argNum(args, 2))],
          ['checked', new VeraBooleanValue(argBool(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
        ])
      case 'Divider':
        return viewNode('divider', [
          ['style', new VeraStringValue(argString(args, 0))],
        ])
      case 'BackHandler':
        return viewNode('backhandler', [
          ['action', new VeraStringValue(argString(args, 0))],
        ])
      case 'Progress':
        return viewNode('progress', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['value', new VeraNumberValue(argNum(args, 2))],
          ['maximum', new VeraNumberValue(argNum(args, 3))],
        ])
      case 'ProgressRing':
        return viewNode('progressring', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['value', new VeraNumberValue(argNum(args, 2))],
          ['maximum', new VeraNumberValue(argNum(args, 3))],
          ['text', new VeraStringValue(argString(args, 4))],
        ])
      case 'Button':
        return viewNode('button', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['action', new VeraStringValue(argString(args, 2))],
          ['value', new VeraNumberValue(argNum(args, 3))],
          ['enabled', new VeraBooleanValue(argBool(args, 4))],
        ])
      case 'Cell':
        return viewNode('cell', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['action', new VeraStringValue(argString(args, 2))],
          ['value', new VeraNumberValue(argNum(args, 3))],
          ['enabled', new VeraBooleanValue(argBool(args, 4))],
        ])
      // The compositional layer. Every one of these reuses fields the decoder
      // already reads -- text, label, value, columns, children -- so nothing
      // below decodeNode changes and its measured cost stays where it was.
      case 'AppTheme':
        return viewNode('apptheme', [
          ['style', new VeraStringValue(argString(args, 0))],
          // The seed colour, under the name the decoder already reads a string
          // from. '' means the preset keeps its own primary.
          ['value', new VeraStringValue(argString(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'Hero':
        return viewNode('hero', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['text', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['children', argArray(args, 4)],
        ])
      case 'AdaptiveColumns':
        return viewNode('adaptivecolumns', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['minimum', new VeraNumberValue(argNum(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'Header':
        return viewNode('header', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['icon', new VeraStringValue(argString(args, 4))],
        ])
      case 'Section':
        return viewNode('section', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['children', argArray(args, 3)],
        ])
      case 'SectionHeader':
        return viewNode('sectionheader', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
        ])
      case 'ListGroup':
        return viewNode('listgroup', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'InsetBanner':
        return viewNode('banner', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
          ['icon', new VeraStringValue(argString(args, 5))],
        ])
      case 'EmptyState':
        return viewNode('emptystate', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
          ['icon', new VeraStringValue(argString(args, 5))],
        ])
      case 'Stat':
        // label is the caption, text the figure, value the line beneath -- the
        // figure goes in 'text' because that is the field a Text-like node
        // carries and the renderer draws largest.
        return viewNode('stat', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['text', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['icon', new VeraStringValue(argString(args, 4))],
        ])
      case 'TileGrid':
        return viewNode('tilegrid', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['children', argArray(args, 1)],
        ])
      case 'Tile':
        return viewNode('tile', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['columns', new VeraNumberValue(argNum(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['text', new VeraStringValue(argString(args, 3))],
          ['value', new VeraStringValue(argString(args, 4))],
          ['icon', new VeraStringValue(argString(args, 5))],
        ])
      case 'MetricGroup':
        return viewNode('metricgroup', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['columns', new VeraNumberValue(argNum(args, 1))],
          ['children', argArray(args, 2)],
        ])
      // The typed numeric layer. The number travels as a number and the
      // renderer formats it, so a program never builds a digit string and
      // never needs the padding function it cannot write.
      case 'NumberText':
        return viewNode('numbertext', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['numberValue', new VeraNumberValue(argNum(args, 1))],
          ['prefix', new VeraStringValue(argString(args, 2))],
          ['suffix', new VeraStringValue(argString(args, 3))],
          ['minimumDigits', new VeraNumberValue(argNum(args, 4))],
          ['decimals', new VeraNumberValue(argNum(args, 5, -1))],
        ])
      case 'ClockText':
        return viewNode('clocktext', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['numberValue', new VeraNumberValue(argNum(args, 1))],
          ['prefix', new VeraStringValue(argString(args, 2))],
          ['suffix', new VeraStringValue(argString(args, 3))],
        ])
      case 'NumberStat':
        return viewNode('numberstat', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['numberValue', new VeraNumberValue(argNum(args, 2))],
          ['prefix', new VeraStringValue(argString(args, 3))],
          ['suffix', new VeraStringValue(argString(args, 4))],
          ['minimumDigits', new VeraNumberValue(argNum(args, 5))],
          ['value', new VeraStringValue(argString(args, 6))],
          ['icon', new VeraStringValue(argString(args, 7))],
          ['decimals', new VeraNumberValue(argNum(args, 8, -1))],
        ])
      case 'NumberField':
        return viewNode('numberfield', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['numberValue', new VeraNumberValue(argNum(args, 2))],
          ['minimum', new VeraNumberValue(argNum(args, 3))],
          ['maximum', new VeraNumberValue(argNum(args, 4))],
          ['action', new VeraStringValue(argString(args, 5))],
          ['step', new VeraNumberValue(argNum(args, 6, 1))],
        ])
      case 'TimeField':
        return viewNode('timefield', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['numberValue', new VeraNumberValue(argNum(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
        ])
      case 'DateField':
        return viewNode('datefield', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['numberValue', new VeraNumberValue(argNum(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
        ])
      case 'NumberListItem':
        return viewNode('numberlistitem', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['numberValue', new VeraNumberValue(argNum(args, 3))],
          ['prefix', new VeraStringValue(argString(args, 4))],
          ['suffix', new VeraStringValue(argString(args, 5))],
          ['minimumDigits', new VeraNumberValue(argNum(args, 6))],
          ['action', new VeraStringValue(argString(args, 7))],
          ['eventValue', new VeraNumberValue(argNum(args, 8))],
          ['enabled', new VeraBooleanValue(argBool(args, 9))],
          ['icon', new VeraStringValue(argString(args, 10))],
          ['decimals', new VeraNumberValue(argNum(args, 11, -1))],
        ])
      case 'ActionBar':
        return containerNode('actionbar', args)
      case 'Timeline':
        return viewNode('timeline', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'TimelineItem':
        return viewNode('timelineitem', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
          ['action', new VeraStringValue(argString(args, 4))],
          ['eventValue', new VeraNumberValue(argNum(args, 5))],
          ['enabled', new VeraBooleanValue(argBool(args, 6))],
          ['icon', new VeraStringValue(argString(args, 7))],
        ])
      case 'Table':
        return viewNode('table', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['options', argArray(args, 1)],
          ['columns', new VeraNumberValue(argNum(args, 2))],
          ['children', argArray(args, 3)],
        ])
      case 'TableRow':
        return viewNode('tablerow', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['options', argArray(args, 1)],
        ])
      case 'KeyValueGroup':
        return viewNode('kvgroup', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['columns', new VeraNumberValue(argNum(args, 1))],
          ['children', argArray(args, 2)],
        ])
      case 'KeyValueItem':
        return viewNode('kvitem', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
          ['text', new VeraStringValue(argString(args, 2))],
          ['value', new VeraStringValue(argString(args, 3))],
        ])
      case 'Icon':
        return viewNode('icon', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['icon', new VeraStringValue(argString(args, 1))],
        ])
      case 'IconButton':
        return viewNode('iconbutton', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['icon', new VeraStringValue(argString(args, 1))],
          ['label', new VeraStringValue(argString(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
          ['value', new VeraNumberValue(argNum(args, 4))],
          ['enabled', new VeraBooleanValue(argBool(args, 5))],
        ])
      case 'Badge':
        return viewNode('badge', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['icon', new VeraStringValue(argString(args, 2))],
        ])
      // Loading and transient-status feedback. None of these need a new
      // VeraUiNode field: Skeleton reuses minimum/maximum/checked exactly as
      // Ticker already does for intervalMs/running, and Snackbar reuses
      // text/value/action exactly as InsetBanner does for message/
      // actionText/action.
      case 'Timer':
        // The moment rides numberValue and the direction checked, as other components reuse an existing field.
        return viewNode('timer', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['numberValue', new VeraNumberValue(argNum(args, 1))],
          ['checked', new VeraBooleanValue(argBool(args, 2, false))],
        ])
      case 'Skeleton':
        return viewNode('skeleton', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['minimum', new VeraNumberValue(argNum(args, 1))],
          ['maximum', new VeraNumberValue(argNum(args, 2))],
          ['checked', new VeraBooleanValue(argBool(args, 3, false))],
        ])
      case 'Spinner':
        return viewNode('spinner', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['label', new VeraStringValue(argString(args, 1))],
        ])
      case 'Snackbar':
        return viewNode('snackbar', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['text', new VeraStringValue(argString(args, 1))],
          ['value', new VeraStringValue(argString(args, 2))],
          ['action', new VeraStringValue(argString(args, 3))],
        ])
      case 'Sparkline':
        return viewNode('sparkline', [
          ['style', new VeraStringValue(argString(args, 0))],
          ['series', argArray(args, 1)],
          ['maximum', new VeraNumberValue(argNum(args, 2))],
          ['label', new VeraStringValue(argString(args, 3))],
          ['bars', new VeraBooleanValue(argBool(args, 4, false))],
          ['series2', argArray(args, 5)],
          ['series2Style', new VeraStringValue(argString(args, 6))],
          ['seriesLabel', new VeraStringValue(argString(args, 7))],
          ['series2Label', new VeraStringValue(argString(args, 8))],
          ['categories', argArray(args, 9)],
          ['minimum', new VeraNumberValue(argNum(args, 10, 0))],
        ])
      case 'When':
        if (asBool(args[0])) { return args[1] }
        return viewNode('spacer', [['style', new VeraStringValue('none')]])
      case 'numberToString':
        return new VeraStringValue(formatVeraNumber(asNum(args[0]), -1, 1))
      case 'formatNumber':
        return new VeraStringValue(formatVeraNumber(asNum(args[0]), asNum(args[1]), 1))
      case 'durationToString':
        return new VeraStringValue(formatVeraDuration(asNum(args[0])))
      case 'clockToString':
        return new VeraStringValue(formatVeraClock(asNum(args[0])))
      case 'dateToString':
        return new VeraStringValue(formatVeraDate(asNum(args[0])))
      case 'booleanToString':
        return new VeraStringValue(asBool(args[0]) ? 'true' : 'false')
      default:
        throw new RuntimeTrap('R0015', `unknown std/ui function: ${name}`)
    }
  }

  /**
   * The unified raw escape hatch: an sdk index entry (found through
   * find_sdk_function) or, since VeraCompiler.buildStdSdkModule merged the
   * two, an intent address (found through find_intent_function) -- told
   * apart downstream by VeraPreview.runEffect on whether the target has a
   * slash in it, the same test the compiler used to accept it. `mode` is the
   * fourth, optional argument: omitted for an sdk-style target (meaningless
   * there), present as "foreground"/"background" for an intent-style one --
   * absent here just means the compiled call had fewer than 4 arguments, not
   * that anything went wrong.
   */
  private queueSdk(args: RuntimeValue[]): RuntimeValue {
    if (!this.effectsAllowed) {
      throw new RuntimeTrap('R0026', 'sdk.call may only be called from a handler, not from view')
    }
    let target = asString(args[0]).trim()
    let pairs = asArray(args[1]).elements
    if (pairs.length % 2 !== 0) {
      throw new RuntimeTrap('R0027',
        'sdk.call parameters are name and value in pairs; got ' + pairs.length.toString() + ' items')
    }
    let values = new Map<string, string>()
    let order: string[] = []
    for (let i = 0; i + 1 < pairs.length; i = i + 2) {
      let key = asString(pairs[i]).trim()
      if (key.length === 0) { continue }
      values.set(key, asString(pairs[i + 1]))
      order.push(key)
    }
    let mode = args.length > 3 ? asString(args[3]) : 'background'
    let id = this.nextEffectId
    this.nextEffectId = id + 1
    let effect = new HostEffect(id, 'sdk', 'call', values, asString(args[2]))
    effect.rawTarget = target
    effect.rawParams = order.join(' ')
    effect.rawMode = mode
    this.pendingEffects.push(effect)
    return new VeraNumberValue(id)
  }
}

let nextNodeId: number = 0

export function decodeVeraUi(value: RuntimeValue): VeraUiNode[] {
  nextNodeId = 0
  if (value instanceof VeraObjectValue) {
    return [decodeNode(value as VeraObjectValue, 0)]
  }
  return []
}

function decodeNode(obj: VeraObjectValue, depth: number): VeraUiNode {
  if (depth > 8) { throw new RuntimeTrap('R0021', 'view tree too deep (max 8)') }
  let node = new VeraUiNode()
  node.id = nextNodeId
  nextNodeId += 1

  // Walk the fields the node actually carries, rather than asking after each of
  // the two dozen a node might carry.
  //
  // This used to be one obj.fields.get() per possible field, so a ui.Text -- a
  // kind, a style and a string -- paid for twenty lookups to find its three,
  // and every node in every tree paid the same flat toll. Decode is a measured
  // phase, and the toll grew every time the vocabulary did. Reading what is
  // there instead makes the cost proportional to the node rather than to the
  // catalogue, which is why the typed numeric fields above could be added at
  // all.
  //
  // Iteration order is insertion order, which is the order the case in
  // UiHostEnvironment.invoke wrote the fields in. Exactly one pair depends on
  // that: ListItem writes 'value' -- its trailing text -- before 'eventValue',
  // its tap payload, and both can land in eventValue. The later write wins, as
  // it did when these were two statements in a fixed order.
  for (let entry of obj.fields.entries()) {
    let key: string = entry[0]
    let v: RuntimeValue = entry[1]
    switch (key) {
      case 'type':
        if (v instanceof VeraStringValue) { node.kind = (v as VeraStringValue).value }
        break
      case 'style':
        if (v instanceof VeraStringValue) { node.style = (v as VeraStringValue).value }
        break
      case 'text':
        if (v instanceof VeraStringValue) { node.text = (v as VeraStringValue).value }
        break
      case 'src':
        if (v instanceof VeraStringValue) { node.source = (v as VeraStringValue).value }
        break
      case 'alt':
        if (v instanceof VeraStringValue) { node.alt = (v as VeraStringValue).value }
        break
      case 'action':
        if (v instanceof VeraStringValue) { node.action = (v as VeraStringValue).value }
        break
      case 'label':
        if (v instanceof VeraStringValue) { node.label = (v as VeraStringValue).value }
        break
      case 'tickerId':
        if (v instanceof VeraStringValue) { node.tickerId = (v as VeraStringValue).value }
        break
      case 'commands':
        if (v instanceof VeraStringValue) { node.commands = (v as VeraStringValue).value }
        break
      case 'prefix':
        if (v instanceof VeraStringValue) { node.prefix = (v as VeraStringValue).value }
        break
      case 'icon':
        if (v instanceof VeraStringValue) { node.icon = (v as VeraStringValue).value }
        break
      case 'suffix':
        if (v instanceof VeraStringValue) { node.suffix = (v as VeraStringValue).value }
        break
      // 'value' carries the text of a field, the position of a slider or
      // select, and the trailing text of a list row, so it arrives as either a
      // string or a number and means something different in each.
      case 'value':
        if (v instanceof VeraNumberValue) { node.eventValue = (v as VeraNumberValue).value }
        else if (v instanceof VeraStringValue) { node.value = (v as VeraStringValue).value }
        break
      case 'eventValue':
        if (v instanceof VeraNumberValue) { node.eventValue = (v as VeraNumberValue).value }
        break
      case 'numberValue':
        if (v instanceof VeraNumberValue) { node.numberValue = (v as VeraNumberValue).value }
        break
      case 'minimumDigits':
        if (v instanceof VeraNumberValue) { node.minimumDigits = (v as VeraNumberValue).value }
        break
      case 'decimals':
        if (v instanceof VeraNumberValue) { node.decimals = (v as VeraNumberValue).value }
        break
      case 'step':
        if (v instanceof VeraNumberValue) { node.step = (v as VeraNumberValue).value }
        break
      case 'spinPeriodMs':
        if (v instanceof VeraNumberValue) { node.spinPeriodMs = (v as VeraNumberValue).value }
        break
      case 'columns':
        if (v instanceof VeraNumberValue) { node.columns = (v as VeraNumberValue).value }
        break
      case 'minimum':
        if (v instanceof VeraNumberValue) { node.minimum = (v as VeraNumberValue).value }
        break
      case 'maximum':
        if (v instanceof VeraNumberValue) { node.maximum = (v as VeraNumberValue).value }
        break
      case 'checked':
        if (v instanceof VeraBooleanValue) { node.checked = (v as VeraBooleanValue).value }
        break
      case 'enabled':
        if (v instanceof VeraBooleanValue) { node.enabled = (v as VeraBooleanValue).value }
        break
      case 'bars':
        if (v instanceof VeraBooleanValue) { node.bars = (v as VeraBooleanValue).value }
        break
      case 'options':
        if (v instanceof VeraArrayValue) {
          let opts: string[] = []
          for (let o of (v as VeraArrayValue).elements) {
            if (o instanceof VeraStringValue) { opts.push((o as VeraStringValue).value) }
          }
          node.options = opts
        }
        break
      case 'series':
        if (v instanceof VeraArrayValue) {
          let nums: number[] = []
          for (let n of (v as VeraArrayValue).elements) {
            if (n instanceof VeraNumberValue) { nums.push((n as VeraNumberValue).value) }
          }
          node.series = nums
        }
        break
      case 'series2':
        if (v instanceof VeraArrayValue) {
          let nums2: number[] = []
          for (let n of (v as VeraArrayValue).elements) {
            if (n instanceof VeraNumberValue) { nums2.push((n as VeraNumberValue).value) }
          }
          node.series2 = nums2
        }
        break
      case 'series2Style':
        if (v instanceof VeraStringValue) { node.series2Style = (v as VeraStringValue).value }
        break
      case 'seriesLabel':
        if (v instanceof VeraStringValue) { node.seriesLabel = (v as VeraStringValue).value }
        break
      case 'series2Label':
        if (v instanceof VeraStringValue) { node.series2Label = (v as VeraStringValue).value }
        break
      case 'categories':
        if (v instanceof VeraArrayValue) {
          let cats: string[] = []
          for (let c of (v as VeraArrayValue).elements) {
            if (c instanceof VeraStringValue) { cats.push((c as VeraStringValue).value) }
          }
          node.categories = cats
        }
        break
      case 'keyboardType':
        if (v instanceof VeraStringValue) { node.keyboardType = (v as VeraStringValue).value }
        break
      case 'required':
        if (v instanceof VeraBooleanValue) { node.required = (v as VeraBooleanValue).value }
        break
      case 'requiredMessage':
        if (v instanceof VeraStringValue) { node.requiredMessage = (v as VeraStringValue).value }
        break
      case 'minLength':
        if (v instanceof VeraNumberValue) { node.minLength = (v as VeraNumberValue).value }
        break
      case 'minLengthMessage':
        if (v instanceof VeraStringValue) { node.minLengthMessage = (v as VeraStringValue).value }
        break
      case 'maxLength':
        if (v instanceof VeraNumberValue) { node.maxLength = (v as VeraNumberValue).value }
        break
      case 'maxLengthMessage':
        if (v instanceof VeraStringValue) { node.maxLengthMessage = (v as VeraStringValue).value }
        break
      case 'pattern':
        if (v instanceof VeraStringValue) { node.pattern = (v as VeraStringValue).value }
        break
      case 'patternMessage':
        if (v instanceof VeraStringValue) { node.patternMessage = (v as VeraStringValue).value }
        break
      case 'email':
        if (v instanceof VeraBooleanValue) { node.email = (v as VeraBooleanValue).value }
        break
      case 'emailMessage':
        if (v instanceof VeraStringValue) { node.emailMessage = (v as VeraStringValue).value }
        break
      case 'children':
        if (v instanceof VeraArrayValue) {
          for (let child of (v as VeraArrayValue).elements) {
            if (child instanceof VeraObjectValue) {
              node.children.push(decodeNode(child as VeraObjectValue, depth + 1))
            }
          }
        }
        break
      default:
        break
    }
  }
  node.style = resolveStyle(node.kind, node.style)
  if (node.series2Style.length > 0) { node.series2Style = resolveStyle(node.kind, node.series2Style) }
  return node
}
