/**
 * std/gfx: what a ui.Surface draws, and how it is drawn.
 *
 * Everything else a program shows is a tree of catalogue components that the
 * renderer lays out and the theme dresses. A surface is the one place that is
 * not true: the program owns every pixel of a box, in its own units, and says
 * what goes where each frame -- a game, a drawing tool, a simulation. So the
 * shapes here carry positions, sizes and colours, which nothing in std/ui does.
 *
 * One table (GFX_FUNCTIONS) is the module: the compiler's interface, the
 * colour check and the prompt's description are generated from it, the way
 * std/ui's are from VeraUiCatalog. Shapes are built by the host as the program
 * calls these functions, decoded into plain GfxOps once per frame, and painted
 * by paintGfx -- the same code on the phone (into an ArkUI Canvas) and on the
 * host (into an SVG recorder in tools/vera-harness), so a proof sheet shows
 * what the phone draws rather than a second opinion of it.
 *
 * Pure apart from paintGfx, which only calls the context it is handed.
 */

import { RuntimeValue, VeraNumberValue, VeraStringValue, VeraBooleanValue, VeraArrayValue, VeraObjectValue,
  RuntimeTrap } from './VeraInterpreter'
import { GfxOp, GFX_ROLES, isGfxColor, gfxColor, hex2, DRIFT_DIRECTIONS, DRIFT_SPEEDS, MAX_GFX_REPEAT } from './GfxPaint'
export { GfxOp, GfxFit, GFX_ROLES, isGfxColor, gfxColor, gfxFit, gfxToSurface, gfxNaturalHeight, encodeGfxOps, decodeGfxOps, paintGfx, DRIFT_DIRECTIONS, DRIFT_SPEEDS, MAX_GFX_REPEAT } from './GfxPaint'

/** Class identities of the module's two types, as the compiler names them. */
export const GFX_SHAPE: string = 'std/gfx:Shape'
export const GFX_POINTER: string = 'std/gfx:Pointer'

/** The most shapes one frame may draw, counting the inside of every group and every copy a gfx.repeat makes. Past it the frame traps rather than stalls. */
export const MAX_GFX_SHAPES: number = 4000
/** Groups inside groups, at most. */
export const MAX_GFX_DEPTH: number = 12
/** The most numbers one polyline or polygon may hold: 1000 points. */
export const MAX_GFX_POINTS: number = 2000

export class GfxParam {
  name: string
  /** 'number' | 'string' | 'boolean' | 'number[]' | 'shapes' | 'color' | 'colors' (a string[] of colours); std/scene adds 'thing' and 'thing[]' */
  kind: string
  optional: boolean
  constructor(name: string, kind: string, optional: boolean = false) {
    this.name = name; this.kind = kind; this.optional = optional
  }
}

export class GfxFunction {
  name: string
  params: GfxParam[]
  /** 'shape' | 'string' | 'number' | 'boolean' */
  result: string
  summary: string
  constructor(name: string, params: GfxParam[], result: string, summary: string) {
    this.name = name; this.params = params; this.result = result; this.summary = summary
  }
}

function num(name: string): GfxParam { return new GfxParam(name, 'number') }
function color(): GfxParam { return new GfxParam('color', 'color') }

export const GFX_FUNCTIONS: GfxFunction[] = [
  new GfxFunction('rect', [num('x'), num('y'), num('width'), num('height'), color()], 'shape',
    'a filled rectangle; x, y is its top-left corner'),
  new GfxFunction('roundRect', [num('x'), num('y'), num('width'), num('height'), num('radius'), color()], 'shape',
    'a filled rectangle with rounded corners'),
  new GfxFunction('circle', [num('x'), num('y'), num('radius'), color()], 'shape',
    'a filled disc centred on x, y'),
  new GfxFunction('arc', [num('x'), num('y'), num('radius'), num('startDegrees'), num('sweepDegrees'), num('lineWidth'), color()],
    'shape', 'a stroked arc centred on x, y; 0 degrees is twelve o\'clock and angles run clockwise; sweep 360 is a ring'),
  new GfxFunction('sector', [num('x'), num('y'), num('radius'), num('startDegrees'), num('sweepDegrees'), color()], 'shape',
    'a filled pie slice from the centre x, y out to radius, angles as gfx.arc (0 is twelve o\'clock, clockwise): one slice of a wheel, ' +
    'a pie chart or a pizza; a wheel of n slices is n sectors of sweep 360 / n, each starting where the last ended'),
  new GfxFunction('line', [num('x1'), num('y1'), num('x2'), num('y2'), num('lineWidth'), color()], 'shape',
    'a straight line with round ends'),
  new GfxFunction('polyline', [new GfxParam('points', 'number[]'), num('lineWidth'), color()], 'shape',
    'a stroked open line through [x0, y0, x1, y1, ...]; for a graph, a trail, a drawn stroke'),
  new GfxFunction('polygon', [new GfxParam('points', 'number[]'), color()], 'shape',
    'a filled closed shape through [x0, y0, x1, y1, ...]; for a star, a ship, a mountain'),
  new GfxFunction('path', [new GfxParam('commands', 'string'), color()], 'shape',
    'a filled SVG path (M L C Q A Z, absolute) in surface units'),
  new GfxFunction('strokePath', [new GfxParam('commands', 'string'), num('lineWidth'), color()], 'shape',
    'an SVG path drawn as a line rather than filled'),
  new GfxFunction('text', [num('x'), num('y'), num('size'), new GfxParam('align', 'string'), color(),
    new GfxParam('text', 'string'), new GfxParam('bold', 'boolean', true)], 'shape',
    'one line of text; align is "left", "center" or "right" about x, and y is the middle of the line'),
  new GfxFunction('group', [num('x'), num('y'), num('rotation'), num('scale'), num('alpha'), new GfxParam('shapes', 'shapes')],
    'shape', 'shapes drawn around their own 0, 0, moved to x, y, turned clockwise by rotation degrees, scaled, and faded by alpha (0..1)'),
  new GfxFunction('linear', [num('x1'), num('y1'), num('x2'), num('y2'), new GfxParam('colors', 'colors')], 'string',
    'a colour that runs from the first of colors at x1, y1 to the last at x2, y2, evenly through the rest: give it to any shape ' +
    'in place of a colour (a sky, a sea, a metal bar); the points are in the units the shape is drawn in'),
  new GfxFunction('radial', [num('x'), num('y'), num('radius'), new GfxParam('colors', 'colors')], 'string',
    'a colour that spreads from the first of colors at x, y to the last at radius: give it to a circle for a ball with depth -- ' +
    'a light colour first, centred a little up and left of the middle, the darkest last'),
  new GfxFunction('glow', [num('blur'), color(), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes with a soft light of color around them, blur units wide: a lamp, a neon line, a star, a magic spark'),
  new GfxFunction('shadow', [num('dx'), num('dy'), num('blur'), color(), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes with a soft shadow of color moved by dx, dy: a thing standing or floating above the ground (color "#00000055")'),
  new GfxFunction('blur', [num('radius'), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes blurred by radius units: mist, a soft cloud, light far away'),
  new GfxFunction('blend', [new GfxParam('mode', 'string'), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes mixed with what is under them: "add" makes light (overlaps glow brighter), "screen" lightens, "multiply" darkens like ink'),
  new GfxFunction('moving', [new GfxParam('motion', 'string'), num('trigger'), num('pivotX'), num('pivotY'), new GfxParam('shapes', 'shapes')], 'shape',
    'the part of the picture that moves -- a pendulum\'s bob and rod, a wheel, a ball, the frog and not its pond: its shapes play the motion ' +
    '(a ui.Motion style) about pivotX, pivotY, where the part is fixed or turns (the top of a pendulum, the wheel\'s centre), while the rest ' +
    'of the picture stays still; a touch on the picture plays every part, and so does a change of trigger (0, or a number the state really ' +
    'changes with). Only among the shapes the draw function returns, not inside a group or an effect; at most 3 in a picture'),
  new GfxFunction('drift', [new GfxParam('direction', 'string'), new GfxParam('speed', 'string'), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes that keep moving and never stop -- clouds drifting, fish swimming, rain or snow falling, stars streaming: they are a tile the size ' +
    'of the picture that slides on and on towards direction ("left", "right", "up", "down") at speed ("slow", "medium", "fast") and comes back ' +
    'in from the other side, so spread them over the whole picture; on a home-screen card it is the one thing that moves without a touch. ' +
    'Only among the shapes the draw function returns, at most 2 in a picture'),
  new GfxFunction('repeat', [num('columns'), num('rows'), num('dx'), num('dy'), new GfxParam('shapes', 'shapes')], 'shape',
    'shapes drawn columns x rows times, each copy dx further right and dy further down than the one before (the first where the shapes ' +
    'are): bubble wrap, a wall of bricks, a grid of stars, seats or dots -- many of the same, written once; at most ' +
    MAX_GFX_REPEAT.toString() + ' copies. Draw what differs from copy to copy (a popped bubble) over it as shapes of its own'),
  new GfxFunction('rgb', [num('red'), num('green'), num('blue'), new GfxParam('alpha', 'number', true)], 'string',
    'a colour from 0..255 channels and an optional 0..1 alpha, for colours computed at run time'),
  new GfxFunction('distance', [num('x1'), num('y1'), num('x2'), num('y2')], 'number',
    'the distance between two points'),
  new GfxFunction('inside', [num('px'), num('py'), num('x'), num('y'), num('width'), num('height')], 'boolean',
    'whether point px, py lies in the rectangle x, y, width, height'),
]

/** The fields of gfx.Pointer, in the order the prompt lists them. */
export const GFX_POINTER_FIELDS: string[][] = [
  ['phase', 'string'], ['id', 'number'], ['x', 'number'], ['y', 'number'],
]

export const POINTER_PHASES: string[] = ['down', 'move', 'up', 'cancel']

/** gfx.blend's modes. */
export const GFX_BLEND_MODES: string[] = ['add', 'screen', 'multiply']

export function gfxFunction(name: string): GfxFunction | null {
  for (let f of GFX_FUNCTIONS) { if (f.name === name) { return f } }
  return null
}

/** A shape as the VM carries it: an object of class gfx.Shape with nothing in it a program can read. */
export class GfxShapeValue extends VeraObjectValue {
  op: GfxOp
  constructor(op: GfxOp) {
    super(GFX_SHAPE, new Map<string, RuntimeValue>())
    this.op = op
  }
}

function asNum(args: RuntimeValue[], i: number, fallback: number = 0): number {
  if (i >= args.length) { return fallback }
  let v = args[i]
  if (v instanceof VeraNumberValue) { return (v as VeraNumberValue).value }
  throw new RuntimeTrap('R0020', 'expected number argument')
}

function asStr(args: RuntimeValue[], i: number, fallback: string = ''): string {
  if (i >= args.length) { return fallback }
  let v = args[i]
  if (v instanceof VeraStringValue) { return (v as VeraStringValue).value }
  throw new RuntimeTrap('R0020', 'expected string argument')
}

function asBool(args: RuntimeValue[], i: number, fallback: boolean = false): boolean {
  if (i >= args.length) { return fallback }
  let v = args[i]
  if (v instanceof VeraBooleanValue) { return (v as VeraBooleanValue).value }
  throw new RuntimeTrap('R0020', 'expected boolean argument')
}

function asNumbers(args: RuntimeValue[], i: number): number[] {
  if (i >= args.length) { return [] }
  let v = args[i]
  if (!(v instanceof VeraArrayValue)) { throw new RuntimeTrap('R0020', 'expected array argument') }
  let items = (v as VeraArrayValue).elements
  if (items.length > MAX_GFX_POINTS) {
    throw new RuntimeTrap('R0028', 'a polyline or polygon holds at most ' + (MAX_GFX_POINTS / 2).toString() +
      ' points; got ' + Math.floor(items.length / 2).toString())
  }
  let out: number[] = []
  for (let item of items) {
    if (item instanceof VeraNumberValue) { out.push((item as VeraNumberValue).value) }
  }
  return out
}

function asStrings(args: RuntimeValue[], i: number): string[] {
  if (i >= args.length) { return [] }
  let v = args[i]
  if (!(v instanceof VeraArrayValue)) { throw new RuntimeTrap('R0020', 'expected array argument') }
  let out: string[] = []
  for (let item of (v as VeraArrayValue).elements) {
    if (item instanceof VeraStringValue) { out.push((item as VeraStringValue).value) }
  }
  return out
}

/** A gradient's numbers, rounded so the colour string stays short in a card's frame. */
function gradientNumber(n: number): string {
  return isFinite(n) ? (Math.round(n * 100) / 100).toString() : 'NaN'
}

/**
 * Children of a shape that holds others (group, fx, moving, drift, repeat): counted and nested as the frame limits say. `count` is what is
 * written (a card holds that many), `drawn` what is painted: a repeat's shapes once each for the first, once for every copy for the second.
 */
function holding(o: GfxOp, children: GfxOp[]): RuntimeValue {
  o.children = children
  let count = 1
  let inside = 0
  let depth = 0
  for (let c of o.children) {
    count += c.count
    inside += c.drawn
    if (c.depth + 1 > depth) { depth = c.depth + 1 }
  }
  let drawn = 1 + inside * (o.kind === 'repeat' ? o.w * o.h : 1)
  if (depth > MAX_GFX_DEPTH) {
    throw new RuntimeTrap('R0028', 'groups nest at most ' + MAX_GFX_DEPTH.toString() + ' deep')
  }
  if (drawn > MAX_GFX_SHAPES) {
    throw new RuntimeTrap('R0028', 'one frame draws at most ' + MAX_GFX_SHAPES.toString() + ' shapes')
  }
  o.count = count
  o.drawn = drawn
  o.depth = depth
  return shape(o)
}

/** The shapes in an array, each once; anything that is not a shape is not drawn. */
function shapesIn(value: RuntimeValue): GfxOp[] {
  let out: GfxOp[] = []
  if (!(value instanceof VeraArrayValue)) { return out }
  for (let item of (value as VeraArrayValue).elements) {
    if (item instanceof GfxShapeValue) { out.push((item as GfxShapeValue).op) }
  }
  return out
}

/** A gfx.repeat's columns or rows: a whole number, none for one that is not a number or below zero. */
function copies(n: number): number {
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

function shape(op: GfxOp): RuntimeValue {
  return new GfxShapeValue(op)
}

function op(kind: string, colour: string): GfxOp {
  let o = new GfxOp()
  o.kind = kind
  o.color = colour
  return o
}

/** The host side of `import * as gfx from "std/gfx"`. */
export function invokeStdGfx(name: string, args: RuntimeValue[]): RuntimeValue {
  switch (name) {
    case 'rect':
    case 'roundRect': {
      let round = name === 'roundRect'
      let o = op(name, asStr(args, round ? 5 : 4))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.w = asNum(args, 2); o.h = asNum(args, 3)
      o.r = round ? asNum(args, 4) : 0
      return shape(o)
    }
    case 'circle': {
      let o = op('circle', asStr(args, 3))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.r = asNum(args, 2)
      return shape(o)
    }
    case 'arc': {
      let o = op('arc', asStr(args, 6))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.r = asNum(args, 2)
      o.start = asNum(args, 3); o.sweep = asNum(args, 4); o.lineWidth = asNum(args, 5)
      return shape(o)
    }
    case 'sector': {
      let o = op('sector', asStr(args, 5))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.r = asNum(args, 2)
      o.start = asNum(args, 3); o.sweep = asNum(args, 4)
      return shape(o)
    }
    case 'line': {
      let o = op('line', asStr(args, 5))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.w = asNum(args, 2); o.h = asNum(args, 3)
      o.lineWidth = asNum(args, 4)
      return shape(o)
    }
    case 'polyline': {
      let o = op('polyline', asStr(args, 2))
      o.points = asNumbers(args, 0); o.lineWidth = asNum(args, 1)
      return shape(o)
    }
    case 'polygon': {
      let o = op('polygon', asStr(args, 1))
      o.points = asNumbers(args, 0)
      return shape(o)
    }
    case 'path': {
      let o = op('path', asStr(args, 1))
      o.text = asStr(args, 0)
      return shape(o)
    }
    case 'strokePath': {
      let o = op('strokePath', asStr(args, 2))
      o.text = asStr(args, 0); o.lineWidth = asNum(args, 1)
      return shape(o)
    }
    case 'text': {
      let o = op('text', asStr(args, 4))
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.size = asNum(args, 2)
      let align = asStr(args, 3)
      o.align = align === 'center' || align === 'right' ? align : 'left'
      o.text = asStr(args, 5)
      o.bold = asBool(args, 6)
      return shape(o)
    }
    case 'group': {
      let o = op('group', '')
      o.x = asNum(args, 0); o.y = asNum(args, 1); o.start = asNum(args, 2)
      o.r = asNum(args, 3, 1); o.size = Math.max(0, Math.min(1, asNum(args, 4, 1)))
      return holding(o, args.length > 5 ? shapesIn(args[5]) : [])
    }
    case 'linear':
    case 'radial': {
      let n = name === 'linear' ? 4 : 3
      let numbers: string[] = []
      for (let i = 0; i < n; i++) { numbers.push(gradientNumber(asNum(args, i))) }
      let colours = asStrings(args, n).map((c: string): string => c.replace(/[|:]/g, ''))
      return new VeraStringValue((name === 'linear' ? 'lin:' : 'rad:') + numbers.join(',') + ':' + colours.join('|'))
    }
    case 'moving': {
      let o = op('moving', '')
      o.fx = asStr(args, 0); o.sweep = asNum(args, 1); o.x = asNum(args, 2); o.y = asNum(args, 3)
      return holding(o, args.length > 4 ? shapesIn(args[4]) : [])
    }
    case 'repeat': {
      let o = op('repeat', '')
      o.w = copies(asNum(args, 0)); o.h = copies(asNum(args, 1)); o.x = asNum(args, 2); o.y = asNum(args, 3)
      if (o.w * o.h > MAX_GFX_REPEAT) {
        throw new RuntimeTrap('R0028', 'gfx.repeat makes at most ' + MAX_GFX_REPEAT.toString() + ' copies; this one asked for ' +
          o.w.toString() + ' x ' + o.h.toString())
      }
      return holding(o, args.length > 4 ? shapesIn(args[4]) : [])
    }
    case 'drift': {
      let o = op('drift', '')
      let direction = asStr(args, 0)
      let speed = asStr(args, 1)
      o.fx = DRIFT_DIRECTIONS.indexOf(direction) >= 0 ? direction : 'left'
      o.text = DRIFT_SPEEDS.indexOf(speed) >= 0 ? speed : 'slow'
      return holding(o, args.length > 2 ? shapesIn(args[2]) : [])
    }
    case 'glow': {
      let o = op('fx', asStr(args, 1))
      o.fx = 'glow'; o.lineWidth = Math.max(0, asNum(args, 0))
      return holding(o, args.length > 2 ? shapesIn(args[2]) : [])
    }
    case 'shadow': {
      let o = op('fx', asStr(args, 3))
      o.fx = 'shadow'; o.w = asNum(args, 0); o.h = asNum(args, 1); o.lineWidth = Math.max(0, asNum(args, 2))
      return holding(o, args.length > 4 ? shapesIn(args[4]) : [])
    }
    case 'blur': {
      let o = op('fx', '')
      o.fx = 'blur'; o.lineWidth = Math.max(0, asNum(args, 0))
      return holding(o, args.length > 1 ? shapesIn(args[1]) : [])
    }
    case 'blend': {
      let o = op('fx', '')
      let mode = asStr(args, 0)
      o.fx = GFX_BLEND_MODES.indexOf(mode) >= 0 ? mode : ''
      return holding(o, args.length > 1 ? shapesIn(args[1]) : [])
    }
    case 'rgb': {
      let a = Math.max(0, Math.min(1, asNum(args, 3, 1)))
      let text = '#' + hex2(asNum(args, 0)) + hex2(asNum(args, 1)) + hex2(asNum(args, 2))
      return new VeraStringValue(a >= 1 ? text : text + hex2(a * 255))
    }
    case 'distance': {
      let dx = asNum(args, 2) - asNum(args, 0)
      let dy = asNum(args, 3) - asNum(args, 1)
      return new VeraNumberValue(Math.sqrt(dx * dx + dy * dy))
    }
    case 'inside': {
      let px = asNum(args, 0)
      let py = asNum(args, 1)
      let x = asNum(args, 2)
      let y = asNum(args, 3)
      return new VeraBooleanValue(px >= x && py >= y && px <= x + asNum(args, 4) && py <= y + asNum(args, 5))
    }
    default:
      throw new RuntimeTrap('R0015', `unknown std/gfx function: ${name}`)
  }
}

/** A gfx.Pointer for a handler: where a finger is, in the surface's own units. */
export function pointerValue(phase: string, id: number, x: number, y: number): RuntimeValue {
  let fields = new Map<string, RuntimeValue>()
  fields.set('phase', new VeraStringValue(phase))
  fields.set('id', new VeraNumberValue(id))
  fields.set('x', new VeraNumberValue(x))
  fields.set('y', new VeraNumberValue(y))
  return new VeraObjectValue(GFX_POINTER, fields)
}

/** What a draw function returned, as the shapes to paint, back to front. */
export function decodeGfx(value: RuntimeValue): GfxOp[] {
  let ops = shapesIn(value)
  let count = 0
  for (let o of ops) { count += o.drawn }
  if (count > MAX_GFX_SHAPES) {
    throw new RuntimeTrap('R0028', 'one frame draws at most ' + MAX_GFX_SHAPES.toString() + ' shapes; this one drew ' +
      count.toString())
  }
  return ops
}

function paramText(p: GfxParam): string {
  return p.optional ? '[' + p.name + ']' : p.name
}

/** std/gfx for the model's prompt: every function, the pointer, and the colours. Generated, so it cannot drift. */
export function describeGfxForPrompt(): string {
  let lines: string[] = []
  lines.push('std/gfx (always available as gfx; every function returning gfx.Shape is drawn by a ui.Surface):')
  for (let f of GFX_FUNCTIONS) {
    let args: string[] = []
    for (let p of f.params) { args.push(paramText(p)) }
    let result = f.result === 'shape' ? 'gfx.Shape' : f.result
    lines.push('  gfx.' + f.name + '(' + args.join(', ') + '): ' + result + '  -- ' + f.summary)
  }
  let fields: string[] = []
  for (let pair of GFX_POINTER_FIELDS) { fields.push(pair[0] + ': ' + pair[1]) }
  lines.push('  class gfx.Pointer { ' + fields.join('; ') + ' }  -- phase is ' + POINTER_PHASES.map((p: string): string => '"' + p + '"').join(', ') +
    '; id tells two fingers apart; x, y are in surface units')
  lines.push('  A colour is a role -- ' + GFX_ROLES.join(' ') + ' -- or "#rrggbb" / "#rrggbbaa", or gfx.rgb(...), or gfx.linear(...) / gfx.radial(...).')
  lines.push('  Roles follow the app\'s theme and dark mode; prefer them, and use your own colours for the things in the scene.')
  return lines.join('\n')
}
