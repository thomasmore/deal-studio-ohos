/**
 * One ui.World on screen: an ArkGraphics3D scene that shows the WorldSpec the program's build function returned.
 *
 * The program describes the world once per state (decodeScene); this box turns the difference from what it shows into
 * scene nodes (diffWorld), so a state change that moves one body touches one node. Everything the kit does is
 * asynchronous, so the applies are serialised: one runs at a time, a spec that arrives meanwhile waits, and only the
 * latest waiting one is applied. New bodies are made BATCH at a time with a frame between batches, so a world of three
 * hundred bodies fills in over a few frames instead of holding the first one.
 *
 * On each frame (VeraPreview's display loop) the bodies that orbit or spin are put where orbitPositions says they are,
 * and, when the world has loose bodies, its WorldSim (vera/VeraPhysics.ets) steps the physics and only the bodies the
 * engine reports as moved get a new pose. The sim's events -- `hit`, `settled` -- wait in the box until the caller
 * dispatches them. A drag on empty space circles the camera round its look point when the program's camera allows it;
 * a drag that starts on a body is a `swipe` on release; a tap is a raycast, helped out by the nearest body on screen
 * when the ray misses (small moving planets are hard to hit).
 *
 * Physics: the native library (libphys.so) holds ONE world, so one box owns it at a time -- the box that most recently
 * asked for physics (its world gained a loose body). A box that loses it keeps showing its bodies where they are, without
 * physics, and does not get it back; the owner resets the engine when it is retired or destroyed. A build without Jolt
 * (physInit() is 0) shows the world without physics and says so in `note`.
 *
 * What the world looks like -- light, colours, the table, the pips, the default camera -- is VeraLook3D, which is plain
 * data the host checks. This file is the only one that imports @kit.ArkGraphics3D.
 *
 * Measured in the spike: node.destroy() alone leaves a node in the scene; root.children.remove(node) takes it out.
 */

import { Scene, Camera, Light, Environment, LightType, SceneResourceFactory, GeometryDefinition, CubeGeometry, SphereGeometry, CylinderGeometry,
  PlaneGeometry, Material, MaterialType, MetallicRoughnessMaterial, UnlitMaterial, Vec2, Vec3, Vec4, Quaternion, Node, Geometry,
  MeshResource, EnvironmentBackgroundType, PostProcessSettings, RaycastResult, RaycastParameters, Color, SpotLight, CustomGeometry,
  PrimitiveTopology } from '@kit.ArkGraphics3D'
import { WorldSpec, BodySpec, WorldDiff, diffWorld, orbitPositions, MotionCarry } from '../vera/VeraScene'
import { SurfaceMesh, paintedSphere, flatRing, surfaceSeed } from '../vera/VeraSurfaces'
import { prismMesh, hullMesh } from '../vera/VeraShapes'
import { PhysEngine, WorldSim, SimEvent } from '../vera/VeraPhysics'
import { physInit, physReset, physSetGravity, physSetBound, physAddBox, physAddSphere, physAddCylinder, physAddParts, physRemove, physSetPose,
  physSetMaterial, physSetVelocity, physSleep, physMoveKinematic, physStep, physStepBegin, physStepEnd, physReadAwake, physReadPose, physDrainContacts,
  physAwakeDynamic } from 'libphys.so'
import { ResolvedTheme } from '../vera/VeraTheme'
import { LOOK_SUN_INTENSITY, LOOK_SUN_POSITION, LOOK_SUN_TARGET, sunFor, LOOK_SHADOWS, LOOK_AMBIENT, LOOK_FOV, LOOK_FLOOR_ROLE,
  LOOK_TABLE_ROLE, LOOK_PIP_ROLE, LOOK_BACKGROUND_ROLE, TABLE_TOP_THICKNESS, PIP_RADIUS, lookLinear, lookColorKey, quatXYZ,
  lookAtQuat, CameraPose, worldCamera, orbitEye, pinchDistance, zoomPose, worldBounds, tableParts, floorSize, pipLayout, floorColor, worldGlows,
  floorGain, floorBaseLinear, linearHex, FLOOR_ROUGHNESS, FLOOR_METALLIC, FLOOR_SPECULAR, projectPoint, metresPerVp, floorDirection,
  GLOW_AMBIENT, GLOW_SPOTS, GLOW_SPOT_INNER, GLOW_SPOT_OUTER, TRAIL_POINTS, glowCandela, worldBackgroundRgba, isDarkRgba,
  worldHasBackdrop, starField, worldTrails, worldSuns, lookRgba, srgbToLinear } from '../vera/VeraLook3D'

/** A SurfaceMesh as the kit's geometry: its colours turned from sRGB to the linear values a vertex colour is. */
function customGeometry(m: SurfaceMesh): CustomGeometry {
  let g = new CustomGeometry()
  g.topology = PrimitiveTopology.TRIANGLE_LIST
  let vertices: Vec3[] = []
  let normals: Vec3[] = []
  let colors: Color[] = []
  for (let i = 0; i < m.positions.length; i += 3) {
    vertices.push({ x: m.positions[i], y: m.positions[i + 1], z: m.positions[i + 2] })
    normals.push({ x: m.normals[i], y: m.normals[i + 1], z: m.normals[i + 2] })
    colors.push({ r: srgbToLinear(m.colors[i]), g: srgbToLinear(m.colors[i + 1]), b: srgbToLinear(m.colors[i + 2]), a: 1 })
  }
  g.vertices = vertices
  g.normals = normals
  g.colors = colors
  g.indices = m.indices
  return g
}

/**
 * Painted spheres already worked out, by everything that decides their colours: marking a planet or drawing its world
 * again makes the body again, and its surface (noise at every vertex) should not be worked out again with it.
 */
const PAINTED: Map<string, CustomGeometry> = new Map<string, CustomGeometry>()
const PAINTED_KEEP: number = 48

function paintedGeometry(b: BodySpec, theme: ResolvedTheme): CustomGeometry {
  let c1 = lookRgba(theme, b.color, 'ink')
  let c2 = lookRgba(theme, b.color2.length > 0 ? b.color2 : b.color, 'ink')
  let key = [b.id, b.pattern, (b.dims[0] / 2).toFixed(4), c1.join(','), c2.join(',')].join('|')
  let known = PAINTED.get(key)
  if (known !== undefined) { return known }
  let made = customGeometry(paintedSphere(b.dims[0] / 2, b.pattern, c1, c2, surfaceSeed(b.id)))
  if (PAINTED.size >= PAINTED_KEEP) { PAINTED.delete(PAINTED.keys().next().value as string) }
  PAINTED.set(key, made)
  return made
}

/**
 * Meshes of scene.shape and scene.hull, by their points: white vertices under the body's own material, so a body of any
 * shape is coloured, recoloured and themed as a box is.
 */
const SHAPED: Map<string, CustomGeometry> = new Map<string, CustomGeometry>()
const SHAPED_KEEP: number = 64

function shapedGeometry(b: BodySpec): CustomGeometry {
  let key = b.shape + '|' + b.dims[1].toFixed(5) + '|' + b.points.map((v: number): string => v.toFixed(5)).join(',')
  let known = SHAPED.get(key)
  if (known !== undefined) { return known }
  let made = customGeometry(b.shape === 'hull' ? hullMesh(b.points) : prismMesh(b.points, b.dims[1]))
  if (SHAPED.size >= SHAPED_KEEP) { SHAPED.delete(SHAPED.keys().next().value as string) }
  SHAPED.set(key, made)
  return made
}

/** The stars of a scene.sky, by how many: the same sky each time for one count. */
const STARS: Map<number, number[][]> = new Map<number, number[][]>()
function starsOf(n: number): number[][] {
  let known = STARS.get(n)
  if (known !== undefined) { return known }
  let made = starField(n)
  STARS.set(n, made)
  return made
}
/** How far off a star is drawn, in metres: far enough that walking the camera round a solar system does not move it. */
const STAR_DISTANCE: number = 500
/** A sun's halo on screen, as a multiple of its radius there. */
const HALO_SCALE: number = 2.6

/** Bodies made per frame while a world fills in. */
const BATCH: number = 20
/** A tap moves less than this many px and lifts within this many ms; anything else is a drag. */
const TAP_MOVE_PX: number = 10
const TAP_MS: number = 300
/** How far a drag turns the camera, in radians per vp. */
const DRAG_RAD_PER_VP: number = 0.008
/** How long a retired box that is still on screen waits for its Component3D to go before it destroys the scene anyway. */
const RETIRE_MS: number = 1000
/** A tap whose ray hits no body takes the body whose centre on screen is nearest, within its own size and this many vp. */
const TAP_SLOP_VP: number = 24
/** A drag starts on a body when the finger is within its size on screen and this many vp. */
const DRAG_SLOP_VP: number = 8
/** A swipe's speed is the finger's over the last this many ms, in m/s at the body's distance, at most SWIPE_MAX. */
const SWIPE_WINDOW_MS: number = 100
const SWIPE_MAX: number = 10
/** Events waiting for the caller beyond this drop their oldest hit (a settle is never dropped). */
const EVENT_QUEUE: number = 64
const PHYSICS_MISSING: string = 'Physics is not available in this build: bodies stay where they are put.'

/** The native physics behind the PhysEngine interface WorldSim drives. */
class NativePhys implements PhysEngine {
  init(maxBodies: number, threads: number): number {
    try {
      if (maxBodies > 0 && threads > 0) { return physInit(maxBodies, threads) }
      return maxBodies > 0 ? physInit(maxBodies) : physInit()
    } catch (e) {
      console.warn('VERA-WORLD physics init failed: ' + (e as Error).message)
      return 0
    }
  }
  reset(): void { physReset() }
  setGravity(y: number): void { physSetGravity(y) }
  setBound(minY: number, halfX: number, halfZ: number): void { physSetBound(minY, halfX, halfZ) }
  addBox(hx: number, hy: number, hz: number, kind: number): number { return physAddBox(hx, hy, hz, kind) }
  addSphere(r: number, kind: number): number { return physAddSphere(r, kind) }
  addCylinder(r: number, halfHeight: number, kind: number): number { return physAddCylinder(r, halfHeight, kind) }
  addParts(records: Float32Array, points: Float32Array, kind: number): number { return physAddParts(records, points, kind) }
  remove(i: number): void { physRemove(i) }
  setPose(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number): void {
    physSetPose(i, px, py, pz, qx, qy, qz, qw)
  }
  setMaterial(i: number, mass: number, restitution: number, friction: number): void { physSetMaterial(i, mass, restitution, friction) }
  setVelocity(i: number, vx: number, vy: number, vz: number, wx: number, wy: number, wz: number): void {
    physSetVelocity(i, vx, vy, vz, wx, wy, wz)
  }
  sleep(i: number): void { physSleep(i) }
  moveKinematic(i: number, px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number, dt: number): void {
    physMoveKinematic(i, px, py, pz, qx, qy, qz, qw, dt)
  }
  step(dt: number, substeps: number): number { return physStep(dt, substeps) }
  /** The step runs on the library's own thread while the frame is drawn (phys_stepper.h). */
  overlaps(): boolean { return true }
  stepBegin(dt: number, substeps: number): void { physStepBegin(dt, substeps) }
  stepEnd(): number { return physStepEnd() }
  readAwake(out: Float32Array): number { return physReadAwake(out) }
  readPose(i: number, out: Float32Array): number { return physReadPose(i, out) }
  drainContacts(out: Float32Array): number { return physDrainContacts(out) }
  awakeDynamic(): number { return physAwakeDynamic() }
}

/** The one native engine, made on first use; its thread count once known (0: this build has no physics). */
let nativePhys: NativePhys | null = null
let nativeThreads: number = -1
/** The box whose world is in the native engine now. */
let physOwner: WorldBox | null = null

function nativeEngine(): NativePhys | null {
  if (nativeThreads < 0) {
    let engine = new NativePhys()
    nativeThreads = engine.init(0, 0)
    nativePhys = engine
    console.info('VERA-WORLD physics threads=' + nativeThreads.toString())
  }
  return nativeThreads > 0 ? nativePhys : null
}

function v3(x: number, y: number, z: number): Vec3 {
  let v: Vec3 = { x: x, y: y, z: z }
  return v
}

function quat(q: number[]): Quaternion {
  let r: Quaternion = { x: q[0], y: q[1], z: q[2], w: q[3] }
  return r
}

function vec4(c: number[]): Vec4 {
  let v: Vec4 = { x: c[0], y: c[1], z: c[2], w: c[3] }
  return v
}

function nextFrame(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 16) })
}

function hasKinematic(spec: WorldSpec | null): boolean {
  if (spec === null) { return false }
  for (let b of spec.bodies) { if (b.motion === 'kinematic') { return true } }
  return false
}

function hasLoose(spec: WorldSpec | null): boolean {
  if (spec === null) { return false }
  for (let b of spec.bodies) { if (b.motion === 'loose') { return true } }
  return false
}

/** What a tap hit: the body's id ("" for empty space, the table or the floor) and where, in metres. */
export class WorldPick {
  body: string = ''
  /** For a group, the id of the part hit; '' otherwise. */
  part: string = ''
  x: number = 0
  y: number = 0
  z: number = 0
}

/**
 * A finger lifted from the world that the program may hear of: a tap (the caller then picks what is under it) or a
 * swipe of a body -- x, z a unit direction along the floor, speed in m/s.
 */
export class WorldGesture {
  kind: string = ''
  body: string = ''
  x: number = 0
  z: number = 0
  speed: number = 0
}

class BodyNode {
  spec: BodySpec
  node: Node
  names: string[] = []
  pips: Node[] = []
  /** A group's part nodes, children of `node` (an empty node), and the part each one draws. */
  parts: Node[] = []
  partSpecs: BodySpec[] = []
  /** Where the node was last put, for picking by screen distance. */
  pos: number[] = [0, 0, 0]
  constructor(spec: BodySpec, node: Node) {
    this.spec = spec
    this.node = node
  }
}

@ObservedV2
export class WorldBox {
  /** What Component3D is given, once the scene exists: the branch shows a placeholder until then. */
  @Trace options: SceneOptions | null = null
  /** What VeraPreview last asked for (the spec as JSON, and the theme), so an unchanged state asks nothing. */
  key: string = ''
  theme: ResolvedTheme | null = null
  /** Said over the world when it cannot do what it was asked: a build without physics. */
  @Trace note: string = ''
  /** Frames written and the ms they took, physics ms and loose bodies awake, since VeraPreview last read them for its VERA-WORLD line. */
  frames: number = 0
  writeMs: number = 0
  stepMs: number = 0
  awake: number = 0
  /** The most contacts the physics drained in one frame, since VeraPreview last read it. */
  mostContacts: number = 0

  private scene: Scene | null = null
  private rf: SceneResourceFactory | null = null
  private cam: Camera | null = null
  private light: Light | null = null
  private env: Environment | null = null
  private glows: boolean = false
  /**
   * Whether anything is painted behind the bodies (worldHasBackdrop): the sky's colour and stars, the trails and the halo
   * of each glowing body that stands still. The backdrop is a canvas under the scene (touches pass through it), which is
   * then cleared see-through; it is painted when the camera, the box or the world changes -- not per frame: nothing in
   * it moves by itself.
   */
  private backdropOn: boolean = false
  /** Whether what is behind the world is dark (the sky's colour, else the theme's background): text over it goes light. */
  dark: boolean = false
  readonly backdrop: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private backdropReady: boolean = false
  /** The spot lights of a glowing body (GLOW_SPOTS), made the first time a world needs them. */
  private spots: Light[] = []
  private spotsMade: boolean = false
  private sim: WorldSim | null = null
  /** The sim's kickSerial when last looked at, and Date.now() when that throw was applied (for the VERA-WORLD lines). */
  private kickSeen: number = 0
  private kickWallAt: number = 0
  private physicsLost: boolean = false
  private events: SimEvent[] = []
  private destroyed: boolean = false
  private retired: boolean = false
  private shown: boolean = false
  private retireTimer: number = -1
  private running: boolean = false
  /** The latest spec asked for, the one being applied (frames place its orbits), and the one fully applied. */
  private wanted: WorldSpec | null = null
  private wantedTheme: ResolvedTheme | null = null
  private showing: WorldSpec | null = null
  private showingMoves: boolean = false
  private applied: WorldSpec | null = null
  private appliedTheme: ResolvedTheme | null = null
  private bodies: Map<string, BodyNode> = new Map<string, BodyNode>()
  /** Node name -> body id, pips included, for a raycast hit. */
  private byName: Map<string, string> = new Map<string, string>()
  /** Node name -> part id, for a raycast that hits a part of a group. */
  private partByName: Map<string, string> = new Map<string, string>()
  private materials: Map<string, Promise<Material>> = new Map<string, Promise<Material>>()
  private tableNodes: Node[] = []
  private floorNodes: Node[] = []
  private serial: number = 0
  private timeS: number = 0
  /** The elapsed time of the frame begun last, for advance. */
  private frameMs: number = 0
  private carry: MotionCarry = new MotionCarry()
  private pose: CameraPose | null = null
  private width: number = 0
  private height: number = 0
  private density: number = 1
  private tracking: boolean = false
  private finger: number = -1
  private moved: boolean = false
  private downX: number = 0
  private downY: number = 0
  private lastX: number = 0
  private lastY: number = 0
  private downAt: number = 0
  /** The body a drag started on ('' for empty space), and the gesture it belongs to (a late raycast checks it). */
  private downBody: string = ''
  private gesture: number = 0
  /** [ms, x, y] of the finger's recent positions, for a swipe's speed. */
  private samples: number[] = []
  /** A second finger pinching (-1: none), where it is, how far apart the two started and the camera's distance then. */
  private pinchFinger: number = -1
  private pinchX: number = 0
  private pinchY: number = 0
  private pinchSpan: number = 0
  private pinchFrom: number = 0
  /** The camera's distance when the world was last framed, and the world's radius: what a pinch is measured against. */
  private framed: number = 0
  private worldRadius: number = 1

  /** Show this world (with this theme) as soon as what is being applied now is done. */
  apply(spec: WorldSpec, theme: ResolvedTheme): void {
    if (this.destroyed || this.retired) { return }
    this.wanted = spec
    this.wantedTheme = theme
    this.pump()
  }

  /** Whether the display loop should run for this world: something in what it shows, or is about to, orbits or spins. */
  needsFrames(): boolean {
    if (this.destroyed || this.retired) { return false }
    if (hasKinematic(this.wanted) || this.showingMoves || this.events.length > 0) { return true }
    if (this.sim !== null && this.sim.needsFrames()) { return true }
    // A world about to be given loose bodies (or a throw) starts its frames before the apply is done.
    return this.wanted !== this.applied && hasLoose(this.wanted) && !this.physicsLost && this.note.length === 0
  }

  /** Up to max of the events the world has told, oldest first; the rest wait for the next frame. */
  takeEvents(max: number): SimEvent[] {
    return this.events.splice(0, Math.max(0, max))
  }

  bodyCount(): number {
    return this.bodies.size
  }

  /**
   * The first half of one display frame, elapsedMs after the last: the orbiting and spinning bodies move to where they
   * are now, and what the physics step begun last frame did lands on the nodes and in the events. No step runs until
   * advance, so the events can go to the program (and its changes be applied) in between without waiting on one.
   */
  frame(elapsedMs: number): void {
    if (this.destroyed) { return }
    this.timeS += elapsedMs / 1000
    this.frameMs = elapsedMs
    this.writeKinematic()
    let sim = this.sim
    if (sim !== null) {
      sim.collect()
      this.stepMs += sim.stepMs
      this.awake = sim.awake
      this.mostContacts = Math.max(this.mostContacts, sim.mostContacts)
      sim.mostContacts = 0
      this.writePhysics(sim)
      for (let e of sim.takeEvents()) {
        if (e.kind === 'settled') {
          console.info('VERA-WORLD settled kick=' + e.kick.toString() + ' values=' + e.values.join(',') + ' afterMs=' +
            (Date.now() - this.kickWallAt).toString() + ' simMs=' + e.afterMs.toString())
        }
        this.queue(e)
      }
    }
  }

  /** The second half of the frame: the next physics step begins, on its own thread, while the frame is drawn. */
  advance(): void {
    if (this.destroyed || this.retired || this.sim === null) { return }
    (this.sim as WorldSim).advance(this.frameMs, this.timeS)
  }

  /** The poses of the bodies the engine moved this frame, and no others. */
  private writePhysics(sim: WorldSim): void {
    let n = sim.poseCount
    if (n <= 0 || this.bodies.size === 0) { return }
    let t0 = Date.now()
    let p = sim.poses
    for (let k = 0; k < n; k++) {
      let o = k * 8
      let entry = this.bodies.get(sim.idAt(Math.round(p[o])))
      // Orbits are written from orbitPositions; the engine's copy of a kinematic body only pushes things.
      if (entry === undefined || entry.spec.motion !== 'loose') { continue }
      entry.node.position = v3(p[o + 1], p[o + 2], p[o + 3])
      let r: Quaternion = { x: p[o + 4], y: p[o + 5], z: p[o + 6], w: p[o + 7] }
      entry.node.rotation = r
      entry.pos[0] = p[o + 1]
      entry.pos[1] = p[o + 2]
      entry.pos[2] = p[o + 3]
    }
    this.writeMs += Date.now() - t0
  }

  private queue(e: SimEvent): void {
    this.events.push(e)
    if (this.events.length <= EVENT_QUEUE) { return }
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].kind === 'hit') {
        this.events.splice(i, 1)
        return
      }
    }
  }

  /** Another box took the native engine: this one keeps its bodies where they are, without physics, from now on. */
  losePhysics(): void {
    this.sim = null
    this.physicsLost = true
    this.awake = 0
  }

  /** Give the native engine back, empty, if this box has it. */
  private releasePhysics(): void {
    if (physOwner !== this) { return }
    physOwner = null
    let sim = this.sim
    this.sim = null
    try {
      if (sim !== null) { sim.reset() } else { physReset() }
    } catch (e) {
      console.warn('VERA-WORLD physics reset failed: ' + (e as Error).message)
    }
  }

  /**
   * The physics side of one apply, before any node is touched: the first world with a loose body takes the native engine
   * and puts in every body it shows (only this state's kicks fire); after that each diff goes to the sim as it comes.
   */
  private applyPhysics(prev: WorldSpec | null, diff: WorldDiff, next: WorldSpec): void {
    let sim = this.sim
    if (sim !== null) {
      sim.apply(diff, next)
      this.noteKick(sim)
      return
    }
    let wants = hasLoose(next)
    if (!wants || this.physicsLost) {
      this.note = ''
      return
    }
    let engine = nativeEngine()
    if (engine === null) {
      this.note = PHYSICS_MISSING
      return
    }
    this.note = ''
    if (physOwner !== null && physOwner !== this) { physOwner.losePhysics() }
    physOwner = this
    // Dice thrown here draw from Math.random, so no two throws are alike (the host's checks seed them instead).
    let made = new WorldSim(engine, (): number => Math.random())
    made.reset()
    // Only a trigger that changed in this apply throws. On the box's first apply (prev null) every non-zero trigger
    // is one the state already had -- restored on reopen, or a rebuild -- and throwing it again would roll the dice by
    // itself and overwrite the faces the state keeps.
    let full = diffWorld(null, next)
    full.kick = prev !== null ? diff.kick : []
    made.apply(full, next)
    this.sim = made
    this.noteKick(made)
    if (made.restingCount > 0) { console.info('VERA-WORLD resting=' + made.restingCount.toString() + ' start asleep') }
  }

  /**
   * After an apply: a new throw is logged, and a settle of an earlier throw still waiting here to be dispatched is
   * dropped -- delivered now it would reach the state of the new throw with the faces of the old one.
   */
  private noteKick(sim: WorldSim): void {
    if (sim.kickSerial === this.kickSeen) { return }
    this.kickSeen = sim.kickSerial
    this.kickWallAt = Date.now()
    console.info('VERA-WORLD kick n=' + sim.kickSerial.toString() + ' bodies=' + sim.lastKickBodies.toString() +
      ' awake=' + sim.lastKickAwake.toString())
    let kept: SimEvent[] = []
    for (let e of this.events) {
      if (e.kind === 'settled' && e.kick < sim.kickSerial) {
        console.info('VERA-WORLD event dropped kind=settled reason=superseded-by-kick-' + sim.kickSerial.toString() +
          ' values=' + e.values.join(','))
      } else {
        kept.push(e)
      }
    }
    this.events = kept
  }

  /**
   * The box Component3D was laid out in, in vp, and px per vp. The world is framed again for it: the default camera fits
   * the box, and the program's stands back if the world no longer fits (worldCamera).
   */
  setSize(width: number, height: number, density: number): void {
    this.density = density > 0 ? density : 1
    if (Math.abs(width - this.width) < 1 && Math.abs(height - this.height) < 1) { return }
    this.width = width
    this.height = height
    if (this.applied !== null && this.cam !== null) { this.resetCamera(this.applied) } else { this.paintBackdrop() }
  }

  appeared(): void {
    this.shown = true
  }

  /** Its Component3D has gone: a retired box can now let the scene go. */
  disappeared(): void {
    this.shown = false
    if (this.retired) { this.destroy() }
  }

  /**
   * The world's node has left the tree. No more applies; the scene is destroyed once its Component3D has gone (or at
   * once if it never showed), so the kit is never asked to draw a scene that no longer exists.
   */
  retire(): void {
    if (this.retired || this.destroyed) { return }
    this.retired = true
    this.wanted = null
    this.events = []
    this.releasePhysics()
    if (!this.shown) {
      this.destroy()
      return
    }
    this.retireTimer = setTimeout(() => {
      this.retireTimer = -1
      this.destroy()
    }, RETIRE_MS)
  }

  /** Let the scene go. Safe to call twice; whatever is still in flight finds the box destroyed and touches nothing. */
  destroy(): void {
    if (this.destroyed) { return }
    this.destroyed = true
    this.retired = true
    this.releasePhysics()
    this.events = []
    if (this.retireTimer >= 0) {
      clearTimeout(this.retireTimer)
      this.retireTimer = -1
    }
    let scene = this.scene
    this.scene = null
    this.rf = null
    this.cam = null
    this.light = null
    this.env = null
    this.wanted = null
    this.showing = null
    this.showingMoves = false
    this.applied = null
    this.bodies.clear()
    this.byName.clear()
    this.partByName.clear()
    this.materials.clear()
    this.tableNodes = []
    this.floorNodes = []
    if (scene !== null) {
      try {
        scene.destroy()
      } catch (e) {
        console.warn('VERA-WORLD scene destroy failed: ' + (e as Error).message)
      }
    }
  }

  // ---------------------------------------------------------------- touch

  /** Whether a drag turns the camera: the page should not scroll under it then. */
  orbits(): boolean {
    return this.pose !== null && this.pose.orbit
  }

  /**
   * Whether the world keeps a drag that started on a body (it becomes a swipe), so the page does not scroll under it.
   */
  holdsDrag(): boolean {
    return this.tracking && this.downBody.length > 0
  }

  /**
   * A finger down at (x, y), in vp from the box's top left. A second finger while one is down starts a pinch when the
   * camera orbits, and is ignored otherwise. What it is on is guessed from the bodies on screen at once, and the
   * raycast's answer replaces the guess when it comes.
   */
  touchDown(finger: number, x: number, y: number, density: number): void {
    if (this.tracking) {
      if (finger !== this.finger && this.pinchFinger < 0) { this.startPinch(finger, x, y) }
      return
    }
    this.density = density > 0 ? density : 1
    this.finger = finger
    this.tracking = true
    this.moved = false
    this.downX = x
    this.downY = y
    this.lastX = x
    this.lastY = y
    this.downAt = Date.now()
    this.samples = [this.downAt, x, y]
    this.gesture++
    this.downBody = this.screenPick(x, y, DRAG_SLOP_VP)
    let gesture = this.gesture
    this.raycast(x, y).then((hit: WorldPick | null) => {
      if (hit !== null && hit.body.length > 0 && this.tracking && gesture === this.gesture && !this.moved) { this.downBody = hit.body }
    }).catch((e: Error) => {
      console.warn('VERA-WORLD pick failed: ' + e.message)
    })
  }

  /**
   * A finger moving: past the tap distance it is a drag. A drag on empty space turns the camera when the program's camera
   * orbits; one that started on a body is left alone until it lifts (a swipe).
   */
  touchMove(finger: number, x: number, y: number): void {
    if (!this.tracking) { return }
    if (this.pinchFinger >= 0) {
      this.movePinch(finger, x, y)
      return
    }
    if (finger !== this.finger) { return }
    if (!this.moved && Math.hypot(x - this.downX, y - this.downY) * this.density >= TAP_MOVE_PX) { this.moved = true }
    let now = Date.now()
    this.samples.push(now, x, y)
    while (this.samples.length > 3 && now - this.samples[0] > SWIPE_WINDOW_MS * 3) { this.samples.splice(0, 3) }
    if (this.moved && this.downBody.length === 0 && this.pose !== null && this.pose.orbit && this.cam !== null) {
      let pose = this.pose
      let grounded = this.applied !== null && (this.applied.floor !== null || this.applied.table !== null)
      pose.eye = orbitEye(pose.eye, pose.look, -(x - this.lastX) * DRAG_RAD_PER_VP, (y - this.lastY) * DRAG_RAD_PER_VP,
        grounded ? 0.05 : -1.45, 1.45)
      this.writeCamera()
    }
    this.lastX = x
    this.lastY = y
  }

  /**
   * The finger lifted: a tap (short and nearly still; the caller picks with it), a swipe of the body the drag started
   * on, or null for anything else (a camera turn, a long press).
   */
  touchUp(finger: number, x: number, y: number): WorldGesture | null {
    if (!this.tracking) { return null }
    if (this.pinchFinger >= 0) {
      // Either finger lifting ends the pinch, and the gesture with it: the one left down neither turns nor taps.
      if (finger === this.finger || finger === this.pinchFinger) {
        this.tracking = false
        this.pinchFinger = -1
      }
      return null
    }
    if (finger !== this.finger) { return null }
    this.tracking = false
    let now = Date.now()
    if (Math.hypot(x - this.downX, y - this.downY) * this.density >= TAP_MOVE_PX) { this.moved = true }
    if (!this.moved) {
      if (now - this.downAt >= TAP_MS) { return null }
      let tap = new WorldGesture()
      tap.kind = 'tap'
      return tap
    }
    let body = this.downBody
    let entry = this.bodies.get(body)
    let pose = this.pose
    if (body.length === 0 || entry === undefined || pose === null) { return null }
    this.samples.push(now, x, y)
    // The finger's velocity over the last SWIPE_WINDOW_MS (the whole drag if it was quicker than that).
    let from = 0
    while (from + 3 < this.samples.length - 3 && now - this.samples[from + 3] >= SWIPE_WINDOW_MS) { from += 3 }
    let last = this.samples.length - 3
    let ms = Math.max(1, this.samples[last] - this.samples[from])
    let dx = this.samples[last + 1] - this.samples[from + 1]
    let dy = this.samples[last + 2] - this.samples[from + 2]
    if (Math.hypot(dx, dy) < 1) {
      dx = x - this.downX
      dy = y - this.downY
      ms = Math.max(1, now - this.downAt)
    }
    let swipe = new WorldGesture()
    swipe.kind = 'swipe'
    swipe.body = body
    let dir = floorDirection(pose, dx, dy)
    swipe.x = dir[0]
    swipe.z = dir[2]
    let seen = projectPoint(pose, this.width, this.height, entry.pos)
    let depth = seen !== null ? seen[2] : Math.hypot(entry.pos[0] - pose.eye[0], entry.pos[1] - pose.eye[1], entry.pos[2] - pose.eye[2])
    let vpPerS = Math.hypot(dx, dy) * 1000 / ms
    swipe.speed = Math.max(0, Math.min(SWIPE_MAX, vpPerS * metresPerVp(pose, this.height, depth)))
    return swipe
  }

  touchCancel(): void {
    this.tracking = false
    this.pinchFinger = -1
    this.gesture++
  }

  /**
   * A second finger down: from now on the two fingers pinch. Spreading them brings the camera nearer along its line of
   * sight, closing them takes it back (pinchDistance), the direction it looks from kept; the gesture is no longer a tap,
   * a swipe or a turn. Only a camera the program lets the person move (orbit true) is pinched.
   */
  private startPinch(finger: number, x: number, y: number): void {
    let pose = this.pose
    if (pose === null || !pose.orbit || this.cam === null) { return }
    this.pinchFinger = finger
    this.pinchX = x
    this.pinchY = y
    this.pinchSpan = Math.hypot(x - this.lastX, y - this.lastY)
    let d = Math.hypot(pose.eye[0] - pose.look[0], pose.eye[1] - pose.look[1], pose.eye[2] - pose.look[2])
    this.pinchFrom = d
    if (this.framed <= 0) { this.framed = d }
    this.moved = true
    this.downBody = ''
    this.gesture++
  }

  private movePinch(finger: number, x: number, y: number): void {
    if (finger === this.finger) {
      this.lastX = x
      this.lastY = y
    } else if (finger === this.pinchFinger) {
      this.pinchX = x
      this.pinchY = y
    } else {
      return
    }
    let pose = this.pose
    if (pose === null) { return }
    let span = Math.hypot(this.pinchX - this.lastX, this.pinchY - this.lastY)
    zoomPose(pose, pinchDistance(this.pinchFrom, this.pinchSpan, span, this.framed), this.worldRadius)
    this.writeCamera()
  }

  /**
   * What is under (x, y), in vp from the box's top left: the body the ray hits, else the body nearest on screen within
   * TAP_SLOP_VP, else body "" with where the ray met the table or floor; null when there is no scene.
   */
  async pick(x: number, y: number): Promise<WorldPick | null> {
    let pick = await this.raycast(x, y)
    if (pick === null || pick.body.length > 0 || this.destroyed) { return pick }
    let near = this.screenPick(x, y, TAP_SLOP_VP)
    let entry = this.bodies.get(near)
    if (entry !== undefined) {
      pick.body = near
      pick.x = entry.pos[0]
      pick.y = entry.pos[1]
      pick.z = entry.pos[2]
    }
    return pick
  }

  private async raycast(x: number, y: number): Promise<WorldPick | null> {
    let cam = this.cam
    if (cam === null || this.destroyed || this.width <= 0 || this.height <= 0) { return null }
    let at: Vec2 = { x: x / this.width, y: y / this.height }
    let params: RaycastParameters = {}
    let hits: RaycastResult[] = await cam.raycast(at, params)
    if (this.destroyed) { return null }
    let pick = new WorldPick()
    if (hits.length > 0) {
      let hit = hits[0]
      pick.body = this.bodyOf(hit.node)
      pick.part = this.partOf(hit.node)
      pick.x = hit.hitPosition.x
      pick.y = hit.hitPosition.y
      pick.z = hit.hitPosition.z
    }
    return pick
  }

  /**
   * The body whose centre on screen is nearest (x, y), counting from the edge of its size on screen, if that is within
   * slop vp; '' if none is. Nearer the eye wins a tie.
   */
  private screenPick(x: number, y: number, slop: number): string {
    let pose = this.pose
    if (pose === null || this.width <= 0 || this.height <= 0) { return '' }
    let best = ''
    let bestGap = slop
    let bestDepth = Infinity
    this.bodies.forEach((entry: BodyNode, id: string) => {
      let seen = projectPoint(pose as CameraPose, this.width, this.height, entry.pos)
      if (seen === null) { return }
      let perVp = metresPerVp(pose as CameraPose, this.height, seen[2])
      let radius = perVp > 0 ? Math.max(entry.spec.dims[0], entry.spec.dims[1], entry.spec.dims[2]) / 2 / perVp : 0
      let gap = Math.max(0, Math.hypot(seen[0] - x, seen[1] - y) - radius)
      if (gap < bestGap || (gap === bestGap && gap <= slop && seen[2] < bestDepth)) {
        best = id
        bestGap = gap
        bestDepth = seen[2]
      }
    })
    return best
  }

  /** The group part a raycast hit belongs to ('' for none): the hit may be a node inside the part's, so look up the chain. */
  private partOf(node: Node | null): string {
    let at: Node | null = node
    let steps = 0
    while (at !== null && steps < 8) {
      let id = this.partByName.get(at.name)
      if (id !== undefined) { return id }
      at = at.parent
      steps++
    }
    return ''
  }

  private bodyOf(node: Node | null): string {
    let at: Node | null = node
    let steps = 0
    while (at !== null && steps < 8) {
      let id = this.byName.get(at.name)
      if (id !== undefined) { return id }
      at = at.parent
      steps++
    }
    return ''
  }

  // ---------------------------------------------------------------- applying

  private pump(): void {
    if (this.running) { return }
    this.running = true
    let failed = false
    this.run().catch((e: Error) => {
      failed = true
      if (!this.destroyed) { console.error('VERA-WORLD apply failed: ' + e.message) }
    }).finally(() => {
      this.running = false
      // A spec asked for between run() finishing and this callback found the box still running and only left itself in
      // `wanted`: apply it now rather than leave the world (and a throw's kick) behind until the next state change. Not
      // after a failure, which would only fail again, at once and for ever.
      if (!failed && !this.destroyed && !this.retired && this.wanted !== null && this.wantedTheme !== null &&
          (this.wanted !== this.applied || this.wantedTheme !== this.appliedTheme)) {
        this.pump()
      }
    })
  }

  private async run(): Promise<void> {
    if (this.scene === null && !(await this.create())) { return }
    while (!this.destroyed && this.wanted !== null && this.wantedTheme !== null &&
        (this.wanted !== this.applied || this.wantedTheme !== this.appliedTheme)) {
      await this.applyOne(this.wanted as WorldSpec, this.wantedTheme as ResolvedTheme)
    }
  }

  /** The scene, its camera, sun and environment: look B. False when the box was destroyed while they were made. */
  private async create(): Promise<boolean> {
    let scene = await Scene.load()
    if (this.destroyed) {
      scene.destroy()
      return false
    }
    this.scene = scene
    let rf = scene.getResourceFactory()
    this.rf = rf
    let cam = await rf.createCamera({ name: 'cam' })
    if (this.destroyed) { return false }
    cam.enabled = true
    cam.fov = LOOK_FOV
    // {} and not null: null still tone-maps, and the colours would no longer be the theme's.
    let pp: PostProcessSettings = {}
    cam.postProcess = pp
    this.cam = cam
    let env = await rf.createEnvironment({ name: 'env' })
    if (this.destroyed) { return false }
    env.backgroundType = EnvironmentBackgroundType.BACKGROUND_NONE
    let amb: Vec4 = { x: LOOK_AMBIENT, y: LOOK_AMBIENT, z: LOOK_AMBIENT, w: 1 }
    env.indirectDiffuseFactor = amb
    env.indirectSpecularFactor = amb
    scene.environment = env
    this.env = env
    let light = await rf.createLight({ name: 'sun' }, LightType.DIRECTIONAL)
    if (this.destroyed) { return false }
    light.position = v3(LOOK_SUN_POSITION[0], LOOK_SUN_POSITION[1], LOOK_SUN_POSITION[2])
    light.rotation = quat(lookAtQuat(LOOK_SUN_POSITION, LOOK_SUN_TARGET, [0, 1, 0]))
    light.intensity = LOOK_SUN_INTENSITY
    light.shadowEnabled = LOOK_SHADOWS
    this.light = light
    let opt: SceneOptions = { scene: scene, modelType: ModelType.SURFACE }
    this.options = opt
    return true
  }

  private async applyOne(next: WorldSpec, theme: ResolvedTheme): Promise<void> {
    let prev = this.applied
    // A new period goes on from where each body is now, not from where the new period alone would put it.
    if (next !== prev) { this.carry.apply(next, this.timeS) }
    let diff: WorldDiff = diffWorld(prev, next)
    let themeChanged = theme !== this.appliedTheme
    this.applyPhysics(prev, diff, next)
    let glows = worldGlows(next)
    let glowsChanged = glows !== this.glows
    let backdrop = worldHasBackdrop(next)
    let backdropChanged = backdrop !== this.backdropOn
    this.backdropOn = backdrop
    this.dark = isDarkRgba(worldBackgroundRgba(next, theme))
    if (glows && !this.spotsMade) {
      await this.makeSpots()
      if (this.destroyed) { return }
    }
    if (glowsChanged) {
      this.glows = glows
      this.writeLight()
    }
    if (backdropChanged && !themeChanged) { this.writeBackground(theme) }
    this.showing = next
    this.showingMoves = hasKinematic(next)
    if (themeChanged) {
      // Materials are by the colour a role comes out as; a new theme makes them again.
      this.materials.clear()
      this.writeBackground(theme)
    }
    for (let id of diff.remove) { this.removeBody(id) }
    let creating: BodySpec[] = []
    for (let b of diff.recreate) {
      this.removeBody(b.id)
      creating.push(b)
    }
    for (let b of diff.create) { creating.push(b) }
    // Every body still here takes the spec it now has (orbits, spins and later physics read it).
    let fresh = new Set<string>()
    for (let b of creating) { fresh.add(b.id) }
    for (let b of next.bodies) {
      let known = this.bodies.get(b.id)
      if (known !== undefined && !fresh.has(b.id)) { known.spec = b }
    }
    let recolour: BodySpec[] = themeChanged ? next.bodies.filter((b: BodySpec): boolean => !fresh.has(b.id)) : diff.material
    for (let b of recolour) {
      let known = this.bodies.get(b.id)
      // A painted ball's colours are its mesh's (diffWorld makes it again when they change).
      if (known === undefined || (b.shape === 'sphere' && b.pattern.length > 0)) { continue }
      if (known.parts.length > 0) {
        // A group: each part its own colour (a painted part's are its mesh's); the group's node itself draws nothing.
        for (let k = 0; k < known.parts.length; k++) {
          let part = known.partSpecs[k]
          if (part.shape === 'sphere' && part.pattern.length > 0) { continue }
          let partMaterial = await this.material(part.color, b.glow, theme, 'ink')
          if (this.destroyed) { return }
          this.paint(known.parts[k], partMaterial)
        }
        continue
      }
      let material = await this.material(b.color, b.glow, theme, 'ink')
      if (this.destroyed) { return }
      this.paint(known.node, material)
      if (themeChanged && known.pips.length > 0) {
        let pipMaterial = await this.material('', false, theme, LOOK_PIP_ROLE)
        if (this.destroyed) { return }
        for (let pip of known.pips) { this.paint(pip, pipMaterial) }
      }
    }
    for (let b of diff.setPose) {
      let known = this.bodies.get(b.id)
      if (known !== undefined) { this.place(known, b) }
    }
    if (diff.tableChanged || diff.floorChanged || themeChanged || glowsChanged) {
      await this.buildGround(next, theme, diff.tableChanged || themeChanged, diff.floorChanged || themeChanged || glowsChanged)
      if (this.destroyed) { return }
    }
    let reframe = prev === null || diff.cameraChanged || (next.camera === null &&
      (creating.length > 0 || diff.remove.length > 0 || diff.setPose.length > 0 || diff.tableChanged))
    if (reframe) { this.resetCamera(next) }
    for (let i = 0; i < creating.length; i += BATCH) {
      let batch = creating.slice(i, i + BATCH)
      await Promise.all(batch.map((b: BodySpec): Promise<void> => this.createBody(b, theme)))
      if (this.destroyed) { return }
      this.writeKinematic()
      if (i + BATCH < creating.length) {
        await nextFrame()
        if (this.destroyed) { return }
      }
    }
    this.applied = next
    this.appliedTheme = theme
    this.writeKinematic()
    // A glowing body moved or came, a trail or the sky changed: the light and the backdrop follow the world as applied.
    if (this.glows) { this.writeLight() }
    if (this.backdropOn || backdropChanged || diff.backdropChanged || themeChanged) { this.paintBackdrop() }
  }

  private writeBackground(theme: ResolvedTheme): void {
    if (this.cam === null) { return }
    // With a backdrop the scene is see-through and the canvas under it paints the sky, its stars, the trails and the halos,
    // so the bodies hide them; otherwise the scene clears to the theme's background itself.
    let c = lookLinear(theme, LOOK_BACKGROUND_ROLE, LOOK_BACKGROUND_ROLE)
    let on = this.backdropOn
    let clear: Color = { r: on ? 0 : c[0], g: on ? 0 : c[1], b: on ? 0 : c[2], a: on ? 0 : 1 }
    this.cam.clearColor = clear
  }

  /** The material for a colour, made once per colour (and glow) and shared by every body in it. */
  private material(color: string, glow: boolean, theme: ResolvedTheme, fallbackRole: string): Promise<Material> {
    let key = lookColorKey(theme, color, glow, fallbackRole)
    let known = this.materials.get(key)
    if (known !== undefined) { return known }
    let made = this.makeMaterial(key, lookLinear(theme, color, fallbackRole), glow, false)
    this.materials.set(key, made)
    return made
  }

  /** The table's and the floor's: as material(), but shadows fall on it. */
  private groundMaterial(color: string, theme: ResolvedTheme, fallbackRole: string): Promise<Material> {
    let key = 'ground:' + lookColorKey(theme, color, false, fallbackRole)
    let known = this.materials.get(key)
    if (known !== undefined) { return known }
    let made = this.makeMaterial(key, lookLinear(theme, color, fallbackRole), false, true)
    this.materials.set(key, made)
    return made
  }

  private async makeMaterial(name: string, linear: number[], glow: boolean, receiver: boolean): Promise<Material> {
    let rf = this.rf as SceneResourceFactory
    if (glow) {
      // A glowing body is drawn in its own colour whatever the light: unlit.
      let unlit = await rf.createMaterial({ name: name }, MaterialType.UNLIT) as UnlitMaterial
      unlit.baseColor.factor = vec4(linear)
      return unlit
    }
    let m = await rf.createMaterial({ name: name }, MaterialType.METALLIC_ROUGHNESS) as MetallicRoughnessMaterial
    m.baseColor.factor = vec4(linear)
    if (receiver) { m.shadowReceiver = true }
    return m
  }

  private paint(node: Node, material: Material): void {
    let subMeshes = (node as Geometry).mesh.subMeshes
    if (subMeshes.length > 0) { subMeshes[0].material = material }
  }

  private place(entry: BodyNode, b: BodySpec): void {
    entry.node.position = v3(b.position[0], b.position[1], b.position[2])
    entry.node.rotation = quat(quatXYZ(b.rotation[0], b.rotation[1], b.rotation[2]))
    entry.pos = [b.position[0], b.position[1], b.position[2]]
  }

  /** A node of its own mesh. Meshes are not shared: the material is set on the mesh, and that is only proven per node. */
  private async node(rf: SceneResourceFactory, name: string, geometry: GeometryDefinition, material: Material): Promise<Geometry> {
    let mesh: MeshResource = await rf.createMesh({ name: name + 'm' }, geometry)
    let node = await rf.createGeometry({ name: name }, mesh)
    node.mesh.subMeshes[0].material = material
    return node
  }

  private shapeOf(b: BodySpec): GeometryDefinition {
    if (b.shape === 'shape' || b.shape === 'hull') { return shapedGeometry(b) }
    if (b.shape === 'sphere') {
      let s = new SphereGeometry()
      s.radius = b.dims[0] / 2
      s.segmentCount = 32
      return s
    }
    if (b.shape === 'cylinder') {
      let c = new CylinderGeometry()
      c.radius = b.dims[0] / 2
      c.height = b.dims[1]
      c.segmentCount = 32
      return c
    }
    let box = new CubeGeometry()
    box.size = v3(b.dims[0], b.dims[1], b.dims[2])
    return box
  }

  private async createBody(b: BodySpec, theme: ResolvedTheme): Promise<void> {
    let rf = this.rf
    if (rf === null || this.destroyed) { return }
    if (b.shape === 'group') {
      await this.createGroup(rf, b, theme)
      return
    }
    this.serial++
    let name = 'b' + this.serial.toString()
    // A painted ball carries its colours in its vertices, under a white material; anything else is one colour.
    let painted = b.shape === 'sphere' && b.pattern.length > 0
    let material = painted ? await this.vertexMaterial(b.glow) : await this.material(b.color, b.glow, theme, 'ink')
    if (this.destroyed) { return }
    let geometry: GeometryDefinition = painted ? paintedGeometry(b, theme) : this.shapeOf(b)
    let node = await this.node(rf, name, geometry, material)
    if (this.destroyed) { return }
    let entry = new BodyNode(b, node)
    this.place(entry, b)
    // A loose body may have moved in the physics while its node was being made.
    let at = b.motion === 'loose' && this.sim !== null ? this.sim.poseOf(b.id) : null
    if (at !== null) {
      node.position = v3(at[0], at[1], at[2])
      node.rotation = quat([at[3], at[4], at[5], at[6]])
      entry.pos = [at[0], at[1], at[2]]
    }
    entry.names.push(name)
    this.bodies.set(b.id, entry)
    this.byName.set(name, b.id)
    if (b.isDie) { await this.addPips(rf, entry, theme) }
    await this.addMarks(rf, entry, b, theme)
  }

  /**
   * A scene.group: an empty node where the group stands, and each part a node of its own under it, placed and turned
   * about the group's centre, in its own colour. Every node's name leads a tap to the group, and a part's to the part.
   */
  private async createGroup(rf: SceneResourceFactory, b: BodySpec, theme: ResolvedTheme): Promise<void> {
    this.serial++
    let name = 'b' + this.serial.toString()
    let parent = await rf.createNode({ name: name })
    if (this.destroyed) { return }
    let entry = new BodyNode(b, parent)
    this.place(entry, b)
    let at = b.motion === 'loose' && this.sim !== null ? this.sim.poseOf(b.id) : null
    if (at !== null) {
      parent.position = v3(at[0], at[1], at[2])
      parent.rotation = quat([at[3], at[4], at[5], at[6]])
      entry.pos = [at[0], at[1], at[2]]
    }
    entry.names.push(name)
    this.bodies.set(b.id, entry)
    this.byName.set(name, b.id)
    for (let p of b.parts) {
      let painted = p.shape === 'sphere' && p.pattern.length > 0
      let material = painted ? await this.vertexMaterial(b.glow) : await this.material(p.color, b.glow, theme, 'ink')
      if (this.destroyed) { return }
      this.serial++
      let partName = 'b' + this.serial.toString()
      let node = await this.node(rf, partName, painted ? paintedGeometry(p, theme) : this.shapeOf(p), material)
      if (this.destroyed) { return }
      if (this.bodies.get(b.id) !== entry) {
        this.removeNode(node)
        return
      }
      node.position = v3(p.position[0], p.position[1], p.position[2])
      node.rotation = quat(quatXYZ(p.rotation[0], p.rotation[1], p.rotation[2]))
      parent.children.append(node)
      entry.parts.push(node)
      entry.partSpecs.push(p)
      entry.names.push(partName)
      this.byName.set(partName, b.id)
      this.partByName.set(partName, p.id)
    }
    await this.addMarks(rf, entry, b, theme)
  }

  /** A body's rings and selection mark, as rings under its node. */
  private async addMarks(rf: SceneResourceFactory, entry: BodyNode, b: BodySpec, theme: ResolvedTheme): Promise<void> {
    if (b.rings.length === 2) {
      await this.addRing(rf, entry, flatRing(b.rings[0], b.rings[1], lookRgba(theme, b.ringColor, 'surface'), 1, surfaceSeed(b.id)))
    }
    if (b.mark.length > 0) {
      let r = Math.max(b.dims[0], b.dims[1], b.dims[2]) / 2
      let out = b.rings.length === 2 ? b.rings[1] : r
      // Wide enough to see round a small planet: at least 3 cm of ring, a little way out from it.
      let inner = out * 1.25
      await this.addRing(rf, entry, flatRing(inner, inner + Math.max(0.03, out * 0.3), lookRgba(theme, b.mark, 'accent'), 0, 0))
    }
  }

  /** A ring as a child of its body, so it goes, tilts and turns with it: unlit, so its colour holds edge-on to the sun. */
  private async addRing(rf: SceneResourceFactory, entry: BodyNode, mesh: SurfaceMesh): Promise<void> {
    let material = await this.vertexMaterial(true)
    if (this.destroyed) { return }
    this.serial++
    let ring = await this.node(rf, 'r' + this.serial.toString(), customGeometry(mesh), material)
    if (this.destroyed || this.bodies.get(entry.spec.id) !== entry) { return }
    entry.node.children.append(ring)
    entry.names.push(ring.name)
    this.byName.set(ring.name, entry.spec.id)
  }

  /** The white material a vertex-coloured mesh is drawn with: lit, or unlit for a glowing ball and for rings. */
  private vertexMaterial(unlit: boolean): Promise<Material> {
    let key = unlit ? 'vertex:unlit' : 'vertex:lit'
    let known = this.materials.get(key)
    if (known !== undefined) { return known }
    let made = this.makeMaterial(key, [1, 1, 1, 1], unlit, false)
    this.materials.set(key, made)
    return made
  }

  /** Small dark spheres on the die's faces, children of it, so they turn with it. Faces as pipLayout. */
  private async addPips(rf: SceneResourceFactory, entry: BodyNode, theme: ResolvedTheme): Promise<void> {
    let half = entry.spec.dims[0] / 2
    let material = await this.material('', false, theme, LOOK_PIP_ROLE)
    if (this.destroyed) { return }
    let made: Promise<Geometry>[] = []
    let layout = pipLayout(half)
    for (let i = 0; i < layout.length; i++) {
      this.serial++
      let s = new SphereGeometry()
      s.radius = half * PIP_RADIUS
      s.segmentCount = 12
      made.push(this.node(rf, 'p' + this.serial.toString(), s, material))
    }
    let pips = await Promise.all(made)
    if (this.destroyed || this.bodies.get(entry.spec.id) !== entry) { return }
    for (let i = 0; i < pips.length; i++) {
      let pip = pips[i]
      pip.position = v3(layout[i][1], layout[i][2], layout[i][3])
      entry.node.children.append(pip)
      entry.pips.push(pip)
      entry.names.push(pip.name)
      this.byName.set(pip.name, entry.spec.id)
    }
  }

  private removeBody(id: string): void {
    let entry = this.bodies.get(id)
    if (entry === undefined) { return }
    this.bodies.delete(id)
    for (let name of entry.names) {
      this.byName.delete(name)
      this.partByName.delete(name)
    }
    this.removeNode(entry.node)
  }

  private removeNode(node: Node): void {
    let root = this.scene !== null ? this.scene.root : null
    try {
      if (root !== null) { root.children.remove(node) }
      node.destroy()
    } catch (e) {
      console.warn('VERA-WORLD remove failed: ' + (e as Error).message)
    }
  }

  /** The table (top and walls) and the floor, made again when they change. Shadows fall on the table, and on the floor through its shadow layer. */
  private async buildGround(spec: WorldSpec, theme: ResolvedTheme, table: boolean, floor: boolean): Promise<void> {
    let rf = this.rf
    if (rf === null) { return }
    if (table) {
      for (let n of this.tableNodes) { this.removeNode(n) }
      this.tableNodes = []
      let tableSpec = spec.table
      if (tableSpec !== null) {
        let material = await this.groundMaterial(tableSpec.color, theme, LOOK_TABLE_ROLE)
        if (this.destroyed) { return }
        let parts = tableParts(tableSpec)
        for (let part of parts) {
          this.serial++
          let box = new CubeGeometry()
          box.size = v3(part[3], part[4], part[5])
          let node = await this.node(rf, 't' + this.serial.toString(), box, material)
          if (this.destroyed) { return }
          node.position = v3(part[0], part[1], part[2])
          this.tableNodes.push(node)
        }
      }
    }
    if (floor) {
      for (let n of this.floorNodes) { this.removeNode(n) }
      this.floorNodes = []
      let floorSpec = spec.floor
      if (floorSpec !== null) {
        let material = await this.floorMaterial(floorSpec.color, theme)
        if (this.destroyed) { return }
        let plane = new PlaneGeometry()
        let size = floorSize(spec)
        let extent: Vec2 = { x: size, y: size }
        plane.size = extent
        this.serial++
        let node = await this.node(rf, 'f' + this.serial.toString(), plane, material)
        if (this.destroyed) { return }
        // Under a table the floor is where the table's top slab ends, so the two never fight over y = 0.
        let floorY = spec.table !== null ? -TABLE_TOP_THICKNESS : 0
        node.position = v3(0, floorY, 0)
        this.floorNodes.push(node)
      }
    }
  }

  /**
   * The floor: one lit, matte, non-metallic plane that receives shadows. Its base colour is the colour wanted over the
   * light's gain (see FLOOR_LIGHT_GAIN), so lit it comes out as the colour wanted.
   */
  private async floorMaterial(color: string, theme: ResolvedTheme): Promise<Material> {
    let rf = this.rf as SceneResourceFactory
    let gain = floorGain(this.glows)
    let base = floorBaseLinear(theme, color, gain)
    console.info('VERA-WORLD floor lit gain=' + gain.toString() + ' base=' + linearHex(base) + ' target=' + floorColor(theme, color))
    this.serial++
    let m = await rf.createMaterial({ name: 'floor' + this.serial.toString() }, MaterialType.METALLIC_ROUGHNESS) as MetallicRoughnessMaterial
    m.baseColor.factor = vec4(base)
    // material.factor: y roughness, z metallic, w reflectance (SceneResources.d.ts); specular.factor.w is the specular intensity.
    let mat: Vec4 = { x: m.material.factor.x, y: FLOOR_ROUGHNESS, z: FLOOR_METALLIC, w: m.material.factor.w }
    m.material.factor = mat
    let spec: Vec4 = { x: m.specular.factor.x, y: m.specular.factor.y, z: m.specular.factor.z, w: FLOOR_SPECULAR }
    m.specular.factor = spec
    m.shadowReceiver = true
    return m
  }

  // ---------------------------------------------------------------- camera and motion

  private resetCamera(spec: WorldSpec): void {
    let pose = worldCamera(spec, this.height > 0 ? this.width / this.height : 1)
    this.pose = pose
    this.framed = Math.hypot(pose.eye[0] - pose.look[0], pose.eye[1] - pose.look[1], pose.eye[2] - pose.look[2])
    let bounds = worldBounds(spec)
    this.worldRadius = bounds !== null ? bounds[3] : 1
    this.writeCamera()
  }

  private writeCamera(): void {
    let cam = this.cam
    let pose = this.pose
    if (cam === null || pose === null) { return }
    cam.position = v3(pose.eye[0], pose.eye[1], pose.eye[2])
    cam.rotation = quat(lookAtQuat(pose.eye, pose.look, [0, 1, 0]))
    cam.nearPlane = pose.near
    cam.farPlane = pose.far
    // The sun keeps its place beside the camera, so shadows stay in view as the camera turns.
    this.writeLight()
    this.paintBackdrop()
  }

  /** A glowing body's spot lights, off until writeLight puts them in one. Without shadows: six shadow maps would cost the frame. */
  private async makeSpots(): Promise<void> {
    this.spotsMade = true
    let rf = this.rf
    if (rf === null) { return }
    for (let k = 0; k < GLOW_SPOTS; k++) {
      let light = await rf.createLight({ name: 'glowspot' + k.toString() }, LightType.SPOT)
      if (this.destroyed) { return }
      let spot = light as SpotLight
      spot.innerAngle = GLOW_SPOT_INNER
      spot.outerAngle = GLOW_SPOT_OUTER
      spot.shadowEnabled = false
      spot.enabled = false
      spot.intensity = 0
      this.spots.push(spot)
    }
  }

  /** The backdrop canvas is on screen and can be painted. */
  backdropShown(): void {
    this.backdropReady = true
    this.paintBackdrop()
  }

  /**
   * What is behind the world, under the scene: the background (the sky's colour, else the theme's), the sky's stars (each
   * a direction, drawn where it lands far off, so they wheel with the camera and never move with the bodies), the trails
   * (faint, so a body crossing one still reads) and a halo round each glowing body that stands still. Cleared and left
   * empty when there is none of that, where the scene clears to the background itself.
   */
  paintBackdrop(): void {
    if (!this.backdropReady || this.width <= 0 || this.height <= 0) { return }
    let ctx = this.backdrop
    ctx.clearRect(0, 0, this.width, this.height)
    let spec = this.applied !== null ? this.applied : this.showing
    let pose = this.pose
    let theme = this.appliedTheme !== null ? this.appliedTheme : this.wantedTheme
    if (!this.backdropOn || spec === null || pose === null || theme === null) { return }
    let w = this.width
    let h = this.height
    let bg = worldBackgroundRgba(spec, theme)
    ctx.globalAlpha = 1
    ctx.fillStyle = 'rgb(' + Math.round(bg[0] * 255).toString() + ', ' + Math.round(bg[1] * 255).toString() + ', ' +
      Math.round(bg[2] * 255).toString() + ')'
    ctx.fillRect(0, 0, w, h)
    let sky = spec.sky
    let stars: number[][] = sky !== null && sky.stars > 0 ? starsOf(sky.stars) : []
    for (let star of stars) {
      let p = [pose.eye[0] + star[0] * STAR_DISTANCE, pose.eye[1] + star[1] * STAR_DISTANCE, pose.eye[2] + star[2] * STAR_DISTANCE]
      let at = projectPoint(pose, w, h, p)
      if (at === null || at[0] < 0 || at[1] < 0 || at[0] > w || at[1] > h) { continue }
      ctx.globalAlpha = star[3]
      ctx.fillStyle = '#ffffff'
      ctx.beginPath()
      ctx.arc(at[0], at[1], 0.35 + star[4] * star[3] * 1.0, 0, 2 * Math.PI)
      ctx.fill()
    }
    ctx.globalAlpha = 1
    ctx.strokeStyle = this.dark ? 'rgba(190, 205, 255, 0.22)' : 'rgba(40, 50, 80, 0.22)'
    ctx.lineWidth = 1
    for (let ring of worldTrails(spec)) {
      ctx.beginPath()
      let open = false
      for (let i = 0; i <= TRAIL_POINTS; i++) {
        let a = 2 * Math.PI * i / TRAIL_POINTS
        let at = projectPoint(pose, w, h, [ring[0] + ring[3] * Math.cos(a), ring[1], ring[2] - ring[3] * Math.sin(a)])
        if (at === null) {
          open = false
          continue
        }
        if (open) { ctx.lineTo(at[0], at[1]) } else { ctx.moveTo(at[0], at[1]) }
        open = true
      }
      ctx.stroke()
    }
    for (let sun of worldSuns(spec)) {
      let at = projectPoint(pose, w, h, [sun[0], sun[1], sun[2]])
      if (at === null) { continue }
      let r = sun[3] / Math.max(1e-6, metresPerVp(pose, h, at[2]))
      let halo = ctx.createRadialGradient(at[0], at[1], r * 0.85, at[0], at[1], r * HALO_SCALE)
      halo.addColorStop(0, 'rgba(255, 214, 120, 0.55)')
      halo.addColorStop(0.35, 'rgba(255, 190, 90, 0.18)')
      halo.addColorStop(1, 'rgba(255, 170, 60, 0)')
      ctx.fillStyle = halo
      ctx.beginPath()
      ctx.arc(at[0], at[1], r * HALO_SCALE, 0, 2 * Math.PI)
      ctx.fill()
    }
  }

  /**
   * The light: the spots of a glowing body that stands still, or else look B's sun beside the camera.
   */
  private writeLight(): void {
    let light = this.light
    let env = this.env
    if (light === null || env === null) { return }
    // A glowing body that stands still is the light: its spots shine out all round from where it is, so each body has a
    // side towards it and a side away, and look B's sun is off. Wherever it is -- a sun among planets, a lamp over a table.
    let spec = this.applied !== null ? this.applied : this.showing
    let suns = spec !== null ? worldSuns(spec) : []
    let fromGlow = suns.length > 0 && this.spots.length > 0
    let candela = fromGlow && spec !== null ? glowCandela(spec, suns[0]) : 0
    for (let k = 0; k < this.spots.length; k++) {
      let spot = this.spots[k]
      spot.enabled = fromGlow
      spot.intensity = candela
      if (!fromGlow) { continue }
      let at = suns[0]
      // Four level, one down, one up.
      let a = k * Math.PI / 2
      let target = k < 4 ? [at[0] + Math.cos(a), at[1], at[2] + Math.sin(a)] : [at[0], at[1] + (k === 4 ? -1 : 1), at[2]]
      spot.position = v3(at[0], at[1], at[2])
      spot.rotation = quat(lookAtQuat([at[0], at[1], at[2]], target, [0, 1, 0]))
    }
    light.enabled = !fromGlow
    light.intensity = fromGlow ? 0 : LOOK_SUN_INTENSITY
    let ambient = fromGlow ? GLOW_AMBIENT : LOOK_AMBIENT
    let amb: Vec4 = { x: ambient, y: ambient, z: ambient, w: 1 }
    env.indirectDiffuseFactor = amb
    env.indirectSpecularFactor = amb
    if (fromGlow) { return }
    let pose = this.pose
    if (pose !== null) {
      let sun = sunFor(pose.eye, pose.look)
      light.position = v3(sun[0], sun[1], sun[2])
      light.rotation = quat(lookAtQuat(sun, pose.look, [0, 1, 0]))
    } else {
      light.position = v3(LOOK_SUN_POSITION[0], LOOK_SUN_POSITION[1], LOOK_SUN_POSITION[2])
      light.rotation = quat(lookAtQuat(LOOK_SUN_POSITION, LOOK_SUN_TARGET, [0, 1, 0]))
    }
  }

  /** Orbiting and spinning bodies where they are at the box's own time (which stands still while the loop does). */
  private writeKinematic(): void {
    let spec = this.showing
    if (spec === null || !this.showingMoves || this.bodies.size === 0 || this.destroyed) { return }
    let t0 = Date.now()
    let poses = orbitPositions(spec, this.timeS)
    poses.forEach((p: number[], id: string) => {
      let entry = this.bodies.get(id)
      if (entry === undefined) { return }
      entry.node.position = v3(p[0], p[1], p[2])
      entry.node.rotation = quat(quatXYZ(p[3], p[4], p[5]))
      entry.pos[0] = p[0]
      entry.pos[1] = p[1]
      entry.pos[2] = p[2]
    })
    this.writeMs += Date.now() - t0
    this.frames++
  }
}
