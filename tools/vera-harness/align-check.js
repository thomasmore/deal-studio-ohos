// align-lib.js without the network: what Jev is shown for a plan, and the comparison of the three readings (the section pick for
// the request as typed, the same for the request plus its plan, the composition the agent builds), on the recorded plans in
// tools/vera-harness/compose/.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const lib = require('./align-lib')
const {compose, sections} = lib

const dir = path.join(__dirname, 'compose')
const sketchOf = label => compose.parseSketch(fs.readFileSync(path.join(dir, label, 'sketch.json'), 'utf8'))
const compositionOf = label => compose.readComposition(fs.readFileSync(path.join(dir, label, 'jev-answer.json'), 'utf8'), sketchOf(label))

// A pick as Jev would give it for these kinds, in order, with the vetoes quiet unless named.
const VETOES = ['needs_integration', 'needs_real_data', 'needs_search_or_form', 'needs_live_ticking', 'needs_multiple_counters', 'needs_multiple_series', 'needs_logic']
function pick(kinds, fired = []) {
  const answers = {}
  kinds.forEach((k, i) => { answers['section' + (i + 1)] = {choice: k, confidence: 0.9} })
  for (const v of VETOES) answers['veto.' + v] = {noul: fired.includes(v) ? 0.95 : 0}
  return sections.readSectionPick(JSON.stringify({answers}))
}

// The plan is part of what Jev reads, after the person's words and never in place of them.
{
  const prompt = 'tip calculator'
  for (const label of fs.readdirSync(dir)) {
    const sketch = sketchOf(label)
    assert.notEqual(sketch, null, label)
    const text = lib.alignmentText(prompt, sketch)
    assert.ok(text.startsWith(prompt), label)
    assert.match(text, /The screen is planned to have:\n- /, label)
    assert.ok(text.includes(compose.describeSketch(sketch)), label)
  }
  assert.equal(lib.alignmentText('x', new compose.Sketch()), 'x', 'an empty plan adds nothing')
}

// A pick as plain data.
{
  const d = lib.describePick(pick(['checklist', 'metrics'], ['needs_logic']))
  assert.deepEqual(d.kinds, ['checklist', 'metrics'])
  assert.deepEqual(d.soft, ['needs_logic'])
  assert.equal(d.why, '')
  const none = lib.describePick(pick([]))
  assert.deepEqual(none.kinds, []); assert.notEqual(none.why, '', 'a pick of nothing says why')
  assert.equal(lib.describePick(null), null)
}

// A composition as plain data, on a recorded plan: the sections Jev chose for its ready needs, and what is left to write.
{
  const tipping = lib.describeComposition(compositionOf('sections-tipping'))
  assert.deepEqual(tipping.blocks, ['key_facts'])
  assert.ok(tipping.parts.length > 0)
  const beach = lib.describeComposition(compositionOf('sections-beach'))
  assert.deepEqual(beach.blocks, ['checklist'])
  const todos = lib.describeComposition(compositionOf('own-todos'))
  assert.ok(todos.custom.length > 0, 'the person\'s own records are left for the model to write')
  assert.deepEqual(lib.describeComposition(compositionOf('egg')).blocks, [])
}

// The row says where the readings differ, and says nothing when they agree.
{
  const comp = compositionOf('sections-tipping')
  let r = lib.row('t', 'tipping around the world', pick(['key_facts']), pick(['key_facts']), comp)
  assert.deepEqual(r.notes, [])
  r = lib.row('t', 'tipping around the world', pick(['key_facts']), pick(['checklist']), comp)
  assert.ok(r.notes.some(n => /the plan changes the pick: key_facts -> checklist/.test(n)))
  assert.ok(r.notes.some(n => /pick has checklist, composition does not/.test(n)))
  assert.ok(r.notes.some(n => /composition has key_facts, pick does not/.test(n)))
  r = lib.row('t', 'x', pick(['key_facts'], []), pick(['key_facts'], ['needs_logic']), comp)
  assert.ok(r.notes.some(n => /vetoes - -> needs_logic/.test(n)))
  // No composition (the agent had no plan): only the two picks are compared.
  r = lib.row('t', 'x', pick(['checklist']), pick(['metrics']), null)
  assert.ok(r.notes.every(n => !/composition/.test(n)))
}

// The table counts what the rows say.
{
  const rows = [
    lib.row('same', 'a', pick(['key_facts']), pick(['key_facts']), compositionOf('sections-tipping')),
    lib.row('moved', 'b', pick(['key_facts']), pick(['checklist']), compositionOf('sections-tipping')),
    lib.row('left', 'c', pick([]), pick([]), compositionOf('own-todos'))
  ]
  const t = lib.table(rows)
  assert.equal(t.count.prompts, 3); assert.equal(t.count.planChanges, 1); assert.equal(t.count.disagree, 1)
  assert.equal(t.count.pickOnly, 1); assert.equal(t.count.compOnly, 1); assert.equal(t.count.leftOver, 1)
  assert.match(t.text, /prompts 3 \| the plan changes the pick 1/)
}

// Per need: what a plan asks for that is not plainly a part, the one batched request, and how its answers are read.
{
  const needs = sketchOf('egg') && lib.needsOf(sketchOf('egg'))
  assert.deepEqual(needs.map(n => n.source), ['countdown', 'event', 'other', 'other'], 'a countdown, its event, and what the plan lists beyond the parts')
  assert.deepEqual(lib.needsOf(sketchOf('expenses')).map(n => n.source), ['list'])
  assert.deepEqual(lib.needsOf(sketchOf('own-todos')).map(n => n.source), ['ready'])
  assert.deepEqual(lib.needsOf(sketchOf('bmi')).map(n => n.source), [], 'inputs and figures are the composer\'s parts: nothing to ask')
  assert.deepEqual(lib.needsOf(sketchOf('egg')).filter(n => n.source === 'event').map(n => n.index), [0])

  const kinds = lib.standaloneKinds().map(k => k.kind)
  for (const reader of ['filter_box', 'detail_view', 'list_summary', 'number_strip', 'breakdown_table', 'series_chart', 'settle_up', 'progress_line'])
    assert.ok(!kinds.includes(reader), reader + ' needs a partner and is not offered on its own')
  for (const hub of ['checklist', 'record_log', 'itinerary', 'reminders', 'timer']) assert.ok(kinds.includes(hub), hub)

  const body = JSON.parse(lib.buildNeedRequest('an egg timer', needs))
  assert.equal(body.state, 'an egg timer')
  assert.equal(Object.keys(body.questions).length, needs.length)
  const q = body.questions['need.0']
  assert.equal(q.type, 'choice')
  assert.ok(q.instructions.includes(needs[0].text))
  assert.ok('part' in q.criteria && 'none' in q.criteria && 'timer' in q.criteria)
  assert.ok(Object.keys(q.criteria).length <= 255)

  const answer = (...a) => JSON.stringify({answers: Object.fromEntries(a.map(([c, p], i) => ['need.' + i, {choice: c, confidence: p}]))})
  const read = lib.readNeedAnswers(answer(['timer', 0.9], ['part', 0.8], ['key_facts', 0.3], ['none', 0.7], ['not-a-kind', 1]), needs.concat(needs).slice(0, 5))
  assert.deepEqual(read.map(r => r.decision), ['section', 'part', 'weak', 'none', 'undecided'])
  assert.equal(read[0].choice, 'timer'); assert.equal(read[2].p, 0.3)
  assert.deepEqual(lib.readNeedAnswers('not json', needs).map(r => r.decision), needs.map(() => 'undecided'))
  assert.equal(lib.readNeedAnswers(answer(['timer', 0.5]), [needs[0]])[0].decision, 'section', 'the bar itself is enough')

  // The row says where a need's section is not what the composition builds, and where a ready need's section differs.
  const comp = compositionOf('sections-tipping')
  const tipNeeds = lib.needsOf(sketchOf('sections-tipping'))
  let r = lib.row('t', 'x', null, null, comp, lib.readNeedAnswers(answer(['key_facts', 0.9]), tipNeeds))
  assert.deepEqual(r.notes, [], 'the same section as the composition')
  r = lib.row('t', 'x', null, null, comp, lib.readNeedAnswers(answer(['checklist', 0.9]), tipNeeds))
  assert.ok(r.notes.some(n => /checklist \(0\.90\), composition does not/.test(n)))
  assert.ok(r.notes.some(n => /ready need .*need=checklist composition=key_facts/.test(n)))
  r = lib.row('t', 'x', null, null, comp, lib.readNeedAnswers(answer(['part', 0.9]), tipNeeds))
  assert.ok(r.notes.some(n => /ready need .*need=part composition=key_facts/.test(n)), 'a ready need Jev would build with parts')
  r = lib.row('t', 'x', null, null, comp, lib.readNeedAnswers(answer(['key_facts', 0.3]), tipNeeds))
  assert.ok(r.notes.some(n => /weak key_facts \(0\.30\) -> written/.test(n)))
  assert.match(lib.table([r]).text, /needs ready:weak key_facts@0\.30/)
}

console.log('align-check: ok')
