/**
 * What a ball looks like on its surface: the patterns scene.paint names, as colours over a sphere, and the meshes the
 * renderer builds from them -- a sphere coloured vertex by vertex, and a flat ring (rings round a body, or the mark round a
 * selected one). Pure: colours in, numbers out, so the host checks and proofs run it as the phone does.
 *
 * A pattern is how a surface looks, not what it is: the program says which look suits its body ("patches" for land on
 * sea, a map, a camouflage; "craters" for a moon or a golf ball). Every colour comes from the program but the white of
 * the caps and wisps; where a feature sits (an oval, a crater, an edge) comes from the body's seed. The program picks the pattern and both colours; the host draws
 * it, with value noise over the unit sphere (no seam, no stretching at the poles) seeded by the body's id, so two moons
 * with the same pattern still differ and a body looks the same every time it is built.
 */

import { hash3, fbm } from './VeraNoise'
export { surfaceSeed } from './VeraNoise'

/** The patterns scene.paint takes, each by how it looks (the prompt is built from this). */
export const SURFACE_PATTERNS: string[][] = [
  ['patches', 'large patches of the second colour over the first, with white caps at both poles and thin white wisps'],
  ['bands', 'wavy stripes along the latitudes in the two colours'],
  ['oval', 'bands with one large oval in a deeper shade of the second colour'],
  ['craters', 'the colour pocked with round craters, with dark plains in the second colour'],
  ['mottled', 'the colour mottled with small patches of the second colour'],
  ['polar', 'mottled, with white caps at both poles'],
  ['swirls', 'soft swirls of the two colours'],
  ['stripes', 'segments from pole to pole, alternating the two colours'],
]

export function surfacePattern(name: string): boolean {
  for (let p of SURFACE_PATTERNS) { if (p[0] === name) { return true } }
  return false
}

/** Segments round a painted sphere and from pole to pole: enough for coastlines on a planet a few centimetres across. */
export const SURFACE_LON: number = 72
export const SURFACE_LAT: number = 36
/** Segments round a ring. */
export const RING_SEGMENTS: number = 96

function smooth(t: number): number { return t * t * (3 - 2 * t) }

function mix(a: number[], b: number[], t: number): number[] {
  let k = Math.max(0, Math.min(1, t))
  return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k]
}

function shade(c: number[], k: number): number[] {
  return [Math.min(1, c[0] * k), Math.min(1, c[1] * k), Math.min(1, c[2] * k)]
}

function step(edge0: number, edge1: number, x: number): number {
  return smooth(Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0))))
}

const WHITE: number[] = [0.96, 0.97, 0.99]

/**
 * The colour (sRGB 0..1) of a pattern at the point (x, y, z) of the unit sphere, y up: c1 is the body's colour, c2 the
 * second colour scene.paint gave. An unknown pattern is the plain colour.
 */
export function surfaceColor(pattern: string, c1: number[], c2: number[], seed: number, x: number, y: number, z: number): number[] {
  let lat = Math.asin(Math.max(-1, Math.min(1, y)))
  let lon = Math.atan2(z, x)
  if (pattern === 'patches') {
    let h = fbm(x * 1.6 + 7, y * 1.6, z * 1.6, 5, seed)
    let land = step(0.5, 0.53, h)
    // Deeper seas darker, highland lighter and drier.
    let sea = shade(c1, 0.8 + 0.4 * h)
    // Highland is the land's own colour, lighter: no tint of any one planet's deserts.
    let ground = mix(shade(c2, 0.85 + 0.3 * fbm(x * 6, y * 6, z * 6, 3, seed + 9)), shade(c2, 1.35), step(0.62, 0.75, h) * 0.6)
    let c = mix(sea, ground, land)
    let ice = step(0.86, 0.9, Math.abs(y) + 0.06 * (fbm(x * 4, y * 4, z * 4, 2, seed + 3) - 0.5))
    c = mix(c, WHITE, ice)
    let cloud = step(0.58, 0.72, fbm(x * 2.4 + 31, y * 3.6, z * 2.4, 4, seed + 77))
    return mix(c, WHITE, cloud * 0.55)
  }
  if (pattern === 'bands' || pattern === 'oval') {
    let warp = (fbm(x * 3, y * 3, z * 3, 3, seed) - 0.5) * 0.5
    let wave = 0.5 + 0.5 * Math.sin(lat * 11 + warp * 4 + Math.sin(lat * 3.7) * 1.3)
    let c = mix(c1, c2, wave)
    c = shade(c, 0.9 + 0.2 * fbm(x * 8, y * 2, z * 8, 2, seed + 5))
    if (pattern === 'oval') {
      // One oval, longer east-west than north-south, at a latitude and longitude of the body's own (seeded), in a deeper
      // shade of the second colour with a lighter core.
      let south = hash3(1, 2, 3, seed) < 0.5 ? -1 : 1
      let atLat = south * (0.25 + 0.3 * hash3(4, 5, 6, seed))
      let atLon = 2 * Math.PI * hash3(7, 8, 9, seed)
      let dLat = (lat - atLat) / 0.17
      let dLon = Math.atan2(Math.sin(lon - atLon), Math.cos(lon - atLon)) / 0.34
      let d = Math.sqrt(dLat * dLat + dLon * dLon)
      let eye = shade(c2, 0.72)
      c = mix(c, mix(eye, shade(c2, 1.1), 1 - step(0.2, 0.6, d)), 1 - step(0.75, 1.0, d))
    }
    return c
  }
  if (pattern === 'craters') {
    let c = mix(c1, c2, step(0.55, 0.62, fbm(x * 1.4, y * 1.4, z * 1.4, 4, seed)) * 0.85)
    c = shade(c, 0.88 + 0.24 * fbm(x * 10, y * 10, z * 10, 2, seed + 1))
    // Craters: cells of a coarse grid in space, each maybe holding one pit with a bright rim.
    let scale = 5
    let gx = x * scale
    let gy = y * scale
    let gz = z * scale
    let ix = Math.floor(gx)
    let iy = Math.floor(gy)
    let iz = Math.floor(gz)
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (let dz = -1; dz <= 1; dz++) {
          let cx = ix + dx
          let cy = iy + dy
          let cz = iz + dz
          if (hash3(cx, cy, cz, seed + 13) > 0.55) { continue }
          let px = cx + hash3(cx, cy, cz, seed + 17)
          let py = cy + hash3(cx, cy, cz, seed + 19)
          let pz = cz + hash3(cx, cy, cz, seed + 23)
          let r = 0.18 + 0.3 * hash3(cx, cy, cz, seed + 29)
          let d = Math.sqrt((gx - px) * (gx - px) + (gy - py) * (gy - py) + (gz - pz) * (gz - pz)) / r
          if (d < 1) { c = shade(c, 0.72 + 0.18 * d) } else if (d < 1.25) { c = shade(c, 1.12) }
        }
      }
    }
    return c
  }
  if (pattern === 'mottled' || pattern === 'polar') {
    let c = mix(c1, c2, step(0.45, 0.65, fbm(x * 1.8, y * 1.8, z * 1.8, 5, seed)))
    c = shade(c, 0.86 + 0.28 * fbm(x * 9, y * 9, z * 9, 2, seed + 4))
    if (pattern === 'polar') {
      c = mix(c, WHITE, step(0.84, 0.88, Math.abs(y) + 0.05 * (fbm(x * 5, y * 5, z * 5, 2, seed + 8) - 0.5)))
    }
    return c
  }
  if (pattern === 'swirls') {
    let w = fbm(x * 1.5, y * 1.5, z * 1.5, 3, seed) * 2.2
    let t = fbm(x * 2 + w, y * 3.5 + w * 0.5, z * 2 - w, 4, seed + 41)
    return mix(c1, c2, step(0.35, 0.7, t))
  }
  if (pattern === 'stripes') {
    let k = Math.floor(((lon + Math.PI) / (2 * Math.PI)) * 6) % 2
    let c = k === 0 ? c1 : c2
    return mix(c, WHITE, step(0.93, 0.97, Math.abs(y)))
  }
  return [c1[0], c1[1], c1[2]]
}

/** A mesh as plain arrays: positions, normals and colours three numbers a vertex (colours sRGB 0..1), and triangle indices. */
export class SurfaceMesh {
  positions: number[] = []
  normals: number[] = []
  colors: number[] = []
  uvs: number[] = []
  indices: number[] = []
}

/** A sphere of radius r, lon by lat segments, each vertex coloured by its pattern. Seam vertices are repeated, so no colour bleeds across. */
export function paintedSphere(r: number, pattern: string, c1: number[], c2: number[], seed: number,
    lonSegments: number = SURFACE_LON, latSegments: number = SURFACE_LAT): SurfaceMesh {
  let m = new SurfaceMesh()
  for (let j = 0; j <= latSegments; j++) {
    let lat = Math.PI / 2 - Math.PI * j / latSegments
    let y = Math.sin(lat)
    let ring = Math.cos(lat)
    for (let i = 0; i <= lonSegments; i++) {
      let lon = 2 * Math.PI * i / lonSegments
      let x = ring * Math.cos(lon)
      let z = -ring * Math.sin(lon)
      m.positions.push(x * r, y * r, z * r)
      m.normals.push(x, y, z)
      let c = surfaceColor(pattern, c1, c2, seed, x, y, z)
      m.colors.push(c[0], c[1], c[2])
    }
  }
  let row = lonSegments + 1
  for (let j = 0; j < latSegments; j++) {
    for (let i = 0; i < lonSegments; i++) {
      let a = j * row + i
      let b = a + row
      // Counter-clockwise seen from outside.
      if (j > 0) { m.indices.push(a, b, a + 1) }
      if (j < latSegments - 1) { m.indices.push(a + 1, b, b + 1) }
    }
  }
  return m
}

/**
 * A flat ring in the plane y = 0 from radius inner to outer, seen from both sides (each face twice, wound each way), in
 * the colour with faint darker lanes across it (bands = 0 for one even colour, as a selection mark is).
 */
export function flatRing(inner: number, outer: number, c: number[], bands: number, seed: number,
    segments: number = RING_SEGMENTS): SurfaceMesh {
  let m = new SurfaceMesh()
  let rows = bands > 0 ? 6 : 1
  for (let side = 0; side < 2; side++) {
    let base = m.positions.length / 3
    let ny = side === 0 ? 1 : -1
    for (let k = 0; k <= rows; k++) {
      let t = k / rows
      let r = inner + (outer - inner) * t
      let lane = bands > 0 ? 0.78 + 0.32 * hash3(k, 0, 0, seed) : 1
      for (let i = 0; i <= segments; i++) {
        let a = 2 * Math.PI * i / segments
        m.positions.push(r * Math.cos(a), 0, -r * Math.sin(a))
        m.normals.push(0, ny, 0)
        m.colors.push(Math.min(1, c[0] * lane), Math.min(1, c[1] * lane), Math.min(1, c[2] * lane))
      }
    }
    let row = segments + 1
    for (let k = 0; k < rows; k++) {
      for (let i = 0; i < segments; i++) {
        let a = base + k * row + i
        let b = a + row
        if (side === 0) {
          m.indices.push(a, b, a + 1, a + 1, b, b + 1)
        } else {
          m.indices.push(a, a + 1, b, a + 1, b + 1, b)
        }
      }
    }
  }
  return m
}
