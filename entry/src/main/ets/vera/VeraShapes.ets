/**
 * Bodies of any shape for std/scene: scene.shape (an outline in the x/z plane, h thick along y) and scene.hull (the convex
 * body round some 3D points). Pure, so the host checks load it under node.
 *
 * The physics takes convex pieces (Jolt's ConvexHullShape, several in a StaticCompoundShape): an outline is cut into
 * convex pieces (ear clipping, then triangles merged while the merge stays convex, Hertel-Mehlhorn), each one a prism. The
 * renderer takes a SurfaceMesh with flat faces, wound counter-clockwise seen from outside, as VeraSurfaces' meshes are.
 */
import { SurfaceMesh, paintedSphere } from './VeraSurfaces'
import { TEXTURE_TILE_M } from './VeraTextures'

/** The most corners an outline may have, and the most points a hull. */
export const MAX_SHAPE_POINTS: number = 64
/** The most convex pieces an outline may be cut into. */
export const MAX_SHAPE_PARTS: number = 16
/** Lengths below this many metres count as none (a corner repeated, a side of no length). */
const EPS: number = 1e-6

/** Floats in one part record of PartRecords (and of physAddParts): [type, px, py, pz, qx, qy, qz, qw, a, b, c, n]. */
export const PART_RECORD: number = 12
/** The most convex parts one body may be made of (kMaxParts in phys_world.h). */
export const MAX_BODY_PARTS: number = 32

/**
 * What the physics is given for a body of any shape: one record per convex part (PART_RECORD floats: its type -- 0 box
 * of half-extents a, b, c; 1 sphere of radius a; 2 cylinder of radius a and half-height b; 3 hull of the next n points --
 * where it sits about the body's origin and how it is turned), and the hulls' points, x y z after x y z.
 */
export class PartRecords {
  records: number[] = []
  points: number[] = []
}

/** Twice the signed area of the outline [x1, z1, x2, z2, ...]: positive when its corners run counter-clockwise in x, z. */
function area2(p: number[]): number {
  let n = p.length / 2
  let s = 0
  for (let i = 0; i < n; i++) {
    let j = (i + 1) % n
    s += p[2 * i] * p[2 * j + 1] - p[2 * j] * p[2 * i + 1]
  }
  return s
}

function cross(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number {
  return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
}

/** Whether segments ab and cd cross or touch (collinear overlap included). */
function segmentsMeet(ax: number, az: number, bx: number, bz: number, cx: number, cz: number, dx: number, dz: number): boolean {
  let d1 = cross(cx, cz, dx, dz, ax, az)
  let d2 = cross(cx, cz, dx, dz, bx, bz)
  let d3 = cross(ax, az, bx, bz, cx, cz)
  let d4 = cross(ax, az, bx, bz, dx, dz)
  if (((d1 > EPS && d2 < -EPS) || (d1 < -EPS && d2 > EPS)) && ((d3 > EPS && d4 < -EPS) || (d3 < -EPS && d4 > EPS))) {
    return true
  }
  let on = (px: number, pz: number, qx: number, qz: number, rx: number, rz: number, d: number): boolean =>
    Math.abs(d) <= EPS && Math.min(px, qx) - EPS <= rx && rx <= Math.max(px, qx) + EPS &&
      Math.min(pz, qz) - EPS <= rz && rz <= Math.max(pz, qz) + EPS
  return on(cx, cz, dx, dz, ax, az, d1) || on(cx, cz, dx, dz, bx, bz, d2) || on(ax, az, bx, bz, cx, cz, d3) ||
    on(ax, az, bx, bz, dx, dz, d4)
}

/** The outline counter-clockwise in x, z (a copy, turned round if it ran the other way). */
export function counterClockwise(points: number[]): number[] {
  if (area2(points) >= 0) { return points.slice() }
  let out: number[] = []
  for (let i = points.length / 2 - 1; i >= 0; i--) { out.push(points[2 * i], points[2 * i + 1]) }
  return out
}

/** Triangles of a simple counter-clockwise outline, as corner indices, by ear clipping. */
function triangulate(p: number[]): number[][] {
  let left: number[] = []
  for (let i = 0; i < p.length / 2; i++) { left.push(i) }
  let out: number[][] = []
  let guard = 0
  while (left.length > 3 && guard < 10000) {
    guard++
    let cut = false
    for (let k = 0; k < left.length; k++) {
      let a = left[(k + left.length - 1) % left.length]
      let b = left[k]
      let c = left[(k + 1) % left.length]
      let ax = p[2 * a], az = p[2 * a + 1], bx = p[2 * b], bz = p[2 * b + 1], cx = p[2 * c], cz = p[2 * c + 1]
      let turn = cross(ax, az, bx, bz, cx, cz)
      if (turn <= EPS) {
        // A straight corner (collinear) is dropped without a triangle; a reflex one is no ear.
        if (Math.abs(turn) <= EPS) {
          left.splice(k, 1)
          cut = true
          break
        }
        continue
      }
      let inside = false
      for (let m of left) {
        if (m === a || m === b || m === c) { continue }
        let mx = p[2 * m], mz = p[2 * m + 1]
        if (cross(ax, az, bx, bz, mx, mz) >= -EPS && cross(bx, bz, cx, cz, mx, mz) >= -EPS &&
            cross(cx, cz, ax, az, mx, mz) >= -EPS) {
          inside = true
          break
        }
      }
      if (inside) { continue }
      out.push([a, b, c])
      left.splice(k, 1)
      cut = true
      break
    }
    if (!cut) { break }
  }
  if (left.length === 3) { out.push([left[0], left[1], left[2]]) }
  return out
}

function convexPiece(p: number[], piece: number[]): boolean {
  let n = piece.length
  for (let i = 0; i < n; i++) {
    let a = piece[i], b = piece[(i + 1) % n], c = piece[(i + 2) % n]
    if (cross(p[2 * a], p[2 * a + 1], p[2 * b], p[2 * b + 1], p[2 * c], p[2 * c + 1]) < -EPS) { return false }
  }
  return true
}

/** Two pieces that share the edge a-b (a then b in `one`, b then a in `two`), joined into one, still counter-clockwise. */
function joined(one: number[], two: number[], a: number, b: number): number[] {
  let i = one.indexOf(a)
  let j = two.indexOf(b)
  let out: number[] = []
  // one from b round to a, then two from a round to b, without repeating the shared corners.
  for (let k = 1; k <= one.length; k++) { out.push(one[(i + k) % one.length]) }
  for (let k = 1; k < two.length - 1; k++) { out.push(two[(j + 1 + k) % two.length]) }
  return out
}

/** The triangles merged while the merge stays convex: the outline's convex pieces, as corner indices. */
function convexPieces(p: number[], triangles: number[][]): number[][] {
  let pieces = triangles.map((t: number[]): number[] => t.slice())
  let merged = true
  while (merged) {
    merged = false
    for (let x = 0; x < pieces.length && !merged; x++) {
      let one = pieces[x]
      for (let e = 0; e < one.length && !merged; e++) {
        let a = one[e]
        let b = one[(e + 1) % one.length]
        for (let y = 0; y < pieces.length && !merged; y++) {
          if (y === x) { continue }
          let two = pieces[y]
          let k = two.indexOf(b)
          if (k < 0 || two[(k + 1) % two.length] !== a) { continue }
          let both = joined(one, two, a, b)
          if (!convexPiece(p, both)) { continue }
          pieces[x] = both
          pieces.splice(y, 1)
          merged = true
        }
      }
    }
  }
  return pieces
}

/**
 * Why an outline [x1, z1, x2, z2, ...] cannot be a body, or '' when it can: the count of corners, numbers that are not
 * finite, no area, sides that cross, or more convex pieces than MAX_SHAPE_PARTS.
 */
export function outlineCheck(points: number[]): string {
  if (points.length % 2 !== 0) { return 'the points are x, z pairs: an even count of numbers' }
  let n = points.length / 2
  if (n < 3) { return 'an outline needs at least 3 corners' }
  if (n > MAX_SHAPE_POINTS) { return 'an outline has at most ' + MAX_SHAPE_POINTS.toString() + ' corners' }
  for (let v of points) { if (!isFinite(v)) { return 'every point must be a finite number' } }
  for (let i = 0; i < n; i++) {
    let j = (i + 1) % n
    if (Math.hypot(points[2 * j] - points[2 * i], points[2 * j + 1] - points[2 * i + 1]) <= EPS) {
      return 'corner ' + (i + 1).toString() + ' is repeated'
    }
  }
  for (let i = 0; i < n; i++) {
    let i2 = (i + 1) % n
    for (let j = i + 1; j < n; j++) {
      let j2 = (j + 1) % n
      if (j === i2 || i === j2) { continue }
      if (segmentsMeet(points[2 * i], points[2 * i + 1], points[2 * i2], points[2 * i2 + 1],
          points[2 * j], points[2 * j + 1], points[2 * j2], points[2 * j2 + 1])) {
        return 'the sides of the outline cross: list the corners in order round it'
      }
    }
  }
  if (Math.abs(area2(points)) <= EPS) { return 'the outline encloses no area' }
  if (outlineParts(points).length > MAX_SHAPE_PARTS) {
    return 'the outline is too intricate: at most ' + MAX_SHAPE_PARTS.toString() + ' convex pieces'
  }
  return ''
}

/** The convex pieces of an outline (one that passed outlineCheck), each a counter-clockwise outline of its own. */
export function outlineParts(points: number[]): number[][] {
  let p = counterClockwise(points)
  let pieces = convexPieces(p, triangulate(p))
  return pieces.map((piece: number[]): number[] => {
    let out: number[] = []
    for (let i of piece) { out.push(p[2 * i], p[2 * i + 1]) }
    return out
  })
}

/** The box round some points of `dims` numbers each: [min..., max...]. */
export function pointBounds(points: number[], dims: number): number[] {
  let lo: number[] = []
  let hi: number[] = []
  for (let k = 0; k < dims; k++) { lo.push(Infinity); hi.push(-Infinity) }
  for (let i = 0; i + dims - 1 < points.length; i += dims) {
    for (let k = 0; k < dims; k++) {
      lo[k] = Math.min(lo[k], points[i + k])
      hi[k] = Math.max(hi[k], points[i + k])
    }
  }
  return lo.concat(hi)
}

/** One flat triangle into the mesh, wound so that it faces along (nx, ny, nz). */
function face(m: SurfaceMesh, a: number[], b: number[], c: number[], nx: number, ny: number, nz: number): void {
  let ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2]
  let vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2]
  let cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx
  let base = m.positions.length / 3
  let order: number[][] = cx * nx + cy * ny + cz * nz >= 0 ? [a, b, c] : [a, c, b]
  for (let v of order) {
    m.positions.push(v[0], v[1], v[2])
    m.normals.push(nx, ny, nz)
    m.colors.push(1, 1, 1)
    if (Math.abs(ny) >= Math.abs(nx) && Math.abs(ny) >= Math.abs(nz)) {
      m.uvs.push(v[0] / TEXTURE_TILE_M, v[2] / TEXTURE_TILE_M)
    } else if (Math.abs(nx) >= Math.abs(nz)) {
      m.uvs.push(v[2] / TEXTURE_TILE_M, v[1] / TEXTURE_TILE_M)
    } else {
      m.uvs.push(v[0] / TEXTURE_TILE_M, v[1] / TEXTURE_TILE_M)
    }
  }
  m.indices.push(base, base + 1, base + 2)
}

function textureVertex(m: SurfaceMesh, p: number[], n: number[], u: number, v: number): void {
  m.positions.push(p[0], p[1], p[2])
  m.normals.push(n[0], n[1], n[2])
  m.colors.push(1, 1, 1)
  m.uvs.push(u / TEXTURE_TILE_M, v / TEXTURE_TILE_M)
}

function textureQuad(m: SurfaceMesh, origin: number[], u: number[], v: number[], width: number, height: number): void {
  let base = m.positions.length / 3
  let n = cross3(u, v)
  for (let t of [[0, 0], [1, 0], [1, 1], [0, 1]]) {
    let p = [origin[0] + u[0] * width * t[0] + v[0] * height * t[1],
      origin[1] + u[1] * width * t[0] + v[1] * height * t[1],
      origin[2] + u[2] * width * t[0] + v[2] * height * t[1]]
    textureVertex(m, p, n, width * t[0], height * t[1])
  }
  m.indices.push(base, base + 1, base + 2, base, base + 2, base + 3)
}

export function texturedBoxMesh(width: number, height: number, depth: number): SurfaceMesh {
  let m = new SurfaceMesh()
  let x = width / 2, y = height / 2, z = depth / 2
  textureQuad(m, [x, -y, z], [0, 0, -1], [0, 1, 0], depth, height)
  textureQuad(m, [-x, -y, -z], [0, 0, 1], [0, 1, 0], depth, height)
  textureQuad(m, [-x, y, z], [1, 0, 0], [0, 0, -1], width, depth)
  textureQuad(m, [-x, -y, -z], [1, 0, 0], [0, 0, 1], width, depth)
  textureQuad(m, [-x, -y, z], [1, 0, 0], [0, 1, 0], width, height)
  textureQuad(m, [x, -y, -z], [-1, 0, 0], [0, 1, 0], width, height)
  return m
}

export function texturedPlaneMesh(width: number, depth: number): SurfaceMesh {
  let m = new SurfaceMesh()
  for (let p of [[-width / 2, 0, -depth / 2], [-width / 2, 0, depth / 2],
      [width / 2, 0, depth / 2], [width / 2, 0, -depth / 2]]) {
    textureVertex(m, p, [0, 1, 0], p[0], p[2])
  }
  m.indices.push(0, 1, 2, 0, 2, 3)
  return m
}

export function texturedCylinderMesh(radius: number, height: number, segments: number = 32): SurfaceMesh {
  let m = new SurfaceMesh()
  let count = isFinite(segments) ? Math.max(3, Math.floor(segments)) : 32
  for (let j = 0; j < 2; j++) {
    for (let i = 0; i <= count; i++) {
      let a = i === count ? 0 : 2 * Math.PI * i / count
      let x = Math.cos(a), z = -Math.sin(a)
      textureVertex(m, [radius * x, (j - 0.5) * height, radius * z], [x, 0, z], 2 * Math.PI * radius * i / count, height * j)
    }
  }
  let row = count + 1
  for (let i = 0; i < count; i++) { m.indices.push(i, i + 1, row + i, i + 1, row + i + 1, row + i) }
  for (let side = 0; side < 2; side++) {
    let ny = side === 0 ? 1 : -1
    let y = ny * height / 2
    let base = m.positions.length / 3
    textureVertex(m, [0, y, 0], [0, ny, 0], 0, 0)
    for (let i = 0; i <= count; i++) {
      let a = i === count ? 0 : 2 * Math.PI * i / count
      let x = radius * Math.cos(a), z = -radius * Math.sin(a)
      textureVertex(m, [x, y, z], [0, ny, 0], x, z)
    }
    for (let i = 0; i < count; i++) {
      if (ny > 0) { m.indices.push(base, base + i + 1, base + i + 2) }
      else { m.indices.push(base, base + i + 2, base + i + 1) }
    }
  }
  return m
}

export function texturedSphereMesh(radius: number, lon: number = 48, lat: number = 24): SurfaceMesh {
  let cols = isFinite(lon) ? Math.max(3, Math.floor(lon)) : 48
  let rows = isFinite(lat) ? Math.max(2, Math.floor(lat)) : 24
  let m = paintedSphere(radius, '', [1, 1, 1], [1, 1, 1], 0, cols, rows)
  for (let j = 0; j <= rows; j++) {
    for (let i = 0; i <= cols; i++) {
      m.uvs.push(2 * Math.PI * radius * i / cols / TEXTURE_TILE_M, Math.PI * radius * j / rows / TEXTURE_TILE_M)
    }
  }
  return m
}

/** The outline as a solid h thick along y, centred on y = 0: top, bottom and a flat side for every edge. White vertices. */
export function prismMesh(points: number[], h: number): SurfaceMesh {
  let p = counterClockwise(points)
  let m = new SurfaceMesh()
  let top = h / 2
  let tris = triangulate(p)
  for (let t of tris) {
    let a = t[0], b = t[1], c = t[2]
    face(m, [p[2 * a], top, p[2 * a + 1]], [p[2 * b], top, p[2 * b + 1]], [p[2 * c], top, p[2 * c + 1]], 0, 1, 0)
    face(m, [p[2 * a], -top, p[2 * a + 1]], [p[2 * b], -top, p[2 * b + 1]], [p[2 * c], -top, p[2 * c + 1]], 0, -1, 0)
  }
  let n = p.length / 2
  for (let i = 0; i < n; i++) {
    let j = (i + 1) % n
    let ax = p[2 * i], az = p[2 * i + 1], bx = p[2 * j], bz = p[2 * j + 1]
    let len = Math.hypot(bx - ax, bz - az)
    if (len <= EPS) { continue }
    // Counter-clockwise in x, z: the outward side of edge a->b is to its right, (dz, -dx).
    let nx = (bz - az) / len
    let nz = -(bx - ax) / len
    face(m, [ax, top, az], [bx, top, bz], [bx, -top, bz], nx, 0, nz)
    face(m, [ax, top, az], [bx, -top, bz], [ax, -top, az], nx, 0, nz)
  }
  return m
}

class HullFace {
  a: number
  b: number
  c: number
  /** Outward normal (unit) and offset: a point q is in front when n . q > d. */
  n: number[]
  d: number
  constructor(a: number, b: number, c: number, n: number[], d: number) {
    this.a = a; this.b = b; this.c = c; this.n = n; this.d = d
  }
}

function pt(p: number[], i: number): number[] { return [p[3 * i], p[3 * i + 1], p[3 * i + 2]] }

function sub(a: number[], b: number[]): number[] { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }

function cross3(a: number[], b: number[]): number[] {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

function dot3(a: number[], b: number[]): number { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

/** The face a, b, c turned to face away from `inside`. */
function hullFace(p: number[], a: number, b: number, c: number, inside: number[]): HullFace | null {
  let n = cross3(sub(pt(p, b), pt(p, a)), sub(pt(p, c), pt(p, a)))
  let len = Math.sqrt(dot3(n, n))
  if (len <= EPS * EPS) { return null }
  n = [n[0] / len, n[1] / len, n[2] / len]
  let d = dot3(n, pt(p, a))
  if (dot3(n, inside) > d) { return new HullFace(a, c, b, [-n[0], -n[1], -n[2]], -d) }
  return new HullFace(a, b, c, n, d)
}

/**
 * The triangles of the convex hull of [x1, y1, z1, ...], as point indices wound counter-clockwise seen from outside;
 * [] when the points span no volume. Incremental: plenty for MAX_SHAPE_POINTS points.
 */
export function hullTriangles(p: number[]): number[][] {
  let n = Math.floor(p.length / 3)
  if (n < 4) { return [] }
  // A first tetrahedron: the two points farthest apart along x, the point farthest from their line, and the point
  // farthest from their plane.
  let i0 = 0, i1 = 0
  for (let i = 1; i < n; i++) {
    if (p[3 * i] < p[3 * i0]) { i0 = i }
    if (p[3 * i] > p[3 * i1]) { i1 = i }
  }
  if (i0 === i1) {
    let best = -1
    for (let i = 0; i < n; i++) {
      let d = sub(pt(p, i), pt(p, i0))
      let l = dot3(d, d)
      if (l > best) { best = l; i1 = i }
    }
  }
  let line = sub(pt(p, i1), pt(p, i0))
  if (dot3(line, line) <= EPS * EPS) { return [] }
  let i2 = -1
  let far = EPS
  for (let i = 0; i < n; i++) {
    let c = cross3(line, sub(pt(p, i), pt(p, i0)))
    let l = Math.sqrt(dot3(c, c))
    if (l > far) { far = l; i2 = i }
  }
  if (i2 < 0) { return [] }
  let plane = cross3(line, sub(pt(p, i2), pt(p, i0)))
  let pl = Math.sqrt(dot3(plane, plane))
  let i3 = -1
  far = EPS * Math.max(1, pl)
  for (let i = 0; i < n; i++) {
    let h = Math.abs(dot3(plane, sub(pt(p, i), pt(p, i0))))
    if (h > far) { far = h; i3 = i }
  }
  if (i3 < 0) { return [] }
  let inside = [0, 0, 0]
  for (let i of [i0, i1, i2, i3]) {
    inside[0] += p[3 * i] / 4; inside[1] += p[3 * i + 1] / 4; inside[2] += p[3 * i + 2] / 4
  }
  let faces: HullFace[] = []
  let quad: number[][] = [[i0, i1, i2], [i0, i1, i3], [i0, i2, i3], [i1, i2, i3]]
  for (let t of quad) {
    let f = hullFace(p, t[0], t[1], t[2], inside)
    if (f !== null) { faces.push(f) }
  }
  let scale = Math.max(1e-3, Math.sqrt(dot3(line, line)))
  for (let i = 0; i < n; i++) {
    if (i === i0 || i === i1 || i === i2 || i === i3) { continue }
    let q = pt(p, i)
    let seen: boolean[] = faces.map((f: HullFace): boolean => dot3(f.n, q) - f.d > 1e-9 * scale)
    if (!seen.some((s: boolean): boolean => s)) { continue }
    // The horizon: edges of seen faces whose other face is not seen. Keyed by "from>to" as each seen face winds them.
    let edges = new Map<string, number[]>()
    for (let k = 0; k < faces.length; k++) {
      if (!seen[k]) { continue }
      let f = faces[k]
      let ring: number[][] = [[f.a, f.b], [f.b, f.c], [f.c, f.a]]
      for (let e of ring) {
        let back = e[1].toString() + '>' + e[0].toString()
        if (edges.has(back)) { edges.delete(back) } else { edges.set(e[0].toString() + '>' + e[1].toString(), e) }
      }
    }
    let kept: HullFace[] = []
    for (let k = 0; k < faces.length; k++) { if (!seen[k]) { kept.push(faces[k]) } }
    edges.forEach((e: number[]) => {
      let f = hullFace(p, e[0], e[1], i, inside)
      if (f !== null) { kept.push(f) }
    })
    faces = kept
  }
  return faces.map((f: HullFace): number[] => [f.a, f.b, f.c])
}

/** The volume of the hull of [x1, y1, z1, ...] in cubic metres, 0 when it spans none. */
export function hullVolume(p: number[]): number {
  let tris = hullTriangles(p)
  let v = 0
  for (let t of tris) { v += dot3(pt(p, t[0]), cross3(pt(p, t[1]), pt(p, t[2]))) / 6 }
  return Math.abs(v)
}

/** Why some points cannot be a hull, or '' when they can. */
export function hullCheck(points: number[]): string {
  if (points.length % 3 !== 0) { return 'the points are x, y, z triples: a count of numbers divisible by 3' }
  let n = points.length / 3
  if (n < 4) { return 'a hull needs at least 4 points' }
  if (n > MAX_SHAPE_POINTS) { return 'a hull has at most ' + MAX_SHAPE_POINTS.toString() + ' points' }
  for (let v of points) { if (!isFinite(v)) { return 'every point must be a finite number' } }
  if (hullTriangles(points).length < 4) { return 'the points lie in one plane: a hull needs volume' }
  return ''
}

/** The convex hull of [x1, y1, z1, ...] with a flat normal on every face. White vertices. */
export function hullMesh(points: number[]): SurfaceMesh {
  let m = new SurfaceMesh()
  for (let t of hullTriangles(points)) {
    let a = pt(points, t[0]), b = pt(points, t[1]), c = pt(points, t[2])
    let nrm = cross3(sub(b, a), sub(c, a))
    let len = Math.sqrt(dot3(nrm, nrm))
    if (len <= 0) { continue }
    face(m, a, b, c, nrm[0] / len, nrm[1] / len, nrm[2] / len)
  }
  return m
}

/** Degrees about x, then y, then z (as VeraMotion.poseMatrix) as a quaternion [x, y, z, w]: q = qz * qy * qx. */
export function quatXYZ(degX: number, degY: number, degZ: number): number[] {
  let hx = degX * Math.PI / 360
  let hy = degY * Math.PI / 360
  let hz = degZ * Math.PI / 360
  let cx = Math.cos(hx)
  let sx = Math.sin(hx)
  let cy = Math.cos(hy)
  let sy = Math.sin(hy)
  let cz = Math.cos(hz)
  let sz = Math.sin(hz)
  // qy * qx
  let w1 = cy * cx
  let x1 = cy * sx
  let y1 = sy * cx
  let z1 = -sy * sx
  // qz * (qy * qx)
  return [cz * x1 - sz * y1, cz * y1 + sz * x1, cz * z1 + sz * w1, cz * w1 - sz * z1]
}

/** v turned by the quaternion q [x, y, z, w]. */
export function turnPoint(q: number[], x: number, y: number, z: number): number[] {
  let tx = 2 * (q[1] * z - q[2] * y)
  let ty = 2 * (q[2] * x - q[0] * z)
  let tz = 2 * (q[0] * y - q[1] * x)
  return [x + q[3] * tx + (q[1] * tz - q[2] * ty), y + q[3] * ty + (q[2] * tx - q[0] * tz), z + q[3] * tz + (q[0] * ty - q[1] * tx)]
}

/** The points a body's shape reaches to, about its own centre: corners, a hull's points, a prism's top and bottom corners. */
function reachPoints(shape: string, dims: number[], points: number[]): number[] {
  if (shape === 'hull') { return points.slice() }
  if (shape === 'shape') {
    let out: number[] = []
    for (let i = 0; i + 1 < points.length; i += 2) {
      out.push(points[i], dims[1] / 2, points[i + 1], points[i], -dims[1] / 2, points[i + 1])
    }
    return out
  }
  let out: number[] = []
  for (let sx of [-1, 1]) {
    for (let sy of [-1, 1]) {
      for (let sz of [-1, 1]) { out.push(sx * dims[0] / 2, sy * dims[1] / 2, sz * dims[2] / 2) }
    }
  }
  return out
}

/**
 * The box [minX, minY, minZ, maxX, maxY, maxZ] a body of this shape fills when it stands at (px, py, pz) turned by
 * degrees rx, ry, rz: what a group's parts add up to. A ball turns into itself.
 */
export function partBounds(shape: string, dims: number[], points: number[], position: number[], rotation: number[]): number[] {
  let q = shape === 'sphere' ? [0, 0, 0, 1] : quatXYZ(rotation[0], rotation[1], rotation[2])
  let reach = reachPoints(shape, dims, points)
  let moved: number[] = []
  for (let i = 0; i + 2 < reach.length; i += 3) {
    let v = turnPoint(q, reach[i], reach[i + 1], reach[i + 2])
    moved.push(v[0] + position[0], v[1] + position[1], v[2] + position[2])
  }
  return pointBounds(moved, 3)
}

/** How many convex parts the physics makes of a body of this shape (an outline may be cut into several). */
export function partCount(shape: string, points: number[]): number {
  return shape === 'shape' ? outlineParts(points).length : 1
}

/**
 * The records of one body of this shape (box, sphere, cylinder, shape or hull) standing at (px, py, pz) about the body's
 * origin, turned by the quaternion q, added to out.
 */
export function addPartRecords(out: PartRecords, shape: string, dims: number[], points: number[], px: number, py: number,
    pz: number, q: number[]): void {
  let head = (type: number, a: number, b: number, c: number, n: number): void => {
    out.records.push(type, px, py, pz, q[0], q[1], q[2], q[3], a, b, c, n)
  }
  if (shape === 'sphere') {
    head(1, dims[0] / 2, 0, 0, 0)
  } else if (shape === 'cylinder') {
    head(2, dims[0] / 2, dims[1] / 2, 0, 0)
  } else if (shape === 'hull') {
    head(3, 0, 0, 0, points.length / 3)
    for (let v of points) { out.points.push(v) }
  } else if (shape === 'shape') {
    let h = dims[1]
    for (let piece of outlineParts(points)) {
      head(3, 0, 0, 0, piece.length)
      for (let i = 0; i < piece.length; i += 2) {
        out.points.push(piece[i], h / 2, piece[i + 1], piece[i], -h / 2, piece[i + 1])
      }
    }
  } else {
    head(0, dims[0] / 2, dims[1] / 2, dims[2] / 2, 0)
  }
}

// ---------------------------------------------------------------- pieces: what scene.split cuts a body into

/** The most pieces scene.split makes of one body. */
export const MAX_SPLIT: number = 8

/** The area of an outline [x1, z1, ...] in square metres. */
export function outlineArea(points: number[]): number {
  return Math.abs(area2(points)) / 2
}

/**
 * A box of extents dims cut into n cells as a grid: the counts along x, y, z whose product is n and whose cells are the
 * least elongated (ties go to cutting the longer sides), each cell [cx, cy, cz, w, h, d] about the box's centre.
 */
export function boxGrid(dims: number[], n: number): number[][] {
  let best: number[] = [n, 1, 1]
  let bestScore = Infinity
  for (let a = 1; a <= n; a++) {
    if (n % a !== 0) { continue }
    for (let b = 1; b <= n / a; b++) {
      if ((n / a) % b !== 0) { continue }
      let c = n / a / b
      let cell = [dims[0] / a, dims[1] / b, dims[2] / c]
      let score = Math.max(cell[0], cell[1], cell[2]) / Math.max(1e-9, Math.min(cell[0], cell[1], cell[2]))
      // Ties: the grid whose cuts go across the longer sides (the larger count on the longer side) wins.
      let tie = a * dims[0] + b * dims[1] + c * dims[2]
      let bestTie = best[0] * dims[0] + best[1] * dims[1] + best[2] * dims[2]
      if (score < bestScore - 1e-9 || (Math.abs(score - bestScore) <= 1e-9 && tie > bestTie)) {
        bestScore = score
        best = [a, b, c]
      }
    }
  }
  let out: number[][] = []
  let w = dims[0] / best[0], h = dims[1] / best[1], d = dims[2] / best[2]
  for (let i = 0; i < best[0]; i++) {
    for (let j = 0; j < best[1]; j++) {
      for (let k = 0; k < best[2]; k++) {
        out.push([-dims[0] / 2 + (i + 0.5) * w, -dims[1] / 2 + (j + 0.5) * h, -dims[2] / 2 + (k + 0.5) * d, w, h, d])
      }
    }
  }
  return out
}

/** Points [x, y, z, ...] with near repeats left out. */
function distinct(points: number[]): number[] {
  let out: number[] = []
  for (let i = 0; i + 2 < points.length; i += 3) {
    let seen = false
    for (let j = 0; j + 2 < out.length && !seen; j += 3) {
      seen = Math.abs(out[j] - points[i]) < 1e-7 && Math.abs(out[j + 1] - points[i + 1]) < 1e-7 && Math.abs(out[j + 2] - points[i + 2]) < 1e-7
    }
    if (!seen) { out.push(points[i], points[i + 1], points[i + 2]) }
  }
  return out
}

/** Only the points that are corners of their hull, and at most MAX_SHAPE_POINTS of them (the ones nearest the middle go first). */
function hullCorners(points: number[]): number[] {
  let p = distinct(points)
  let used = new Set<number>()
  for (let t of hullTriangles(p)) { used.add(t[0]); used.add(t[1]); used.add(t[2]) }
  let out: number[] = []
  for (let i = 0; i < p.length / 3; i++) { if (used.has(i)) { out.push(p[3 * i], p[3 * i + 1], p[3 * i + 2]) } }
  if (out.length / 3 <= MAX_SHAPE_POINTS) { return out }
  let c = [0, 0, 0]
  let m = out.length / 3
  for (let i = 0; i < m; i++) { c[0] += out[3 * i] / m; c[1] += out[3 * i + 1] / m; c[2] += out[3 * i + 2] / m }
  let order: number[] = []
  for (let i = 0; i < m; i++) { order.push(i) }
  let far = (i: number): number => Math.hypot(out[3 * i] - c[0], out[3 * i + 1] - c[1], out[3 * i + 2] - c[2])
  order.sort((a: number, b: number): number => far(b) - far(a))
  let kept: number[] = []
  for (let k = 0; k < MAX_SHAPE_POINTS; k++) { kept.push(out[3 * order[k]], out[3 * order[k] + 1], out[3 * order[k] + 2]) }
  return kept
}

/**
 * The convex hull of points [x, y, z, ...] cut by the plane n . p = d: [the part in front (n . p >= d), the part behind],
 * each as the corners of its hull ([] for a side with no volume).
 */
export function cutHull(points: number[], normal: number[], offset: number): number[][] {
  let tris = hullTriangles(points)
  let front: number[] = []
  let back: number[] = []
  let side = (i: number): number => normal[0] * points[3 * i] + normal[1] * points[3 * i + 1] + normal[2] * points[3 * i + 2] - offset
  let used = new Set<number>()
  let edges = new Set<string>()
  for (let t of tris) {
    for (let k = 0; k < 3; k++) {
      let a = t[k]
      let b = t[(k + 1) % 3]
      used.add(a)
      let key = Math.min(a, b).toString() + ':' + Math.max(a, b).toString()
      if (edges.has(key)) { continue }
      edges.add(key)
      let sa = side(a)
      let sb = side(b)
      if ((sa > 1e-12 && sb < -1e-12) || (sa < -1e-12 && sb > 1e-12)) {
        let f = sa / (sa - sb)
        let x = points[3 * a] + (points[3 * b] - points[3 * a]) * f
        let y = points[3 * a + 1] + (points[3 * b + 1] - points[3 * a + 1]) * f
        let z = points[3 * a + 2] + (points[3 * b + 2] - points[3 * a + 2]) * f
        front.push(x, y, z)
        back.push(x, y, z)
      }
    }
  }
  used.forEach((i: number) => {
    let s = side(i)
    if (s >= -1e-12) { front.push(points[3 * i], points[3 * i + 1], points[3 * i + 2]) }
    if (s <= 1e-12) { back.push(points[3 * i], points[3 * i + 1], points[3 * i + 2]) }
  })
  let keep = (p: number[]): number[] => hullTriangles(distinct(p)).length >= 4 && hullVolume(distinct(p)) > 1e-12 ? hullCorners(p) : []
  return [keep(front), keep(back)]
}

/**
 * A convex hull cut into n pieces by planes: the largest piece so far cut through the middle of its box, across its
 * longest side, until there are n (fewer only if a piece will not cut).
 */
export function splitHull(points: number[], n: number): number[][] {
  let pieces: number[][] = [hullCorners(points)]
  while (pieces.length < n) {
    let at = 0
    for (let k = 1; k < pieces.length; k++) { if (hullVolume(pieces[k]) > hullVolume(pieces[at])) { at = k } }
    let b = pointBounds(pieces[at], 3)
    let axis = 0
    for (let k = 1; k < 3; k++) { if (b[k + 3] - b[k] > b[axis + 3] - b[axis]) { axis = k } }
    let normal = [0, 0, 0]
    normal[axis] = 1
    let two = cutHull(pieces[at], normal, (b[axis] + b[axis + 3]) / 2)
    if (two[0].length === 0 || two[1].length === 0) { break }
    pieces.splice(at, 1, two[0], two[1])
  }
  return pieces
}

/**
 * A ball of radius r as n chunks from its centre outward: n sectors about the upright, or, for an even n of 4 or more,
 * n / 2 sectors each cut at the equator (8: the octants). Each chunk is a hull's points about the ball's centre, scaled
 * so that together they hold the ball's volume (scaling about the centre keeps them apart: each is a cone from it).
 */
export function sphereChunks(r: number, n: number): number[][] {
  let layers = n % 2 === 0 && n >= 4 ? 2 : 1
  let sectors = n / layers
  let span = 2 * Math.PI / sectors
  let steps = Math.max(2, Math.ceil(span / (Math.PI / 6)))
  let rows = layers === 1 ? 6 : 4
  let chunks: number[][] = []
  for (let layer = 0; layer < layers; layer++) {
    let lo = layers === 1 ? -Math.PI / 2 : (layer === 0 ? -Math.PI / 2 : 0)
    let hi = layers === 1 ? Math.PI / 2 : (layer === 0 ? 0 : Math.PI / 2)
    for (let s = 0; s < sectors; s++) {
      let p: number[] = [0, 0, 0]
      for (let i = 0; i <= steps; i++) {
        let a = s * span + span * i / steps
        for (let j = 0; j <= rows; j++) {
          let phi = lo + (hi - lo) * j / rows
          p.push(r * Math.cos(phi) * Math.cos(a), r * Math.sin(phi), -r * Math.cos(phi) * Math.sin(a))
        }
      }
      chunks.push(distinct(p))
    }
  }
  let total = 0
  for (let c of chunks) { total += hullVolume(c) }
  let k = total > 0 ? Math.cbrt(4 / 3 * Math.PI * r * r * r / total) : 1
  return chunks.map((c: number[]): number[] => c.map((v: number): number => v * k))
}

/**
 * An upright cylinder of radius r and height h as n wedges about its axis, each a hull's points about its centre, widened
 * so that together they hold the cylinder's volume.
 */
export function cylinderWedges(r: number, h: number, n: number): number[][] {
  let span = 2 * Math.PI / n
  let steps = Math.max(1, Math.ceil(span / (Math.PI / 8)))
  let wedges: number[][] = []
  for (let s = 0; s < n; s++) {
    let p: number[] = [0, h / 2, 0, 0, -h / 2, 0]
    for (let i = 0; i <= steps; i++) {
      let a = s * span + span * i / steps
      p.push(r * Math.cos(a), h / 2, -r * Math.sin(a), r * Math.cos(a), -h / 2, -r * Math.sin(a))
    }
    wedges.push(p)
  }
  let total = 0
  for (let w of wedges) { total += hullVolume(w) }
  let k = total > 0 ? Math.sqrt(Math.PI * r * r * h / total) : 1
  return wedges.map((w: number[]): number[] => {
    let out: number[] = []
    for (let i = 0; i < w.length; i += 3) { out.push(w[i] * k, w[i + 1], w[i + 2] * k) }
    return out
  })
}

/** A convex outline cut by the line where (nx, nz) . p = d: [in front, behind], each [] when it has no area. */
function cutOutline(p: number[], nx: number, nz: number, d: number): number[][] {
  let front: number[] = []
  let back: number[] = []
  let m = p.length / 2
  for (let i = 0; i < m; i++) {
    let j = (i + 1) % m
    let si = nx * p[2 * i] + nz * p[2 * i + 1] - d
    let sj = nx * p[2 * j] + nz * p[2 * j + 1] - d
    if (si >= 0) { front.push(p[2 * i], p[2 * i + 1]) }
    if (si <= 0) { back.push(p[2 * i], p[2 * i + 1]) }
    if ((si > 0 && sj < 0) || (si < 0 && sj > 0)) {
      let f = si / (si - sj)
      let x = p[2 * i] + (p[2 * j] - p[2 * i]) * f
      let z = p[2 * i + 1] + (p[2 * j + 1] - p[2 * i + 1]) * f
      front.push(x, z)
      back.push(x, z)
    }
  }
  let clean = (q: number[]): number[] => {
    let out: number[] = []
    for (let i = 0; i < q.length; i += 2) {
      let k = out.length
      if (k >= 2 && Math.hypot(out[k - 2] - q[i], out[k - 1] - q[i + 1]) <= EPS) { continue }
      out.push(q[i], q[i + 1])
    }
    while (out.length >= 4 && Math.hypot(out[0] - out[out.length - 2], out[1] - out[out.length - 1]) <= EPS) { out.splice(out.length - 2, 2) }
    return out.length >= 6 && outlineArea(out) > EPS ? out : []
  }
  return [clean(front), clean(back)]
}

/** Two outlines that share a side (a to b in one, b to a in the other), joined into one; null when they share none. */
function mergeOutlines(one: number[], two: number[]): number[] | null {
  let n1 = one.length / 2
  let n2 = two.length / 2
  let same = (p: number[], i: number, q: number[], j: number): boolean =>
    Math.abs(p[2 * i] - q[2 * j]) <= 1e-9 && Math.abs(p[2 * i + 1] - q[2 * j + 1]) <= 1e-9
  for (let i = 0; i < n1; i++) {
    let i2 = (i + 1) % n1
    for (let j = 0; j < n2; j++) {
      let j2 = (j + 1) % n2
      if (!same(one, i, two, j2) || !same(one, i2, two, j)) { continue }
      // one from i2 round to i, then two from j2 + 1 round to j - 1 (its corners other than the shared side's).
      let out: number[] = []
      for (let k = 0; k < n1; k++) { let c = (i2 + k) % n1; out.push(one[2 * c], one[2 * c + 1]) }
      for (let k = 1; k < n2 - 1; k++) { let c = (j2 + k) % n2; out.push(two[2 * c], two[2 * c + 1]) }
      return out
    }
  }
  return null
}

/**
 * An outline cut into n pieces: its convex pieces (outlineParts), neighbours joined, the two smallest together first, while
 * there are more than n, and the largest cut across its longest side while there are fewer. Each piece is an outline
 * [x1, z1, ...] about the same origin.
 */
export function splitOutline(points: number[], n: number): number[][] {
  let parts = outlineParts(points).map((p: number[]): number[] => counterClockwise(p))
  while (parts.length > n) {
    let best: number[] | null = null
    let bx = -1
    let by = -1
    let bestArea = Infinity
    for (let x = 0; x < parts.length; x++) {
      for (let y = x + 1; y < parts.length; y++) {
        let area = outlineArea(parts[x]) + outlineArea(parts[y])
        if (area >= bestArea) { continue }
        let m = mergeOutlines(parts[x], parts[y])
        if (m === null) { continue }
        best = m
        bestArea = area
        bx = x
        by = y
      }
    }
    if (best === null) { break }
    parts.splice(by, 1)
    parts[bx] = best as number[]
  }
  while (parts.length < n) {
    let at = 0
    for (let k = 1; k < parts.length; k++) { if (outlineArea(parts[k]) > outlineArea(parts[at])) { at = k } }
    let b = pointBounds(parts[at], 2)
    let alongX = b[2] - b[0] >= b[3] - b[1]
    let two = alongX ? cutOutline(parts[at], 1, 0, (b[0] + b[2]) / 2) : cutOutline(parts[at], 0, 1, (b[1] + b[3]) / 2)
    if (two[0].length === 0 || two[1].length === 0) { break }
    parts.splice(at, 1, two[0], two[1])
  }
  return parts
}
