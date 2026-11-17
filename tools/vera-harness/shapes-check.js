// Bodies of any shape (VeraShapes.ets): outlines cut into convex pieces, the checks that refuse bad ones, and the
// meshes the renderer draws: closed, flat, facing out. Needs VERA_TYPESCRIPT_PATH (see source-loader.js).
'use strict'
const assert = require('node:assert/strict')
const {loadVera} = require('./source-loader')
const V = loadVera('VeraShapes')

const star = (outer, inner, n) => {
  const p = []
  for (let k = 0; k < 2 * n; k++) {
    const r = k % 2 === 0 ? outer : inner
    const a = Math.PI * k / n
    p.push(r * Math.cos(a), r * Math.sin(a))
  }
  return p
}
const triangle = [0, -0.1, 0.1, 0.07, -0.1, 0.07]
const square = [-0.1, -0.1, 0.1, -0.1, 0.1, 0.1, -0.1, 0.1]
const ell = [0, 0, 0.3, 0, 0.3, 0.1, 0.1, 0.1, 0.1, 0.3, 0, 0.3]
const fivePoint = star(0.1, 0.04, 5)

// Pieces: a convex outline is one piece; an L two; a five-pointed star at most six (a pentagon and five tips).
assert.equal(V.outlineParts(triangle).length, 1, 'a triangle is one piece')
assert.equal(V.outlineParts(square).length, 1, 'a square is one piece')
assert.equal(V.outlineParts(square.slice().reverse()).length, 1, 'clockwise is turned round, not refused')
assert.equal(V.outlineParts(ell).length, 2, 'an L is two pieces')
const starParts = V.outlineParts(fivePoint)
assert.ok(starParts.length >= 5 && starParts.length <= 6, 'a star is its tips and a middle: ' + starParts.length)
// The pieces cover the outline exactly: their areas add up to its own.
const area = p => { let s = 0; for (let i = 0; i < p.length; i += 2) { const j = (i + 2) % p.length; s += p[i] * p[j + 1] - p[j] * p[i + 1] } return s / 2 }
for (const [name, p] of [['L', ell], ['star', fivePoint], ['triangle', triangle]]) {
  const sum = V.outlineParts(p).reduce((s, q) => s + area(q), 0)
  assert.ok(Math.abs(sum - Math.abs(area(p))) < 1e-9, name + ': pieces cover the outline, ' + sum + ' vs ' + area(p))
  for (const q of V.outlineParts(p)) assert.ok(area(q) > 0, name + ': every piece counter-clockwise and not empty')
}

// Refused, each with a reason the model can act on.
assert.equal(V.outlineCheck(triangle), '')
assert.equal(V.outlineCheck(fivePoint), '')
assert.match(V.outlineCheck([0, 0, 1, 0]), /at least 3/)
assert.match(V.outlineCheck([0, 0, 1, 0, 2, 0]), /no area/)
assert.match(V.outlineCheck([0, 0, 1, 1, 1, 0, 0, 1]), /cross/, 'a bow tie')
assert.match(V.outlineCheck([0, 0, 1, 0, 1, 0, 0, 1]), /repeated/)
assert.match(V.outlineCheck([0, 0, 1, NaN, 0, 1]), /finite/)
assert.match(V.outlineCheck([0, 0, 1]), /pairs/)
assert.match(V.outlineCheck(star(0.1, 0.05, 40)), /at most 64 corners/)
// A comb of 20 teeth needs more than 16 pieces.
const comb = [0, 0]
for (let k = 0; k < 20; k++) comb.push(k * 0.1 + 0.05, 1, k * 0.1 + 0.1, 0.1)
comb.push(2, 0)
assert.match(V.outlineCheck(comb), /too intricate/)

// A mesh is closed (every edge in two triangles, once each way), and every face faces away from the inside.
const checkMesh = (name, m, inside) => {
  const key = i => [0, 1, 2].map(k => m.positions[3 * i + k].toFixed(6)).join(',')
  const edges = new Map()
  for (let t = 0; t < m.indices.length; t += 3) {
    const v = [m.indices[t], m.indices[t + 1], m.indices[t + 2]]
    for (let e = 0; e < 3; e++) {
      const k = key(v[e]) + '>' + key(v[(e + 1) % 3])
      edges.set(k, (edges.get(k) || 0) + 1)
    }
    const p = v.map(i => [0, 1, 2].map(k => m.positions[3 * i + k]))
    const u = [0, 1, 2].map(k => p[1][k] - p[0][k]), w = [0, 1, 2].map(k => p[2][k] - p[0][k])
    const c = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]]
    const n = [0, 1, 2].map(k => m.normals[3 * v[0] + k])
    assert.ok(c[0] * n[0] + c[1] * n[1] + c[2] * n[2] > 0, name + ': wound counter-clockwise seen along its normal')
    const centre = [0, 1, 2].map(k => (p[0][k] + p[1][k] + p[2][k]) / 3)
    const out = [0, 1, 2].map(k => centre[k] - inside[k])
    assert.ok(out[0] * n[0] + out[1] * n[1] + out[2] * n[2] > -1e-9, name + ': faces outward')
  }
  for (const [k, count] of edges) {
    const [a, b] = k.split('>')
    assert.equal(count, 1, name + ': edge once each way ' + k)
    assert.equal(edges.get(b + '>' + a), 1, name + ': edge has its twin ' + k)
  }
}
checkMesh('triangle prism', V.prismMesh(triangle, 0.05), [0, 0, 0.0133])
checkMesh('square prism', V.prismMesh(square.slice().reverse(), 0.02), [0, 0, 0])
// Outward for a non-convex prism is checked per side against the outline (the centre of an L lies outside some faces).
{
  const m = V.prismMesh(ell, 0.1)
  for (let i = 0; i < m.positions.length; i += 9) {
    const n = [m.normals[i], m.normals[i + 1], m.normals[i + 2]]
    if (n[1] !== 0) continue
    // A point a little way out along the normal from the middle of the side is outside the L.
    const cx = (m.positions[i] + m.positions[i + 3] + m.positions[i + 6]) / 3 + n[0] * 1e-3
    const cz = (m.positions[i + 2] + m.positions[i + 5] + m.positions[i + 8]) / 3 + n[2] * 1e-3
    const inL = (cx > 0 && cx < 0.3 && cz > 0 && cz < 0.1) || (cx > 0 && cx < 0.1 && cz > 0 && cz < 0.3)
    assert.ok(!inL, 'L prism: side faces outward at ' + cx.toFixed(3) + ',' + cz.toFixed(3))
  }
  const edges = new Map()
  const key = j => [0, 1, 2].map(k => m.positions[3 * j + k].toFixed(6)).join(',')
  for (let t = 0; t < m.indices.length; t += 3) for (let e = 0; e < 3; e++) {
    const k = key(m.indices[t + e]) + '>' + key(m.indices[t + (e + 1) % 3]); edges.set(k, (edges.get(k) || 0) + 1)
  }
  // The top and bottom of an L are cut on a diagonal the sides do not have: count matched edges, not every one.
  let open = 0
  for (const k of edges.keys()) { const [a, b] = k.split('>'); if (!edges.has(b + '>' + a)) open++ }
  assert.equal(open, 0, 'L prism is closed')
}

// Hulls: a cube's eight corners give a cube's volume and 12 triangles; a pyramid; points in a plane are refused.
const cube = []
for (const x of [-0.1, 0.1]) for (const y of [-0.1, 0.1]) for (const z of [-0.1, 0.1]) cube.push(x, y, z)
assert.ok(Math.abs(V.hullVolume(cube) - 0.008) < 1e-12, 'cube volume ' + V.hullVolume(cube))
assert.equal(V.hullTriangles(cube).length, 12)
checkMesh('cube hull', V.hullMesh(cube), [0, 0, 0])
const pyramid = [-0.1, 0, -0.1, 0.1, 0, -0.1, 0.1, 0, 0.1, -0.1, 0, 0.1, 0, 0.15, 0]
assert.ok(Math.abs(V.hullVolume(pyramid) - 0.2 * 0.2 * 0.15 / 3) < 1e-12, 'pyramid volume')
checkMesh('pyramid hull', V.hullMesh(pyramid), [0, 0.04, 0])
// Inner points do not change the hull.
assert.ok(Math.abs(V.hullVolume(cube.concat([0, 0, 0, 0.05, 0.02, -0.03])) - 0.008) < 1e-12, 'inner points ignored')
// A gem: an octagon ring and a point above and below.
const gem = [0, 0.08, 0, 0, -0.12, 0]
for (let k = 0; k < 8; k++) gem.push(0.1 * Math.cos(k * Math.PI / 4), 0, 0.1 * Math.sin(k * Math.PI / 4))
assert.equal(V.hullCheck(gem), '')
checkMesh('gem hull', V.hullMesh(gem), [0, 0, 0])
assert.match(V.hullCheck([0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1]), /one plane/)
assert.match(V.hullCheck([0, 0, 0, 1, 0, 0, 0, 1, 0]), /at least 4/)
assert.match(V.hullCheck([0, 0, 0, 1]), /triples/)

// What the physics is given: a record per convex part, a shape's pieces as hulls of their top and bottom corners.
{
  const out = new V.PartRecords()
  V.addPartRecords(out, 'shape', [0.2, 0.04, 0.17], triangle, 0, 0, 0, [0, 0, 0, 1])
  assert.equal(out.records.length, V.PART_RECORD, 'a triangle is one record')
  assert.equal(out.records[0], 3, 'a hull')
  assert.equal(out.records[11], 6, 'of its 6 corners')
  assert.equal(out.points.length, 18)
  V.addPartRecords(out, 'shape', [0.3, 0.1, 0.3], ell, 0, 0, 0, [0, 0, 0, 1])
  assert.equal(out.records.length, 3 * V.PART_RECORD, 'an L adds two')
  V.addPartRecords(out, 'sphere', [0.2, 0.2, 0.2], [], 0.1, 0.2, 0.3, [0, 0, 0, 1])
  assert.deepEqual(out.records.slice(-12), [1, 0.1, 0.2, 0.3, 0, 0, 0, 1, 0.1, 0, 0, 0], 'a ball: radius, where it sits')
  V.addPartRecords(out, 'cylinder', [0.1, 0.4, 0.1], [], 0, 0, 0, [0, 0, 0, 1])
  assert.deepEqual(out.records.slice(-12).slice(8), [0.05, 0.2, 0, 0], 'a cylinder: radius and half-height')
  V.addPartRecords(out, 'box', [0.2, 0.4, 0.6], [], 0, 0, 0, [0, 0, 0, 1])
  assert.deepEqual(out.records.slice(-12).slice(8), [0.1, 0.2, 0.3, 0], 'a box: half-extents')
  assert.equal(V.partCount('shape', fivePoint), starParts.length)
  assert.equal(V.partCount('box', []), 1)
}
// Bounds of a part: a box turned 90 degrees about z swaps its width and height; a ball turned is the same ball.
{
  const near = (a, b) => a.every((v, k) => Math.abs(v - b[k]) < 1e-9)
  assert.ok(near(V.partBounds('box', [0.4, 0.1, 0.2], [], [1, 0, 0], [0, 0, 90]), [0.95, -0.2, -0.1, 1.05, 0.2, 0.1]), 'box turned')
  assert.ok(near(V.partBounds('sphere', [0.2, 0.2, 0.2], [], [0, 0.5, 0], [30, 40, 50]), [-0.1, 0.4, -0.1, 0.1, 0.6, 0.1]), 'ball turned')
  assert.ok(near(V.partBounds('shape', [0.2, 0.04, 0.17], triangle, [0, 0, 0], [0, 0, 0]), [-0.1, -0.02, -0.1, 0.1, 0.02, 0.07]), 'outline')
  const q = V.quatXYZ(0, 90, 0)
  const v = V.turnPoint(q, 1, 0, 0)
  assert.ok(Math.abs(v[0]) < 1e-9 && Math.abs(v[2] + 1) < 1e-9, '90 degrees about y takes +x to -z: ' + v)
}

console.log('shapes-check ok: star ' + starParts.length + ' pieces')
