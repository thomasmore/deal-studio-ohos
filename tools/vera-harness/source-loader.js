// Load current application sources for host verification. No ArkUI or platform execution.
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const sourceRoot = path.resolve(process.env.VERA_SOURCE_ROOT || path.join(__dirname, '../../entry/src/main/ets'))
const cache = new Map()
function loadSource(file) {
  file = path.resolve(file)
  if (cache.has(file)) return cache.get(file).exports
  const source = fs.readFileSync(file, 'utf8')
  const compiled = ts.transpileModule(source, {fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true}, reportDiagnostics: true})
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error)
  if (errors.length) throw Error(ts.formatDiagnosticsWithColorAndContext(errors, {getCurrentDirectory: () => sourceRoot, getCanonicalFileName: f => f, getNewLine: () => '\n'}))
  const mod = {exports: {}}
  cache.set(file, mod)
  const localRequire = name => {
    if (name.endsWith('/VeraSdkIndex')) return loadSource(path.join(__dirname, 'src/VeraSdkIndex.ts'))
    // Platform modules the template/selector files import for their network calls; the host checks never reach them.
    if (name === '@kit.PerformanceAnalysisKit') return {hilog: {info() {}, warn() {}, error() {}, debug() {}}}
    if (name === '@kit.NetworkKit') return {http: {RequestMethod: {POST: 'POST', GET: 'GET'}, HttpProtocol: {HTTP1_1: 'http1.1'}, createHttp() { if (typeof globalThis.__veraHttp === 'function') return globalThis.__veraHttp(); return {on() {}, destroy() {}, request() { return Promise.reject(Object.assign(Error('network is not available in the host harness'), {code: 2300028})) }} }}}
    // Any other platform module is only touched when a network or file call is made, which host checks never do.
    if (name.startsWith('@kit.') || name === 'libllama.so') return {}
    if (name.startsWith('.')) return loadSource(path.resolve(path.dirname(file), name + '.ets'))
    throw Error('Unsupported host dependency: ' + name)
  }
  new Function('require', 'module', 'exports', compiled.outputText)(localRequire, mod, mod.exports)
  return mod.exports
}
function loadVera(name) { return loadSource(path.join(sourceRoot, 'vera', name + '.ets')) }
module.exports = {loadVera, loadSource, sourceRoot}
