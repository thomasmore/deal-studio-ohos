// The game route (agent/AgentSurface.ets) with a mocked model: which requests ask the question, how the answer is read,
// that a game is written on a ui.Surface and served only once it compiles and plays, that a broken one is repaired by
// edits against the play check, that a "no" goes on to the agent, and that the guide's own example plays.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const S = loadVera('agent/AgentSurface')
const {AgentHost} = loadVera('agent/AgentHost')
const route = loadVera('agent/VeraBuildRoute')
const {AgentRequest} = loadVera('agent/VeraAgent')
const {compileVeraSource} = loadVera('VeraCompiler')
const {playSurface} = loadVera('VeraSurfacePlay')

const rawfile = name => fs.readFileSync(path.join(__dirname, '../../entry/src/main/resources/rawfile', name), 'utf8').replace(/\r\n/g, '\n')
const exampleFile = name => fs.readFileSync(path.join(__dirname, 'examples', name), 'utf8').replace(/\r\n/g, '\n')
const guide = rawfile('vera-surface-skill.txt')
const worldGuide = rawfile('vera-world-skill.txt')
const worldBasics = exampleFile('world-basics.vera')
// A dice app as the model might write one: the fixture for the route's 3D tests (not what the guide shows).
const worldDice = exampleFile('world-dice.vera')
const language = rawfile('vera-skill.txt')
const example = guide.slice(guide.indexOf('--- EXAMPLE ---') + '--- EXAMPLE ---'.length, guide.indexOf('--- END EXAMPLE ---')).trim()

// The guide's example is the program the model copies its structure from: it must compile, run and play.
assert.equal(S.checkSurfaceProgram(example), '', 'the guide\'s example compiles, runs once and plays')
assert.equal(example.trim(), exampleFile('surface-basics.vera').slice(exampleFile('surface-basics.vera').indexOf('@jsonable')).trim(),
 'the guide carries examples/surface-basics.vera as it is (regenerate the rawfile when the example changes)')

{
  const open = '--- EXAMPLE ---\n', close = '--- END EXAMPLE ---'
  const worldExample = worldGuide.slice(worldGuide.indexOf(open) + open.length, worldGuide.indexOf(close))
  assert.equal(worldExample, worldBasics, 'the world guide carries examples/world-basics.vera as it is (regenerate the rawfile when the example changes)')
  assert.equal(S.checkWorldProgram(worldExample), '', 'the world guide\'s example compiles, runs once and plays')
  assert.match(S.checkWorldProgram(example), /^1:1 P0008 .*shows no ui.World/, 'a flat game is not a 3D program')
  const tOpen = '--- TRAVEL EXAMPLE ---\n', tClose = '--- END TRAVEL EXAMPLE ---'
  const travel = worldGuide.slice(worldGuide.indexOf(tOpen) + tOpen.length, worldGuide.indexOf(tClose))
  assert.equal(travel, exampleFile('world-walk.vera'),
    'the world guide carries examples/world-walk.vera as it is (regenerate the rawfile when the example changes)')
  for (const t of ['none', 'self', 'steered', 'both']) {
    assert.equal(S.checkWorldProgram(travel, t), '', 'the travel example plays for travel ' + t)
  }
  assert.match(S.checkWorldProgram(worldExample, 'self'), /P0014 .*goes anywhere by itself/, 'the throwing example has nothing that travels')
  // The guide tells of shooting, breaking and a blast in general terms, and of what struck, a tap and action carry.
  for (const w of ['"struck"', 'e.dx, e.dy, e.dz', 'e.other its\n  label', '- Shooting: whatever shoots', '- Breaking:', '- A blast:', 'scene.split(thing, n, burst)',
    'scene.shoot says how many', 'never "shot", "piece" or "body"']) assert.ok(worldGuide.includes(w), 'the world guide says ' + w)
  // The fixtures for shooting and breaking play through the route's own check.
  for (const name of ['world-shoot', 'world-break']) {
    assert.equal(S.checkWorldProgram(fs.readFileSync(path.join(__dirname, 'examples', name + '.vera'), 'utf8')), '', name + ' passes the route check')
  }
}

// The gate: game words ask, everything else goes straight to the agent.
for (const p of ['neon arkanoid', 'tank battle', 'a snake game', 'bouncing balls with gravity', 'a drawing pad for kids', 'fireworks animation'])
  assert.ok(S.looksLikeSurface(p), p + ' is asked about')
for (const p of ['a to-do list', 'tic-tac-toe', 'water reminder every 2 hours', 'split the bill between friends', 'pomodoro timer'])
  assert.ok(!S.looksLikeSurface(p), p + ' is not asked about')
for (const p of ['帮我做一个小时候红白机风格的坦克大战', '霓虹打砖块', '贪吃蛇小游戏', '儿童画板'])
  assert.ok(S.looksLikeSurface(p), p + ' is asked about')
for (const p of ['dice game', '3D solar system', 'cubes knocking over', 'a 3D cube', 'planets orbiting the sun', 'physics stack of blocks',
  'dominoes toppling'])
  assert.ok(S.looksLikeSurface(p), p + ' is asked about')
for (const p of ['break the 3D vases', 'smash crates', 'shatter glass', 'destroy the tower', 'a 3D cannon', 'exploding barrels'])
  assert.ok(S.looksLikeSurface(p), p + ' is asked about')
for (const p of ['breakfast log', 'a meal planner for breakfast and lunch'])
  assert.ok(!S.looksLikeSurface(p), p + ' is not asked about')
for (const p of ['立方体', '太阳系模型', '掷骰子', '三维地球', '物理堆叠'])
  assert.ok(S.looksLikeSurface(p), p + ' is asked about')
for (const p of ['帮我创建一张吃药卡，提醒我每天吃药', '西湖一日游', '成绩和绩点计算器'])
  assert.ok(!S.looksLikeSurface(p), p + ' is not asked about')

// Reading the answer.
assert.equal(S.parseSurfaceBrief('{"surface": true, "title": "T", "design": "D"}').design, 'D')
assert.equal(S.parseSurfaceBrief('noise {"surface": false, "title": "", "design": ""} noise').kind, S.SURFACE_NONE)
assert.equal(S.parseSurfaceBrief('{"surface": true, "title": "T", "design": ""}'), null, 'a game with no design is not an answer')
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "world", "title": "T", "design": ""}').engine, S.ENGINE_WORLD,
  'a 3D world with no design is still one: the world guide and the request are enough')
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "world", "travel": "Self", "title": "T", "design": "D"}').travel, 'self',
  'what travels is read')
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "world", "travel": "walks", "title": "T", "design": "D"}').travel, 'none',
  'an answer that is not one of the four is none')
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "flat", "travel": "steered", "title": "T", "design": "D"}').travel, 'none',
  'a flat app has no travel')
for (const w of ['"travel"', '"self"', '"steered"']) assert.ok(S.SURFACE_CLASSIFY_PROMPT.includes(w), 'the classifier says ' + w)
for (const w of ['up to two buttons beside', 'what it or anything else shoots', 'a tap that aims at the point tapped',
  'what breaks into pieces when struck hard enough']) assert.ok(S.SURFACE_CLASSIFY_PROMPT.includes(w), 'the world design asks ' + w)
assert.equal(S.parseSurfaceBrief('not json'), null)
// The engine: world only for a whole app that says so, flat otherwise.
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "title": "T", "design": "D"}').engine, S.ENGINE_FLAT, 'no engine is flat')
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "world", "title": "Dice", "design": "Two dice."}').engine, S.ENGINE_WORLD)
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": " World ", "title": "Dice", "design": "Two dice."}').engine, S.ENGINE_WORLD)
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "flat", "title": "T", "design": "D"}').engine, S.ENGINE_FLAT)
assert.equal(S.parseSurfaceBrief('{"surface": "whole", "engine": "3d", "title": "T", "design": "D"}').engine, S.ENGINE_FLAT, 'an unknown engine is flat')
assert.equal(S.parseSurfaceBrief('{"surface": "part", "engine": "world", "scene": "a wheel"}').engine, S.ENGINE_FLAT, 'a part is never a world')
assert.equal(S.parseSurfaceBrief('{"surface": "none", "engine": "world"}').engine, S.ENGINE_FLAT)
assert.ok(S.SURFACE_CLASSIFY_PROMPT.includes('"engine": "flat" | "world"'), 'the plan model is asked for the engine')
assert.deepEqual(S.WORLD_COMPONENTS, ['AppTheme', 'World', 'Column', 'Row', 'Text', 'Header', 'Button', 'ActionBar'])

// The language: the catalogue is the surface's few components and std/gfx, the guide replaces the screen-composition advice.
const system = S.surfaceLanguage(language, guide)
assert.ok(system.includes('ui.Surface(style, width, height, draw, frame, pointer)') && system.includes('gfx.polygon(points, color)'))
assert.ok(system.includes('FULL-CANVAS APPS') && system.includes('Clock -- time.') && system.includes('Syntax rules:'))
assert.ok(!system.includes('ui.Hero(') && !system.includes('Use ui.Hero when'), 'no catalogue or advice for screens of sections')
assert.ok(!system.includes('{{UI_CATALOG}}'))
assert.equal(S.sourceIn('```vera\nabc\n```\ntrailing'), 'abc')
assert.equal(S.sourceIn('abc'), 'abc')

// The 3D language: the World's components and std/scene, with the world guide in place of the screen-composition advice.
const worldSystem = S.worldLanguage(language, worldGuide)
assert.ok(worldSystem.includes('ui.World(') && worldSystem.includes('scene.die(') && worldSystem.includes('scene.Event'))
assert.ok(worldSystem.includes('3D WORLD APPS') && worldSystem.includes('Clock -- time.') && worldSystem.includes('Syntax rules:'))
assert.ok(!worldSystem.includes('ui.Surface(style') && !worldSystem.includes('gfx.polygon(') && !worldSystem.includes('ui.Hero('),
  'no surface, std/gfx or screens of sections in the 3D language')
assert.ok(!worldSystem.includes('FULL-CANVAS APPS'))

// The play check refuses a surface that never moves, one that traps mid-game, and a program with no surface: on a game
// with rounds (examples/surface-catch.vera, a fixture, not what the guide shows).
const catchGame = exampleFile('surface-catch.vera')
const still = catchGame.replace('if (state.phase !== "playing") {\n    if (p.phase !== "down") {', 'if (true) {\n    if (true) {')
assert.match(playSurface(compileVeraSource(still)), /nothing on the surface changed/, 'a game that never starts is refused')
const trapping = catchGame.replace('let dt: number = math.min(elapsedMs, 50) / 1000;',
  'let dt: number = math.min(elapsedMs, 50) / 1000;\n  if (state.stars.length() > 1) { let none: Star[] = []; dt = none[1].y; }')
assert.match(playSurface(compileVeraSource(trapping)), /^\d+:1 R\d+ The program compiled, but stopped in onFrame at frame \d+/, 'a trap mid-game says where')
assert.match(playSurface(compileVeraSource('@jsonable class AppState { n: number; }\nfunction init(): AppState { return {n: 0}; }\n' +
  'function view(state: AppState): ui.View { return ui.AppTheme("clean", "", [ui.Text("body", "hi"), ui.Text("body", "there")]); }')),
/draws no ui.Surface/)

// The route, with a mocked model.
function mockHost(answers) {
  const h = new AgentHost()
  h.language = language
  h.surfaceGuide = guide
  h.worldGuide = answers.worldGuide === undefined ? worldGuide : answers.worldGuide
  h.calls = {plan: [], code: []}
  h.askPlan = async (systemPrompt, user) => {
    h.calls.plan.push(systemPrompt === S.SURFACE_CLASSIFY_PROMPT ? 'surface' : 'needs')
    if (systemPrompt !== S.SURFACE_CLASSIFY_PROMPT) h.calls.needsUser = user
    else h.calls.surfaceUser = user
    return systemPrompt === S.SURFACE_CLASSIFY_PROMPT ? answers.brief : null
  }
  h.askCode = async (systemPrompt, user, budget, think) => {
    h.calls.code.push({think, repair: user.includes('SEARCH'), system: systemPrompt})
    return answers.code.shift() ?? null
  }
  return h
}
const request = prompt => Object.assign(new route.RouteRequest(), {agent: Object.assign(new AgentRequest(), {prompt})})
const brief = JSON.stringify({surface: true, title: 'Star Catch', design: 'Catch falling stars with a basket you drag.'})

;(async () => {
  // A game: designed, written, checked, served without the agent.
  let host = mockHost({brief, code: ['```vera\n' + example + '\n```']})
  let outcome = await route.buildScreen(request('a game where I catch falling stars'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT, 'the game is served')
  assert.equal(outcome.agent.source, example)
  assert.ok(outcome.agent.vbc2.length > 0)
  assert.deepEqual(host.calls.plan, ['surface'], 'the agent\'s plan is never drawn for a game')
  assert.equal(host.calls.code.length, 1)
  assert.ok(host.calls.code[0].system.includes('FULL-CANVAS APPS'), 'the writer is shown the guide')
  assert.match(outcome.agent.note, /written in 1 attempt\(s\), 0 repair round\(s\)/)

  // A game written with a mistake is repaired by edits against the play check.
  const broken = example.replace('let dt: number = math.min(elapsedMs, 50) / 1000;', 'let dt: number = math.min(elapsedMs, 50) / 1000 + nope;')
  const edit = '<<<<<<< SEARCH\n  let dt: number = math.min(elapsedMs, 50) / 1000 + nope;\n=======\n  let dt: number = math.min(elapsedMs, 50) / 1000;\n>>>>>>> REPLACE'
  host = mockHost({brief, code: [broken, edit]})
  outcome = await route.buildScreen(request('a game where I catch falling stars'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT, 'the repaired game is served')
  assert.equal(outcome.agent.source, example)
  assert.match(outcome.agent.note, /1 repair round/)

  // Nothing that plays: written twice (the second with thinking), then not built, and the agent is not asked.
  host = mockHost({brief, code: [still, 'no edits', 'no edits', still, 'no edits', 'no edits']})
  outcome = await route.buildScreen(request('a game where I catch falling stars'), host)
  assert.equal(outcome.kind, route.OUTCOME_NOT_BUILT)
  assert.match(outcome.reason, /not built \(.*\) in 2 attempt/)
  assert.deepEqual(host.calls.code.filter(c => !c.repair).map(c => c.think), [false, true], 'the second program is written with thinking on')
  assert.deepEqual(host.calls.plan, ['surface'])

  // The model says it is not a game: the agent builds it, as before.
  host = mockHost({brief: JSON.stringify({surface: false, title: '', design: ''}), code: []})
  const told = request('score keeper for a board game')
  outcome = await route.buildScreen(told, host)
  assert.equal(told.agent.sceneAllowed, false, 'a "no" keeps the plan from making a scene')
  assert.deepEqual(host.calls.plan.slice(0, 2), ['surface', 'needs'], 'a "no" goes on to the agent\'s plan')
  assert.ok(host.calls.code.every(c => !c.system.includes('FULL-CANVAS APPS')), 'and the game writer is not asked')

  // Part of the screen is drawn: the agent builds it, and its plan is told of the scene.
  host = mockHost({brief: JSON.stringify({surface: 'part', title: '', design: '', scene: 'a roulette wheel the ball lands on'}), code: []})
  outcome = await route.buildScreen(request('virtual casino roulette: bets and the bank are forms, with the wheel and ball animated'), host)
  assert.deepEqual(host.calls.plan.slice(0, 2), ['surface', 'needs'], 'a part goes on to the agent\'s plan')
  assert.match(host.calls.needsUser, /need of type scene: a roulette wheel the ball lands on/)
  assert.ok(host.calls.code.every(c => !c.system.includes('FULL-CANVAS APPS')), 'and the game writer is not asked')

  // No game words: not even asked. No guide on the host, or switched off: not asked either.
  host = mockHost({brief, code: []})
  await route.buildScreen(request('a to-do list'), host)
  assert.equal(host.calls.plan[0], 'needs')
  host = mockHost({brief, code: []}); host.surfaceGuide = ''
  await route.buildScreen(request('tank battle'), host)
  assert.equal(host.calls.plan[0], 'needs')
  S.setSurfaceRouteEnabled(false)
  host = mockHost({brief, code: []})
  await route.buildScreen(request('tank battle'), host)
  assert.equal(host.calls.plan[0], 'needs')
  S.setSurfaceRouteEnabled(true)

  // A chat widget is never a game screen.
  host = mockHost({brief, code: []})
  await route.buildScreen(Object.assign(new route.RouteRequest(), {agent: Object.assign(new AgentRequest(), {prompt: 'tank battle', widget: true})}), host)
  assert.equal(host.calls.plan[0], 'needs')

  // A 3D request: designed with engine world, written on a ui.World from the world guide, played on the host's physics, served.
  const worldBrief = JSON.stringify({surface: 'whole', engine: 'world', title: 'Dice', design: 'Two dice thrown on a table; the total shows.'})
  host = mockHost({brief: worldBrief, code: ['```vera\n' + worldDice + '\n```']})
  outcome = await route.buildScreen(request('3D dice game'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT, 'the 3D app is served')
  assert.equal(outcome.agent.source, worldDice.trim())
  assert.ok(outcome.agent.vbc2.length > 0)
  assert.deepEqual(host.calls.plan, ['surface'], 'the agent\'s plan is never drawn for a 3D app')
  assert.equal(host.calls.code.length, 1)
  assert.ok(host.calls.code[0].system.includes('3D WORLD APPS') && !host.calls.code[0].system.includes('FULL-CANVAS APPS'),
    'the writer is shown the world guide, not the surface guide')
  assert.match(outcome.agent.note, /^world "Dice": written in 1 attempt\(s\), 0 repair round\(s\)/)
  assert.equal(JSON.parse(outcome.agent.composed.sketch).engine, 'world')

  // A 3D program whose dice result is never read is refused by the world's play and repaired by edits against it.
  const unread = worldDice.replace('return {throws: state.throws, read: state.throws, total: total, faces: faces};', 'return state;')
  assert.notEqual(unread, worldDice)
  assert.match(S.checkWorldProgram(unread), /^\d+:1 P0007 /)
  const fix = '<<<<<<< SEARCH\n  return state;\n}\n\nfunction view\n=======\n  return {throws: state.throws, read: state.throws, total: total, faces: faces};\n}\n\nfunction view\n>>>>>>> REPLACE'
  host = mockHost({brief: worldBrief, code: [unread, fix]})
  outcome = await route.buildScreen(request('3D dice game'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT, 'the repaired 3D app is served')
  assert.equal(outcome.agent.source, worldDice.trim())
  assert.match(outcome.agent.note, /1 repair round/)
  assert.ok(host.calls.code[1].repair, 'the second ask is a repair')

  // A flat game written for a 3D brief does not pass: a 3D program must show a ui.World.
  host = mockHost({brief: worldBrief, code: [example, 'no edits', 'no edits', example, 'no edits', 'no edits']})
  outcome = await route.buildScreen(request('3D dice game'), host)
  assert.equal(outcome.kind, route.OUTCOME_NOT_BUILT)
  assert.match(outcome.reason, /^world "Dice": not built/)

  // Without "3D" in the request, a world brief is written flat: dice, planets or a tower may well be wanted in 2D. The
  // classifier is told which, and the host holds to it whatever it answers.
  for (const p of ['3D dice game', 'a 3d solar system', 'three-dimensional tower', '三维骰子', '3D骰子', 'dice in 3 d', 'a 3-dimensional cube I can spin',
    '3 dimensional maze', 'threedimensional planets', 'a 3D game with a 3D-printed look']) assert.ok(S.asksFor3D(p), p + ' asks for 3D')
  for (const p of ['dice game', 'solar system', 'knock down the tower', 'roll five dice', '3Dish', 'a d3 roller', 'roll 3d6 for my stats', 'roll 3 d20', '3D6 damage',
    'track my 3D-printer filament', 'log my 3D printing jobs', 'a list of 3D printed parts', 'a 13-dimensional table']) assert.ok(!S.asksFor3D(p), p + ' does not')
  host = mockHost({brief: worldBrief, code: ['```vera\n' + example + '\n```']})
  outcome = await route.buildScreen(request('dice game'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT)
  assert.ok(host.calls.code[0].system.includes('FULL-CANVAS APPS'), 'no 3D asked: written on a surface')
  assert.match(host.calls.surfaceUser, /does not ask for 3D: engine is "flat"/)
  assert.match(outcome.agent.note, /^surface "Dice"/)

  // No world guide on the host: the 3D brief is written flat, from the surface guide.
  host = mockHost({brief: worldBrief, code: ['```vera\n' + example + '\n```'], worldGuide: ''})
  outcome = await route.buildScreen(request('3D dice game'), host)
  assert.equal(outcome.kind, route.OUTCOME_AGENT)
  assert.ok(host.calls.code[0].system.includes('FULL-CANVAS APPS'))
  assert.match(outcome.agent.note, /^surface "Dice"/)

  console.log('surface-route-check ok')
})().catch(e => { console.error(e); process.exit(1) })
