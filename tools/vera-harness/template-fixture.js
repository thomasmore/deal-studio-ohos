'use strict'
// Shared fixture for the template-block checks. Loads the composition stack once
// and provides the helpers those checks repeat: fragment values, a compiled VM,
// node walking, text flattening and effect-returning handler calls.

const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')

const {fragments, FragmentSpec, StateFieldSpec, PortSpec} = loadVera('VeraTemplates')
const {composeProgram, composeFragments, bindPorts, readSectionPick} = loadVera('VeraSectionCompose')
const {expandListRows} = loadVera('VeraTemplateContent')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VirtualMachine, deserializeVbc2, decodeRuntimeValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment, decodeVeraUi} = loadVera('VeraUI')
const {smokeRun} = loadVera('VeraSmoke')


const globals = new Map([['__THEME__', 'clean'], ['__HEADER_STYLE__', 'default'], ['__BANNER_SECTION__', 'hide'], ['__TITLE_CHECK__', 'Check']])

function specOf(kind) {
  const spec = fragments().find(f => f.kind === kind)
  if (!spec) throw new Error('no fragment ' + kind)
  return spec
}

// over is keyed by slot/content token; listRows fills every list field
function values(kind, over = {}, listRows = undefined) {
  const spec = specOf(kind), m = new Map()
  spec.slots.forEach(s => m.set(s.token, over[s.token] !== undefined ? over[s.token] : s.values[0]))
  spec.contentFields.forEach(c => m.set(c.token, over[c.token] !== undefined ? over[c.token] : c.fallback))
  spec.listFields.forEach(l => m.set(l.token, listRows === undefined ? '' : expandListRows(listRows, 1).text))
  return m
}

// kinds is a string or array; overByKind/listRowsByKind are keyed by kind.
function build(kinds, overByKind = {}, listRowsByKind = {}, opts = {}) {
  const list = Array.isArray(kinds) ? kinds : [kinds]
  const src = composeProgram(list, globals, list.map(k => values(k, overByKind[k] || {}, listRowsByKind[k])))
  const compiled = compileVeraSource(src)
  if (opts.smoke) assert.equal(smokeRun(compiled, false), '', 'every handler runs')
  const env = new UiHostEnvironment()
  return {src, env, vm: new VirtualMachine(deserializeVbc2(compiled.vbc2 !== undefined ? compiled.vbc2 : compiled), env)}
}

// buildFromMaps takes pre-built values maps (one per kind) for blocks whose list
// fields hold raw row text rather than expandListRows input.
function buildFromMaps(kinds, maps, opt = {}) {
  const list = Array.isArray(kinds) ? kinds : [kinds]
  const src = composeProgram(list, globals, maps)
  const compiled = compileVeraSource(src)
  if (opts.smoke) assert.equal(smokeRun(compiled, false), '', 'every handler runs')
  const env = new UiHostEnvironment()
  return {src, env, vm: new VirtualMachine(deserializeVbc2(compiled.vbc2 !== undefined ? compiled.vbc2 : compiled), env)}
}

function walk(node, f) {
  f(node)
  ;(node.children || []).forEach(child => walk(child, f))
}

function nodes(h, st) {
  const out = []
  walk(decodeVeraUi(h.vm.execute('view', [st]))[0], n => out.push(n))
  return out
}

function texts(h, st) {
  return nodes(h, st).flatMap(n => Object.values(n).filter(v => typeof v === 'string' && v !== ''))
}

function text(h, st) {
  return texts(h, st).join('|')
}

// Run one handler the way the renderer does: effects are allowed, and what the
// program asked for its read back from the host's pending effects.
function act(h, name, st, ...args) {
  h.env.effectsAllowed = true
  h.env.pendingEffects = []
  const next = h.vm.execute(name, [st, ...args])
  h.env.effectsAllowed = false
  return {st: next, effects: h.env.pendingEffects}
}

module.exports = {
  assert, fragments, FragmentSpec, StateFieldSpec, PortSpec,
  composeProgram, composeFragments, bindPorts, readSectionPick, expandListRows,
  compileVeraSource, VirtualMachine, deserializeVbc2, decodeRuntimeValue,
  UiHostEnvironment, decodeVeraUi, smokeRun,
  num, str, bool, globals, specOf, values, build, buildFromMaps, walk, nodes, texts, text, act,
}
