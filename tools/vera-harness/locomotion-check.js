// Moving through a world on the host: scene.path, scene.wander, scene.player, scene.follow, scene.zone and scene.swing.
// Each verb's contract and refusals, a route walked continuously and closed, there and back, turning its corners, a
// wander that stays within its radius at about its speed, a new speed going on from where a body is, the diffs that must
// not put a walking body back where it was built, a player driven by the stick, zones that tell only real entries, the
// follow camera catching up, and a swinging leg.
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const {compileVeraSource} = loadVera('VeraCompiler')
const {VeraNumberValue, VeraStringValue, VeraBooleanValue, VeraArrayValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment} = loadVera('VeraUi')
const S = loadVera('VeraScene')
const L = loadVera('VeraLocomotion')
const look = loadVera('VeraLook3D')

const host = new UiHostEnvironment()
const wrapArg = a => typeof a === 'number' ? new VeraNumberValue(a) : typeof a === 'string' ? new VeraStringValue(a)
  : typeof a === 'boolean' ? new VeraBooleanValue(a) : Array.isArray(a) ? new VeraArrayValue(a.map(wrapArg)) : a
const call = (name, ...args) => host.invoke('std/scene', name, args.map(wrapArg), false)
const box = (id, x = 0, y = 0.5, z = 0, size = 1) => call('box', id, x, y, z, size, size, size, 'ink')
const world = items => S.decodeScene(new VeraArrayValue(items))
const traps = (fn, re, msg) => assert.throws(fn, e => re.test(e.message), msg + ' (' + re + ')')
const near = (a, b, eps, msg) => assert.ok(Math.abs(a - b) <= eps, msg + ': ' + a + ' vs ' + b)
const codes = src => {
  try { compileVeraSource(src); return [] } catch (e) { if (!e.diagnostics) throw e; return e.diagnostics.map(d => d.code + ' ' + d.message) }
}

// ---- the verbs compile and are described to the model
const program = body => `
@jsonable class AppState { n: number; }
function init(): AppState { return {n: 0}; }
function build(state: AppState): scene.Thing[] {
  let things: scene.Thing[] = [];
  ${body}
  return things;
}
function onWorld(state: AppState, e: scene.Event): AppState { if (e.kind === "enter" || e.kind === "action") { return {n: state.n + 1}; } return state; }
function view(state: AppState): ui.View { return ui.AppTheme("clean", "", [ui.World("fill", 0, "build", "onWorld")]); }
`
assert.deepEqual(codes(program(`
  things.push(scene.floor("surface"));
  let leg: scene.Thing = scene.swing(scene.box("leg", 0.3, 0.2, 0, 0.1, 0.4, 0.1, "ink"), 25, 0.8, 0);
  let horse: scene.Thing = scene.group("horse", 0, 0, 0, [scene.box("body", 0, 0.6, 0, 1, 0.4, 0.4, "accent"), leg]);
  things.push(scene.path(horse, [0, 0, 4, 0, 4, 4], 1.2, true));
  things.push(scene.wander(scene.box("sheep", 3, 0.3, 3, 0.6, 0.6, 0.6, "white"), 2, 0.5));
  things.push(scene.player(scene.box("me", -2, 0.5, 0, 1, 1, 1, "ink"), 3, "Jump"));
  things.push(scene.zone("goal", 5, 5, 1, "accent"));`)), [], 'the new verbs compile')
assert.ok(codes(program('things.push(scene.zone("", 0, 0, 1, "accent"));')).some(c => c.includes('needs an id')), 'a zone needs an id')
const prompt = S.describeSceneForPrompt()
for (const word of ['scene.path(', 'scene.wander(', 'scene.player(', 'scene.follow(', 'scene.zone(', 'scene.swing(', '"enter"', '"action"',
  'front of a body is its +x side', 'takes it nowhere']) {
  assert.ok(prompt.includes(word), 'the prompt says ' + word)
}

// ---- refusals
traps(() => call('path', box('a'), [0, 0], 1, true), /2 to 64 corners/, 'one corner is not a route')
traps(() => call('path', box('a'), [0, 0, 1], 1, true), /2 to 64 corners/, 'an odd count is not a route')
traps(() => call('path', box('a'), [1, 1, 1, 1], 1, true), /all in one place/, 'a route that goes nowhere')
traps(() => call('path', box('a'), [0, 0, 1, 0], -1, true), /0 or more/, 'a negative speed')
traps(() => call('path', call('loose', box('a'), 1), [0, 0, 1, 0], 1, true), /is loose/, 'a loose body does not follow a path')
traps(() => call('path', call('spin', box('a'), 2), [0, 0, 1, 0], 1, true), /orbits or spins/, 'a spinning body does not follow a path')
traps(() => call('spin', call('path', box('a'), [0, 0, 1, 0], 1, true), 2), /follows a path or wanders/, 'a walking body does not spin')
traps(() => call('orbit', call('wander', box('a'), 1, 1), 'c', 1, 1, 0), /follows a path or wanders/, 'a wandering body does not orbit')
traps(() => call('wander', call('path', box('a'), [0, 0, 1, 0], 1, true), 1, 1), /already follows a path/, 'one way of travelling')
traps(() => call('wander', box('a'), 0, 1), /radius must be more than 0/, 'a wander needs room')
traps(() => call('player', call('wander', box('a'), 1, 1), 2, ''), /cannot also be the player/, 'a wandering player')
traps(() => call('path', call('player', box('a'), 2, ''), [0, 0, 1, 0], 1, true), /the player/, 'a player on a path')
traps(() => call('player', box('a'), 0, ''), /speed must be more than 0/, 'a player that cannot go')
traps(() => world([call('floor', 'surface'), call('player', box('a'), 2, ''), call('player', box('b', 3), 2, '')]), /one player/, 'two players')
traps(() => world([call('swing', box('a'), 20, 1, 0)]), /for a part of a scene.group/, 'a swing on a body')
traps(() => call('swing', call('group', 'g', 0, 0, 0, [box('p')]), 20, 1, 0), /not a group/, 'a swing on a group')
traps(() => call('group', 'g', 0, 0, 0, [call('path', box('p'), [0, 0, 1, 0], 1, true)]), /wrap the group instead/, 'a part on a path')
traps(() => world([call('camera', 0, 2, 5, 0, 0, 0, false), call('follow', box('a'), 3, 1)]), /scene.camera and a scene.follow/, 'camera and follow')
traps(() => world([call('follow', box('a'), 3, 1), call('follow', box('b', 3), 3, 1)]), /follows one body/, 'two follows')
traps(() => world([call('zone', 'z', 0, 0, 1, 'accent'), call('zone', 'z', 1, 0, 1, 'accent')]), /zone needs an id of its own/, 'two zones, one id')
traps(() => world([box('z'), call('zone', 'z', 1, 0, 1, 'accent')]), /id of its own/, 'a zone with a body\'s id')
traps(() => world([call('zone', 'z', 1, 0, 1, 'accent'), box('z')]), /id of its own/, 'a body with a zone\'s id')
traps(() => world(Array.from({length: S.MAX_WORLD_ZONES + 1}, (_, i) => call('zone', 'z' + i, i, 0, 0.4, 'accent'))), /at most 32 zones/, 'the zone cap')

// ---- decode
{
  const w = world([call('floor', 'surface'), call('player', call('kick', box('me', 0, 0.5, 0), 0, 0, 4, 0, 0), 3, 'Jump'),
    call('zone', 'goal', 5, -2, 1.5, 'accent')])
  const me = w.bodies[0]
  assert.equal(me.motion, 'loose', 'a player is loose')
  assert.equal(me.mass, 1)
  assert.deepEqual([me.player.speed, me.player.action], [3, 'Jump'])
  assert.deepEqual(w.zones.map(z => [z.id, z.x, z.z, z.r]), [['goal', 5, -2, 1.5]])
  assert.equal(w.follow.target, 'me', 'a world with a player and no camera follows it')
  assert.ok(w.follow.distance >= S.FOLLOW_MIN_BACK && w.follow.height >= S.FOLLOW_MIN_UP)
  const fixed = world([call('camera', 0, 3, 6, 0, 0, 0, false), call('player', box('me'), 3, '')])
  assert.equal(fixed.follow, null, 'with the program\'s camera there is no follow')
  const chosen = world([call('follow', call('wander', box('cow'), 2, 1), 4, 2)])
  assert.deepEqual([chosen.follow.target, chosen.follow.distance, chosen.follow.height], ['cow', 4, 2], 'scene.follow on any body')
  const walker = world([call('path', box('w', 9, 0.5, 9), [0, 0, 2, 0], 1, false)]).bodies[0]
  assert.equal(walker.motion, 'kinematic', 'a path is the host\'s to move')
}

// ---- a path: continuous, closed, there and back, turning its corners
{
  const square = world([call('path', box('w', 0, 0.5, 0), [0, 0, 4, 0, 4, 4, 0, 4], 2, true)]).bodies[0]
  const at = t => S.orbitPositions({bodies: [square]}, t).get('w')
  assert.deepEqual(at(0).slice(0, 3), [0, 0.5, 0], 'it starts at the first corner, at its own height')
  near(at(0)[4], 45, 1e-6, 'at the first corner of a loop it is half way round from the closing side')
  near(at(1)[0], 2, 1e-9, 'two metres a second along the first side')
  // 16 m round: 8 s a lap.
  for (const t of [0.3, 2.7, 5.1]) {
    const a = at(t), b = at(t + 8)
    near(Math.hypot(a[0] - b[0], a[2] - b[2]), 0, 1e-9, 'a lap later it is where it was, at ' + t)
  }
  let worst = 0
  for (let k = 1; k < 1600; k++) {
    const a = at((k - 1) / 100), b = at(k / 100)
    worst = Math.max(worst, Math.hypot(a[0] - b[0], a[2] - b[2]))
  }
  assert.ok(worst <= 0.0201, 'it never jumps, corners and the closing side included: ' + worst)
  // Heading: +x is 0, the second side (+z) is -90, the third (-x) 180, the closing side (-z) 90.
  near(at(1)[4], 0, 1e-6, 'first side')
  near(at(3)[4], -90, 1e-6, 'second side')
  near(Math.abs(at(5)[4]), 180, 1e-6, 'third side')
  near(at(7)[4], 90, 1e-6, 'closing side')
  const corner = at(2)[4]
  assert.ok(corner < -10 && corner > -80, 'at a corner it is half way round the turn: ' + corner)
  const turned = world([call('path', call('turn', box('w'), 0, 90, 0), [0, 0, 4, 0], 1, true)]).bodies[0]
  near(S.orbitPositions({bodies: [turned]}, 1).get('w')[4], 90, 1e-6, 'scene.turn adds to the heading (a model built facing the other way)')

  const line = world([call('path', box('w'), [0, 0, 3, 0], 1, false)]).bodies[0]
  const lat = t => S.orbitPositions({bodies: [line]}, t).get('w')
  near(lat(2)[0], 2, 1e-9, 'there...')
  near(lat(4)[0], 2, 1e-9, '...and back')
  near(Math.abs(lat(4)[4]), 180, 1e-6, 'facing the way back')
  near(lat(6)[0], 0, 1e-9, 'home after twice its length')
  const two = world([call('path', box('w'), [0, 0, 3, 0], 1, true)]).bodies[0]
  near(S.orbitPositions({bodies: [two]}, 4).get('w')[0], 2, 1e-9, 'a loop of two corners is a there-and-back')
  const still = world([call('path', box('w'), [1, 1, 3, 1], 0, true)]).bodies[0]
  assert.deepEqual(S.orbitPositions({bodies: [still]}, 50).get('w').slice(0, 3), [1, 0.5, 1], 'speed 0 stands it at the start')
  near(S.travelPace(still, 3), 0, 0, 'a body standing has no stride')
  near(S.travelPace(square, 3), 1, 0, 'a body going has its full stride')
  // At the far turnaround, where the way there and back fold onto one point, it faces the way it came in.
  const ell = world([call('path', box('w'), [0, 0, 3, 0, 3, 3], 1, false)]).bodies[0]
  near(S.orbitPositions({bodies: [ell]}, 6).get('w')[4], -90, 1e-6, 'at the far end it faces along the last side, not the first')
  near(S.orbitPositions({bodies: [ell]}, 5.99).get('w')[4], -90, 1e-6, 'as it did coming in')
}

// ---- a wander: within its radius, at about its speed, pausing, turning the way it goes
{
  for (const [id, radius, speed] of [['cow', 3, 0.6], ['sheep-7', 1.5, 0.3], ['r1-dog', 6, 2]]) {
    const b = world([call('wander', box(id, 2, 0.5, -1), radius, speed)]).bodies[0]
    const at = t => S.orbitPositions({bodies: [b]}, t).get(id)
    let far = 0, travelled = 0, slowest = Infinity, fastest = 0, headingErr = 0
    let prev = at(0)
    const dt = 0.05
    for (let k = 1; k <= 12000; k++) {
      const p = at(k * dt)
      far = Math.max(far, Math.hypot(p[0] - 2, p[2] + 1))
      const step = Math.hypot(p[0] - prev[0], p[2] - prev[2])
      travelled += step
      if (k % 20 === 0) { slowest = Math.min(slowest, step / dt); fastest = Math.max(fastest, step / dt) }
      if (step > speed * dt * 0.3) {
        const h = Math.atan2(-(p[2] - prev[2]), p[0] - prev[0]) * 180 / Math.PI
        headingErr = Math.max(headingErr, Math.abs(L.turnDeg(h, prev[4] + L.turnDeg(prev[4], p[4]) / 2)))
      }
      assert.equal(p[1], 0.5, 'its height is kept')
      prev = p
    }
    assert.ok(far <= radius + 1e-9, id + ' stays within its radius: ' + far)
    assert.ok(far >= radius * 0.4, id + ' uses its room: ' + far)
    const mean = travelled / 600
    assert.ok(Math.abs(mean - speed) <= speed * 0.3, id + ' goes at about its speed: ' + mean.toFixed(3) + ' for ' + speed)
    assert.ok(slowest < speed * 0.35, id + ' slows down now and then: ' + slowest.toFixed(3))
    assert.ok(headingErr < 15, id + ' faces the way it goes: ' + headingErr.toFixed(2))
    let snap = 0
    for (let k = 1; k <= 12000; k++) snap = Math.max(snap, Math.abs(L.turnDeg(at((k - 1) * dt)[4], at(k * dt)[4])) / dt)
    assert.ok(snap < 400, id + ' never snaps round: at most ' + snap.toFixed(0) + ' degrees a second')
    assert.deepEqual(at(77.7), at(77.7), 'pure')
  }
  const a = world([call('wander', box('a'), 2, 1)]).bodies[0]
  const b = world([call('wander', box('b'), 2, 1)]).bodies[0]
  assert.notDeepEqual(S.orbitPositions({bodies: [a]}, 10).get('a').slice(0, 3), S.orbitPositions({bodies: [b]}, 10).get('b').slice(0, 3),
    'two animals roam differently')
}

// ---- a new speed goes on from where the body is
{
  const mk = speed => world([call('path', box('w'), [0, 0, 10, 0, 10, 10, 0, 10], speed, true)])
  const carry = new S.MotionCarry()
  const slow = mk(1)
  carry.apply(slow, 0)
  const before = S.orbitPositions(slow, 7.5).get('w')
  const fast = mk(3)
  carry.apply(fast, 7.5)
  const after = S.orbitPositions(fast, 7.5).get('w')
  near(Math.hypot(before[0] - after[0], before[2] - after[2]), 0, 1e-9, 'a faster path goes on from where it was')
  near(S.orbitPositions(fast, 8.5).get('w')[0], 10, 1e-9, 'and at the new speed (7.5 + 3 = 10.5 m: the corner)')
  const stop = mk(0)
  carry.apply(stop, 8.5)
  const stood = S.orbitPositions(stop, 8.5).get('w')
  near(S.orbitPositions(stop, 30).get('w')[0], stood[0], 1e-9, 'speed 0 stands it where it is')
  const reroute = world([call('path', box('w'), [5, 5, 6, 5], 1, true)])
  carry.apply(reroute, 9)
  assert.equal(reroute.bodies[0].travelStart, 0, 'a new route starts again')

  const wmk = speed => world([call('wander', box('cow', 1, 0.5, 1), 3, speed)])
  const wc = new S.MotionCarry()
  const w1 = wmk(0.5)
  wc.apply(w1, 0)
  const wb = S.orbitPositions(w1, 13).get('cow')
  const w2 = wmk(1.5)
  wc.apply(w2, 13)
  const wa = S.orbitPositions(w2, 13).get('cow')
  near(Math.hypot(wb[0] - wa[0], wb[2] - wa[2]), 0, 1e-9, 'a faster wander goes on from where it was')
}

// ---- diffs that must not put a body back where it was built
{
  const scene = (speed, colour, label, mark) => {
    const parts = [call('box', 'b', 0, 0.6, 0, 1, 0.4, 0.4, colour), call('swing', call('box', 'l', 0.3, 0.2, 0, 0.1, 0.4, 0.1, 'ink'), 20, 1, 0)]
    let horse = call('group', 'horse', 0, 0, 0, parts)
    if (mark) horse = call('mark', horse, 'accent')
    return world([call('floor', 'surface'), call('player', horse, speed, label), call('path', box('w', 0, 0.5, 4), [0, 4, 4, 4], speed, true)])
  }
  const w = scene(2, 'accent', 'Jump', false)
  const d = S.diffWorld(w, scene(4, 'accent', 'Go', false))
  assert.deepEqual([d.recreate.length, d.create.length, d.remove.length], [0, 0, 0], 'a new speed or label makes nothing again')
  const c = S.diffWorld(w, scene(2, 'ink', 'Jump', false))
  assert.deepEqual(c.recreate.map(b => b.id), [], 'a part\'s new colour does not make the player again')
  assert.deepEqual(c.material.map(b => b.id), ['horse'], 'it is a material update')
  const unplayer = world([call('floor', 'surface'), call('loose', call('group', 'horse', 0, 0, 0, [box('b')]), 1)])
  const replayer = world([call('floor', 'surface'), call('player', call('group', 'horse', 0, 0, 0, [box('b')]), 2, '')])
  assert.deepEqual(S.diffWorld(unplayer, replayer).recreate.map(b => b.id), ['horse'], 'becoming the player makes the body again')
  const z1 = world([call('zone', 'z', 0, 0, 1, 'accent')])
  const z2 = world([call('zone', 'z', 1, 0, 1, 'accent')])
  assert.ok(S.diffWorld(z1, z2).zonesChanged && !S.diffWorld(z1, world([call('zone', 'z', 0, 0, 1, 'accent')])).zonesChanged, 'zones diff')
  assert.ok(S.diffWorld(w, world([call('floor', 'surface'), call('player', box('other'), 2, '')])).cameraChanged, 'a new player is followed afresh')
  assert.ok(!S.diffWorld(w, scene(4, 'accent', 'Jump', false)).cameraChanged, 'the same player is still followed')
}

// ---- the player's driving
{
  const drive = new L.PlayerDrive()
  let yaw = 0, x = 0, z = 0, vx = 0, vz = 0
  const dt = 1 / 60
  const run = (frames, dx, dz, push) => {
    for (let f = 0; f < frames; f++) {
      const v = drive.step(yaw, dx, dz, push, 4, dt, vx, vz)
      vx = v[0]; vz = v[1]
      x += v[0] * dt; z += v[1] * dt; yaw += v[2] * dt * 180 / Math.PI
    }
  }
  run(60, 1, 0, 1)
  near(drive.speed, 4, 1e-9, 'it comes up to speed within a second (8 m/s²)')
  assert.ok(x > 2.5 && x < 3.1, 'and has gone about 3 m: ' + x)
  run(30, 0, 1, 1)
  near(L.turnDeg(yaw, -90), 0, 25, 'pushed towards +z it turns to face it: ' + yaw)
  assert.ok(z > 0.3, 'and goes that way: ' + z)
  const turnStart = yaw
  drive.step(yaw, -1, 0, 1, 4, dt, vx, vz)
  const wy = drive.step(yaw, -1, 0, 1, 4, dt, vx, vz)[2] * 180 / Math.PI
  assert.ok(Math.abs(wy) <= L.PLAYER_TURN_DEG_S + 1e-9, 'turning is capped: ' + wy)
  run(60, 0, 0, 0)
  assert.equal(drive.speed, 0, 'let go, it stops within a second')
  assert.equal(drive.moving(), false)
  const v = drive.step(yaw, 1, 0, 0.05, 4, dt)
  assert.deepEqual(v.map(n => Math.abs(n)), [0, 0, 0], 'a stick barely touched is let go')
  // Knocked while let go: the going it was given runs out, at PLAYER_BRAKE.
  vx = 3; vz = 0
  run(1, 0, 0, 0)
  near(vx, 3 - L.PLAYER_BRAKE * dt, 1e-9, 'a knocked player brakes from the velocity it really has')
  run(30, 0, 0, 0)
  assert.equal(drive.speed, 0, 'and stops within half a second')
  // A dash across the stick: not undone at once, it runs out towards the stick's going.
  vx = 0; vz = 0
  run(60, 0, 1, 1)
  vx = 6
  run(1, 0, 1, 1)
  assert.ok(vx > 5.5, 'a dash across the held stick is kept, nearly: ' + vx)
  run(60, 0, 1, 1)
  assert.ok(Math.abs(vx) < 0.05 && Math.abs(vz - 4) < 0.05, 'and runs out into the stick\'s going: ' + vx + ' ' + vz)
  // Held into a wall: the body goes nowhere, so its speed is about none, not the stick's.
  vx = 0; vz = 0
  const pinned = drive.step(yaw, 1, 0, 1, 4, dt, 0, 0)
  assert.ok(drive.speed <= L.PLAYER_ACCEL * dt + 1e-9 && pinned[0] > 0, 'against a wall its speed is what it really goes at')
  const r = L.yawOf(look.quatXYZ(0, 37, 0))
  near(r, 37, 1e-9, 'the heading of a turn about y')
  near(L.yawOf(look.quatXYZ(10, -120, 5)), -120, 6, 'nearly so when tipped a little')
  void turnStart
}

// ---- zones
{
  const zones = world([call('zone', 'goal', 5, 0, 1, 'accent'), call('zone', 'start', 0, 0, 1, 'accent')]).zones
  const watch = new L.ZoneWatch()
  const at = (p, q) => new Map(Object.entries({me: p, ...(q ? {cow: q} : {})}))
  assert.deepEqual(watch.update(zones, at([0, 0.5, 0])), [], 'made inside the start zone: not an entry')
  assert.deepEqual(watch.update(zones, at([2, 0.5, 0])), [], 'out of it')
  assert.deepEqual(watch.update(zones, at([4.2, 0.5, 0.3])).map(e => [e.body, e.zone]), [['me', 'goal']], 'into the goal')
  assert.deepEqual(watch.update(zones, at([4.5, 0.5, 0])), [], 'still in it: told once')
  assert.deepEqual(watch.update(zones, at([7, 0.5, 0])), [], 'out')
  assert.deepEqual(watch.update(zones, at([5, 0.5, 0])).map(e => e.zone), ['goal'], 'in again: told again')
  assert.deepEqual(watch.update(zones, at([5, 0.5, 0], [5.2, 0.4, 0])), [], 'a body made inside it is not an entry')
  const moved = world([call('zone', 'goal', 9, 0, 1, 'accent'), call('zone', 'far', 20, 0, 1, 'accent')]).zones
  watch.update(moved, at([0, 0, 0]))
  assert.deepEqual(watch.update(moved, at([20, 0, 0])).map(e => e.zone), ['far'], 'a zone seen before tells')
  const fresh = [...moved, ...world([call('zone', 'new', 20, 0, 1, 'accent')]).zones]
  assert.deepEqual(watch.update(fresh, at([20, 0, 0])), [], 'a zone put round a body is not an entry')
  // The same zone moved (a new round's goal) onto a body that stands still: not an entry, and coming in later is.
  const shifted = world([call('zone', 'goal', 0, 0, 1, 'accent')]).zones
  watch.update(moved, at([0, 0, 0]))
  assert.deepEqual(watch.update(shifted, at([0, 0, 0])), [], 'a zone moved onto a standing body is not an entry')
  const grown = world([call('zone', 'goal', 9, 0, 9.5, 'accent')]).zones
  watch.update(moved, at([0, 0, 0]))
  assert.deepEqual(watch.update(grown, at([0, 0, 0])), [], 'nor one grown round it')
  watch.update(grown, at([-12, 0, 0]))
  assert.deepEqual(watch.update(grown, at([0, 0, 0])).map(e => e.zone), ['goal'], 'coming into the moved zone is')
}

// ---- the follow camera
{
  const f = new L.Follower()
  const pose = new look.CameraPose()
  const spec = {target: 'me', distance: 4, height: 2}
  f.snap(pose, [0, 0.5, 0], 0, spec)
  assert.deepEqual(pose.eye.map(v => +v.toFixed(9)), [-4, 2.5 + 0.3, 0], 'behind the body (facing +x) and above it')
  assert.ok(pose.far >= look.PLAYER_FLOOR, 'it sees far: ' + pose.far)
  let moved = false
  for (let k = 0; k < 120; k++) moved = f.step(pose, [10, 0.5, 0], spec, 1 / 60) || moved
  assert.ok(moved && !f.behind([10, 0.5, 0], spec, 0.01), 'it catches up within two seconds: ' + pose.look)
  assert.equal(f.step(pose, [10, 0.5, 0], spec, 1 / 60), false, 'and then holds still')
  f.turn(pose, Math.PI / 2, 0, 0.05)
  near(Math.hypot(pose.eye[0] - pose.look[0], pose.eye[2] - pose.look[2]), 4, 1e-6, 'a drag turns it round the body at its distance')
  for (let k = 0; k < 120; k++) f.step(pose, [10, 0.5, 5], spec, 1 / 60)
  near(pose.eye[2] - pose.look[2], f.offset[2], 1e-9, 'and the turn is kept as it follows')
  const facing = new L.Follower()
  facing.snap(pose, [0, 0, 0], 90, spec)
  near(pose.eye[2], 4, 1e-9, 'a body facing -z is followed from +z')
}

// ---- swing
{
  const leg = world([call('group', 'g', 0, 0, 0, [box('body', 0, 1, 0), call('swing', call('box', 'leg', 0.3, 0.2, 0, 0.1, 0.4, 0.1, 'ink'), 30, 1, 0)])])
    .bodies[0].parts[1]
  const top = p => [p[0] - 0.2 * Math.sin(2 * Math.asin(p[5])), p[1] + 0.2 * Math.cos(2 * Math.asin(p[5]))]
  const rest = L.swingTurn(leg, 0, 1)
  assert.deepEqual(rest.slice(0, 3).map(v => +v.toFixed(9)), leg.position.map(v => +v.toFixed(9)), 'at the start of its swing it hangs as built')
  const out = L.swingTurn(leg, 0.25, 1)
  near(2 * Math.asin(out[5]) * 180 / Math.PI, 30, 1e-6, 'a quarter period later it is at its full swing')
  const pivot = top(out)
  near(pivot[0], leg.position[0], 1e-9, 'turned about the middle of its top (x)')
  near(pivot[1], leg.position[1] + 0.2, 1e-9, 'turned about the middle of its top (y)')
  assert.deepEqual(L.swingTurn(leg, 0.25, 0).slice(0, 3).map(v => +v.toFixed(9)), leg.position.map(v => +v.toFixed(9)), 'a body standing still: no swing')
  near(2 * Math.asin(L.swingTurn(leg, 0.25, 0.5)[5]) * 180 / Math.PI, 15, 1e-6, 'half the pace, half the swing')
  assert.ok(L.hasSwing(world([call('group', 'g', 0, 0, 0, [call('swing', box('p'), 10, 1, 0)])]).bodies[0]))
}

// ---- the player in the physics (FakePhys): steered by the stick, not waited on by a throw, never put back by a rebuild
{
  const P = loadVera('VeraPhysics')
  const FRAME_MS = 1000 / 60
  const horse = (colour, mark, kick = 0) => {
    let h = call('group', 'horse', 0, 0, 0, [call('box', 'body', 0, 0.8, 0, 1.2, 0.4, 0.4, colour),
      call('box', 'legs', 0, 0.3, 0, 1, 0.6, 0.3, 'ink')])
    if (mark) h = call('mark', h, 'accent')
    if (kick) h = call('kick', h, kick, 0, 4, 0, 0)
    return call('player', h, 3, 'Jump')
  }
  const scene = (colour = 'accent', mark = false, kick = 0, dieKick = 0) => world([call('floor', 'surface'), horse(colour, mark, kick),
    call('kick', call('die', 'd', 4, 0.15, 4, 0.3, 'white'), dieKick, 1, 3, 0, 2)])
  const sim = new P.WorldSim(new P.FakePhys())
  let spec = scene()
  sim.apply(S.diffWorld(null, spec), spec)
  assert.equal(sim.playerId(), 'horse')
  const frames = (n, t0 = 0) => { for (let f = 0; f < n; f++) sim.step(FRAME_MS, t0 + f / 60) }
  frames(30)
  const start = sim.poseOf('horse')
  assert.ok(!sim.needsFrames(), 'a player standing needs no frames')
  sim.setStick(1, 0, 1)
  assert.ok(sim.needsFrames(), 'the stick held needs frames')
  frames(120)
  const went = sim.poseOf('horse')
  const dist = went[0] - start[0]
  assert.ok(dist > 3.5 && dist < 6.2, 'held for 2 s it goes about 5 m (3 m/s after a short start): ' + dist.toFixed(2))
  near(Math.abs(went[3]) + Math.abs(went[5]), 0, 1e-6, 'upright')
  sim.setStick(0, -1, 1)
  frames(60)
  const turned = sim.poseOf('horse')
  near(L.turnDeg(L.yawOf(turned.slice(3)), 90), 0, 20, 'pushed towards -z it turns to face it: ' + L.yawOf(turned.slice(3)).toFixed(1))
  assert.ok(turned[2] < went[2] - 0.5, 'and goes that way')
  sim.setStick(0, 0, 0)
  frames(90)
  const stopped = sim.poseOf('horse')
  frames(60)
  near(Math.hypot(sim.poseOf('horse')[0] - stopped[0], sim.poseOf('horse')[2] - stopped[2]), 0, 0.01, 'let go, it stops')
  assert.ok(!sim.needsFrames(), 'and frames stop')

  // A new colour or a mark (a material update; a recreate) leaves it where the person took it.
  const here = sim.poseOf('horse')
  let next = scene('ink')
  sim.apply(S.diffWorld(spec, next), next); spec = next
  assert.deepEqual(sim.poseOf('horse').slice(0, 3).map(v => +v.toFixed(4)), here.slice(0, 3).map(v => +v.toFixed(4)), 'recoloured, it stays')
  next = scene('ink', true)
  const d = S.diffWorld(spec, next)
  assert.deepEqual(d.recreate.map(b => b.id), ['horse'], 'a mark makes it again')
  sim.apply(d, next); spec = next
  assert.deepEqual(sim.poseOf('horse').slice(0, 3).map(v => +v.toFixed(4)), here.slice(0, 3).map(v => +v.toFixed(4)), 'made again, it stays')

  // Its jump is not a throw: nothing waits to settle; a die thrown while it walks settles once.
  const serial = sim.kickSerial
  next = scene('ink', true, 1)
  sim.apply(S.diffWorld(spec, next), next); spec = next
  assert.equal(sim.kickSerial, serial, 'a jump is not a throw')
  let top = 0
  for (let f = 0; f < 60; f++) { sim.step(FRAME_MS, f / 60); top = Math.max(top, sim.poseOf('horse')[1]) }
  assert.ok(top > here[1] + 0.4, 'it jumps: ' + top.toFixed(2))
  next = scene('ink', true, 1, 1)
  sim.apply(S.diffWorld(spec, next), next); spec = next
  sim.setStick(-1, 0, 1)
  let settled = null
  for (let f = 0; f < 600 && !settled; f++) {
    sim.step(FRAME_MS, f / 60)
    settled = sim.takeEvents().find(e => e.kind === 'settled') || null
  }
  assert.ok(settled, 'a die thrown while the player walks settles')
  assert.deepEqual(settled.bodies, ['d'], 'and the player is not among what settled')
  assert.ok(sim.needsFrames(), 'the player still walking needs frames')

  // A new round: a new id starts where it was built, standing.
  const round = world([call('floor', 'surface'), call('player', call('box', 'r1-me', 0, 0.5, 0, 1, 1, 1, 'ink'), 3, '')])
  sim.setStick(0, 0, 0)
  sim.apply(S.diffWorld(spec, round), round)
  assert.deepEqual(sim.poseOf('r1-me').slice(0, 3), [0, 0.5, 0], 'a new round\'s player is where it was built')
  assert.equal(sim.playerSpeedNow(), 0, 'and starts standing')
}

// ---- the player knocked, dashing, and made the player lying on its side (FakePhys)
{
  const P = loadVera('VeraPhysics')
  const FRAME_MS = 1000 / 60
  const me = (kick = 0, vx = 0) => {
    let b = call('box', 'me', 0, 0.5, 0, 1, 1, 1, 'ink')
    if (kick) b = call('kick', b, kick, vx, 0, 0, 0)
    return call('player', b, 3, 'Dash')
  }
  const scene = (kick = 0, vx = 0) => world([call('floor', 'surface'), me(kick, vx)])
  const run = (sim, n) => { for (let f = 0; f < n; f++) sim.step(FRAME_MS, f / 60) }

  // A dash with the stick let go: it goes, then stops by itself, it does not glide on.
  let sim = new P.WorldSim(new P.FakePhys())
  let spec = scene()
  sim.apply(S.diffWorld(null, spec), spec)
  run(sim, 20)
  let next = scene(1, 6)
  sim.apply(S.diffWorld(spec, next), next); spec = next
  assert.ok(sim.needsFrames(), 'a dash needs frames')
  run(sim, 60)
  const after = sim.poseOf('me')
  assert.ok(after[0] > 1 && after[0] < 2.5, 'a dash with the stick let go takes it about 1.5 m: ' + after[0].toFixed(2))
  run(sim, 120)
  near(sim.poseOf('me')[0], after[0], 0.01, 'and then it stands: no friction of its own does not make it glide')
  assert.ok(!sim.needsFrames(), 'and frames stop')

  // A dash across the stick held: not wiped out the next step.
  sim = new P.WorldSim(new P.FakePhys())
  spec = scene()
  sim.apply(S.diffWorld(null, spec), spec)
  run(sim, 20)
  sim.setStick(0, 1, 1)
  run(sim, 60)
  const before = sim.poseOf('me')
  next = scene(1, 6)
  sim.apply(S.diffWorld(spec, next), next); spec = next
  run(sim, 30)
  const dashed = sim.poseOf('me')
  assert.ok(dashed[0] - before[0] > 1, 'a dash while the stick is held goes across it: ' + (dashed[0] - before[0]).toFixed(2))
  assert.ok(dashed[2] - before[2] > 0.5, 'and it still goes the stick\'s way')

  // A box tumbled onto its side, then made the player: it stands upright where it lay.
  sim = new P.WorldSim(new P.FakePhys())
  const lying = world([call('floor', 'surface'), call('loose', call('turn', call('box', 'me', 2, 0.5, 1, 1, 1, 1, 'ink'), 30, 40, 90), 1)])
  sim.apply(S.diffWorld(null, lying), lying)
  run(sim, 30)
  const lay = sim.poseOf('me')
  const asPlayer = world([call('floor', 'surface'), call('player', call('turn', call('box', 'me', 2, 0.5, 1, 1, 1, 1, 'ink'), 30, 40, 90), 3, '')])
  const d = S.diffWorld(lying, asPlayer)
  assert.deepEqual(d.recreate.map(b => b.id), ['me'], 'becoming the player makes it again')
  sim.apply(d, asPlayer)
  const stood = sim.poseOf('me')
  near(Math.hypot(stood[0] - lay[0], stood[2] - lay[2]), 0, 1e-4, 'where it lay')
  near(Math.abs(stood[3]) + Math.abs(stood[5]), 0, 1e-6, 'but upright, turned only about y')
  const up = P.uprightPose([0, 0, 0, ...look.quatXYZ(0, 37, 0)])
  near(L.yawOf(up.slice(3)), 37, 1e-6, 'uprightPose keeps the heading')
  near(L.yawOf(P.uprightPose([0, 0, 0, ...look.quatXYZ(20, -120, 15)]).slice(3)), L.yawOf(look.quatXYZ(20, -120, 15)), 1e-6,
    'of a tipped body too')
}

// ---- the follow camera swings behind the player that walks, keeping its distance and height, and waits after a drag
{
  const spec = {target: 'me', distance: 4, height: 2}
  const f = new L.Follower()
  const pose = new look.CameraPose()
  f.snap(pose, [0, 0.5, 0], 0, spec)
  const flat0 = Math.hypot(f.offset[0], f.offset[2])
  const up0 = f.offset[1]
  // The body turns to face -z (heading 90): behind it is +z.
  assert.equal(f.turnBehind(pose, 90, 1 / 60, false), false, 'standing, it does not swing')
  near(Math.abs(f.yawGap(90)), 90, 1e-6, 'a quarter turn off behind')
  for (let k = 0; k < 60; k++) f.turnBehind(pose, 90, 1 / 60, true)
  const gap1 = Math.abs(f.yawGap(90))
  assert.ok(gap1 < 90 * Math.exp(-1 / L.FOLLOW_TURN_S) + 1 && gap1 > 5, 'in a second it closes most of the gap, eased: ' + gap1.toFixed(1))
  near(Math.hypot(f.offset[0], f.offset[2]), flat0, 1e-9, 'its distance along the ground is kept')
  near(f.offset[1], up0, 1e-12, 'and its height')
  for (let k = 0; k < 300; k++) f.turnBehind(pose, 90, 1 / 60, true)
  assert.ok(Math.abs(f.yawGap(90)) < L.FOLLOW_BEHIND_DEG, 'it comes to stand behind it: ' + f.yawGap(90).toFixed(3))
  near(pose.eye[2] - pose.look[2], flat0, 1e-3, 'behind a body facing -z is +z')
  // A drag turns it away: it is held there for FOLLOW_HOLD_MS, then swings back.
  f.turn(pose, Math.PI / 2, 0, 0.05)
  const dragged = f.yawGap(90)
  assert.ok(Math.abs(dragged) > 80, 'the drag turned it: ' + dragged.toFixed(1))
  const holdFrames = Math.floor(L.FOLLOW_HOLD_MS / 1000 * 60) - 2
  for (let k = 0; k < holdFrames; k++) assert.equal(f.turnBehind(pose, 90, 1 / 60, true), false, 'held after a drag (frame ' + k + ')')
  near(f.yawGap(90), dragged, 1e-9, 'where the person put it')
  for (let k = 0; k < 10; k++) f.turnBehind(pose, 90, 1 / 60, true)
  assert.ok(Math.abs(f.yawGap(90)) < Math.abs(dragged), 'and after the hold it swings back')
  // The hold counts down while the body stands, too.
  f.turn(pose, 0.5, 0, 0.05)
  for (let k = 0; k < 120; k++) f.turnBehind(pose, 90, 1 / 60, false)
  assert.equal(f.turning(true), true, 'a hold runs out while the body stands')
}

// ---- the stick steers by the frame it was pushed in: held sideways under a camera that swings behind, no circle
{
  const P = loadVera('VeraPhysics')
  const walk = (frozen) => {
    const spec = world([call('floor', 'surface'), call('player', box('me', 0, 0.5, 0), 3, '')])
    assert.ok(spec.follow !== null, 'the player is followed')
    const sim = new P.WorldSim(new P.FakePhys())
    sim.apply(S.diffWorld(null, spec), spec)
    const f = new L.Follower()
    const pose = look.followStart(look.followTarget(spec), spec.follow)
    f.snap(pose, [0, 0.5, 0], 0, spec.follow)
    const frame = new L.StickFrame()
    const headings = []
    for (let k = 0; k < 360; k++) {
      // The stick pushed right all the time.
      frame.push(pose, 1)
      const d = frozen ? frame.direction(pose, 1, 0) : look.floorDirection(pose, 1, 0)
      sim.setStick(d[0], d[2], 1)
      sim.step(1000 / 60, k / 60)
      const at = sim.poseOf('me')
      f.step(pose, at.slice(0, 3), spec.follow, 1 / 60)
      f.turnBehind(pose, L.yawOf(at.slice(3)), 1 / 60, sim.playerSpeedNow() > 0.3)
      headings.push(L.yawOf(at.slice(3)))
    }
    return {headings, at: sim.poseOf('me')}
  }
  const held = walk(true)
  const late = held.headings.slice(90)
  const spread = Math.max(...late.map(h => Math.abs(L.turnDeg(late[0], h))))
  assert.ok(spread < 3, 'pushed right, it walks one way while the camera swings behind it: heading varies ' + spread.toFixed(2) + ' deg')
  near(L.turnDeg(held.headings[359], -90), 0, 3, 'the way right was when the push began (+z, heading -90): ' + held.headings[359].toFixed(1))
  assert.ok(held.at[2] > 12, 'and it goes far along it: ' + held.at[2].toFixed(2))
  // Steered by the camera as it is now, the same push walks it round in a circle: what the frozen frame is for.
  const live = walk(false)
  let turned = 0
  for (let k = 1; k < live.headings.length; k++) turned += L.turnDeg(live.headings[k - 1], live.headings[k])
  assert.ok(Math.abs(turned) > 180, 'steered by the live camera it turns on and on: ' + turned.toFixed(0) + ' deg')
  // Let go, the frame goes; a drag while it is held takes the view as it is then.
  const frame = new L.StickFrame()
  const a = new look.CameraPose()
  frame.push(a, 1)
  const b = new look.CameraPose()
  b.eye = [6, 3, 0]
  assert.deepEqual(frame.direction(b, 1, 0).map(v => +v.toFixed(9)), look.floorDirection(a, 1, 0).map(v => +v.toFixed(9)), 'held: the first frame')
  frame.refresh(b)
  assert.deepEqual(frame.direction(b, 1, 0).map(v => +v.toFixed(9)), look.floorDirection(b, 1, 0).map(v => +v.toFixed(9)), 'a drag: the new view')
  frame.push(b, 0)
  assert.equal(frame.pose, null, 'let go, no frame')
  frame.refresh(a)
  assert.equal(frame.pose, null, 'and a drag with the stick let go keeps none')
}

// ---- a tap's ray: screenRay is the inverse of projectPoint
{
  const pose = new look.CameraPose()
  pose.eye = [3, 4, 7]
  pose.look = [-1, 0.5, 0]
  for (const [w, h] of [[360, 640], [800, 400]]) {
    for (const [x, y] of [[w / 2, h / 2], [10, 20], [w - 5, h - 7], [w * 0.3, h * 0.8]]) {
      const [eye, dir] = look.screenRay(pose, w, h, x, y)
      near(Math.hypot(...dir), 1, 1e-12, 'a unit direction')
      assert.deepEqual(eye, pose.eye, 'from the eye')
      for (const t of [0.5, 5, 40]) {
        const back = look.projectPoint(pose, w, h, [eye[0] + dir[0] * t, eye[1] + dir[1] * t, eye[2] + dir[2] * t])
        near(back[0], x, 1e-6, 'lands back on x at ' + t + ' m')
        near(back[1], y, 1e-6, 'lands back on y at ' + t + ' m')
      }
    }
  }
  const mid = look.screenRay(pose, 360, 640, 180, 320)[1]
  const f = look.cameraBasis(pose)[0]
  near(mid[0] * f[0] + mid[1] * f[1] + mid[2] * f[2], 1, 1e-12, 'the middle of the screen is straight ahead')
}

// ---- shots and pieces do not frame the world
{
  const base = [call('floor', 'surface'), box('crate', 0, 0.5, 0)]
  const plain = look.worldBounds(world(base))
  const shot = call('from', call('shoot', call('sphere', 'shot-1', 0.5, 0, 0, 0.1, 'ink'), 20, false), 'crate', 0)
  const far = call('shoot', call('sphere', 'shot-2', 50, 3, 50, 0.1, 'ink'), 20, false)
  const withShots = look.worldBounds(world([...base, shot, far]))
  assert.deepEqual(withShots, plain, 'shots leave the bounds as they were')
  assert.equal(look.worldFitPoints(world([...base, shot, far])).length, look.worldFitPoints(world(base)).length, 'and the fit points')
  assert.equal(look.floorSize(world([...base, far])), look.floorSize(world(base)), 'and the floor')
  assert.ok(look.framedOut(world([...base, far]).bodies.find(b => b.id === 'shot-2')), 'a shot is framed out')
}

console.log('locomotion-check ok')
