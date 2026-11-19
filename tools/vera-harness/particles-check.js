'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {loadVera, sourceRoot} = require('./source-loader')
const P = loadVera('VeraParticles')
const names = ['sparks', 'smoke', 'dust', 'debris', 'confetti']
const counts = [24, 18, 22, 28, 32]
const close = (a, b, eps = 1e-10) => assert.ok(Math.abs(a - b) < eps, a + ' vs ' + b)
const vectorClose = (a, b) => a.forEach((v, i) => close(v, b[i]))
const finiteVector = v => {
  assert.equal(v.length, 3)
  assert.ok(v.every(Number.isFinite))
}
const freezeSpec = p => {
  Object.freeze(p.origin)
  Object.freeze(p.velocity)
  Object.freeze(p.acceleration)
  return Object.freeze(p)
}
const request = (kind, seed, color = 'accent', origin = [0, 0, 0]) => {
  const burst = new P.ParticleBurst()
  burst.kind = kind
  burst.seed = seed
  burst.color = color
  burst.origin = origin
  return burst
}
const assertPool = pool => {
  const poses = pool.poses()
  assert.equal(pool.particleCount(), poses.length)
  assert.ok(poses.length <= P.MAX_PARTICLES)
  assert.ok(pool.burstCount() <= P.MAX_BURSTS)
  assert.equal(pool.needsFrames(), poses.length > 0)
  assert.ok(poses.every(p => p.alive && p.sizeM > 0 && p.alpha > 0))
  poses.forEach(p => finiteVector(p.position))
}

assert.deepEqual(P.PARTICLE_KINDS.map(p => p[0]), names)
assert.equal(P.MAX_PARTICLES, 256)
assert.equal(P.MAX_BURSTS, 16)
assert.equal(P.DUST_MIN_SPEED, 3)
for (const [name, description] of P.PARTICLE_KINDS) {
  assert.ok(description.length > 25)
  assert.equal(P.particleKind(name), true)
}
for (const kind of ['', 'SPARKS', 'unknown', '__proto__']) {
  assert.equal(P.particleKind(kind), false)
  assert.deepEqual(P.burstParticles(kind, 1, [0, 0, 0], 'red'), [])
}
for (const origin of [[], [1, 2], [NaN, 0, 0], [0, Infinity, 0], [0, 0, -Infinity]]) {
  assert.deepEqual(P.burstParticles('sparks', 1, origin, 'red'), [])
}
assert.deepEqual({...new P.ParticleBurst()}, {kind: '', seed: 0, origin: [0, 0, 0], color: ''})
const defaultSpec = new P.ParticleSpec()
assert.equal(P.particlePose(defaultSpec, 0).alive, true)
assert.equal(P.particlePose(defaultSpec, defaultSpec.lifeS).alive, false)
assert.equal(new P.ParticlePose().alive, false)

for (const [index, kind] of names.entries()) {
  for (const seed of [-2147483648, -1, 0, 1, 123, 0xffffffff, 0x100000001]) {
    const origin = Object.freeze([-3, -5, 7])
    const particles = P.burstParticles(kind, seed, origin, '#12abEF')
    assert.equal(particles.length, counts[index])
    assert.ok(particles.length <= P.MAX_PARTICLES)
    assert.deepEqual(particles, P.burstParticles(kind, seed, origin, '#12abEF'))
    assert.notDeepEqual(particles, P.burstParticles(kind, seed + 1, origin, '#12abEF'))
    assert.notEqual(particles[0].origin, origin)
    assert.notEqual(particles[0].origin, particles[1].origin)
    const before = JSON.stringify(particles)
    for (const p of particles) {
      freezeSpec(p)
      finiteVector(p.origin)
      finiteVector(p.velocity)
      finiteVector(p.acceleration)
      for (const field of ['drag', 'lifeS', 'sizeM', 'endSizeM', 'alpha']) assert.ok(Number.isFinite(p[field]))
      assert.ok(p.lifeS > 0 && p.lifeS <= 3)
      assert.ok(p.drag >= 0 && p.drag <= 3)
      assert.ok(p.sizeM > 0 && p.sizeM <= 0.2)
      assert.ok(p.endSizeM >= 0 && p.endSizeM <= 0.6)
      assert.ok(p.alpha > 0 && p.alpha <= 1)
      assert.equal(p.color, '#12abEF')
      assert.equal(p.kind, kind)
      const start = P.particlePose(p, 0)
      assert.deepEqual(start.position, origin)
      assert.equal(start.sizeM, p.sizeM)
      assert.equal(start.alpha, p.alpha)
      assert.notEqual(start.position, p.origin)
      assert.deepEqual(P.particlePose(p, -1), start)
      assert.deepEqual(P.particlePose(p, NaN), start)
      for (let step = 0; step <= 20; step++) {
        const age = p.lifeS * step / 20
        const pose = P.particlePose(p, age)
        finiteVector(pose.position)
        assert.ok(pose.sizeM >= 0 && pose.sizeM <= Math.max(p.sizeM, p.endSizeM))
        assert.ok(pose.alpha >= 0 && pose.alpha <= p.alpha)
        assert.equal(pose.color, p.color)
        assert.equal(pose.kind, kind)
        assert.ok(Math.hypot(...pose.position.map((v, i) => v - origin[i])) < 50)
        for (const floor of [-8, -2, 0, 4]) {
          const clamped = P.particlePose(p, age, floor)
          assert.ok(clamped.position[1] >= floor + clamped.sizeM / 2)
          close(clamped.position[0], pose.position[0])
          close(clamped.position[2], pose.position[2])
        }
      }
      for (const age of [p.lifeS, p.lifeS + 100, Infinity]) {
        const dead = P.particlePose(p, age)
        assert.equal(dead.alive, false)
        assert.equal(dead.sizeM, 0)
        assert.equal(dead.alpha, 0)
        finiteVector(dead.position)
      }
      if (kind === 'smoke') {
        const middle = P.particlePose(p, p.lifeS / 2)
        assert.ok(middle.position[1] > origin[1])
        assert.ok(middle.sizeM > start.sizeM)
        assert.ok(middle.alpha < start.alpha)
      }
    }
    assert.equal(JSON.stringify(particles), before)
    assert.deepEqual(origin, [-3, -5, 7])
  }
}

const ballistic = new P.ParticleSpec()
ballistic.origin = [-1, -10, -3]
ballistic.velocity = [2, 3, -4]
ballistic.acceleration = [1, -9.81, 2]
ballistic.lifeS = 4
ballistic.sizeM = 0.2
ballistic.endSizeM = 0.1
vectorClose(P.particlePose(ballistic, 1).position, [1.5, -11.905, -6])
assert.ok(P.particlePose(ballistic, 1).position[1] < 0)
assert.deepEqual(P.particlePose(ballistic, 1, null), P.particlePose(ballistic, 1))
close(P.particlePose(ballistic, 1, -7).position[1], -7 + 0.175 / 2)
ballistic.drag = 2
const travel = (1 - Math.exp(-2)) / 2
const fall = (1 - travel) / 2
vectorClose(P.particlePose(ballistic, 1).position,
  ballistic.origin.map((v, i) => v + ballistic.velocity[i] * travel + ballistic.acceleration[i] * fall))
ballistic.drag = 1e-12
vectorClose(P.particlePose(ballistic, 1).position, [1.5, -11.905, -6])
const terminal = P.burstParticles('confetti', 1, [0, 0, 0], 'gold')[0]
const plain = Object.assign(new P.ParticleSpec(), terminal, {drag: 0})
assert.ok(Math.abs(P.particlePose(terminal, 1).position[0]) < Math.abs(P.particlePose(plain, 1).position[0]))
assert.ok(P.particlePose(terminal, terminal.lifeS * 0.95).position[1] < P.particlePose(terminal, terminal.lifeS * 0.5).position[1])
for (const color of ['', 'primary', '#ff8800', 'rgba(1,2,3,0.4)']) {
  assert.ok(P.burstParticles('confetti', 1, [0, 0, 0], color).every(p => p.color === color))
}

const pool = new P.ParticlePool()
assertPool(pool)
const admitted = request('sparks', 7, 'primary', Object.freeze([-1, -5, 3]))
Object.freeze(admitted)
pool.emit(admitted)
const first = pool.poses()
assert.equal(pool.particleCount(), 24)
assert.equal(pool.burstCount(), 1)
assert.ok(first.every(p => p.position[1] === -5))
pool.advance(10)
assert.deepEqual(pool.poses(), first)
assertPool(pool)
pool.advance(0.1, -4)
assert.ok(pool.poses().every(p => p.position[1] >= -4 + p.sizeM / 2))
const snapshot = pool.poses()
assert.deepEqual(pool.poses(), snapshot)
const damaged = pool.poses()
damaged[0].position[0] = 999
damaged[0].sizeM = 999
damaged.pop()
assert.deepEqual(pool.poses(), snapshot)
for (const dt of [-1, NaN, Infinity, -Infinity]) {
  pool.advance(dt, -4)
  assert.deepEqual(pool.poses(), snapshot)
}
pool.emit(request('unknown', 0))
assert.deepEqual(pool.poses(), snapshot)
pool.advance(10)
assertPool(pool)
assert.equal(pool.burstCount(), 0)
pool.emit(request('smoke', 1))
pool.clear()
assertPool(pool)
assert.deepEqual(pool.poses(), [])
pool.emit(request('dust', 1, 'brown', [0, -5, 0]))
assert.ok(pool.poses().every(p => p.position[1] === -5))
pool.clear()

const mutable = request('debris', 5, 'original', [1, 2, 3])
pool.emit(mutable)
const copied = pool.poses()
mutable.origin[1] = 100
mutable.kind = 'smoke'
mutable.color = 'changed'
mutable.seed = 100
assert.deepEqual(pool.poses(), copied)
pool.clear()
for (let i = 0; i < 9; i++) {
  pool.emit(request('confetti', i, 'burst-' + i))
  assertPool(pool)
}
assert.equal(pool.particleCount(), 256)
assert.equal(pool.burstCount(), 8)
for (let i = 0; i < 8; i++) {
  assert.ok(pool.poses().slice(i * 32, (i + 1) * 32).every(p => p.color === 'burst-' + (i + 1)))
}
pool.advance(0)
pool.advance(10)
assertPool(pool)
assert.equal(pool.particleCount(), 0)

let reachedBurstLimit = false
for (let seed = 0; seed < 20 && !reachedBurstLimit; seed++) {
  pool.clear()
  for (let i = 0; i < 16; i++) {
    pool.emit(request('smoke', seed, 'smoke-' + i))
    pool.advance(0)
    pool.advance(0.16)
    assertPool(pool)
  }
  if (pool.burstCount() === 16) {
    reachedBurstLimit = true
    assert.ok(pool.poses().some(p => p.color === 'smoke-0'))
    const expected = pool.poses().filter(p => p.color !== 'smoke-0')
    assert.ok(expected.length + 18 <= P.MAX_PARTICLES)
    pool.emit(request('smoke', seed, 'smoke-16'))
    assert.equal(pool.burstCount(), 16)
    assert.equal(pool.particleCount(), expected.length + 18)
    assert.deepEqual(pool.poses().slice(0, expected.length), expected)
    assert.ok(!pool.poses().some(p => p.color === 'smoke-0'))
  }
}
assert.equal(reachedBurstLimit, true)
pool.clear()

const partial = P.burstParticles('sparks', 1, [0, 0, 0], 'orange')
pool.emit(request('sparks', 1, 'orange'))
pool.advance(0)
const halfLife = (Math.min(...partial.map(p => p.lifeS)) + Math.max(...partial.map(p => p.lifeS))) / 2
pool.advance(halfLife)
assertPool(pool)
const survivors = partial.filter(p => p.lifeS > halfLife)
assert.ok(survivors.length > 0 && survivors.length < partial.length)
assert.deepEqual(pool.poses(), survivors.map(p => P.particlePose(p, halfLife)))
assert.equal(pool.burstCount(), 1)
pool.emit(request('dust', 1, 'new'))
const old = pool.poses().filter(p => p.color === 'orange')
pool.advance(0.01)
assert.deepEqual(pool.poses().filter(p => p.color === 'orange'),
  survivors.filter(p => p.lifeS > halfLife + 0.01).map(p => P.particlePose(p, halfLife + 0.01)))
assert.ok(old.length > 0)
assert.ok(pool.poses().filter(p => p.color === 'new').every(p => p.position[1] === 0))
for (let i = 0; i < 200; i++) {
  if (i < 100) pool.emit(request(names[i % names.length], i, 'stress-' + i))
  pool.advance(0.05, -1)
  assertPool(pool)
}
assert.equal(pool.needsFrames(), false)
assert.equal(pool.particleCount(), 0)
assert.equal(pool.burstCount(), 0)

const source = fs.readFileSync(path.join(sourceRoot, 'vera/VeraParticles.ets'), 'utf8')
const imports = [...source.matchAll(/from\s+['"]([^'"]+)['"]/g)].map(m => m[1])
assert.deepEqual(imports, ['./VeraNoise'])
assert.doesNotMatch(source, /Math\.random|Date\.|setTimeout|setInterval|@kit\.|libphys|VeraScene|VeraPhysics/)
console.log('particles-check ok: 5 deterministic kinds, finite lifetimes, exact drag, smoke rise, colour passthrough, nullable floor, age-zero admission, dense poses, both limits, whole-burst eviction, expiry, immutable inputs, no platform')
