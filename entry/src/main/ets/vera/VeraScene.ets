/**
 * std/scene: what a ui.World shows, and the contract between the program and the 3D host.
 *
 * A ui.Surface is drawn by the program every frame. A world is not: the program describes it -- a camera, a
 * table or a floor, bodies with sizes and colours, which of them fall and roll, which circle which, which are
 * thrown when a number in the state changes -- and the host moves it. Poses go from the physics straight into
 * the 3D nodes and never through the VM, so a world of three hundred bodies costs the program nothing per frame.
 * The program hears back through one event handler: a tap, a swipe, a hit, and `settled` with the faces dice
 * landed on.
 *
 * One table (SCENE_FUNCTIONS) is the module, as GFX_FUNCTIONS is std/gfx: the compiler's interface, the colour
 * check and the prompt's description are generated from it. Things are built by the host as the program calls
 * these functions (invokeStdScene), flattened into a plain WorldSpec once per state (decodeScene), and compared
 * with the last one (diffWorld) so the renderer only creates, removes and moves what changed. Kinematic motion
 * -- orbits and spins -- is a pure function of time (orbitPositions), and a die's top face a pure function of
 * its rotation (topFace), so all of it runs on the host as it does on the phone.
 *
 * Pure: imports only relative modules, never a platform kit, so tools/vera-harness loads it under node.
 */

import { RuntimeValue, VeraNumberValue, VeraStringValue, VeraBooleanValue, VeraArrayValue, VeraObjectValue,
  RuntimeTrap } from './VeraInterpreter'
import { GfxParam, GfxFunction, GFX_ROLES } from './VeraGfx'
import { SURFACE_PATTERNS, surfacePattern } from './VeraSurfaces'

/** Class identities of the module's two types, as the compiler names them. */
export const SCENE_THING: string = 'std/scene:Thing'
export const SCENE_EVENT: string = 'std/scene:Event'

/** The most bodies one world may hold (a camera, a table and a floor are not bodies). */
export const MAX_WORLD_BODIES: number = 300

/** The kinds of a scene.Event, in the order the prompt lists them. */
export const SCENE_EVENT_KINDS: string[] = ['tap', 'swipe', 'hit', 'settled']

/** Things that are bodies, which every wrapper takes; the rest (camera, table, floor) set up the world. */
const BODY_KINDS: string[] = ['box', 'sphere', 'cylinder', 'die']

function num(name: string): GfxParam { return new GfxParam(name, 'number') }
function str(name: string): GfxParam { return new GfxParam(name, 'string') }
function color(): GfxParam { return new GfxParam('color', 'color') }
function thing(): GfxParam { return new GfxParam('thing', 'thing') }

/** std/scene's functions. Every result is a scene.Thing ('thing'). */
export const SCENE_FUNCTIONS: GfxFunction[] = [
  new GfxFunction('box', [str('id'), num('x'), num('y'), num('z'), num('w'), num('h'), num('d'), color()], 'thing',
    'a box centred on x, y, z, w wide (x), h tall (y), d deep (z): a crate, a brick, a wall, a building'),
  new GfxFunction('sphere', [str('id'), num('x'), num('y'), num('z'), num('r'), color()], 'thing',
    'a ball of radius r centred on x, y, z: a ball, a planet, a sun, a marble'),
  new GfxFunction('cylinder', [str('id'), num('x'), num('y'), num('z'), num('r'), num('h'), color()], 'thing',
    'an upright cylinder of radius r and height h centred on x, y, z: a can, a pillar, a coin (small h), a tower'),
  new GfxFunction('die', [str('id'), num('x'), num('y'), num('z'), num('size'), color()], 'thing',
    'a die with pips, a cube of side size centred on x, y, z; when it comes to rest the event "settled" tells the face on top ' +
    '(1..6) in e.values, in the order of e.bodies'),
  new GfxFunction('table', [num('width'), num('depth'), color()], 'thing',
    'a table top at y = 0, width by depth, centred on 0, 0, with low walls round it: loose bodies stay on it. Use it for dice and ' +
    'for anything thrown'),
  new GfxFunction('floor', [color()], 'thing',
    'the ground at y = 0, as far as the eye sees: a world with no table or floor floats in space (a solar system)'),
  new GfxFunction('camera', [num('x'), num('y'), num('z'), num('lookX'), num('lookY'), num('lookZ'), new GfxParam('orbit', 'boolean')],
    'thing', 'where the viewer stands and the point it looks at; orbit true lets a drag on empty space turn the view around that point. ' +
    'At most one; without it the host picks a view of everything'),
  new GfxFunction('loose', [thing(), num('mass')], 'thing',
    'the thing falls, rolls and knocks into others under physics (mass in kg, 1 is fine); without it a body stays where it is put'),
  new GfxFunction('kick', [thing(), num('trigger'), num('vx'), num('vy'), num('vz'), num('spin')], 'thing',
    'throws the thing with velocity vx, vy, vz (metres a second) and a tumble of spin (turns a second) each time trigger changes ' +
    '-- keep a count in state (state.throws) and add 1 in the handler that throws; the thing becomes loose (mass 1) if it was not'),
  new GfxFunction('orbit', [thing(), str('centreId'), num('radius'), num('periodS'), num('phaseDeg')], 'thing',
    'the thing circles the body with id centreId at radius, once every periodS seconds, starting phaseDeg round, level and ' +
    'counter-clockwise seen from above; its own x, y, z are ignored. A centre may itself orbit (a moon round a planet round a sun) ' +
    'but may not be loose'),
  new GfxFunction('spin', [thing(), num('periodS')], 'thing',
    'the thing turns about its upright axis once every periodS seconds (negative turns the other way): a planet, a turntable'),
  new GfxFunction('turn', [thing(), num('rx'), num('ry'), num('rz')], 'thing',
    'the thing\'s starting rotation, in degrees about x, y and z: a tilted box, a fallen pillar'),
  new GfxFunction('glow', [thing()], 'thing',
    'the thing shines by itself and casts no shadow: a sun, a lamp, a light'),
  new GfxFunction('paint', [thing(), str('pattern'), new GfxParam('color2', 'color')], 'thing',
    'a ball\'s surface: pattern drawn in the ball\'s own colour and color2, so it reads as what it is -- ' +
    SURFACE_PATTERNS.map((p: string[]): string => '"' + p[0] + '" ' + p[1]).join('; ') +
    '. With scene.spin the pattern turns, so the ball is seen turning'),
  new GfxFunction('rings', [thing(), num('inner'), num('outer'), color()], 'thing',
    'flat rings round the thing\'s equator from radius inner to outer (metres from its centre), tilted and carried with it: ' +
    'a ringed planet\'s rings (about 1.3 to 2.3 times its radius)'),
  new GfxFunction('mark', [thing(), color()], 'thing',
    'a thin ring round the thing that marks it, in the colour (the accent): the planet or body the person selected'),
  new GfxFunction('bounce', [thing(), num('restitution'), num('friction')], 'thing',
    'how the thing bounces (0 dead .. 1 rubber; 0.3 by default) and grips (0 ice .. 1 rubber; 0.6 by default)'),
]

/** The fields of scene.Event, in the order the prompt lists them. */
export const SCENE_EVENT_FIELDS: string[][] = [
  ['kind', 'string'], ['body', 'string'], ['other', 'string'], ['x', 'number'], ['y', 'number'], ['z', 'number'],
  ['speed', 'number'], ['bodies', 'string[]'], ['values', 'number[]'],
]

export function sceneFunction(name: string): GfxFunction | null {
  for (let f of SCENE_FUNCTIONS) { if (f.name === name) { return f } }
  return null
}

export class SceneKick {
  trigger: number = 0
  vx: number = 0
  vy: number = 0
  vz: number = 0
  spin: number = 0
}

export class SceneOrbit {
  centre: string = ''
  radius: number = 0
  periodS: number = 0
  phaseDeg: number = 0
}

/** One thing as the program built it, wrappers applied. Plain data, copied by every wrapper. */
export class SceneThing {
  /** 'box' | 'sphere' | 'cylinder' | 'die' | 'table' | 'floor' | 'camera' */
  kind: string = ''
  id: string = ''
  x: number = 0
  y: number = 0
  z: number = 0
  /** Extents along x, y, z: a sphere's are its diameter, a cylinder's 2r, h, 2r, a table's width, 0, depth. */
  w: number = 0
  h: number = 0
  d: number = 0
  color: string = ''
  /** The camera's. */
  lookX: number = 0
  lookY: number = 0
  lookZ: number = 0
  orbitCamera: boolean = false
  /** 'static' | 'loose' | 'kinematic' */
  motion: string = 'static'
  mass: number = 0
  restitution: number = 0.3
  friction: number = 0.6
  kick: SceneKick | null = null
  orbit: SceneOrbit | null = null
  spinPeriodS: number = 0
  rx: number = 0
  ry: number = 0
  rz: number = 0
  glow: boolean = false
  /** scene.paint: the surface pattern and its second colour ('' for a plain body). */
  pattern: string = ''
  color2: string = ''
  /** scene.rings: inner and outer radius (0, 0 for none) and their colour. */
  ringInner: number = 0
  ringOuter: number = 0
  ringColor: string = ''
  /** scene.mark: the colour of the ring that marks the body ('' for none). */
  mark: string = ''

  copy(): SceneThing {
    let t = new SceneThing()
    t.kind = this.kind; t.id = this.id; t.x = this.x; t.y = this.y; t.z = this.z
    t.w = this.w; t.h = this.h; t.d = this.d; t.color = this.color
    t.lookX = this.lookX; t.lookY = this.lookY; t.lookZ = this.lookZ; t.orbitCamera = this.orbitCamera
    t.motion = this.motion; t.mass = this.mass; t.restitution = this.restitution; t.friction = this.friction
    t.kick = this.kick; t.orbit = this.orbit; t.spinPeriodS = this.spinPeriodS
    t.rx = this.rx; t.ry = this.ry; t.rz = this.rz; t.glow = this.glow
    t.pattern = this.pattern; t.color2 = this.color2
    t.ringInner = this.ringInner; t.ringOuter = this.ringOuter; t.ringColor = this.ringColor; t.mark = this.mark
    return t
  }
}

/** A thing as the VM carries it: an object of class scene.Thing with nothing in it a program can read. */
export class SceneThingValue extends VeraObjectValue {
  thing: SceneThing
  constructor(thing: SceneThing) {
    super(SCENE_THING, new Map<string, RuntimeValue>())
    this.thing = thing
  }
}

function finite(n: number, what: string): number {
  if (!isFinite(n)) { throw new RuntimeTrap('R0020', 'scene: ' + what + ' must be a finite number') }
  return n
}

function asNum(args: RuntimeValue[], i: number, what: string): number {
  if (i >= args.length) { return 0 }
  let v = args[i]
  if (v instanceof VeraNumberValue) { return finite((v as VeraNumberValue).value, what) }
  throw new RuntimeTrap('R0020', 'expected number argument')
}

function asStr(args: RuntimeValue[], i: number): string {
  if (i >= args.length) { return '' }
  let v = args[i]
  if (v instanceof VeraStringValue) { return (v as VeraStringValue).value }
  throw new RuntimeTrap('R0020', 'expected string argument')
}

function asBool(args: RuntimeValue[], i: number): boolean {
  if (i >= args.length) { return false }
  let v = args[i]
  if (v instanceof VeraBooleanValue) { return (v as VeraBooleanValue).value }
  throw new RuntimeTrap('R0020', 'expected boolean argument')
}

function positive(n: number, what: string): number {
  if (!(n > 0)) { throw new RuntimeTrap('R0029', 'scene: ' + what + ' must be more than 0; got ' + n.toString()) }
  return n
}

function asId(args: RuntimeValue[], i: number, fn: string): string {
  let id = asStr(args, i)
  if (id.length === 0) { throw new RuntimeTrap('R0029', 'scene.' + fn + ' needs an id: a name no other body in the world has') }
  return id
}

/** The body a wrapper is handed, copied: never the camera, the table or the floor. */
function asBody(args: RuntimeValue[], fn: string): SceneThing {
  let v = args.length > 0 ? args[0] : null
  if (!(v instanceof SceneThingValue)) {
    throw new RuntimeTrap('R0020', 'scene.' + fn + ' takes a scene.Thing made by scene.box, sphere, cylinder or die')
  }
  let t = (v as SceneThingValue).thing
  if (BODY_KINDS.indexOf(t.kind) < 0) {
    throw new RuntimeTrap('R0029', 'scene.' + fn + ' takes a body (box, sphere, cylinder, die), not the ' + t.kind)
  }
  return t.copy()
}

function body(kind: string, args: RuntimeValue[]): SceneThing {
  let t = new SceneThing()
  t.kind = kind
  t.id = asId(args, 0, kind)
  t.x = asNum(args, 1, 'x'); t.y = asNum(args, 2, 'y'); t.z = asNum(args, 3, 'z')
  return t
}

function wrap(t: SceneThing): RuntimeValue { return new SceneThingValue(t) }

/** One std/scene call: a thing, as plain data in an opaque value. */
export function invokeStdScene(name: string, args: RuntimeValue[]): RuntimeValue {
  switch (name) {
    case 'box': {
      let t = body('box', args)
      t.w = positive(asNum(args, 4, 'w'), 'w'); t.h = positive(asNum(args, 5, 'h'), 'h'); t.d = positive(asNum(args, 6, 'd'), 'd')
      t.color = asStr(args, 7)
      return wrap(t)
    }
    case 'sphere': {
      let t = body('sphere', args)
      let r = positive(asNum(args, 4, 'r'), 'r')
      t.w = 2 * r; t.h = 2 * r; t.d = 2 * r
      t.color = asStr(args, 5)
      return wrap(t)
    }
    case 'cylinder': {
      let t = body('cylinder', args)
      let r = positive(asNum(args, 4, 'r'), 'r')
      t.w = 2 * r; t.h = positive(asNum(args, 5, 'h'), 'h'); t.d = 2 * r
      t.color = asStr(args, 6)
      return wrap(t)
    }
    case 'die': {
      let t = body('die', args)
      let s = positive(asNum(args, 4, 'size'), 'size')
      t.w = s; t.h = s; t.d = s
      t.color = asStr(args, 5)
      return wrap(t)
    }
    case 'table': {
      let t = new SceneThing()
      t.kind = 'table'
      t.w = positive(asNum(args, 0, 'width'), 'width'); t.d = positive(asNum(args, 1, 'depth'), 'depth')
      t.color = asStr(args, 2)
      return wrap(t)
    }
    case 'floor': {
      let t = new SceneThing()
      t.kind = 'floor'
      t.color = asStr(args, 0)
      return wrap(t)
    }
    case 'camera': {
      let t = new SceneThing()
      t.kind = 'camera'
      t.x = asNum(args, 0, 'x'); t.y = asNum(args, 1, 'y'); t.z = asNum(args, 2, 'z')
      t.lookX = asNum(args, 3, 'lookX'); t.lookY = asNum(args, 4, 'lookY'); t.lookZ = asNum(args, 5, 'lookZ')
      t.orbitCamera = asBool(args, 6)
      if (t.x === t.lookX && t.y === t.lookY && t.z === t.lookZ) {
        throw new RuntimeTrap('R0029', 'scene.camera looks at the point it stands on; put it away from what it looks at')
      }
      return wrap(t)
    }
    case 'loose': {
      let t = asBody(args, 'loose')
      if (t.motion === 'kinematic') {
        throw new RuntimeTrap('R0029', 'body "' + t.id + '" orbits or spins, so it cannot also be loose: the host moves it, not physics')
      }
      t.motion = 'loose'
      t.mass = positive(asNum(args, 1, 'mass'), 'mass')
      return wrap(t)
    }
    case 'kick': {
      let t = asBody(args, 'kick')
      if (t.motion === 'kinematic') {
        throw new RuntimeTrap('R0029', 'body "' + t.id + '" orbits or spins, so it cannot be kicked: only a loose body flies')
      }
      if (t.motion !== 'loose') { t.motion = 'loose'; t.mass = 1 }
      let k = new SceneKick()
      k.trigger = asNum(args, 1, 'trigger')
      k.vx = asNum(args, 2, 'vx'); k.vy = asNum(args, 3, 'vy'); k.vz = asNum(args, 4, 'vz')
      k.spin = asNum(args, 5, 'spin')
      t.kick = k
      return wrap(t)
    }
    case 'orbit': {
      let t = asBody(args, 'orbit')
      if (t.motion === 'loose') {
        throw new RuntimeTrap('R0029', 'body "' + t.id + '" is loose, so it cannot also orbit: physics moves it, not the host')
      }
      let o = new SceneOrbit()
      o.centre = asStr(args, 1)
      if (o.centre.length === 0) { throw new RuntimeTrap('R0029', 'scene.orbit needs the id of the body to circle') }
      if (o.centre === t.id) { throw new RuntimeTrap('R0029', 'body "' + t.id + '" cannot orbit itself') }
      o.radius = asNum(args, 2, 'radius')
      o.periodS = asNum(args, 3, 'periodS')
      o.phaseDeg = asNum(args, 4, 'phaseDeg')
      t.motion = 'kinematic'
      t.orbit = o
      return wrap(t)
    }
    case 'spin': {
      let t = asBody(args, 'spin')
      if (t.motion === 'loose') {
        throw new RuntimeTrap('R0029', 'body "' + t.id + '" is loose, so it cannot also spin: physics turns it, not the host')
      }
      t.motion = 'kinematic'
      t.spinPeriodS = asNum(args, 1, 'periodS')
      return wrap(t)
    }
    case 'turn': {
      let t = asBody(args, 'turn')
      t.rx = asNum(args, 1, 'rx'); t.ry = asNum(args, 2, 'ry'); t.rz = asNum(args, 3, 'rz')
      return wrap(t)
    }
    case 'glow': {
      let t = asBody(args, 'glow')
      t.glow = true
      return wrap(t)
    }
    case 'paint': {
      let t = asBody(args, 'paint')
      let pattern = asStr(args, 1)
      if (!surfacePattern(pattern)) {
        throw new RuntimeTrap('R0029', 'scene.paint has no pattern "' + pattern + '": use one of ' +
          SURFACE_PATTERNS.map((p: string[]): string => '"' + p[0] + '"').join(', '))
      }
      if (t.kind !== 'sphere') {
        throw new RuntimeTrap('R0029', 'scene.paint paints a sphere; "' + t.id + '" is a ' + t.kind)
      }
      t.pattern = pattern
      t.color2 = asStr(args, 2)
      return wrap(t)
    }
    case 'rings': {
      let t = asBody(args, 'rings')
      let inner = positive(asNum(args, 1, 'inner'), 'inner')
      let outer = asNum(args, 2, 'outer')
      let radius = Math.max(t.w, t.h, t.d) / 2
      if (!(outer > inner) || inner <= radius * 0.9) {
        throw new RuntimeTrap('R0029', 'scene.rings of "' + t.id + '" go from inner to outer, both beyond its radius ' +
          radius.toString() + ' and outer more than inner; got ' + inner.toString() + ' to ' + outer.toString())
      }
      t.ringInner = inner
      t.ringOuter = outer
      t.ringColor = asStr(args, 3)
      return wrap(t)
    }
    case 'mark': {
      let t = asBody(args, 'mark')
      let c = asStr(args, 1)
      t.mark = c.length > 0 ? c : 'accent'
      return wrap(t)
    }
    case 'bounce': {
      let t = asBody(args, 'bounce')
      t.restitution = Math.max(0, Math.min(1, asNum(args, 1, 'restitution')))
      t.friction = Math.max(0, Math.min(1, asNum(args, 2, 'friction')))
      return wrap(t)
    }
    default:
      throw new RuntimeTrap('R0015', `unknown std/scene function: ${name}`)
  }
}

/** A scene.Event for the world's handler. */
export function sceneEventValue(kind: string, bodyId: string, other: string, x: number, y: number, z: number, speed: number,
    bodies: string[], values: number[]): RuntimeValue {
  let fields = new Map<string, RuntimeValue>()
  fields.set('kind', new VeraStringValue(kind))
  fields.set('body', new VeraStringValue(bodyId))
  fields.set('other', new VeraStringValue(other))
  fields.set('x', new VeraNumberValue(x))
  fields.set('y', new VeraNumberValue(y))
  fields.set('z', new VeraNumberValue(z))
  fields.set('speed', new VeraNumberValue(speed))
  let ids: RuntimeValue[] = []
  for (let b of bodies) { ids.push(new VeraStringValue(b)) }
  let nums: RuntimeValue[] = []
  for (let v of values) { nums.push(new VeraNumberValue(v)) }
  fields.set('bodies', new VeraArrayValue(ids))
  fields.set('values', new VeraArrayValue(nums))
  return new VeraObjectValue(SCENE_EVENT, fields)
}

// ---------------------------------------------------------------- the world as plain data

export class CameraSpec {
  x: number = 0
  y: number = 0
  z: number = 0
  lookX: number = 0
  lookY: number = 0
  lookZ: number = 0
  orbit: boolean = false
}

export class TableSpec {
  width: number = 0
  depth: number = 0
  color: string = ''
}

export class FloorSpec {
  color: string = ''
}

export class BodySpec {
  id: string = ''
  /** 'box' | 'sphere' | 'cylinder' (a die is a box with isDie) */
  shape: string = 'box'
  /** Extents along x, y, z in metres. */
  dims: number[] = [0, 0, 0]
  /** Where it was put, in metres: for a loose body, where it starts; for an orbiting one, unused. */
  position: number[] = [0, 0, 0]
  /** Starting rotation in degrees about x, y, z. */
  rotation: number[] = [0, 0, 0]
  /** As written: a theme role or a literal colour. */
  color: string = ''
  /** 'static' | 'loose' | 'kinematic' */
  motion: string = 'static'
  mass: number = 0
  restitution: number = 0.3
  friction: number = 0.6
  kick: SceneKick | null = null
  orbit: SceneOrbit | null = null
  spinPeriodS: number = 0
  glow: boolean = false
  isDie: boolean = false
  /** scene.paint's pattern and second colour; '' for a plain body. */
  pattern: string = ''
  color2: string = ''
  /** scene.rings: [inner, outer] in metres, or [] for none, and their colour. */
  rings: number[] = []
  ringColor: string = ''
  /** scene.mark's colour, '' for none. */
  mark: string = ''
}

export class WorldSpec {
  camera: CameraSpec | null = null
  floor: FloorSpec | null = null
  table: TableSpec | null = null
  bodies: BodySpec[] = []
}

function bodySpec(t: SceneThing): BodySpec {
  let b = new BodySpec()
  b.id = t.id
  b.shape = t.kind === 'die' ? 'box' : t.kind
  b.dims = [t.w, t.h, t.d]
  b.position = [t.x, t.y, t.z]
  b.rotation = [t.rx, t.ry, t.rz]
  b.color = t.color
  b.motion = t.motion
  b.mass = t.motion === 'loose' ? t.mass : 0
  b.restitution = t.restitution
  b.friction = t.friction
  b.kick = t.kick
  b.orbit = t.orbit
  b.spinPeriodS = t.spinPeriodS
  b.glow = t.glow
  b.isDie = t.kind === 'die'
  b.pattern = t.pattern
  b.color2 = t.color2
  b.rings = t.ringOuter > 0 ? [t.ringInner, t.ringOuter] : []
  b.ringColor = t.ringColor
  b.mark = t.mark
  return b
}

/** What a build function returned, as one world: every field resolved, the contract checked. */
export function decodeScene(value: RuntimeValue): WorldSpec {
  let world = new WorldSpec()
  if (!(value instanceof VeraArrayValue)) { return world }
  let byId = new Map<string, BodySpec>()
  for (let item of (value as VeraArrayValue).elements) {
    if (!(item instanceof SceneThingValue)) { continue }
    let t = (item as SceneThingValue).thing
    if (t.kind === 'camera') {
      if (world.camera !== null) { throw new RuntimeTrap('R0029', 'a world has at most one scene.camera') }
      let c = new CameraSpec()
      c.x = t.x; c.y = t.y; c.z = t.z; c.lookX = t.lookX; c.lookY = t.lookY; c.lookZ = t.lookZ; c.orbit = t.orbitCamera
      world.camera = c
    } else if (t.kind === 'table') {
      if (world.table !== null) { throw new RuntimeTrap('R0029', 'a world has at most one scene.table') }
      let s = new TableSpec()
      s.width = t.w; s.depth = t.d; s.color = t.color
      world.table = s
    } else if (t.kind === 'floor') {
      if (world.floor !== null) { throw new RuntimeTrap('R0029', 'a world has at most one scene.floor') }
      let f = new FloorSpec()
      f.color = t.color
      world.floor = f
    } else {
      if (byId.has(t.id)) {
        throw new RuntimeTrap('R0029', 'two bodies have the id "' + t.id + '": every body needs an id of its own')
      }
      if (t.motion === 'loose' && t.orbit !== null) {
        throw new RuntimeTrap('R0029', 'body "' + t.id + '" is loose and orbits: it can be one or the other')
      }
      let b = bodySpec(t)
      byId.set(b.id, b)
      world.bodies.push(b)
      if (world.bodies.length > MAX_WORLD_BODIES) {
        throw new RuntimeTrap('R0028', 'a world holds at most ' + MAX_WORLD_BODIES.toString() + ' bodies')
      }
    }
  }
  for (let b of world.bodies) {
    if (b.orbit === null) { continue }
    let seen = new Set<string>()
    seen.add(b.id)
    let at: BodySpec = b
    while (at.orbit !== null) {
      let centreId = (at.orbit as SceneOrbit).centre
      let centre = byId.get(centreId)
      if (centre === undefined) {
        throw new RuntimeTrap('R0029', 'body "' + at.id + '" orbits "' + centreId + '", and no body has that id')
      }
      if (centre.motion === 'loose') {
        throw new RuntimeTrap('R0029', 'body "' + at.id + '" orbits "' + centreId + '", which is loose: an orbit\'s centre stays put or moves on its own orbit')
      }
      if (seen.has(centreId)) {
        throw new RuntimeTrap('R0029', 'orbits go round in a circle at "' + centreId + '": a centre cannot orbit what orbits it')
      }
      seen.add(centreId)
      at = centre
    }
  }
  return world
}

// ---------------------------------------------------------------- what changed

export class WorldDiff {
  /** New ids: create them (and kick each whose kick.trigger is not 0, listed in `kick` as well). */
  create: BodySpec[] = []
  /** Ids that are gone. */
  remove: string[] = []
  /** Same id, but a different shape, size, die-ness, motion or mass: remove and create again. */
  recreate: BodySpec[] = []
  /** Same body, a new colour, glow, bounce or friction: update its material in place. */
  material: BodySpec[] = []
  /** A static or kinematic body put somewhere else, or turned: set its pose (a loose body's placement is the host's). */
  setPose: BodySpec[] = []
  /** Bodies to throw now: kick.trigger changed, or created with a trigger other than 0. */
  kick: BodySpec[] = []
  cameraChanged: boolean = false
  tableChanged: boolean = false
  floorChanged: boolean = false

  empty(): boolean {
    return this.create.length === 0 && this.remove.length === 0 && this.recreate.length === 0 && this.material.length === 0 &&
      this.setPose.length === 0 && this.kick.length === 0 && !this.cameraChanged && !this.tableChanged && !this.floorChanged
  }
}

function sameNumbers(a: number[], b: number[]): boolean {
  if (a.length !== b.length) { return false }
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false } }
  return true
}

function sameCamera(a: CameraSpec | null, b: CameraSpec | null): boolean {
  if (a === null || b === null) { return a === b }
  return a.x === b.x && a.y === b.y && a.z === b.z && a.lookX === b.lookX && a.lookY === b.lookY && a.lookZ === b.lookZ &&
    a.orbit === b.orbit
}

function sameTable(a: TableSpec | null, b: TableSpec | null): boolean {
  if (a === null || b === null) { return a === b }
  return a.width === b.width && a.depth === b.depth && a.color === b.color
}

function sameFloor(a: FloorSpec | null, b: FloorSpec | null): boolean {
  if (a === null || b === null) { return a === b }
  return a.color === b.color
}

/** What the renderer has to do to go from the world it shows to the next one. Pure. */
export function diffWorld(prev: WorldSpec | null, next: WorldSpec): WorldDiff {
  let diff = new WorldDiff()
  let before = new Map<string, BodySpec>()
  if (prev !== null) { for (let b of prev.bodies) { before.set(b.id, b) } }
  let kept = new Set<string>()
  for (let b of next.bodies) {
    let old = before.get(b.id)
    if (old === undefined) {
      diff.create.push(b)
      if (b.kick !== null && (b.kick as SceneKick).trigger !== 0) { diff.kick.push(b) }
      continue
    }
    kept.add(b.id)
    // A painted body's colours are in its mesh, so a new colour, pattern, rings or mark makes it again.
    if (old.shape !== b.shape || old.isDie !== b.isDie || !sameNumbers(old.dims, b.dims) || old.motion !== b.motion ||
        old.mass !== b.mass || old.pattern !== b.pattern || old.color2 !== b.color2 || !sameNumbers(old.rings, b.rings) ||
        old.ringColor !== b.ringColor || old.mark !== b.mark || (b.pattern.length > 0 && old.color !== b.color)) {
      diff.recreate.push(b)
    } else {
      if (old.color !== b.color || old.glow !== b.glow || old.restitution !== b.restitution || old.friction !== b.friction) {
        diff.material.push(b)
      }
      if (b.motion !== 'loose' && (!sameNumbers(old.position, b.position) || !sameNumbers(old.rotation, b.rotation))) {
        diff.setPose.push(b)
      }
    }
    let oldTrigger = old.kick !== null ? (old.kick as SceneKick).trigger : 0
    if (b.kick !== null && (b.kick as SceneKick).trigger !== oldTrigger) { diff.kick.push(b) }
  }
  if (prev !== null) {
    for (let b of prev.bodies) { if (!kept.has(b.id)) { diff.remove.push(b.id) } }
  }
  let prevCamera: CameraSpec | null = prev !== null ? prev.camera : null
  let prevTable: TableSpec | null = prev !== null ? prev.table : null
  let prevFloor: FloorSpec | null = prev !== null ? prev.floor : null
  diff.cameraChanged = !sameCamera(prevCamera, next.camera)
  diff.tableChanged = !sameTable(prevTable, next.table)
  diff.floorChanged = !sameFloor(prevFloor, next.floor)
  return diff
}

// ---------------------------------------------------------------- kinematic motion and dice

const DEG: number = Math.PI / 180

/**
 * Where every orbiting or spinning body is at tSeconds: [x, y, z, rx, ry, rz] (metres, degrees). An orbit is level,
 * counter-clockwise seen from above (from +x towards -z), round where its centre is at that moment, so a moon follows
 * its planet. A spin adds 360 * t / periodS to ry. Pure; decodeScene has already refused a chain that goes round.
 */
export function orbitPositions(spec: WorldSpec, tSeconds: number): Map<string, number[]> {
  let byId = new Map<string, BodySpec>()
  for (let b of spec.bodies) { byId.set(b.id, b) }
  let placed = new Map<string, number[]>()
  let result = new Map<string, number[]>()
  for (let b of spec.bodies) {
    if (b.motion !== 'kinematic') { continue }
    result.set(b.id, placeAt(b, byId, placed, tSeconds, 0))
  }
  return result
}

function placeAt(b: BodySpec, byId: Map<string, BodySpec>, placed: Map<string, number[]>, tSeconds: number, depth: number): number[] {
  let done = placed.get(b.id)
  if (done !== undefined) { return done }
  let p: number[] = [b.position[0], b.position[1], b.position[2]]
  let o = b.orbit
  if (o !== null && depth < MAX_WORLD_BODIES) {
    let centre = byId.get(o.centre)
    if (centre !== undefined) {
      let c = placeAt(centre, byId, placed, tSeconds, depth + 1)
      let turns = o.periodS !== 0 ? tSeconds / o.periodS : 0
      let a = (o.phaseDeg + 360 * turns) * DEG
      p = [c[0] + o.radius * Math.cos(a), c[1], c[2] - o.radius * Math.sin(a)]
    }
  }
  let ry = b.rotation[1]
  if (b.spinPeriodS !== 0) { ry += 360 * tSeconds / b.spinPeriodS }
  let out: number[] = [p[0], p[1], p[2], b.rotation[0], ry, b.rotation[2]]
  placed.set(b.id, out)
  return out
}

/**
 * The face of a die on top for its rotation quaternion: +Z 1, -Z 6, +X 3, -X 4, +Y 2, -Y 5 (the faces the renderer
 * paints, checked on the phone). Whichever local axis points most nearly up or down decides, by the world-y part of
 * each local axis.
 */
export function topFace(qx: number, qy: number, qz: number, qw: number): number {
  let ax = 2 * (qx * qy + qz * qw)
  let ay = 1 - 2 * (qx * qx + qz * qz)
  let az = 2 * (qy * qz - qx * qw)
  let bx = Math.abs(ax)
  let by = Math.abs(ay)
  let bz = Math.abs(az)
  if (bx >= by && bx >= bz) { return ax > 0 ? 3 : 4 }
  if (by >= bz) { return ay > 0 ? 2 : 5 }
  return az > 0 ? 1 : 6
}

// ---------------------------------------------------------------- the prompt

function paramText(p: GfxParam): string {
  return p.optional ? '[' + p.name + ']' : p.name
}

/** std/scene for the model's prompt: every function, the event and the contract. Generated, so it cannot drift. */
export function describeSceneForPrompt(): string {
  let lines: string[] = []
  lines.push('std/scene (always available as scene; a ui.World shows the scene.Thing[] its build function returns):')
  lines.push('  Units are metres; y is up and the floor or table top is y = 0, so a box of height h stands on it at y = h / 2.')
  for (let f of SCENE_FUNCTIONS) {
    let args: string[] = []
    for (let p of f.params) { args.push(p.kind === 'thing' ? 'thing: scene.Thing' : paramText(p)) }
    lines.push('  scene.' + f.name + '(' + args.join(', ') + '): scene.Thing  -- ' + f.summary)
  }
  let fields: string[] = []
  for (let pair of SCENE_EVENT_FIELDS) { fields.push(pair[0] + ': ' + pair[1]) }
  lines.push('  class scene.Event { ' + fields.join('; ') + ' }  -- kind is ' +
    SCENE_EVENT_KINDS.map((k: string): string => '"' + k + '"').join(', ') + ': tap is a finger on body (x, y, z where it touched), ' +
    'swipe a drag that started on body (speed is how fast), hit bodies knocking together, told at most four times a second: ' +
    'bodies every body knocked since the last hit and values how hard each was knocked (m/s), body and other the hardest pair ' +
    'and speed its speed; settled every ' +
    'loose body come to rest after a throw (bodies the ids; values the face each die shows, 1..6, and for any other body 1 when ' +
    'it was knocked from where it was built, moved or tipped over, else 0). body is "" for a tap on ' +
    'empty space')
  lines.push('  Wrappers take a thing and return it changed, so they nest: scene.kick(scene.loose(scene.die("d1", 0, 0.5, 0, 0.3, "white"), 1), ' +
    'state.throws, 2, 3, 0, 2). Without loose, kick, orbit or spin a body never moves.')
  lines.push('  Every body has an id of its own (two bodies with one id stop the program); at most ' + MAX_WORLD_BODIES.toString() +
    ' bodies, at most one camera, table and floor. Do not let bodies start inside one another or below y = 0.')
  lines.push('  build runs only when the state changes, never per frame: once a loose body exists the host moves it, and its x, y, z are ' +
    'only where it starts -- returning it again somewhere else does nothing. To throw it again change its kick trigger; to put it ' +
    'back, give it a new id (state.round in the id). Never keep positions or angles in the state to animate them: orbit, spin and ' +
    'kick do it.')
  lines.push('  A colour is a role -- ' + GFX_ROLES.join(' ') + ' -- or "#rrggbb", or gfx.rgb(...).')
  return lines.join('\n')
}
