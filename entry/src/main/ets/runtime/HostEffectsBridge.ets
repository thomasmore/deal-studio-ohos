import { ActorHandle, AdmissionResult, EffectRequest } from './shared/Messages'
import { EffectController, EffectExecutor, executeEffect } from './EffectController'
import { StageTrace } from './trace/StageTrace'

export interface EffectResultHost {
  postEffectResult(handle: ActorHandle, effectId: number, text: string): AdmissionResult
}

export interface HostEffectsBridgeOptions {
  askBeforeCalls: boolean
  onPending: (effect: EffectRequest | null) => void
  flushPendingInputFor: (appId: string) => void | Promise<void>
  captureValidity?: (effect: EffectRequest) => () => boolean
  readyToPost?: (effect: EffectRequest) => boolean
  onAdmitted?: (effect: EffectRequest, inputSeq: number | undefined) => void
  onFailure: (effect: EffectRequest | null, error: Error) => void
  traceOwner?: Object
}

export interface HostEffectsBinding {
  onEffectRequest(effect: EffectRequest): void
  bind(handle: ActorHandle): void
  failBinding(): void
}

class EffectsBinding implements HostEffectsBinding {
  private request: (effect: EffectRequest) => void
  private attach: (handle: ActorHandle) => void
  private fail: () => void

  constructor(request: (effect: EffectRequest) => void, attach: (handle: ActorHandle) => void, fail: () => void) {
    this.request = request
    this.attach = attach
    this.fail = fail
  }

  onEffectRequest(effect: EffectRequest): void { this.request(effect) }
  bind(handle: ActorHandle): void { this.attach(handle) }
  failBinding(): void { this.fail() }
}

class EffectResult {
  effect: EffectRequest
  text: string
  current: () => boolean

  constructor(effect: EffectRequest, text: string, current: () => boolean) {
    this.effect = effect
    this.text = text
    this.current = current
  }
}

class EffectBindingState {
  stamp: string
  handle: ActorHandle | null = null
  buffered: EffectRequest[] = []
  seen: Set<number> = new Set<number>()
  terminal: Set<string> = new Set<string>()
  owners: Map<string, Object> = new Map<string, Object>()
  results: EffectResult[] = []
  controller: EffectController | null = null
  flushing: Promise<void> | null = null
  writable: boolean = false

  constructor(stamp: string) { this.stamp = stamp }
}

export class HostEffectsBridge {
  private host: EffectResultHost
  private options: HostEffectsBridgeOptions
  private execute: EffectExecutor
  private binding: EffectBindingState | null = null

  constructor(host: EffectResultHost, options: HostEffectsBridgeOptions, execute: EffectExecutor = executeEffect) {
    this.host = host
    this.options = options
    this.execute = execute
  }

  beginBinding(stamp: string): HostEffectsBinding {
    let previous = this.binding
    let state = new EffectBindingState(stamp)
    this.binding = state
    state.controller = new EffectController({
      askBeforeCalls: this.options.askBeforeCalls,
      stamp: (): string => state.stamp,
      isCurrent: (): boolean => this.binding === state && state.handle !== null,
      traceResults: false,
      onDiscard: (effect: EffectRequest): void => { this.terminalTrace(state, effect, 'DROPPED_STALE') },
      onFailure: (effect: EffectRequest | null, error: Error): void => {
        if (effect !== null) { this.terminalTrace(state, effect, 'ERROR') }
        this.report(effect, error)
      },
      onPending: (effect: EffectRequest | null): void => {
        if (this.binding === state) { this.options.onPending(effect) }
      },
      complete: (effect: EffectRequest, text: string): void => { this.complete(state, effect, text) }
    }, this.execute)
    let binding: HostEffectsBinding = new EffectsBinding(
      (effect: EffectRequest): void => { this.accept(state, effect) },
      (handle: ActorHandle): void => { this.bind(state, handle) },
      (): void => { if (this.binding === state) { this.invalidate() } })
    if (previous !== null) { this.disposeBinding(previous) }
    if (this.binding === state) { this.notifyCleared() }
    return binding
  }

  invalidate(): void {
    let state = this.binding
    this.binding = null
    if (state !== null) { this.disposeBinding(state) }
    if (this.binding === null) { this.notifyCleared() }
  }

  private disposeBinding(state: EffectBindingState): void {
    let buffered = state.buffered
    let results = state.results
    state.buffered = []
    state.results = []
    state.writable = false
    state.controller!.invalidate()
    for (let effect of buffered) { this.terminalTrace(state, effect, 'DROPPED_STALE') }
    for (let result of results) { this.terminalTrace(state, result.effect, 'DROPPED_STALE') }
  }

  private notifyCleared(): void {
    try { this.options.onPending(null) } catch (e) { this.report(null, e as Error) }
  }

  allowPending(): void {
    if (this.binding !== null) { this.binding!.controller!.allowPending() }
  }

  refusePending(): void {
    if (this.binding !== null) { this.binding!.controller!.refusePending() }
  }

  onMailboxWritable(): void {
    if (this.binding === null) { return }
    let state: EffectBindingState = this.binding!
    if (state.flushing !== null) { state.writable = true; return }
    this.flush()
  }

  flush(): Promise<void> {
    if (this.binding === null || this.binding!.handle === null) { return Promise.resolve() }
    let state: EffectBindingState = this.binding!
    if (state.flushing !== null) { return Promise.resolve() }
    let handle: ActorHandle = state.handle!
    let flushing: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      let continuation = true
      try {
        while (this.binding === state && state.results.length > 0) {
          state.writable = false
          let blocked = await this.flushResults(state, handle)
          if (blocked) {
            if (!state.writable || !continuation) { break }
            continuation = false
          }
        }
      } finally {
        state.flushing = null
        state.writable = false
      }
    })
    state.flushing = flushing
    return flushing
  }

  private matches(state: EffectBindingState, effect: EffectRequest): boolean {
    return this.binding === state && state.handle !== null &&
      effect.appId === state.handle!.appId && effect.vmGeneration === state.handle!.vmGeneration
  }

  private accept(state: EffectBindingState, effect: EffectRequest): void {
    if (this.binding !== state) { return }
    let key = this.terminalKey(effect)
    if (!state.owners.has(key) && !state.terminal.has(key)) {
      let owner = StageTrace.effectOwner(effect)
      if (owner !== undefined) { state.owners.set(key, owner) }
    }
    if (state.handle === null) {
      state.buffered.push({ appId: effect.appId, vmGeneration: effect.vmGeneration, effectId: effect.effectId,
        kind: effect.kind, rawTarget: effect.rawTarget, params: effect.params.slice(),
        resultHandler: effect.resultHandler, mode: effect.mode })
      return
    }
    if (state.seen.has(effect.effectId)) { return }
    if (!this.matches(state, effect)) { this.terminalTrace(state, effect, 'DROPPED_STALE'); return }
    state.seen.add(effect.effectId)
    state.controller!.accept([effect])
  }

  private bind(state: EffectBindingState, handle: ActorHandle): void {
    if (this.binding !== state || state.handle !== null) { return }
    state.handle = handle
    while (this.binding === state && state.buffered.length > 0) {
      this.accept(state, state.buffered.shift()!)
    }
  }

  private complete(state: EffectBindingState, effect: EffectRequest, text: string): void {
    if (!this.matches(state, effect)) { this.terminalTrace(state, effect, 'DROPPED_STALE'); return }
    try {
      let current = this.options.captureValidity === undefined ? (): boolean => true : this.options.captureValidity!(effect)
      if (!this.matches(state, effect)) { this.terminalTrace(state, effect, 'DROPPED_STALE'); return }
      state.results.push(new EffectResult(effect, text, current))
      this.flush()
    } catch (e) {
      this.terminalTrace(state, effect, 'ERROR')
      this.report(effect, e as Error)
    }
  }

  private terminalKey(effect: EffectRequest): string {
    return JSON.stringify([effect.appId, effect.vmGeneration.toString(), effect.effectId.toString()])
  }

  private terminalTrace(state: EffectBindingState, effect: EffectRequest, outcome: string): void {
    let key = this.terminalKey(effect)
    if (state.terminal.has(key)) { return }
    state.terminal.add(key)
    let owner = state.owners.get(key)
    state.owners.delete(key)
    StageTrace.emit(owner === undefined ? (this.options.traceOwner === undefined ? this : this.options.traceOwner!) : owner,
      'EFFECT_RESULT', {
      id: effect.effectId, resultHandler: effect.resultHandler, generation: effect.vmGeneration, outcome: outcome
    })
  }

  private report(effect: EffectRequest | null, error: Error): void {
    try { this.options.onFailure(effect, error) } catch (_) {}
  }

  private async flushResults(state: EffectBindingState, handle: ActorHandle): Promise<boolean> {
    while (this.binding === state && state.handle === handle && state.results.length > 0) {
      let result = state.results[0]
      let admitted = false
      try {
        if (!result.current()) {
          state.results.shift()
          this.terminalTrace(state, result.effect, 'DROPPED_STALE')
          continue
        }
        if (this.binding !== state || state.handle !== handle) { return false }
        await this.options.flushPendingInputFor(result.effect.appId)
        if (this.binding !== state || state.handle !== handle) { return false }
        if (!result.current()) {
          state.results.shift()
          this.terminalTrace(state, result.effect, 'DROPPED_STALE')
          continue
        }
        if (this.options.readyToPost !== undefined && !this.options.readyToPost!(result.effect)) { return true }
        if (!result.current()) {
          state.results.shift()
          this.terminalTrace(state, result.effect, 'DROPPED_STALE')
          continue
        }
        if (this.binding !== state || state.handle !== handle) { return false }
        state.results.shift()
        let admission = this.host.postEffectResult(handle, result.effect.effectId, result.text)
        if (admission.status === 'ACCEPTED') {
          admitted = true
          let key = this.terminalKey(result.effect)
          state.terminal.add(key)
          state.owners.delete(key)
          if (this.binding === state && this.options.onAdmitted !== undefined) {
            this.options.onAdmitted!(result.effect, admission.inputSeq)
          }
        } else if (admission.status === 'BACKPRESSURE') {
          if (this.binding === state) { state.results.unshift(result) }
          else { this.terminalTrace(state, result.effect, 'DROPPED_STALE') }
          return true
        } else if (admission.status === 'COALESCED') {
          this.terminalTrace(state, result.effect, 'ERROR')
          this.report(result.effect, new Error('EFFECT_RESULT cannot be coalesced'))
        } else {
          this.terminalTrace(state, result.effect, 'DROPPED_STALE')
        }
      } catch (e) {
        if (state.results[0] === result) { state.results.shift() }
        if (!admitted) { this.terminalTrace(state, result.effect, this.binding === state ? 'ERROR' : 'DROPPED_STALE') }
        this.report(result.effect, e as Error)
      }
    }
    return false
  }
}
