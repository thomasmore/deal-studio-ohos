/**
 * The poses of ui.Motion: where a child is, as a function of how far through its arrival it is.
 *
 * A Motion child arrives: when the program bumps the trigger it has already changed state, so the new content is what plays
 * the animation, starting from a displaced pose and settling on the normal one. Pure and plain data, so the renderer draws
 * from it and the host can check every preset without a phone. Nothing here touches the VM: decoration must not become
 * state transitions.
 */

export class MotionPose {
  /** The rotation axis (any vector) and angle in degrees; angle 0 is no rotation. */
  axisX: number = 0
  axisY: number = 0
  axisZ: number = 1
  angle: number = 0
  scale: number = 1
  /** A squash or stretch on top of `scale`, along each axis. */
  scaleX: number = 1
  scaleY: number = 1
  dx: number = 0
  dy: number = 0
  opacity: number = 1
  /** Where it turns, from the top edge (0) to the bottom (1): motionPivot. */
  pivotY: number = 0.5
}

/**
 * Every preset, by what the movement means (not by what it is drawn on): the catalogue lists these and a card plays all of them.
 * emphasis: pop pulse jelly press flash breathe; reaction: shake nod wobble swing recoil; gravity: bounce hop jump fall;
 * turning: spin turn tumble flip; arrival: fade rise zoom slide; ambient: float drift; leaving: launch roll.
 */
export const MOTION_PRESETS: string[] = ['pop', 'pulse', 'jelly', 'press', 'flash', 'breathe', 'shake', 'nod', 'wobble', 'swing', 'recoil',
  'bounce', 'hop', 'jump', 'fall', 'spin', 'turn', 'tumble', 'flip', 'fade', 'rise', 'zoom', 'slide', 'float', 'drift', 'launch', 'roll']

/**
 * A preset as stages. The first row is the pose the child starts in: [0, dx, dy, scaleX, scaleY, rotation, opacity, 0]; every
 * later row is a stage that glides to its pose over `ms` with a curve (1 ease out, 2 ease in, 3 ease in-out, 0 linear):
 * [ms, dx, dy, scaleX, scaleY, rotation, opacity, curve]. A card plays the stages one after the other (a platform animation
 * each, the next started when the one before finishes: it cannot loop and stops about two seconds after a redraw, so a preset
 * lasts under MOTION_BUDGET_MS); the app samples the same table. dx and dy are points, rotation degrees, the rest unitless.
 * A preset ends on the pose it should rest in, a whole number of turns round.
 */
export const MOTION_BUDGET_MS: number = 1500

function row(ms: number, dx: number, dy: number, sx: number, sy: number, rot: number, a: number, curve: number): number[] {
  return [ms, dx, dy, sx, sy, rot, a, curve]
}

const REST: number[] = [0, 0, 0, 1, 1, 0, 1, 0]

/** The stages of a preset (a fresh copy), or [] for a name that is not one. */
export function motionStages(preset: string): number[][] {
  let rest = (ms: number, curve: number): number[] => row(ms, 0, 0, 1, 1, 0, 1, curve)
  if (preset === 'pop') { return [REST, row(140, 0, 0, 1.3, 1.3, 0, 1, 1), rest(210, 3)] }
  if (preset === 'pulse') { return [REST, row(110, 0, 0, 1.2, 1.2, 0, 1, 1), rest(110, 2), row(110, 0, 0, 1.12, 1.12, 0, 1, 1), rest(160, 3)] }
  if (preset === 'jelly') {
    return [REST, row(90, 0, 0, 1.28, 0.78, 0, 1, 1), row(110, 0, 0, 0.84, 1.18, 0, 1, 3), row(110, 0, 0, 1.1, 0.92, 0, 1, 3),
      row(110, 0, 0, 0.97, 1.03, 0, 1, 3), rest(130, 3)]
  }
  if (preset === 'press') { return [REST, row(90, 0, 2, 0.86, 0.86, 0, 1, 2), row(150, 0, 0, 1.06, 1.06, 0, 1, 1), rest(110, 3)] }
  if (preset === 'flash') { return [REST, row(80, 0, 0, 1, 1, 0, 0.2, 1), rest(80, 2), row(80, 0, 0, 1, 1, 0, 0.35, 1), rest(120, 2)] }
  if (preset === 'breathe') { return [REST, row(480, 0, 0, 1.07, 1.07, 0, 1, 3), rest(520, 3)] }
  if (preset === 'shake') {
    return [REST, row(60, 12, 0, 1, 1, 0, 1, 3), row(80, -10, 0, 1, 1, 0, 1, 3), row(70, 7, 0, 1, 1, 0, 1, 3), row(70, -4, 0, 1, 1, 0, 1, 3), rest(60, 3)]
  }
  if (preset === 'nod') {
    return [REST, row(70, 0, 7, 1, 1, 0, 1, 3), row(90, 0, -5, 1, 1, 0, 1, 3), row(80, 0, 4, 1, 1, 0, 1, 3), row(70, 0, -2, 1, 1, 0, 1, 3), rest(60, 3)]
  }
  if (preset === 'wobble') {
    return [REST, row(70, 0, 0, 1, 1, 12, 1, 3), row(100, 0, 0, 1, 1, -9, 1, 3), row(90, 0, 0, 1, 1, 6, 1, 3), row(80, 0, 0, 1, 1, -3, 1, 3), rest(70, 3)]
  }
  if (preset === 'swing') {
    return [REST, row(160, 0, 0, 1, 1, -32, 1, 1), row(260, 0, 0, 1, 1, 26, 1, 3), row(240, 0, 0, 1, 1, -15, 1, 3), row(200, 0, 0, 1, 1, 8, 1, 3), rest(160, 3)]
  }
  if (preset === 'recoil') { return [REST, row(80, 0, 5, 0.94, 0.94, -3, 1, 2), row(70, 0, -6, 1.16, 1.16, 2, 1, 1), rest(240, 1)] }
  if (preset === 'bounce') {
    return [row(0, 0, -44, 1, 1, 0, 1, 0), rest(250, 2), row(130, 0, -14, 1, 1, 0, 1, 1), rest(120, 2), row(70, 0, -4, 1, 1, 0, 1, 1), rest(70, 2)]
  }
  if (preset === 'hop') { return [REST, row(190, 0, -28, 0.96, 1.06, 0, 1, 1), rest(190, 2), row(70, 0, 0, 1.12, 0.9, 0, 1, 1), rest(110, 3)] }
  if (preset === 'jump') {
    return [REST, row(130, 0, 3, 1.14, 0.82, 0, 1, 3), row(210, 0, -46, 0.94, 1.1, 0, 1, 1), rest(200, 2), row(70, 0, 0, 1.18, 0.8, 0, 1, 1), rest(150, 3)]
  }
  if (preset === 'fall') { return [row(0, 0, -70, 1, 1, 0, 0, 0), rest(300, 2), row(70, 0, 0, 1.14, 0.86, 0, 1, 1), rest(130, 3)] }
  if (preset === 'spin') { return [REST, row(1100, 0, 0, 1, 1, 720, 1, 1)] }
  if (preset === 'turn') { return [REST, row(500, 0, 0, 1, 1, 360, 1, 3)] }
  if (preset === 'tumble') {
    return [REST, row(330, 0, -26, 1.14, 1.14, 360, 1, 1), row(330, 0, 0, 1, 1, 720, 1, 2), row(70, 0, 0, 1.14, 0.86, 720, 1, 1), row(110, 0, 0, 1, 1, 720, 1, 3)]
  }
  if (preset === 'flip') { return [row(0, 0, 0, 0.02, 1, 0, 1, 0), rest(320, 1)] }
  if (preset === 'fade') { return [row(0, 0, 0, 1, 1, 0, 0, 0), rest(400, 3)] }
  if (preset === 'rise') { return [row(0, 0, 28, 0.96, 0.96, 0, 0, 0), rest(420, 1)] }
  if (preset === 'zoom') { return [row(0, 0, 0, 0.2, 0.2, 0, 0, 0), row(260, 0, 0, 1.14, 1.14, 0, 1, 1), rest(160, 3)] }
  if (preset === 'slide') { return [row(0, 64, 0, 1, 1, 0, 0, 0), rest(380, 1)] }
  if (preset === 'float') { return [REST, row(450, 0, -9, 1, 1, 0, 1, 3), row(450, 0, 3, 1, 1, 0, 1, 3), rest(300, 3)] }
  if (preset === 'drift') { return [REST, row(450, 10, 0, 1, 1, 0, 1, 3), row(500, -8, 0, 1, 1, 0, 1, 3), rest(400, 3)] }
  // Leaving and coming back: a rocket goes up out of sight (stretched as it speeds), comes in again from below unseen, and rises to its
  // place; a ball rolls away to the side, turning, and rolls back. A stage of 30 ms moves it while it is invisible.
  if (preset === 'launch') {
    return [REST, row(120, 0, 4, 1.06, 0.92, 0, 1, 3), row(300, 0, -170, 0.9, 1.16, 0, 1, 2), row(30, 0, 120, 1, 1, 0, 0, 0),
      row(420, 0, 0, 1, 1, 0, 1, 1)]
  }
  if (preset === 'roll') { return [REST, row(380, 46, 0, 1, 1, 260, 1, 3), row(420, 0, 0, 1, 1, 0, 1, 3)] }
  return []
}

/** Where a preset turns: 0 is the top edge, 0.5 the middle, 1 the bottom (a swing hangs from the top, a wobble rocks on its base). */
export function motionPivot(preset: string): number {
  if (preset === 'swing') { return 0 }
  if (preset === 'wobble') { return 1 }
  return 0.5
}

/** A pivot as ArkUI's rotate takes it: a share of the height, '0%' to '100%'. The app and the card both turn about this. */
export function pivotPercent(pivot: number): string { return Math.round(100 * pivot).toString() + '%' }

/** How long a preset's stages take together, in ms: what a card plays. 0 for a name that is not a preset. */
export function stagedDuration(preset: string): number {
  let total = 0
  let stages = motionStages(preset)
  for (let i = 1; i < stages.length; i++) { total += stages[i][0] }
  return total
}

function curved(curve: number, p: number): number {
  if (curve === 1) { return 1 - (1 - p) * (1 - p) * (1 - p) }
  if (curve === 2) { return p * p * p }
  if (curve === 3) { return p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2 }
  return p
}

/** The pose of a staged preset at progress 0..1 of its whole length. */
function stagedPose(stages: number[][], total: number, p: number): MotionPose {
  let pose = new MotionPose()
  let at = p * total
  let from = stages[0]
  let used = 0
  for (let i = 1; i < stages.length; i++) {
    let to = stages[i]
    if (at <= used + to[0] || i === stages.length - 1) {
      let u = to[0] > 0 ? Math.min(1, Math.max(0, (at - used) / to[0])) : 1
      let e = curved(to[7], u)
      let mix = (k: number): number => from[k] + (to[k] - from[k]) * e
      pose.dx = mix(1)
      pose.dy = mix(2)
      pose.scaleX = mix(3)
      pose.scaleY = mix(4)
      pose.angle = mix(5)
      pose.opacity = mix(6)
      return pose
    }
    used += to[0]
    from = to
  }
  return pose
}

/**
 * The six the app drew first, by formula (3D turns included), and how long each formula plays: its curve was tuned for that length.
 * A card cannot draw a formula and plays their stages instead. The rest come from the table in the app too.
 */
const FORMULA_MS: Map<string, number> = new Map<string, number>([
  ['tumble', 900], ['flip', 450], ['shake', 450], ['bounce', 650], ['pop', 350], ['fade', 400]
])

/** How long a preset plays in the app, in milliseconds. Fixed per preset: the program has no knob that could make it janky. */
export function motionDuration(preset: string): number {
  let formula = FORMULA_MS.get(preset)
  return formula !== undefined ? formula : stagedDuration(preset)
}

function easeOut(p: number): number {
  let q = 1 - p
  return 1 - q * q * q
}

function clamp01(p: number): number {
  if (p < 0 || p !== p) { return 0 }
  if (p > 1) { return 1 }
  return p
}

/** The pose at progress 0..1. Progress 1, and any unknown preset, is the identity pose. */
export function motionPose(preset: string, progress: number): MotionPose {
  let pose = new MotionPose()
  let p = clamp01(progress)
  if (p >= 1) { return pose }
  let e = easeOut(p)
  if (!FORMULA_MS.has(preset)) {
    let stages = motionStages(preset)
    if (stages.length === 0) { return pose }
    // A turn is about the viewer's axis (z), the default, and about the preset's own pivot.
    let sampled = stagedPose(stages, stagedDuration(preset), p)
    sampled.pivotY = motionPivot(preset)
    return sampled
  }
  pose.pivotY = motionPivot(preset)
  if (preset === 'tumble') {
    // A turn about a diagonal axis with a hop, slowing as it lands.
    pose.axisX = 1
    pose.axisY = 0.8
    pose.axisZ = 0.2
    pose.angle = 720 * (1 - e)
    pose.dy = -28 * Math.sin(Math.PI * p)
    pose.scale = 1 + 0.18 * Math.sin(Math.PI * p)
  } else if (preset === 'flip') {
    // The new content turns into view from edge-on.
    pose.axisX = 0
    pose.axisY = 1
    pose.axisZ = 0
    pose.angle = 90 * (1 - e)
  } else if (preset === 'shake') {
    pose.dx = 14 * Math.sin(p * Math.PI * 6) * (1 - p)
  } else if (preset === 'bounce') {
    pose.dy = -48 * (1 - p) * Math.abs(Math.cos(p * Math.PI * 2.5))
  } else if (preset === 'pop') {
    pose.scale = 1 + 0.35 * Math.sin(Math.PI * p)
  } else if (preset === 'fade') {
    pose.opacity = e
    pose.scale = 0.96 + 0.04 * e
  }
  return pose
}

// ---------------------------------------------------------------------------------------------------------------------
// A pose written as numbers (ui.Transform).
//
// pose = [rotateX, rotateY, rotateZ, translateX, translateY, translateZ, scale, opacity]: degrees, points, unitless. Missing
// entries are the identity, so [0, 30] is a turn of 30 degrees about the vertical axis. A layer is turned about its own centre;
// +z points at the viewer. Matrices are 4x4, row-major (m[row * 4 + column]), applied to column vectors, so a chain is
// parent * child.
// ---------------------------------------------------------------------------------------------------------------------

export const POSE_LENGTH: number = 8

/** The pose an array stands for: missing or non-finite entries are the identity ones. Never longer than POSE_LENGTH. */
export function poseFromArray(values: number[]): number[] {
  let identity: number[] = [0, 0, 0, 0, 0, 0, 1, 1]
  let out: number[] = []
  for (let i = 0; i < POSE_LENGTH; i++) {
    let v = i < values.length ? values[i] : identity[i]
    out.push(v === v && v !== Infinity && v !== -Infinity ? v : identity[i])
  }
  return out
}

/** Linear blend of two poses, `p` in 0..1. Angles blend by value (720 -> 810 is two and a quarter turns, not a quarter). */
export function lerpPose(from: number[], to: number[], p: number): number[] {
  let q = p < 0 || p !== p ? 0 : (p > 1 ? 1 : p)
  let out: number[] = []
  for (let i = 0; i < POSE_LENGTH; i++) { out.push(from[i] + (to[i] - from[i]) * q) }
  return out
}

/** Progress after easing: fast at first, settling at the end. */
export function easeOutCubic(p: number): number {
  let q = 1 - (p < 0 || p !== p ? 0 : (p > 1 ? 1 : p))
  return 1 - q * q * q
}

export function identityMatrix(): number[] {
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
}

/** a * b. */
export function multiplyMatrices(a: number[], b: number[]): number[] {
  let out: number[] = []
  for (let r = 0; r < 4; r++) {
    for (let c = 0; c < 4; c++) {
      let sum = 0
      for (let k = 0; k < 4; k++) { sum += a[r * 4 + k] * b[k * 4 + c] }
      out.push(sum)
    }
  }
  return out
}

/**
 * The matrix of one pose: the layer is scaled, turned about its own centre (X, then Y, then Z), then moved by [tx, ty, tz] in
 * its parent's frame. So a card that spins and moves is one pose, [turnX, turnY, turnZ, x, y, z]. The opacity is not part of the matrix.
 */
export function poseMatrix(pose: number[]): number[] {
  let rad = Math.PI / 180
  let cx = Math.cos(pose[0] * rad), sx = Math.sin(pose[0] * rad)
  let cy = Math.cos(pose[1] * rad), sy = Math.sin(pose[1] * rad)
  let cz = Math.cos(pose[2] * rad), sz = Math.sin(pose[2] * rad)
  let rotX = [1, 0, 0, 0, 0, cx, -sx, 0, 0, sx, cx, 0, 0, 0, 0, 1]
  let rotY = [cy, 0, sy, 0, 0, 1, 0, 0, -sy, 0, cy, 0, 0, 0, 0, 1]
  let rotZ = [cz, -sz, 0, 0, sz, cz, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
  let s = pose[6]
  let scale = [s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1]
  let move = [1, 0, 0, pose[3], 0, 1, 0, pose[4], 0, 0, 1, pose[5], 0, 0, 0, 1]
  return multiplyMatrices(move, multiplyMatrices(rotZ, multiplyMatrices(rotY, multiplyMatrices(rotX, scale))))
}

/** The same pose with its distances (the three translations) multiplied by `density`: points to pixels, as ArkUI's matrices want. */
export function poseToPixels(pose: number[], density: number): number[] {
  return [pose[0], pose[1], pose[2], pose[3] * density, pose[4] * density, pose[5] * density, pose[6], pose[7]]
}

/** The viewer `distance` pixels in front of the layer as a matrix: w = 1 - z / distance. A distance of 0 or less is no perspective. */
export function perspectiveMatrix(distance: number): number[] {
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, distance > 0 ? -1 / distance : 0, 1]
}

/** The 16 numbers ArkUI's matrix4.init wants: column by column (the translation ends up at 12, 13, 14, the perspective at 11). */
export function columnMajor(matrix: number[]): number[] {
  let out: number[] = []
  for (let column = 0; column < 4; column++) {
    for (let row = 0; row < 4; row++) { out.push(matrix[row * 4 + column]) }
  }
  return out
}

/** Whether two poses are the same numbers. */
export function samePose(a: number[], b: number[]): boolean {
  for (let i = 0; i < POSE_LENGTH; i++) { if (a[i] !== b[i]) { return false } }
  return true
}

/**
 * The pose shown `now`, for an animation from `from` to `to` that began at `start` and lasts `duration` ms. Eased; a start
 * before 0 or a duration of 0 is "already there". Moving on from `from` is what makes a retarget in mid-flight continuous.
 */
export function animatedPose(from: number[], to: number[], start: number, duration: number, now: number): number[] {
  if (start < 0 || duration <= 0 || now - start >= duration) { return to }
  return lerpPose(from, to, easeOutCubic((now - start) / duration))
}

/** The viewer distance of a Transform, in points. */
export const TRANSFORM_DISTANCE: number = 900
