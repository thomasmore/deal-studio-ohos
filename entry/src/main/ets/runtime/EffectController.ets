import { EffectRequest } from './shared/Messages'
import { StageTrace } from './trace/StageTrace'
import { consent } from '../vera/VeraConsentStore'
import { runRawIntent } from '../vera/VeraIntents'
import { runSdkAdapter } from '../vera/VeraSdkBackend'

export type EffectExecutor = (effect: EffectRequest) => Promise<string>

export interface EffectControllerOptions {
  askBeforeCalls: boolean
  stamp: () => string
  isCurrent: () => boolean
  onPending: (effect: EffectRequest | null) => void
  complete: (effect: EffectRequest, text: string) => void
  traceOwner?: Object
  traceRequests?: boolean
  traceResults?: boolean
  onDiscard?: (effect: EffectRequest) => void
  onFailure?: (effect: EffectRequest | null, error: Error) => void
  generation?: () => number
}

export function effectValues(effect: EffectRequest): Map<string, string> {
  let values = new Map<string, string>()
  for (let i = 0; i + 1 < effect.params.length; i += 2) {
    values.set(effect.params[i], effect.params[i + 1])
  }
  return values
}

export function effectConsentKey(effect: EffectRequest): string {
  return effect.rawTarget
}

export function effectConsentTitle(effect: EffectRequest): string {
  if (effect.kind === 'sdk') {
    let parts = effect.rawTarget.split(effect.rawTarget.indexOf('/') >= 0 ? '/' : '.')
    return 'Run ' + parts[parts.length - 1]
  }
  return 'Run ' + effect.rawTarget
}

export function effectConsentValues(effect: EffectRequest): string {
  let lines: string[] = []
  effectValues(effect).forEach((value: string, key: string) => { lines.push(key + ': ' + value) })
  return lines.length > 0 ? lines.join('\n') : '(no parameters)'
}

export function executeEffect(effect: EffectRequest): Promise<string> {
  let values = effectValues(effect)
  if (effect.kind === 'sdk' && effect.rawTarget.indexOf('/') >= 0) {
    return runRawIntent(effect.rawTarget, values, effect.mode)
  }
  return runSdkAdapter(effect.rawTarget, values)
}

class EffectWork {
  effect: EffectRequest
  epoch: number
  generation: number
  stamp: string
  finished: boolean = false

  constructor(effect: EffectRequest, epoch: number, generation: number, stamp: string) {
    this.effect = { appId: effect.appId, vmGeneration: effect.vmGeneration, effectId: effect.effectId,
      kind: effect.kind, rawTarget: effect.rawTarget, params: effect.params.slice(),
      resultHandler: effect.resultHandler, mode: effect.mode }
    this.epoch = epoch
    this.generation = generation
    this.stamp = stamp
  }
}

export class EffectController {
  private options: EffectControllerOptions
  private execute: EffectExecutor
  private epoch: number = 0
  private heldEffects: EffectWork[] = []
  private heldIndex: number = 0
  private executing: Set<EffectWork> = new Set<EffectWork>()
  private pending: EffectWork | null = null
  private draining: boolean = false

  constructor(options: EffectControllerOptions, execute: EffectExecutor = executeEffect) {
    this.options = options
    this.execute = execute
  }

  accept(effects: EffectRequest[]): void {
    if (!this.options.isCurrent() || effects.length === 0) { return }
    let epoch = this.epoch
    let generation = this.options.generation === undefined ? epoch : this.options.generation!()
    let stamp = this.options.askBeforeCalls ? this.options.stamp() : ''
    if (epoch !== this.epoch || !this.options.isCurrent()) { return }
    for (let effect of effects) {
      this.heldEffects.push(new EffectWork(effect, epoch,
        this.options.generation === undefined ? effect.vmGeneration : generation, stamp))
    }
    this.runQueued()
  }

  invalidate(): void {
    this.epoch++
    let held = this.heldEffects.slice(this.heldIndex)
    let pending = this.pending
    let executing = this.executing
    this.heldEffects = []
    this.heldIndex = 0
    this.pending = null
    this.executing = new Set<EffectWork>()
    for (let work of held) { this.discard(work) }
    if (pending !== null) { this.discard(pending) }
    for (let work of executing) { this.discard(work) }
    this.notifyPending(null, null)
  }

  allowPending(): void {
    this.resolvePending(true)
  }

  refusePending(): void {
    this.resolvePending(false)
  }

  private resolvePending(allowed: boolean): void {
    let work = this.pending
    if (work === null || !this.current(work)) { return }
    let draining = this.draining
    this.draining = true
    this.pending = null
    try {
      if (!this.notifyPending(null, work)) { return }
      if (!this.current(work)) { this.discard(work); return }
      if (allowed) {
        consent.remember(work.stamp, effectConsentKey(work.effect))
        this.runEffect(work, true)
      } else {
        this.deliver(work, 'declined by the person', 'DECLINED')
      }
    } catch (e) {
      this.fail(work, e as Error)
    } finally {
      this.draining = draining
      if (!draining) { this.runQueued() }
    }
  }

  private report(effect: EffectRequest | null, error: Error): void {
    try {
      if (this.options.onFailure !== undefined) { this.options.onFailure!(effect, error) }
    } catch (_) {}
  }

  private fail(work: EffectWork, error: Error): void {
    if (!work.finished) {
      work.finished = true
      this.resultTrace(work, 'ERROR')
    }
    this.report(work.effect, error)
  }

  private notifyPending(effect: EffectRequest | null, work: EffectWork | null): boolean {
    try {
      this.options.onPending(effect)
      return true
    } catch (e) {
      if (work !== null) {
        if (this.pending === work) { this.pending = null }
        this.fail(work, e as Error)
      } else {
        this.report(null, e as Error)
      }
      return false
    }
  }

  private discard(work: EffectWork): void {
    if (work.finished) { return }
    work.finished = true
    this.resultTrace(work, 'DROPPED_STALE')
    try {
      if (this.options.onDiscard !== undefined) { this.options.onDiscard!(work.effect) }
    } catch (e) { this.report(work.effect, e as Error) }
  }

  private deliver(work: EffectWork, text: string, outcome: string): void {
    if (work.finished) { return }
    if (!this.current(work)) { this.discard(work); return }
    work.finished = true
    this.resultTrace(work, outcome)
    if (!this.current(work)) { return }
    try { this.options.complete(work.effect, text) } catch (e) { this.report(work.effect, e as Error) }
  }

  private current(work: EffectWork): boolean {
    return work.epoch === this.epoch && this.options.isCurrent() &&
      (this.options.generation === undefined || this.options.generation!() === work.generation)
  }

  private needsConsent(work: EffectWork): boolean {
    return this.options.askBeforeCalls && work.effect.kind === 'sdk' &&
      !consent.has(work.stamp, effectConsentKey(work.effect))
  }

  private requestTrace(work: EffectWork): void {
    if (this.options.traceOwner === undefined || this.options.traceRequests !== true || !StageTrace.enabled()) { return }
    let effect = work.effect
    StageTrace.request(this.options.traceOwner!, effect.effectId, effect.rawTarget, effectValues(effect),
      effect.resultHandler, effect.mode, work.generation)
  }

  private resultTrace(work: EffectWork, outcome: string): void {
    if (this.options.traceOwner === undefined || this.options.traceResults === false) { return }
    StageTrace.emit(this.options.traceOwner!, 'EFFECT_RESULT', { id: work.effect.effectId,
      resultHandler: work.effect.resultHandler, generation: work.generation, outcome: outcome })
  }

  private runQueued(): void {
    if (this.draining) { return }
    this.draining = true
    try {
      while (this.heldIndex < this.heldEffects.length && this.pending === null) {
        let work = this.heldEffects[this.heldIndex]
        this.heldIndex++
        if (!this.current(work)) { this.discard(work); continue }
        try {
          let effect = work.effect
          console.info('VERA-EFFECT id=' + effect.effectId.toString() + ' ' + effect.kind + '.call -> ' + effect.resultHandler)
          if (this.needsConsent(work)) {
            this.requestTrace(work)
            if (!this.current(work)) { this.discard(work); continue }
            this.pending = work
            this.notifyPending(effect, work)
          } else {
            this.runEffect(work)
          }
        } catch (e) { this.fail(work, e as Error) }
      }
    } finally {
      if (this.heldIndex > 0) {
        this.heldEffects = this.heldEffects.slice(this.heldIndex)
        this.heldIndex = 0
      }
      this.draining = false
    }
  }

  private runEffect(work: EffectWork, requestTraced: boolean = false): void {
    if (!this.current(work)) { this.discard(work); return }
    if (!requestTraced) { this.requestTrace(work) }
    if (!this.current(work)) { this.discard(work); return }
    this.executing.add(work)
    let answer: Promise<string>
    try {
      answer = this.execute(work.effect)
    } catch (e) {
      answer = Promise.reject(e)
    }
    answer.then((text: string): void => {
      if (work.finished) { return }
      this.deliver(work, text, text.startsWith('declined') ? 'DECLINED' : text.startsWith('error') ? 'ERROR' : 'OK')
    }, (e: Error): void => {
      if (work.finished) { return }
      if (!this.current(work)) { this.discard(work); return }
      if (this.options.traceOwner !== undefined && this.options.traceResults !== false) {
        StageTrace.emit(this.options.traceOwner!, 'ERROR', { kind: 'EFFECT_RESULT' })
      }
      let message = e !== null && e !== undefined && e.message !== undefined ? e.message : String(e)
      this.deliver(work, 'error: ' + message, 'ERROR')
    }).catch((e: Error): void => { this.fail(work, e) })
      .finally((): void => { this.executing.delete(work) })
  }
}
