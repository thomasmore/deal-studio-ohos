/**
 * What a frame of a program costs on the phone, predicted from what the host can count: the VM steps a frame ran and the
 * shapes it drew. Measured on the phone with eight programs (a fit within about 2 ms each): a ui.Surface frame costs about
 * 3.6 ms of its own (the canvas, the layout, the bridge), 0.31 µs per VM step and 4 µs per shape drawn. A generated
 * first-person maze at 107 000 steps a frame ran at 23 frames a second and passed every check before this one.
 *
 * The plays (VeraSurfacePlay.ets, VeraWorldPlay.ets) count; this file holds the constants, the judging and the message
 * the model is shown, so a change of phone is a change here only. Pure.
 */

import { BytecodeModule } from './VeraInterpreter'

/** A drawn frame's fixed cost on the phone, ms: canvas, layout and the bridge, whatever the program does. */
export const FRAME_BASE_MS: number = 3.6
/** One VM step on the phone, ms (0.31 µs). */
export const STEP_MS: number = 0.00031
/** One shape drawn on the phone, ms (4 µs). */
export const SHAPE_MS: number = 0.004

/** A ui.Surface frame (frame handler and draw together) may take this much: 60 a second leaves room for the rest. */
export const SURFACE_FRAME_BUDGET_MS: number = 12
/** A ui.World's build and event handler, run on a state change, may take this much together: the frame they land in. */
export const WORLD_BUILD_BUDGET_MS: number = 8

/** The repair code for a frame or a build too slow for the phone. */
export const CODE_TOO_SLOW: string = 'P0001'

/** A drawn frame's time on the phone, ms, for this many VM steps and shapes. */
export function predictFrameMs(steps: number, shapes: number): number {
  return FRAME_BASE_MS + steps * STEP_MS + shapes * SHAPE_MS
}

/** Handler work's time on the phone, ms, for this many VM steps: no canvas of its own (a world's build, its event handler). */
export function predictWorkMs(steps: number): number {
  return steps * STEP_MS
}

/** The middle of the values (the mean of the two middle ones for an even count); 0 for none. */
export function median(values: number[]): number {
  if (values.length === 0) { return 0 }
  let sorted = values.slice().sort((a: number, b: number): number => a - b)
  let mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/** The frames of a played run: what each ran and drew, and its predicted time. */
export class FrameCosts {
  steps: number[] = []
  shapes: number[] = []

  add(steps: number, shapes: number): void {
    this.steps.push(steps)
    this.shapes.push(shapes)
  }

  /** The predicted time of each frame, ms. */
  frameMs(): number[] {
    let out: number[] = []
    for (let i = 0; i < this.steps.length; i++) { out.push(predictFrameMs(this.steps[i], this.shapes[i])) }
    return out
  }

  /** The median frame's predicted time: what the game feels like, not its one slow frame. */
  medianMs(): number {
    return median(this.frameMs())
  }

  medianSteps(): number {
    return median(this.steps)
  }

  medianShapes(): number {
    return median(this.shapes)
  }
}

/** The first source line of a function in the bytecode, 1 when it has none (old bytecode, or no such function). */
export function functionLine(module: BytecodeModule, name: string): number {
  for (let f of module.functions) {
    if (f.name !== name) { continue }
    let first = 0
    for (let line of f.lines) {
      if (line > 0 && (first === 0 || line < first)) { first = line }
    }
    return first > 0 ? first : 1
  }
  return 1
}

/** '' when a played surface keeps within its frame budget, else the repair diagnostic, pointing at `line` (the draw function). */
export function surfaceBudgetProblem(costs: FrameCosts, line: number): string {
  let ms = costs.medianMs()
  if (!(ms > SURFACE_FRAME_BUDGET_MS)) { return '' }
  return line.toString() + ':1 ' + CODE_TOO_SLOW + ' The program plays, but each frame takes about ' + Math.round(ms).toString() +
    ' ms on the phone (budget ' + SURFACE_FRAME_BUDGET_MS.toString() + '): about ' + Math.round(costs.medianSteps()).toString() +
    ' steps of work and ' + Math.round(costs.medianShapes()).toString() + ' shapes a frame. Draw fewer shapes or do less work per ' +
    'frame: no loops over every pixel, cell or ray each frame, keep what does not change in state instead of computing it again'
}

/** '' when a world's slowest state change (event handler plus build) keeps within budget, else the repair diagnostic. */
export function worldBudgetProblem(steps: number, line: number): string {
  let ms = predictWorkMs(steps)
  if (!(ms > WORLD_BUILD_BUDGET_MS)) { return '' }
  return line.toString() + ':1 ' + CODE_TOO_SLOW + ' The program plays, but a change of state takes about ' + Math.round(ms).toString() +
    ' ms on the phone (budget ' + WORLD_BUILD_BUDGET_MS.toString() + ') to handle the event and build the world again: about ' +
    Math.round(steps).toString() + ' steps of work. build only describes the world -- fewer bodies, no work per body beyond ' +
    'making it -- and the host moves things by itself: never compute positions or animations in build or in the event handler'
}
