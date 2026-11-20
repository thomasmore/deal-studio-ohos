'use strict'
const fs = require('node:fs')
const path = require('node:path')
const zlib = require('node:zlib')
const {loadVera} = require('./source-loader')
const T = loadVera('VeraTextures')
const G = loadVera('VeraShapes')
const width = 1080, rowHeight = 200, height = 64 + rowHeight * T.TEXTURE_PATTERNS.length
const pixels = Buffer.alloc(width * height * 4)
const depth = new Float64Array(width * height).fill(-Infinity)
for (let i = 0; i < pixels.length; i += 4) pixels.set([237, 240, 244, 255], i)
const fonts = {
  A: '01110/10001/10001/11111/10001/10001/10001', B: '11110/10001/10001/11110/10001/10001/11110',
  C: '01111/10000/10000/10000/10000/10000/01111', D: '11110/10001/10001/10001/10001/10001/11110',
  E: '11111/10000/10000/11110/10000/10000/11111', F: '11111/10000/10000/11110/10000/10000/10000',
  G: '01111/10000/10000/10111/10001/10001/01111', H: '10001/10001/10001/11111/10001/10001/10001',
  I: '11111/00100/00100/00100/00100/00100/11111', K: '10001/10010/10100/11000/10100/10010/10001',
  L: '10000/10000/10000/10000/10000/10000/11111', M: '10001/11011/10101/10101/10001/10001/10001',
  N: '10001/11001/10101/10011/10001/10001/10001', O: '01110/10001/10001/10001/10001/10001/01110',
  P: '11110/10001/10001/11110/10000/10000/10000', R: '11110/10001/10001/11110/10100/10010/10001',
  S: '01111/10000/10000/01110/00001/00001/11110', T: '11111/00100/00100/00100/00100/00100/00100',
  U: '10001/10001/10001/10001/10001/10001/01110', V: '10001/10001/10001/10001/10001/01010/00100',
  W: '10001/10001/10001/10101/10101/10101/01010', X: '10001/10001/01010/00100/01010/10001/10001',
  Y: '10001/10001/01010/00100/00100/00100/00100', '1': '00100/01100/00100/00100/00100/00100/01110',
}
function dot(x, y, c) {
  if (x >= 0 && y >= 0 && x < width && y < height) pixels.set([...c, 255], (y * width + x) * 4)
}
function text(value, x, y, scale = 2) {
  for (const char of value.toUpperCase()) {
    const rows = (fonts[char] || '00000/00000/00000/00000/00000/00000/00000').split('/')
    rows.forEach((row, j) => [...row].forEach((v, i) => {
      if (v === '1') for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) dot(x + i * scale + dx, y + j * scale + dy, [32, 42, 57])
    }))
    x += 6 * scale
  }
}
const palettes = [
  [[0.64, 0.38, 0.16], [0.23, 0.11, 0.04]],
  [[0.67, 0.43, 0.23], [0.22, 0.12, 0.06]],
  [[0.65, 0.23, 0.14], [0.77, 0.73, 0.65]],
  [[0.2, 0.59, 0.68], [0.88, 0.89, 0.84]],
  [[0.69, 0.7, 0.67], [0.18, 0.22, 0.23]],
  [[0.13, 0.31, 0.07], [0.48, 0.65, 0.17]],
  [[0.84, 0.7, 0.45], [0.58, 0.43, 0.24]],
  [[0.75, 0.8, 0.85], [0.29, 0.36, 0.44]],
  [[0.91, 0.91, 0.87], [0.2, 0.28, 0.31]],
  [[0.9, 0.88, 0.79], [0.08, 0.12, 0.19]],
  [[0.67, 0.19, 0.12], [0.93, 0.7, 0.43]],
]
const mod = (x, n) => ((x % n) + n) % n
function texel(image, u, v) {
  const x = (u - Math.floor(u)) * 256 - 0.5, y = (v - Math.floor(v)) * 256 - 0.5
  const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy
  const c = [0, 0, 0]
  for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) {
    const weight = (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy)
    const i = 4 * (mod(iy + dy, 256) * 256 + mod(ix + dx, 256))
    for (let k = 0; k < 3; k++) c[k] += image[i + k] * weight
  }
  return c
}
const sin = Math.sin(0.7), cos = Math.cos(0.7), tilt = 0.55, up = Math.sqrt(1 - tilt * tilt)
function render(mesh, image, cx, cy, scale) {
  const vertices = []
  for (let i = 0; i < mesh.positions.length; i += 3) {
    const [x, y, z] = mesh.positions.slice(i, i + 3)
    vertices.push([cx + scale * (cos * x - sin * z), cy - scale * (-sin * tilt * x + up * y - cos * tilt * z), sin * up * x + tilt * y + cos * up * z])
  }
  for (let t = 0; t < mesh.indices.length; t += 3) {
    const ids = mesh.indices.slice(t, t + 3), [a, b, c] = ids.map(i => vertices[i])
    const area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if (area >= -1e-9) continue
    const xmin = Math.max(0, Math.floor(Math.min(a[0], b[0], c[0]))), xmax = Math.min(width - 1, Math.ceil(Math.max(a[0], b[0], c[0])))
    const ymin = Math.max(0, Math.floor(Math.min(a[1], b[1], c[1]))), ymax = Math.min(height - 1, Math.ceil(Math.max(a[1], b[1], c[1])))
    for (let y = ymin; y <= ymax; y++) for (let x = xmin; x <= xmax; x++) {
      const wa = ((b[0] - x - 0.5) * (c[1] - y - 0.5) - (b[1] - y - 0.5) * (c[0] - x - 0.5)) / area
      const wb = ((c[0] - x - 0.5) * (a[1] - y - 0.5) - (c[1] - y - 0.5) * (a[0] - x - 0.5)) / area
      const wc = 1 - wa - wb
      if (Math.min(wa, wb, wc) < -1e-9) continue
      const z = wa * a[2] + wb * b[2] + wc * c[2], index = y * width + x
      if (z <= depth[index]) continue
      depth[index] = z
      const weights = [wa, wb, wc], n = [0, 0, 0]
      let u = 0, v = 0
      for (let j = 0; j < 3; j++) {
        u += mesh.uvs[ids[j] * 2] * weights[j]; v += mesh.uvs[ids[j] * 2 + 1] * weights[j]
        for (let k = 0; k < 3; k++) n[k] += mesh.normals[ids[j] * 3 + k] * weights[j]
      }
      const light = 0.5 + 0.5 * Math.max(0, (-0.35 * n[0] + 0.8 * n[1] + 0.48 * n[2]) / Math.hypot(...n))
      dot(x, y, texel(image, u, v).map(c => Math.round(c * light)))
    }
  }
}
text('PURE TEXTURES', 18, 20)
text('CUBE', 302, 20)
text('CYLINDER', 565, 20)
text('FLOOR', 895, 20)
T.TEXTURE_PATTERNS.forEach(([pattern], row) => {
  const top = 64 + row * rowHeight, [c1, c2] = palettes[row]
  const image = T.texturePixels(pattern, c1, c2, 123, 256)
  text(pattern, 16, top + 8)
  for (let y = 0; y < 128; y++) for (let x = 0; x < 128; x++) dot(16 + x, top + 36 + y, texel(image, x / 128, y / 128).map(Math.round))
  render(G.texturedBoxMesh(1.4, 1.4, 1.4), image, 340, top + 100, 69)
  render(G.texturedCylinderMesh(0.75, 1.5, 48), image, 640, top + 100, 73)
  render(G.texturedPlaneMesh(3, 3), image, 925, top + 100, 57)
  for (let x = 0; x < width; x++) dot(x, top + rowHeight - 1, [207, 214, 222])
})
function crc32(bytes) {
  let crc = 0xffffffff
  for (const byte of bytes) {
    crc ^= byte
    for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0)
  }
  return (crc ^ 0xffffffff) >>> 0
}
function chunk(name, data) {
  const type = Buffer.from(name), out = Buffer.alloc(data.length + 12)
  out.writeUInt32BE(data.length, 0); type.copy(out, 4); data.copy(out, 8)
  out.writeUInt32BE(crc32(Buffer.concat([type, data])), out.length - 4)
  return out
}
const header = Buffer.alloc(13)
header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6
const rows = Buffer.alloc(height * (width * 4 + 1))
for (let y = 0; y < height; y++) pixels.copy(rows, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4)
const output = path.resolve(process.argv[2] || '/tmp/opencode/texture-proofs.png')
if (!fs.statSync(path.dirname(output)).isDirectory()) throw Error('output directory must exist')
fs.writeFileSync(output, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]))
console.log(output + ': ' + width + 'x' + height + ', 11 patterns on cube/cylinder/floor, actual UV geometry and RGBA, repeat bilinear sampling')
