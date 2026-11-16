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
import { WorldSpec, BodySpec, TableSpec, CameraSpec, WorldDiff, decodeScene, diffWorld, orbitPositions, sceneEventValue } from './VeraScene'
import { FakePhys, WorldSim, SimEvent, specBounds } from './VeraPhysics'
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

/** What a play saw, for the host checks: the slowest change of state and what the dice did. */
export class WorldPlayReport {
  /** VM steps of the slowest event handler plus the build after it, and its predicted ms on the phone. */
  slowestSteps: number = 0
  slowestMs: number = 0
  bodies: number = 0
  kicksWithDice: number = 0
  settledWithDice: number = 0
  settledRead: number = 0
  stateChanged: boolean = false
  /** Hits handed to the handler, and the VM steps of the costliest (handler, and the build when the state changed). */
  hitEvents: number = 0
  hitStepsMax: number = 0
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
  /** The slowest change of state: event handler and the build after it, VM steps. */
  slowest: number = 0
  /** Whether any body ever moved by itself (loose, orbiting, spinning), whether the state ever changed, whether dice were seen. */
  moving: boolean = false
  stateChanged: boolean = false
  dice: boolean = false
  kicksWithDice: number = 0
  settledWithDice: number = 0
  settledRead: number = 0
  hitEvents: number = 0
  hitStepsMax: number = 0

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
    let diff = diffWorld(this.spec, next)
    this.checkCreated(next, diff)
    for (let b of next.bodies) {
      if (b.motion !== 'static' || b.orbit !== null || b.spinPeriodS !== 0) { this.moving = true }
      if (b.isDie) { this.dice = true }
    }
    let kicksBefore = this.sim.kickSerial
    this.sim.apply(diff, next)
    if (this.sim.kickSerial > kicksBefore && next.bodies.some((b: BodySpec): boolean => b.isDie && b.motion === 'loose')) {
      this.kicksWithDice++
    }
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
      let isDiceSettle = e.kind === 'settled' && this.spec !== null &&
        (this.spec as WorldSpec).bodies.some((b: BodySpec): boolean => b.isDie)
      if (isDiceSettle) { this.settledWithDice++ }
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
      this.time += WORLD_STEP_MS / 1000
      this.sim.step(WORLD_STEP_MS, this.time)
      for (let e of this.sim.takeEvents()) { queue.push(e) }
      this.deliver(queue, frame)
    }
    return this.verdict()
  }

  verdict(): string {
    if (!this.moving && !this.stateChanged) {
      return this.line(this.build).toString() + ':1 ' + CODE_STILL + ' The program plays, but nothing in the world moves: no body ' +
        'is loose, orbits or spins, and neither a tap on a body, a swipe nor a button changed the state. Make the bodies move ' +
        'with scene.loose and scene.kick (thrown when a count in the state changes), scene.orbit or scene.spin, and change the ' +
        'state in ' + (this.event.length > 0 ? this.event : 'an event handler (the World\'s last argument)') + ' when a body is tapped'
    }
    if (this.dice && this.kicksWithDice === 0) {
      return this.line(this.build).toString() + ':1 ' + CODE_NO_SETTLE + ' The program plays, but the dice are never thrown: ' +
        'neither a tap, a swipe nor a button changed their kick trigger. Wrap each die in scene.kick(scene.loose(die, 1), ' +
        'state.throws, ...) and add 1 to state.throws in the handler that throws'
    }
    if (this.dice && this.settledWithDice === 0) {
      return this.line(this.build).toString() + ':1 ' + CODE_NO_SETTLE + ' The program plays, but the dice were thrown and the ' +
        'event "settled" never arrived' + (this.event.length === 0 ? ': the World has no event handler, so nothing can read ' +
        'the faces. Name one as the World\'s last argument' : ': keep the dice loose on a scene.table, thrown by scene.kick')
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
export function playWorld(compiled: CompileResult, requireWorld: boolean = true, report: WorldPlayReport | null = null): string {
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
    report.kicksWithDice = play.kicksWithDice
    report.settledWithDice = play.settledWithDice
    report.settledRead = play.settledRead
    report.stateChanged = play.stateChanged
    report.hitEvents = play.hitEvents
    report.hitStepsMax = play.hitStepsMax
  }
  return verdict
}

function cameraText(c: CameraSpec): string {
  return [c.x, c.y, c.z].join(', ') + ' and looks at ' + [c.lookX, c.lookY, c.lookZ].join(', ')
}

function overlaps(b: BodySpec, box: number[], o: BodySpec): boolean {
  if (b.shape === 'sphere' && o.shape === 'sphere') {
    let dx = b.position[0] - o.position[0]
    let dy = b.position[1] - o.position[1]
    let dz = b.position[2] - o.position[2]
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
