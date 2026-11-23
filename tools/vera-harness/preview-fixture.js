'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require(process.env.VERA_TYPESCRIPT_PATH || 'typescript')
const { loadSource, sourceRoot } = require('./source-loader')

function declaration(source, prefix) {
  const start = source.indexOf(prefix)
  assert(start >= 0, 'missing declaration: ' + prefix)
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(start))
  let depth = 0
  let opened = false
  while (scanner.scan() !== ts.SyntaxKind.EndOfFileToken) {
    if (scanner.getToken() === ts.SyntaxKind.OpenBraceToken) { depth++; opened = true }
    if (scanner.getToken() === ts.SyntaxKind.CloseBraceToken && --depth === 0 && opened) {
      return source.slice(start, start + scanner.getTextPos())
    }
  }
  throw Error('unterminated declaration: ' + prefix)
}

function extractPreview(source) {
  source = source.replace(/\r\n/g, '\n')
  source = source.replace(declaration(source, '  build()'), '')
  const builders = [...source.matchAll(/^  @LocalBuilder\s*\n  (\w+)\(/gm)].map(match => match[1])
  assert(builders.length > 0, 'must exclude ArkUI builders')
  for (const name of builders) source = source.replace('  @LocalBuilder\n' + declaration(source, '  ' + name + '('), '')
  return source.replace('export struct VeraPreview', 'export class VeraPreview')
    .replace(/@(Watch|StorageProp)\([^)]*\)/g, '')
    .replace(/@(Component|ObservedV2|Trace|Prop|State)\b/g, '')
}

function createPreview({ runtime, HostOperationFailure, HostEffectsBridge, mocks = {}, askBeforeCalls = false }) {
  const file = path.join(sourceRoot, 'components/VeraPreview.ets')
  const renderer = fs.readFileSync(file, 'utf8')
  const slider = renderer.slice(renderer.indexOf("} else if (node.kind === 'slider') {"), renderer.indexOf("} else if (node.kind === 'select') {"))
  const field = renderer.slice(renderer.indexOf("} else if (node.kind === 'field') {"), renderer.indexOf("} else if (node.kind === 'toggle' || node.kind === 'checkbox') {"))
  const callbacks = 'sliderChange(node: LiveNode) { return ' + declaration(slider, '.onChange(').slice('.onChange('.length) + ' }\n' +
    [['nativeChange', '.onChange('], ['nativeSubmit', '.onSubmit('], ['nativeEditChange', '.onEditChange(']].map(([name, prefix]) =>
      name + '(node: LiveNode, generation: number) { return ' + declaration(field, prefix).slice(prefix.length) + ' }').join('\n')
  const source = extractPreview(renderer).replace('export class VeraPreview {', 'export class VeraPreview {\n' + callbacks)
    .replace(/const ASK_BEFORE_CALLS: boolean = (true|false)/, 'const ASK_BEFORE_CALLS: boolean = ' + askBeforeCalls)
  const compiled = ts.transpileModule(source, {
    fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
    reportDiagnostics: true
  })
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
  assert.equal(errors.length, 0, errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'))
  const platform = {
    Scroller: class {}, TextInputController: class { getText() { return '' } }, TextTimerController: class {},
    CanvasRenderingContext2D: class {}, RenderingContextSettings: class {},
    TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 }, SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 },
    Date, console: { info() {}, warn() {}, error() {} }, setTimeout, clearTimeout, setInterval, clearInterval,
    ...mocks
  }
  const importer = name => {
    if (name === '../runtime/InProcessHost') return { InProcessHost: { get: () => runtime }, HostOperationFailure }
    if (name === '../runtime/HostEffectsBridge') return { HostEffectsBridge }
    if (name === './VeraWorld3D') return {
      WorldBox: mocks.WorldBox || class { constructor() { throw Error('Unexpected World3D in non-world fixture') } },
      playerOf: mocks.playerOf || (() => { throw Error('Unexpected World3D player in non-world fixture') })
    }
    if (name === '../vera/FormUpdater') return { scheduleCardRefresh: mocks.scheduleCardRefresh || (() => {}) }
    if (name === '@kit.ArkUI') return { LengthMetrics: {}, mediaquery: {}, matrix4: {} }
    if (name === '@kit.ArkGraphics2D') return { displaySync: mocks.displaySync || { create() { throw Error('fixture interval fallback') } } }
    assert(name.startsWith('.'), 'Unexpected preview dependency: ' + name)
    const loaded = loadSource(path.resolve(path.dirname(file), name + '.ets'))
    return Object.fromEntries(Object.entries(loaded).map(([key, value]) => [key, Object.hasOwn(mocks, key) ? mocks[key] : value]))
  }
  const mod = { exports: {} }
  new Function('require', 'module', 'exports', ...Object.keys(platform), compiled.outputText)(importer, mod, mod.exports, ...Object.values(platform))
  const probe = new mod.exports.VeraPreview()
  probe.getUIContext = () => ({ vp2px: value => value,
    getMediaQuery: () => ({ matchMediaSync: () => ({ matches: false, on() {}, off() {} }) }) })
  return { probe, ...mod.exports }
}

function effectRequest(probe, effect) {
  return { appId: probe.frameAppId, vmGeneration: probe.frameVmGeneration, effectId: effect.id,
    kind: effect.kind, rawTarget: effect.rawTarget, params: [...effect.values].flat(),
    resultHandler: effect.resultHandler, mode: effect.rawMode || 'background' }
}

function seedEffects(probe, effects) {
  if (probe.disposed || probe.previewOnly || probe.handle === null) return
  const record = probe.runtime.registry.get(probe.handle.appId)
  for (const effect of effects) {
    const request = effectRequest(probe, effect)
    const current = record.current
    const sequence = record.effectSeq
    record.current = { lease: record.leases.get(probe.handle.leaseId) }
    record.effectSeq = request.effectId - 1
    try { probe.runtime.deliverEffects(record, [effect]) }
    finally { record.current = current; record.effectSeq = Math.max(sequence, request.effectId) }
  }
}

module.exports = { declaration, extractPreview, createPreview, effectRequest, seedEffects }
