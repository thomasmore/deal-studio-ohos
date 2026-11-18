// Shooting, breaking and blasts in the physics, on the host (WorldSim over FakePhys): where a body made from another
// starts (resolveFrom, with w x r and an aim), pieces made from a body removed in the same apply, a shot that flies along
// its +x, holds up nothing and stops where it leaves the world, struck told at most once a step and ten times a second,
// for watched pairs only and once per pair in its cooldown, a body made again kept where the physics had it, settled
// without shots and with pieces as 1, pieces awake from the start, a blast once per trigger, and FakePhys's own side of
// the native contract (contact records of 6 with their point, the watched reserve, spin read back, kinds 4 and 5).
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const {VeraNumberValue, VeraStringValue, VeraBooleanValue, VeraArrayValue} = loadVera('VeraInterpreter')
const {UiHostEnvironment} = loadVera('VeraUi')
const S = loadVera('VeraScene')
const P = loadVera('VeraPhysics')
const Sh = loadVera('VeraShapes')

const FRAME_MS = 1000 / 60
const host = new UiHostEnvironment()
const call = (name, ...args) => host.invoke('std/scene', name, args.map(a => typeof a === 'number' ? new VeraNumberValue(a)
  : typeof a === 'string' ? new VeraStringValue(a) : typeof a === 'boolean' ? new VeraBooleanValue(a) : a), false)
const world = items => S.decodeScene(new VeraArrayValue(items))
const near = (a, b, eps, msg) => assert.ok(Math.abs(a - b) <= eps, msg + ': ' + a + ' vs ' + b)
const nearAll = (a, b, eps, msg) => { assert.equal(a.length, b.length, msg); a.forEach((v, i) => near(v, b[i], eps, msg + ' [' + i + ']')) }
const yawQ = deg => [0, Math.sin(deg * Math.PI / 360), 0, Math.cos(deg * Math.PI / 360)]
const run = (sim, n, t0 = 0) => { const told = []; for (let f = 0; f < n; f++) { sim.step(FRAME_MS, t0 + f / 60); told.push(...sim.takeEvents()) } return told }
const velocity = (engine, sim, id) => { const out = new Float32Array(6); engine.readVelocity(sim.index.get(id), out); return Array.from(out) }
const fakeBody = (engine, sim, id) => engine.bodies[sim.index.get(id)]

// ---- resolveFrom: the parent's frame, its velocity and spin, the burst, the shot, the aim
{
  // A parent at (1, 2, 3) turned 90 degrees about y (its +x is the world's -z), going (1, 0, 0), turning 2 rad/s about y.
  const parent = [1, 2, 3, ...yawQ(90), 1, 0, 0, 0, 2, 0]
  let [pose, v, w] = P.resolveFrom(parent, [1, 0, 0], [0, 0, 0], [], 0, 0)
  nearAll(pose.slice(0, 3), [1, 2, 2], 1e-9, 'one metre ahead of the parent, in its frame')
  nearAll(pose.slice(3), yawQ(90), 1e-9, 'turned as the parent is')
  // v + w x r: r = (0, 0, -1), w x r = (2 * -1 - 0, 0, 0).
  nearAll(v, [-1, 0, 0], 1e-9, 'the parent\'s velocity and its turn at that point')
  nearAll(w, [0, 2, 0], 1e-9, 'and its spin')
  ;[pose, v] = P.resolveFrom(parent, [1, 0, 0], [0, 0, 0], [], 3, 0)
  nearAll(v, [-1, 0, -3], 1e-9, 'burst pushes it straight out of the parent\'s centre')
  ;[pose, v] = P.resolveFrom(parent, [0, 0, 0], [0, 0, 0], [], 3, 0)
  nearAll(v, [1, 3, 0], 1e-9, 'a piece at the centre is burst upward')
  ;[pose, v] = P.resolveFrom(parent, [0.5, 0, 0], [0, 0, 0], [], 0, 10)
  // r = (0, 0, -0.5): v + w x r = (1 - 1, 0, 0), and 10 along the parent's +x, the world's -z.
  nearAll(v, [0, 0, -10], 1e-9, 'a shot goes at its speed along its own +x, carried by the parent')
  // A rod laid along the way it flies (turned 90 about z, so its own +x is up) still goes the way the shooter faces: the
  // shot's own turn is only how it looks. Found on the phone: a generated robot fired its bolts straight up.
  ;[pose, v] = P.resolveFrom([0, 0.5, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0], [0.3, 0, 0], [0, 0, 90], [], 0, 14)
  nearAll(v, [14, 0, 0], 1e-9, 'a turned shot from a body goes the way the body faces')
  nearAll(Sh.turnPoint(pose.slice(3), 1, 0, 0), [0, 1, 0], 1e-9, 'and keeps its own turn for how it looks')
  ;[pose, v] = P.resolveFrom(null, [0, 0, 0], [0, 90, 0], [], 0, 5)
  nearAll(v, [0, 0, -5], 1e-9, 'alone and unaimed, a shot goes along its own +x')
  // A shot built inside its shooter is moved ahead along +x, clear of it; one already clear is left where it is.
  nearAll(P.clearOfShooter([0.2, -0.3, 0], [0.1, 0.1, 0.1], [1.2, 1, 0.4], false), [0.6 + 0.05 + P.SHOT_CLEARANCE_M, -0.3, 0], 1e-9, 'moved ahead of the shooter')
  nearAll(P.clearOfShooter([0.9, -0.3, 0], [0.1, 0.1, 0.1], [1.2, 1, 0.4], false), [0.9, -0.3, 0], 0, 'already clear')
  nearAll(P.clearOfShooter([0.2, 0.8, 0], [0.1, 0.1, 0.1], [1.2, 1, 0.4], false), [0.2, 0.8, 0], 0, 'above the shooter is clear')
  near(P.clearOfShooter([0.2, 0, 0.1], [0.1, 0.1, 0.1], [1.2, 1, 0.4], true)[0], Math.hypot(0.6, 0.2) + 0.05 + P.SHOT_CLEARANCE_M, 1e-9, 'aimed: past its widest reach')
  ;[pose] = P.resolveFrom(parent, [0, 0, 0], [0, 0, 90], [], 0, 0)
  // The parent's turn, then its own: its +x (turned 90 about z, so up) stays up; its +y (turned to -x) is the parent's -x, +z.
  nearAll(Sh.turnPoint(pose.slice(3), 1, 0, 0), [0, 1, 0], 1e-9, 'its own turn is taken in the parent\'s frame (q . localRot)')
  nearAll(Sh.turnPoint(pose.slice(3), 0, 1, 0), [0, 0, 1], 1e-9, 'its own turn is taken in the parent\'s frame (q . localRot)')
  // No parent: the numbers are where it is, nothing inherited, no burst.
  ;[pose, v, w] = P.resolveFrom(null, [4, 5, 6], [0, 0, 0], [], 7, 0)
  nearAll(pose, [4, 5, 6, 0, 0, 0, 1], 1e-9, 'with no parent it stands where its numbers say'); nearAll(v, [0, 0, 0], 0, 'still'); nearAll(w, [0, 0, 0], 0, 'unturned')
  // Aim without a parent: +x turned to the point.
  ;[pose, v] = P.resolveFrom(null, [0, 1, 0], [0, 0, 0], [3, 1, -3], 0, 5)
  const ahead = Sh.turnPoint(pose.slice(3), 1, 0, 0)
  nearAll(ahead, [Math.SQRT1_2, 0, -Math.SQRT1_2], 1e-9, '+x points at the aim')
  nearAll(v, [5 * Math.SQRT1_2, 0, -5 * Math.SQRT1_2], 1e-9, 'and a shot goes there')
  // Aim with a parent: the offset is taken in the parent's place turned to the point, and the body points from where it is.
  const still = [0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
  ;[pose, v] = P.resolveFrom(still, [1, 0, 0], [0, 0, 0], [0, 1, -5], 0, 10)
  nearAll(pose.slice(0, 3), [0, 1, -1], 1e-9, 'one metre towards the aim from the parent')
  nearAll(v, [0, 0, -10], 1e-9, 'flying at the aim')
  ;[pose, v] = P.resolveFrom(still, [1, 0.5, 0], [0, 0, 0], [0, 1, -5], 0, 10)
  nearAll(pose.slice(0, 3), [0, 1.5, -1], 1e-9, 'an offset up stays up in the turned frame')
  const dir = [0 - 0, 1 - 1.5, -5 + 1], len = Math.hypot(...dir)
  nearAll(v, dir.map(x => 10 * x / len), 1e-9, 'and the shot still goes at the aim point')
  // The aimed pitch: up and down too.
  const qa = P.lookQuat(1, 1, 0)
  nearAll(Sh.turnPoint(qa, 1, 0, 0), [Math.SQRT1_2, Math.SQRT1_2, 0], 1e-9, 'lookQuat pitches up'); nearAll(Sh.turnPoint(qa, 0, 0, 1), [0, 0, 1], 1e-9, 'without a roll')
}

// ---- a body broken in an apply: its pieces come from where it is, going as it goes; awake; none missing
{
  const fake = new P.FakePhys()
  const sim = new P.WorldSim(fake)
  const vase = () => call('target', call('loose', call('box', 'v', 0, 0.5, 0, 0.6, 1, 0.6, 'accent'), 2))
  const w1 = world([call('floor', 'surface'), vase()])
  sim.apply(S.diffWorld(null, w1), w1)
  assert.equal(fakeBody(fake, sim, 'v').awake, false, 'the vase starts asleep on the floor')
  // Moved and turned by the physics, then going and spinning when it breaks.
  const i = sim.index.get('v')
  fake.setPose(i, 2, 0.5, 1, ...yawQ(30))
  fake.setVelocity(i, 0.5, 0, 0, 0, 1.5, 0)
  const live = sim.poseOf('v')
  const broken = [call('floor', 'surface'), ...call('split', vase(), 4, 2).elements]
  const w2 = world(broken)
  const d = S.diffWorld(w1, w2)
  assert.deepEqual(d.remove, ['v']); assert.deepEqual(d.create.map(b => b.id), ['v-1', 'v-2', 'v-3', 'v-4'])
  sim.apply(d, w2)
  assert.deepEqual(sim.fromMissing, [], 'the parent removed in the same apply is found')
  for (const b of w2.bodies) {
    const [pose, v] = P.resolveFrom([...live, 0.5, 0, 0, 0, 1.5, 0], b.position, b.rotation, [], 2, 0)
    nearAll(sim.poseOf(b.id), pose, 1e-5, b.id + ' is where the vase was, in its frame')
    nearAll(velocity(fake, sim, b.id), [...v, 0, 1.5, 0], 1e-5, b.id + ' goes as the vase went, plus its burst')
    const r = [pose[0] - live[0], pose[1] - live[1], pose[2] - live[2]]
    const out = r.map(x => x / Math.hypot(...r))
    // w x r for w = (0, 1.5, 0): (1.5 * rz, 0, -1.5 * rx).
    nearAll(v, [0.5 + 1.5 * r[2] + 2 * out[0], 2 * out[1], -1.5 * r[0] + 2 * out[2]], 1e-9, b.id + ': v + w x r + burst')
    assert.equal(fakeBody(fake, sim, b.id).awake, true, b.id + ' is not put to sleep where it starts')
  }
  assert.equal(sim.restingCount, 0, 'no piece rests at the start')
  // They fly apart and come to rest; the settle that follows a throw counts every piece as knocked.
  const kicked = world([...broken, call('kick', call('die', 'd', 3, 0.15, 3, 0.3, 'white'), 1, 0, 2, 0, 1)])
  sim.apply(S.diffWorld(w2, kicked), kicked)
  const told = run(sim, 600)
  const settled = told.filter(e => e.kind === 'settled')
  assert.equal(settled.length, 1, 'one settle')
  const at = id => settled[0].values[settled[0].bodies.indexOf(id)]
  for (const id of ['v-1', 'v-2', 'v-3', 'v-4']) assert.equal(at(id), 1, id + ' counts as knocked')
  assert.ok(at('d') >= 1 && at('d') <= 6, 'the die still tells its face')
}

// ---- a parent that is nowhere: placed by its own numbers (a piece where its parent was built), and said so
{
  const fake = new P.FakePhys()
  const sim = new P.WorldSim(fake)
  const w = world([call('floor', 'surface'), call('from', call('box', 'x', 1, 2, 3, 0.2, 0.2, 0.2, 'ink'), 'nobody', 5),
    ...call('split', call('box', 'gone', 5, 0.5, 0, 1, 1, 1, 'ink'), 2, 0).elements])
  const logged = []
  const info = console.info
  console.info = m => logged.push(m)
  sim.apply(S.diffWorld(null, w), w)
  console.info = info
  assert.deepEqual(sim.fromMissing, ['x', 'gone-1', 'gone-2'])
  assert.ok(logged.some(m => m === 'VERA-WORLD from missing parent=nobody id=x'), 'logged: ' + logged)
  nearAll(sim.poseOf('x').slice(0, 3), [1, 2, 3], 1e-6, 'a plain from with no parent stands where its numbers say')
  nearAll(velocity(fake, sim, 'x').slice(0, 3), [0, 0, 0], 1e-9, 'and has no burst: there is no centre to burst from')
  near(sim.poseOf('gone-1')[0] + sim.poseOf('gone-2')[0], 10, 1e-6, 'the pieces where their parent was built')
  // A new parent or burst later moves nothing.
  const w2 = world([call('floor', 'surface'), call('from', call('box', 'x', 1, 2, 3, 0.2, 0.2, 0.2, 'ink'), 'other', 9),
    ...call('split', call('box', 'gone', 5, 0.5, 0, 1, 1, 1, 'ink'), 2, 0).elements])
  assert.ok(S.diffWorld(w, w2).empty())
}

// ---- a shot: along its +x, without gravity until it touches, not waited on, through no thin wall, stopped at the bound
{
  const fake = new P.FakePhys()
  const sim = new P.WorldSim(fake)
  const shot = (id, x, y, speed, arc = false) => call('shoot', call('sphere', id, x, y, 0, 0.05, 'accent'), speed, arc)
  const w1 = world([call('floor', 'surface'), call('kick', call('die', 'd', 0, 0.15, 3, 0.3, 'white'), 1, 0, 3, 0, 2), shot('s1', 0, 1, 20)])
  sim.apply(S.diffWorld(null, w1), w1)
  assert.equal(fakeBody(fake, sim, 's1').projectile, true, 'a shot is a projectile in the engine')
  assert.ok(sim.needsFrames() && sim.shotsFlying === 1, 'a shot flying needs frames')
  run(sim, 15)
  const p = sim.poseOf('s1')
  near(p[0], 5, 0.2, 'it went 5 m along +x in a quarter second'); near(p[1], 1, 1e-6, 'and did not fall: no gravity until it touches')
  // The die settles while the shot is still flying: a shot holds up nothing, and is not among what settled.
  let settled = null
  for (let f = 0; f < 400 && !settled; f++) { sim.step(FRAME_MS, f / 60); settled = sim.takeEvents().find(e => e.kind === 'settled') || null }
  assert.ok(settled, 'the throw settles')
  assert.deepEqual(settled.bodies, ['d'], 'without the shot')
  // A shot that leaves the world stops where it is, told once, and is never sent back.
  for (let f = 0; f < 600; f++) sim.step(FRAME_MS, f / 60)
  const out = sim.poseOf('s1')
  assert.ok(out[0] > 99, 'it went past the bound: ' + out[0])
  run(sim, 60)
  nearAll(sim.poseOf('s1'), out, 1e-9, 'and stays where it stopped, not where it was made')
  assert.equal(sim.shotsFlying, 0); assert.equal(fake.awakeDynamic(), 0)
  assert.ok(!sim.needsFrames(), 'nothing flying, nothing awake: no frames')

  // A shot at 30 m/s does not pass through a wall 2 cm thick; once it has touched it falls.
  const fake2 = new P.FakePhys()
  const sim2 = new P.WorldSim(fake2)
  const w2 = world([call('floor', 'surface'), call('box', 'wall', 3, 1, 0, 0.02, 2, 2, 'ink'), call('target', call('box', 'behind', 4, 0.25, 0, 0.5, 0.5, 0.5, 'ink')),
    shot('s2', 0, 1, 30)])
  sim2.apply(S.diffWorld(null, w2), w2)
  const told = run(sim2, 120)
  let most = -Infinity
  const pose = sim2.poseOf('s2')
  most = Math.max(most, pose[0])
  assert.ok(pose[0] < 3, 'the shot stayed this side of the wall: ' + pose[0])
  assert.ok(pose[1] < 0.2, 'and fell after it touched it: y ' + pose[1])
  assert.ok(!told.some(e => e.kind === 'struck' && e.body === 'behind'), 'what is behind the wall was not struck')
  const hitWall = told.filter(e => e.kind === 'struck' && e.body === 's2')
  assert.equal(hitWall.length, 1, 'a shot hitting a body is told once, with the shot as body: ' + JSON.stringify(told.filter(e => e.kind === 'struck')))
  assert.equal(hitWall[0].other, 'wall'); near(hitWall[0].x, 2.99 - 0.02, 0.06, 'where it touched the wall')
  assert.ok(!told.some(e => e.kind === 'struck' && e.other === '' && e.body === 's2'), 'a shot on the ground is not told')

  // An arc shot falls from the start.
  const fake3 = new P.FakePhys()
  const sim3 = new P.WorldSim(fake3)
  const w3 = world([call('floor', 'surface'), shot('s3', 0, 5, 10, true)])
  sim3.apply(S.diffWorld(null, w3), w3)
  run(sim3, 30)
  assert.ok(sim3.poseOf('s3')[1] < 4, 'an arc shot falls: ' + sim3.poseOf('s3')[1])
}

// ---- struck: watched pairs only, harder than 1.5 m/s, once a step, ten a second, a pair once in 0.3 s
{
  const fake = new P.FakePhys()
  let records = []
  fake.drainContacts = out => { records.forEach((v, k) => { out[k] = v }); const n = records.length / 6; return n }
  const sim = new P.WorldSim(fake)
  const items = [call('floor', 'surface')]
  for (let k = 0; k < 40; k++) items.push(call('target', call('box', 't' + k, k * 2, 0.5, 0, 1, 1, 1, 'ink')))
  items.push(call('box', 'plain', 0, 0.5, 9, 1, 1, 1, 'ink'), call('box', 'plain2', 3, 0.5, 9, 1, 1, 1, 'ink'))
  items.push(call('loose', call('box', 'ball', 0, 0.5, -9, 1, 1, 1, 'ink'), 1))
  items.push(call('shoot', call('sphere', 'shot', 0, 3, -20, 0.05, 'ink'), 1, true))
  const w = world(items)
  sim.apply(S.diffWorld(null, w), w)
  const ix = id => sim.index.get(id)
  const ground = Array.from({length: 64}, (_, i) => i).find(i => sim.idAt(i) === '' && fake.bodies[i] && fake.bodies[i].alive)
  const rec = (a, b, speed, x = 0, y = 0, z = 0) => [a === '' ? ground : ix(a), b === '' ? ground : ix(b), speed, x, y, z]
  const struck = (frames, make) => {
    const told = []
    for (let f = 0; f < frames; f++) {
      records = make(f).flat()
      sim.step(FRAME_MS, f / 60)
      for (const e of sim.takeEvents()) if (e.kind === 'struck') told.push([f, e])
    }
    records = []
    return told
  }
  // Not watched, or too soft: nothing.
  assert.deepEqual(struck(10, () => [rec('plain', 'plain2', 9), rec('t0', 'ball', 1.4), rec('shot', '', 9)]), [], 'unwatched pairs, a soft knock and a shot on the ground')
  run(sim, 30)
  // A target knocked by a body: body the target, other the body, the contact point.
  let told = struck(1, () => [rec('ball', 't1', 4, 1.5, 0.7, -0.2)])
  assert.equal(told.length, 1)
  assert.deepEqual([told[0][1].body, told[0][1].other, told[0][1].speed, told[0][1].x, told[0][1].y].map(v => typeof v === 'number' ? +v.toFixed(3) : v),
    ['t1', 'ball', 4, 1.5, 0.7], 'struck: the target, what hit it, how hard, where')
  run(sim, 30, 1)
  // Several at once: one struck, the hardest pair, every target in bodies hardest first.
  told = struck(1, () => [rec('t2', 'ball', 3), rec('ball', 't3', 6), rec('t4', '', 2), rec('t3', 'plain', 5)])
  assert.equal(told.length, 1, 'one struck a step')
  assert.deepEqual([told[0][1].body, told[0][1].other], ['t3', 'ball'])
  assert.deepEqual(told[0][1].bodies, ['t3', 't2', 't4']); assert.deepEqual(told[0][1].values.map(v => +v.toFixed(3)), [6, 3, 2])
  assert.equal(told[0][1].bodies.includes('ball'), false, 'only what was struck, not what struck it')
  run(sim, 30, 2)
  // A new target knocked every step: at most ten a second, the rest merged into the next.
  told = struck(120, f => [rec('t' + (5 + (f % 30)), 'ball', 2 + f % 3)])
  assert.ok(told.length >= 18 && told.length <= 21, 'ten a second over two seconds: ' + told.length)
  for (let k = 1; k < told.length; k++) assert.ok(told[k][0] - told[k - 1][0] >= 5, 'at least a tenth of a second apart: ' + told.map(t => t[0]))
  assert.ok(told.slice(1).every(t => t[1].bodies.length >= 5), 'what waited is told with the next: ' + told.map(t => t[1].bodies.length))
  run(sim, 30, 4)
  // One pair knocking every step: told once each 0.3 s.
  told = struck(60, () => [rec('t36', 'ball', 3)])
  assert.ok(told.length >= 3 && told.length <= 4, 'one pair, at most once each 0.3 s: ' + told.map(t => t[0]))
  for (let k = 1; k < told.length; k++) assert.ok(told[k][0] - told[k - 1][0] >= 17, 'the pair\'s cooldown: ' + told.map(t => t[0]))
  run(sim, 30, 6)
  // A target on the ground, and a shot on a body.
  told = struck(1, () => [rec('', 't37', 3)])
  assert.deepEqual([told[0][1].body, told[0][1].other], ['t37', ''], 'a target falling hard: other is the ground')
  run(sim, 30, 7)
  told = struck(1, () => [rec('plain', 'shot', 8)])
  assert.deepEqual([told[0][1].body, told[0][1].other], ['shot', 'plain'], 'a shot on a body that is no target: body the shot')
  // A target no longer: not told.
  run(sim, 30, 8)
  const w2 = world(items.map(t => t.thing.id === 't38' ? call('box', 't38', 76, 0.5, 0, 1, 1, 1, 'ink') : t))
  const d = S.diffWorld(w, w2)
  assert.deepEqual(d.material.map(b => b.id), ['t38'])
  sim.apply(d, w2)
  assert.equal(fakeBody(fake, sim, 't38').watched, false, 'unwatched in the engine')
  assert.deepEqual(struck(1, () => [rec('ball', 't38', 9)]), [], 'and its knocks are not told')
  // Frames go on while a struck waits.
  records = []
}

// ---- a loose body made again stays where the physics had it, going as it went; at rest it stays asleep
{
  const fake = new P.FakePhys()
  const sim = new P.WorldSim(fake)
  const scene = (mark, mass = 1) => {
    let a = call('loose', call('box', 'a', 0, 0.25, 0, 0.5, 0.5, 0.5, 'ink'), mass)
    let b = call('loose', call('box', 'b', 5, 0.25, 0, 0.5, 0.5, 0.5, 'ink'), 1)
    if (mark) { a = call('mark', a, 'accent'); b = call('mark', b, 'accent') }
    return world([call('floor', 'surface'), a, b])
  }
  let spec = scene(false)
  sim.apply(S.diffWorld(null, spec), spec)
  fake.setVelocity(sim.index.get('a'), 3, 0, 0, 0, 0, 0)
  run(sim, 10)
  const here = sim.poseOf('a')
  const going = velocity(fake, sim, 'a')
  assert.ok(here[0] > 0.3 && going[0] > 1, 'a slides along')
  const restB = sim.poseOf('b')
  const next = scene(true, 2)
  const d = S.diffWorld(spec, next)
  assert.deepEqual(d.recreate.map(b => b.id), ['a', 'b'], 'a mark and a mass make them again')
  sim.apply(d, next)
  nearAll(sim.poseOf('a'), here, 1e-6, 'made again, it is where it was, not where it was built')
  nearAll(velocity(fake, sim, 'a').slice(0, 3), going.slice(0, 3), 1e-6, 'and goes on as it went')
  nearAll(sim.poseOf('b'), restB, 1e-6, 'the one at rest stays put')
  assert.equal(fakeBody(fake, sim, 'b').awake, false, 'asleep')
}

// ---- a blast: once per change of trigger, every loose body within its radius pushed away; settled follows
{
  const fake = new P.FakePhys()
  let calls = 0
  const explode = fake.explode.bind(fake)
  fake.explode = (...a) => { calls++; return explode(...a) }
  const sim = new P.WorldSim(fake)
  const scene = trigger => world([call('floor', 'surface'), call('blast', 'bomb', trigger, 0, 0, 0, 3, 6),
    ...[[1, 0], [-1, 0], [0, 2], [5, 0]].map(([x, z], k) => call('loose', call('box', 'c' + k, x, 0.25, z, 0.5, 0.5, 0.5, 'ink'), 1)),
    call('box', 'fixed', 0, 0.25, -1, 0.5, 0.5, 0.5, 'ink')])
  let spec = scene(0)
  sim.apply(S.diffWorld(null, spec), spec)
  run(sim, 10)
  assert.equal(calls, 0, 'trigger 0: nothing')
  let next = scene(1)
  sim.apply(S.diffWorld(spec, next), next); spec = next
  assert.equal(calls, 1, 'a new trigger: one blast')
  const v = id => velocity(fake, sim, id)
  assert.ok(v('c0')[0] > 3 && v('c1')[0] < -3 && v('c2')[2] > 1, 'pushed away from it: ' + [v('c0'), v('c1'), v('c2')].map(a => a.slice(0, 3).map(x => x.toFixed(2))).join(' | '))
  near(Math.hypot(...v('c0').slice(0, 3)), 6 * (1 - Math.hypot(1, 0.25) / 3), 1e-4, 'by strength * (1 - d / r)')
  assert.ok(Math.hypot(...v('c2').slice(0, 3)) < Math.hypot(...v('c0').slice(0, 3)), 'less further out')
  nearAll(v('c3').slice(0, 3), [0, 0, 0], 1e-9, 'beyond the radius: untouched')
  assert.deepEqual(sim.poseOf('fixed').slice(0, 3), [0, 0.25, -1], 'a fixed body is not moved')
  sim.apply(S.diffWorld(spec, scene(1)), scene(1))
  assert.equal(calls, 1, 'the same trigger: no second blast')
  const told = run(sim, 600)
  assert.equal(told.filter(e => e.kind === 'settled').length, 1, 'what it threw settles once')
}

// ---- FakePhys's side of the native contract
{
  // Contact records of six, with the point where they touch, and spin read back when there is room for it.
  const fp = new P.FakePhys()
  fp.setGravity(-9.81)
  fp.setBound(-5, 99, 99)
  const floor = fp.addBox(50, 0.5, 50, P.PHYS_STATIC)
  fp.setPose(floor, 0, -0.5, 0, 0, 0, 0, 1)
  const a = fp.addBox(0.1, 0.1, 0.1, P.PHYS_DYNAMIC)
  fp.setPose(a, 2, 0.3, 1, 0, 0, 0, 1)
  fp.setVelocity(a, 0, -3, 0, 0, 4, 0)
  for (let k = 0; k < 10; k++) fp.step(1 / 60, 1)
  const out = new Float32Array(6 * 16)
  const n = fp.drainContacts(out)
  assert.equal(n, 1, 'one contact begun')
  assert.deepEqual([out[0], out[1]].sort(), [floor, a].sort())
  near(out[3], 2, 0.11, 'the point is under the box'); near(out[4], 0, 0.02, 'on the floor'); near(out[5], 1, 0.11, 'z')
  const vel = new Float32Array(6)
  fp.setVelocity(a, 1, 2, 3, 4, 5, 6)
  assert.equal(fp.readVelocity(a, vel), 1); assert.deepEqual(Array.from(vel), [1, 2, 3, 4, 5, 6], 'v and then w')
  const three = new Float32Array(3).fill(9)
  assert.equal(fp.readVelocity(a, three), 1); assert.deepEqual(Array.from(three), [1, 2, 3], 'no room, no spin')
  assert.equal(fp.readVelocity(a, new Float32Array(2)), 0, 'fewer than 3: nothing')
  // Kinds 4 and 5: dynamic, watched, not counted awake.
  const s4 = fp.addSphere(0.05, P.PHYS_PROJECTILE)
  const s5 = fp.addSphere(0.05, P.PHYS_PROJECTILE_ARC)
  fp.setPose(s4, 10, 5, 0, 0, 0, 0, 1); fp.setPose(s5, 12, 5, 0, 0, 0, 0, 1)
  fp.step(1 / 60, 1)
  assert.equal(fp.bodies[s4].watched && fp.bodies[s5].watched, true, 'projectiles are watched')
  assert.equal(fp.bodies[s4].awake && fp.bodies[s5].awake, true)
  const awake = fp.awakeDynamic()
  fp.remove(s4); fp.remove(s5)
  assert.equal(fp.awakeDynamic(), awake, 'and not among awakeDynamic')
  // The watched reserve: a thousand bodies landing at once fill the ordinary records; the watched one still gets in.
  const many = new P.FakePhys()
  many.setGravity(-9.81)
  many.setBound(-5, 200, 200)
  const g = many.addBox(150, 0.5, 150, P.PHYS_STATIC)
  many.setPose(g, 0, -0.5, 0, 0, 0, 0, 1)
  const ids = []
  for (let k = 0; k < 1000; k++) {
    const i = many.addBox(0.1, 0.1, 0.1, P.PHYS_DYNAMIC)
    many.setPose(i, (k % 40) * 0.5 - 10, 0.09, Math.floor(k / 40) * 0.5 - 6, 0, 0, 0, 1)
    ids.push(i)
  }
  // The last in the order the records are written (keys sort as strings: '0:999' last), so the reserve is what lets it in.
  const watched = ids[998]
  many.watch(watched, 1)
  many.step(1 / 60, 1)
  const buf = new Float32Array(6 * P.CONTACT_CAP)
  const got = many.drainContacts(buf)
  assert.equal(got, P.CONTACT_CAP - P.CONTACT_WATCH_RESERVE + 1, 'ordinary contacts stop at 960 records, the watched one is kept: ' + got)
  let found = false
  for (let k = 0; k < got; k++) if (buf[6 * k] === watched || buf[6 * k + 1] === watched) found = true
  assert.ok(found, 'the watched body\'s contact is among them')
  assert.equal(many.drainContacts(buf), 0, 'drained')
  // explode counts what it pushed: dynamic bodies, characters and projectiles; not fixed ones.
  const ex = new P.FakePhys()
  ex.setGravity(0)
  const d1 = ex.addBox(0.1, 0.1, 0.1, P.PHYS_DYNAMIC); ex.setPose(d1, 1, 0, 0, 0, 0, 0, 1)
  const c1 = ex.addBox(0.1, 0.1, 0.1, P.PHYS_CHARACTER); ex.setPose(c1, 0, 1, 0, 0, 0, 0, 1)
  const p1 = ex.addSphere(0.1, P.PHYS_PROJECTILE); ex.setPose(p1, 0, 0, 1, 0, 0, 0, 1)
  const f1 = ex.addBox(0.1, 0.1, 0.1, P.PHYS_STATIC); ex.setPose(f1, -1, 0, 0, 0, 0, 0, 1)
  const k1 = ex.addBox(0.1, 0.1, 0.1, P.PHYS_KINEMATIC); ex.setPose(k1, 0, -1, 0, 0, 0, 0, 1)
  assert.equal(ex.explode(0, 0, 0, 2, 4), 3)
  ex.readVelocity(d1, vel); nearAll(Array.from(vel).slice(0, 3), [2, 0, 0], 1e-6, 'dv = strength * (1 - d / r), outward')
}

console.log('interaction-check ok')
