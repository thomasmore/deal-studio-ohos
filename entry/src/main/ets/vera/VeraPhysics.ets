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

import { WorldSpec, BodySpec, WorldDiff, SceneKick, TableSpec, ScenePlayer, SceneFrom, SceneShot, orbitPositions,
  topFace, particleRequest, samePhysicalBody, sameCollisionShape } from './VeraScene'
import { PlayerDrive, ZoneEnter, yawOf, PLAYER_STOP } from './VeraLocomotion'
import { pointBounds, partBounds, PartRecords, PART_RECORD, addPartRecords, turnPoint } from './VeraShapes'
import { tableParts, quatXYZ, TABLE_TOP_THICKNESS } from './VeraLook3D'
import { ParticleBurst, MAX_BURSTS, DUST_MIN_SPEED } from './VeraParticles'

/** Body kinds, as the native library numbers them. */
export const PHYS_STATIC: number = 0
export const PHYS_DYNAMIC: number = 1
export const PHYS_KINEMATIC: number = 2
/** A dynamic body kept upright, turning only about y, without friction or bounce, moved by drive (the player). */
export const PHYS_CHARACTER: number = 3
/**
 * A shot (scene.shoot): a dynamic body with continuous collision, without gravity until it first touches something and
 * with it from then on; and one that falls all the way (arc). Both are watched from the start. One that leaves the bound
 * stops where it is (asleep, reported once among the awake records) instead of going back where it was made; awakeDynamic
 * does not count them, so no throw waits on a shot.
 */
export const PHYS_PROJECTILE: number = 4
export const PHYS_PROJECTILE_ARC: number = 5
/** Floats in one contact record of drainContacts: [a, b, approach speed, px, py, pz]. */
export const CONTACT_RECORD: number = 6
/** Contact records one drain holds at most (kContactCap), the last CONTACT_WATCH_RESERVE of them kept for watched bodies. */
export const CONTACT_CAP: number = 1024
export const CONTACT_WATCH_RESERVE: number = 64

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
  /** A body of convex parts, records of PART_RECORD floats and the hulls' points (VeraShapes.PartRecords); -1 if refused. */
  addParts(records: Float32Array, points: Float32Array, kind: number): number
  remove(i: number): void
  setPose(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number): void
  setMaterial(i: number, mass: number, restitution: number, friction: number): void
  setVelocity(i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number): void
  /** A dynamic body asleep where it is, as if it had come to rest there: it stays put until something awake touches it. */
  sleep(i: number): void
  moveKinematic(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number, dt: number): void
  /** A character's velocity along the ground and turn about y (rad/s); its vertical velocity is its own. */
  drive(i: number, vx: number, vz: number, wy: number): void
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
  /**
   * vx, vy, vz of one body (m/s), and wx, wy, wz (rad/s) after them when out holds 6 or more; 1, or 0 when there is no such
   * body (or out holds fewer than 3).
   */
  readVelocity(i: number, out: Float32Array): number
  /**
   * Records of CONTACT_RECORD floats [a, b, approach speed, px, py, pz] of contacts begun since the last drain (a and b
   * engine indices -- the ground's too -- in either order; p a point of the contact); returns how many. Ordinary contacts
   * stop at CONTACT_CAP - CONTACT_WATCH_RESERVE records; one with a watched body may use the whole CONTACT_CAP.
   */
  drainContacts(out: Float32Array): number
  /** Dynamic bodies awake, characters and projectiles not counted. */
  awakeDynamic(): number
  /** Whether the body's contacts go into the watched reserve (on 1, off 0). Projectiles are watched from the start. */
  watch(i: number, on: number): void
  /**
   * Every dynamic body (characters and projectiles too) whose centre is within radius of cx, cy, cz is given
   * strength * (1 - d / radius) m/s more velocity straight away from it, and woken; returns how many.
   */
  explode(cx: number, cy: number, cz: number, radius: number, strength: number): number
}

/**
 * A pose [px, py, pz, qx, qy, qz, qw] stood upright: the same place, turned only about y, to the heading its +x had.
 * A body on its side (its +x straight up) keeps its place and faces +x.
 */
export function uprightPose(at: number[]): number[] {
  let x = at[3]
  let y = at[4]
  let z = at[5]
  let w = at[6]
  let fx = 1 - 2 * (y * y + z * z)
  let fz = 2 * (x * z - y * w)
  // A turn of a about y takes +x to (cos a, 0, -sin a).
  let a = Math.hypot(fx, fz) > 1e-6 ? Math.atan2(-fz, fx) : 0
  return [at[0], at[1], at[2], 0, Math.sin(a / 2), 0, Math.cos(a / 2)]
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
/**
 * As the native library: a dynamic body awake this long in a row while touching something is put to sleep. Each body
 * has its own time, started again whenever it sleeps or is woken, placed, kicked or sent back by the bound; free flight
 * does not count.
 */
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
  /** Seconds awake in a row while touching something, for the sleep cap. */
  awakeFor: number = 0
  seed: number = 0
  /** Made as PHYS_CHARACTER: upright, turning about y only, no friction or bounce. */
  character: boolean = false
  /** Made as PHYS_PROJECTILE(_ARC): its share of gravity (0 until it first touches something), watched, stopped at the bound. */
  projectile: boolean = false
  gravityFactor: number = 1
  watched: boolean = false
  /** A projectile stopped outside the bound: not stopped or reported again until it is placed or given a velocity. */
  frozen: boolean = false
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
  /** Records left out of the contact buffer because it was full (for checks). */
  droppedContacts: number = 0
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
  }

  setGravity(y: number): void { this.gravity = y }

  setBound(minY: number, halfX: number, halfZ: number): void {
    this.minY = minY
    this.halfX = halfX
    this.halfZ = halfZ
  }

  private add(kind: number, hx: number, hy: number, hz: number, sphere: boolean): number {
    let b = new FakeBody()
    b.kind = Math.max(0, Math.min(PHYS_PROJECTILE_ARC, kind))
    if (b.kind === PHYS_PROJECTILE || b.kind === PHYS_PROJECTILE_ARC) {
      b.projectile = true
      b.gravityFactor = b.kind === PHYS_PROJECTILE_ARC ? 1 : 0
      b.watched = true
      b.kind = PHYS_DYNAMIC
    }
    if (b.kind === PHYS_CHARACTER) {
      b.kind = PHYS_DYNAMIC
      b.character = true
      b.friction = 0
      b.restitution = 0
    }
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
  /** Stood in for by the box round its parts, about its origin: the shape itself is the native engine's (tools/phys-world-test.cpp). */
  addParts(records: Float32Array, points: Float32Array, kind: number): number {
    let n = Math.floor(records.length / PART_RECORD)
    if (n === 0) { return -1 }
    let reach = 0.0001
    let half: number[] = [reach, reach, reach]
    let used = 0
    for (let k = 0; k < n; k++) {
      let o = k * PART_RECORD
      let type = records[o]
      // How far the part reaches from its own centre, then from the body's origin, along each axis (a bound, not exact).
      let r = type === 0 ? Math.hypot(records[o + 8], records[o + 9], records[o + 10]) : type === 1 ? records[o + 8]
        : type === 2 ? Math.hypot(records[o + 8], records[o + 9]) : 0
      if (type === 3) {
        let m = records[o + 11]
        for (let j = 0; j < m; j++) {
          r = Math.max(r, Math.hypot(points[used + 3 * j], points[used + 3 * j + 1], points[used + 3 * j + 2]))
        }
        used += m * 3
      }
      for (let c = 0; c < 3; c++) { half[c] = Math.max(half[c], Math.abs(records[o + 1 + c]) + r) }
    }
    return this.add(kind, half[0], half[1], half[2], false)
  }

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
    b.frozen = false
    if (b.kind === PHYS_DYNAMIC) { this.wake(b) }
  }

  setMaterial(i: number, mass: number, restitution: number, friction: number): void {
    if (!this.valid(i)) { return }
    let b = this.bodies[i]
    if (b.kind === PHYS_DYNAMIC && mass > 0) { b.mass = mass }
    b.restitution = b.character ? 0 : restitution
    b.friction = b.character ? 0 : friction
  }

  setVelocity(i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number): void {
    if (!this.valid(i)) { return }
    let b = this.bodies[i]
    b.v = [vx, vy, vz]
    b.w = b.character ? [0, wy, 0] : [wx, wy, wz]
    b.frozen = false
    if (b.kind === PHYS_DYNAMIC) { this.wake(b) }
  }

  drive(i: number, vx: number, vz: number, wy: number): void {
    if (!this.valid(i) || !this.bodies[i].character) { return }
    let b = this.bodies[i]
    b.v = [vx, b.v[1], vz]
    b.w = [0, wy, 0]
    if (vx !== 0 || vz !== 0 || wy !== 0) { this.wake(b) }
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
    b.awakeFor = 0
    // A shot stopped at the bound and knocked moves again, and is stopped again if it is still outside (as the native
    // engine stops one whenever it is active out there).
    b.frozen = false
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

  private touch(a: number, b: number, speed: number, now: Map<string, number[]>, at: number[]): void {
    let lo = Math.min(a, b)
    let hi = Math.max(a, b)
    let key = lo.toString() + ':' + hi.toString()
    let known = now.get(key)
    if (known === undefined) {
      now.set(key, [lo, hi, speed, at[0], at[1], at[2]])
    } else if (speed > known[2]) {
      known[2] = speed
      known[3] = at[0]; known[4] = at[1]; known[5] = at[2]
    }
    // A projectile falls once it has touched something.
    for (let i of [a, b]) {
      let body = this.bodies[i]
      if (body.projectile) { body.gravityFactor = 1 }
    }
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
    // Where they touch: the middle of the box both overlap in, before they are pushed apart.
    let at: number[] = [0, 0, 0]
    for (let c = 0; c < 3; c++) {
      at[c] = (Math.max(a.p[c] - a.e[c], b.p[c] - b.e[c]) + Math.min(a.p[c] + a.e[c], b.p[c] + b.e[c])) / 2
    }
    a.p[k] -= s * pen[k] * ma / total
    b.p[k] += s * pen[k] * mb / total
    this.touch(ia, ib, Math.max(0, rel), now, at)
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
      if (ma > 0 && !a.character) { a.w[n] *= FAKE_CONTACT_SPIN }
      if (mb > 0 && !b.character) { b.w[n] *= FAKE_CONTACT_SPIN }
    }
  }

  private integrate(b: FakeBody, h: number): void {
    if (b.character) {
      b.w[0] = 0
      b.w[2] = 0
    }
    b.v[1] += this.gravity * b.gravityFactor * h
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
    b.awakeFor = 0
    b.v = [0, 0, 0]
    b.w = [0, 0, 0]
    if (!b.character) { this.snap(b) }
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
      // A projectile moves at most half its smallest half-extent a micro-step, so it cannot pass through a thin wall
      // between two (the native engine casts it instead).
      let m = 1
      for (let i of moving) {
        let b = this.bodies[i]
        if (!b.awake || !b.projectile) { continue }
        let reach = Math.max(1e-4, Math.min(b.half[0], b.half[1], b.half[2]) / 2)
        m = Math.max(m, Math.ceil(Math.hypot(b.v[0], b.v[1], b.v[2]) * h / reach))
      }
      m = Math.min(m, 256)
      for (let micro = 0; micro < m; micro++) { this.subStep(h / m, moving, fixed, now, pen) }
    }
    this.finishStep(dt, moving, now)
    return 0
  }

  private subStep(h: number, moving: number[], fixed: number[], now: Map<string, number[]>, pen: number[]): void {
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

  private finishStep(dt: number, moving: number[], now: Map<string, number[]>): void {
    this.simSeconds += dt
    let touched = new Set<number>()
    now.forEach((c: number[]) => {
      touched.add(c[0])
      touched.add(c[1])
    })
    let reset: number[] = []
    for (let i of moving) {
      let b = this.bodies[i]
      let p = b.p
      if (b.frozen) { continue }
      let out = p[1] < this.minY || Math.abs(p[0]) > this.halfX || Math.abs(p[2]) > this.halfZ
      if (b.projectile && out && isFinite(p[0] + p[1] + p[2])) {
        // A shot that left the world stops where it is, told once, and is never sent back.
        b.v = [0, 0, 0]
        b.w = [0, 0, 0]
        b.awake = false
        b.still = 0
        b.awakeFor = 0
        b.frozen = true
        reset.push(i)
        continue
      }
      if (out || !isFinite(p[0] + p[1] + p[2])) {
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
      if (touched.has(i)) { b.awakeFor += dt }
      if (b.still >= FAKE_SLEEP_AFTER_S || b.awakeFor > FAKE_SLEEP_CAP_S) { this.fallAsleep(b) }
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
        let records = this.contacts.length / CONTACT_RECORD
        let watched = this.bodies[c[0]].watched || this.bodies[c[1]].watched
        if (records >= CONTACT_CAP || (!watched && records >= CONTACT_CAP - CONTACT_WATCH_RESERVE)) {
          this.droppedContacts++
          continue
        }
        this.contacts.push(c[0], c[1], c[2], c[3], c[4], c[5])
      }
    }
    this.touching = new Set<string>(keys)
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

  readVelocity(i: number, out: Float32Array): number {
    if (!this.valid(i) || out.length < 3) { return 0 }
    let v = this.bodies[i].v
    out[0] = v[0]; out[1] = v[1]; out[2] = v[2]
    if (out.length >= 6) {
      let w = this.bodies[i].w
      out[3] = w[0]; out[4] = w[1]; out[5] = w[2]
    }
    return 1
  }

  drainContacts(out: Float32Array): number {
    let n = Math.min(Math.floor(out.length / CONTACT_RECORD), this.contacts.length / CONTACT_RECORD)
    for (let k = 0; k < n * CONTACT_RECORD; k++) { out[k] = this.contacts[k] }
    this.contacts = []
    return n
  }

  awakeDynamic(): number {
    let n = 0
    for (let b of this.bodies) { if (b.alive && b.kind === PHYS_DYNAMIC && b.awake && !b.character && !b.projectile) { n++ } }
    return n
  }

  watch(i: number, on: number): void {
    if (this.valid(i)) { this.bodies[i].watched = on !== 0 }
  }

  explode(cx: number, cy: number, cz: number, radius: number, strength: number): number {
    if (!(radius > 0)) { return 0 }
    let n = 0
    for (let b of this.bodies) {
      if (!b.alive || b.kind !== PHYS_DYNAMIC) { continue }
      let dx = b.p[0] - cx
      let dy = b.p[1] - cy
      let dz = b.p[2] - cz
      let d = Math.sqrt(dx * dx + dy * dy + dz * dz)
      if (d >= radius) { continue }
      let dir = d > 1e-9 ? [dx / d, dy / d, dz / d] : [0, 1, 0]
      let dv = strength * (1 - d / radius)
      for (let k = 0; k < 3; k++) { b.v[k] += dir[k] * dv }
      b.frozen = false
      this.wake(b)
      n++
    }
    return n
  }
}

// ---------------------------------------------------------------- WorldSim: the world's logic over an engine

/** What WorldSim.apply does with the bodies diffWorld makes again (planRecreate). */
class RecreatePlan {
  /** Made again only for how they look: the engine keeps their bodies. */
  inPlace: BodySpec[] = []
  /** Made again in the engine too. */
  rebuilt: BodySpec[] = []
  /** Of those, loose ones that go on from their live state [pose, velocity]. */
  kept: Map<string, number[]> = new Map<string, number[]>()
  /** Of the kept, those that collide as another shape now: never put to sleep where the old shape rested. */
  reshaped: Set<string> = new Set<string>()
}

/** The kicks of one apply (giveKicks): the bodies kicked, and the throws to wait on, blasts' pushes added later. */
class ThrowResult {
  kicked: Set<string> = new Set<string>()
  thrown: number = 0
}

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
/**
 * `struck`: a knock on a watched body (scene.target, or a shot) closing faster than STRUCK_MIN_SPEED m/s. One pair is told
 * at most once every STRUCK_PAIR_COOLDOWN_S, a finished step tells at most one struck (every knock since the last one
 * gathered into it), and at most STRUCK_RATE a second: a knock that would go over waits and is told with the next.
 */
export const STRUCK_MIN_SPEED: number = 1.5
export const STRUCK_PAIR_COOLDOWN_S: number = 0.3
export const STRUCK_RATE: number = 10
/** A shot slower than this (m/s) is no longer flying: frames are not kept going for it. */
export const SHOT_FLYING_SPEED: number = 0.05
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
const SIM_CONTACT_CAPACITY: number = CONTACT_CAP

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
  /** dx, dy, dz: a tap's ray, the player's heading for `action`; 0 for what the physics tells. */
  dx: number = 0
  dy: number = 0
  dz: number = 0
  /** For `settled`: which throw it ends (WorldSim.kickSerial when it was kicked) and the simulated ms since that kick. */
  kick: number = 0
  afterMs: number = 0
}

/** The `enter` event of a body that came into a zone: the one both the phone (WorldBox) and the host play check send. */
export function enterEvent(z: ZoneEnter): SimEvent {
  let e = new SimEvent()
  e.kind = 'enter'
  e.body = z.body
  e.other = z.zone
  e.x = z.x
  e.y = z.y
  e.z = z.z
  return e
}

/** [minX, minY, minZ, maxX, maxY, maxZ] of a body where its spec puts it, turned as its spec turns it. */
export function specBounds(b: BodySpec): number[] {
  if (b.model.length > 0 && b.shape === 'hull') {
    return partBounds(b.shape, b.dims, b.points, b.position, b.rotation)
  }
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
 *
 * standing holds loose bodies from earlier applies that still stand where they were built, as [x, y, z] where they are
 * now: a block added on top of a tower built in an earlier state rests on it as on one built with it.
 */
export function restingAtStart(spec: WorldSpec, created: BodySpec[], kicked: Set<string>,
  standing: Map<string, number[]> | null = null): string[] {
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
    let at = standing !== null && b.motion === 'loose' && !kicked.has(b.id) && b.aim.length !== 3 ? standing.get(b.id) : undefined
    if (at !== undefined) {
      let e = specBounds(b)
      let d = [at[0] - b.position[0], at[1] - b.position[1], at[2] - b.position[2]]
      holders.push([e[0] + d[0], e[1] + d[1], e[2] + d[2], e[3] + d[0], e[4] + d[1], e[5] + d[2]])
    }
  }
  let floorTop = spec.floor !== null ? (table !== null ? -TABLE_TOP_THICKNESS : 0) : NaN
  // A piece (scene.from) or a shot is made moving where something else was: never put to sleep at the start. Nor is an
  // aimed body, turned from the rotation its bounds here are worked out from: it settles by itself.
  let candidates: BodySpec[] = created.filter((b: BodySpec): boolean => b.motion === 'loose' && !kicked.has(b.id) &&
    b.from === null && b.shot === null && b.aim.length !== 3)
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

/** What the physics is given for a shape, a hull or a group: its convex parts, each where it sits in the body. */
export function bodyRecords(b: BodySpec): PartRecords {
  let out = new PartRecords()
  if (b.shape !== 'group') {
    addPartRecords(out, b.shape, b.dims, b.points, 0, 0, 0, [0, 0, 0, 1])
    return out
  }
  for (let p of b.parts) {
    addPartRecords(out, p.shape, p.dims, p.points, p.position[0], p.position[1], p.position[2],
      quatXYZ(p.rotation[0], p.rotation[1], p.rotation[2]))
  }
  return out
}

function kindOf(b: BodySpec): number {
  if (b.shot !== null && b.motion === 'loose') { return (b.shot as SceneShot).arc ? PHYS_PROJECTILE_ARC : PHYS_PROJECTILE }
  if (b.motion === 'loose') { return b.player !== null ? PHYS_CHARACTER : PHYS_DYNAMIC }
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
export function knockedOver(b: BodySpec, pose: Float32Array, origin: number[] | null = null): boolean {
  // A body made from another (scene.from) was built where WorldSim put it (its origin), not at its spec's position.
  let o: number[] = origin !== null ? origin : b.position
  let dx = pose[0] - o[0]
  let dy = pose[1] - o[1]
  let dz = pose[2] - o[2]
  let side = Math.max(0.001, Math.min(b.dims[0], b.dims[1], b.dims[2]))
  if (Math.sqrt(dx * dx + dy * dy + dz * dz) > side * KNOCKED_MOVE) { return true }
  let q = origin !== null ? [origin[3], origin[4], origin[5], origin[6]] : quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2])
  let dot = Math.abs(q[0] * pose[3] + q[1] * pose[4] + q[2] * pose[5] + q[3] * pose[6])
  return 2 * Math.acos(Math.min(1, dot)) * 180 / Math.PI > KNOCKED_TURN_DEG
}

/** The turn that points +x along (dx, dy, dz) and keeps it level sideways: a heading about y, then a pitch up. */
export function lookQuat(dx: number, dy: number, dz: number): number[] {
  let flat = Math.hypot(dx, dz)
  if (flat < 1e-9 && Math.abs(dy) < 1e-9) { return [0, 0, 0, 1] }
  let yaw = Math.atan2(-dz, dx)
  let pitch = Math.atan2(dy, flat)
  return mulQ([0, Math.sin(yaw / 2), 0, Math.cos(yaw / 2)], [0, 0, Math.sin(pitch / 2), Math.cos(pitch / 2)])
}

/** How far past the shooter's side a shot is moved when it was built inside it (m). */
export const SHOT_CLEARANCE_M: number = 0.03

/**
 * A shot's position in its shooter's frame, moved ahead along +x when it would start inside the shooter: a shot placed low
 * enough to hit things on the ground easily ends up inside a tall shooter's body. shooterDims are the shooter's sizes
 * (x, y, z) about its centre, shotDims the shot's; aimed, the frame turns toward the point, so the shooter's widest
 * horizontal reach is what to clear. Unchanged when the two do not overlap. Pure.
 */
export function clearOfShooter(local: number[], shotDims: number[], shooterDims: number[], aimed: boolean): number[] {
  let half = Math.max(shotDims[0], shotDims[1], shotDims[2]) / 2
  let hx = shooterDims[0] / 2
  let hy = shooterDims[1] / 2
  let hz = shooterDims[2] / 2
  let reach = aimed ? Math.hypot(hx, hz) : hx
  let inside = Math.abs(local[1]) < hy + half && Math.abs(local[0]) < reach + half && (aimed || Math.abs(local[2]) < hz + half)
  if (!inside) { return local }
  return [reach + half + SHOT_CLEARANCE_M, local[1], aimed ? 0 : local[2]]
}

/**
 * Where a body made from another (scene.from), a shot (scene.shoot) or an aimed body (scene.aim) starts: [pose
 * [px, py, pz, qx, qy, qz, qw], velocity [vx, vy, vz], spin [wx, wy, wz]]. Pure.
 *
 * parent is the parent's live state [px, py, pz, qx, qy, qz, qw, vx, vy, vz, wx, wy, wz], or null for none (then local is
 * taken in the world, and nothing is inherited). local and rot (degrees about x, y, z) are the body's position and turn as
 * the program built them. The frame is the parent's (p, q); with an aim point [x, y, z] it is the parent's place turned
 * so its +x points at the aim, and the body itself is then turned to point its +x from where it is at the aim. pos =
 * p + frame . local, rotation = turn . rot; velocity v + w x r + burst * r / |r| (r = frame . local, the way out of the
 * parent's centre; straight up when it is at the centre), plus shotSpeed along the frame's +x (turn's: the parent's facing
 * or the aim; the body's own +x only when it has neither); spin w.
 */
export function resolveFrom(parent: number[] | null, local: number[], rot: number[], aim: number[], burst: number,
    shotSpeed: number): number[][] {
  let p = parent !== null ? [parent[0], parent[1], parent[2]] : [0, 0, 0]
  let q = parent !== null ? [parent[3], parent[4], parent[5], parent[6]] : [0, 0, 0, 1]
  normQ(q)
  let aimed = aim.length === 3
  let frame = q
  if (aimed && parent !== null) { frame = lookQuat(aim[0] - p[0], aim[1] - p[1], aim[2] - p[2]) }
  let r = turnPoint(frame, local[0], local[1], local[2])
  let pos = [p[0] + r[0], p[1] + r[1], p[2] + r[2]]
  let turn = aimed ? lookQuat(aim[0] - pos[0], aim[1] - pos[1], aim[2] - pos[2]) : q
  let qf = mulQ(turn, quatXYZ(rot[0], rot[1], rot[2]))
  normQ(qf)
  let v = [0, 0, 0]
  let w = [0, 0, 0]
  if (parent !== null) {
    w = [parent[10], parent[11], parent[12]]
    v = [parent[7] + w[1] * r[2] - w[2] * r[1], parent[8] + w[2] * r[0] - w[0] * r[2], parent[9] + w[0] * r[1] - w[1] * r[0]]
    if (burst !== 0) {
      let d = Math.hypot(r[0], r[1], r[2])
      let out = d > 1e-9 ? [r[0] / d, r[1] / d, r[2] / d] : [0, 1, 0]
      for (let k = 0; k < 3; k++) { v[k] += burst * out[k] }
    }
  }
  if (shotSpeed !== 0) {
    // A shot made from a body, or aimed, goes the way its frame faces (the shooter's +x, or at the point): its own turn is
    // only how it looks (a rod laid along the way it flies). Alone and unaimed, its own turn is the only way it has.
    let ahead = turnPoint(parent !== null || aimed ? turn : qf, 1, 0, 0)
    for (let k = 0; k < 3; k++) { v[k] += shotSpeed * ahead[k] }
  }
  return [[pos[0], pos[1], pos[2], qf[0], qf[1], qf[2], qf[3]], v, w]
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

  /** The world apply is putting in, while it does (bodySpec reads it for a shooter built in the same build). */
  private building: WorldSpec | null = null
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
  /** The poses in `poses` are from a step an apply finished early (see apply): the next frame writes them, not zero. */
  private held: boolean = false
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
  private contacts: Float32Array = new Float32Array(SIM_CONTACT_CAPACITY * CONTACT_RECORD)
  private one: Float32Array = new Float32Array(7)
  /** Ids of the bodies the last apply made with scene.from whose parent was nowhere: placed as if from nothing. */
  fromMissing: string[] = []
  /** Where each body made from another, shot or aimed was made, [px, py, pz, qx, qy, qz, qw]: what knockedOver compares with. */
  private origin: Map<string, number[]> = new Map<string, number[]>()
  /** scene.target bodies, shots, and both (whose knocks are struck). */
  private targets: Set<string> = new Set<string>()
  private shots: string[] = []
  private watched: Set<string> = new Set<string>()
  /** Shots still flying after the last step or apply. */
  shotsFlying: number = 0
  /** Knocks gathered for the next struck: each body's hardest and the hardest; when each pair was last taken; the bucket. */
  private struckSpeeds: Map<string, number> = new Map<string, number>()
  private struckBest: SimEvent | null = null
  private pairAt: Map<string, number> = new Map<string, number>()
  private struckTokens: number = 1
  private struckClock: number = 0
  private spin: Float32Array = new Float32Array(6)
  private events: SimEvent[] = []
  private pendingBursts: ParticleBurst[] = []
  private burstSerial: number = 0
  /** The player (scene.player), '' for none; the stick as the renderer last set it; its driving; whether it was driven last step. */
  private player: string = ''
  private playerSpeed: number = 0
  private stick: number[] = [0, 0, 0]
  private driver: PlayerDrive = new PlayerDrive()
  private driving: boolean = false
  /** The player's speed along the ground when it was last driven (m/s), and whether it was going up or down. */
  private playerGround: number = 0
  private playerFlying: boolean = false
  /** The player kicked by the apply going on, '' for none. */
  private playerKicked: string = ''

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

  /** Whether frames are needed: loose bodies awake, a throw whose settling has not been told yet, or the player going. */
  needsFrames(): boolean {
    return this.pendingBursts.length > 0 || (this.loose.length > 0 && (this.awake > 0 || this.settlePending ||
      this.hitBest !== null || this.playerGoing() || this.shotsFlying > 0 || this.struckBest !== null))
  }

  /** The player's id, '' for none. */
  playerId(): string {
    return this.player
  }

  /**
   * The stick: dx, dz a direction along the floor (the renderer turns the screen's push into it with floorDirection) and
   * push how far it is pushed, 0..1; 0 lets go.
   */
  setStick(dx: number, dz: number, push: number): void {
    this.stick = [dx, dz, Math.max(0, Math.min(1, push))]
  }

  /** Whether the player is being steered, or still coming to a stop. */
  playerGoing(): boolean {
    return this.player.length > 0 && (this.stick[2] > 0 || this.driver.moving() || this.driving || this.playerGround >= PLAYER_STOP ||
      this.playerFlying)
  }

  /** The player's speed along the ground now (m/s), as the physics last had it: about none held against a wall. */
  playerSpeedNow(): number {
    return this.playerGround
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

  takeBursts(): ParticleBurst[] {
    let out = this.pendingBursts
    this.pendingBursts = []
    return out
  }

  /** Empty the engine and forget every body. */
  reset(): void {
    if (this.stepping) { this.engine.stepEnd() }
    this.stepping = false
    this.steppingSteps = 0
    this.held = false
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
    this.pendingBursts = []
    this.burstSerial = 0
    this.fromMissing = []
    this.origin.clear()
    this.targets.clear()
    this.shots = []
    this.watched.clear()
    this.shotsFlying = 0
    this.struckSpeeds.clear()
    this.struckBest = null
    this.pairAt.clear()
    this.struckTokens = 1
    this.struckClock = this.simTime
    this.awake = 0
    this.poseCount = 0
    this.player = ''
    this.stick = [0, 0, 0]
    this.driver.reset()
    this.driving = false
    this.playerGround = 0
    this.playerFlying = false
  }

  /**
   * Bring the engine from the world it had to next, by the diff between them (diffWorld). The steps run in this order
   * because each reads what the one before left: live poses are read before anything is removed, bodies are made before
   * their poses, kicks and blasts are given, and resting bodies are put to sleep only after the throws are known.
   */
  apply(diff: WorldDiff, next: WorldSpec): void {
    this.building = next
    // A step still running belongs to the world before this apply: finish it now, while its engine indices still name
    // the bodies it moved (removing frees an index and creating takes it again) and before a kick restarts the count of
    // steps since the kick. Its poses are kept for the next frame, less those of the bodies this apply removes.
    if (this.stepping) {
      this.finishStep()
      this.held = true
    }
    let first = this.spec === null
    if (first || diff.tableChanged || diff.floorChanged) {
      this.buildGround(next)
      if (!first) { this.wakeResting() }
    }
    this.fromMissing = []
    let plan = this.planRecreate(diff)
    let parents = this.parentsNow(diff, plan)
    let created = this.replaceBodies(diff, plan, parents)
    this.restoreKept(plan, next)
    this.updateInPlace(diff, plan.inPlace)
    let throws = this.giveKicks(diff)
    let unrested = this.giveBlasts(diff, next, throws)
    this.startResting(next, created, unrested)
    if (throws.thrown > 0) { this.beginThrow(throws.thrown) }
    this.spec = next
    this.indexWorld(next)
    if (this.loose.length === 0) { this.settlePending = false }
    this.awake = this.engine.awakeDynamic()
    if (throws.thrown > 0) { this.lastKickAwake = this.awake }
    this.shotsFlying = this.countFlying()
  }

  /**
   * Which bodies diffWorld makes again are made again in the engine, and the live state the loose ones among them keep.
   *
   * Made again only for how it looks (a mark, a pattern, rings, a colour in a painted mesh): the renderer makes its node
   * again, the engine keeps its body as it is -- velocity, sleep and a shot's gravity once it has touched something (a
   * straight projectile made again would fly straight again). Only one the engine has, or it is made after all.
   *
   * A loose body made again (a new shape, the player only now) stays where the physics took it, not where it was built,
   * facing the way it faced and going as it went. The player is stood upright: a character turns only about y, so a tilt
   * kept now (a box that had tumbled onto its side) would be kept for good. Only a body that was loose before: one only
   * now let go (static or held until this state) has no live pose of its own to keep -- kept, it would be put to sleep
   * where it was built, hanging in the air, instead of falling from there.
   */
  private planRecreate(diff: WorldDiff): RecreatePlan {
    let before = new Map<string, BodySpec>()
    if (this.spec !== null) {
      for (let b of (this.spec as WorldSpec).bodies) { before.set(b.id, b) }
    }
    let plan = new RecreatePlan()
    for (let b of diff.recreate) {
      let old = before.get(b.id)
      if (old !== undefined && this.index.has(b.id) && samePhysicalBody(old, b)) {
        plan.inPlace.push(b)
        continue
      }
      plan.rebuilt.push(b)
      if (b.motion !== 'loose' || old === undefined || old.motion !== 'loose') { continue }
      let live = this.liveState(b.id)
      if (live === null) { continue }
      let pose = live.slice(0, 7)
      plan.kept.set(b.id, (b.player !== null ? uprightPose(pose) : pose).concat(live.slice(7)))
      if (!sameCollisionShape(old, b)) { plan.reshaped.add(b.id) }
    }
    return plan
  }

  /**
   * Bodies made from another (scene.from) start in their parent's frame as it is now: taken before anything is removed
   * or made again, so a body broken into pieces in this same apply gives them where it was, how it went and how it
   * turned. Pieces made again without a live state of their own (planRecreate) are placed from it the same way.
   */
  private parentsNow(diff: WorldDiff, plan: RecreatePlan): Map<string, number[]> {
    let parents = new Map<string, number[]>()
    for (let b of diff.create.concat(plan.rebuilt)) {
      if (b.from === null || plan.kept.has(b.id)) { continue }
      let id = (b.from as SceneFrom).parent
      if (parents.has(id)) { continue }
      let live = this.liveState(id)
      if (live !== null) { parents.set(id, live) }
    }
    return parents
  }

  /** Removes what goes and makes what comes; returns the bodies made new (not those keeping a live state). */
  private replaceBodies(diff: WorldDiff, plan: RecreatePlan, parents: Map<string, number[]>): BodySpec[] {
    let freed = new Set<number>()
    for (let id of diff.remove) { this.removeBody(id, freed) }
    for (let b of plan.rebuilt) { this.removeBody(b.id, freed) }
    // A body to create that the engine already has: an apply that stopped half-way (the renderer's 3D side failed after
    // this ran) is given again from the spec before it. Made again, not twice -- a second body under one id would stay
    // in the engine, colliding, with nothing to draw it or remove it.
    for (let b of diff.create) { this.removeBody(b.id, freed) }
    if (this.held && freed.size > 0) { this.dropPoses(freed) }
    let created: BodySpec[] = []
    for (let b of plan.rebuilt) {
      this.createBody(b, parents, plan.kept.has(b.id))
      if (!plan.kept.has(b.id)) { created.push(b) }
    }
    // Bodies made from others last, in build order, so a parent made in this apply is there for them.
    for (let b of diff.create) {
      if (b.from !== null) { continue }
      this.createBody(b, parents, false)
      created.push(b)
    }
    for (let b of diff.create) {
      if (b.from === null) { continue }
      this.createBody(b, parents, false)
      created.push(b)
    }
    return created
  }

  /**
   * Bodies made again with a live state kept (planRecreate) go on from it. One at rest sleeps there only if it has the
   * shape it rested with: a body made smaller would hang above what held it, a bigger one sunk into it.
   */
  private restoreKept(plan: RecreatePlan, next: WorldSpec): void {
    plan.kept.forEach((at: number[], id: string) => {
      let i = this.index.get(id)
      if (i === undefined) { return }
      this.engine.setPose(i, at[0], at[1], at[2], at[3], at[4], at[5], at[6])
      if (this.playerOf(next, id)) {
        // A character is woken where it stands, to settle on its feet; it keeps its velocity, never a tumble.
        this.engine.setVelocity(i, at[7], at[8], at[9], 0, 0, 0)
      } else if (!plan.reshaped.has(id) && Math.hypot(at[7], at[8], at[9]) < 1e-3 && Math.hypot(at[10], at[11], at[12]) < 1e-3) {
        this.engine.sleep(i)
      } else {
        this.engine.setVelocity(i, at[7], at[8], at[9], at[10], at[11], at[12])
      }
    })
  }

  /** New materials and watches, bodies kept in place (planRecreate), and new poses of bodies the program places. */
  private updateInPlace(diff: WorldDiff, inPlace: BodySpec[]): void {
    for (let b of diff.material.concat(inPlace)) {
      let i = this.index.get(b.id)
      if (i === undefined) { continue }
      this.engine.setMaterial(i, b.mass, b.restitution, b.friction)
      this.engine.watch(i, b.target || b.shot !== null ? 1 : 0)
    }
    // One kept in place that the program places (not loose) goes where this spec puts it, as setPose would.
    for (let b of inPlace) {
      let i = this.index.get(b.id)
      if (i !== undefined && b.motion !== 'loose') { this.placeBody(i, b) }
    }
    for (let b of diff.setPose) {
      let i = this.index.get(b.id)
      if (i !== undefined) { this.placeBody(i, b) }
    }
  }

  /** Kicks whose trigger changed: the bodies kicked, and how many of them are a throw to wait on (not the player). */
  private giveKicks(diff: WorldDiff): ThrowResult {
    let out = new ThrowResult()
    for (let b of diff.kick) {
      let i = this.index.get(b.id)
      if (i === undefined || b.kick === null || b.motion !== 'loose') { continue }
      let k = b.kick as SceneKick
      if (b.player !== null) {
        // The player's kick is a jump or a dash: no tumble, and not a throw to wait on (it walks on after it). Its
        // driving starts from that velocity and runs it out (drivePlayer), and frames run while it does.
        this.engine.setVelocity(i, k.vx, k.vy, k.vz, 0, 0, 0)
        out.kicked.add(b.id)
        this.playerKicked = b.id
        continue
      }
      out.thrown++
      if (b.isDie) {
        let v = dieThrow(k.vx, k.vy, k.vz, k.spin, this.draw(b.id + '#' + k.trigger.toString()))
        this.engine.setVelocity(i, v[0], v[1], v[2], v[3], v[4], v[5])
      } else {
        let axis = kickAxis(b.id, k.trigger)
        let w = k.spin * 2 * Math.PI
        this.engine.setVelocity(i, k.vx, k.vy, k.vz, axis[0] * w, axis[1] * w, axis[2] * w)
      }
      out.kicked.add(b.id)
    }
    return out
  }

  /**
   * The blasts of this apply go off; returns the bodies not to start resting: those kicked, and the loose ones a blast
   * pushes (put to sleep after it by restingAtStart, a body made in this same apply would lose the push). A blast is a
   * throw of the bodies settled waits on that it pushes -- not the player or a shot, which settled never tells, so a
   * blast that reaches only them begins no throw. The player pushed is driven from that push and runs it out, as after
   * a kick (drivePlayer). Within the radius as the engine reckons it (the centre of mass, here the pose), so the two
   * agree.
   */
  private giveBlasts(diff: WorldDiff, next: WorldSpec, throws: ThrowResult): Set<string> {
    let unrested = new Set<string>(throws.kicked)
    if (diff.blast.length === 0) { return unrested }
    for (let b of next.bodies) {
      if (b.motion !== 'loose') { continue }
      let live = this.liveState(b.id)
      if (live === null) { continue }
      let reached = 0
      for (let x of diff.blast) {
        if (Math.hypot(live[0] - x.x, live[1] - x.y, live[2] - x.z) < x.radius) { reached++ }
      }
      if (reached === 0) { continue }
      unrested.add(b.id)
      if (b.player !== null) {
        this.playerKicked = b.id
      } else if (b.shot === null) {
        throws.thrown += reached
      }
    }
    for (let x of diff.blast) { this.engine.explode(x.x, x.y, x.z, x.radius, x.strength) }
    return unrested
  }

  /** Bodies made standing as built start asleep (restingAtStart), but for those kicked or pushed now. */
  private startResting(next: WorldSpec, created: BodySpec[], unrested: Set<string>): void {
    let resting = created.length > 0 ? restingAtStart(next, created, unrested, this.standing(next, created)) : []
    for (let id of resting) {
      let i = this.index.get(id)
      if (i !== undefined) { this.engine.sleep(i) }
    }
    this.restingCount = resting.length
  }

  /**
   * A new throw: whatever the last one had not yet told is superseded, and this one settles once, after its bodies have
   * been seen awake (see step).
   */
  private beginThrow(thrown: number): void {
    this.events = this.events.filter((e: SimEvent): boolean => e.kind !== 'settled')
    this.kickSerial++
    this.lastKickBodies = thrown
    this.settlePending = true
    this.woke = false
    this.stepsSinceKick = 0
    this.kickAt = this.simTime
  }

  /** Which bodies are loose, kinematic, targets, shots and the player, as next has them. */
  private indexWorld(next: WorldSpec): void {
    this.loose = []
    this.kinematic = []
    let player = ''
    this.targets.clear()
    this.watched.clear()
    this.shots = []
    for (let b of next.bodies) {
      if (!this.index.has(b.id)) { continue }
      if (b.target) { this.targets.add(b.id); this.watched.add(b.id) }
      if (b.shot !== null && b.motion === 'loose') { this.shots.push(b.id); this.watched.add(b.id) }
      if (b.motion === 'loose') { this.loose.push(b.id) } else if (b.motion === 'kinematic') { this.kinematic.push(b.id) }
      if (b.player !== null && b.motion === 'loose') {
        player = b.id
        this.playerSpeed = (b.player as ScenePlayer).speed
      }
    }
    if (player !== this.player) {
      // A new player (or a new round's) starts standing.
      this.driver.reset()
      this.driving = false
      this.playerGround = 0
      this.playerFlying = false
    }
    this.player = player
    if (this.playerKicked.length > 0 && this.playerKicked === player) { this.driving = true }
    this.playerKicked = ''
  }

  /** Whether the body id is the player in spec. */
  private playerOf(spec: WorldSpec, id: string): boolean {
    for (let b of spec.bodies) { if (b.id === id) { return b.player !== null } }
    return false
  }

  /** A body's state now, [px, py, pz, qx, qy, qz, qw, vx, vy, vz, wx, wy, wz]; null for one the engine does not have. */
  private liveState(id: string): number[] | null {
    let i = this.index.get(id)
    if (i === undefined || this.engine.readPose(i, this.one) === 0) { return null }
    let o = this.one
    let out: number[] = [o[0], o[1], o[2], o[3], o[4], o[5], o[6]]
    let w = this.spin
    for (let k = 0; k < 6; k++) { w[k] = 0 }
    if (this.engine.readVelocity(i, w) !== 1) { for (let k = 0; k < 6; k++) { w[k] = 0 } }
    for (let k = 0; k < 6; k++) { out.push(w[k]) }
    return out
  }

  /** Shots going faster than SHOT_FLYING_SPEED. */
  private countFlying(): number {
    let n = 0
    for (let id of this.shots) {
      let i = this.index.get(id)
      if (i === undefined || this.engine.readVelocity(i, this.spin) !== 1) { continue }
      if (Math.hypot(this.spin[0], this.spin[1], this.spin[2]) > SHOT_FLYING_SPEED) { n++ }
    }
    return n
  }

  /**
   * One display frame, elapsedMs after the last, with orbits at timeS (the box's clock): whole sixtieths of a second are
   * stepped (at most four; a longer gap is dropped, not caught up), kinematic bodies are moved along their orbits, the
   * awake poses land in `poses`, and hits and settling become events.
   */
  step(elapsedMs: number, timeS: number): void {
    this.collect()
    this.advance(elapsedMs, timeS)
  }

  /**
   * The first half of a frame: what the step begun last did lands in `poses` and the events. An engine that overlaps
   * steps ran it while the frame was drawn, so the world shows one step behind the clock, a sixtieth of a second, and
   * the UI thread spends none of it. Between collect and advance no step runs: that is where the events go to the
   * program, so a handler that changes the world is applied without waiting on the step thread.
   */
  collect(): void {
    if (this.held) {
      this.held = false
    } else {
      this.poseCount = 0
      this.stepMs = 0
    }
    if (this.stepping) { this.finishStep() }
  }

  /** The second half of a frame: the kinematic bodies are moved and the next step begun (finished at once, or by collect). */
  advance(elapsedMs: number, timeS: number): void {
    if (this.stepping || this.spec === null || this.loose.length === 0) { return }
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
    this.drivePlayer(dt)
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

  /**
   * The player, steered by the stick for the step about to run: its velocity and turn from PlayerDrive, from the way it
   * faces and the velocity it has now. Driven while the stick is held and while it goes along the ground for any reason
   * (the stick let go, a knock, a dash), then once more with nothing, so it can sleep: it has no friction of its own, and
   * this is what stops it.
   */
  private drivePlayer(dt: number): void {
    if (this.player.length === 0) { return }
    let i = this.index.get(this.player)
    if (i === undefined) { return }
    let held = this.stick[2] > 0
    let vx = 0
    let vz = 0
    this.playerFlying = false
    if (this.engine.readVelocity(i, this.one) === 1) {
      vx = this.one[0]
      vz = this.one[2]
      this.playerFlying = Math.abs(this.one[1]) >= PLAYER_STOP
    }
    this.playerGround = Math.hypot(vx, vz)
    if (!held && !this.driving && this.playerGround < PLAYER_STOP) { return }
    let yaw = this.engine.readPose(i, this.one) === 1 ? yawOf([this.one[3], this.one[4], this.one[5], this.one[6]]) : 0
    let v = this.driver.step(yaw, this.stick[0], this.stick[1], this.stick[2], this.playerSpeed, dt, vx, vz)
    this.engine.drive(i, v[0], v[1], v[2])
    this.driving = held || this.driver.moving()
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
    this.shotsFlying = this.countFlying()
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
      // Shots are never waited on, nor told.
      if (b.motion !== 'loose' || b.player !== null || b.shot !== null) { continue }
      let i = this.index.get(b.id)
      if (i === undefined) { continue }
      let value = 0
      if (this.engine.readPose(i, this.one) === 1) {
        // A piece (scene.from) is not where anything was built: it counts as knocked.
        let origin = this.origin.get(b.id)
        value = b.isDie ? topFace(this.one[3], this.one[4], this.one[5], this.one[6]) : b.from !== null ? 1
          : (knockedOver(b, this.one, origin !== undefined ? origin : null) ? 1 : 0)
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
      let o = k * CONTACT_RECORD
      let speed = this.contacts[o + 2]
      let a = this.idAt(Math.round(this.contacts[o]))
      let b = this.idAt(Math.round(this.contacts[o + 1]))
      let px = this.contacts[o + 3]
      let py = this.contacts[o + 4]
      let pz = this.contacts[o + 5]
      if (speed > STRUCK_MIN_SPEED && this.watched.size > 0) { this.gatherStruck(a, b, speed, px, py, pz) }
      if (!(speed > HIT_MIN_SPEED)) { continue }
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
        e.x = px
        e.y = py
        e.z = pz
        this.hitBest = e
      }
    }
    this.tellStruck()
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

  /** One knock with a watched body, kept for the next struck if it counts (see STRUCK_MIN_SPEED). */
  private gatherStruck(a: string, b: string, speed: number, px: number, py: number, pz: number): void {
    let wa = a.length > 0 && this.watched.has(a)
    let wb = b.length > 0 && this.watched.has(b)
    if (!wa && !wb) { return }
    let body = ''
    let other = ''
    if (a.length > 0 && this.targets.has(a)) {
      body = a
      other = b
    } else if (b.length > 0 && this.targets.has(b)) {
      body = b
      other = a
    } else {
      // Only a shot: told when it hits a body, never the ground.
      body = wa ? a : b
      other = wa ? b : a
      if (other.length === 0) { return }
    }
    let key = body < other ? body + '|' + other : other + '|' + body
    let last = this.pairAt.get(key)
    if (last !== undefined && this.simTime - last < STRUCK_PAIR_COOLDOWN_S - 1e-9) { return }
    this.pairAt.set(key, this.simTime)
    let shot = this.shots.indexOf(a) >= 0 || this.shots.indexOf(b) >= 0
    if ((shot || speed >= DUST_MIN_SPEED) && Number.isFinite(px) && Number.isFinite(py) && Number.isFinite(pz)) {
      this.pendingBursts.push(particleRequest(key, this.burstSerial++, px, py, pz, shot ? 'sparks' : 'dust',
        shot ? '#ffc45c' : '#a89b84'))
      if (this.pendingBursts.length > MAX_BURSTS) { this.pendingBursts.shift() }
    }
    // Every target in the contact is struck: two targets knocking together are both in bodies and values (body and other
    // name the pair once, for the event's own fields).
    for (let id of [a, b]) {
      if (id !== body && !(id.length > 0 && this.targets.has(id))) { continue }
      let known = this.struckSpeeds.get(id)
      if (known === undefined || speed > known) { this.struckSpeeds.set(id, speed) }
    }
    let best = this.struckBest
    if (best === null || speed > best.speed) {
      let e = new SimEvent()
      e.kind = 'struck'
      e.body = body
      e.other = other
      e.speed = speed
      e.x = px
      e.y = py
      e.z = pz
      this.struckBest = e
    }
  }

  /** What was gathered becomes one struck, if the bucket has a token for it (STRUCK_RATE a second, one at most). */
  private tellStruck(): void {
    this.struckTokens = Math.min(1, this.struckTokens + Math.max(0, this.simTime - this.struckClock) * STRUCK_RATE)
    this.struckClock = this.simTime
    if (this.pairAt.size > 64) {
      let old: string[] = []
      this.pairAt.forEach((t: number, key: string) => { if (this.simTime - t >= STRUCK_PAIR_COOLDOWN_S) { old.push(key) } })
      for (let key of old) { this.pairAt.delete(key) }
    }
    if (this.struckBest === null || this.struckTokens < 1 - 1e-9) { return }
    let e = this.struckBest as SimEvent
    let ids: string[] = []
    this.struckSpeeds.forEach((v: number, id: string) => { if (this.index.has(id)) { ids.push(id) } })
    let speeds = this.struckSpeeds
    ids.sort((x: string, y: string): number => {
      let d = (speeds.get(y) as number) - (speeds.get(x) as number)
      return d !== 0 ? d : (x < y ? -1 : x > y ? 1 : 0)
    })
    e.bodies = ids
    e.values = ids.map((id: string): number => speeds.get(id) as number)
    this.struckSpeeds = new Map<string, number>()
    this.struckBest = null
    if (ids.length === 0) { return }
    this.struckTokens -= 1
    this.events.push(e)
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

  /**
   * The bodies at rest, woken after the ground they lay on was made again: taking a body away does not wake what rests
   * on it, so dice on a table top that moved or went would stay asleep in the air until something hit them. A body still
   * moving is left as it goes.
   */
  private wakeResting(): void {
    for (let id of this.loose) {
      let i = this.index.get(id)
      if (i === undefined || this.engine.readVelocity(i, this.one) !== 1) { continue }
      if (Math.hypot(this.one[0], this.one[1], this.one[2]) < 1e-6) { this.engine.setVelocity(i, 0, 0, 0, 0, 0, 0) }
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

  /** The body id as the world being applied builds it, else as the last one did; null if neither has it. */
  private bodySpec(id: string): BodySpec | null {
    for (let w of [this.building, this.spec]) {
      if (w === null) { continue }
      for (let o of (w as WorldSpec).bodies) {
        if (o.id === id) { return o }
      }
    }
    return null
  }

  private createBody(b: BodySpec, parents: Map<string, number[]> | null = null, keptPose: boolean = false): void {
    let kind = kindOf(b)
    let i = -1
    if (b.shape === 'sphere') {
      i = this.engine.addSphere(b.dims[0] / 2, kind)
    } else if (b.shape === 'cylinder') {
      i = this.engine.addCylinder(b.dims[0] / 2, b.dims[1] / 2, kind)
    } else if (b.shape === 'shape' || b.shape === 'hull' || b.shape === 'group') {
      let parts = bodyRecords(b)
      i = this.engine.addParts(new Float32Array(parts.records), new Float32Array(parts.points), kind)
    } else {
      i = this.engine.addBox(b.dims[0] / 2, b.dims[1] / 2, b.dims[2] / 2, kind)
    }
    if (i < 0) { return }
    this.index.set(b.id, i)
    this.setName(i, b.id)
    this.origin.delete(b.id)
    let made = !keptPose && (b.from !== null || (b.shot !== null && b.motion === 'loose') || b.aim.length === 3)
    if (!made) {
      // A new loose die lies on a face drawn at random (dieStartTurn); the renderer takes its pose from here.
      this.placeBody(i, b, b.isDie && b.motion === 'loose' ? dieStartTurn(this.draw(b.id + '#start')) : null)
      this.engine.setMaterial(i, b.mass, b.restitution, b.friction)
    } else {
      let parent: number[] | null = null
      let burst = 0
      if (b.from !== null) {
        let f = b.from as SceneFrom
        burst = f.burst
        let live = parents !== null ? parents.get(f.parent) : undefined
        parent = live !== undefined ? live : this.liveState(f.parent)
        if (parent === null) {
          // Nowhere to come from: a piece goes where its parent was built, anything else where its own numbers put it.
          if (f.base.length === 6) {
            let q = quatXYZ(f.base[3], f.base[4], f.base[5])
            parent = [f.base[0], f.base[1], f.base[2], q[0], q[1], q[2], q[3], 0, 0, 0, 0, 0, 0]
          }
          this.fromMissing.push(b.id)
          console.info('VERA-WORLD from missing parent=' + f.parent + ' id=' + b.id)
        }
      }
      let shot = b.shot !== null && b.motion === 'loose' ? (b.shot as SceneShot).speed : 0
      let local = b.position
      if (shot !== 0 && b.from !== null) {
        let shooter = this.bodySpec((b.from as SceneFrom).parent)
        if (shooter !== null) { local = clearOfShooter(local, b.dims, shooter.dims, b.aim.length === 3) }
      }
      let at = resolveFrom(parent, local, b.rotation, b.aim, burst, shot)
      let pose = at[0]
      this.engine.setPose(i, pose[0], pose[1], pose[2], pose[3], pose[4], pose[5], pose[6])
      this.engine.setMaterial(i, b.mass, b.restitution, b.friction)
      if (b.motion === 'loose') {
        let v = at[1]
        let w = at[2]
        this.engine.setVelocity(i, v[0], v[1], v[2], w[0], w[1], w[2])
      }
      this.origin.set(b.id, pose)
    }
    if (b.target) { this.engine.watch(i, 1) }
  }

  private placeBody(i: number, b: BodySpec, turn: number[] | null = null): void {
    if (b.aim.length === 3 && b.from === null) {
      let at = resolveFrom(null, b.position, b.rotation, b.aim, 0, 0)[0]
      this.engine.setPose(i, at[0], at[1], at[2], at[3], at[4], at[5], at[6])
      return
    }
    let q = quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2])
    if (turn !== null) { q = mulQ(q, turn as number[]) }
    this.engine.setPose(i, b.position[0], b.position[1], b.position[2], q[0], q[1], q[2], q[3])
  }

  /** Where a die's numbers come from: the random source, else a generator seeded by `seed`. */
  private draw(seed: string): RandomSource {
    return this.random !== null ? this.random as RandomSource : seededRandom(fnv32(seed))
  }

  /** Loose bodies from earlier applies still standing as they were built, where they are now (see restingAtStart). */
  private standing(next: WorldSpec, created: BodySpec[]): Map<string, number[]> {
    let fresh = new Set<string>()
    for (let b of created) { fresh.add(b.id) }
    let out = new Map<string, number[]>()
    for (let b of next.bodies) {
      if (b.motion !== 'loose' || fresh.has(b.id) || b.shot !== null) { continue }
      let i = this.index.get(b.id)
      let origin = this.origin.get(b.id)
      if (i === undefined || this.engine.readPose(i, this.one) !== 1 ||
          knockedOver(b, this.one, origin !== undefined ? origin : null)) { continue }
      out.set(b.id, [this.one[0], this.one[1], this.one[2]])
    }
    return out
  }

  /** Poses held from an early finish lose those of freed indices: the index may name a new body by the next frame. */
  private dropPoses(freed: Set<number>): void {
    let p = this.poses
    let kept = 0
    for (let k = 0; k < this.poseCount; k++) {
      if (freed.has(Math.round(p[k * 8]))) { continue }
      if (kept !== k) {
        for (let j = 0; j < 8; j++) { p[kept * 8 + j] = p[k * 8 + j] }
      }
      kept++
    }
    this.poseCount = kept
  }

  private removeBody(id: string, freed: Set<number> | null = null): void {
    let i = this.index.get(id)
    if (i === undefined) { return }
    if (freed !== null) { freed.add(i) }
    this.engine.remove(i)
    this.index.delete(id)
    this.origin.delete(id)
    this.setName(i, '')
  }
}
