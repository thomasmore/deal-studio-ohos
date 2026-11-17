/**
 * A first play of a program built on a ui.World, before it is served: the smoke run (VeraSmoke.ets) builds the world once
 * and sends one tap on empty space, which says nothing about a 3D app -- whether the camera sees anything, whether bodies
 * start inside one another or under the floor, whether the dice ever settle and the program reads what they show. So
 * this plays it the way a person tries it, on the host's physics (FakePhys and WorldSim, VeraPhysics.ets), the way the
 * phone runs it (VeraPreview's world branch): build on every change of state, the diff applied, ten seconds of frames, a
 * tap on bodies, a swipe of each loose one, a tap on empty space, each button pressed, and what the world tells (hits,
 * settling) handed to the event handler, at most four a frame.
 *
 * What it reports goes back to the model as a repair, in the smoke run's form ("line:col CODE message"), so only what is
 * wrong whatever the person does counts. Pure: no platform kit.
 */

import { VirtualMachine, deserializeVbc2, RuntimeValue, RuntimeTrap, VeraNumberValue, BytecodeModule,
  encodeRuntimeValue } from './VeraInterpreter'
import { UiHostEnvironment, decodeVeraUi, VeraUiNode } from './VeraUi'
import { CompileResult } from './VeraCompiler'
import { WorldSpec, BodySpec, TableSpec, CameraSpec, WorldDiff, ZoneSpec, ScenePlayer, decodeScene, diffWorld, orbitPositions,
  sceneEventValue, MotionCarry, SceneOrbit } from './VeraScene'
import { ZoneWatch } from './VeraLocomotion'
import { FakePhys, WorldSim, SimEvent, specBounds, enterEvent } from './VeraPhysics'
import { worldCamera, projectPoint, metresPerVp, floorDirection, CameraPose } from './VeraLook3D'
import { functionLine, worldBudgetProblem, predictWorkMs } from './VeraBudget'

/** Frames played: ten seconds at 60 a second, enough for a throw to settle (FakePhys settles within 8 s). */
export const WORLD_PLAY_FRAMES: number = 600
const WORLD_STEP_MS: number = 16
/** What the world tells the program each frame, at most (VeraPreview's WORLD_EVENTS_PER_FRAME); the rest waits. */
const EVENTS_PER_FRAME: number = 4
/** Bodies tapped and loose bodies swiped, at most: spread over the world, so a wall of a hundred cubes is not a hundred rebuilds. */
const TAPPED_BODIES: number = 24
const SWIPED_BODIES: number = 12
const PRESSED_BUTTONS: number = 6

/** The repair codes of a world's play (P0001, too slow, is VeraBudget's). */
export const CODE_NOT_SEEN: string = 'P0002'
export const CODE_OVERLAP: string = 'P0003'
export const CODE_OUT_OF_WORLD: string = 'P0004'
export const CODE_STILL: string = 'P0005'
export const CODE_NO_SETTLE: string = 'P0006'
export const CODE_RESULT_UNREAD: string = 'P0007'
export const CODE_NO_WORLD: string = 'P0008'
export const CODE_ORBITS_CROSS: string = 'P0009'
export const CODE_TOO_SMALL: string = 'P0010'
export const CODE_STUCK: string = 'P0011'
export const CODE_WALKS_THROUGH: string = 'P0012'
export const CODE_ZONE_UNREACHABLE: string = 'P0013'
export const CODE_NO_TRAVEL: string = 'P0014'
/** The stick is held this many frames ahead, then this many to the right, from STICK_FROM; the player must go this share of its speed's reach. */
const STICK_FROM: number = 30
const STICK_AHEAD: number = 120
const STICK_RIGHT: number = 60
const STICK_MIN_SHARE: number = 0.25
/** A body that walks by itself is sampled this often (s), for this long, against what stands in its way. */
const WALK_SAMPLE_S: number = 0.25
const WALK_SAMPLE_FOR_S: number = 60
/** A body standing no higher than this share of a walker's height is stepped over (grass, a stone, a mark on the ground). */
const STEP_OVER: number = 0.3

/**
 * What the request says should travel, as the design names it: 'none' (nothing asked), 'self' (something walks, runs or
 * drives by itself), 'steered' (the person steers something), 'both'.
 */
export const TRAVEL_KINDS: string[] = ['none', 'self', 'steered', 'both']
/** The biggest body the person plays with or watches is at least this many vp across as the world starts, or it is a speck. */
export const MIN_BODY_VP: number = 12

/** The box the world is seen in on a phone about 360 vp wide: square by default, its height when given, tall when it fills, the whole screen when full. */
function boxSize(node: VeraUiNode): number[] {
  if (node.style === 'full') { return [360, 720] }
  if (node.style === 'fill') { return [360, 560] }
  return [360, node.minimum > 0 ? node.minimum : 360]
}

function findWorld(node: VeraUiNode): VeraUiNode | null {
  if (node.kind === 'world') { return node }
  for (let child of node.children) {
    let found = findWorld(child)
    if (found !== null) { return found }
  }
  return null
}

function buttonsIn(node: VeraUiNode, out: VeraUiNode[]): VeraUiNode[] {
  if (node.kind === 'button' && node.enabled && node.action.length > 0) { out.push(node) }
  for (let child of node.children) { buttonsIn(child, out) }
  return out
}

/** Every `step`-th of `items`, at most `most` of them, spread from the first to the last. */
function spread<T>(items: T[], most: number): T[] {
  if (items.length <= most) { return items.slice() }
  let out: T[] = []
  for (let k = 0; k < most; k++) { out.push(items[Math.floor(k * items.length / most)]) }
  return out
}

function fingerprint(state: RuntimeValue): string {
  return JSON.stringify(encodeRuntimeValue(state))
}

/** A body's half size along x, y, z, ignoring its turn: for whether it can be seen. */
function radiusOf(b: BodySpec): number {
  return Math.sqrt(b.dims[0] * b.dims[0] + b.dims[1] * b.dims[1] + b.dims[2] * b.dims[2]) / 2
}

/** How far a body reaches across from its centre, seen from above: a ball its radius, rings to their outer edge. */
function flatReach(b: BodySpec): number {
  let own = b.shape === 'sphere' ? b.dims[0] / 2 : Math.sqrt(b.dims[0] * b.dims[0] + b.dims[2] * b.dims[2]) / 2
  return b.rings.length === 2 ? Math.max(own, b.rings[1]) : own
}

/** flatReach, or further when something orbits the body: a planet with a moon reaches to the moon's far side. */
function orbitReach(b: BodySpec, byCentre: Map<string, BodySpec[]>, depth: number): number {
  let r = flatReach(b)
  let around = byCentre.get(b.id)
  if (around !== undefined && depth < 4) {
    for (let m of around) { r = Math.max(r, (m.orbit as SceneOrbit).radius + orbitReach(m, byCentre, depth + 1)) }
  }
  return r
}

/** One of the scripted inputs: a tap on a body (or on empty space), a swipe of a loose body, or a button pressed. */
class Input {
  frame: number
  kind: string
  body: string
  button: number
  constructor(frame: number, kind: string, body: string, button: number) {
    this.frame = frame; this.kind = kind; this.body = body; this.button = button
  }
}

/** What a play saw, for the host checks: the slowest change of state and what the throws did. */
export class WorldPlayReport {
  /** VM steps of the slowest event handler plus the build after it, and its predicted ms on the phone. */
  slowestSteps: number = 0
  slowestMs: number = 0
  bodies: number = 0
  kicks: number = 0
  settledAfterKick: number = 0
  settledRead: number = 0
  stateChanged: boolean = false
  /** Hits handed to the handler, and the VM steps of the costliest (handler, and the build when the state changed). */
  hitEvents: number = 0
  hitStepsMax: number = 0
  /** How far the player went under the held stick (m), and the zone entries told. */
  playerMoved: number = 0
  enterEvents: number = 0
}

/** A failure the play stops at: its diagnostic, already in the repair form. */
class PlayStop extends Error {
  constructor(text: string) { super(text) }
}

class WorldPlay {
  readonly vm: VirtualMachine
  readonly host: UiHostEnvironment
  readonly module: BytecodeModule
  readonly build: string
  readonly event: string
  readonly width: number
  readonly height: number
  readonly sim: WorldSim
  state: RuntimeValue
  spec: WorldSpec | null = null
  /** Simulated seconds, the orbits' clock. */
  time: number = 0
  /** Orbits and spins go on from where they are when a state changes their periods, as on the phone. */
  carry: MotionCarry = new MotionCarry()
  /** The slowest change of state: event handler and the build after it, VM steps. */
  slowest: number = 0
  /** Whether any body ever moved by itself (loose, orbiting, spinning), whether the state ever changed, whether dice were seen. */
  moving: boolean = false
  stateChanged: boolean = false
  dice: boolean = false
  /** Whether a body has scene.kick; the throws the state changes fired; the "settled" told after one; dice faces read. */
  thrower: boolean = false
  kicks: number = 0
  settledAfterKick: number = 0
  settledRead: number = 0
  hitEvents: number = 0
  hitStepsMax: number = 0
  /** What the design says travels (TRAVEL_KINDS), the zones' watch, the player's start under the stick and how far it went. */
  travel: string = 'none'
  zones: ZoneWatch = new ZoneWatch()
  enterEvents: number = 0
  playerStart: number[] | null = null
  playerId: string = ''
  playerMoved: number = -1
  playerSpeed: number = 1

  constructor(node: VeraUiNode, state: RuntimeValue, vm: VirtualMachine, host: UiHostEnvironment,
      module: BytecodeModule) {
    this.vm = vm
    this.host = host
    this.module = module
    this.build = node.label
    this.event = node.action
    let size = boxSize(node)
    this.width = size[0]
    this.height = size[1]
    this.sim = new WorldSim(new FakePhys())
    this.state = state
  }

  line(name: string): number {
    return functionLine(this.module, name)
  }

  /** A trap as the repair form: where the VM says it stopped, else the function it stopped in. */
  trap(e: Error, fn: string, when: string): PlayStop {
    if (e instanceof PlayStop) { return e as PlayStop }
    let text = 'The program compiled, but stopped ' + when + ': ' + e.message
    if (e instanceof RuntimeTrap) {
      let t = e as RuntimeTrap
      return new PlayStop((t.line > 0 ? t.line : this.line(fn)).toString() + ':1 ' + t.trapCode + ' ' + text)
    }
    return new PlayStop(text)
  }

  /** A handler run as the phone runs it: phone actions asked for are dropped. Returns the VM steps it took. */
  handle(name: string, value: RuntimeValue, when: string): number {
    let before = fingerprint(this.state)
    this.host.effectsAllowed = true
    try {
      this.state = this.vm.execute(name, [this.state, value])
    } catch (e) {
      throw this.trap(e as Error, name, when)
    } finally {
      this.host.effectsAllowed = false
      this.host.pendingEffects = []
    }
    let steps = this.vm.stepsExecuted()
    if (fingerprint(this.state) !== before) {
      this.stateChanged = true
      steps += this.rebuild(when)
    }
    if (steps > this.slowest) { this.slowest = steps }
    return steps
  }

  /** build for the state, decoded, checked where new bodies start, and applied to the physics. Returns the VM steps. */
  rebuild(when: string): number {
    let next: WorldSpec
    let steps = 0
    try {
      let value = this.vm.execute(this.build, [this.state])
      steps = this.vm.stepsExecuted()
      next = decodeScene(value)
    } catch (e) {
      throw this.trap(e as Error, this.build, 'in ' + this.build + ' ' + when)
    }
    this.carry.apply(next, this.time)
    let diff = diffWorld(this.spec, next)
    this.checkCreated(next, diff)
    this.checkOrbits(next)
    for (let b of next.bodies) {
      if (b.motion !== 'static' || b.orbit !== null || b.spinPeriodS !== 0 || b.path !== null || b.wander !== null) { this.moving = true }
      if (b.isDie) { this.dice = true }
      // The player's kick is a jump, not a throw that settles.
      if (b.kick !== null && b.player === null) { this.thrower = true }
    }
    let kicksBefore = this.sim.kickSerial
    this.sim.apply(diff, next)
    if (this.sim.kickSerial > kicksBefore) { this.kicks++ }
    this.spec = next
    return steps
  }

  /** New loose bodies: not inside another body, not under the ground, not outside the world they are in. */
  checkCreated(next: WorldSpec, diff: WorldDiff): void {
    let created: BodySpec[] = diff.create.concat(diff.recreate).filter((b: BodySpec): boolean => b.motion === 'loose')
    if (created.length === 0) { return }
    let at = this.line(this.build)
    let grounded = next.floor !== null || next.table !== null
    for (let b of created) {
      let box = specBounds(b)
      if (grounded && box[1] < -0.01) {
        throw new PlayStop(at.toString() + ':1 ' + CODE_OUT_OF_WORLD + ' The program plays, but body "' + b.id + '" starts ' +
          (Math.round(-box[1] * 100) / 100).toString() + ' m below the ' + (next.table !== null ? 'table top' : 'floor') +
          ' (y = 0): a body of height h stands on it at y = h / 2, and one dropped starts above that')
      }
      let p = b.position
      let outside = false
      if (next.table !== null) {
        let t = next.table as TableSpec
        outside = Math.abs(p[0]) > t.width / 2 || Math.abs(p[2]) > t.depth / 2
      } else if (next.floor !== null) {
        outside = Math.abs(p[0]) > 99 || Math.abs(p[2]) > 99
      } else {
        outside = Math.abs(p[0]) > 50 || Math.abs(p[1]) > 50 || Math.abs(p[2]) > 50
      }
      if (outside) {
        throw new PlayStop(at.toString() + ':1 ' + CODE_OUT_OF_WORLD + ' The program plays, but loose body "' + b.id + '" starts at ' +
          p.map((v: number): string => (Math.round(v * 100) / 100).toString()).join(', ') + ', outside ' +
          (next.table !== null ? 'the table (' + (next.table as TableSpec).width.toString() + ' by ' +
            (next.table as TableSpec).depth.toString() +
            ' m, centred on 0, 0)' : 'the world') + ': loose bodies start over the table or floor, near the middle')
      }
    }
    // Against every body there, new or not, that it could be inside: spheres by their distance, the rest by their boxes.
    let others: BodySpec[] = next.bodies.filter((b: BodySpec): boolean => b.orbit === null)
    let createdIds = new Set<string>()
    for (let b of created) { createdIds.add(b.id) }
    for (let b of created) {
      let box = specBounds(b)
      for (let o of others) {
        if (o.id === b.id || (createdIds.has(o.id) && o.id < b.id)) { continue }
        if (overlaps(b, box, o)) {
          throw new PlayStop(at.toString() + ':1 ' + CODE_OVERLAP + ' The program plays, but bodies "' + b.id + '" and "' + o.id +
            '" start inside one another: place each where nothing else is -- a row of cubes of side s is s apart, a stack ' +
            'is s higher each level -- or the physics throws them apart')
        }
      }
    }
  }

  /**
   * Bodies circling one centre at different speeds pass each other, so neighbouring orbits must be further apart than
   * the two bodies reach: their radius, their rings and whatever orbits them (a planet's moon). Closer, they go through
   * each other -- Saturn's rings through Jupiter -- and an orbit must clear its centre the same way. Two bodies going
   * round in the same time never gain on each other: they keep the distance they start at, so for them that distance,
   * not the gap between their orbits, has to clear what they reach (a ring of bodies sharing one orbit).
   */
  checkOrbits(next: WorldSpec): void {
    let byCentre = new Map<string, BodySpec[]>()
    for (let b of next.bodies) {
      if (b.orbit === null) { continue }
      let c = (b.orbit as SceneOrbit).centre
      let list = byCentre.get(c)
      if (list === undefined) {
        list = []
        byCentre.set(c, list)
      }
      list.push(b)
    }
    let r2 = (v: number): string => (Math.round(v * 100) / 100).toString()
    for (let entry of byCentre.entries()) {
      let list = entry[1]
      let centre = next.bodies.find((b: BodySpec): boolean => b.id === entry[0])
      if (centre !== undefined) {
        for (let b of list) {
          let o = b.orbit as SceneOrbit
          let need = flatReach(centre) + orbitReach(b, byCentre, 0)
          if (o.radius >= need) { continue }
          throw new PlayStop(this.line(this.build).toString() + ':1 ' + CODE_ORBITS_CROSS + ' The program plays, but "' + b.id +
            '" orbits "' + centre.id + '" at ' + r2(o.radius) + ', inside it: the two reach ' + r2(need) + ' across (radius, rings ' +
            'and the orbits of moons). Orbit further out, or make the bodies smaller')
        }
      }
      let sorted = list.slice().sort((a: BodySpec, b: BodySpec): number => (a.orbit as SceneOrbit).radius - (b.orbit as SceneOrbit).radius)
      for (let i = 0; i < sorted.length; i++) {
        for (let j = i + 1; j < sorted.length; j++) {
          let inner = sorted[i]
          let outer = sorted[j]
          let oi = inner.orbit as SceneOrbit
          let oo = outer.orbit as SceneOrbit
          let gap = oo.radius - oi.radius
          let need = orbitReach(inner, byCentre, 0) + orbitReach(outer, byCentre, 0)
          if (gap >= need) { continue }
          if (oi.periodS === oo.periodS) {
            let apart = (oi.phaseDeg - oo.phaseDeg) * Math.PI / 180
            let d = Math.sqrt(oi.radius * oi.radius + oo.radius * oo.radius - 2 * oi.radius * oo.radius * Math.cos(apart))
            if (d >= need) { continue }
          }
          throw new PlayStop(this.line(this.build).toString() + ':1 ' + CODE_ORBITS_CROSS + ' The program plays, but "' + inner.id +
            '" (orbit ' + r2(oi.radius) + ') and "' + outer.id + '" (orbit ' + r2(oo.radius) + ') pass through each other: their orbits are ' +
            r2(gap) + ' apart and the two reach ' + r2(need) + ' across (radius, rings and the orbits of their moons). Put neighbouring ' +
            'orbits further apart than that -- spread the outer ones wider, or make the bodies, rings and moon orbits smaller; bodies ' +
            'sharing one orbit radius need one period and phases far enough apart that they start ' + r2(need) + ' apart')
        }
      }
    }
  }

  /** The bodies the camera sees now, by their centres and sizes on the screen. */
  seen(pose: CameraPose, spec: WorldSpec, t: number): number {
    let orbits = orbitPositions(spec, t)
    let n = 0
    for (let b of spec.bodies) {
      let p: number[] = b.position
      let o = orbits.get(b.id)
      if (o !== undefined) { p = [o[0], o[1], o[2]] }
      let live = b.motion === 'loose' ? this.sim.poseOf(b.id) : null
      if (live !== null) { p = [live[0], live[1], live[2]] }
      let at = projectPoint(pose, this.width, this.height, p)
      if (at === null) { continue }
      let reach = radiusOf(b) / Math.max(1e-6, metresPerVp(pose, this.height, at[2]))
      if (reach < 1) { continue }
      if (at[0] + reach >= 0 && at[0] - reach <= this.width && at[1] + reach >= 0 && at[1] - reach <= this.height) { n++ }
    }
    return n
  }

  /** The camera sees at least one body, at the start or at some moment of the orbits' first ten seconds. */
  checkSeen(): void {
    let spec = this.spec as WorldSpec
    let at = this.line(this.build)
    if (spec.bodies.length === 0) {
      throw new PlayStop(at.toString() + ':1 ' + CODE_NOT_SEEN + ' The program plays, but ' + this.build + ' returns no bodies: ' +
        'the world is empty. Return the camera, the ground and the bodies of the scene')
    }
    let pose = worldCamera(spec, this.width / this.height)
    for (let t = 0; t <= 10; t++) {
      if (this.seen(pose, spec, t) > 0) { return }
    }
    let c: CameraSpec | null = spec.camera
    throw new PlayStop(at.toString() + ':1 ' + CODE_NOT_SEEN + ' The program plays, but the camera sees none of the ' +
      spec.bodies.length.toString() + ' bodies' + (c !== null ? ' (it stands at ' + cameraText(c as CameraSpec) + ')' : '') + ': put scene.camera back from the bodies and above them, looking at ' +
      'their middle -- for things about s metres across, about 2 to 3 s away -- or leave the camera out and the host frames everything')
  }

  /**
   * The bodies that move (or, with none moving, all of them) are not specks: the biggest is MIN_BODY_VP across on screen
   * as the world starts. Real sizes can make them so -- dice of 16 mm on a table 0.9 m wide came out 4 vp (2026-11-16).
   */
  checkReadable(): void {
    let spec = this.spec as WorldSpec
    let pose = worldCamera(spec, this.width / this.height)
    let orbits = orbitPositions(spec, 0)
    let moving = spec.bodies.filter((b: BodySpec): boolean => b.motion !== 'static')
    let list = moving.length > 0 ? moving : spec.bodies
    let biggest = 0
    let biggestId = ''
    for (let b of list) {
      let o = orbits.get(b.id)
      let p: number[] = o !== undefined ? [o[0], o[1], o[2]] : b.position
      let at = projectPoint(pose, this.width, this.height, p)
      if (at === null) { continue }
      let across = Math.max(b.dims[0], b.dims[1], b.dims[2]) / Math.max(1e-6, metresPerVp(pose, this.height, at[2]))
      if (across > biggest) {
        biggest = across
        biggestId = b.id
      }
    }
    if (biggestId.length === 0 || biggest >= MIN_BODY_VP) { return }
    throw new PlayStop(this.line(this.build).toString() + ':1 ' + CODE_TOO_SMALL + ' The program plays, but its bodies are specks on ' +
      'the phone: the biggest, "' + biggestId + '", is ' + (Math.round(biggest * 10) / 10).toString() + ' points across in a world ' +
      Math.round(this.width).toString() + ' points wide. Size the scene for the screen, not for reality: make the bodies bigger ' +
      'and keep the table or the spread of things just big enough for them, so each body the person watches is a good part ' +
      'of the view')
  }

  /** Where a body is now, for a tap on it. */
  where(id: string): number[] {
    let live = this.sim.poseOf(id)
    if (live !== null) { return [live[0], live[1], live[2]] }
    let spec = this.spec as WorldSpec
    let o = orbitPositions(spec, this.time).get(id)
    if (o !== undefined) { return [o[0], o[1], o[2]] }
    for (let b of spec.bodies) { if (b.id === id) { return b.position } }
    return [0, 0, 0]
  }

  hasBody(id: string): boolean {
    for (let b of (this.spec as WorldSpec).bodies) { if (b.id === id) { return true } }
    return false
  }

  /** The scripted inputs for the world as it starts: taps, swipes, a tap on nothing, the buttons. */
  script(buttons: number): Input[] {
    let spec = this.spec as WorldSpec
    let out: Input[] = []
    let frame = 20
    let tapped = spread(spec.bodies, TAPPED_BODIES)
    for (let b of tapped) {
      out.push(new Input(frame, 'tap', b.id, -1))
      frame += 8
    }
    out.push(new Input(frame, 'tap', '', -1))
    frame += 20
    let loose = spread(spec.bodies.filter((b: BodySpec): boolean => b.motion === 'loose'), SWIPED_BODIES)
    for (let b of loose) {
      out.push(new Input(frame, 'swipe', b.id, -1))
      frame += 15
    }
    // The buttons last, each with time after it for what it throws to settle.
    let room = Math.max(60, Math.floor((WORLD_PLAY_FRAMES - 30 - frame) / Math.max(1, buttons)))
    for (let k = 0; k < buttons; k++) {
      out.push(new Input(frame, 'button', '', k))
      frame += room
    }
    return out
  }

  /** What the world told, oldest first, at most EVENTS_PER_FRAME a frame, to the event handler. */
  deliver(queue: SimEvent[], frame: number): void {
    let n = 0
    while (queue.length > 0 && n < EVENTS_PER_FRAME) {
      let e = queue.shift() as SimEvent
      n++
      if (this.event.length === 0) { continue }
      if (e.kind === 'settled' && this.kicks > 0) { this.settledAfterKick++ }
      let isDiceSettle = e.kind === 'settled' && this.spec !== null &&
        (this.spec as WorldSpec).bodies.some((b: BodySpec): boolean => b.isDie)
      let before = fingerprint(this.state)
      let steps = this.handle(this.event, sceneEventValue(e.kind, e.body, e.other, e.x, e.y, e.z, e.speed, e.bodies, e.values),
        'in ' + this.event + ' (the event "' + e.kind + '" at frame ' + frame.toString() + ')')
      if (isDiceSettle && fingerprint(this.state) !== before) { this.settledRead++ }
      if (e.kind === 'hit') {
        this.hitEvents++
        this.hitStepsMax = Math.max(this.hitStepsMax, steps)
      }
    }
  }

  play(): string {
    this.rebuild('when the program starts')
    this.checkSeen()
    this.checkReadable()
    this.checkTravel()
    this.checkWalks()
    this.checkZones()
    let buttons: VeraUiNode[] = []
    for (let root of decodeVeraUi(this.vm.execute('view', [this.state]))) { buttonsIn(root, buttons) }
    let pressed = spread(buttons, PRESSED_BUTTONS)
    let inputs = this.script(pressed.length)
    let queue: SimEvent[] = []
    for (let frame = 1; frame <= WORLD_PLAY_FRAMES; frame++) {
      for (let input of inputs) {
        if (input.frame !== frame) { continue }
        if (input.kind === 'button') {
          let b = pressed[input.button]
          this.handle(b.action, new VeraNumberValue(b.eventValue), 'in ' + b.action + ' (the button "' + b.text + '")')
          continue
        }
        if (this.event.length === 0) { continue }
        if (input.body.length > 0 && !this.hasBody(input.body)) { continue }
        if (input.kind === 'tap') {
          let p = input.body.length > 0 ? this.where(input.body) : [0, 0, 0]
          this.handle(this.event, sceneEventValue('tap', input.body, '', p[0], p[1], p[2], 0, [], []),
            'in ' + this.event + ' (a tap on ' + (input.body.length > 0 ? 'body "' + input.body + '"' : 'empty space') +
            ' at frame ' + frame.toString() + ')')
        } else {
          let d = floorDirection(worldCamera(this.spec as WorldSpec, this.width / this.height), 0, -1)
          this.handle(this.event, sceneEventValue('swipe', input.body, '', d[0], 0, d[2], 3, [], []),
            'in ' + this.event + ' (a swipe of body "' + input.body + '" at frame ' + frame.toString() + ')')
        }
      }
      this.steerAt(frame)
      this.time += WORLD_STEP_MS / 1000
      this.sim.step(WORLD_STEP_MS, this.time)
      for (let e of this.sim.takeEvents()) { queue.push(e) }
      this.watchZones(queue)
      this.deliver(queue, frame)
      if (frame === STICK_FROM + STICK_AHEAD) { this.checkPlayerSeen() }
    }
    return this.verdict()
  }

  /**
   * The person's thumb on the stick, when the world has a player: held ahead (away from the eye) from STICK_FROM for
   * STICK_AHEAD frames, then to the right, then let go; its action button pressed once on the way. How far the player
   * went while held ahead is what P0011 reads.
   */
  steerAt(frame: number): void {
    let spec = this.spec as WorldSpec
    let player: BodySpec | null = null
    for (let b of spec.bodies) { if (b.player !== null) { player = b } }
    if (player === null) { return }
    let p = player as BodySpec
    if (frame === STICK_FROM) {
      let d = floorDirection(worldCamera(spec, this.width / this.height), 0, -1)
      this.sim.setStick(d[0], d[2], 1)
      this.playerId = p.id
      this.playerStart = this.sim.poseOf(p.id)
    } else if (frame === STICK_FROM + STICK_AHEAD) {
      let at = this.sim.poseOf(this.playerId)
      let from = this.playerStart
      this.playerSpeed = (p.player as ScenePlayer).speed
      this.playerMoved = at !== null && from !== null && this.playerId === p.id ?
        Math.hypot(at[0] - (from as number[])[0], at[2] - (from as number[])[2]) : -1
      let d = floorDirection(worldCamera(spec, this.width / this.height), 1, 0)
      this.sim.setStick(d[0], d[2], 1)
    } else if (frame === STICK_FROM + STICK_AHEAD + STICK_RIGHT) {
      this.sim.setStick(0, 0, 0)
    } else if (frame === STICK_FROM + STICK_AHEAD / 2 && (p.player as ScenePlayer).action.length > 0 && this.event.length > 0) {
      let at = this.where(p.id)
      this.handle(this.event, sceneEventValue('action', p.id, '', at[0], at[1], at[2], 0, [], []),
        'in ' + this.event + ' (the player\'s button "' + (p.player as ScenePlayer).action + '" at frame ' + frame.toString() + ')')
    }
  }

  /** The bodies that move, against the zones: entries go to the handler with the world's other events. */
  watchZones(queue: SimEvent[]): void {
    let spec = this.spec as WorldSpec
    if (spec.zones.length === 0) { return }
    let at = new Map<string, number[]>()
    let orbits = orbitPositions(spec, this.time)
    for (let b of spec.bodies) {
      if (b.motion === 'static') { continue }
      let live = b.motion === 'loose' ? this.sim.poseOf(b.id) : null
      let o = orbits.get(b.id)
      if (live !== null) { at.set(b.id, live) } else if (o !== undefined) { at.set(b.id, o) }
    }
    for (let z of this.zones.update(spec.zones, at)) {
      queue.push(enterEvent(z))
      this.enterEvents++
    }
  }

  /** After the stick has been held ahead, the player is still in view: a camera the program fixed does not lose it. */
  checkPlayerSeen(): void {
    let spec = this.spec as WorldSpec
    if (spec.camera === null || this.playerId.length === 0) { return }
    let at = this.sim.poseOf(this.playerId)
    if (at === null) { return }
    let pose = worldCamera(spec, this.width / this.height)
    let seen = projectPoint(pose, this.width, this.height, [at[0], at[1], at[2]])
    if (seen !== null && seen[0] >= 0 && seen[0] <= this.width && seen[1] >= 0 && seen[1] <= this.height) { return }
    throw new PlayStop(this.line(this.build).toString() + ':1 ' + CODE_NOT_SEEN + ' The program plays, but the player "' +
      this.playerId + '" walks out of view within two seconds: the scene.camera stands still. Leave scene.camera out -- the ' +
      'camera then follows the player -- or follow it with scene.follow')
  }

  /**
   * What the request asks to travel is there: a thing that walks or drives by itself has scene.path or scene.wander (or
   * orbits), one the person steers is scene.player.
   */
  checkTravel(): void {
    let spec = this.spec as WorldSpec
    let at = this.line(this.build)
    let self = this.travel === 'self' || this.travel === 'both'
    let steered = this.travel === 'steered' || this.travel === 'both'
    let travels = spec.bodies.some((b: BodySpec): boolean => b.path !== null || b.wander !== null || b.orbit !== null)
    let player = spec.bodies.some((b: BodySpec): boolean => b.player !== null)
    if (self && !travels) {
      let spins = spec.bodies.some((b: BodySpec): boolean => b.spinPeriodS !== 0)
      throw new PlayStop(at.toString() + ':1 ' + CODE_NO_TRAVEL + ' The program plays, but nothing in the world goes anywhere by ' +
        'itself, and the request has something that does' + (spins ? ': scene.spin only turns a body where it stands' : '') +
        '. Give what walks, runs or drives scene.path(body, [x1, z1, x2, z2, ...], speed, true) for a route or ' +
        'scene.wander(body, radius, speed) to roam, built facing +x')
    }
    if (steered && !player) {
      throw new PlayStop(at.toString() + ':1 ' + CODE_NO_TRAVEL + ' The program plays, but nothing in the world can be steered, ' +
        'and the request has the person move something: wrap it in scene.player(body, speed, action) -- the host draws the ' +
        'stick and the camera follows it')
    }
  }

  /** Each zone is somewhere a body can get to: on the floor or table, not inside a body, in a world where something moves. */
  checkZones(): void {
    let spec = this.spec as WorldSpec
    if (spec.zones.length === 0) { return }
    let at = this.line(this.build)
    let movers = spec.bodies.some((b: BodySpec): boolean => b.motion !== 'static')
    for (let z of spec.zones) {
      let why = ''
      if (!movers) {
        why = 'nothing in the world moves, so nothing can come into it: make a body the player, give one a path, or throw one'
      } else if (spec.table !== null && (Math.abs(z.x) > (spec.table as TableSpec).width / 2 ||
          Math.abs(z.z) > (spec.table as TableSpec).depth / 2)) {
        why = 'its centre is off the table (' + (spec.table as TableSpec).width.toString() + ' by ' +
          (spec.table as TableSpec).depth.toString() + ' m, centred on 0, 0)'
      } else if (spec.floor !== null && (Math.abs(z.x) > 99 || Math.abs(z.z) > 99)) {
        why = 'its centre is past the edge of the floor (99 m from the middle)'
      } else {
        for (let b of spec.bodies) {
          if (b.motion !== 'static') { continue }
          let box = specBounds(b)
          if (z.x > box[0] && z.x < box[3] && z.z > box[2] && z.z < box[5] && box[4] > 0.3 && box[1] < 0.3) {
            why = 'its centre is inside "' + b.id + '", which stands there'
            break
          }
        }
      }
      if (why.length > 0) {
        throw new PlayStop(at.toString() + ':1 ' + CODE_ZONE_UNREACHABLE + ' The program plays, but zone "' + z.id +
          '" cannot be reached: ' + why)
      }
    }
  }

  /**
   * Bodies that walk by themselves keep out of what stands in their way: over their route or area, every WALK_SAMPLE_S for
   * WALK_SAMPLE_FOR_S, never inside a body that stands still (one low enough to step over is no obstacle), never below
   * the ground.
   */
  checkWalks(): void {
    let spec = this.spec as WorldSpec
    let at = this.line(this.build)
    let walkers = spec.bodies.filter((b: BodySpec): boolean => b.path !== null || b.wander !== null)
    if (walkers.length === 0) { return }
    let grounded = spec.floor !== null || spec.table !== null
    let still = spec.bodies.filter((b: BodySpec): boolean => b.motion === 'static')
    for (let w of walkers) {
      let own = specBounds(w)
      let height = own[4] - own[1]
      if (grounded && own[1] < -0.01) {
        throw new PlayStop(at.toString() + ':1 ' + CODE_OUT_OF_WORLD + ' The program plays, but "' + w.id + '" walks ' +
          (Math.round(-own[1] * 100) / 100).toString() + ' m below the ground (y = 0): its y is kept as it goes, so put it ' +
          'at half its height')
      }
      let obstacles = still.filter((o: BodySpec): boolean => specBounds(o)[4] > own[1] + height * STEP_OVER)
      if (obstacles.length === 0) { continue }
      for (let t = 0; t <= WALK_SAMPLE_FOR_S; t += WALK_SAMPLE_S) {
        let p = orbitPositions(spec, t).get(w.id)
        if (p === undefined) { break }
        let dx = p[0] - w.position[0]
        let dz = p[2] - w.position[2]
        let box = [own[0] + dx, own[1], own[2] + dz, own[3] + dx, own[4], own[5] + dz]
        for (let o of obstacles) {
          if (!overlapsAt(w, [p[0], p[1], p[2]], box, o)) { continue }
          throw new PlayStop(at.toString() + ':1 ' + CODE_WALKS_THROUGH + ' The program plays, but "' + w.id + '" walks through "' +
            o.id + '" (at ' + (Math.round(p[0] * 100) / 100).toString() + ', ' + (Math.round(p[2] * 100) / 100).toString() +
            ', after ' + t.toString() + ' s): ' + (w.path !== null ? 'route the path round it, with its corners clear of it' :
            'wander where nothing stands, or move what stands out of its area') + ' -- the host moves it through anything')
        }
      }
    }
  }

  verdict(): string {
    if (this.playerMoved >= 0) {
      // The speed it had while it was steered: a later round may have made it again under another id.
      let speed = this.playerSpeed
      let reach = speed * STICK_AHEAD * WORLD_STEP_MS / 1000
      if (this.playerMoved < reach * STICK_MIN_SHARE) {
        return this.line(this.build).toString() + ':1 ' + CODE_STUCK + ' The program plays, but the player "' + this.playerId +
          '" hardly moves with the stick held: ' + (Math.round(this.playerMoved * 100) / 100).toString() + ' m in ' +
          (STICK_AHEAD * WORLD_STEP_MS / 1000).toString() + ' s at speed ' + speed.toString() + '. It must start on the ' +
          'ground (y half its height) and clear of every other body -- not inside a wall, a fence or under something'
      }
    }
    if (!this.moving && !this.stateChanged) {
      return this.line(this.build).toString() + ':1 ' + CODE_STILL + ' The program plays, but nothing in the world moves: no body ' +
        'is loose, orbits, spins, walks or is steered, and neither a tap on a body, a swipe nor a button changed the state. ' +
        'Make the bodies move with scene.loose and scene.kick (thrown when a count in the state changes), scene.orbit or ' +
        'scene.spin, scene.path or scene.wander (walking by itself), or scene.player (steered), and change the ' +
        'state in ' + (this.event.length > 0 ? this.event : 'an event handler (the World\'s last argument)') + ' when a body is tapped'
    }
    // Anything with scene.kick is there to be thrown, and a throw ends in "settled"; a die's face is read from it.
    if ((this.thrower || this.dice) && this.kicks === 0) {
      return this.line(this.build).toString() + ':1 ' + CODE_NO_SETTLE + ' The program plays, but ' +
        (this.thrower ? 'the bodies with scene.kick are' : 'the dice are') + ' never thrown: neither a tap, a swipe nor a ' +
        'button changed a kick trigger. Wrap each in scene.kick(scene.loose(body, 1), state.throws, ...) and add 1 to ' +
        'state.throws in the handler that throws'
    }
    if (this.kicks > 0 && this.settledAfterKick === 0 && (this.dice || this.event.length > 0)) {
      return this.line(this.build).toString() + ':1 ' + CODE_NO_SETTLE + ' The program plays, but the bodies were thrown and ' +
        'the event "settled" never arrived' + (this.event.length === 0 ? ': the World has no event handler, so nothing can ' +
        'read the faces. Name one as the World\'s last argument' : ': keep what is thrown loose, over the table or floor, ' +
        'thrown by scene.kick')
    }
    if (this.dice && this.settledRead === 0) {
      return this.line(this.event).toString() + ':1 ' + CODE_RESULT_UNREAD + ' The program plays, but when the dice came to rest ' +
        this.event + ' left the state as it was: on e.kind === "settled", read the faces from e.values (in the order of ' +
        'e.bodies), keep the result in the state and show it'
    }
    return worldBudgetProblem(this.slowest, this.line(this.event.length > 0 ? this.event : this.build))
  }
}

/**
 * '' when the program's world plays, else what is wrong, for the repair prompt. `requireWorld`: a program with no ui.World
 * is itself the problem (the 3D route asked for one). Only the first ui.World on the screen is played; the smoke run has
 * built every one.
 */
export function playWorld(compiled: CompileResult, requireWorld: boolean = true, report: WorldPlayReport | null = null,
    travel: string = 'none'): string {
  let host = new UiHostEnvironment()
  let module = deserializeVbc2(compiled.vbc2)
  let vm = new VirtualMachine(module, host)
  let state: RuntimeValue
  let world: VeraUiNode | null = null
  try {
    state = vm.execute('init')
    for (let root of decodeVeraUi(vm.execute('view', [state]))) {
      if (world === null) { world = findWorld(root) }
    }
  } catch (e) {
    let err = e as Error
    let text = 'The program compiled, but stopped when the program starts: ' + err.message
    return err instanceof RuntimeTrap && (err as RuntimeTrap).line > 0 ?
      (err as RuntimeTrap).line.toString() + ':1 ' + (err as RuntimeTrap).trapCode + ' ' + text : text
  }
  if (world === null) {
    return requireWorld ? '1:1 ' + CODE_NO_WORLD + ' The program compiled, but view() shows no ui.World: the 3D app must be ' +
      'built on one, ui.World("default", 0, "build", "onWorld")' : ''
  }
  let play = new WorldPlay(world as VeraUiNode, state, vm, host, module)
  play.travel = TRAVEL_KINDS.indexOf(travel) >= 0 ? travel : 'none'
  let verdict = ''
  try {
    verdict = play.play()
  } catch (e) {
    verdict = e instanceof PlayStop ? (e as PlayStop).message : play.trap(e as Error, play.build, 'while it was played').message
  }
  if (report !== null) {
    report.slowestSteps = play.slowest
    report.slowestMs = predictWorkMs(play.slowest)
    report.bodies = play.spec !== null ? (play.spec as WorldSpec).bodies.length : 0
    report.kicks = play.kicks
    report.settledAfterKick = play.settledAfterKick
    report.settledRead = play.settledRead
    report.stateChanged = play.stateChanged
    report.hitEvents = play.hitEvents
    report.hitStepsMax = play.hitStepsMax
    report.playerMoved = play.playerMoved
    report.enterEvents = play.enterEvents
  }
  return verdict
}

function cameraText(c: CameraSpec): string {
  return [c.x, c.y, c.z].join(', ') + ' and looks at ' + [c.lookX, c.lookY, c.lookZ].join(', ')
}

function overlaps(b: BodySpec, box: number[], o: BodySpec): boolean {
  return overlapsAt(b, b.position, box, o)
}

/** overlaps, for b at position p with its bounds box there. */
function overlapsAt(b: BodySpec, p: number[], box: number[], o: BodySpec): boolean {
  if (b.shape === 'sphere' && o.shape === 'sphere') {
    let dx = p[0] - o.position[0]
    let dy = p[1] - o.position[1]
    let dz = p[2] - o.position[2]
    let r = (b.dims[0] + o.dims[0]) / 2
    return Math.sqrt(dx * dx + dy * dy + dz * dz) < r * 0.9
  }
  let other = specBounds(o)
  // Boxes turned or round are bounded loosely: count only a clear overlap, a tenth of the smaller body on every axis.
  for (let k = 0; k < 3; k++) {
    let depth = Math.min(box[k + 3], other[k + 3]) - Math.max(box[k], other[k])
    let small = Math.min(box[k + 3] - box[k], other[k + 3] - other[k])
    if (!(depth > Math.max(0.002, small * 0.1))) { return false }
  }
  return true
}
