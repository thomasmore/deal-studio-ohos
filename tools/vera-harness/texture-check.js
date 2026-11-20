'use strict'
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const {loadVera} = require('./source-loader')
const T = loadVera('VeraTextures')
const N = loadVera('VeraNoise')
const S = loadVera('VeraSurfaces')
const c1 = [0.12, 0.31, 0.72], c2 = [0.91, 0.64, 0.08]
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const close = (a, b, eps = 1e-10) => assert.ok(a.every((v, i) => Math.abs(v - b[i]) < eps), a + ' vs ' + b)
const names = ['wood', 'planks', 'brick', 'tiles', 'stone', 'grass', 'sand', 'metal', 'marble', 'checker', 'fabric']
assert.deepEqual(T.TEXTURE_PATTERNS.map(p => p[0]), names)
assert.equal(T.TEXTURE_TILE_M, 1)
assert.equal(T.texturePattern('patches'), false)
assert.equal(T.texturePattern('WOOD'), false)
assert.equal(T.texturePattern(''), false)
const keys = new Set()
const images = new Set()
for (const [pattern, description] of T.TEXTURE_PATTERNS) {
  assert.ok(description.length > 25)
  assert.equal(T.texturePattern(pattern), true)
  const pixels = T.texturePixels(pattern, c1, c2, 123, 256)
  assert.equal(pixels.length, 256 * 256 * 4)
  const hash = digest(pixels)
  assert.equal(hash, digest(T.texturePixels(pattern, c1, c2, 123, 256)), pattern + ' deterministic')
  images.add(hash)
  const varied = digest(T.texturePixels(pattern, c1, c2, 124, 256))
  if (pattern !== 'checker') assert.notEqual(hash, varied, pattern + ' varies by seed')
  else assert.equal(hash, varied)
  assert.notEqual(hash, digest(T.texturePixels(pattern, [0.8, 0.1, 0.1], c2, 123, 256)), pattern + ' uses first colour')
  assert.notEqual(hash, digest(T.texturePixels(pattern, c1, [0.1, 0.8, 0.1], 123, 256)), pattern + ' uses second colour')
  let low = 1, high = 0
  for (let i = 0; i < pixels.length; i += 4) {
    assert.equal(pixels[i + 3], 255)
    const t = (pixels[i] / 255 - c1[0]) / (c2[0] - c1[0])
    low = Math.min(low, t); high = Math.max(high, t)
    for (let k = 0; k < 3; k++) assert.ok(pixels[i + k] / 255 >= Math.min(c1[k], c2[k]) - 1 / 255 &&
      pixels[i + k] / 255 <= Math.max(c1[k], c2[k]) + 1 / 255, pattern + ' stays between supplied colours')
  }
  assert.ok(high - low > 0.2 && low < 0.6 && high > 0.4, pattern + ' visible contrast: ' + low + '..' + high)
  for (const seed of [0, 1, 123, 0xffffffff]) {
    for (let k = 0; k < 97; k++) {
      const u = (k + 0.231) / 97, v = (k * 37 % 97 + 0.417) / 97
      const sample = (x, y) => T.textureSample(pattern, c1, c2, seed, x, y)
      close(sample(u, v), sample(u + 3, v - 2))
      close(sample(0, v), sample(1, v))
      close(sample(u, 0), sample(u, 1))
      if (pattern !== 'checker') {
        close(sample(-1e-8, v), sample(1e-8, v), 1e-4)
        close(sample(u, -1e-8), sample(u, 1e-8), 1e-4)
      }
    }
  }
  const key = T.textureKey(pattern, c1, c2, 123)
  assert.match(key, /^tex_v2_256_[a-z0-9_]+$/)
  assert.ok(key.length < 240)
  assert.equal(key, T.textureKey(pattern, c1.slice(), c2.slice(), 123))
  for (const other of [T.textureKey(pattern, c2, c1, 123), T.textureKey(pattern, c1, c2, 124),
    T.textureKey(pattern, [c1[0] + 1e-10, c1[1], c1[2]], c2, 123),
    T.textureKey(pattern, c1, [c2[0], c2[1] + 1e-10, c2[2]], 123)]) assert.notEqual(key, other)
  keys.add(key)
  const rough = T.textureRoughness(pattern)
  assert.ok(rough >= 0 && rough <= 1)
  assert.equal(rough, T.textureRoughness(pattern))
  const small = T.texturePixels(pattern, c1, c2, 123, 13)
  for (const [x, y] of [[0, 0], [4, 7], [12, 12]]) {
    const expected = T.textureSample(pattern, c1, c2, 123, (x + 0.5) / 13, (y + 0.5) / 13).map(c => Math.round(c * 255))
    assert.deepEqual(Array.from(small.slice((y * 13 + x) * 4, (y * 13 + x) * 4 + 4)), [...expected, 255])
  }
}
assert.equal(keys.size, 11)
assert.equal(images.size, 11)
assert.ok(T.textureRoughness('metal') < T.textureRoughness('wood'))
assert.ok(T.textureRoughness('metal') < T.textureRoughness('stone'))
assert.ok(Number.isFinite(T.textureRoughness('unknown')))
assert.match(T.textureKey('../../bad', c1, c2, 3), /^tex_v\d+_256_plain_[a-z0-9_]+$/)
close(T.textureSample('unknown', c1, c2, 3, 0.2, 0.3), c1)
assert.deepEqual(Array.from(T.texturePixels('unknown', [1, 0, 0], c2, 0, 1)), [255, 0, 0, 255])
for (const size of [0, -1, 1.5, NaN, Infinity, 4097]) assert.throws(() => T.texturePixels('wood', c1, c2, 0, size), /size/)
assert.equal(N.surfaceSeed('hello'), 1335831723)
assert.equal(S.surfaceSeed, N.surfaceSeed)
const snapshots = {
  patches: 'a75c8d188be55e538e513dc2c37603d9c8c3ce53294e09022f58556b3c2654ad',
  bands: '251fb408fd6926844ad048411ba42a08687e7996a3b672ca82e43ba4c219c0e1',
  oval: '4df12774f59c6bfbd1d08fb6c806e5118004d805166d9094decde9dce28dd170',
  craters: 'cfa46fb153d139893751f5684361b3f73eca59590baf3a33aa9b5b5a08f25ca8',
  mottled: '23a0d35f68f0cdd13e411f10a6f3f601fae2d9a9e79c45103c68f3431ef33c5d',
  polar: '7bb272b149297c23d2c7e11e8d8b9167d0ef60a02176c85ddeba3d7b29c6ce30',
  swirls: '591d9052c43d5bcafb54e3e3ce7d2d536207e7d7802d6116c0cd097c28c8a0fe',
  stripes: '28f12e7e9bac3f5997d5e400e8b7bf00188ebe03fbaa12e62eae879dfa171451',
}
for (const [pattern, expected] of Object.entries(snapshots)) {
  const mesh = S.paintedSphere(0.7, pattern, [0.2, 0.4, 0.8], [0.8, 0.6, 0.1], 123)
  assert.deepEqual(mesh.uvs, [])
  delete mesh.uvs
  assert.equal(digest(JSON.stringify(mesh)), expected, pattern + ' legacy sphere unchanged')
}
assert.deepEqual(S.flatRing(0.1, 0.2, c1, 3, 123).uvs, [])
console.log('texture-check ok: 11 patterns, deterministic RGBA, periodic seams, colour contribution, keys, roughness, 8 legacy sphere snapshots')
