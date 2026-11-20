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
  const key = i => [0, 1, 2].map(k => (Math.round(m.positions[3 * i + k] * 1e6) / 1e6).toFixed(6)).join(',')
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

const tile = loadVera('VeraTextures').TEXTURE_TILE_M
const uvCheck = (name, mesh) => {
  assert.equal(mesh.uvs.length, mesh.positions.length / 3 * 2, name + ': two UVs per vertex')
  assert.equal(mesh.normals.length, mesh.positions.length)
  assert.equal(mesh.colors.length, mesh.positions.length)
  assert.ok(mesh.colors.every(c => c === 1), name + ': white vertices')
  assert.ok(mesh.uvs.every(Number.isFinite), name + ': finite UVs')
  for (const i of mesh.indices) assert.ok(Number.isInteger(i) && i >= 0 && i < mesh.positions.length / 3)
  for (let i = 0; i < mesh.normals.length; i += 3) assert.ok(Math.abs(Math.hypot(...mesh.normals.slice(i, i + 3)) - 1) < 1e-9)
}
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, a + ' vs ' + b)
for (const [name, mesh] of [['prism', V.prismMesh(ell, 0.7)], ['hull', V.hullMesh(pyramid)]]) {
  uvCheck(name, mesh)
  for (let i = 0; i < mesh.positions.length / 3; i++) {
    const p = mesh.positions.slice(i * 3, i * 3 + 3), n = mesh.normals.slice(i * 3, i * 3 + 3).map(Math.abs)
    const expected = n[1] >= n[0] && n[1] >= n[2] ? [p[0], p[2]] : n[0] >= n[2] ? [p[2], p[1]] : [p[0], p[1]]
    near(mesh.uvs[2 * i], expected[0] / tile)
    near(mesh.uvs[2 * i + 1], expected[1] / tile)
  }
}
const box = V.texturedBoxMesh(2, 3, 4)
uvCheck('textured box', box)
checkMesh('textured box', box, [0, 0, 0])
assert.equal(box.positions.length / 3, 24)
assert.equal(box.indices.length, 36)
for (let f = 0; f < 6; f++) {
  const base = f * 4
  for (const [a, b] of [[base, base + 1], [base + 1, base + 2], [base + 2, base + 3], [base + 3, base]]) {
    const distance = Math.hypot(...[0, 1, 2].map(k => box.positions[a * 3 + k] - box.positions[b * 3 + k]))
    const uvDistance = Math.hypot(box.uvs[a * 2] - box.uvs[b * 2], box.uvs[a * 2 + 1] - box.uvs[b * 2 + 1])
    near(distance / tile, uvDistance)
  }
}
const floor = V.texturedPlaneMesh(7, 5)
uvCheck('textured floor', floor)
assert.equal(floor.positions.length / 3, 4)
for (let i = 0; i < 4; i++) {
  near(floor.uvs[i * 2], floor.positions[i * 3] / tile)
  near(floor.uvs[i * 2 + 1], floor.positions[i * 3 + 2] / tile)
  assert.deepEqual(floor.normals.slice(i * 3, i * 3 + 3), [0, 1, 0])
}
for (let t = 0; t < floor.indices.length; t += 3) {
  const [a, b, c] = floor.indices.slice(t, t + 3).map(i => floor.positions.slice(i * 3, i * 3 + 3))
  assert.ok((b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]) > 0)
}
for (const segments of [3, 8, 32, 57]) {
  const r = 0.7, h = 2.3, mesh = V.texturedCylinderMesh(r, h, segments), row = segments + 1
  uvCheck('textured cylinder ' + segments, mesh)
  checkMesh('textured cylinder ' + segments, mesh, [0, 0, 0])
  assert.equal(mesh.indices.length, segments * 12)
  for (let j = 0; j < 2; j++) {
    for (let i = 0; i <= segments; i++) {
      near(mesh.uvs[2 * (j * row + i)], 2 * Math.PI * r * i / segments / tile)
      near(mesh.uvs[2 * (j * row + i) + 1], j * h / tile)
    }
    for (let k = 0; k < 3; k++) near(mesh.positions[3 * j * row + k], mesh.positions[3 * (j * row + segments) + k])
  }
  for (let i = 2 * row; i < mesh.positions.length / 3; i++) {
    near(mesh.uvs[i * 2], mesh.positions[i * 3] / tile)
    near(mesh.uvs[i * 2 + 1], mesh.positions[i * 3 + 2] / tile)
  }
}
for (const [lon, lat] of [[3, 2], [12, 6], [48, 24]]) {
  const r = 0.7, mesh = V.texturedSphereMesh(r, lon, lat)
  uvCheck('textured sphere', mesh)
  checkMesh('textured sphere', mesh, [0, 0, 0])
  assert.equal(mesh.indices.length, 6 * lon * (lat - 1))
  for (let j = 0; j <= lat; j++) for (let i = 0; i <= lon; i++) {
    const index = j * (lon + 1) + i
    near(mesh.uvs[index * 2], 2 * Math.PI * r * i / lon / tile)
    near(mesh.uvs[index * 2 + 1], Math.PI * r * j / lat / tile)
  }
}
assert.equal(V.texturedCylinderMesh(1, 1).indices.length, 32 * 12)
assert.equal(V.texturedSphereMesh(1).positions.length / 3, 49 * 25)
console.log('shapes-check ok: star ' + starParts.length + ' pieces; texture UV counts, winding, normals, metre scales, caps and sphere arcs')
