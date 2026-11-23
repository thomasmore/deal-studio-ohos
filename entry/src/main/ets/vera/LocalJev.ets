import nativeLocalJev from 'liblocaljev.so'
import { OperationCancellation, throwIfCancelled } from './OperationCancellation'

/** Developer-only local selector; readiness means the bundle actually loaded. */
export class LocalJev {
  private ready: boolean = false
  private note: string = 'not loaded'
  private loading: Promise<void> | null = null
  private source: string = ''

  isReady(): boolean { return this.ready }
  statusNote(): string { return this.note }
  identity(): string { return this.source }

  prepare(): Promise<void> {
    if (this.loading !== null) { return this.loading! }
    this.note = 'loading'
    this.loading = this.load()
    return this.loading!
  }

  private async load(): Promise<void> {
    try {
      let text = await nativeLocalJev.status()
      let status = JSON.parse(text) as Record<string, Object>
      this.ready = status['ready'] === true && status['abi'] === 1 && status['productionAllowed'] === false
      this.source = text
      this.note = this.ready ? 'experimental / uncalibrated' : String(status['reason'] || 'unavailable')
    } catch (_e) {
      this.ready = false
      this.note = 'native module unavailable'
    }
  }

  async ask(body: string, cancellation?: OperationCancellation): Promise<string> {
    throwIfCancelled(cancellation)
    await this.prepare()
    throwIfCancelled(cancellation)
    if (!this.ready) { return this.uncertain(this.note) }
    try {
      // Rust validates requests, scores and option IDs. No UI-thread inference.
      let text = await nativeLocalJev.experimentalDecisions(body)
      throwIfCancelled(cancellation)
      let reply = JSON.parse(text) as Record<string, Object>
      let local = reply['local'] as Record<string, Object>
      if (reply['answers'] === undefined || local === undefined ||
          (local['status'] !== 'uncertain' &&
            (local['diagnostic'] !== true || local['productionAllowed'] !== false))) {
        return this.uncertain('invalid_local_reply')
      }
      return text
    } catch (e) {
      throwIfCancelled(cancellation)
      return this.uncertain('local_inference_failed')
    }
  }

  private uncertain(reason: string): string {
    let local: Record<string, Object> = {}
    local['status'] = 'uncertain'
    local['reason'] = reason
    local['productionAllowed'] = false
    let reply: Record<string, Object> = {}
    let answers: Record<string, Object> = {}
    reply['answers'] = answers
    reply['local'] = local
    return JSON.stringify(reply)
  }
}

export const localJev: LocalJev = new LocalJev()
