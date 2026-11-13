/**
 * The layout of a home-screen card: the nodes of a frame (VeraLiveWidget) drawn the one way, by both the launcher's card (pages/LiveCard.ets) and
 * the app's Widget tab (components/WidgetPreview.ets), so the preview cannot drift from what the card shows. It loads only the theme and
 * the painter, never the VM. What happens on a touch is the host's: this reports it through onTap and onPoint.
 */

import { CardNode, CARD_MAX_MOTIONS, CARD_MAX_PICTURES, CARD_MAX_TIMERS, CARD_MAX_DRIFT_SLICES, CARD_PADDING, OPEN_STRIP, OPEN_STRIP_MARK, cardSize, TimerFace, timerFace, TOUCH_ACTION, pictureCovers, pictureBare } from './CardModel'
import { paintGfx, decodeGfxOps, gfxFit, gfxToSurface } from '../vera/GfxPaint'
import { resolveTheme } from '../vera/VeraTheme'
import { motionStages, motionPivot, pivotPercent } from '../vera/VeraMotion'

/** A picture on a card is as wide as its node says (the frame sizes it to the room left, VeraLiveWidget.pictureRoom); a 2x2 card's largest when it says nothing (vp). */
const PICTURE_WIDTH: number = cardSize(2).pictureMax
/** Motions a card carries, each with a slot of its own below. */
const SLOTS: number = CARD_MAX_MOTIONS

/** Where a ui.Motion (or a gfx.moving part) stands now, and the animation that takes it there: one value, so its modifiers are written once. */
class MotionPose {
  dx: number = 0
  dy: number = 0
  scaleX: number = 1
  scaleY: number = 1
  angle: number = 0
  opacity: number = 1
  centerX: string = '50%'
  centerY: string = '50%'
  animation: AnimateParam = {}
}

@Extend(Column)
function posed(pose: MotionPose) {
  .scale({ x: pose.scaleX, y: pose.scaleY, centerX: pose.centerX, centerY: pose.centerY })
  .rotate({ angle: pose.angle, centerX: pose.centerX, centerY: pose.centerY })
  .translate({ x: pose.dx, y: pose.dy })
  .opacity(pose.opacity)
  .animation(pose.animation)
}

function filled(count: number, value: number): number[] {
  let out: number[] = []
  for (let i = 0; i < count; i++) { out.push(value) }
  return out
}
function contexts(count: number): CanvasRenderingContext2D[] {
  let out: CanvasRenderingContext2D[] = []
  for (let i = 0; i < count; i++) { out.push(new CanvasRenderingContext2D(new RenderingContextSettings(true))) }
  return out
}
function timerControllers(count: number): TextTimerController[] {
  let out: TextTimerController[] = []
  for (let i = 0; i < count; i++) { out.push(new TextTimerController()) }
  return out
}

/**
 * The strip along a card's bottom over a cover picture (CardModel.OPEN_STRIP): the cover takes every other touch, so this is the way
 * into the app on the home screen (LiveCard passes onOpen; the app's own preview, already in the app, does not).
 */
@Component
export struct OpenStrip {
  onOpen?: () => void

  build() {
    Column() {
      Column().width(24).height(3).borderRadius(1.5).backgroundColor(OPEN_STRIP_MARK)
    }
    .width('100%').height(OPEN_STRIP).margin({ top: -6 }).justifyContent(FlexAlign.Center)
    .onClick(() => { if (this.onOpen !== undefined) { this.onOpen() } })
  }
}

@Component
export struct CardView {
  /** The frame's nodes, and what makes them new: the nodes are made again whenever frameKey changes (a tap's answer, a new state). */
  @Prop nodes: CardNode[] = []
  @Prop frameKey: string = ''
  /** The widget's theme: a picture's colours by role follow it. */
  @Prop preset: string = 'clean'
  @Prop primary: string = ''
  /** The card's size (FormDimension), and whether these nodes are its cover picture (splitCover), drawn under everything to its edges. */
  @Prop dimension: number = 2
  @Prop fill: boolean = false
  /** A button, or a shape with an action, was tapped: the handler's name and its number. */
  onTap: (action: string, value: number) => void = (action: string, value: number): void => {}
  /** A toggle or a checkbox was tapped: its handler's name and whether it is now on. */
  onSwitch: (handler: string, on: boolean) => void = (handler: string, on: boolean): void => {}
  /** A picture was tapped: its pointer handler's name and where, in the picture's own units. */
  onPoint: (handler: string, x: number, y: number) => void = (handler: string, x: number, y: number): void => {}

  /** ui.Timer: the platform's TextTimer, one controller for each timer by its number in the frame. */
  private timers: TextTimerController[] = timerControllers(CARD_MAX_TIMERS)
  private timerOf(node: CardNode): TextTimerController { return this.timers[node.pic >= 0 && node.pic < this.timers.length ? node.pic : 0] }
  /** How the timer is set as of when the card draws it: from its moment (val), down to it when max is 1. */
  private faceOf(node: CardNode): TimerFace { return timerFace(node.val !== undefined ? node.val : 0, node.max === 1, Date.now()) }
  /**
   * ui.Surface: a still picture. The app's own painter (paintGfx) draws, on a Canvas, the shapes the frame carries; each picture has
   * its own context, by its number in the frame.
   */
  private contexts: CanvasRenderingContext2D[] = contexts(CARD_MAX_PICTURES)
  private contextOf(node: CardNode): CanvasRenderingContext2D {
    return this.contexts[node.pic >= 0 && node.pic < this.contexts.length ? node.pic : 0]
  }
  /** A cover picture is the whole card, its padding included; any other is as wide as the frame sized it. */
  private covering(node: CardNode): boolean { return this.fill && (pictureCovers(node.style) || node.cover === true) }

  /**
   * gfx.drift: a strip that never stops, played by the platform's Swiper (a card's script stops soon after a redraw; the Swiper does not).
   * The strip is cut into node.value slices, all on view, each its own canvas painting its slice of the picture; the Swiper moves one slice a
   * page and loops, so the picture slides on and on. Right is the same strip laid right to left; down is the upward strip turned over, each
   * slice painted upside down so it reads the right way up.
   */
  private driftContexts: CanvasRenderingContext2D[] = contexts(CARD_MAX_DRIFT_SLICES)
  private driftBase(node: CardNode): number { return node.pic >= 0 ? node.pic * 16 : 0 }
  private sliceContext(node: CardNode, k: number): CanvasRenderingContext2D {
    let index = this.driftBase(node) + k
    return this.driftContexts[index >= 0 && index < this.driftContexts.length ? index : 0]
  }
  /** The slices on view at once: the strip is cut into this many. */
  private sliceCount(node: CardNode): number { return Math.max(1, Math.min(8, node.value)) }
  /**
   * The Swiper's items: the strip twice over. A Swiper with no more items than it shows has nothing to bring in and does not play
   * (found on the phone: a drift of eight slices all on view stood still), so the second copy is what slides in.
   */
  private sliceList(node: CardNode): number[] {
    let out: number[] = []
    for (let k = 0; k < 2 * this.sliceCount(node); k++) { out.push(k) }
    return out
  }
  private across(node: CardNode): boolean { return node.style === 'left' || node.style === 'right' }
  private sliceW(node: CardNode): number { return this.across(node) ? this.pictureW(node) / this.sliceCount(node) : this.pictureW(node) }
  private sliceH(node: CardNode): number { return this.across(node) ? this.pictureH(node) : this.pictureH(node) / this.sliceCount(node) }
  private paintSlice(node: CardNode, item: number): void {
    let n = this.sliceCount(node)
    let k = item % n
    // The strip's own slice for the k-th place: laid right to left (right) or turned over (down), the places run the other way.
    let slice = node.style === 'right' || node.style === 'down' ? n - 1 - k : k
    let shiftX = this.across(node) ? -slice * this.sliceW(node) : 0
    let shiftY = this.across(node) ? 0 : -slice * this.sliceH(node)
    paintGfx(this.sliceContext(node, item), decodeGfxOps(node.ops), resolveTheme(this.preset, this.primary, false),
      this.pictureW(node), this.pictureH(node), node.w, node.h, vp2px(1), true, this.covering(node), [], -1, shiftX, shiftY, node.style === 'down')
  }
  private pictureW(node: CardNode): number {
    if (this.covering(node)) { return cardSize(this.dimension).width + 2 * CARD_PADDING }
    return node.size > 0 ? node.size : PICTURE_WIDTH
  }
  private pictureH(node: CardNode): number {
    if (this.covering(node)) { return cardSize(this.dimension).height + 2 * CARD_PADDING }
    return Math.min(this.pictureW(node) * 1.1, this.pictureW(node) * node.h / node.w)
  }
  private paintPicture(node: CardNode): void {
    paintGfx(this.contextOf(node), decodeGfxOps(node.ops), resolveTheme(this.preset, this.primary, false),
      this.pictureW(node), this.pictureH(node), node.w, node.h, vp2px(1), pictureBare(node.style), pictureCovers(node.style))
  }
  private pictureAt(node: CardNode, event: ClickEvent): number[] {
    return gfxToSurface(gfxFit(this.pictureW(node), this.pictureH(node), node.w, node.h, pictureCovers(node.style)), event.x, event.y)
  }

  /**
   * ui.Motion: the trigger each Motion last settled on (by its slot). The node is made again for every frame (its key carries frameKey), so
   * there is nothing on it to animate from: a frame that carries another trigger starts it in the hit pose and it settles in
   * onAppear. The first frame only records its trigger, so a card never plays when it opens. A card plays for about two
   * seconds after a redraw, which is all a hit needs; there is no repeat or loop.
   */
  @State settled: number[] = filled(SLOTS, -1e18)
  @State settledTouches: number[] = filled(SLOTS, 0)
  /** How far each Motion's chain of stages has got: 0 before it plays, k the pose after stage k. */
  @State phase: number[] = filled(SLOTS, 0)
  /**
   * The frame each Motion last began on (its onAppear). A frame not yet begun is one just drawn: a Motion about to play shows its starting
   * pose there, so it plays from it. One already begun that is not playing rests, whatever a touch did: a touch only counts.
   */
  private begun: string[] = filled(SLOTS, 0).map((): string => '')
  private settledOf(node: CardNode): number { return node.slot >= 0 && node.slot < SLOTS ? this.settled[node.slot] : -1e18 }
  private settle(node: CardNode): void {
    if (node.slot < 0 || node.slot >= SLOTS) { return }
    let next = this.settled.slice()
    next[node.slot] = node.trigger
    this.settled = next
    let touches = this.settledTouches.slice()
    touches[node.slot] = this.touches[node.slot]
    this.settledTouches = touches
  }
  private setPhase(slot: number, value: number): void {
    if (slot < 0 || slot >= SLOTS) { return }
    let next = this.phase.slice()
    next[slot] = value
    this.phase = next
  }

  /**
   * Touches on the pictures and shapes under each Motion, counted here independently of its trigger: a touch makes the picture react
   * whether or not the program's handler changed anything. Plain fields, not state: nothing is redrawn before the answer comes, and
   * a touch whose answer never comes (a refused tap, a busy preview) leaves the card as it was; the next frame plays it.
   */
  private touches: number[] = filled(SLOTS, 0)
  private touched(node: CardNode): void {
    // A node in a ui.Layers plays every Motion of the scene; any other plays the one it is under.
    let slots: number[] = node.links !== undefined ? node.links : (node.slot >= 0 ? [node.slot] : [])
    for (let slot of slots) {
      if (slot >= 0 && slot < SLOTS) { this.touches[slot] = this.touches[slot] + 1 }
    }
  }
  private playing(node: CardNode): boolean {
    return this.settledOf(node) > -1e17 &&
      (node.trigger !== this.settledOf(node) || this.touches[node.slot] !== this.settledTouches[node.slot])
  }

  /** The stages of the node's preset (MOTION_STAGES in VeraMotion): row 0 is where it starts, each later row a stage. */
  private stagesOf(node: CardNode): number[][] { return motionStages(node.style) }
  /**
   * One number of the pose the Motion is in: its starting pose when a movement is about to play, the pose of the stage it has
   * reached while it plays, its resting pose (the last row) otherwise. 1 dx, 2 dy, 3 scale x, 4 scale y, 5 rotation, 6 opacity.
   */
  private poseOf(node: CardNode, index: number): number {
    let stages = this.stagesOf(node)
    if (stages.length === 0) { return index >= 3 && index !== 5 ? 1 : 0 }
    let last = stages.length - 1
    if (!this.playing(node)) { return stages[last][index] }
    // A new frame, about to begin: the starting pose, even when the last movement was still under way.
    if (this.begun[node.slot] !== this.frameKey) { return stages[0][index] }
    let at = this.phase[node.slot]
    return stages[at >= 1 ? Math.min(at, last) : last][index]
  }
  /** Where a Motion turns and scales: a moving part's own pivot (gfx.moving), else the preset's (a swing from the top). */
  private pivotXOf(node: CardNode): string { return node.px !== undefined ? this.partPivot(node, node.px, true) : '50%' }
  private pivotOf(node: CardNode): string {
    return node.py !== undefined ? this.partPivot(node, node.py, false) : pivotPercent(motionPivot(node.style))
  }
  /**
   * A moving part's pivot, given as a share of its picture's units, as a share of the box its picture is drawn in: the picture is fitted
   * into that box (letterboxed when it is taller than the card allows, cut by cover-fit when it is the card's background), so the two differ.
   */
  private partPivot(node: CardNode, share: number, across: boolean): string {
    let picture = node.children.length === 1 && node.children[0].kind === 'surface' ? node.children[0] : null
    if (picture === null || !(picture.w > 0) || !(picture.h > 0)) { return pivotPercent(share) }
    let boxW = this.pictureW(picture)
    let boxH = this.pictureH(picture)
    let fit = gfxFit(boxW, boxH, picture.w, picture.h, pictureCovers(picture.style))
    let at = across ? fit.offsetX + share * picture.w * fit.scale : fit.offsetY + share * picture.h * fit.scale
    return (Math.round(10000 * at / (across ? boxW : boxH)) / 100).toString() + '%'
  }
  private motionPose(node: CardNode): MotionPose {
    let pose = new MotionPose()
    pose.dx = this.poseOf(node, 1)
    pose.dy = this.poseOf(node, 2)
    pose.scaleX = this.poseOf(node, 3)
    pose.scaleY = this.poseOf(node, 4)
    pose.angle = this.poseOf(node, 5)
    pose.opacity = this.poseOf(node, 6)
    pose.centerX = this.pivotXOf(node)
    pose.centerY = this.pivotOf(node)
    pose.animation = this.motionAnimation(node)
    return pose
  }
  /** The platform animation to the stage the Motion is at: its time and curve, and what to do when it ends (go on to the next stage). */
  private motionAnimation(node: CardNode): AnimateParam {
    let stages = this.stagesOf(node)
    let at = node.slot >= 0 && node.slot < SLOTS ? this.phase[node.slot] : 0
    let seen = at
    let slot = node.slot
    let key = this.frameKey
    let curve = at >= 1 && at < stages.length ? stages[at][7] : 1
    return {
      duration: at >= 1 && at < stages.length ? stages[at][0] : 0,
      curve: curve === 0 ? Curve.Linear : curve === 2 ? Curve.EaseIn : curve === 3 ? Curve.EaseInOut : Curve.EaseOut,
      onFinish: () => { this.advance(node, slot, seen, key) }
    }
  }
  /** The card shows a movement when the frame is new: the first frame only records its trigger, a later one starts the chain. */
  private begin(node: CardNode): void {
    if (node.slot < 0 || node.slot >= SLOTS) { return }
    this.begun[node.slot] = this.frameKey
    if (this.settledOf(node) < -1e17) { this.settle(node); return }
    // From the starting pose this frame was drawn in (poseOf), even when an older frame's chain was still under way.
    if (this.playing(node)) { this.setPhase(node.slot, 1) }
  }
  /** A stage ended: start the next, or, after the last, record the trigger so a redraw does not play it again. A stage of an older frame is over. */
  private advance(node: CardNode, slot: number, seen: number, key: string): void {
    if (slot < 0 || slot >= SLOTS || key !== this.frameKey || this.phase[slot] !== seen || seen < 1) { return }
    if (seen + 1 < this.stagesOf(node).length) {
      this.setPhase(slot, seen + 1)
    } else {
      this.settle(node)
      this.setPhase(slot, 0)
    }
  }

  /** How the theme dressed a node (CardStyle, set by the extension): an unset field is the card's default. */
  private weightOf(node: CardNode): number { return node.weight !== undefined ? node.weight : 400 }
  private familyOf(node: CardNode): string { return node.family !== undefined ? node.family : '' }
  private spacingOf(node: CardNode): number { return node.spacing !== undefined ? node.spacing : 0 }
  private gapOf(node: CardNode, fallback: number): number { return node.gap !== undefined ? node.gap : fallback }
  private padOf(node: CardNode): number { return node.pad !== undefined ? node.pad : 0 }
  private panelOf(node: CardNode): string { return node.panel !== undefined ? node.panel : '#00000000' }
  private radiusOf(node: CardNode, fallback: number): number { return node.radius !== undefined ? node.radius : fallback }
  private colAlign(node: CardNode): HorizontalAlign { return node.align === 'end' ? HorizontalAlign.End : HorizontalAlign.Center }
  private valueNow(node: CardNode): number { return node.val !== undefined ? node.val : 0 }
  private maxOf(node: CardNode): number { return node.max !== undefined && node.max > 0 ? node.max : 100 }
  private inkOf(node: CardNode): string { return node.ink !== undefined ? node.ink : '#333333' }
  private percent(node: CardNode): string { return Math.round(100 * this.valueNow(node) / this.maxOf(node)).toString() + '%' }
  /** Something in the node, or the node itself, runs a handler when tapped: a button, a shape or icon button with an action, a switch, a picture with a pointer. */
  private handles(node: CardNode): boolean {
    if (node.pointer.length > 0 || node.action.length > 0) { return true }
    return node.children.some((child: CardNode): boolean => this.handles(child))
  }
  /**
   * A Motion a touch plays: one around a picture or a shape. A figure or a text in a Motion plays when it changes, and a tap on it opens the app.
   * One in a ui.Layers takes no touch of its own: the scene plays all its Motions, and a Motion that took the touch would keep it from the
   * parts under it (layerHit).
   */
  private touchPlays(node: CardNode): boolean {
    if (node.links !== undefined) { return false }
    let pictured = (nodes: CardNode[]): boolean =>
      nodes.some((child: CardNode): boolean => child.kind === 'surface' || child.kind === 'path' || pictured(child.children))
    return pictured(node.children)
  }
  /** A ui.Layers with movements: a touch on a part with no handler of its own plays them all. */
  private scenePlays(node: CardNode): boolean { return node.links !== undefined && node.links.length > 0 }
  /**
   * In a ui.Layers a part with nothing to run lets a touch through to the parts under it (a clear picture over the whole scene would
   * otherwise take every touch); a part with a handler takes the touches that land on it. Transparent, not None: None lets a touch past
   * the part itself but not past what is in it, and anything hit there (even a column with no handler) keeps it from the parts under it
   * (measured on the phone). Nothing in such a part runs anything on a touch (touchPlays), so only the parts under it can.
   */
  private layerHit(node: CardNode): HitTestMode { return this.handles(node) ? HitTestMode.Default : HitTestMode.Transparent }

  private rowJustify(node: CardNode): FlexAlign {
    return node.align === 'split' ? FlexAlign.SpaceBetween : node.align === 'end' ? FlexAlign.End :
      node.align === 'joined' ? FlexAlign.Center : FlexAlign.SpaceEvenly
  }

  build() {
    Column({ space: 6 }) {
      ForEach(this.nodes, (node: CardNode) => { this.level1(node, false) }, (node: CardNode) => node.key + this.frameKey)
    }.width('100%')
  }

  @Builder
  leaf(node: CardNode) {
    if (node.kind === 'drift') {
      Swiper() {
        ForEach(this.sliceList(node), (k: number) => {
          Canvas(this.sliceContext(node, k)).width(this.sliceW(node)).height(this.sliceH(node))
            .onReady(() => { this.paintSlice(node, k) })
        }, (k: number) => node.key + '.' + k.toString())
      }
      .width(this.pictureW(node)).height(this.pictureH(node))
      .displayCount(this.sliceCount(node))
      .vertical(!this.across(node))
      .direction(node.style === 'right' ? Direction.Rtl : Direction.Ltr)
      .rotate({ angle: node.style === 'down' ? 180 : 0 })
      .autoPlay(true).interval(0).loop(true).indicator(false).disableSwipe(true).curve(Curve.Linear)
      .hitTestBehavior(HitTestMode.Transparent)
    } else if (node.kind === 'button') {
      Button(node.text).type(ButtonType.Normal).borderRadius(this.radiusOf(node, 10)).height(40)
        .backgroundColor(node.fill).fontColor(node.color).fontSize(14)
        .enabled(node.enabled).onClick(() => {
          this.onTap(node.action, node.value)
        })
    } else if (node.kind === 'path') {
      // A shape is drawn in a 100-unit box; the viewPort has to say 'px' or the path comes out a quarter of its size
      // (VeraIcons.ets), and a Path left with the default stroke is outlined in thick black. One with an action is a
      // button: the same message a button posts.
      // A shape without an action lets a tap fall through to the card, which opens the app.
      if (node.action.length > 0) {
        Shape() {
          Path({ commands: node.commands }).fill(node.color).stroke(Color.Transparent)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(node.size).height(node.size)
        .onClick(() => {
          if (node.enabled) {
            this.touched(node)
            this.onTap(node.action, node.value)
          }
        })
      } else {
        Shape() {
          Path({ commands: node.commands }).fill(node.color).stroke(Color.Transparent)
        }
        .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
        .width(node.size).height(node.size)
      }
    } else if (node.kind === 'surface') {
      // A picture without a pointer handler lets a tap fall through to the card, which opens the app.
      if (node.pointer.length > 0) {
        Canvas(this.contextOf(node)).width(this.pictureW(node)).height(this.pictureH(node))
          .onReady(() => { this.paintPicture(node) })
          .onClick((event: ClickEvent) => {
            let at = this.pictureAt(node, event)
            this.touched(node)
            this.onPoint(node.pointer, at[0], at[1])
          })
      } else {
        Canvas(this.contextOf(node)).width(this.pictureW(node)).height(this.pictureH(node))
          .onReady(() => { this.paintPicture(node) })
      }
    } else if (node.kind === 'timer') {
      // The platform's own timer: it ticks by itself (a card is not frozen for it, unlike for our animations), from where the frame says.
      if (this.familyOf(node).length > 0) {
        TextTimer({ isCountDown: this.faceOf(node).countDown, count: this.faceOf(node).count, startTime: this.faceOf(node).startTime,
                    controller: this.timerOf(node) })
          .format(this.faceOf(node).format)
          .fontSize(node.size).fontColor(node.color).fontWeight(this.weightOf(node)).fontFamily(this.familyOf(node))
          .onAppear(() => { this.timerOf(node).start() })
      } else {
        TextTimer({ isCountDown: this.faceOf(node).countDown, count: this.faceOf(node).count, startTime: this.faceOf(node).startTime,
                    controller: this.timerOf(node) })
          .format(this.faceOf(node).format)
          .fontSize(node.size).fontColor(node.color).fontWeight(this.weightOf(node))
          .onAppear(() => { this.timerOf(node).start() })
      }
    } else if (node.kind === 'checkbox') {
      Row({ space: 8 }) {
        Column() {
          if (this.valueNow(node) === 1) { this.glyph(node.commands, 14, '#FFFFFF') }
        }
        .width(20).height(20).alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center).borderRadius(6)
        .backgroundColor(this.valueNow(node) === 1 ? node.color : '#00000000')
        .border({ width: 2, color: this.valueNow(node) === 1 ? node.color : node.fill })
        Text(node.text).fontSize(14).fontColor(this.inkOf(node)).maxLines(1).layoutWeight(1)
      }
      .width('100%').opacity(node.enabled ? 1 : 0.4)
      .onClick(() => { if (node.enabled) { this.onSwitch(node.action, this.valueNow(node) !== 1) } })
    } else if (node.kind === 'toggle') {
      Row({ space: 8 }) {
        Stack({ alignContent: this.valueNow(node) === 1 ? Alignment.End : Alignment.Start }) {
          Column().width(36).height(20).borderRadius(10).backgroundColor(this.valueNow(node) === 1 ? node.color : node.fill)
          Circle().width(14).height(14).fill('#FFFFFF').margin(3)
        }.width(36).height(20)
        Text(node.text).fontSize(14).fontColor(this.inkOf(node)).maxLines(1).layoutWeight(1)
      }
      .width('100%').opacity(node.enabled ? 1 : 0.4)
      .onClick(() => { if (node.enabled) { this.onSwitch(node.action, this.valueNow(node) !== 1) } })
    } else if (node.kind === 'icon') {
      this.glyph(node.commands, node.size, node.color)
    } else if (node.kind === 'iconbutton') {
      Column() {
        this.glyph(node.commands, Math.round(node.size * 0.5), node.color)
      }
      .width(node.size).height(node.size)
      .alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
      .backgroundColor(node.fill).borderRadius(node.size / 2)
      .opacity(node.enabled ? 1 : 0.4)
      .onClick(() => {
        if (node.enabled && node.action.length > 0) { this.onTap(node.action, node.value) }
      })
    } else if (node.kind === 'badge') {
      Row({ space: 4 }) {
        if (node.commands.length > 0) {
          this.glyph(node.commands, 12, node.color)
        }
        Text(node.text).fontSize(12).fontWeight(500).fontColor(node.color).maxLines(1)
      }
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(node.fill).borderRadius(this.radiusOf(node, 8))
    } else if (node.kind === 'progress') {
      // The platform's own bar, with the label on the left and how far along on the right, as the app draws it.
      Column({ space: 4 }) {
        Row() {
          Text(node.text).fontSize(12).fontColor(this.inkOf(node)).maxLines(1).layoutWeight(1)
          Text(this.percent(node)).fontSize(12).fontColor(node.color)
        }.width('100%')
        Progress({ value: this.valueNow(node), total: this.maxOf(node), type: ProgressType.Linear })
          .width('100%').style({ strokeWidth: 8, strokeRadius: 4 }).color(node.color).backgroundColor(node.fill)
      }.width('100%')
    } else if (node.kind === 'ring') {
      Column({ space: 2 }) {
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: this.valueNow(node), total: this.maxOf(node), type: ProgressType.Ring })
            .width(node.size).height(node.size).style({ strokeWidth: 7 }).color(node.color).backgroundColor(node.fill)
          Text(node.sub !== undefined ? node.sub : '').fontSize(12).fontWeight(700).fontColor(this.inkOf(node))
            .maxLines(1).textAlign(TextAlign.Center).width(node.size - 14)
        }
        if (node.text.length > 0) {
          Text(node.text).fontSize(12).fontColor(this.inkOf(node)).maxLines(1)
        }
      }
    } else if (node.kind === 'divider') {
      Divider().color(node.color)
    } else if (node.kind === 'spacer') {
      Blank().height(4)
    } else if (node.kind === 'numbertext') {
      // A figure is never broken over two lines: beside another, it shrinks to fit its half of the card.
      if (this.familyOf(node).length > 0) {
        Text(node.text).maxFontSize(node.size).minFontSize(Math.min(node.size, 12)).fontColor(node.color).maxLines(1)
          .fontWeight(this.weightOf(node)).fontFamily(this.familyOf(node)).letterSpacing(this.spacingOf(node))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(node.text).maxFontSize(node.size).minFontSize(Math.min(node.size, 12)).fontColor(node.color).maxLines(1)
          .fontWeight(this.weightOf(node)).letterSpacing(this.spacingOf(node))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    } else {
      if (this.familyOf(node).length > 0) {
        Text(node.text).fontSize(node.size).fontColor(node.color).maxLines(2)
          .fontWeight(this.weightOf(node)).fontFamily(this.familyOf(node)).letterSpacing(this.spacingOf(node))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(node.text).fontSize(node.size).fontColor(node.color).maxLines(2)
          .fontWeight(this.weightOf(node)).letterSpacing(this.spacingOf(node))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
  }

  /** A catalogue icon: strokes in a 100-unit box, the box's unit the pixel (see VeraPreview.drawIcon for why the viewPort and the stroke say 'px'). */
  @Builder
  glyph(commands: string, size: number, color: string) {
    Shape() {
      Path({ commands: commands }).fill(Color.Transparent).stroke(color).strokeWidth('8px')
        .strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
    }
    .viewPort({ x: '0px', y: '0px', width: '100px', height: '100px' })
    .width(size).height(size)
  }

  // ArkTS has no recursive builders: four levels, the depth a card is held to (the theme wrapper consumes none of them).
  @Builder
  level1(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: this.gapOf(node, 8) }) {
        ForEach(node.children, (child: CardNode) => { this.level2(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(this.rowJustify(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'column') {
      Column({ space: this.gapOf(node, 6) }) {
        ForEach(node.children, (child: CardNode) => { this.level2(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).alignItems(this.colAlign(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'layers') {
      // The children one over another, each in the middle: a picture with another moving over it. A touch that no part takes
      // lands on the scene, which plays its movements; a scene with none lets it through to the card, which opens the app.
      if (this.scenePlays(node)) {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level2(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level2(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
      }
    } else if (node.kind === 'motion') {
      // A touch on a moving picture plays it, as a touch on a picture with a handler of its own does: the host only draws the next frame.
      if (this.touchPlays(node)) {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level2(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level2(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
      }
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level2(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: this.gapOf(node, 8) }) {
        ForEach(node.children, (child: CardNode) => { this.level3(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(this.rowJustify(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'column') {
      Column({ space: this.gapOf(node, 6) }) {
        ForEach(node.children, (child: CardNode) => { this.level3(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).alignItems(this.colAlign(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'layers') {
      // The children one over another, each in the middle: a picture with another moving over it. A touch that no part takes
      // lands on the scene, which plays its movements; a scene with none lets it through to the card, which opens the app.
      if (this.scenePlays(node)) {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level3(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level3(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
      }
    } else if (node.kind === 'motion') {
      // A touch on a moving picture plays it, as a touch on a picture with a handler of its own does: the host only draws the next frame.
      if (this.touchPlays(node)) {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level3(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level3(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
      }
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level3(node: CardNode, inRow: boolean) {
    if (node.kind === 'row') {
      Row({ space: this.gapOf(node, 8) }) {
        ForEach(node.children, (child: CardNode) => { this.level4(child, true) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).justifyContent(this.rowJustify(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'column') {
      Column({ space: this.gapOf(node, 6) }) {
        ForEach(node.children, (child: CardNode) => { this.level4(child, false) }, (child: CardNode) => child.key)
      }.width('100%').layoutWeight(inRow ? 1 : 0).alignItems(this.colAlign(node))
      .padding(this.padOf(node)).backgroundColor(this.panelOf(node)).borderRadius(this.radiusOf(node, 0))
    } else if (node.kind === 'layers') {
      // The children one over another, each in the middle: a picture with another moving over it. A touch that no part takes
      // lands on the scene, which plays its movements; a scene with none lets it through to the card, which opens the app.
      if (this.scenePlays(node)) {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level4(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Stack() {
          ForEach(node.children, (child: CardNode) => {
            Stack() { this.level4(child, false) }.hitTestBehavior(this.layerHit(child))
          }, (child: CardNode) => child.key)
        }.layoutWeight(inRow ? 1 : 0)
      }
    } else if (node.kind === 'motion') {
      // A touch on a moving picture plays it, as a touch on a picture with a handler of its own does: the host only draws the next frame.
      if (this.touchPlays(node)) {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level4(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
        .onClick(() => { this.touched(node); this.onTap(TOUCH_ACTION, 0) })
      } else {
        Column({ space: 6 }) {
          ForEach(node.children, (child: CardNode) => { this.level4(child, false) }, (child: CardNode) => child.key)
        }
        .layoutWeight(inRow ? 1 : 0)
        .posed(this.motionPose(node))
        .onAppear(() => { this.begin(node) })
      }
    } else {
      this.leaf(node)
    }
  }

  @Builder
  level4(node: CardNode, inRow: boolean) {
    this.leaf(node)
  }
}
