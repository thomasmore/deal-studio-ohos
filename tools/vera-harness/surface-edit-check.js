// A change to a program that draws on a ui.Surface (agent/AgentSurfaceEdit.ets): the model is shown the guide the program
// was written with and answers with edits; the result is played before it is served, and repaired by edits against that;
// a change that never plays leaves nothing to serve. A fake model stands in for DeepSeek.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const {AgentHost} = loadVera('agent/AgentHost')
const E = loadVera('agent/AgentSurfaceEdit')

const game = fs.readFileSync(path.join(__dirname, 'examples/surface-catch.vera'), 'utf8')
const scene = fs.readFileSync(path.join(__dirname, 'examples/surface-roulette.vera'), 'utf8')
const guide = fs.readFileSync(path.join(__dirname, '../../entry/src/main/resources/rawfile/vera-surface-skill.txt'), 'utf8')
const dice = fs.readFileSync(path.join(__dirname, 'examples/world-dice.vera'), 'utf8')
const worldGuide = fs.readFileSync(path.join(__dirname, '../../entry/src/main/resources/rawfile/vera-world-skill.txt'), 'utf8')
const edit = (search, replace) => '<<<<<<< SEARCH\n' + search + '\n=======\n' + replace + '\n>>>>>>> REPLACE'

function host(replies) {
  const h = new AgentHost()
  h.language = 'LANGUAGE {{UI_CATALOG}} Clock -- time. rest'
  h.surfaceGuide = guide
  h.worldGuide = worldGuide
  h.asks = []
  h.askCode = async (system, user, budget, think) => { h.asks.push({system, user, budget, think}); return replies.shift() ?? null }
  return h
}

;(async () => {
  assert.ok(E.drawsSurface(game) && E.drawsSurface(scene))
  assert.ok(!E.drawsSurface('function view(state: AppState): ui.View { return ui.Text("body", "x"); }'))
  assert.ok(E.isWholeGame(game) && !E.isWholeGame(scene), 'a fill surface is a game, a surface among sections a scene')

  // A game: one edit, played, served; the model saw the game guide and the change.
  const wider = edit('  shapes.push(gfx.roundRect(state.basketX - 50, 572, 100, 28, 12, "accent"));',
    '  shapes.push(gfx.roundRect(state.basketX - 70, 572, 140, 28, 12, "accent"));')
  let h = host([wider])
  let r = await E.editSurfaceProgram(game, 'make the basket wider', 'catch falling stars', h)
  assert.equal(r.failed, '')
  assert.ok(r.game)
  assert.equal(r.edits, 1)
  assert.match(r.source, /basketX - 70, 572, 140/)
  assert.ok(r.vbc2.length > 0)
  assert.equal(h.asks.length, 1)
  assert.ok(h.asks[0].system.includes('FULL-CANVAS APPS'), 'the game guide')
  assert.match(h.asks[0].user, /The change asked for now: make the basket wider/)
  assert.match(h.asks[0].user, /<<<<<<< SEARCH/)
  assert.equal(h.asks[0].budget, E.CHANGE_TOKENS)

  // An edit that compiles but stops the game a second into play is caught by playing it, and repaired by edits.
  const line = '  let dt: number = math.min(elapsedMs, 50) / 1000;'
  const trap = '  if (state.stars.length() > 1) { let none: Star[] = []; dt = none[1].y; }'
  const frozen = edit(line, line + '\n' + trap)
  const unfreeze = edit(trap, '')
  h = host([frozen, unfreeze])
  r = await E.editSurfaceProgram(game, 'something', 'catch falling stars', h)
  assert.equal(r.failed, '', 'served after the repair')
  assert.equal(r.rounds, 1)
  assert.match(h.asks[1].user, /stopped in onFrame at frame/)

  // A change that never plays: asked twice (the second thinking), repaired, then nothing to serve.
  h = host([frozen, 'no edits', 'no edits', frozen, 'no edits', 'no edits'])
  r = await E.editSurfaceProgram(game, 'something', 'catch falling stars', h)
  assert.equal(r.source, '')
  assert.ok(r.failed.length > 0)
  assert.deepEqual(h.asks.filter(a => a.budget === E.CHANGE_TOKENS).map(a => a.think), [false, true])

  // Edits that do not apply are not served either.
  h = host([edit('no such line', 'x'), edit('no such line', 'x')])
  r = await E.editSurfaceProgram(game, 'something', 'catch falling stars', h)
  assert.match(r.failed, /did not apply/)

  // A scene: the scene guide, told the passthrough is written out; played with its buttons (Spin starts the wheel).
  const slower = edit('  let speed: number = math.max(0, w.speed - 10 * dt);', '  let speed: number = math.max(0, w.speed - 5 * dt);')
  h = host([slower])
  r = await E.editSurfaceProgram(scene, 'let the wheel coast longer', 'virtual roulette', h)
  assert.equal(r.failed, '')
  assert.ok(!r.game)
  assert.ok(h.asks[0].system.includes('A SCENE IN THIS SECTION') && h.asks[0].system.includes('writes every field out'))
  assert.ok(!h.asks[0].system.includes('FULL-CANVAS APPS'))
  assert.equal(E.checkSceneProgram(scene), '')

  // A 3D program: the world guide, and the change is played on the host's physics -- one that stops reading the dice is
  // repaired against that play.
  assert.ok(E.drawsSurface(dice) && E.isWorld(dice) && !E.isWorld(game))
  const bigger = edit('  things.push(scene.table(1.2, 0.9, "surface"));', '  things.push(scene.table(1.4, 1.0, "surface"));')
  h = host([bigger])
  r = await E.editSurfaceProgram(dice, 'a bigger table', 'dice game', h)
  assert.equal(r.failed, '')
  assert.ok(r.world && r.game)
  assert.ok(r.source.includes('scene.table(1.4, 1.0, "surface")'))
  assert.ok(h.asks[0].system.includes('3D WORLD APPS') && !h.asks[0].system.includes('FULL-CANVAS APPS'))
  const forget = edit('  return {throws: state.throws, read: state.throws, total: total, faces: faces};', '  return state;')
  const remember = edit('  return state;\n}\n\nfunction view', '  return {throws: state.throws, read: state.throws, total: total, faces: faces};\n}\n\nfunction view')
  h = host([forget, remember])
  r = await E.editSurfaceProgram(dice, 'something', 'dice game', h)
  assert.equal(r.failed, '')
  assert.equal(r.rounds, 1, 'the unread settle was caught by the world\'s play and repaired')
  assert.equal(r.source.trim(), dice.trim())
  h = host([bigger]); h.worldGuide = ''
  r = await E.editSurfaceProgram(dice, 'a bigger table', 'dice game', h)
  assert.match(r.failed, /no model or guide/)

  console.log('surface-edit-check ok')
})().catch(e => { console.error(e); process.exit(1) })
