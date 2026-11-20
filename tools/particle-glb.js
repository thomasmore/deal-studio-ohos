'use strict'
const fs = require('node:fs')
const path = require('node:path')

const output = path.join(__dirname, '../entry/src/main/resources/rawfile/vera-particle.glb')

function particleGlb() {
  const faces = [
    [[-.5, -.5, .5], [.5, -.5, .5], [.5, .5, .5], [-.5, .5, .5]],
    [[.5, -.5, -.5], [-.5, -.5, -.5], [-.5, .5, -.5], [.5, .5, -.5]],
    [[.5, -.5, .5], [.5, -.5, -.5], [.5, .5, -.5], [.5, .5, .5]],
    [[-.5, -.5, -.5], [-.5, -.5, .5], [-.5, .5, .5], [-.5, .5, -.5]],
    [[-.5, .5, .5], [.5, .5, .5], [.5, .5, -.5], [-.5, .5, -.5]],
    [[-.5, -.5, -.5], [.5, -.5, -.5], [.5, -.5, .5], [-.5, -.5, .5]]
  ]
  const normals = [[0, 0, 1], [0, 0, -1], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]]
  const positions = faces.flat(2), directions = normals.flatMap(n => Array.from({length: 4}, () => n).flat())
  const indices = faces.flatMap((_, i) => [0, 1, 2, 0, 2, 3].map(v => 4 * i + v))
  const binary = Buffer.alloc(positions.length * 8 + indices.length * 2)
  positions.concat(directions).forEach((v, i) => binary.writeFloatLE(v, i * 4))
  indices.forEach((v, i) => binary.writeUInt16LE(v, positions.length * 8 + i * 2))
  const doc = {
    asset: {version: '2.0', generator: 'Vera owned particle cube'}, scene: 0,
    extensionsUsed: ['KHR_materials_unlit'], extensionsRequired: ['KHR_materials_unlit'],
    scenes: [{nodes: [0]}], nodes: [{name: 'particleCube', mesh: 0}],
    meshes: [{primitives: [{attributes: {POSITION: 0, NORMAL: 1}, indices: 2, material: 0, mode: 4}]}],
    materials: [{name: 'particleUnlit', alphaMode: 'BLEND', extensions: {KHR_materials_unlit: {}},
      pbrMetallicRoughness: {baseColorFactor: [1, 1, 1, 0], metallicFactor: 0, roughnessFactor: 1}}],
    buffers: [{byteLength: binary.length}],
    bufferViews: [
      {buffer: 0, byteOffset: 0, byteLength: positions.length * 4, target: 34962},
      {buffer: 0, byteOffset: positions.length * 4, byteLength: directions.length * 4, target: 34962},
      {buffer: 0, byteOffset: positions.length * 8, byteLength: indices.length * 2, target: 34963}
    ],
    accessors: [
      {bufferView: 0, componentType: 5126, count: 24, type: 'VEC3', min: [-.5, -.5, -.5], max: [.5, .5, .5]},
      {bufferView: 1, componentType: 5126, count: 24, type: 'VEC3'},
      {bufferView: 2, componentType: 5123, count: 36, type: 'SCALAR'}
    ]
  }
  const text = Buffer.from(JSON.stringify(doc)), json = Buffer.alloc((text.length + 3) & ~3, 32)
  text.copy(json)
  const header = Buffer.alloc(20), binHeader = Buffer.alloc(8)
  header.writeUInt32LE(0x46546c67, 0)
  header.writeUInt32LE(2, 4)
  header.writeUInt32LE(28 + json.length + binary.length, 8)
  header.writeUInt32LE(json.length, 12)
  header.writeUInt32LE(0x4e4f534a, 16)
  binHeader.writeUInt32LE(binary.length, 0)
  binHeader.writeUInt32LE(0x004e4942, 4)
  return Buffer.concat([header, json, binHeader, binary])
}

module.exports = {particleGlb, output}
if (require.main === module) {
  if (process.argv.includes('--check')) require('node:assert/strict').deepEqual(fs.readFileSync(output), particleGlb())
  else fs.writeFileSync(output, particleGlb())
}
