#!/usr/bin/env node
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = process.env.VERA_TYPESCRIPT_PATH ? require(process.env.VERA_TYPESCRIPT_PATH) : require('typescript')
const root = path.resolve(__dirname, '../..')
const virtual = path.join(root, 'entry/src/main/ets/runtime/shared/Messages.ts')
const consumer = path.join(path.dirname(virtual), 'MessagesConsumer.ts')
const source = fs.readFileSync(virtual.replace(/\.ts$/, '.ets'), 'utf8')
const options = { strict: true, noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, moduleResolution: ts.ModuleResolutionKind.NodeJs }
const interfaces = {
  ProgramRef: ['vbc2:string', 'stamp:string'],
  AcquireOptions: ['mode:RuntimeMode', 'persistKey:string', 'seedState:string'],
  ActorHandle: ['appId:string', 'vmGeneration:number', 'leaseId:string'],
  DrawRequest: ['nodeId:number', 'entry:string'],
  SurfaceFrameEvent: ['elapsed:number', 'actions:string[]', 'draws:DrawRequest[]'],
  InputPayload: ['kind:string', 'num:number', 'str:string', 'bool:boolean', 'phase:string', 'id:number', 'x:number', 'y:number'],
  InputEvent: ['appId:string', 'vmGeneration:number', 'kind:string', 'action:string', 'payload:InputPayload', 'persist:boolean', 'draws:DrawRequest[]'],
  TickEvent: ['tickerId:string', 'action:string', 'elapsed:number'],
  FrameEnvelope: ['appId:string', 'vmGeneration:number', 'frameSeq:number', 'appliedSeq:number', 'reveal:boolean', 'view:Object|null', 'gfx:Object[]', 'timing:number[]'],
  EffectRequest: ['appId:string', 'vmGeneration:number', 'effectId:number', 'kind:string', 'rawTarget:string', 'params:string[]', 'resultHandler:string', 'mode:string'],
  AppSubscriber: ['onViewFrame(frame:FrameEnvelope):void', 'onError(kind:string,message:string,inputSeq?:number):void', 'onStateSnapshot(encoded:string):void', 'onStateSaved(projectId:string):void', 'onEffectRequest(effect:EffectRequest):void', 'flushPendingInputFor(appId:string):void|Promise<void>', 'onMailboxWritable():void'],
  AcceptedAdmission: ["status:'ACCEPTED'", 'inputSeq?:number'],
  CoalescedAdmission: ["status:'COALESCED'"],
  BackpressureAdmission: ["status:'BACKPRESSURE'"],
  RejectedAdmission: ["status:'REJECTED'", 'reason:string']
}
const aliases = {
  RuntimeMode: ["'PREVIEW'", "'LIVE_EPHEMERAL'", "'LIVE_PERSISTENT'"],
  HostOperationError: ["'LEASE_CONFLICT'", "'APP_ID_CONFLICT'", "'INVALID_HANDLE'", "'ACTOR_NOT_READY'", "'SUBSCRIBER_CONFLICT'"],
  AdmissionResult: ['AcceptedAdmission', 'CoalescedAdmission', 'BackpressureAdmission', 'RejectedAdmission']
}
let passed = 0
function test(name, fn) {
  try { fn(); passed++; console.log('PASS ' + name) }
  catch (error) { console.error('FAIL ' + name + '\n' + error.stack); process.exitCode = 1 }
}
function compact(node) { return node.getText().replace(/\s|;/g, '') }
function typecheck(text) {
  const host = ts.createCompilerHost(options)
  const originalGet = host.getSourceFile.bind(host), originalExists = host.fileExists.bind(host)
  const files = new Map([[virtual, source], [consumer, text]])
  host.fileExists = name => files.has(name) || originalExists(name)
  host.getSourceFile = (name, languageVersion, onError, shouldCreateNewSourceFile) => files.has(name)
    ? ts.createSourceFile(name, files.get(name), languageVersion, true)
    : originalGet(name, languageVersion, onError, shouldCreateNewSourceFile)
  const program = ts.createProgram([virtual, consumer], options, host)
  return ts.getPreEmitDiagnostics(program).filter(d => d.category === ts.DiagnosticCategory.Error)
}
const fixture = `
import * as M from './Messages'
const program: M.ProgramRef = { vbc2: 'encoded', stamp: 'sha256' }
const modes: M.RuntimeMode[] = ['PREVIEW', 'LIVE_EPHEMERAL', 'LIVE_PERSISTENT']
const options: M.AcquireOptions = { mode: modes[0], persistKey: '', seedState: '' }
const handle: M.ActorHandle = { appId: 'app', vmGeneration: 1, leaseId: 'opaque' }
const draw: M.DrawRequest = { nodeId: 7, entry: 'draw' }
const surface: M.SurfaceFrameEvent = { elapsed: 16, actions: ['animate'], draws: [draw] }
const numeric: M.InputPayload = { kind: 'NUMBER', num: 42, str: '', bool: false, phase: '', id: 0, x: 0, y: 0 }
const back: M.InputPayload = { ...numeric, num: 0 }
const bool: M.InputPayload = { ...numeric, kind: 'BOOLEAN', bool: true }
const string: M.InputPayload = { ...numeric, kind: 'STRING', str: 'hello' }
const pointer: M.InputPayload = { ...numeric, kind: 'POINTER', phase: 'down', id: 2, x: 12.5, y: 24 }
const payloads: M.InputPayload[] = [numeric, back, bool, string, pointer, { ...numeric, kind: 'NONE' }]
const input: M.InputEvent = { appId: 'app', vmGeneration: 1, kind: 'BACK', action: 'back', payload: back, persist: false, draws: [] }
const tick: M.TickEvent = { tickerId: 'clock', action: 'advance', elapsed: 16 }
const frame: M.FrameEnvelope = { appId: 'app', vmGeneration: 1, frameSeq: 2, appliedSeq: 1, reveal: true, view: null, gfx: [], timing: [1, 2, 3] }
const weakFrame: M.FrameEnvelope = { ...frame, view: { arbitrary: true }, gfx: [{ deliberatelyUntyped: true }] }
const effect: M.EffectRequest = { appId: 'app', vmGeneration: 1, effectId: 3, kind: 'intent', rawTarget: 'target', params: ['name', 'value'], resultHandler: 'done', mode: 'future' }
const subscriber: M.AppSubscriber = {
  onViewFrame(frame: M.FrameEnvelope): void {},
  onError(kind: string, message: string, inputSeq?: number): void {},
  onStateSnapshot(encoded: string): void {},
  onStateSaved(projectId: string): void {},
  onEffectRequest(effect: M.EffectRequest): void {},
  flushPendingInputFor(appId: string): void {},
  onMailboxWritable(): void {}
}
const asyncSubscriber: M.AppSubscriber = { ...subscriber, flushPendingInputFor: async (appId: string): Promise<void> => {} }
const hostErrors: M.HostOperationError[] = ['LEASE_CONFLICT', 'APP_ID_CONFLICT', 'INVALID_HANDLE', 'ACTOR_NOT_READY', 'SUBSCRIBER_CONFLICT']
`
function check(name, text, valid = true) {
  test(name, () => {
    const errors = typecheck(fixture + '\n' + text)
    const formatted = ts.formatDiagnostics(errors, { getCurrentDirectory: () => root, getCanonicalFileName: f => f, getNewLine: () => '\n' })
    if (valid) assert.equal(errors.length, 0, formatted)
    else {
      assert(errors.length > 0, 'Invalid consumer unexpectedly accepted')
      assert(errors.every(d => d.file && d.file.fileName === consumer && d.start >= fixture.length), formatted)
    }
  })
}
test('exact exported plain boundary inventories', () => {
  const syntax = ts.createSourceFile(virtual, source, ts.ScriptTarget.Latest, true)
  assert(!/@ts-(ignore|expect-error|nocheck)/.test(source), 'Suppressed diagnostics')
  assert.deepEqual(syntax.statements.map(s => s.name && s.name.text).sort(), [...Object.keys(interfaces), ...Object.keys(aliases)].sort())
  for (const node of syntax.statements) {
    assert.deepEqual((node.modifiers || []).map(m => m.kind), [ts.SyntaxKind.ExportKeyword])
    assert(!node.typeParameters && !node.heritageClauses, node.name.text)
    if (ts.isInterfaceDeclaration(node)) {
      assert(Object.hasOwn(interfaces, node.name.text))
      assert(node.members.every(m => ts.isPropertySignature(m) || ts.isMethodSignature(m)))
      assert.deepEqual(node.members.map(compact).sort(), interfaces[node.name.text].slice().sort(), node.name.text)
    } else {
      assert(ts.isTypeAliasDeclaration(node) && Object.hasOwn(aliases, node.name.text))
      assert(ts.isUnionTypeNode(node.type))
      assert.deepEqual(node.type.types.map(compact).sort(), aliases[node.name.text].slice().sort(), node.name.text)
    }
  }
})
check('representative scalar payloads, separate tick, weak Object frames and both flush implementations', '')
check('subscriber call and return contracts', `
subscriber.onViewFrame(frame); subscriber.onError('trap', 'message'); subscriber.onError('trap', 'message', 4)
subscriber.onStateSnapshot('encoded'); subscriber.onStateSaved('project'); subscriber.onEffectRequest(effect)
subscriber.onMailboxWritable()
const flushed: void | Promise<void> = subscriber.flushPendingInputFor('app')
const callbacks: void[] = [subscriber.onViewFrame(frame), subscriber.onError('trap', 'message'), subscriber.onStateSnapshot('encoded'), subscriber.onStateSaved('project'), subscriber.onEffectRequest(effect), subscriber.onMailboxWritable()]
`)
check('named admissions and exhaustive narrowing', `
const accepted: M.AcceptedAdmission = { status: 'ACCEPTED', inputSeq: 1 }
const noInput: M.AcceptedAdmission = { status: 'ACCEPTED' }
const coalesced: M.CoalescedAdmission = { status: 'COALESCED' }
const blocked: M.BackpressureAdmission = { status: 'BACKPRESSURE' }
const rejected: M.RejectedAdmission = { status: 'REJECTED', reason: 'closed' }
const admissions: M.AdmissionResult[] = [accepted, noInput, coalesced, blocked, rejected]
function inspect(result: M.AdmissionResult): number | undefined {
  switch (result.status) {
    case 'ACCEPTED': return result.inputSeq
    case 'REJECTED': const reason: string = result.reason; return undefined
    case 'COALESCED': case 'BACKPRESSURE': return undefined
    default: const exhaustive: never = result; return exhaustive
  }
}
`)
const invalid = [
  ['invalid mode', `const bad: M.RuntimeMode = 'LIVE'`],
  ['missing acquire state', `const bad: M.AcquireOptions = { mode: 'PREVIEW', persistKey: '' }`],
  ['invalid host error', `const bad: M.HostOperationError = 'UNKNOWN'`],
  ['string pointer id', `const bad: M.InputPayload = { ...pointer, id: '2' }`],
  ['string numeric payload', `const bad: M.InputPayload = { ...numeric, num: '42' }`],
  ['numeric bool payload', `const bad: M.InputPayload = { ...bool, bool: 1 }`],
  ['numeric string payload', `const bad: M.InputPayload = { ...string, str: 1 }`],
  ['numeric pointer phase', `const bad: M.InputPayload = { ...pointer, phase: 0 }`],
  ['string pointer coordinate', `const bad: M.InputPayload = { ...pointer, x: '12' }`],
  ['missing scalar inventory', `const bad: M.InputPayload = { kind: 'number', num: 0 }`],
  ['tick is not input', `const bad: M.InputEvent = tick`],
  ['string tick elapsed', `const bad: M.TickEvent = { ...tick, elapsed: '16' }`],
  ['string draw node', `const bad: M.DrawRequest = { ...draw, nodeId: '7' }`],
  ['string timing', `const bad: M.FrameEnvelope = { ...frame, timing: ['1'] }`],
  ['null gfx element', `const bad: M.FrameEnvelope = { ...frame, gfx: [null] }`],
  ['Map effect params', `const bad: M.EffectRequest = { ...effect, params: new Map<string, string>() }`],
  ['RuntimeValue effect params', `interface RuntimeValue { tag: number; value: string }; const values: RuntimeValue[] = [{ tag: 1, value: 'x' }]; const bad: M.EffectRequest = { ...effect, params: values }`],
  ['nested effect params', `const bad: M.EffectRequest = { ...effect, params: [['name', 'value']] }`],
  ['missing rejection reason', `const bad: M.AdmissionResult = { status: 'REJECTED' }`],
  ['invalid admission status', `const bad: M.AdmissionResult = { status: 'OK', inputSeq: 1 }`],
  ['string admitted sequence', `const bad: M.AdmissionResult = { status: 'ACCEPTED', inputSeq: '1' }`],
  ['unnarrowed admitted sequence', `function bad(result: M.AdmissionResult) { return result.inputSeq }`],
  ['optional admitted sequence', `function bad(result: M.AcceptedAdmission): number { return result.inputSeq }`],
  ['subscriber wrong frame', `subscriber.onViewFrame(input)`],
  ['subscriber wrong error sequence', `subscriber.onError('trap', 'message', '1')`],
  ['subscriber wrong snapshot', `subscriber.onStateSnapshot(frame)`],
  ['subscriber wrong saved id', `subscriber.onStateSaved(1)`],
  ['subscriber wrong effect', `subscriber.onEffectRequest(frame)`],
  ['subscriber missing flush app id', `subscriber.flushPendingInputFor()`],
  ['subscriber wrong flush result', `const bad: M.AppSubscriber = { ...subscriber, flushPendingInputFor: async (appId: string): Promise<number> => 1 }`],
  ['subscriber writable takes no args', `subscriber.onMailboxWritable('app')`],
  ['subscriber method required', `const { onMailboxWritable, ...rest } = subscriber; const bad: M.AppSubscriber = rest`]
]
for (const status of ['COALESCED', 'BACKPRESSURE', 'REJECTED']) {
  invalid.push([status + ' forbids sequence', `const bad: M.AdmissionResult = { status: '${status}', inputSeq: 1${status === 'REJECTED' ? ", reason: 'closed'" : ''} }`])
  invalid.push([status + ' narrowed sequence absent', `function bad(result: M.AdmissionResult) { if (result.status === '${status}') return result.inputSeq }`])
}
for (const type of ['InputEvent', 'TickEvent', 'SurfaceFrameEvent']) {
  const value = { InputEvent: 'input', TickEvent: 'tick', SurfaceFrameEvent: 'surface' }[type]
  for (const field of ['inSeq', 'inputSeq', 'leaseId']) invalid.push([type + ' rejects stale ' + field, `const bad: M.${type} = { ...${value}, ${field}: ${field === 'leaseId' ? "'opaque'" : '1'} }`])
}
for (const [name, text] of invalid) check(name, text, false)
test('type-only source emits no runtime declarations or imports', () => {
  const compiled = ts.transpileModule(source, { fileName: virtual, compilerOptions: options, reportDiagnostics: true })
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0)
  const exports = {}
  new Function('exports', 'require', compiled.outputText)(exports, () => { throw Error('Unexpected runtime import') })
  assert.deepEqual(Object.getOwnPropertyNames(exports), ['__esModule'])
  assert.equal(exports.__esModule, true)
})
console.log(`${passed}/${invalid.length + 5} runtime message contract cases passed`)
