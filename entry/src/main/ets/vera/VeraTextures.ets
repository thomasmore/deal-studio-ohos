import { hash3 } from './VeraNoise'

export const TEXTURE_PATTERNS: string[][] = [
  ['wood', 'long flowing grain lines and fine fibres in the two colours'],
  ['planks', 'parallel boards with staggered end joints and flowing grain inside each board'],
  ['brick', 'offset rows of rectangular blocks, separated by thin mortar lines in the second colour'],
  ['tiles', 'a regular grid of smooth square faces with narrow grout lines in the second colour'],
  ['stone', 'irregular angular patches with dark narrow cracks and a speckled surface'],
  ['grass', 'dense short overlapping blade-like streaks in the two colours'],
  ['sand', 'fine scattered grains over soft rippling bands in the two colours'],
  ['metal', 'fine parallel brushed scratches with occasional longer scoring in the two colours'],
  ['marble', 'thin branching wavy veins of the second colour through a softly mottled first colour'],
  ['checker', 'crisp alternating squares of the two colours'],
  ['fabric', 'a fine woven grid of alternating over-and-under threads in the two colours'],
]

export const TEXTURE_TILE_M: number = 1

export function texturePattern(name: string): boolean {
  for (let p of TEXTURE_PATTERNS) { if (p[0] === name) { return true } }
  return false
}

function wrap(x: number): number { return x - Math.floor(x) }
function clamp(x: number): number { return Math.max(0, Math.min(1, x)) }
function smooth(x: number): number { let t = clamp(x); return t * t * (3 - 2 * t) }
function mod(x: number, n: number): number { return ((x % n) + n) % n }

function periodicNoise(u: number, v: number, nx: number, ny: number, seed: number): number {
  let x = wrap(u) * nx, y = wrap(v) * ny
  let ix = Math.floor(x), iy = Math.floor(y)
  let fx = smooth(x - ix), fy = smooth(y - iy)
  let a = hash3(ix, iy, 0, seed)
  let b = hash3(mod(ix + 1, nx), iy, 0, seed)
  let c = hash3(ix, mod(iy + 1, ny), 0, seed)
  let d = hash3(mod(ix + 1, nx), mod(iy + 1, ny), 0, seed)
  return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
}

function grain(u: number, v: number, seed: number): number {
  let warp = periodicNoise(u, v, 4, 4, seed)
  let rings = 0.5 + 0.5 * Math.sin(2 * Math.PI * (u * 12 + warp * 1.7))
  let fibre = periodicNoise(u, v, 128, 8, seed + 13)
  return clamp(0.12 + 0.65 * Math.pow(rings, 5) + 0.23 * fibre)
}

function textureWeight(pattern: string, u: number, v: number, seed: number): number {
  let tau = 2 * Math.PI
  if (pattern === 'checker') { return (Math.floor(u * 8) + Math.floor(v * 8)) % 2 }
  if (pattern === 'wood') { return grain(u, v, seed) }
  if (pattern === 'planks') {
    let board = Math.floor(u * 4)
    let x = wrap(u * 4), y = wrap(v * 2 + (board % 2) * 0.5)
    let edge = Math.min(x, 1 - x, y, 1 - y)
    let joint = 1 - smooth(edge / 0.025)
    return joint + (1 - joint) * clamp(grain(u, v, seed) * 0.75 + hash3(board, mod(Math.floor(v * 2 + (board % 2) * 0.5), 2), 0, seed) * 0.15)
  }
  if (pattern === 'brick' || pattern === 'tiles') {
    let rows = pattern === 'brick' ? 8 : 4
    let row = Math.floor(v * rows)
    let x = wrap(u * 4 + (pattern === 'brick' ? (row % 2) * 0.5 : 0))
    let y = wrap(v * rows)
    let edge = Math.min(x, 1 - x, y, 1 - y)
    let grout = 1 - smooth((edge - 0.035) / 0.025)
    let cell = Math.floor(u * 4 + (pattern === 'brick' ? (row % 2) * 0.5 : 0)) % 4
    let body = 0.07 + 0.25 * hash3(cell, row, 0, seed) + 0.12 * periodicNoise(u, v, 64, 64, seed + 7)
    return grout + (1 - grout) * body
  }
  if (pattern === 'stone') {
    let x = u * 5, y = v * 5
    let ix = Math.floor(x), iy = Math.floor(y)
    let near = 100, next = 100, tint = 0
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        let cx = ix + dx, cy = iy + dy
        let hx = mod(cx, 5), hy = mod(cy, 5)
        let px = cx + 0.15 + 0.7 * hash3(hx, hy, 0, seed)
        let py = cy + 0.15 + 0.7 * hash3(hx, hy, 1, seed)
        let dist = (x - px) * (x - px) + (y - py) * (y - py)
        if (dist < near) { next = near; near = dist; tint = hash3(hx, hy, 2, seed) }
        else if (dist < next) { next = dist }
      }
    }
    let crack = 1 - smooth((Math.sqrt(next) - Math.sqrt(near)) / 0.065)
    return clamp(crack * 0.85 + (1 - crack) * (0.1 + 0.65 * tint + 0.15 * periodicNoise(u, v, 96, 96, seed + 9)))
  }
  if (pattern === 'grass') {
    let bend = periodicNoise(u, v, 12, 16, seed)
    let blades = Math.pow(0.5 + 0.5 * Math.sin(tau * (u * 72 + bend * 1.3)), 3)
    let tips = periodicNoise(u, v, 64, 48, seed + 17)
    return clamp(0.08 + blades * 0.65 + tips * 0.27)
  }
  if (pattern === 'sand') {
    let warp = periodicNoise(u, v, 4, 4, seed)
    let ripple = 0.5 + 0.5 * Math.sin(tau * (v * 8 + warp * 0.7))
    return 0.1 + 0.4 * ripple + 0.5 * periodicNoise(u, v, 192, 192, seed + 19)
  }
  if (pattern === 'metal') {
    let brushed = periodicNoise(u, v, 4, 128, seed)
    let scratch = Math.pow(periodicNoise(u, v, 8, 96, seed + 23), 9)
    return clamp(0.08 + 0.65 * brushed + 0.8 * scratch)
  }
  if (pattern === 'marble') {
    let warp = periodicNoise(u, v, 4, 4, seed) + 0.35 * periodicNoise(u, v, 16, 16, seed + 5)
    let wave = Math.abs(Math.sin(tau * (u * 3 + v * 2 + warp)))
    let vein = 1 - smooth(wave / 0.2)
    return clamp(vein * 0.9 + 0.15 * periodicNoise(u, v, 8, 8, seed + 29))
  }
  if (pattern === 'fabric') {
    let x = 0.5 + 0.5 * Math.cos(tau * u * 64)
    let y = 0.5 + 0.5 * Math.cos(tau * v * 64)
    let over = 0.5 + 0.5 * Math.sin(tau * u * 32) * Math.sin(tau * v * 32)
    let thread = x * over + (1 - y) * (1 - over)
    return clamp(0.1 + 0.7 * thread + 0.2 * periodicNoise(u, v, 64, 64, seed))
  }
  return 0
}

export function textureSample(pattern: string, c1: number[], c2: number[], seed: number, u: number, v: number): number[] {
  let t = textureWeight(pattern, wrap(u), wrap(v), seed >>> 0)
  return [clamp(c1[0] + (c2[0] - c1[0]) * t), clamp(c1[1] + (c2[1] - c1[1]) * t), clamp(c1[2] + (c2[2] - c1[2]) * t)]
}

export function texturePixels(pattern: string, c1: number[], c2: number[], seed: number, size: number): Uint8Array {
  if (!isFinite(size) || size < 1 || size > 4096 || Math.floor(size) !== size) { throw new Error('texture size must be an integer in 1..4096') }
  let out = new Uint8Array(size * size * 4)
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let c = textureSample(pattern, c1, c2, seed, (x + 0.5) / size, (y + 0.5) / size)
      let i = 4 * (y * size + x)
      out[i] = Math.round(c[0] * 255)
      out[i + 1] = Math.round(c[1] * 255)
      out[i + 2] = Math.round(c[2] * 255)
      out[i + 3] = 255
    }
  }
  return out
}

function colorKey(c: number[]): string {
  let view = new DataView(new ArrayBuffer(24))
  for (let i = 0; i < 3; i++) { view.setFloat64(i * 8, clamp(c[i]), false) }
  let key = ''
  for (let i = 0; i < 24; i++) { key += view.getUint8(i).toString(16).padStart(2, '0') }
  return key
}

export function textureKey(pattern: string, c1: number[], c2: number[], seed: number): string {
  return 'tex_v2_256_' + (texturePattern(pattern) ? pattern : 'plain') + '_' + colorKey(c1) + '_' + colorKey(c2) + '_' + (seed >>> 0).toString(16)
}

export function textureRoughness(pattern: string): number {
  if (pattern === 'metal') { return 0.32 }
  if (pattern === 'tiles') { return 0.38 }
  if (pattern === 'marble') { return 0.3 }
  if (pattern === 'wood' || pattern === 'planks') { return 0.78 }
  if (pattern === 'stone' || pattern === 'brick') { return 0.9 }
  if (pattern === 'grass' || pattern === 'sand' || pattern === 'fabric') { return 0.96 }
  return 0.65
}
