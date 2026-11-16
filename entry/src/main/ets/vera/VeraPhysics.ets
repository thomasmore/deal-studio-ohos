/**
 * The physics of a ui.World, as the program never sees it.
 *
 * PhysEngine is the native library's API (libphys.so, Jolt) as an interface, so the world's logic -- which body is which
 * index, what a diff does to the physics, when a kick fires, when the dice have settled and what they show, which knocks
 * are worth telling the program -- runs the same on the phone (NativePhys in components/VeraWorld3D.ets) and on the host
 * (FakePhys, below). WorldSim is that logic. FakePhys is a small deterministic stand-in: it checks the logic, not how
 * convincing a throw looks; tuning the feel is done on the phone against Jolt.
 *
 * Pure: imports only relative modules, never a platform kit, so tools/vera-harness loads it under node.
 */

import { WorldSpec, BodySpec, WorldDiff, SceneKick, TableSpec, orbitPositions, topFace } from './VeraScene'
import { tableParts, quatXYZ, TABLE_TOP_THICKNESS } from './VeraLook3D'

/** Body kinds, as the native library numbers them. */
export const PHYS_STATIC: number = 0
export const PHYS_DYNAMIC: number = 1
export const PHYS_KINEMATIC: number = 2

/**
 * The native physics API (entry/src/main/cpp/types/libphys/index.d.ts), one method per function. Metres, seconds,
 * kilograms; y up; quaternions x, y, z, w; bodies named by a dense index that is reused after remove.
 */
export interface PhysEngine {
  /** Threads used, or 0 when there is no physics in this build. */
  init(maxBodies: number, threads: number): number
  reset(): void
  setGravity(y: number): void
  setBound(minY: number, halfX: number, halfZ: number): void
  addBox(hx: number, hy: number, hz: number, kind: number): number
  addSphere(r: number, kind: number): number
  addCylinder(r: number, halfHeight: number, kind: number): number
  remove(i: number): void
  setPose(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number): void
  setMaterial(i: number, mass: number, restitution: number, friction: number): void
  setVelocity(i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number): void
  /** A dynamic body asleep where it is, as if it had come to rest there: it stays put until something awake touches it. */
  sleep(i: number): void
  moveKinematic(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number, dt: number): void
  /** Milliseconds the step took. */
  step(dt: number, substeps: number): number
  /**
   * Whether the engine can run a step while the caller goes on (stepBegin, then stepEnd a frame later). The native one
   * can: the step runs on its own thread while the frame is drawn, and anything else the caller asks of the engine
   * waits for it first.
   */
  overlaps(): boolean
  /** Starts a step of dt seconds in substeps; an engine that does not overlap steps runs it here. */
  stepBegin(dt: number, substeps: number): void
  /** Waits for the step begun last and returns the milliseconds it took. */
  stepEnd(): number
  /** Records of 8 floats [index, px, py, pz, qx, qy, qz, qw] for the bodies that moved in the last step; returns how many. */
  readAwake(out: Float32Array): number
  /** px, py, pz, qx, qy, qz, qw of one body; 1, or 0 when there is no such body. */
  readPose(i: number, out: Float32Array): number
  /** Triples [a, b, approach speed] of contacts begun since the last drain; returns how many. */
  drainContacts(out: Float32Array): number
  awakeDynamic(): number
}

/** FNV-1a, 32 bits: the seed of everything the world does that could otherwise be random. */
export function fnv32(s: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h = h ^ s.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return h >>> 0
}

/** The unit axis a kicked body tumbles about: from the hash of its id and the trigger, so a throw is the same every run. */
export function kickAxis(id: string, trigger: number): number[] {
  let h = fnv32(id + '#' + trigger.toString())
  let a = [((h & 0x3ff) / 1023) * 2 - 1, (((h >>> 10) & 0x3ff) / 1023) * 2 - 1, (((h >>> 20) & 0x3ff) / 1023) * 2 - 1]
  let d = Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
  if (d < 1e-6) { return [1, 0, 0] }
  return [a[0] / d, a[1] / d, a[2] / d]
}

/**
 * A die is thrown fair whatever the program wrote: its kick tumbles DIE_MIN_TURNS to DIE_MIN_TURNS + DIE_EXTRA_TURNS turns
 * a second about a level axis of any direction, and its velocity across is turned by up to DIE_TURN_DEG either way and
 * scaled by up to DIE_SPEED_JITTER, its lift by up to DIE_LIFT_JITTER. A die is also created lying on a face drawn at random
 * (dieStartTurn), so the first throw does not start from the face every start shows.
 *
 * Why: the throw was the program's alone (2 turns a second about an axis seeded by id and trigger), so every start threw
 * the same dice the same way from face 2 up: the white die showed 2, 4, 4, 1, 2 on the phone, exactly the host's replay, and
 * the first throw from face 2 up showed 2 in a third of starts. Against Jolt (tools/phys-world-test.cpp, TestDiceFair, which
 * mirrors dieThrow and dieStartTurn), an axis from every direction kept the face on top in 28% of throws (a spin about the
 * upright does not turn a die over); a level one in 18.5% (a fair die: 17%).
 */
export const DIE_MIN_TURNS: number = 4
export const DIE_EXTRA_TURNS: number = 2
export const DIE_TURN_DEG: number = 20
export const DIE_SPEED_JITTER: number = 0.25
export const DIE_LIFT_JITTER: number = 0.15

/** Uniform numbers in [0, 1), as Math.random gives them. */
export type RandomSource = () => number

/** A small seeded generator (mulberry32): the same seed, the same numbers, on every machine. */
export function seededRandom(seed: number): RandomSource {
  let a = seed >>> 0
  return (): number => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * The velocity [vx, vy, vz, wx, wy, wz] a die is thrown with, for the kick the program wrote (vx, vy, vz in m/s, spin in
 * turns a second) and five numbers from `u` (see DIE_MIN_TURNS). Pure apart from `u`.
 */
export function dieThrow(vx: number, vy: number, vz: number, spin: number, u: RandomSource): number[] {
  let turns = Math.max(Math.abs(spin), DIE_MIN_TURNS) + DIE_EXTRA_TURNS * u()
  let phi = 2 * Math.PI * u()
  let w = turns * 2 * Math.PI
  let turn = (2 * u() - 1) * DIE_TURN_DEG * Math.PI / 180
  let scale = 1 + (2 * u() - 1) * DIE_SPEED_JITTER
  let lift = 1 + (2 * u() - 1) * DIE_LIFT_JITTER
  let c = Math.cos(turn)
  let s = Math.sin(turn)
  return [(vx * c - vz * s) * scale, vy * lift, (vx * s + vz * c) * scale, Math.cos(phi) * w, 0, Math.sin(phi) * w]
}

const HALF_SQRT2: number = Math.SQRT1_2
/** The turns that put each of a die's local axes up: +y, -y, +x, -x, +z, -z (quaternions x, y, z, w). */
const DIE_FACE_UP: number[][] = [[0, 0, 0, 1], [1, 0, 0, 0], [0, 0, HALF_SQRT2, HALF_SQRT2], [0, 0, -HALF_SQRT2, HALF_SQRT2],
  [-HALF_SQRT2, 0, 0, HALF_SQRT2], [HALF_SQRT2, 0, 0, HALF_SQRT2]]

/**
 * One of the 24 turns that map a cube onto itself, drawn from two numbers of `u`: a face up, then a quarter turn about the
 * upright. Applied before the die's own turn it leaves where the die is and what it touches as they were.
 */
export function dieStartTurn(u: RandomSource): number[] {
  let face = DIE_FACE_UP[Math.min(5, Math.floor(u() * 6))]
  let k = Math.min(3, Math.floor(u() * 4))
  let half = k * Math.PI / 4
  return mulQ([0, Math.sin(half), 0, Math.cos(half)], face)
}

// ---------------------------------------------------------------- FakePhys: the host's stand-in

const FAKE_LINEAR_DAMPING: number = 0.05
const FAKE_ANGULAR_DAMPING: number = 0.3
/** Each sub-step a body touches something, its spin keeps this much. */
const FAKE_CONTACT_SPIN: number = 0.92
/** Slower than this (m/s) into a surface, a body stops instead of bouncing. */
const FAKE_BOUNCE_MIN: number = 0.3
const FAKE_WAKE_SPEED: number = 0.5
const FAKE_SLEEP_SPEED: number = 0.05
const FAKE_SLEEP_SPIN: number = 0.5
const FAKE_SLEEP_AFTER_S: number = 0.5
/** As the native library: every dynamic body sleeps this long after the last setVelocity. */
const FAKE_SLEEP_CAP_S: number = 8

class FakeBody {
  alive: boolean = true
  kind: number = 0
  sphere: boolean = false
  half: number[] = [0, 0, 0]
  p: number[] = [0, 0, 0]
  q: number[] = [0, 0, 0, 1]
  v: number[] = [0, 0, 0]
  w: number[] = [0, 0, 0]
  home: number[] = [0, 0, 0, 0, 0, 0, 1]
  mass: number = 1
  restitution: number = 0.3
  friction: number = 0.5
  awake: boolean = false
  still: number = 0
  seed: number = 0
  /** Extents along the world axes, for this sub-step. */
  e: number[] = [0, 0, 0]
}

function normQ(q: number[]): void {
  let d = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
  if (d < 1e-12) { q[0] = 0; q[1] = 0; q[2] = 0; q[3] = 1; return }
  q[0] /= d; q[1] /= d; q[2] /= d; q[3] /= d
}

/** a * b, quaternions [x, y, z, w]. */
function mulQ(a: number[], b: number[]): number[] {
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ]
}

/** Row k, column j: the world k component of the body's local axis j. */
function rotation(q: number[]): number[] {
  let x = q[0]
  let y = q[1]
  let z = q[2]
  let w = q[3]
  return [
    1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
    2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
    2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
  ]
}

/**
 * A deterministic stand-in for the native physics, for host checks: semi-implicit Euler under gravity; every body is
 * its box turned into world axes (a sphere its radius), and contacts are resolved along the axis of least overlap with
 * restitution and friction; static and kinematic bodies do not move (a kinematic one moves only where moveKinematic puts
 * it); a body that stays slower than 0.05 m/s for 0.5 s sleeps, and a sleeping box is snapped to lie flat on its
 * nearest face (the tie broken by its seed). The world bound, the 8 s sleep cap, the awake records and the begun
 * contacts behave as the native library documents them.
 */
export class FakePhys implements PhysEngine {
  private bodies: FakeBody[] = []
  private free: number[] = []
  private gravity: number = -9.81
  private minY: number = -50
  private halfX: number = 100
  private halfZ: number = 100
  private reported: number[] = []
  private lastActive: number[] = []
  private touching: Set<string> = new Set<string>()
  private contacts: number[] = []
  private sinceVelocity: number = 0
  private serial: number = 0
  /** Simulated seconds so far, for checks. */
  simSeconds: number = 0

  init(maxBodies: number, threads: number): number { return 1 }

  reset(): void {
    this.bodies = []
    this.free = []
    this.reported = []
    this.lastActive = []
    this.touching = new Set<string>()
    this.contacts = []
    this.sinceVelocity = 0
  }

  setGravity(y: number): void { this.gravity = y }

  setBound(minY: number, halfX: number, halfZ: number): void {
    this.minY = minY
    this.halfX = halfX
    this.halfZ = halfZ
  }

  private add(kind: number, hx: number, hy: number, hz: number, sphere: boolean): number {
    let b = new FakeBody()
    b.kind = Math.max(0, Math.min(2, kind))
    b.half = [hx, hy, hz]
    b.sphere = sphere
    b.awake = b.kind === PHYS_DYNAMIC
    let i = this.free.length > 0 ? (this.free.pop() as number) : this.bodies.length
    this.serial++
    b.seed = fnv32('fake' + i.toString() + ':' + this.serial.toString())
    if (i === this.bodies.length) { this.bodies.push(b) } else { this.bodies[i] = b }
    return i
  }

  addBox(hx: number, hy: number, hz: number, kind: number): number { return this.add(kind, hx, hy, hz, false) }
  addSphere(r: number, kind: number): number { return this.add(kind, r, r, r, true) }
  addCylinder(r: number, halfHeight: number, kind: number): number { return this.add(kind, r, halfHeight, r, false) }

  private valid(i: number): boolean {
    return i >= 0 && i < this.bodies.length && this.bodies[i].alive
  }

  remove(i: number): void {
    if (!this.valid(i)) { return }
    this.bodies[i].alive = false
    this.free.push(i)
  }

  setPose(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number): void {
    if (!this.valid(i)) { return }
    let b = this.bodies[i]
    b.p = [px, py, pz]
    b.q = [qx, qy, qz, qw]
    normQ(b.q)
    b.home = [px, py, pz, b.q[0], b.q[1], b.q[2], b.q[3]]
    if (b.kind === PHYS_DYNAMIC) { this.wake(b) }
  }

  setMaterial(i: number, mass: number, restitution: number, friction: number): void {
    if (!this.valid(i)) { return }
    let b = this.bodies[i]
    if (b.kind === PHYS_DYNAMIC && mass > 0) { b.mass = mass }
    b.restitution = restitution
    b.friction = friction
  }

  setVelocity(i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number): void {
    if (!this.valid(i)) { return }
    let b = this.bodies[i]
    b.v = [vx, vy, vz]
    b.w = [wx, wy, wz]
    if (b.kind === PHYS_DYNAMIC) { this.wake(b) }
    this.sinceVelocity = 0
  }

  sleep(i: number): void {
    if (!this.valid(i) || this.bodies[i].kind !== PHYS_DYNAMIC) { return }
    let b = this.bodies[i]
    b.awake = false
    b.still = 0
    b.v = [0, 0, 0]
    b.w = [0, 0, 0]
  }

  moveKinematic(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number, dt: number): void {
    if (!this.valid(i) || this.bodies[i].kind !== PHYS_KINEMATIC) { return }
    let b = this.bodies[i]
    let t = Math.max(dt, 1e-4)
    b.v = [(px - b.p[0]) / t, (py - b.p[1]) / t, (pz - b.p[2]) / t]
    b.p = [px, py, pz]
    b.q = [qx, qy, qz, qw]
    normQ(b.q)
  }

  private wake(b: FakeBody): void {
    b.awake = true
    b.still = 0
  }

  private extents(b: FakeBody): void {
    if (b.sphere) {
      b.e = [b.half[0], b.half[0], b.half[0]]
      return
    }
    let r = rotation(b.q)
    for (let k = 0; k < 3; k++) {
      b.e[k] = Math.abs(r[k * 3]) * b.half[0] + Math.abs(r[k * 3 + 1]) * b.half[1] + Math.abs(r[k * 3 + 2]) * b.half[2]
    }
  }

  private touch(a: number, b: number, speed: number, now: Map<string, number[]>): void {
    let lo = Math.min(a, b)
    let hi = Math.max(a, b)
    let key = lo.toString() + ':' + hi.toString()
    let known = now.get(key)
    if (known === undefined) { now.set(key, [lo, hi, speed]) } else if (speed > known[2]) { known[2] = speed }
  }

  /** Overlap of a and b along each axis (positive on all three means they touch), and the axis of least overlap. */
  private overlap(a: FakeBody, b: FakeBody, pen: number[]): number {
    let best = -1
    for (let k = 0; k < 3; k++) {
      pen[k] = a.e[k] + b.e[k] - Math.abs(a.p[k] - b.p[k])
      if (pen[k] <= 0) { return -1 }
      if (best < 0 || pen[k] < pen[best]) { best = k }
    }
    return best
  }

  /** Body b (moving, or asleep and treated as fixed) and o, which does not give way unless both move (ib > 0). */
  private resolve(ia: number, a: FakeBody, ib: number, b: FakeBody, ma: number, mb: number, h: number,
      now: Map<string, number[]>, pen: number[]): void {
    let k = this.overlap(a, b, pen)
    if (k < 0) { return }
    let s = b.p[k] - a.p[k] >= 0 ? 1 : -1
    // Approach speed along the axis: positive when they close.
    let rel = (a.v[k] - b.v[k]) * s
    // A knock harder than resting under gravity (g / 60 a step) wakes a sleeping body, which then takes its share of it.
    if (rel > FAKE_WAKE_SPEED) {
      if (a.kind === PHYS_DYNAMIC && !a.awake) {
        this.wake(a)
        ma = 1 / a.mass
      }
      if (b.kind === PHYS_DYNAMIC && !b.awake) {
        this.wake(b)
        mb = 1 / b.mass
      }
    }
    let total = ma + mb
    if (total <= 0) { return }
    a.p[k] -= s * pen[k] * ma / total
    b.p[k] += s * pen[k] * mb / total
    this.touch(ia, ib, Math.max(0, rel), now)
    if (rel <= 0) { return }
    let e = Math.max(a.restitution, b.restitution)
    let bounce = rel > FAKE_BOUNCE_MIN ? e : 0
    let j = (1 + bounce) * rel / total
    a.v[k] -= s * j * ma
    b.v[k] += s * j * mb
    // Friction against the sliding, and gravity's share of grip while they rest on each other.
    let mu = Math.sqrt(a.friction * b.friction)
    let t1 = (k + 1) % 3
    let t2 = (k + 2) % 3
    let r1 = a.v[t1] - b.v[t1]
    let r2 = a.v[t2] - b.v[t2]
    let slide = Math.sqrt(r1 * r1 + r2 * r2)
    if (slide > 1e-9) {
      let drop = mu * ((1 + bounce) * rel + Math.abs(this.gravity) * h)
      let f = Math.min(1, drop / slide)
      a.v[t1] -= r1 * f * ma / total
      a.v[t2] -= r2 * f * ma / total
      b.v[t1] += r1 * f * mb / total
      b.v[t2] += r2 * f * mb / total
    }
    for (let n = 0; n < 3; n++) {
      if (ma > 0) { a.w[n] *= FAKE_CONTACT_SPIN }
      if (mb > 0) { b.w[n] *= FAKE_CONTACT_SPIN }
    }
  }

  private integrate(b: FakeBody, h: number): void {
    b.v[1] += this.gravity * h
    let lin = Math.max(0, 1 - FAKE_LINEAR_DAMPING * h)
    let ang = Math.max(0, 1 - FAKE_ANGULAR_DAMPING * h)
    for (let k = 0; k < 3; k++) {
      b.v[k] *= lin
      b.w[k] *= ang
      b.p[k] += b.v[k] * h
    }
    let dq = mulQ([b.w[0], b.w[1], b.w[2], 0], b.q)
    for (let k = 0; k < 4; k++) { b.q[k] += 0.5 * h * dq[k] }
    normQ(b.q)
  }

  /** The body lies flat on whichever face is nearest to down, lowered by what it no longer stands on. */
  private snap(b: FakeBody): void {
    if (b.sphere) { return }
    this.extents(b)
    let before = b.e[1]
    let r = rotation(b.q)
    let up = [r[3], r[4], r[5]]
    let best = 0
    for (let j = 1; j < 3; j++) {
      let d = Math.abs(up[j]) - Math.abs(up[best])
      // A tie (an edge or a corner straight up) goes the way the body's seed says.
      if (d > 1e-9 || (Math.abs(d) <= 1e-9 && ((b.seed >>> j) & 1) === 1)) { best = j }
    }
    let axis = [r[best], r[3 + best], r[6 + best]]
    let target = [0, up[best] >= 0 ? 1 : -1, 0]
    let c = [axis[1] * target[2] - axis[2] * target[1], axis[2] * target[0] - axis[0] * target[2], axis[0] * target[1] - axis[1] * target[0]]
    let turn = [c[0], c[1], c[2], 1 + axis[0] * target[0] + axis[1] * target[1] + axis[2] * target[2]]
    normQ(turn)
    b.q = mulQ(turn, b.q)
    normQ(b.q)
    this.extents(b)
    b.p[1] -= before - b.e[1]
  }

  private fallAsleep(b: FakeBody): void {
    b.awake = false
    b.still = 0
    b.v = [0, 0, 0]
    b.w = [0, 0, 0]
    this.snap(b)
  }

  private stepTook: number = 0
  overlaps(): boolean { return false }
  stepBegin(dt: number, substeps: number): void { this.stepTook = this.step(dt, substeps) }
  stepEnd(): number {
    let ms = this.stepTook
    this.stepTook = 0
    return ms
  }

  step(dt: number, substeps: number): number {
    if (dt <= 0) { return 0 }
    let n = Math.max(1, Math.floor(substeps))
    let h = dt / n
    let now = new Map<string, number[]>()
    let pen: number[] = [0, 0, 0]
    let fixed: number[] = []
    let moving: number[] = []
    for (let i = 0; i < this.bodies.length; i++) {
      let b = this.bodies[i]
      if (!b.alive) { continue }
      if (b.kind === PHYS_DYNAMIC) { moving.push(i) } else { fixed.push(i) }
    }
    for (let s = 0; s < n; s++) {
      for (let i of moving) {
        let b = this.bodies[i]
        if (b.awake) { this.integrate(b, h) }
      }
      for (let i of fixed) { this.extents(this.bodies[i]) }
      for (let i of moving) { this.extents(this.bodies[i]) }
      // Moving bodies against each other: sweep along x, so a wall of cubes is not every pair with every pair.
      let order = moving.slice()
      order.sort((a: number, b: number): number => {
        let d = (this.bodies[a].p[0] - this.bodies[a].e[0]) - (this.bodies[b].p[0] - this.bodies[b].e[0])
        return d !== 0 ? d : a - b
      })
      for (let x = 0; x < order.length; x++) {
        let a = this.bodies[order[x]]
        let reach = a.p[0] + a.e[0]
        for (let y = x + 1; y < order.length; y++) {
          let b = this.bodies[order[y]]
          if (b.p[0] - b.e[0] > reach) { break }
          if (!a.awake && !b.awake) { continue }
          // A sleeping body holds still under an awake one (infinite mass) unless the knock wakes it.
          this.resolve(order[x], a, order[y], b, a.awake ? 1 / a.mass : 0, b.awake ? 1 / b.mass : 0, h, now, pen)
        }
      }
      for (let i of moving) {
        let b = this.bodies[i]
        if (!b.awake) { continue }
        for (let j of fixed) { this.resolve(i, b, j, this.bodies[j], 1 / b.mass, 0, h, now, pen) }
      }
    }
    this.sinceVelocity += dt
    this.simSeconds += dt
    let reset: number[] = []
    for (let i of moving) {
      let b = this.bodies[i]
      let p = b.p
      if (p[1] < this.minY || Math.abs(p[0]) > this.halfX || Math.abs(p[2]) > this.halfZ || !isFinite(p[0] + p[1] + p[2])) {
        b.p = [b.home[0], b.home[1], b.home[2]]
        b.q = [b.home[3], b.home[4], b.home[5], b.home[6]]
        b.v = [0, 0, 0]
        b.w = [0, 0, 0]
        this.wake(b)
        reset.push(i)
        continue
      }
      if (!b.awake) { continue }
      let speed = Math.sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1] + b.v[2] * b.v[2])
      let spin = Math.sqrt(b.w[0] * b.w[0] + b.w[1] * b.w[1] + b.w[2] * b.w[2])
      b.still = speed < FAKE_SLEEP_SPEED && spin < FAKE_SLEEP_SPIN ? b.still + dt : 0
      if (b.still >= FAKE_SLEEP_AFTER_S || this.sinceVelocity > FAKE_SLEEP_CAP_S) { this.fallAsleep(b) }
    }
    let active: number[] = []
    for (let i of moving) { if (this.bodies[i].awake) { active.push(i) } }
    let seen = new Set<number>()
    this.reported = []
    for (let list of [active, this.lastActive, reset]) {
      for (let i of list) {
        if (!seen.has(i) && this.valid(i)) {
          seen.add(i)
          this.reported.push(i)
        }
      }
    }
    this.lastActive = active
    let keys = Array.from(now.keys()).sort()
    for (let key of keys) {
      if (!this.touching.has(key)) {
        let c = now.get(key) as number[]
        this.contacts.push(c[0], c[1], c[2])
      }
    }
    this.touching = new Set<string>(keys)
    if (this.contacts.length > 3 * 1024) { this.contacts = this.contacts.slice(0, 3 * 1024) }
    return 0
  }

  private pose(i: number, out: Float32Array, at: number): void {
    let b = this.bodies[i]
    out[at] = b.p[0]; out[at + 1] = b.p[1]; out[at + 2] = b.p[2]
    out[at + 3] = b.q[0]; out[at + 4] = b.q[1]; out[at + 5] = b.q[2]; out[at + 6] = b.q[3]
  }

  readAwake(out: Float32Array): number {
    let cap = Math.floor(out.length / 8)
    let n = 0
    for (let i of this.reported) {
      if (n >= cap) { break }
      if (!this.valid(i)) { continue }
      out[n * 8] = i
      this.pose(i, out, n * 8 + 1)
      n++
    }
    return n
  }

  readPose(i: number, out: Float32Array): number {
    if (!this.valid(i) || out.length < 7) { return 0 }
    this.pose(i, out, 0)
    return 1
  }

  drainContacts(out: Float32Array): number {
    let n = Math.min(Math.floor(out.length / 3), this.contacts.length / 3)
    for (let k = 0; k < n * 3; k++) { out[k] = this.contacts[k] }
    this.contacts = []
    return n
  }

  awakeDynamic(): number {
    let n = 0
    for (let b of this.bodies) { if (b.alive && b.kind === PHYS_DYNAMIC && b.awake) { n++ } }
    return n
  }
}

// ---------------------------------------------------------------- WorldSim: the world's logic over an engine

/** Physics steps in fixed sixtieths of a second, at most this many per frame, from at most this much real time. */
export const SIM_STEP_S: number = 1 / 60
export const SIM_MAX_SUBSTEPS: number = 4
export const SIM_MAX_ELAPSED_MS: number = 100
/**
 * A knock counts when the bodies close faster than HIT_MIN_SPEED (m/s). The program hears them as one `hit` at most every
 * HIT_INTERVAL_S: every knock since the last one gathered into it (bodies, values), so a wall of a hundred cubes coming
 * down is four calls of its handler a second, not four a frame -- each is a VM call, a build and a render, and four a
 * frame took the phone from 60 to 44 frames a second (phone, phase 3).
 */
export const HIT_MIN_SPEED: number = 1
export const HIT_INTERVAL_S: number = 0.25
/** Physics walls round a table stand this much of the table's longer side above the walls drawn, so a throw stays on it. */
export const TABLE_GLASS_RATIO: number = 0.5
/**
 * After a kick, `settled` waits until the engine has reported the kicked world awake after a step and then all asleep. A
 * kick the engine never reports awake (one of no speed) is told settled after this many steps anyway, so every throw
 * settles exactly once.
 */
export const SETTLE_WAKE_STEPS: number = 30
/** A loose body built at most this far (m) above the ground, or above a resting body under its centre, starts asleep. */
export const REST_GAP: number = 0.01
/** Room for the awake records the engine writes each frame. */
const SIM_POSE_CAPACITY: number = 2048
/**
 * Contact triples one drain can take: the native buffer's own cap (kContactCap in phys_world.h), so a wall knocked down
 * loses none (a 100-cube wall begins about 350 in one step). The native side writes no more than this array holds
 * (FloatCapacity); what a full drain leaves is dropped there.
 */
const SIM_CONTACT_CAPACITY: number = 1024

/** One thing the world tells the program; VeraPreview turns it into a scene.Event (sceneEventValue). */
export class SimEvent {
  kind: string = ''
  body: string = ''
  other: string = ''
  x: number = 0
  y: number = 0
  z: number = 0
  speed: number = 0
  /**
   * For `hit`: body, other and speed are the hardest knock; bodies every body knocked since the last hit, hardest first
   * (ground and walls are not bodies), and values the speed of each one's hardest knock. For `settled`: the loose bodies
   * and the face each die shows.
   */
  bodies: string[] = []
  values: number[] = []
  /** For `settled`: which throw it ends (WorldSim.kickSerial when it was kicked) and the simulated ms since that kick. */
  kick: number = 0
  afterMs: number = 0
}

/** [minX, minY, minZ, maxX, maxY, maxZ] of a body where its spec puts it, turned as its spec turns it. */
export function specBounds(b: BodySpec): number[] {
  let half = b.shape === 'sphere' ? [b.dims[0] / 2, b.dims[0] / 2, b.dims[0] / 2]
    : b.shape === 'cylinder' ? [b.dims[0] / 2, b.dims[1] / 2, b.dims[0] / 2] : [b.dims[0] / 2, b.dims[1] / 2, b.dims[2] / 2]
  let e = [half[0], half[1], half[2]]
  if (b.shape !== 'sphere') {
    let r = rotation(quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2]))
    for (let k = 0; k < 3; k++) {
      e[k] = Math.abs(r[k * 3]) * half[0] + Math.abs(r[k * 3 + 1]) * half[1] + Math.abs(r[k * 3 + 2]) * half[2]
    }
  }
  let p = b.position
  return [p[0] - e[0], p[1] - e[1], p[2] - e[2], p[0] + e[0], p[1] + e[1], p[2] + e[2]]
}

/**
 * Which of the loose bodies just created (and not thrown) were built resting: standing on the floor, the table or a
 * fixed body, or on bodies that themselves rest, within REST_GAP, with their centre over what holds them up. Those
 * start asleep, so a wall or a stack the program built stands still until something hits it instead of settling -- and,
 * for a tall one, toppling -- on its own. A body built in the air, inside something, or thrown, starts awake.
 */
export function restingAtStart(spec: WorldSpec, created: BodySpec[], kicked: Set<string>): string[] {
  let holders: number[][] = []
  let table = spec.table
  if (table !== null) {
    for (let part of tableParts(table as TableSpec)) {
      holders.push([part[0] - part[3] / 2, part[1] - part[4] / 2, part[2] - part[5] / 2, part[0] + part[3] / 2, part[1] + part[4] / 2,
        part[2] + part[5] / 2])
    }
  }
  for (let b of spec.bodies) {
    if (b.motion === 'static') { holders.push(specBounds(b)) }
  }
  let floorTop = spec.floor !== null ? (table !== null ? -TABLE_TOP_THICKNESS : 0) : NaN
  let candidates: BodySpec[] = created.filter((b: BodySpec): boolean => b.motion === 'loose' && !kicked.has(b.id))
  let bounds = new Map<string, number[]>()
  for (let b of candidates) { bounds.set(b.id, specBounds(b)) }
  // Bottom up, so a body can rest on one that was found resting just before it.
  candidates.sort((a: BodySpec, b: BodySpec): number => (bounds.get(a.id) as number[])[1] - (bounds.get(b.id) as number[])[1])
  let resting: string[] = []
  for (let b of candidates) {
    let box = bounds.get(b.id) as number[]
    let bottom = box[1]
    if (!isNaN(floorTop) && Math.abs(bottom - floorTop) <= REST_GAP) {
      resting.push(b.id)
      holders.push(box)
      continue
    }
    // What is under it, its top within REST_GAP of its bottom; together they must reach under its centre.
    let lo = [Infinity, Infinity]
    let hi = [-Infinity, -Infinity]
    for (let h of holders) {
      if (Math.abs(h[4] - bottom) > REST_GAP) { continue }
      if (h[0] >= box[3] || h[3] <= box[0] || h[2] >= box[5] || h[5] <= box[2]) { continue }
      lo[0] = Math.min(lo[0], h[0]); lo[1] = Math.min(lo[1], h[2])
      hi[0] = Math.max(hi[0], h[3]); hi[1] = Math.max(hi[1], h[5])
    }
    let cx = b.position[0]
    let cz = b.position[2]
    if (cx >= lo[0] && cx <= hi[0] && cz >= lo[1] && cz <= hi[1]) {
      resting.push(b.id)
      holders.push(box)
    }
  }
  return resting
}

function kindOf(b: BodySpec): number {
  if (b.motion === 'loose') { return PHYS_DYNAMIC }
  if (b.motion === 'kinematic') { return PHYS_KINEMATIC }
  return PHYS_STATIC
}

/** How far a body must have moved, as a share of its smallest side, to count as knocked from where it was built. */
const KNOCKED_MOVE: number = 0.5
/** How far it must have turned, in degrees, to count as tipped over. */
const KNOCKED_TURN_DEG: number = 25

/**
 * Whether a loose body at rest (pose [x, y, z, qx, qy, qz, qw]) no longer stands as it was built: moved more than half
 * its smallest side from where it started, or turned more than KNOCKED_TURN_DEG. What "settled" tells for a body that is
 * not a die, so a game of knocking things over can count what fell.
 */
export function knockedOver(b: BodySpec, pose: Float32Array): boolean {
  let dx = pose[0] - b.position[0]
  let dy = pose[1] - b.position[1]
  let dz = pose[2] - b.position[2]
  let side = Math.max(0.001, Math.min(b.dims[0], b.dims[1], b.dims[2]))
  if (Math.sqrt(dx * dx + dy * dy + dz * dz) > side * KNOCKED_MOVE) { return true }
  let q = quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2])
  let dot = Math.abs(q[0] * pose[3] + q[1] * pose[4] + q[2] * pose[5] + q[3] * pose[6])
  return 2 * Math.acos(Math.min(1, dot)) * 180 / Math.PI > KNOCKED_TURN_DEG
}

/**
 * A world's physics: which body is which engine index, what a WorldDiff does to the engine, the fixed-step clock,
 * kinematic bodies along their orbits, and the events -- `hit` from the engine's contacts, `settled` once every loose
 * body is at rest after a throw (exactly one per throw, read from poses after its kick; a throw before the last one has
 * settled supersedes it). Loose bodies built resting start asleep (restingAtStart). It owns the engine's contents (call
 * reset before handing the engine to another world).
 *
 * The ground: a table is its top and four walls as static boxes (the walls taller than drawn, see TABLE_GLASS_RATIO), and
 * the bound just outside it; a floor is a wide static slab and a wide bound; with neither, the world floats in space:
 * no gravity, and a generous bound. A loose body outside the bound goes back where it was created (the engine does it).
 */
export class WorldSim {
  readonly engine: PhysEngine
  /**
   * Where a die's throw draws its numbers from (dieThrow): null on the host, where each throw is seeded by the die's id and
   * its trigger, so a check plays the same every run; Math.random on the phone, so no two throws are alike.
   */
  readonly random: RandomSource | null
  /** The awake records of the last step and how many there are: [index, px, py, pz, qx, qy, qz, qw] each. */
  readonly poses: Float32Array = new Float32Array(SIM_POSE_CAPACITY * 8)
  poseCount: number = 0
  /** Loose bodies awake after the last step, and the ms the engine spent on it. */
  awake: number = 0
  stepMs: number = 0
  /** The most contacts one drain gave since WorldBox last read and cleared it (VeraPreview's VERA-WORLD line says it). */
  mostContacts: number = 0
  /** Simulated seconds. */
  simTime: number = 0

  private index: Map<string, number> = new Map<string, number>()
  /** Engine index -> body id; '' for the ground and for free indices. */
  private names: string[] = []
  private ground: number[] = []
  private spec: WorldSpec | null = null
  private loose: string[] = []
  private kinematic: string[] = []
  /** Throws so far (applies that kicked something); the last one's bodies and how many were awake right after it. */
  kickSerial: number = 0
  lastKickBodies: number = 0
  lastKickAwake: number = 0
  /** Loose bodies the last apply started asleep because they were built resting (restingAtStart). */
  restingCount: number = 0

  /** A step begun and not yet finished (an engine that overlaps steps), and its substeps. */
  private stepping: boolean = false
  private steppingSteps: number = 0
  private settlePending: boolean = false
  /** Since the kick: whether a step has seen the kicked world awake, steps taken, and simTime at the kick. */
  private woke: boolean = false
  private stepsSinceKick: number = 0
  private kickAt: number = 0
  private carry: number = 0
  /** Knocks gathered for the next hit: each body's hardest, the hardest pair, and simTime of the last hit told. */
  private hitSpeeds: Map<string, number> = new Map<string, number>()
  private hitBest: SimEvent | null = null
  private lastHitAt: number = -1e9
  private contacts: Float32Array = new Float32Array(SIM_CONTACT_CAPACITY * 3)
  private one: Float32Array = new Float32Array(7)
  private events: SimEvent[] = []

  constructor(engine: PhysEngine, random: RandomSource | null = null) {
    this.engine = engine
    this.random = random
  }

  /** The body id of an engine index, or '' (the ground, or nothing). */
  idAt(i: number): string {
    return i >= 0 && i < this.names.length ? this.names[i] : ''
  }

  /** Where the engine has the body now, [px, py, pz, qx, qy, qz, qw]; null for one it does not have. */
  poseOf(id: string): number[] | null {
    let i = this.index.get(id)
    if (i === undefined || this.engine.readPose(i, this.one) === 0) { return null }
    let o = this.one
    return [o[0], o[1], o[2], o[3], o[4], o[5], o[6]]
  }

  /** Whether frames are needed: loose bodies awake, or a throw whose settling has not been told yet. */
  needsFrames(): boolean {
    return this.loose.length > 0 && (this.awake > 0 || this.settlePending || this.hitBest !== null)
  }

  hasLoose(): boolean {
    return this.loose.length > 0
  }

  /** Everything the world told since the last call, oldest first. */
  takeEvents(): SimEvent[] {
    let out = this.events
    this.events = []
    return out
  }

  /** Empty the engine and forget every body. */
  reset(): void {
    if (this.stepping) { this.engine.stepEnd() }
    this.stepping = false
    this.steppingSteps = 0
    this.engine.reset()
    this.index.clear()
    this.names = []
    this.ground = []
    this.spec = null
    this.loose = []
    this.kinematic = []
    this.settlePending = false
    this.woke = false
    this.stepsSinceKick = 0
    this.carry = 0
    this.hitSpeeds.clear()
    this.hitBest = null
    this.lastHitAt = -1e9
    this.events = []
    this.awake = 0
    this.poseCount = 0
  }

  /** Bring the engine from the world it had to next, by the diff between them (diffWorld). */
  apply(diff: WorldDiff, next: WorldSpec): void {
    let first = this.spec === null
    if (first || diff.tableChanged || diff.floorChanged) { this.buildGround(next) }
    for (let id of diff.remove) { this.removeBody(id) }
    let created: BodySpec[] = []
    for (let b of diff.recreate) {
      this.removeBody(b.id)
      this.createBody(b)
      created.push(b)
    }
    for (let b of diff.create) {
      this.createBody(b)
      created.push(b)
    }
    for (let b of diff.material) {
      let i = this.index.get(b.id)
      if (i !== undefined) { this.engine.setMaterial(i, b.mass, b.restitution, b.friction) }
    }
    for (let b of diff.setPose) {
      let i = this.index.get(b.id)
      if (i !== undefined) { this.placeBody(i, b) }
    }
    let kicked = new Set<string>()
    for (let b of diff.kick) {
      let i = this.index.get(b.id)
      if (i === undefined || b.kick === null || b.motion !== 'loose') { continue }
      let k = b.kick as SceneKick
      if (b.isDie) {
        let v = dieThrow(k.vx, k.vy, k.vz, k.spin, this.draw(b.id + '#' + k.trigger.toString()))
        this.engine.setVelocity(i, v[0], v[1], v[2], v[3], v[4], v[5])
      } else {
        let axis = kickAxis(b.id, k.trigger)
        let w = k.spin * 2 * Math.PI
        this.engine.setVelocity(i, k.vx, k.vy, k.vz, axis[0] * w, axis[1] * w, axis[2] * w)
      }
      kicked.add(b.id)
    }
    let resting = restingAtStart(next, created, kicked)
    for (let id of resting) {
      let i = this.index.get(id)
      if (i !== undefined) { this.engine.sleep(i) }
    }
    this.restingCount = resting.length
    if (kicked.size > 0) {
      // A new throw: whatever the last one had not yet told is superseded, and this one settles once, after its bodies
      // have been seen awake (see step).
      this.kickSerial++
      this.lastKickBodies = kicked.size
      this.settlePending = true
      this.woke = false
      this.stepsSinceKick = 0
      this.kickAt = this.simTime
    }
    this.spec = next
    this.loose = []
    this.kinematic = []
    for (let b of next.bodies) {
      if (!this.index.has(b.id)) { continue }
      if (b.motion === 'loose') { this.loose.push(b.id) } else if (b.motion === 'kinematic') { this.kinematic.push(b.id) }
    }
    if (this.loose.length === 0) { this.settlePending = false }
    this.awake = this.engine.awakeDynamic()
    if (kicked.size > 0) { this.lastKickAwake = this.awake }
  }

  /**
   * One display frame, elapsedMs after the last, with orbits at timeS (the box's clock): whole sixtieths of a second are
   * stepped (at most four; a longer gap is dropped, not caught up), kinematic bodies are moved along their orbits, the
   * awake poses land in `poses`, and hits and settling become events.
   */
  step(elapsedMs: number, timeS: number): void {
    this.poseCount = 0
    this.stepMs = 0
    // An engine that overlaps steps ran the last one while the frame was drawn: its poses, hits and settling are this
    // frame's. The world shows one step behind the clock, a sixtieth of a second, and the UI thread spends none of it.
    if (this.stepping) { this.finishStep() }
    if (this.spec === null || this.loose.length === 0) { return }
    this.carry += Math.min(SIM_MAX_ELAPSED_MS, Math.max(0, elapsedMs)) / 1000
    let n = Math.floor(this.carry / SIM_STEP_S + 1e-9)
    if (n <= 0) { return }
    if (n > SIM_MAX_SUBSTEPS) {
      n = SIM_MAX_SUBSTEPS
      this.carry = 0
    } else {
      this.carry = Math.max(0, this.carry - n * SIM_STEP_S)
    }
    let dt = n * SIM_STEP_S
    if (this.kinematic.length > 0) {
      let at = orbitPositions(this.spec as WorldSpec, timeS)
      for (let id of this.kinematic) {
        let i = this.index.get(id)
        let p = at.get(id)
        if (i === undefined || p === undefined) { continue }
        let q = quatXYZ(p[3], p[4], p[5])
        this.engine.moveKinematic(i, p[0], p[1], p[2], q[0], q[1], q[2], q[3], dt)
      }
    }
    this.engine.stepBegin(dt, n)
    this.simTime += dt
    this.stepping = true
    this.steppingSteps = n
    if (!this.engine.overlaps()) { this.finishStep() }
  }

  /** What the step begun last did: the awake poses, the knocks, and whether a throw has settled. */
  private finishStep(): void {
    let n = this.steppingSteps
    this.stepping = false
    this.steppingSteps = 0
    this.stepMs = this.engine.stepEnd()
    this.poseCount = Math.max(0, this.engine.readAwake(this.poses))
    this.collectHits()
    this.awake = this.engine.awakeDynamic()
    if (this.settlePending) {
      // Settled is told from poses after the kick: only once a step has had the thrown world awake and a later one has
      // it all asleep (or the kick never woke anything), never from the poses the bodies had before it.
      this.stepsSinceKick += n
      if (this.awake > 0) {
        this.woke = true
      } else if (this.woke || this.stepsSinceKick >= SETTLE_WAKE_STEPS) {
        this.settlePending = false
        this.events.push(this.settled())
      }
    }
  }

  private settled(): SimEvent {
    let e = new SimEvent()
    e.kind = 'settled'
    e.kick = this.kickSerial
    e.afterMs = Math.round((this.simTime - this.kickAt) * 1000)
    let spec = this.spec as WorldSpec
    for (let b of spec.bodies) {
      if (b.motion !== 'loose') { continue }
      let i = this.index.get(b.id)
      if (i === undefined) { continue }
      let value = 0
      if (this.engine.readPose(i, this.one) === 1) {
        value = b.isDie ? topFace(this.one[3], this.one[4], this.one[5], this.one[6]) : (knockedOver(b, this.one) ? 1 : 0)
      }
      e.bodies.push(b.id)
      e.values.push(value)
    }
    return e
  }

  /**
   * The knocks the engine began this frame, gathered (each body's hardest, and the hardest pair); once HIT_INTERVAL_S has
   * passed since the last hit, what was gathered becomes one hit event.
   */
  private collectHits(): void {
    let n = this.engine.drainContacts(this.contacts)
    if (n > this.mostContacts) { this.mostContacts = n }
    for (let k = 0; k < n; k++) {
      let speed = this.contacts[k * 3 + 2]
      if (!(speed > HIT_MIN_SPEED)) { continue }
      let a = this.idAt(Math.round(this.contacts[k * 3]))
      let b = this.idAt(Math.round(this.contacts[k * 3 + 1]))
      if (a.length === 0) {
        a = b
        b = ''
      }
      if (a.length === 0) { continue }
      this.gather(a, speed)
      if (b.length > 0) { this.gather(b, speed) }
      let best = this.hitBest
      if (best === null || speed > best.speed) {
        let e = new SimEvent()
        e.kind = 'hit'
        e.body = a
        e.other = b
        e.speed = speed
        let i = this.index.get(a)
        if (i !== undefined && this.engine.readPose(i, this.one) === 1) {
          e.x = this.one[0]
          e.y = this.one[1]
          e.z = this.one[2]
        }
        this.hitBest = e
      }
    }
    if (this.hitBest === null || this.simTime - this.lastHitAt < HIT_INTERVAL_S - 1e-9) { return }
    let e = this.hitBest as SimEvent
    let ids: string[] = []
    this.hitSpeeds.forEach((v: number, id: string) => { if (this.index.has(id)) { ids.push(id) } })
    let speeds = this.hitSpeeds
    ids.sort((x: string, y: string): number => {
      let d = (speeds.get(y) as number) - (speeds.get(x) as number)
      return d !== 0 ? d : (x < y ? -1 : x > y ? 1 : 0)
    })
    e.bodies = ids
    e.values = ids.map((id: string): number => speeds.get(id) as number)
    this.hitSpeeds = new Map<string, number>()
    this.hitBest = null
    this.lastHitAt = this.simTime
    if (ids.length > 0) { this.events.push(e) }
  }

  private gather(id: string, speed: number): void {
    let known = this.hitSpeeds.get(id)
    if (known === undefined || speed > known) { this.hitSpeeds.set(id, speed) }
  }

  private setName(i: number, id: string): void {
    while (this.names.length <= i) { this.names.push('') }
    this.names[i] = id
  }

  private buildGround(spec: WorldSpec): void {
    for (let i of this.ground) {
      this.engine.remove(i)
      this.setName(i, '')
    }
    this.ground = []
    let table = spec.table
    if (table !== null) {
      let t = table as TableSpec
      let parts = tableParts(t)
      let glass = Math.max(t.width, t.depth) * TABLE_GLASS_RATIO
      for (let k = 0; k < parts.length; k++) {
        let p = parts[k]
        let h = p[4]
        let cy = p[1]
        if (k > 0) {
          h = p[4] + glass
          cy = h / 2
        }
        this.addGround(p[0], cy, p[2], p[3] / 2, h / 2, p[5] / 2)
      }
    }
    if (spec.floor !== null) {
      let top = table !== null ? -TABLE_TOP_THICKNESS : 0
      this.addGround(0, top - 0.5, 0, 100, 0.5, 100)
      this.engine.setGravity(-9.81)
      this.engine.setBound(top - 5, 99, 99)
    } else if (table !== null) {
      let t = table as TableSpec
      let wall = tableParts(t)[4][3]
      this.engine.setGravity(-9.81)
      this.engine.setBound(-1, t.width / 2 + wall + 0.05, t.depth / 2 + wall + 0.05)
    } else {
      this.engine.setGravity(0)
      this.engine.setBound(-50, 50, 50)
    }
  }

  private addGround(x: number, y: number, z: number, hx: number, hy: number, hz: number): void {
    let i = this.engine.addBox(hx, hy, hz, PHYS_STATIC)
    if (i < 0) { return }
    this.engine.setPose(i, x, y, z, 0, 0, 0, 1)
    this.engine.setMaterial(i, 0, 0.3, 0.6)
    this.setName(i, '')
    this.ground.push(i)
  }

  private createBody(b: BodySpec): void {
    let kind = kindOf(b)
    let i = -1
    if (b.shape === 'sphere') {
      i = this.engine.addSphere(b.dims[0] / 2, kind)
    } else if (b.shape === 'cylinder') {
      i = this.engine.addCylinder(b.dims[0] / 2, b.dims[1] / 2, kind)
    } else {
      i = this.engine.addBox(b.dims[0] / 2, b.dims[1] / 2, b.dims[2] / 2, kind)
    }
    if (i < 0) { return }
    this.index.set(b.id, i)
    this.setName(i, b.id)
    // A new loose die lies on a face drawn at random (dieStartTurn); the renderer takes its pose from here.
    this.placeBody(i, b, b.isDie && b.motion === 'loose' ? dieStartTurn(this.draw(b.id + '#start')) : null)
    this.engine.setMaterial(i, b.mass, b.restitution, b.friction)
  }

  private placeBody(i: number, b: BodySpec, turn: number[] | null = null): void {
    let q = quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2])
    if (turn !== null) { q = mulQ(q, turn as number[]) }
    this.engine.setPose(i, b.position[0], b.position[1], b.position[2], q[0], q[1], q[2], q[3])
  }

  /** Where a die's numbers come from: the random source, else a generator seeded by `seed`. */
  private draw(seed: string): RandomSource {
    return this.random !== null ? this.random as RandomSource : seededRandom(fnv32(seed))
  }

  private removeBody(id: string): void {
    let i = this.index.get(id)
    if (i === undefined) { return }
    this.engine.remove(i)
    this.index.delete(id)
    this.setName(i, '')
  }
}
