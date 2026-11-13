import { VirtualMachine, deserializeVbc2, RuntimeValue, VeraNumberValue,
  encodeRuntimeValue, decodeRuntimeValue } from '../vera/VeraInterpreter'
import { UiHostEnvironment, HostEffect, VeraUiNode, decodeVeraUi } from '../vera/VeraUi'
import { decodeGfx, GfxOp } from '../vera/VeraGfx'
import { decodeScene, WorldSpec as SceneSpec } from '../vera/VeraScene'
import { carryState } from '../vera/VeraStateCarry'
import { store } from '../vera/ProjectStore'
import { ProgramRef, AcquireOptions, RuntimeMode } from './shared/Messages'
import { StageTrace } from './trace/StageTrace'

export interface AppActorCallbacks {
  render: (paint: boolean, reveal: boolean) => void
  snapshot: (encoded: string) => void
  saved: (projectId: string) => void
  effects: (effects: HostEffect[]) => void
  error: (kind: string, message: string) => void
}

export class AppActor {
  private callbacks: AppActorCallbacks
  private traceOwner: Object
  private vm: VirtualMachine | null = null
  private host: UiHostEnvironment | null = null
  private currentState: RuntimeValue | null = null
  private diskState: string = ''
  private refreshes: boolean = false
  private mode: RuntimeMode = 'PREVIEW'
  private program: ProgramRef | null = null
  private persistKey: string = ''
  private seedState: string = ''
  private lastViewAt: number = 0
  private lastSurfaceSave: number = 0
  private worldUnsaved: boolean = false
  private disposed: boolean = false

  constructor(callbacks: AppActorCallbacks, traceOwner: Object) {
    this.callbacks = callbacks
    this.traceOwner = traceOwner
  }

  ready(): boolean {
    return !this.disposed && this.vm !== null && this.currentState !== null
  }

  initialize(program: ProgramRef, options: AcquireOptions): void {
    if (this.disposed) { return }
    this.clearEffects()
    this.vm = null
    this.host = null
    this.currentState = null
    this.diskState = ''
    this.refreshes = false
    this.lastViewAt = 0
    this.lastSurfaceSave = 0
    this.worldUnsaved = false
    this.program = program
    this.mode = options.mode
    this.persistKey = options.persistKey
    this.seedState = options.seedState
    if (program.vbc2.length === 0) { return }
    try {
      this.host = new UiHostEnvironment()
      let module = deserializeVbc2(program.vbc2)
      this.vm = new VirtualMachine(module, this.host)
      this.refreshes = module.functions.some((fn): boolean => fn.name === 'widgetRefresh')
      this.currentState = this.restoreState()
      if (this.currentState === null) {
        StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: 'init', kind: 'INIT' })
        this.currentState = this.seeded(this.vm!.execute('init'))
      }
      this.notifyStateSnapshot()
      this.callbacks.render(true, false)
      this.runWidgetRefresh()
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'INIT' })
      this.clearEffects()
      this.callbacks.error('INIT', 'Init error: ' + (e as Error).message)
    }
  }

  replaceProgram(program: ProgramRef, options: AcquireOptions): void {
    this.initialize(program, options)
  }

  promote(options: AcquireOptions): void {
    if (this.disposed || (this.mode === options.mode && this.persistKey === options.persistKey)) { return }
    this.mode = options.mode
    this.persistKey = options.persistKey
    if (this.mode === 'PREVIEW') { this.clearEffects() }
    this.notifyStateSnapshot()
    this.callbacks.render(true, false)
  }

  resume(): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    let keys = this.stateKeys()
    let changed = keys.length > 0 && store.loadState(keys[0], keys[1], this.stamp()) !== this.diskState
    StageTrace.emit(this.traceOwner, 'RESUME_STATE_RELOAD', { changed: changed })
    if (changed) {
      let restored = this.restoreState()
      if (restored !== null) { this.currentState = restored }
    }
    this.callbacks.render(true, false)
    this.runWidgetRefresh()
  }

  snapshot(): string {
    if (!this.ready() || this.mode === 'PREVIEW') { return '' }
    return JSON.stringify(encodeRuntimeValue(this.currentState!))
  }

  notifyStateSnapshot(): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    try {
      let encoded = this.snapshot()
      StageTrace.snapshot(this.traceOwner, encoded)
      this.callbacks.snapshot(encoded)
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'SNAPSHOT' })
      console.warn('VERA-STATE snapshot unavailable: ' + (e as Error).message)
    }
  }

  persistState(): boolean {
    if (!this.ready() || this.mode !== 'LIVE_PERSISTENT') { return false }
    let keys = this.stateKeys()
    if (keys.length === 0) { return false }
    let encoded = ''
    try {
      encoded = JSON.stringify(encodeRuntimeValue(this.currentState!))
      store.saveState(keys[0], keys[1], this.stamp(), encoded)
      this.diskState = encoded
      this.worldUnsaved = false
      this.callbacks.saved(keys[0])
      if (StageTrace.enabled()) {
        StageTrace.emit(this.traceOwner, 'SAVE', { digest: StageTrace.digest(encoded), result: 'OK' })
      }
      return true
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'SAVE' })
      if (StageTrace.enabled()) {
        StageTrace.emit(this.traceOwner, 'SAVE', { digest: StageTrace.digest(encoded), result: 'ERROR' })
      }
      console.error('VERA-STATE save failed: ' + (e as Error).message)
      return false
    }
  }

  clearEffects(): void {
    if (this.host !== null) {
      this.host!.effectsAllowed = false
      this.host!.pendingEffects = []
    }
  }

  dispose(): void {
    this.clearEffects()
    this.disposed = true
    this.vm = null
    this.host = null
    this.currentState = null
    this.diskState = ''
    this.refreshes = false
    this.mode = 'PREVIEW'
    this.program = null
    this.persistKey = ''
    this.seedState = ''
    this.lastViewAt = 0
    this.lastSurfaceSave = 0
    this.worldUnsaved = false
  }

  view(): VeraUiNode | null {
    if (!this.ready()) { return null }
    this.lastViewAt = Date.now()
    if (this.host !== null) { this.host!.effectsAllowed = false }
    StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: 'view', kind: 'VIEW' })
    let nodes = decodeVeraUi(this.vm!.execute('view', [this.currentState!]))
    return nodes.length > 0 ? nodes[0] : null
  }

  draw(entry: string): GfxOp[] {
    if (!this.ready() || entry.length === 0) { return [] }
    if (this.host !== null) { this.host!.effectsAllowed = false }
    StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: entry, kind: 'DRAW' })
    return decodeGfx(this.vm!.execute(entry, [this.currentState!]))
  }

  buildScene(entry: string): SceneSpec {
    if (!this.ready() || entry.length === 0) { return new SceneSpec() }
    if (this.host !== null) { this.host!.effectsAllowed = false }
    StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: entry, kind: 'BUILD' })
    return decodeScene(this.vm!.execute(entry, [this.currentState!]))
  }

  dispatch(action: string, payload: RuntimeValue, persist: boolean = true, kind: string = 'HANDLER', skipIfSame: boolean = false): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    let t0 = Date.now()
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      let before = this.currentState!
      let beforeCode = skipIfSame ? this.stateCode(before) : ''
      StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: action, kind: kind })
      this.currentState = this.vm!.execute(action, [before, payload])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      if (skipIfSame && this.stateCode(this.currentState!) === beforeCode) {
        if (persist && this.worldUnsaved) { this.persistState() }
        this.drainEffects()
        return
      }
      StageTrace.emit(this.traceOwner, 'INPUT_APPLIED', { action: action })
      this.notifyStateSnapshot()
      console.info('VERA-ACTION ' + action + ' steps=' + this.vm!.stepsExecuted().toString() +
        ' ms=' + (Date.now() - t0).toString())
      this.callbacks.render(true, true)
      if (persist) {
        this.persistState()
      } else {
        this.worldUnsaved = true
      }
      this.drainEffects()
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: kind })
      this.clearEffects()
      console.error('VERA-ACTION ' + action + ' TRAP steps=' + this.vm!.stepsExecuted().toString() +
        ' ms=' + (Date.now() - t0).toString() + ' err=' + (e as Error).message)
      this.callbacks.error(kind, 'Action error: ' + (e as Error).message)
    }
  }

  runWidgetRefresh(): void {
    if (!this.refreshes || !this.ready() || this.mode === 'PREVIEW') { return }
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: 'widgetRefresh', kind: 'WIDGET_REFRESH' })
      this.currentState = this.vm!.execute('widgetRefresh', [this.currentState!])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.notifyStateSnapshot()
      this.callbacks.render(true, false)
      this.persistState()
      this.drainEffects()
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'WIDGET_REFRESH' })
      this.clearEffects()
      console.warn('VERA-REFRESH widgetRefresh failed: ' + (e as Error).message)
    }
  }

  frameHandlers(actions: string[], elapsed: number): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      for (let action of actions) {
        if (action.length === 0) { continue }
        StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: action, kind: 'FRAME' })
        this.currentState = this.vm!.execute(action, [this.currentState!, new VeraNumberValue(elapsed)])
      }
      if (this.host !== null) { this.host!.effectsAllowed = false }
      this.drainEffects()
    } catch (e) {
      this.clearEffects()
      throw e as Error
    }
  }

  move(action: string, payload: RuntimeValue): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    try {
      if (this.host !== null) { this.host!.effectsAllowed = true }
      StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: action, kind: 'MOVE' })
      this.currentState = this.vm!.execute(action, [this.currentState!, payload])
      if (this.host !== null) { this.host!.effectsAllowed = false }
      StageTrace.emit(this.traceOwner, 'INPUT_APPLIED', { action: action })
      this.drainEffects()
    } catch (e) {
      this.clearEffects()
      throw e as Error
    }
  }

  viewDue(now: number): boolean {
    return this.ready() && now - this.lastViewAt >= 100
  }

  beginSurfaceLoop(now: number): void {
    if (!this.ready() || this.mode === 'PREVIEW') { return }
    this.lastSurfaceSave = now
  }

  surfaceSave(now: number, editsPending: boolean): string {
    if (!this.ready() || this.mode === 'PREVIEW' || now - this.lastSurfaceSave < 5000) { return 'NOT_DUE' }
    if (editsPending) { return 'DEFERRED' }
    this.lastSurfaceSave = now
    this.persistState()
    this.notifyStateSnapshot()
    return 'DONE'
  }

  worldSave(now: number, editsPending: boolean, stopping: boolean): string {
    if (!this.ready() || this.mode === 'PREVIEW' || !this.worldUnsaved ||
      (!stopping && now - this.lastSurfaceSave < 5000)) { return 'NOT_DUE' }
    if (editsPending) { return 'DEFERRED' }
    if (!this.persistState()) { return 'ERROR' }
    this.lastSurfaceSave = now
    return 'DONE'
  }

  worldDirty(): boolean {
    return this.worldUnsaved
  }

  private stateCode(state: RuntimeValue): string {
    return JSON.stringify(encodeRuntimeValue(state))
  }

  private stateKeys(): string[] {
    if (this.disposed || this.mode !== 'LIVE_PERSISTENT') { return [] }
    let slash = this.persistKey.indexOf('/')
    if (this.persistKey.length === 0 || slash <= 0) { return [] }
    return [this.persistKey.substring(0, slash), this.persistKey.substring(slash + 1)]
  }

  private stamp(): string {
    return this.program !== null ? this.program!.stamp : ''
  }

  private seeded(fresh: RuntimeValue): RuntimeValue {
    if (this.seedState.length === 0 || this.mode === 'PREVIEW') { return fresh }
    try {
      let carried = carryState(fresh, decodeRuntimeValue(JSON.parse(this.seedState) as Object), this.vm!.classShapes())
      if (this.host !== null) { this.host!.effectsAllowed = false }
      StageTrace.emit(this.traceOwner, 'EXECUTE', { entry: 'view', kind: 'VIEW' })
      this.vm!.execute('view', [carried])
      console.info('VERA-STATE carried into the refined program')
      return carried
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'STATE_CARRY' })
      console.warn('VERA-STATE could not carry the old state, starting clean: ' + (e as Error).message)
      return fresh
    }
  }

  private restoreState(): RuntimeValue | null {
    let keys = this.stateKeys()
    if (keys.length === 0) { return null }
    let encoded = store.loadState(keys[0], keys[1], this.stamp())
    this.diskState = encoded
    if (encoded.length === 0) { return null }
    try {
      return decodeRuntimeValue(JSON.parse(encoded) as Object)
    } catch (e) {
      StageTrace.emit(this.traceOwner, 'ERROR', { kind: 'RESTORE' })
      console.error('VERA-STATE restore failed, starting clean: ' + (e as Error).message)
      return null
    }
  }

  private drainEffects(): void {
    if (!this.ready() || this.mode === 'PREVIEW' || this.host === null) { return }
    let effects: HostEffect[] = this.host!.pendingEffects
    if (effects.length === 0) { return }
    this.host!.pendingEffects = []
    this.callbacks.effects(effects)
  }
}
