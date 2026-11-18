/**
 * A first play of a program built on a ui.Surface, before it is served: the smoke run (VeraSmoke.ets) taps every handler
 * once, which says nothing about a game -- whether it starts when touched, whether anything moves, whether it traps on the
 * hundredth frame when the first bullet leaves the screen. So this plays it the way a person tries a game: a tap in the
 * middle, then a few seconds of frames with a finger dragging across the bottom and the middle, every frame drawn.
 *
 * What it reports goes back to the model as a repair, in the smoke run's form ("line:col CODE message"), so only what is
 * wrong whatever the person does counts: a trap in a frame, a draw or a finger; a surface that draws nothing; and a scene
 * that does not change at all although it has a frame handler and was touched; and a game too slow for the phone, by the
 * VM steps and shapes of each frame (VeraBudget.ets).
 */

import { VirtualMachine, deserializeVbc2, RuntimeValue, RuntimeTrap, VeraNumberValue } from './VeraInterpreter'
import { UiHostEnvironment, decodeVeraUi, VeraUiNode } from './VeraUi'
import { CompileResult } from './VeraCompiler'
import { decodeGfx, pointerValue, GfxOp } from './VeraGfx'
import { FrameCosts, functionLine, surfaceBudgetProblem } from './VeraBudget'

/** Frames played: four seconds at 60 a second, enough for a spawn timer, a first collision and a ball to reach an edge. */
export const PLAY_FRAMES: number = 240
const PLAY_STEP_MS: number = 16

/** One finger event of the scripted play: [frame, phase, id, x, y], x and y as fractions of the surface. */
class Touch {
  frame: number
  phase: string
  id: number
  x: number
  y: number
  constructor(frame: number, phase: string, id: number, x: number, y: number) {
    this.frame = frame; this.phase = phase; this.id = id; this.x = x; this.y = y
  }
}

/** A tap in the middle to start, then a slow drag across the bottom, a tap on the right, and a drag through the middle. */
function script(): Touch[] {
  let out: Touch[] = [new Touch(2, 'down', 0, 0.5, 0.5), new Touch(3, 'up', 0, 0.5, 0.5)]
  out.push(new Touch(20, 'down', 1, 0.2, 0.9))
  for (let i = 1; i <= 30; i++) { out.push(new Touch(20 + i * 2, 'move', 1, 0.2 + 0.6 * i / 30, 0.9)) }
  out.push(new Touch(81, 'up', 1, 0.8, 0.9))
  out.push(new Touch(100, 'down', 2, 0.85, 0.4))
  out.push(new Touch(102, 'up', 2, 0.85, 0.4))
  out.push(new Touch(130, 'down', 3, 0.5, 0.75))
  for (let i = 1; i <= 20; i++) { out.push(new Touch(130 + i * 2, 'move', 3, 0.5 - 0.3 * i / 20, 0.75 - 0.3 * i / 20)) }
  out.push(new Touch(171, 'up', 3, 0.2, 0.45))
  return out
}

/** The buttons a person can press on the screen: enabled, with a handler. */
function buttonsIn(node: VeraUiNode, out: VeraUiNode[]): VeraUiNode[] {
  if (node.kind === 'button' && node.enabled && node.action.length > 0) { out.push(node) }
  for (let child of node.children) { buttonsIn(child, out) }
  return out
}

/** At most this many buttons are pressed, each followed by this many frames, when the fingers moved nothing. */
const PRESSED_BUTTONS: number = 6
const FRAMES_AFTER_PRESS: number = 120

function findSurface(node: VeraUiNode): VeraUiNode | null {
  if (node.kind === 'surface') { return node }
  for (let child of node.children) {
    let found = findSurface(child)
    if (found !== null) { return found }
  }
  return null
}

/**
 * The shapes of a frame as text, to tell whether two frames differ: everything a shape is drawn from, so a circle that
 * only grows (a breathing guide), a colour that pulses or a group that fades counts as a change.
 */
function fingerprint(ops: GfxOp[]): string {
  let parts: string[] = []
  for (let o of ops) {
    let points = 0
    for (let i = 0; i < o.points.length; i++) { points += o.points[i] * (i + 1) }
    parts.push(o.kind + ':' + Math.round(o.x * 10).toString() + ',' + Math.round(o.y * 10).toString() + ',' +
      Math.round(o.w * 10).toString() + ',' + Math.round(o.h * 10).toString() + ',' + Math.round(o.r * 10).toString() + ',' +
      Math.round(o.start).toString() + ',' + Math.round(o.sweep).toString() + ',' + Math.round(o.size * 100).toString() + ',' +
      o.color + ',' + o.text + ',' + o.points.length.toString() + ',' + Math.round(points).toString() +
      '[' + fingerprint(o.children) + ']')
  }
  return parts.join(';')
}

function count(ops: GfxOp[]): number {
  let n = 0
  for (let o of ops) { n += 1 + count(o.children) }
  return n
}

function diagnostic(e: Error, when: string): string {
  let text = 'The program compiled, but stopped ' + when + ': ' + e.message
  if (!(e instanceof RuntimeTrap) || e.line <= 0) { return text }
  return e.line.toString() + ':1 ' + e.trapCode + ' ' + text
}

/**
 * '' when the program's surface plays, else what is wrong, for the repair prompt. `requireSurface`: a program with no
 * ui.Surface is itself the problem (the game route asked for one). `pressButtons`: the surface is one part of a screen, and
 * what sets it moving may be a button beside it (Spin, Roll, Start) rather than a finger on it -- when the fingers moved
 * nothing, each button on the screen is pressed in turn and the frames played again. `costsOut` collects what each
 * scripted frame cost (for the host checks).
 */
export function playSurface(compiled: CompileResult, requireSurface: boolean = true, pressButtons: boolean = false,
    costsOut: FrameCosts | null = null): string {
  let host = new UiHostEnvironment()
  let module = deserializeVbc2(compiled.vbc2)
  let vm = new VirtualMachine(module, host)
  let state: RuntimeValue
  let surface: VeraUiNode | null = null
  try {
    state = vm.execute('init')
    for (let root of decodeVeraUi(vm.execute('view', [state]))) {
      if (surface === null) { surface = findSurface(root) }
    }
  } catch (e) {
    return diagnostic(e as Error, 'when the program starts')
  }
  if (surface === null) {
    return requireSurface ? 'The program compiled, but view() draws no ui.Surface: the game must be drawn on one' : ''
  }
  let s = surface!
  let w = s.minimum
  let h = s.maximum
  if (!(w > 0) || !(h > 0)) {
    return 'The program compiled, but its ui.Surface is ' + w.toString() + ' by ' + h.toString() + ': width and height must be positive'
  }
  // Fingers, frames and buttons are handlers on the phone (VeraPreview): they may ask for phone actions, which the play
  // asks for and drops. Only draw() runs with them refused.
  let handle = (name: string, value: RuntimeValue): RuntimeValue => {
    host.effectsAllowed = true
    try {
      return vm.execute(name, [state, value])
    } finally {
      host.effectsAllowed = false
      host.pendingEffects = []
    }
  }
  let touches = script()
  // What each scripted frame ran (frame handler and draw) and drew, for the phone's frame time.
  let costs = costsOut !== null ? costsOut : new FrameCosts()
  let first = ''
  let changed = false
  let frame = 0
  let where = 'drawing the first frame'
  try {
    let ops = decodeGfx(vm.execute(s.label, [state]))
    if (count(ops) === 0) { return 'The program compiled, but draw() returns no shapes: the surface is blank' }
    first = fingerprint(ops)
    for (frame = 1; frame <= PLAY_FRAMES; frame++) {
      for (let t of touches) {
        if (t.frame !== frame || s.value.length === 0) { continue }
        where = 'in ' + s.value + ' (a finger ' + t.phase + ' at frame ' + frame.toString() + ')'
        state = handle(s.value, pointerValue(t.phase, t.id, t.x * w, t.y * h))
      }
      let steps = 0
      if (s.action.length > 0) {
        where = 'in ' + s.action + ' at frame ' + frame.toString()
        state = handle(s.action, new VeraNumberValue(PLAY_STEP_MS))
        steps += vm.stepsExecuted()
      }
      where = 'in ' + s.label + ' at frame ' + frame.toString()
      let drawn = decodeGfx(vm.execute(s.label, [state]))
      steps += vm.stepsExecuted()
      costs.add(steps, count(drawn))
      if (!changed && fingerprint(drawn) !== first) { changed = true }
    }
    if (pressButtons && s.action.length > 0 && !changed) {
      let buttons: VeraUiNode[] = []
      for (let root of decodeVeraUi(vm.execute('view', [state]))) { buttonsIn(root, buttons) }
      for (let b of buttons.slice(0, PRESSED_BUTTONS)) {
        if (changed) { break }
        where = 'in ' + b.action + ' (the button "' + b.text + '")'
        state = handle(b.action, new VeraNumberValue(b.eventValue))
        let before = fingerprint(decodeGfx(vm.execute(s.label, [state])))
        for (let more = 1; more <= FRAMES_AFTER_PRESS && !changed; more++) {
          frame++
          where = 'in ' + s.action + ' at frame ' + frame.toString() + ', after the button "' + b.text + '"'
          state = handle(s.action, new VeraNumberValue(PLAY_STEP_MS))
          where = 'in ' + s.label + ' at frame ' + frame.toString() + ', after the button "' + b.text + '"'
          let drawn = fingerprint(decodeGfx(vm.execute(s.label, [state])))
          if (drawn !== before || drawn !== first) { changed = true }
        }
      }
    }
  } catch (e) {
    return diagnostic(e as Error, where)
  }
  if (s.action.length > 0 && !changed && pressButtons) {
    return 'The program compiled, but nothing on the surface changed in ' + (PLAY_FRAMES * PLAY_STEP_MS / 1000).toString() +
      ' seconds of frames after a tap in the middle and drags across it, nor after pressing each button on the screen: what ' +
      'sets the scene moving (a tap on it, or a button such as Spin or Roll) must change the state ' + s.label + ' draws, and ' +
      s.action + ' must move it by elapsedMs'
  }
  if (s.action.length > 0 && !changed) {
    return 'The program compiled, but nothing on the surface changed in ' + (PLAY_FRAMES * PLAY_STEP_MS / 1000).toString() +
      ' seconds of frames after a tap in the middle and drags across it: a tap anywhere on the surface must start the game, ' +
      'and ' + s.action + ' must move things by elapsedMs'
  }
  return surfaceBudgetProblem(costs, functionLine(module, s.label))
}
