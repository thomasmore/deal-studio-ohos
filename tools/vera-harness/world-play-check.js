// The pre-serve plays and the phone's frame budget (vera/VeraWorldPlay.ets, vera/VeraBudget.ets, vera/VeraSurfacePlay.ets):
// the three example worlds play and keep within budget; broken worlds are refused with the code the repair needs (two
// bodies with one id, too many bodies, a camera looking away, bodies inside one another or under the floor or off the
// table, orbits that pass through each other or their centre, a still world, thrown bodies never thrown or never settled, dice faces not read, a build too slow,
// a shot made inside its shooter, a body made from one that is not there, targets struck and never read); the surface
// examples keep within the frame budget, and a game doing 107 000 steps a frame -- the generated maze that ran at 23
// frames a second -- is refused.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {playWorld, WorldPlayReport, CODE_NOT_SEEN, CODE_OVERLAP, CODE_OUT_OF_WORLD, CODE_STILL, CODE_NO_SETTLE,
  CODE_RESULT_UNREAD, CODE_NO_WORLD, CODE_ORBITS_CROSS, CODE_TOO_SMALL, CODE_STUCK, CODE_WALKS_THROUGH, CODE_ZONE_UNREACHABLE,
  CODE_NO_TRAVEL, CODE_STRUCK_UNREAD, CODE_FROM_MISSING, CODE_ID_SHOWN, CODE_BUTTON_TWICE, CODE_SHOT_OVER, shownId} = loadVera('VeraWorldPlay')
const B = loadVera('VeraBudget')
const {playSurface} = loadVera('VeraSurfacePlay')

const example = name => fs.readFileSync(path.join(__dirname, 'examples', name + '.vera'), 'utf8')
const swap = (src, from, to) => { assert.ok(src.includes(from), 'the example still has: ' + from); return src.replace(from, to) }
const play = src => playWorld(compileVeraSource(src))
const refused = (src, code, re, what) => {
  const got = play(src)
  assert.match(got, new RegExp('^\\d+:1 ' + code + ' '), what + ' is refused with ' + code + ': ' + got)
  if (re) assert.match(got, re, what + ': ' + got)
}

// ---- the budget's arithmetic
assert.equal(B.predictFrameMs(0, 0), B.FRAME_BASE_MS)
assert.ok(Math.abs(B.predictFrameMs(107000, 0) - 36.77) < 0.01, 'the maze: about 37 ms a frame')
assert.ok(Math.abs(B.predictFrameMs(1000, 100) - (3.6 + 0.31 + 0.4)) < 1e-9)
assert.equal(B.median([5, 1, 3]), 3)
assert.equal(B.median([4, 1, 3, 2]), 2.5)
assert.equal(B.median([]), 0)

// ---- the examples play, within budget
const budgets = []
for (const name of ['world-dice', 'world-cubes', 'world-solar', 'world-basics', 'world-walk']) {
  const report = new WorldPlayReport()
  assert.equal(playWorld(compileVeraSource(example(name)), true, report), '', name + ' plays')
  assert.ok(report.slowestMs < B.WORLD_BUILD_BUDGET_MS, name + ' within budget')
  budgets.push(name + ' ' + report.slowestMs.toFixed(2) + ' ms (' + report.slowestSteps + ' steps, ' + report.bodies + ' bodies)')
  if (name === 'world-cubes') {
    // Hits reach the handler at most 1 / HIT_INTERVAL_S times a second, each a VM call plus the build after it.
    const P = loadVera('VeraPhysics')
    const perSecond = 1 / P.HIT_INTERVAL_S
    assert.ok(report.hitEvents > 0, 'the cubes hear hits')
    const ms = B.predictWorkMs(report.hitStepsMax)
    assert.ok(ms < B.WORLD_BUILD_BUDGET_MS, 'a hit delivery within budget')
    budgets.push('world-cubes hits: ' + report.hitEvents + ' delivered, the costliest ' + report.hitStepsMax + ' steps = ' + ms.toFixed(2) +
      ' ms; at ' + perSecond + ' a second at most ' + (ms * perSecond).toFixed(1) + ' ms of VM a second (was up to 4 a frame: ' +
      (ms * 4 * 60).toFixed(0) + ' ms a second)')
  }
  if (name === 'world-dice') {
    assert.ok(report.kicks > 0 && report.settledAfterKick > 0 && report.settledRead > 0, 'the dice are thrown, settle and are read')
  }
}
for (const name of ['surface-catch', 'surface-roulette']) {
  const costs = new B.FrameCosts()
  assert.equal(playSurface(compileVeraSource(example(name)), true, name === 'surface-roulette', costs), '', name + ' plays')
  assert.ok(costs.medianMs() < B.SURFACE_FRAME_BUDGET_MS, name + ' within the frame budget: ' + costs.medianMs())
  budgets.push(name + ' ' + costs.medianMs().toFixed(2) + ' ms a frame (' + costs.medianSteps() + ' steps, ' + costs.medianShapes() + ' shapes)')
}

// ---- a surface game doing the maze's work every frame is refused, pointing at its draw function
const maze = `
@jsonable class AppState { t: number; }
function init(): AppState { return {t: 0}; }
function onFrame(state: AppState, elapsedMs: number): AppState { return {t: state.t + elapsedMs}; }
function draw(state: AppState): gfx.Shape[] {
  let shapes: gfx.Shape[] = [];
  shapes.push(gfx.rect(0, 0, 360, 640, "background"));
  let depth: number = 0;
  let ray: number = 0;
  while (ray < 5350) {
    depth = depth + math.sin(ray + state.t) * 0.5;
    ray = ray + 1;
  }
  shapes.push(gfx.text(180, 320, 20, "center", "ink", ui.numberToString(math.round(depth)), true));
  return shapes;
}
function onPointer(state: AppState, p: gfx.Pointer): AppState { return state; }
function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [ui.Surface("fill", 360, 640, "draw", "onFrame", "onPointer")]);
}
`
{
  const costs = new B.FrameCosts()
  const got = playSurface(compileVeraSource(maze), true, false, costs)
  assert.ok(costs.medianSteps() > 90000 && costs.medianSteps() < 130000, 'the synthetic maze does about 107k steps a frame: ' + costs.medianSteps())
  assert.match(got, /^6:1 P0001 The program plays, but each frame takes about \d+ ms on the phone \(budget 12\)/, 'the maze is refused: ' + got)
  assert.match(got, /draw fewer shapes or do less work per frame/i)
  budgets.push('synthetic maze ' + costs.medianMs().toFixed(1) + ' ms a frame (' + costs.medianSteps() + ' steps): refused')
}

// ---- broken worlds
const dice = example('world-dice')
const cubes = example('world-cubes')
// Two bodies with one id, and more than 300 bodies: decodeScene's traps, pointed at build.
assert.match(play(swap(dice, 'scene.die("d2"', 'scene.die("d1"')), /^\d+:1 R0029 .*two bodies have the id "d1"/, 'a repeated id')
assert.match(play(swap(cubes, 'while (row < 10) {', 'while (row < 31) {')), /^\d+:1 R0028 .*at most 300 bodies/, 'too many bodies')
// The camera looks away from everything.
refused(swap(dice, 'scene.camera(0, 1.25, 0.85, 0, 0, 0, false)', 'scene.camera(0, 1.25, 0.85, 0, 1.25, 9, false)'), CODE_NOT_SEEN,
  /camera sees none of the 2 bodies/, 'a camera looking away')
// A camera far too far away sees the dice as specks.
refused(swap(dice, 'scene.camera(0, 1.25, 0.85, 0, 0, 0, false)', 'scene.camera(0, 900, 900, 0, 0, 0, false)'), CODE_NOT_SEEN, null, 'a camera miles away')
// Bodies inside one another, under the floor, off the table.
refused(swap(dice, 'scene.die("d2", 0.2, 0.3, 0.1', 'scene.die("d2", -0.18, 0.3, 0.1'), CODE_OVERLAP, /"d\d" and "d\d" start inside one another/, 'overlapping dice')
refused(swap(cubes, 'side / 2 + row * side', 'side / 2 + row * side * 0.5'), CODE_OVERLAP, null, 'a wall of cubes in one another')

// ---- orbits round one centre that pass through each other: Saturn's rings through Jupiter, the moon through Venus (a
// generated orrery, 2026-11-16), or an orbit inside its sun; laid out with room, they play.
{
  const orrery = planets => `@jsonable
class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function build(state: AppState): scene.Thing[] {
  let things: scene.Thing[] = [];
  things.push(scene.camera(0, 7, 5, 0, 0, 0, true));
  things.push(scene.glow(scene.sphere("sun", 0, 0, 0, 0.45, "#fbbf24")));
  ${planets}
  return things;
}
function onWorld(state: AppState, e: scene.Event): AppState { return {n: state.n + 1}; }
function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [ui.World("full", 0, "build", "onWorld"), ui.Text("body", ui.numberToString(state.n))]);
}`
  const planet = (id, r, at, period, extra = '') => `things.push(scene.orbit(${extra || `scene.sphere("${id}", 0, 0, 0, ${r}, "#888888")`}, "sun", ${at}, ${period}, 0));`
  const jupiter = planet('jupiter', 0.25, 2.6, 24)
  const saturn = at => planet('saturn', 0, at, 32, `scene.rings(scene.sphere("saturn", 0, 0, 0, 0.21, "#e5d3a1"), 0.28, 0.48, "#d8c9a3")`)
  refused(orrery(jupiter + '\n  ' + saturn(3.2)), CODE_ORBITS_CROSS, /"jupiter" \(orbit 2\.6\) and "saturn" \(orbit 3\.2\) pass through each other: their orbits are 0\.6 apart and the two reach 0\.73/, 'rings through a giant')
  assert.equal(play(orrery(jupiter + '\n  ' + saturn(3.4))), '', 'with room for the rings, they play')
  const venus = planet('venus', 0.14, 1.2, 9)
  const earth = planet('earth', 0.15, 1.6, 12) + '\n  things.push(scene.orbit(scene.sphere("moon", 0, 0, 0, 0.05, "#cccccc"), "earth", 0.28, 3, 0));'
  refused(orrery(venus + '\n  ' + earth), CODE_ORBITS_CROSS, /"venus" \(orbit 1\.2\) and "earth" \(orbit 1\.6\).*reach 0\.47/, 'a moon through the next planet')
  refused(orrery(planet('mercury', 0.1, 0.5, 6)), CODE_ORBITS_CROSS, /"mercury" orbits "sun" at 0\.5, inside it/, 'an orbit inside its sun')
  // Bodies sharing one orbit and one period never gain on each other: spaced round it they play (a generated ring of
  // triangles, 2026-11-17); too close round it, or at one radius with different periods, they still meet.
  const ring = (phases, periods) => phases.map((ph, k) =>
    `things.push(scene.orbit(scene.sphere("p${k}", 0, 0, 0, 0.15, "#888888"), "sun", 1, ${periods[k]}, ${ph}));`).join('\n  ')
  assert.equal(play(orrery(ring([0, 120, 240], [10, 10, 10]))), '', 'three spaced round one orbit play')
  refused(orrery(ring([0, 10], [10, 10])), CODE_ORBITS_CROSS, /"p\d" \(orbit 1\) and "p\d" \(orbit 1\).*start 0\.3 apart/, 'too close round one orbit')
  refused(orrery(ring([0, 180], [10, 14])), CODE_ORBITS_CROSS, /pass through each other/, 'one orbit, two speeds')
}
refused(swap(dice, 'scene.die("d1", -0.2, 0.3, 0.1', 'scene.die("d1", -0.2, -0.3, 0.1'), CODE_OUT_OF_WORLD, /below the table top/, 'a die under the table')
refused(swap(dice, 'scene.die("d1", -0.2, 0.3, 0.1', 'scene.die("d1", 2, 0.3, 0.1'), CODE_OUT_OF_WORLD, /outside the table/, 'a die off the table')
// A still world: nothing moves and nothing changes the state.
const still = `
@jsonable class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function build(state: AppState): scene.Thing[] {
  let things: scene.Thing[] = [];
  things.push(scene.floor("surface"));
  things.push(scene.box("a", 0, 0.5, 0, 1, 1, 1, "accent"));
  things.push(scene.sphere("b", 1.5, 0.5, 0, 0.5, "warning"));
  return things;
}
function onWorld(state: AppState, e: scene.Event): AppState { return state; }
function view(state: AppState): ui.View {
  return ui.AppTheme("clean", "", [ui.Column("default", [ui.World("default", 0, "build", "onWorld"), ui.Text("body", "x")])]);
}
`
refused(still, CODE_STILL, /nothing in the world moves/, 'a still world')
assert.equal(play(swap(still, 'return state; }', 'return {n: state.n + 1}; }')), '', 'a static world whose taps change the state is not still')
assert.equal(play(swap(still, 'scene.sphere("b", 1.5, 0.5, 0, 0.5, "warning")', 'scene.spin(scene.sphere("b", 1.5, 0.5, 0, 0.5, "warning"), 4)')), '',
  'a spinning body is not still')
// Bodies sized for reality, not for the phone: dice of 16 mm on the table are specks (a generated dice app, 2026-11-16).
refused(swap(swap(dice, 'scene.die("d1", -0.2, 0.3, 0.1, 0.16,', 'scene.die("d1", -0.2, 0.3, 0.1, 0.016,'),
  'scene.die("d2", 0.2, 0.3, 0.1, 0.16,', 'scene.die("d2", 0.2, 0.3, 0.1, 0.016,'), CODE_TOO_SMALL, /are specks on the phone/, 'dice of 16 mm')
// Dice: never thrown, thrown without a handler to hear them settle, settled and not read.
refused(swap(swap(dice, 'state.throws, 0.5 * way', '0, 0.5 * way'), 'state.throws, 0.4 * way', '0, 0.4 * way'), CODE_NO_SETTLE,
  /scene.kick are never thrown/, 'dice that are never thrown')
refused(swap(dice, 'ui.World("default", 0, "build", "onWorld")', 'ui.World("default", 0, "build", "")'), CODE_NO_SETTLE,
  /"settled" never arrived: the World has no event handler/, 'dice no handler hears')
refused(swap(dice, 'return {throws: state.throws, read: state.throws, total: total, faces: faces};', 'return state;'), CODE_RESULT_UNREAD,
  /on e.kind === "settled", read the faces/, 'a settle not read')
// A build too slow for the phone: 30 000 rounds of work per body list.
refused(swap(dice, '  let way: number = 1;', '  let way: number = 1;\n  let busy: number = 0;\n  while (busy < 30000) {\n    busy = busy + 1;\n  }'),
  B.CODE_TOO_SLOW, /a change of state takes about \d+ ms on the phone \(budget 8\)/, 'a slow build')
// A handler that traps on a tap says where.
assert.match(play(swap(dice, 'if (e.kind === "tap" || e.kind === "swipe") {', 'if (e.kind === "tap" || e.kind === "swipe") {\n    let none: number[] = [];\n    let x: number = none[3];')),
  /^\d+:1 R\d+ The program compiled, but stopped in onWorld \(a tap on body "d1"/, 'a trapping tap')
// No world at all.
assert.match(play(swap(dice, 'ui.World("default", 0, "build", "onWorld"),', '')), new RegExp('^1:1 ' + CODE_NO_WORLD + ' '), 'no ui.World')
assert.equal(playWorld(compileVeraSource(swap(dice, 'ui.World("default", 0, "build", "onWorld"),', '')), false), '', 'unless one is not required')

// ---- things that travel: the walk example plays (steered, walking, entering zones); what breaks it is refused
{
  const walk = example('world-walk')
  const report = new WorldPlayReport()
  for (const travel of ['none', 'self', 'steered', 'both']) {
    assert.equal(playWorld(compileVeraSource(walk), true, report, travel), '', 'world-walk plays for travel ' + travel)
  }
  assert.ok(report.playerMoved > 3, 'the stick held for two seconds takes the player along: ' + report.playerMoved.toFixed(2) + ' m')
  assert.ok(report.enterEvents > 0, 'the walker comes into the zone on its route: ' + report.enterEvents)
  budgets.push('world-walk: the player went ' + report.playerMoved.toFixed(2) + ' m in 2 s, ' + report.enterEvents + ' zone entries')
  const playT = (src, travel) => playWorld(compileVeraSource(src), true, null, travel)
  const refusedT = (src, travel, code, re, what) => {
    const got = playT(src, travel)
    assert.match(got, new RegExp('^\\d+:1 ' + code + ' '), what + ' is refused with ' + code + ': ' + got)
    if (re) assert.match(got, re, what + ': ' + got)
  }
  // A player boxed in by a wall round it hardly moves.
  refusedT(swap(walk, '  things.push(scene.player(me, 3, "Jump"));', '  things.push(scene.player(me, 3, "Jump"));\n' +
    '  things.push(scene.box(r + "pen1", -0.9, 0.5, 2, 0.2, 1, 3, "ink"));\n  things.push(scene.box(r + "pen2", -3.1, 0.5, 2, 0.2, 1, 3, "ink"));\n' +
    '  things.push(scene.box(r + "pen3", -2, 0.5, 0.9, 2, 1, 0.2, "ink"));\n  things.push(scene.box(r + "pen4", -2, 0.5, 3.1, 2, 1, 0.2, "ink"));'),
    'none', CODE_STUCK, /hardly moves with the stick held/, 'a player penned in')
  // A route through the post.
  refusedT(swap(walk, 'scene.box(r + "post", 0, 0.75, 0,', 'scene.box(r + "post", 4, 0.75, 1,'), 'none', CODE_WALKS_THROUGH,
    /walks through "r0-post"/, 'a route through a post')
  // Grass low enough to step over is no obstacle.
  assert.equal(playT(swap(walk, 'scene.box(r + "post", 0, 0.75, 0, 0.3, 1.5, 0.3,', 'scene.box(r + "post", 4, 0.05, 1, 0.3, 0.1, 0.3,'), 'none'), '',
    'a tuft on the route is stepped over')
  refusedT(swap(walk, 'scene.sphere(r + "roamer", 6, 0.25, -6,', 'scene.sphere(r + "roamer", 6, -0.5, -6,'), 'none', CODE_OUT_OF_WORLD,
    /walks 0.75 m below the ground/, 'a roamer under the floor')
  refusedT(swap(walk, 'scene.zone(r + "gate", 4, 0,', 'scene.zone(r + "gate", 150, 0,'), 'none', CODE_ZONE_UNREACHABLE,
    /past the edge of the floor/, 'a zone off the floor')
  refusedT(swap(walk, 'scene.zone(r + "gate", 4, 0,', 'scene.zone(r + "gate", 0, 0,'), 'none', CODE_ZONE_UNREACHABLE,
    /inside "r0-post"/, 'a zone inside the post')
  // The request's travel: a horse that only spins, where something should walk; nothing to steer, where the person steers.
  const spinner = swap(swap(walk, 'things.push(scene.path(walker(r + "walker", "#8b5a2b"), [-4, -4, 4, -4, 4, 4, -4, 4], 1.2 * state.pace, true));',
    'things.push(scene.spin(walker(r + "walker", "#8b5a2b"), 8));'),
    'things.push(scene.wander(scene.sphere(r + "roamer", 6, 0.25, -6, 0.25, "white"), 2, 0.5 * state.pace));', '')
  refusedT(spinner, 'self', CODE_NO_TRAVEL, /scene.spin only turns a body where it stands/, 'a walker that only spins')
  assert.equal(playT(spinner, 'none'), '', 'a spin is fine where nothing has to travel')
  const unsteered = swap(walk, 'things.push(scene.player(me, 3, "Jump"));', 'things.push(scene.loose(me, 1));')
  refusedT(unsteered, 'steered', CODE_NO_TRAVEL, /wrap it in scene.player/, 'nothing to steer')
  refusedT(unsteered, 'both', CODE_NO_TRAVEL, /wrap it in scene.player/, 'nothing to steer, both asked')
  // A camera the program fixed loses the player as it goes.
  const alone = camera => `
@jsonable class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function build(state: AppState): scene.Thing[] {
  let things: scene.Thing[] = [];
  things.push(scene.floor("surface"));
  ${camera}
  things.push(scene.player(scene.box("me", 0, 0.3, 0, 0.6, 0.6, 0.6, "accent"), 3, ""));
  return things;
}
function view(state: AppState): ui.View { return ui.AppTheme("clean", "", [ui.World("fill", 0, "build", "")]); }
`
  // A scene.camera beside a player is set aside: the camera follows the player, so it cannot lose it.
  assert.equal(playT(alone('things.push(scene.camera(0, 3, 0.5, 0, 0.3, 0, false));'), 'steered'), '', 'a fixed camera gives way to following the player')
  assert.equal(playT(alone(''), 'steered'), '', 'with no camera the player is followed')
}

// ---- shooting and breaking: the player's second button fires shots along the way it faces, a tap aims one from a
// fixed launcher, targets struck hard are split, a blast is a throw that settles; what breaks it is refused
{
  const shoot = example('world-shoot')
  const smash = example('world-break')
  const report = new WorldPlayReport()
  for (const travel of ['none', 'steered']) {
    assert.equal(playWorld(compileVeraSource(shoot), true, report, travel), '', 'world-shoot plays for travel ' + travel)
  }
  assert.equal(report.playerPresses, 6, 'Jump and Fire are each pressed three times')
  assert.ok(report.struckEvents > 0 && report.struckRead > 0, 'shots strike the crates and the handler reads it: ' +
    report.struckEvents + ' struck, ' + report.struckRead + ' changed the state')
  budgets.push('world-shoot: ' + report.struckEvents + ' struck (' + report.struckRead + ' read), ' + report.slowestMs.toFixed(2) + ' ms')
  const breakReport = new WorldPlayReport()
  assert.equal(playWorld(compileVeraSource(smash), true, breakReport), '', 'world-break plays')
  assert.ok(breakReport.struckEvents > 0 && breakReport.struckRead > 0, 'tapped shots strike the tower: ' + breakReport.struckEvents)
  assert.ok(breakReport.kicks > 0 && breakReport.settledAfterKick > 0, 'the blast is a throw, and settled follows it')
  assert.ok(breakReport.slowestMs < B.WORLD_BUILD_BUDGET_MS, 'world-break within budget')
  budgets.push('world-break: ' + breakReport.struckEvents + ' struck (' + breakReport.struckRead + ' read), ' +
    breakReport.slowestMs.toFixed(2) + ' ms (' + breakReport.slowestSteps + ' steps)')
  // A shot made inside the one who shoots it is moved ahead of it by the host, and plays.
  assert.equal(play(swap(shoot, 'scene.sphere(r + "ball" + ui.numberToString(s), 0.6, 0, 0,', 'scene.sphere(r + "ball" + ui.numberToString(s), 0.1, 0, 0,')),
    '', 'a shot built inside the player starts clear of it')
  // A shot from a body that is not there (the id without its round).
  refused(swap(shoot, 'scene.shoot(ball, 14, false), r + "me", 0)', 'scene.shoot(ball, 14, false), "me", 0)'), CODE_FROM_MISSING,
    /"r0-ball0" is made with scene.from\("me"\) and there is no body "me"/, 'a shot from nowhere')
  // Targets struck and never read.
  refused(swap(smash, 'if (e.kind === "struck" && e.speed > 4) {', 'if (e.kind === "struck" && e.speed > 400) {'), CODE_STRUCK_UNREAD,
    /scene.target bodies were struck \d+ time\(s\) and onWorld left the state as it was/, 'struck never read')
  // The screen shows an id (a broken crate's) instead of saying what it is.
  refused(swap(shoot, 'result = ui.numberToString(state.score) + " of 7 crates smashed";', 'result = "Smashed " + state.broken[0];'),
    CODE_ID_SHOWN, /the screen showed the id "r0-crate\d"/, 'an id on the screen')
  assert.equal(shownId(['3 of 7 crates smashed', 'Sun'], ['sun', 'r0-crate1']), '', 'words and plain ids are not ids shown')
  assert.equal(shownId(['Hit shot6'], ['shot6']), 'shot6', 'an id with a number is')
  // Fire again as a ui.Button under the world: the same control twice.
  refused(swap(shoot, 'ui.Button("secondary", "Start again", "onReset", 0, true)', 'ui.Button("primary", "fire", "onReset", 0, true)'),
    CODE_BUTTON_TWICE, /the button "fire" under the world repeats the one the host draws beside the stick/, 'a stick button repeated')
  // A straight shot started high above the shooter's centre passes over every crate.
  refused(swap(shoot, 'scene.sphere(r + "ball" + ui.numberToString(s), 0.6, 0, 0,', 'scene.sphere(r + "ball" + ui.numberToString(s), 0.6, 1.5, 0,'),
    CODE_SHOT_OVER, /shot "r0-ball0" starts [\d.]+ m above the ground and flies straight, over everything it could hit .*taken about the centre of "r0-me"/,
    'a shot over every target')
  // A shot is not held to where loose bodies start (P0004): one fired from past the floor's edge still plays.
  assert.equal(play(swap(swap(smash, 'scene.sphere(r + "ball" + ui.numberToString(s), 0.6, 0, 0,', 'scene.sphere(r + "ball" + ui.numberToString(s), 0, 0.5, 120,'),
    'things.push(scene.from(scene.aim(scene.shoot(ball, 14, false), state.aimX, state.aimY, state.aimZ), "launcher", 0));',
    'things.push(scene.aim(scene.shoot(ball, 14, false), state.aimX, state.aimY, state.aimZ));')), '',
    'a shot made beyond the floor plays')
}

console.log('world-play-check ok\n  ' + budgets.join('\n  '))
