export interface StageTraceAttributes {
  entry?: string
  kind?: string
  action?: string
  digest?: string
  treeHash?: string
  result?: string
  id?: number
  rawTarget?: string
  rawMode?: string
  generation?: number
  params?: string
  resultHandler?: string
  outcome?: string
  reason?: string
  tickerId?: string
  class?: string
  nodeId?: number
  actions?: string[]
  draws?: string[]
  save?: string
  reveal?: boolean
  changed?: boolean
}

export interface StageTraceRecord {
  session: number
  event: string
  at: number
  attributes: StageTraceAttributes
}

export class StageTrace {
  private static active: boolean = false
  private static sessions: WeakMap<Object, number> = new WeakMap<Object, number>()
  private static nextSession: number = 0
  private static sink: ((record: StageTraceRecord) => void) | null = null

  static configure(enabled: boolean, sink?: (record: StageTraceRecord) => void): void {
    StageTrace.active = enabled
    StageTrace.sessions = new WeakMap<Object, number>()
    StageTrace.nextSession = 0
    StageTrace.sink = sink === undefined ? null : sink
  }

  static enabled(): boolean {
    return StageTrace.active
  }

  private static copyAttributes(source: StageTraceAttributes): StageTraceAttributes {
    const copy: StageTraceAttributes = {}
    if (source.entry !== undefined) { copy.entry = source.entry }
    if (source.kind !== undefined) { copy.kind = source.kind }
    if (source.action !== undefined) { copy.action = source.action }
    if (source.digest !== undefined) { copy.digest = source.digest }
    if (source.treeHash !== undefined) { copy.treeHash = source.treeHash }
    if (source.result !== undefined) { copy.result = source.result }
    if (source.id !== undefined) { copy.id = source.id }
    if (source.rawTarget !== undefined) { copy.rawTarget = source.rawTarget }
    if (source.rawMode !== undefined) { copy.rawMode = source.rawMode }
    if (source.generation !== undefined) { copy.generation = source.generation }
    if (source.params !== undefined) { copy.params = source.params }
    if (source.resultHandler !== undefined) { copy.resultHandler = source.resultHandler }
    if (source.outcome !== undefined) { copy.outcome = source.outcome }
    if (source.reason !== undefined) { copy.reason = source.reason }
    if (source.tickerId !== undefined) { copy.tickerId = source.tickerId }
    if (source.class !== undefined) { copy.class = source.class }
    if (source.nodeId !== undefined) { copy.nodeId = source.nodeId }
    if (source.actions !== undefined) { copy.actions = source.actions.slice() }
    if (source.draws !== undefined) { copy.draws = source.draws.slice() }
    if (source.save !== undefined) { copy.save = source.save }
    if (source.reveal !== undefined) { copy.reveal = source.reveal }
    if (source.changed !== undefined) { copy.changed = source.changed }
    return copy
  }

  static emit(owner: Object, event: string, attributes: StageTraceAttributes = {}): void {
    if (!StageTrace.active) { return }
    try {
      let session = StageTrace.sessions.get(owner)
      if (session === undefined) {
        session = ++StageTrace.nextSession
        StageTrace.sessions.set(owner, session)
      }
      const safeAttributes: StageTraceAttributes = StageTrace.copyAttributes(attributes)
      if (safeAttributes.tickerId !== undefined) { safeAttributes.tickerId = StageTrace.digest(safeAttributes.tickerId) }
      const record: StageTraceRecord = { session: session, event: event, at: Date.now(), attributes: safeAttributes }
      if (StageTrace.sink !== null) {
        StageTrace.sink(record)
      } else {
        console.info('VERA-STAGE-TRACE ' + JSON.stringify(record))
      }
    } catch (_) {}
  }

  static digest(text: string): string {
    let first = 2166136261
    let second = 5381
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i)
      first = Math.imul(first ^ code, 16777619)
      second = Math.imul(second, 33) ^ code
    }
    return (first >>> 0).toString(16).padStart(8, '0') + (second >>> 0).toString(16).padStart(8, '0')
  }

  static snapshot(owner: Object, encoded: string): void {
    if (!StageTrace.active) { return }
    try {
      StageTrace.emit(owner, 'SNAPSHOT', { digest: StageTrace.digest(encoded) })
    } catch (_) {}
  }

  static frame(owner: Object, root: Object | null, reveal: boolean): void {
    if (!StageTrace.active) { return }
    try {
      StageTrace.emit(owner, 'FRAME', { treeHash: StageTrace.digest(JSON.stringify(root)), reveal: reveal })
    } catch (_) {}
  }

  static request(owner: Object, id: number, rawTarget: string, values: Map<string, string>, resultHandler: string,
    rawMode: string = '', generation: number = 0): void {
    if (!StageTrace.active) { return }
    try {
      const params: string[][] = []
      values.forEach((value: string, key: string): void => { params.push([key, value]) })
      StageTrace.emit(owner, 'EFFECT_REQUEST', { id: id, rawTarget: StageTrace.digest(rawTarget),
        params: StageTrace.digest(JSON.stringify(params)), resultHandler: resultHandler,
        rawMode: StageTrace.digest(rawMode), generation: generation })
    } catch (_) {}
  }
}
