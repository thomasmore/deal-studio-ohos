export interface OperationCancellation {
  isCancelled(): boolean
  onCancel(callback: () => void): () => void
}

export function isCancelled(cancellation?: OperationCancellation): boolean {
  return cancellation !== undefined && cancellation.isCancelled()
}

export function cancellationError(): Error {
  let error = new Error('Operation cancelled')
  error.name = 'OperationCancelledError'
  return error
}

export function throwIfCancelled(cancellation?: OperationCancellation): void {
  if (isCancelled(cancellation)) { throw cancellationError() }
}

export class PredicateCancellation implements OperationCancellation {
  private cancelled: () => boolean
  private cancellation?: OperationCancellation

  constructor(cancelled: () => boolean, cancellation?: OperationCancellation) {
    this.cancelled = cancelled
    this.cancellation = cancellation
  }

  isCancelled(): boolean {
    return this.cancelled() || isCancelled(this.cancellation)
  }

  onCancel(callback: () => void): () => void {
    if (this.isCancelled()) {
      callback()
      return (): void => {}
    }
    return this.cancellation !== undefined ? this.cancellation.onCancel(callback) : (): void => {}
  }
}

export class OperationController implements OperationCancellation {
  private cancelled: boolean = false
  private callbacks: (() => void)[] = []

  isCancelled(): boolean {
    return this.cancelled
  }

  onCancel(callback: () => void): () => void {
    if (this.cancelled) {
      callback()
      return (): void => {}
    }
    this.callbacks.push(callback)
    return (): void => {
      this.callbacks = this.callbacks.filter((item: () => void): boolean => item !== callback)
    }
  }

  cancel(): void {
    if (this.cancelled) { return }
    this.cancelled = true
    let callbacks = this.callbacks
    this.callbacks = []
    for (let callback of callbacks) {
      try { callback() } catch (_e) {}
    }
  }
}
