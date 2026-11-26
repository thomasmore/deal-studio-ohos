// Compiles every Jev section fragment (VeraTemplates.ets) alone and in every ordered pair, through the
// real composeProgram and compileVeraSource, both normal and legacy widget/tab layouts. No device or Jev call.
'use strict'
const {loadVera} = require('./source-loader')
const {fragments} = loadVera('VeraTemplates')
const {composeProgram} = loadVera('VeraSectionCompose')
const {expandListRows} = loadVera('VeraTemplateContent')
const {compileVeraSource} = loadVera('VeraCompiler')
const kinds = fragments().map(f => f.kind)
const defaults = kind => {
  // First allowed value of every cosmetic slot, fallback text of every content field: what the app uses when Jev or the content call says nothing.
  const spec = fragments().find(f => f.kind === kind)
  const values = new Map()
  spec.slots.forEach(s => values.set(s.token, s.values[0]))
  spec.contentFields.forEach(c => values.set(c.token, c.fallback))
  spec.listFields.forEach(l => values.set(l.token, expandListRows(undefined, l).text))
  return values
}
const globals = new Map([['__THEME__', 'clean'], ['__HEADER_STYLE__', 'default'], ['__BANNER_SECTION__', 'hide']])
const cases = []
for (const a of kinds) cases.push([a])
// A block whose names are not numbered (FragmentSpec.indexed false: live_figure) is one per screen, so it is not paired with itself.
const single = new Set(fragments().filter(f => !f.indexed).map(f => f.kind))
for (const a of kinds) for (const b of kinds) if (a !== b || !single.has(a)) cases.push([a, b])
const results = cases.map(chosen => {
  const label = chosen.join('+')
  try {
    const source = composeProgram(chosen, globals, chosen.map(defaults))
    compileVeraSource(source)
    const widgetGlobals = new Map(globals); widgetGlobals.set('__WIDGET__', 'true')
    compileVeraSource(composeProgram(chosen, widgetGlobals, chosen.map(defaults)))
    return {label, ok: true}
  } catch (e) {
    const d = e.diagnostics ? e.diagnostics.map(x => x.message || String(x)).slice(0, 3) : [String(e.message || e)]
    return {label, ok: false, error: d}
  }
})
const failed = results.filter(r => !r.ok)
console.log(JSON.stringify({kinds, total: results.length, failed: failed.length, failures: failed}, null, 1))
process.exit(failed.length ? 1 : 0)
