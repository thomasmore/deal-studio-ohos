'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const {execFileSync} = require('node:child_process')
const {loadVera} = require('./source-loader')
const M = loadVera('VeraModels')
const S = loadVera('VeraShapes')
const root = path.resolve(__dirname, '../..')
const directory = path.join(root, 'entry/src/main/resources/rawfile/models')
const moduleFile = path.join(root, 'entry/src/main/ets/vera/VeraModels.ets')
const catalog = JSON.parse(fs.readFileSync(path.join(directory, 'models.json'), 'utf8'))
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
// Text files are hashed as committed; a windows checkout may hold them with CRLF
// while the manifest records LF (or the reverse), so accept either line ending.
// .glb stays binary and is only ever hashed raw.
const textFiles = new Set(['models.json', 'LICENSE.txt'])
const lfBytes = bytes => Buffer.from(bytes.toString('utf8').replace(/\r\n/g, '\n'), 'utf8')
const checksumMatches = (file, bytes, expected) =>
  sha(bytes) === expected || (textFiles.has(file) && sha(lfBytes(bytes)) === expected)
const near = (actual, expected, label, tolerance = 1e-8) => {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${label}: ${actual} vs ${expected}`)
}
const nearVector = (actual, expected, label, tolerance) => {
  assert.equal(actual.length, expected.length, label)
  actual.forEach((value, i) => near(value, expected[i], label + '[' + i + ']', tolerance))
}
const sub = (a, b) => a.map((v, k) => v - b[k])
const dot = (a, b) => a.reduce((sum, v, k) => sum + v * b[k], 0)
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
const triples = flat => Array.from({length: flat.length / 3}, (_, i) => flat.slice(i * 3, i * 3 + 3))
const bounds = points => [0, 1, 2].map(k => [Math.min(...points.map(p => p[k])), Math.max(...points.map(p => p[k]))])
const rotate = p => [p[2], p[1], -p[0]]

function applyNode(node, point) {
  if (node.matrix) {
    return [0, 1, 2].map(r => point.reduce((v, p, k) => v + p * node.matrix[k * 4 + r], node.matrix[12 + r]))
  }
  const p = point.map((v, k) => v * (node.scale || [1, 1, 1])[k])
  const q = node.rotation || [0, 0, 0, 1]
  const xyz = q.slice(0, 3), uv = cross(xyz, p), uuv = cross(xyz, uv)
  return p.map((v, k) => v + 2 * (q[3] * uv[k] + uuv[k]) + (node.translation || [0, 0, 0])[k])
}

function glbGeometry(bytes) {
  assert.equal(bytes.toString('ascii', 0, 4), 'glTF')
  assert.equal(bytes.readUInt32LE(4), 2)
  assert.equal(bytes.readUInt32LE(8), bytes.length)
  const chunks = []
  for (let offset = 12; offset < bytes.length;) {
    const length = bytes.readUInt32LE(offset), type = bytes.readUInt32LE(offset + 4)
    assert.equal(length % 4, 0)
    assert.ok(offset + 8 + length <= bytes.length)
    chunks.push({type, data: bytes.subarray(offset + 8, offset + 8 + length)})
    offset += length + 8
  }
  assert.deepEqual(chunks.map(c => c.type), [0x4e4f534a, 0x004e4942])
  const doc = JSON.parse(chunks[0].data.toString('utf8')), binary = chunks[1].data
  assert.equal(doc.asset.version, '2.0')
  assert.equal(doc.buffers.length, 1)
  assert.equal(doc.buffers[0].uri, undefined)
  assert.ok(binary.length - doc.buffers[0].byteLength >= 0 && binary.length - doc.buffers[0].byteLength <= 3)
  assert.deepEqual(doc.extensionsRequired || [], [])
  assert.ok((doc.extensionsUsed || []).every(e => e === 'KHR_materials_unlit'))
  for (const image of doc.images || []) {
    assert.equal(image.uri, undefined)
    assert.ok(Number.isInteger(image.bufferView))
    assert.ok(['image/png', 'image/jpeg'].includes(image.mimeType))
  }
  const formats = {5120: ['readInt8', 1], 5121: ['readUInt8', 1], 5122: ['readInt16LE', 2],
    5123: ['readUInt16LE', 2], 5125: ['readUInt32LE', 4], 5126: ['readFloatLE', 4]}
  const widths = {SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4}
  const read = index => {
    const acc = doc.accessors[index], view = doc.bufferViews[acc.bufferView]
    assert.equal(acc.sparse, undefined)
    const [method, size] = formats[acc.componentType], width = widths[acc.type]
    const start = (view.byteOffset || 0) + (acc.byteOffset || 0), stride = view.byteStride || size * width
    assert.equal(start % size, 0)
    assert.ok(start + (acc.count - 1) * stride + size * width <= (view.byteOffset || 0) + view.byteLength)
    return Array.from({length: acc.count}, (_, i) => Array.from({length: width}, (_, k) => binary[method](start + i * stride + k * size)))
  }
  for (let i = 0; i < doc.accessors.length; i++) assert.ok(read(i).flat().every(Number.isFinite))
  for (const mesh of doc.meshes) for (const primitive of mesh.primitives) {
    assert.equal(primitive.mode === undefined ? 4 : primitive.mode, 4)
    assert.equal(primitive.targets, undefined)
    const positions = read(primitive.attributes.POSITION)
    assert.equal(doc.accessors[primitive.attributes.POSITION].type, 'VEC3')
    for (const index of Object.values(primitive.attributes)) assert.equal(doc.accessors[index].count, positions.length)
    if (primitive.indices !== undefined) {
      const indices = read(primitive.indices).flat()
      assert.equal(indices.length % 3, 0)
      assert.ok(indices.every(i => Number.isInteger(i) && i >= 0 && i < positions.length))
    }
  }
  const vertices = []
  function visit(index, ancestors) {
    assert.ok(!ancestors.includes(index), 'node cycle')
    const node = doc.nodes[index], chain = [index, ...ancestors]
    if (node.mesh !== undefined) for (const primitive of doc.meshes[node.mesh].primitives) {
      for (let p of read(primitive.attributes.POSITION)) {
        for (const id of chain) p = applyNode(doc.nodes[id], p)
        vertices.push(p)
      }
    }
    for (const child of node.children || []) visit(child, chain)
  }
  for (const index of doc.scenes[doc.scene || 0].nodes) visit(index, [])
  assert.ok(vertices.length > 0)
  return {doc, vertices}
}

function containsHull(flat, vertices, label, tolerance = 1e-7) {
  assert.equal(S.hullCheck(flat), '', label + ': hullCheck')
  const points = triples(flat), faces = S.hullTriangles(flat)
  assert.ok(S.hullVolume(flat) > 0, label + ': hull volume')
  const center = points.reduce((sum, p) => sum.map((v, k) => v + p[k] / points.length), [0, 0, 0])
  for (const face of faces) {
    const [a, b, c] = face.map(i => points[i])
    const normal = cross(sub(b, a), sub(c, a)), length = Math.hypot(...normal)
    if (length < 1e-16) continue
    assert.ok(dot(normal, sub(center, a)) <= tolerance * length, label + ': outward face')
    for (const p of vertices) assert.ok(dot(normal, sub(p, a)) <= tolerance * length, label + ': contains mesh vertex ' + p)
  }
}

assert.ok(catalog.models.length >= 25 && catalog.models.length <= 40)
assert.equal(catalog.provenance.repository, 'Tiddybub/3d-assets')
assert.equal(catalog.provenance.commit, '11ff7082e566a6278553bf7623980cb93dd41e27')
assert.equal(catalog.provenance.sourceArchiveSha256, null)
assert.match(catalog.provenance.authenticity_note, /not claimed byte-identical/)
assert.equal(catalog.license, 'CC0-1.0')
const names = catalog.models.map(m => m.name)
assert.deepEqual(M.modelNames(), names)
assert.equal(new Set(names).size, names.length)
for (const required of ['raceCarRed', 'treeSmall', 'treeLarge']) assert.ok(names.includes(required))
assert.equal(M.modelSpec('not-a-model'), null)
assert.equal(M.modelShape('not-a-model', 1), null)
for (const bad of [0, -1, NaN, Infinity, -Infinity]) assert.equal(M.modelShape('treeSmall', bad), null)
const detachedNames = M.modelNames()
detachedNames.length = 0
assert.equal(M.modelNames().length, names.length)
const expectedFiles = [...names.map(n => n + '.glb'), 'LICENSE.txt', 'models.json', 'SHA256SUMS'].sort()
assert.deepEqual(fs.readdirSync(directory).sort(), expectedFiles)
const checksumLines = fs.readFileSync(path.join(directory, 'SHA256SUMS'), 'utf8').replace(/\r\n/g, '\n').trim().split('\n')
const checksums = new Map(checksumLines.map(line => {
  assert.match(line, /^[a-f0-9]{64}  [A-Za-z0-9_.-]+$/)
  const [digest, file] = line.split('  ')
  return [file, digest]
}))
assert.deepEqual([...checksums.keys()].sort(), expectedFiles.filter(f => f !== 'SHA256SUMS'))
assert.equal(checksumLines.length, checksums.size)
let totalBytes = 0, maxBytes = 0
for (const file of expectedFiles) {
  const bytes = fs.readFileSync(path.join(directory, file))
  totalBytes += bytes.length
  if (checksums.has(file)) assert.ok(checksumMatches(file, bytes, checksums.get(file)), file + ': checksum')
}
assert.ok(totalBytes <= 3000000)
assert.ok(checksumMatches('LICENSE.txt', fs.readFileSync(path.join(directory, 'LICENSE.txt')), catalog.provenance.licenseSha256), 'LICENSE.txt: provenance checksum')
for (const model of catalog.models) {
  const spec = M.modelSpec(model.name)
  assert.ok(spec)
  for (const key of ['name', 'description', 'file', 'min', 'max', 'points', 'forward']) assert.deepEqual(spec[key], model[key])
  assert.equal(spec.file, 'models/' + model.name + '.glb')
  assert.deepEqual(spec.forward, [0, 0, 1])
  const bytes = fs.readFileSync(path.join(directory, model.name + '.glb'))
  assert.equal(bytes.length, model.bytes)
  assert.equal(sha(bytes), model.sha256)
  assert.ok(bytes.length <= 100000)
  maxBytes = Math.max(maxBytes, bytes.length)
  assert.equal(model.optimization.lossless, true)
  assert.deepEqual(model.optimization.newExtensions, [])
  assert.match(model.source.sha256, /^[a-f0-9]{64}$/)
  assert.match(model.source.gitBlobSha1, /^[a-f0-9]{40}$/)
  assert.ok(model.source.bytes >= model.bytes)
  assert.ok(model.points.length / 3 <= 64)
  assert.equal(model.collision.containsAllVertices, true)
  if (model.collision.method !== 'exact-convex-hull') assert.ok(model.collision.reason)
  const {vertices, doc} = glbGeometry(bytes)
  const rawBounds = bounds(vertices)
  nearVector(spec.min, rawBounds.map(b => b[0]), model.name + ': raw min')
  nearVector(spec.max, rawBounds.map(b => b[1]), model.name + ': raw max')
  const center = spec.min.map((v, k) => (v + spec.max[k]) / 2)
  nearVector(model.support, [center[0], spec.min[1], center[2]], model.name + ': bottom support')
  containsHull(spec.points, vertices, model.name + ': raw')
  if (model.name.startsWith('raceCar')) {
    const front = doc.nodes.find(n => n.name === 'wheelFrontLeft')
    const back = doc.nodes.find(n => n.name === 'wheelBackLeft')
    assert.ok(front.translation[2] > back.translation[2], 'car front is +z')
    assert.ok(model.source.bytes > 100000 && model.bytes < 100000)
    assert.ok(model.optimization.compactedIndexAccessors > 0)
  }
  const unchanged = JSON.stringify(spec)
  for (const size of [0.1, 0.73, 1, 3.5]) {
    const shape = M.modelShape(model.name, size)
    assert.ok(shape)
    assert.equal(shape.yawDeg, 90)
    near(Math.max(...shape.dims), size, model.name + ': requested largest dimension')
    const scale = size / Math.max(...spec.max.map((v, k) => v - spec.min[k]))
    near(shape.scale, scale, model.name + ': uniform scale')
    nearVector(shape.offset, rotate(center).map(v => -v * scale), model.name + ': renderer offset')
    const transformed = vertices.map(p => rotate(p).map((v, k) => v * scale + shape.offset[k]))
    const actualBounds = bounds(transformed)
    for (let k = 0; k < 3; k++) {
      near(actualBounds[k][0], -shape.dims[k] / 2, model.name + ': centered lower bound')
      near(actualBounds[k][1], shape.dims[k] / 2, model.name + ': centered upper bound')
    }
    const rawHull = triples(spec.points).map(p => rotate(sub(p, center)).map(v => v * scale)).flat()
    nearVector(shape.points, rawHull, model.name + ': centered rotated hull')
    containsHull(shape.points, transformed, model.name + ': body size ' + size)
    const anchor = [2.3, -0.4, 5.7]
    const world = transformed.map(p => p.map((v, k) => v + anchor[k] + (k === 1 ? shape.dims[1] / 2 : 0)))
    const worldBounds = bounds(world)
    near(worldBounds[1][0], anchor[1], model.name + ': anchored bottom')
    near((worldBounds[0][0] + worldBounds[0][1]) / 2, anchor[0], model.name + ': anchor x')
    near((worldBounds[2][0] + worldBounds[2][1]) / 2, anchor[2], model.name + ': anchor z')
    shape.points[0] += 1
    shape.offset[0] += 1
    shape.dims[0] += 1
    nearVector(M.modelShape(model.name, size).points, rawHull, model.name + ': fresh shape arrays')
  }
  assert.equal(JSON.stringify(spec), unchanged, model.name + ': no input mutation')
}
nearVector(applyNode({translation: [3, 4, 5], rotation: [0, Math.SQRT1_2, 0, Math.SQRT1_2], scale: [2, 3, 4]}, [1, 1, 1]), [7, 7, 3], 'TRS fixture')
nearVector(applyNode({matrix: [1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 0, -1, 4, 5, 1]}, [1, 2, 3]), [0, 8, 14], 'matrix fixture')
const moduleSource = fs.readFileSync(moduleFile, 'utf8')
assert.doesNotMatch(moduleSource, /\bimport\b|@kit\.|VeraScene|BodySpec/)
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const virtualFile = path.join(path.dirname(moduleFile), 'VeraModels.ts').replace(/\\/g, '\n')
const options = {strict: true, noEmit: true, target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
const host = ts.createCompilerHost(options), getSourceFile = host.getSourceFile.bind(host)
host.getSourceFile = (file, languageVersion, onError, shouldCreateNewSourceFile) => file.replace(/\\/g, '\n') === virtualFile
  ? ts.createSourceFile(virtualFile, moduleSource, languageVersion, true)
  : getSourceFile(file, languageVersion, onError, shouldCreateNewSourceFile)
const program = ts.createProgram([virtualFile], options, host)
const diagnostics = ts.getPreEmitDiagnostics(program)
assert.deepEqual(diagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), [], 'strict catalogue typecheck')
const python =[['python3'], ['python'], ['py', '-3']].find(candidate => {
  try { execFileSync(candidate[0], [...candidate.slice(1), '--version'], {stdio: 'ignore'}); return true } catch { return false }
})
if (python) execFileSync(python[0], [...python.slice(1), 'tools/model-catalog.py', '--check'], {cwd: root, stdio: 'inherit'})
else console.log('models-check: python not found; skipped tools/model-catalog.py --check')
console.log(`models-check: ${names.length} models, ${totalBytes} total bytes, ${maxBytes} largest GLB; hashes, hulls, containment, scaling, transforms and strict types passed`)
