export function surfaceSeed(id: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < id.length; i++) {
    h = h ^ id.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return h >>> 0
}

export function hash3(ix: number, iy: number, iz: number, seed: number): number {
  let h = Math.imul(ix, 374761393) ^ Math.imul(iy, 668265263) ^ Math.imul(iz, 2147483647) ^ Math.imul(seed, 1274126177)
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  h = h ^ (h >>> 16)
  return (h >>> 0) / 4294967296
}

function smooth(t: number): number { return t * t * (3 - 2 * t) }

export function noise3(x: number, y: number, z: number, seed: number): number {
  let ix = Math.floor(x)
  let iy = Math.floor(y)
  let iz = Math.floor(z)
  let fx = smooth(x - ix)
  let fy = smooth(y - iy)
  let fz = smooth(z - iz)
  let c = (dx: number, dy: number, dz: number): number => hash3(ix + dx, iy + dy, iz + dz, seed)
  let x00 = c(0, 0, 0) + (c(1, 0, 0) - c(0, 0, 0)) * fx
  let x10 = c(0, 1, 0) + (c(1, 1, 0) - c(0, 1, 0)) * fx
  let x01 = c(0, 0, 1) + (c(1, 0, 1) - c(0, 0, 1)) * fx
  let x11 = c(0, 1, 1) + (c(1, 1, 1) - c(0, 1, 1)) * fx
  let y0 = x00 + (x10 - x00) * fy
  let y1 = x01 + (x11 - x01) * fy
  return y0 + (y1 - y0) * fz
}

export function fbm(x: number, y: number, z: number, octaves: number, seed: number): number {
  let sum = 0
  let amp = 0.5
  let norm = 0
  let f = 1
  for (let o = 0; o < octaves; o++) {
    sum += amp * noise3(x * f, y * f, z * f, seed + o * 101)
    norm += amp
    amp *= 0.5
    f *= 2
  }
  return sum / norm
}
