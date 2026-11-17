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
import { MAX_SHAPE_POINTS, MAX_BODY_PARTS, outlineCheck, hullCheck, pointBounds, partBounds, partCount } from './VeraShapes'

/** Class identities of the module's two types, as the compiler names them. */
export const SCENE_THING: string = 'std/scene:Thing'
export const SCENE_EVENT: string = 'std/scene:Event'

/** The most bodies one world may hold (a camera, a table and a floor are not bodies). */
export const MAX_WORLD_BODIES: number = 300

/** The most stars scene.sky paints. */
export const MAX_SKY_STARS: number = 3000

/** The kinds of a scene.Event, in the order the prompt lists them. */
export const SCENE_EVENT_KINDS: string[] = ['tap', 'swipe', 'hit', 'settled']

/** Things that are bodies, which every wrapper takes; the rest (camera, table, floor) set up the world. */
const BODY_KINDS: string[] = ['box', 'sphere', 'cylinder', 'die', 'shape', 'hull', 'group']
/** scene.shape without scene.thick is a sheet this share of its larger side thick, and never thinner than SHEET_MIN metres. */
export const SHEET_RATIO: number = 0.01
export const SHEET_MIN: number = 0.001
/** The most parts one scene.group holds. */
export const MAX_GROUP_PARTS: number = 16

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
  new GfxFunction('shape', [str('id'), num('x'), num('y'), num('z'), new GfxParam('points', 'number[]'), color()], 'thing',
    'a flat body of any outline, thin as a sheet, lying level (wrap it in thick only for a thing with a thickness). points are its corners in order round it, [x1, z1, x2, z2, ...] in metres ' +
    'from x, z (3 to ' + MAX_SHAPE_POINTS.toString() + ' corners, sides not crossing; a star, an L or a letter is fine). For a ' +
    'shape that is not a box, ball or cylinder -- a triangle, a star, an arrow, a game piece; turn it to stand it up'),
  new GfxFunction('hull', [str('id'), num('x'), num('y'), num('z'), new GfxParam('points', 'number[]'), color()], 'thing',
    'the smallest convex body round points [x1, y1, z1, x2, y2, z2, ...] in metres from x, y, z (4 to ' +
    MAX_SHAPE_POINTS.toString() + ' points, not all in one plane): a pyramid, a crystal, a gem, a wedge'),
  new GfxFunction('group', [str('id'), num('x'), num('y'), num('z'), new GfxParam('parts', 'thing[]')], 'thing',
    'one rigid body made of parts -- an animal, a vehicle, a snowman, furniture: each part a box, sphere, cylinder, shape or ' +
    'hull placed by its own x, y, z from the group\'s x, y, z (turn a part to tilt it; 1 to ' + MAX_GROUP_PARTS.toString() +
    ' parts). The group falls, is thrown, turns and is tapped as one body (a tap tells the part in e.other); wrap the group, ' +
    'never a part, in loose, kick, spin, orbit, glow or mark'),
  new GfxFunction('die', [str('id'), num('x'), num('y'), num('z'), num('size'), color()], 'thing',
    'a die with pips, a cube of side size centred on x, y, z; when it comes to rest the event "settled" tells the face on top ' +
    '(1..6) in e.values, in the order of e.bodies'),
  new GfxFunction('table', [num('width'), num('depth'), color()], 'thing',
    'a table top at y = 0, width by depth, centred on 0, 0, with low walls round it: loose bodies stay on it. Use it for dice and ' +
    'for anything thrown'),
  new GfxFunction('floor', [color()], 'thing',
    'the ground at y = 0, as far as the eye sees. With no table or floor nothing falls: loose bodies float'),
  new GfxFunction('sky', [color(), num('stars')], 'thing',
    'what is behind the world: its colour and how many stars are painted in it (0 to ' + MAX_SKY_STARS.toString() + '; ' +
    'they turn with the view and never move by themselves). Without it the world stands on the app\'s own background. ' +
    'At most one'),
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
  new GfxFunction('thick', [thing(), num('h')], 'thing',
    'gives a scene.shape a thickness of h metres (y), for a thing that has one: a tile, a coin, a game piece, a slab. ' +
    'Never for a thing asked for flat or thin: without it a shape is already a flat sheet'),
  new GfxFunction('glow', [thing()], 'thing',
    'the thing shines by itself, casts no shadow and, if it stands still, lights the bodies round it from where it is, ' +
    'each brighter on its side facing it: a sun, a lamp, a fire'),
  new GfxFunction('paint', [thing(), str('pattern'), new GfxParam('color2', 'color')], 'thing',
    'a ball\'s surface: pattern drawn in the ball\'s own colour and color2, so it reads as what it is -- ' +
    SURFACE_PATTERNS.map((p: string[]): string => '"' + p[0] + '" ' + p[1]).join('; ') +
    '. With scene.spin the pattern turns, so the ball is seen turning'),
  new GfxFunction('rings', [thing(), num('inner'), num('outer'), color()], 'thing',
    'flat rings round the thing\'s equator from radius inner to outer (metres from its centre, both beyond its radius), ' +
    'tilted and carried with it'),
  new GfxFunction('mark', [thing(), color()], 'thing',
    'a thin ring round the thing that marks it, in the colour (the accent): the body the person selected'),
  new GfxFunction('trail', [thing()], 'thing',
    'the thing\'s path is drawn as a faint line: the circle of an orbit round a centre that stays put'),
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
  /** 'box' | 'sphere' | 'cylinder' | 'die' | 'shape' | 'hull' | 'table' | 'floor' | 'camera' */
  kind: string = ''
  /** scene.shape's outline [x1, z1, ...] or scene.hull's points [x1, y1, z1, ...], about x, y, z; [] for the rest. */
  points: number[] = []
  /** scene.group's parts, each placed about the group's x, y, z; [] for the rest. */
  parts: SceneThing[] = []
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
  /** scene.trail: its path is drawn. */
  trail: boolean = false
  /** scene.sky: how many stars. */
  stars: number = 0

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
    t.trail = this.trail; t.stars = this.stars; t.points = this.points; t.parts = this.parts
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

/** A number[] argument, every element finite, at most `most` numbers. */
function asNumbers(args: RuntimeValue[], i: number, what: string, most: number): number[] {
  let v = i < args.length ? args[i] : null
  if (!(v instanceof VeraArrayValue)) { throw new RuntimeTrap('R0020', 'scene: ' + what + ' must be a number[]') }
  let items = (v as VeraArrayValue).elements
  if (items.length > most) {
    throw new RuntimeTrap('R0029', 'scene: ' + what + ' holds at most ' + most.toString() + ' numbers; got ' + items.length.toString())
  }
  let out: number[] = []
  for (let item of items) {
    if (!(item instanceof VeraNumberValue)) { throw new RuntimeTrap('R0020', 'scene: ' + what + ' must be a number[]') }
    out.push(finite((item as VeraNumberValue).value, what))
  }
  return out
}

/**
 * The body put where its points' box is centred, and the points moved to match: its x, y, z, w, h, d are then that box,
 * as every other body's are, so placing it, resting it on others and framing it need nothing of their own.
 */
function centreOnPoints(t: SceneThing, points: number[], dims: number): void {
  let b = pointBounds(points, dims)
  let cx = (b[0] + b[dims]) / 2
  let cy = dims === 3 ? (b[1] + b[4]) / 2 : 0
  let cz = dims === 3 ? (b[2] + b[5]) / 2 : (b[1] + b[3]) / 2
  let out: number[] = []
  for (let i = 0; i < points.length; i += dims) {
    if (dims === 3) { out.push(points[i] - cx, points[i + 1] - cy, points[i + 2] - cz) } else { out.push(points[i] - cx, points[i + 1] - cz) }
  }
  t.points = out
  t.x += cx; t.y += cy; t.z += cz
  t.w = b[dims] - b[0]
  if (dims === 3) {
    t.h = b[4] - b[1]
    t.d = b[5] - b[2]
  } else {
    t.d = b[3] - b[1]
  }
}

/**
 * scene.group's parts: bodies a group may hold, each still where the program put it (its x, y, z about the group's).
 * What moves, lights or marks a body is the group's to have: a part wrapped in one is refused with what to do instead.
 */
function asParts(args: RuntimeValue[], i: number, groupId: string): SceneThing[] {
  let v = i < args.length ? args[i] : null
  if (!(v instanceof VeraArrayValue)) { throw new RuntimeTrap('R0020', 'scene.group: parts must be a scene.Thing[]') }
  let items = (v as VeraArrayValue).elements
  let where = 'scene.group "' + groupId + '"'
  if (items.length < 1 || items.length > MAX_GROUP_PARTS) {
    throw new RuntimeTrap('R0029', where + ' holds 1 to ' + MAX_GROUP_PARTS.toString() + ' parts; got ' + items.length.toString())
  }
  let out: SceneThing[] = []
  let ids = new Set<string>()
  let pieces = 0
  for (let item of items) {
    if (!(item instanceof SceneThingValue)) { throw new RuntimeTrap('R0020', where + ': parts must be scene.Things') }
    let t = (item as SceneThingValue).thing
    let part = where + ': part "' + t.id + '"'
    if (t.kind === 'group') { throw new RuntimeTrap('R0029', part + ' is a group: put its parts in this group instead') }
    if (t.kind === 'die') { throw new RuntimeTrap('R0029', part + ' is a die: a die is a body of its own, not a part') }
    if (BODY_KINDS.indexOf(t.kind) < 0) {
      throw new RuntimeTrap('R0029', part + ' is a ' + t.kind + ': a part is a box, sphere, cylinder, shape or hull')
    }
    let moved = t.motion !== 'static' || t.kick !== null || t.orbit !== null || t.spinPeriodS !== 0
    if (moved || t.glow || t.mark.length > 0 || t.trail || t.ringOuter > 0) {
      throw new RuntimeTrap('R0029', part + ' is wrapped in loose, kick, spin, orbit, glow, mark, trail or rings: wrap the ' +
        'group instead -- its parts move, shine and are marked with it')
    }
    if (ids.has(t.id)) { throw new RuntimeTrap('R0029', where + ': two parts have the id "' + t.id + '"') }
    ids.add(t.id)
    pieces += partCount(t.kind, t.points)
    out.push(t.copy())
  }
  if (pieces > MAX_BODY_PARTS) {
    throw new RuntimeTrap('R0029', where + ' is cut into ' + pieces.toString() + ' convex pieces, more than ' +
      MAX_BODY_PARTS.toString() + ': use fewer parts or simpler outlines')
  }
  return out
}

/** The group put where the box round its parts is centred, the parts moved to match, and its w, h, d that box. */
function centreOnParts(t: SceneThing): void {
  let all: number[] = []
  for (let p of t.parts) {
    let b = partBounds(p.kind, [p.w, p.h, p.d], p.points, [p.x, p.y, p.z], [p.rx, p.ry, p.rz])
    all.push(b[0], b[1], b[2], b[3], b[4], b[5])
  }
  let b = pointBounds(all, 3)
  let cx = (b[0] + b[3]) / 2
  let cy = (b[1] + b[4]) / 2
  let cz = (b[2] + b[5]) / 2
  for (let p of t.parts) { p.x -= cx; p.y -= cy; p.z -= cz }
  t.x += cx; t.y += cy; t.z += cz
  t.w = b[3] - b[0]; t.h = b[4] - b[1]; t.d = b[5] - b[2]
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
    throw new RuntimeTrap('R0020', 'scene.' + fn + ' takes a scene.Thing made by scene.box, sphere, cylinder, die, shape, hull or group')
  }
  let t = (v as SceneThingValue).thing
  if (BODY_KINDS.indexOf(t.kind) < 0) {
    throw new RuntimeTrap('R0029', 'scene.' + fn + ' takes a body (box, sphere, cylinder, die, shape, hull, group), not the ' + t.kind)
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
    case 'shape': {
      let t = body('shape', args)
      let points = asNumbers(args, 4, 'points', 2 * MAX_SHAPE_POINTS)
      let why = outlineCheck(points)
      if (why.length > 0) { throw new RuntimeTrap('R0029', 'scene.shape "' + t.id + '": ' + why) }
      centreOnPoints(t, points, 2)
      // A sheet: as thin as a hundredth of its larger side, a millimetre at least (the physics needs a volume).
      t.h = Math.max(SHEET_MIN, SHEET_RATIO * Math.max(t.w, t.d))
      t.color = asStr(args, 5)
      return wrap(t)
    }
    case 'hull': {
      let t = body('hull', args)
      let points = asNumbers(args, 4, 'points', 3 * MAX_SHAPE_POINTS)
      let why = hullCheck(points)
      if (why.length > 0) { throw new RuntimeTrap('R0029', 'scene.hull "' + t.id + '": ' + why) }
      centreOnPoints(t, points, 3)
      t.color = asStr(args, 5)
      return wrap(t)
    }
    case 'group': {
      let t = body('group', args)
      t.parts = asParts(args, 4, t.id)
      centreOnParts(t)
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
    case 'sky': {
      let t = new SceneThing()
      t.kind = 'sky'
      t.color = asStr(args, 0)
      t.stars = Math.round(Math.max(0, Math.min(MAX_SKY_STARS, asNum(args, 1, 'stars'))))
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
    case 'thick': {
      let t = asBody(args, 'thick')
      let h = asNum(args, 1, 'h')
      if (t.kind !== 'shape') {
        throw new RuntimeTrap('R0029', 'scene.thick takes a scene.shape, not a ' + t.kind + ': give a ' + t.kind + ' its size where it is made')
      }
      if (!(h > 0)) { throw new RuntimeTrap('R0029', 'scene.thick "' + t.id + '": h must be more than 0; got ' + h.toString() + ' (a shape without thick is already flat)') }
      t.h = h
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
    case 'trail': {
      let t = asBody(args, 'trail')
      t.trail = true
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

export class SkySpec {
  color: string = ''
  stars: number = 0
}

export class BodySpec {
  id: string = ''
  /** 'box' | 'sphere' | 'cylinder' | 'shape' | 'hull' (a die is a box with isDie) */
  shape: string = 'box'
  /** A shape's outline [x1, z1, ...] or a hull's points [x1, y1, z1, ...], about its position; [] for the rest. */
  points: number[] = []
  /** A group's parts, each with its position and rotation about the group's centre; [] for the rest. */
  parts: BodySpec[] = []
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
  /** scene.trail: its path is drawn. */
  trail: boolean = false
}

export class WorldSpec {
  camera: CameraSpec | null = null
  floor: FloorSpec | null = null
  table: TableSpec | null = null
  sky: SkySpec | null = null
  bodies: BodySpec[] = []
}

function bodySpec(t: SceneThing): BodySpec {
  let b = new BodySpec()
  b.id = t.id
  b.shape = t.kind === 'die' ? 'box' : t.kind
  b.dims = [t.w, t.h, t.d]
  b.points = t.points
  b.parts = t.parts.map((p: SceneThing): BodySpec => bodySpec(p))
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
  b.trail = t.trail
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
    } else if (t.kind === 'sky') {
      if (world.sky !== null) { throw new RuntimeTrap('R0029', 'a world has at most one scene.sky') }
      let k = new SkySpec()
      k.color = t.color
      k.stars = t.stars
      world.sky = k
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
  /** The sky, or which bodies leave a trail: only what is painted behind the world changes. */
  backdropChanged: boolean = false

  empty(): boolean {
    return this.create.length === 0 && this.remove.length === 0 && this.recreate.length === 0 && this.material.length === 0 &&
      this.setPose.length === 0 && this.kick.length === 0 && !this.cameraChanged && !this.tableChanged && !this.floorChanged &&
      !this.backdropChanged
  }
}

/** Everything about a group's parts that its body is made from: a change to any of it makes the group again. */
function partsKey(b: BodySpec): string {
  if (b.parts.length === 0) { return '' }
  return JSON.stringify(b.parts.map((p: BodySpec): string => [p.id, p.shape, p.dims.join(','), p.points.join(','),
    p.position.join(','), p.rotation.join(','), p.color, p.pattern, p.color2].join('|')))
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

/** What the backdrop paints from: the sky and the bodies leaving a trail. */
function backdropKey(w: WorldSpec | null): string {
  if (w === null) { return '' }
  let sky = w.sky !== null ? (w.sky as SkySpec).color + '/' + (w.sky as SkySpec).stars.toString() : '-'
  return sky + '|' + w.bodies.filter((b: BodySpec): boolean => b.trail).map((b: BodySpec): string => b.id).join(',')
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
    if (old.shape !== b.shape || old.isDie !== b.isDie || !sameNumbers(old.dims, b.dims) || !sameNumbers(old.points, b.points) ||
        partsKey(old) !== partsKey(b) ||
        old.motion !== b.motion ||
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
  diff.backdropChanged = backdropKey(prev) !== backdropKey(next)
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

/** Degrees turned by tSeconds at one turn every periodS (0: not turning). */
function turnedDeg(tSeconds: number, periodS: number): number {
  return periodS !== 0 ? 360 * tSeconds / periodS : 0
}

/** The starting angle that, at periodS, is where oldStart at oldPeriodS is at tSeconds: the motion goes on from there. */
function carriedStart(oldStart: number, oldPeriodS: number, periodS: number, tSeconds: number): number {
  let a = (oldStart + turnedDeg(tSeconds, oldPeriodS) - turnedDeg(tSeconds, periodS)) % 360
  return a < 0 ? a + 360 : a
}

class CarriedMotion {
  centre: string = ''
  /** As the program wrote them. */
  periodS: number = 0
  phaseDeg: number = 0
  spinPeriodS: number = 0
  ry: number = 0
  /** What the host uses, so the motion goes on from where it was. */
  phaseUsed: number = 0
  ryUsed: number = 0
}

/**
 * Orbits and spins as a pure function of time put a body wherever start + 360 * t / period says, so a new state that only
 * changes a period (a Faster button dividing every period by the speed) would throw each body to another place on its
 * orbit -- after a minute, many turns away. The host keeps, per body, what the program wrote and the start it really uses:
 * when only the period changes, the start is moved so the body is where it was at that moment and goes on at the new
 * period. A start the program changed itself, or a new centre, is taken as written. One per world, fed every spec it shows
 * at the world's own time; it rewrites the spec's orbit (copied) and starting ry in place.
 */
export class MotionCarry {
  private bodies: Map<string, CarriedMotion> = new Map<string, CarriedMotion>()

  apply(spec: WorldSpec, tSeconds: number): void {
    let next = new Map<string, CarriedMotion>()
    for (let b of spec.bodies) {
      if (b.motion !== 'kinematic') { continue }
      let o = b.orbit
      let m = new CarriedMotion()
      m.centre = o !== null ? o.centre : ''
      m.periodS = o !== null ? o.periodS : 0
      m.phaseDeg = o !== null ? o.phaseDeg : 0
      m.spinPeriodS = b.spinPeriodS
      m.ry = b.rotation[1]
      m.phaseUsed = m.phaseDeg
      m.ryUsed = m.ry
      let old = this.bodies.get(b.id)
      if (old !== undefined) {
        if (o !== null && old.centre === m.centre && old.phaseDeg === m.phaseDeg) {
          m.phaseUsed = old.periodS === m.periodS ? old.phaseUsed : carriedStart(old.phaseUsed, old.periodS, m.periodS, tSeconds)
        }
        if (old.ry === m.ry) {
          m.ryUsed = old.spinPeriodS === m.spinPeriodS ? old.ryUsed : carriedStart(old.ryUsed, old.spinPeriodS, m.spinPeriodS, tSeconds)
        }
      }
      if (o !== null && m.phaseUsed !== m.phaseDeg) {
        let c = new SceneOrbit()
        c.centre = o.centre
        c.radius = o.radius
        c.periodS = o.periodS
        c.phaseDeg = m.phaseUsed
        b.orbit = c
      }
      if (m.ryUsed !== m.ry) { b.rotation = [b.rotation[0], m.ryUsed, b.rotation[2]] }
      next.set(b.id, m)
    }
    this.bodies = next
  }
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
    for (let p of f.params) {
      args.push(p.kind === 'thing' ? 'thing: scene.Thing' : p.kind === 'thing[]' ? p.name + ': scene.Thing[]'
        : p.kind === 'number[]' ? p.name + ': number[]' : paramText(p))
    }
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
    'empty space; a tap on a group is its id in body and the part tapped in other')
  lines.push('  Wrappers take a thing and return it changed, so they nest: scene.kick(scene.loose(scene.die("d1", 0, 0.5, 0, 0.3, "white"), 1), ' +
    'state.throws, 2, 3, 0, 2). Without loose, kick, orbit or spin a body never moves.')
  lines.push('  Every body has an id of its own (two bodies with one id stop the program); at most ' + MAX_WORLD_BODIES.toString() +
    ' bodies, at most one camera, table, floor and sky. Do not let bodies start inside one another or below y = 0.')
  lines.push('  build runs only when the state changes, never per frame: once a loose body exists the host moves it, and its x, y, z are ' +
    'only where it starts -- returning it again somewhere else does nothing. To throw it again change its kick trigger; to put it ' +
    'back, give it a new id (state.round in the id). Never keep positions or angles in the state to animate them: orbit, spin and ' +
    'kick do it.')
  lines.push('  A colour is a role -- ' + GFX_ROLES.join(' ') + ' -- or "#rrggbb", or gfx.rgb(...).')
  return lines.join('\n')
}
