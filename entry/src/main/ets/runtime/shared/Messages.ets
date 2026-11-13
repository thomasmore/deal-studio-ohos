export interface ProgramRef {
  vbc2: string
  stamp: string
}

export type RuntimeMode = 'PREVIEW' | 'LIVE_EPHEMERAL' | 'LIVE_PERSISTENT'

export interface AcquireOptions {
  mode: RuntimeMode
  persistKey: string
  seedState: string
}

export interface ActorHandle {
  appId: string
  vmGeneration: number
  leaseId: string
}

export interface DrawRequest {
  nodeId: number
  entry: string
}

export interface SurfaceFrameEvent {
  elapsed: number
  actions: string[]
  draws: DrawRequest[]
}

export interface InputPayload {
  kind: string
  num: number
  str: string
  bool: boolean
  phase: string
  id: number
  x: number
  y: number
}

export interface InputEvent {
  appId: string
  vmGeneration: number
  kind: string
  action: string
  payload: InputPayload
  persist: boolean
  draws: DrawRequest[]
}

export interface TickEvent {
  tickerId: string
  action: string
  elapsed: number
}

export interface FrameEnvelope {
  appId: string
  vmGeneration: number
  frameSeq: number
  appliedSeq: number
  reveal: boolean
  view: Object | null
  gfx: Object[]
  timing: number[]
}

export interface EffectRequest {
  appId: string
  vmGeneration: number
  effectId: number
  kind: string
  rawTarget: string
  params: string[]
  resultHandler: string
  mode: string
}

export interface AppSubscriber {
  onViewFrame(frame: FrameEnvelope): void
  onError(kind: string, message: string, inputSeq?: number): void
  onStateSnapshot(encoded: string): void
  onStateSaved(projectId: string): void
  onEffectRequest(effect: EffectRequest): void
  flushPendingInputFor(appId: string): void | Promise<void>
  onMailboxWritable(): void
}

export type HostOperationError =
  'LEASE_CONFLICT' | 'APP_ID_CONFLICT' | 'INVALID_HANDLE' | 'ACTOR_NOT_READY' | 'SUBSCRIBER_CONFLICT'

export interface AcceptedAdmission {
  status: 'ACCEPTED'
  inputSeq?: number
}

export interface CoalescedAdmission {
  status: 'COALESCED'
}

export interface BackpressureAdmission {
  status: 'BACKPRESSURE'
}

export interface RejectedAdmission {
  status: 'REJECTED'
  reason: string
}

export type AdmissionResult = AcceptedAdmission | CoalescedAdmission | BackpressureAdmission | RejectedAdmission
