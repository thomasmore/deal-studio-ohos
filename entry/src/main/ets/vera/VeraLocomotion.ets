/**
 * Moving through a world, as the host does it and the program never sees: the player steered by the stick, the camera
 * that follows a body, zones that tell when a body comes into them, and the swing of a walking body's legs.
 *
 * The program says what it wants once per state -- scene.player, scene.follow, scene.zone, scene.swing -- and the host does
 * the rest every frame, so steering a body costs the program nothing per frame, as orbits and physics do not.
 *
 * Pure: imports only relative modules, never a platform kit, so tools/vera-harness loads it under node.
 */

import { BodySpec, ZoneSpec, FollowSpec, headingDeg } from './VeraScene'
import { CameraPose, orbitEye, quatXYZ, followOffset, followLook, followPlanes } from './VeraLook3D'

const DEG: number = Math.PI / 180

/** How fast the player comes up to speed and down from it, m/s². */
export const PLAYER_ACCEL: number = 8
export const PLAYER_BRAKE: number = 12
/** How fast the player turns to face the way it is pushed, at most (degrees a second), and how keenly (per second). */
export const PLAYER_TURN_DEG_S: number = 270
export const PLAYER_TURN_GAIN: number = 7
/** Below this speed (m/s) a released player has stopped. */
export const PLAYER_STOP: number = 0.02
/** A stick pushed less than this share of the way counts as let go. */
export const STICK_DEAD: number = 0.12

/** The difference b - a of two headings in degrees, the short way round (-180 .. 180). */
export function turnDeg(a: number, b: number): number {
  let d = (b - a) % 360
  if (d > 180) { d -= 360 }
  if (d < -180) { d += 360 }
  return d
}

/** The heading (degrees about y) of a rotation [x, y, z, w]: where its +x points, seen from above. */
export function yawOf(q: number[]): number {
  let x = q[0]
  let y = q[1]
  let z = q[2]
  let w = q[3]
  // The world x and z of the body's local +x axis.
  let fx = 1 - 2 * (y * y + z * z)
  let fz = 2 * (x * z - y * w)
  return headingDeg(fx, fz)
}

/**
 * The player's driving, one physics step at a time: from the stick (a unit direction on the floor and how far it is
 * pushed, 0..1), the way the body faces and how it moves along the ground now, the horizontal velocity and the turn to
 * give it. Its velocity goes towards the stick's -- the way the stick points, at the speed pushed -- by at most
 * PLAYER_ACCEL a second when that is faster and PLAYER_BRAKE when slower, from the velocity the body really has: so a
 * dash or a knock is not undone at once but runs out, a stick let go (or never held) brings any going to a stop, and a
 * player held against a wall has the speed it really goes at, about none. It turns, at most PLAYER_TURN_DEG_S, to face
 * the push; pushed against the way it faces it first turns, going slowly.
 */
export class PlayerDrive {
  /** Its speed along the ground after this step, m/s. */
  speed: number = 0
  /** The way it was last pushed, a unit [x, z]. */
  dir: number[] = [1, 0]

  /** [vx, vz, wy] for this step, the body going (vx, vz) now: metres a second, and radians a second about y. */
  step(yawDeg: number, dx: number, dz: number, push: number, maxSpeed: number, dt: number, vx: number = 0,
    vz: number = 0): number[] {
    let held = push > STICK_DEAD && Math.hypot(dx, dz) > 1e-6
    let wy = 0
    let tx = 0
    let tz = 0
    if (held) {
      let n = Math.hypot(dx, dz)
      this.dir = [dx / n, dz / n]
      let delta = turnDeg(yawDeg, headingDeg(this.dir[0], this.dir[1]))
      wy = Math.max(-PLAYER_TURN_DEG_S, Math.min(PLAYER_TURN_DEG_S, delta * PLAYER_TURN_GAIN)) * DEG
      // Facing away from the push it first turns round, nearly on the spot; facing it, it goes at the speed pushed.
      let facing = Math.cos(Math.min(90, Math.abs(delta)) * DEG)
      let target = maxSpeed * Math.min(1, push) * Math.max(0.25, facing)
      tx = this.dir[0] * target
      tz = this.dir[1] * target
    }
    let rate = Math.hypot(tx, tz) > Math.hypot(vx, vz) ? PLAYER_ACCEL : PLAYER_BRAKE
    let gx = tx - vx
    let gz = tz - vz
    let gap = Math.hypot(gx, gz)
    let k = gap > rate * dt ? rate * dt / gap : 1
    let nx = vx + gx * k
    let nz = vz + gz * k
    this.speed = Math.hypot(nx, nz)
    if (!held && this.speed < PLAYER_STOP) {
      nx = 0
      nz = 0
      this.speed = 0
    }
    return [nx, nz, wy]
  }

  /** Whether it is still going (or turning) and needs driving. */
  moving(): boolean {
    return this.speed > 0
  }

  reset(): void {
    this.speed = 0
  }
}

/** A zone as the watch tells it apart: its id where it is and as large as it is. */
function zonePlace(z: ZoneSpec): string {
  return z.id + '\u0000' + z.x.toString() + ',' + z.z.toString() + ',' + z.r.toString()
}

/** A body that came into a zone. */
export class ZoneEnter {
  body: string = ''
  zone: string = ''
  x: number = 0
  y: number = 0
  z: number = 0
}

/**
 * Which bodies are in which zones, from where the bodies are each frame. A body counts as in a zone when its centre is
 * within the zone's radius, seen from above. Only coming in is told; and only for a body and a zone both seen before:
 * a body made inside a zone (a new round puts the player back on its start) or a zone put round a body is not an entry.
 * A zone the program moves or resizes is a zone put down afresh: a body it now lands on has not come into it.
 */
export class ZoneWatch {
  private inside: Set<string> = new Set<string>()
  private bodies: Set<string> = new Set<string>()
  private zones: Set<string> = new Set<string>()

  /** positions: body id -> [x, y, z, ...] of the bodies that may move. */
  update(zones: ZoneSpec[], positions: Map<string, number[]>): ZoneEnter[] {
    let out: ZoneEnter[] = []
    let inside = new Set<string>()
    let zoneIds = new Set<string>()
    for (let z of zones) { zoneIds.add(zonePlace(z)) }
    let bodyIds = new Set<string>()
    positions.forEach((p: number[], id: string) => {
      bodyIds.add(id)
      for (let z of zones) {
        if (Math.hypot(p[0] - z.x, p[2] - z.z) > z.r) { continue }
        let key = id + '\u0000' + z.id
        inside.add(key)
        if (this.inside.has(key) || !this.bodies.has(id) || !this.zones.has(zonePlace(z))) { continue }
        let e = new ZoneEnter()
        e.body = id
        e.zone = z.id
        e.x = p[0]
        e.y = p[1]
        e.z = p[2]
        out.push(e)
      }
    })
    this.inside = inside
    this.bodies = bodyIds
    this.zones = zoneIds
    out.sort((a: ZoneEnter, b: ZoneEnter): number => a.body < b.body ? -1 : a.body > b.body ? 1 : (a.zone < b.zone ? -1 : a.zone > b.zone ? 1 : 0))
    return out
  }

  reset(): void {
    this.inside = new Set<string>()
    this.bodies = new Set<string>()
    this.zones = new Set<string>()
  }
}

/** How quickly the follow camera catches up with its body: it closes 1 - e^(-dt / FOLLOW_LAG_S) of the gap a frame. */
export const FOLLOW_LAG_S: number = 0.25

/**
 * The camera following a body. It stands behind the body (the way it faced when it was first followed) and above it,
 * looks a little above its centre, and catches up with it smoothly; a drag turns it round the body and a pinch brings it
 * nearer, both kept from then on. It does not turn to stay behind the body by itself: the stick pushes the body the way
 * it is pushed on the screen, and a camera that swung round with the body would turn that way under the person's thumb.
 */
export class Follower {
  /** eye - look, as the person last left it. */
  offset: number[] = [0, 0, 0]
  look: number[] = [0, 0, 0]
  ready: boolean = false

  /** Put the camera at once behind the body at target (its heading in degrees), for follow. */
  snap(pose: CameraPose, target: number[], heading: number, follow: FollowSpec): void {
    this.offset = followOffset(heading, follow)
    this.look = followLook(target, follow)
    this.ready = true
    this.write(pose)
  }

  /** dt seconds later, with the body at target: the camera moves towards it. Whether it moved (more than eps metres). */
  step(pose: CameraPose, target: number[], follow: FollowSpec, dt: number, eps: number = 0.0005): boolean {
    if (!this.ready) { return false }
    let want = followLook(target, follow)
    let k = 1 - Math.exp(-Math.max(0, dt) / FOLLOW_LAG_S)
    let moved = 0
    for (let i = 0; i < 3; i++) {
      let d = (want[i] - this.look[i]) * k
      this.look[i] += d
      moved = Math.max(moved, Math.abs(d))
    }
    this.write(pose)
    return moved > eps
  }

  /** Whether the camera has still to catch up with a body at target. */
  behind(target: number[], follow: FollowSpec, eps: number = 0.002): boolean {
    let want = followLook(target, follow)
    return Math.hypot(want[0] - this.look[0], want[1] - this.look[1], want[2] - this.look[2]) > eps
  }

  /** A drag: turned yaw radians round the body and tilted pitch, never below the ground (minPitch). */
  turn(pose: CameraPose, yaw: number, pitch: number, minPitch: number): void {
    let eye = orbitEye([this.look[0] + this.offset[0], this.look[1] + this.offset[1], this.look[2] + this.offset[2]],
      this.look, yaw, pitch, minPitch, 1.45)
    this.offset = [eye[0] - this.look[0], eye[1] - this.look[1], eye[2] - this.look[2]]
    this.write(pose)
  }

  /** The pose's eye taken as the camera's new distance (a pinch). */
  keepEye(pose: CameraPose): void {
    this.offset = [pose.eye[0] - this.look[0], pose.eye[1] - this.look[1], pose.eye[2] - this.look[2]]
  }

  private write(pose: CameraPose): void {
    pose.look = [this.look[0], this.look[1], this.look[2]]
    pose.eye = [this.look[0] + this.offset[0], this.look[1] + this.offset[1], this.look[2] + this.offset[2]]
    pose.orbit = true
    followPlanes(pose)
  }
}

/** Half a part's height: how far its top is above its centre (a ball's radius). */
function partHalfHeight(p: BodySpec): number {
  return p.shape === 'sphere' ? p.dims[0] / 2 : p.dims[1] / 2
}

/**
 * Where a swinging part of a group is at tSeconds, [px, py, pz, qx, qy, qz, qw] about the group's centre: turned about the
 * group's z axis (forward and back, the group facing +x) round the middle of its top, by deg * pace * sin(...), pace the
 * share of its stride the body is going at (0 still, 1 at its pace). A part without a swing stays as it was built.
 */
export function swingTurn(p: BodySpec, tSeconds: number, pace: number): number[] {
  let q0 = quatXYZ(p.rotation[0], p.rotation[1], p.rotation[2])
  let s = p.swing
  if (s === null || s.periodS <= 0) { return [p.position[0], p.position[1], p.position[2], q0[0], q0[1], q0[2], q0[3]] }
  let theta = s.deg * Math.max(0, Math.min(1.5, pace)) * Math.sin(2 * Math.PI * tSeconds / s.periodS + s.phaseDeg * DEG) * DEG
  let half = partHalfHeight(p)
  let px = p.position[0] + half * Math.sin(theta)
  let py = p.position[1] + half - half * Math.cos(theta)
  let sz = Math.sin(theta / 2)
  let cz = Math.cos(theta / 2)
  // qz * q0: the part's own turn, then the swing.
  let q = [cz * q0[0] - sz * q0[1], cz * q0[1] + sz * q0[0], cz * q0[2] + sz * q0[3], cz * q0[3] - sz * q0[2]]
  return [px, py, p.position[2], q[0], q[1], q[2], q[3]]
}

/** Whether any part of a body swings. */
export function hasSwing(b: BodySpec): boolean {
  for (let p of b.parts) { if (p.swing !== null) { return true } }
  return false
}
