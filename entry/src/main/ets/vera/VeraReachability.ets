/** Bounded, deterministic UI exploration. A screen passes only after view() actually displays it.
 * No c_view_* calls, state injection, hidden handlers, network calls or model-authored test journeys.
 * Missing witnesses are repair diagnostics, not a claim of mathematical unreachability.
 */
import { VirtualMachine, deserializeVbc2, RuntimeValue, VeraNumberValue, VeraStringValue,
  VeraBooleanValue, VeraArrayValue, VeraObjectValue, encodeRuntimeValue, decodeRuntimeValue } from './VeraInterpreter'
import { UiHostEnvironment, VeraUiNode, decodeVeraUi } from './VeraUi'

const MAX_STATES: number = 192
const MAX_ACTIONS: number = 768
const MAX_DEPTH: number = 16
const MAX_STEPS: number = 2000000
const MAX_STATE_SIZE: number = 65536

/** Freeze the clock too: two runs of the same bytecode must explore the same states. */
class ReachHost extends UiHostEnvironment {
  invoke(module: string, name: string, args: RuntimeValue[], awaited: boolean): RuntimeValue {
    if (module === 'std/time') {
      switch (name) {
        case 'nowMillis': return new VeraNumberValue(1767268800000)
        case 'nowSeconds': return new VeraNumberValue(1767268800)
        case 'daysSinceEpoch': return new VeraNumberValue(20454)
        case 'millisOfDay': return new VeraNumberValue(43200000)
        case 'hourOfDay': return new VeraNumberValue(12)
        case 'minuteOfHour': return new VeraNumberValue(0)
        case 'weekday': return new VeraNumberValue(4)
        case 'dayOfMonth': return new VeraNumberValue(1)
        case 'monthOfYear': return new VeraNumberValue(1)
        case 'year': return new VeraNumberValue(2026)
      }
    }
    return super.invoke(module, name, args, awaited)
  }
}

class ReachState {
  state: RuntimeValue
  path: string[]
  constructor(state: RuntimeValue, path: string[]) { this.state = state; this.path = path }
}

export class ReachabilityResult {
  reached: string[] = []
  paths: string[] = []
  missing: string[] = []
  states: number = 0
  actions: number = 0
  steps: number = 0
  limits: string[] = []
  observations: string[] = []
  diagnostic: string = ''
}

function clone(value: RuntimeValue): RuntimeValue { return decodeRuntimeValue(encodeRuntimeValue(value)) }

/** Field insertion order is not application state. Sort it before deduplicating branches. */
function stateKey(value: RuntimeValue): string {
  if (value instanceof VeraObjectValue) {
    let names: string[] = []
    value.fields.forEach((_v: RuntimeValue, name: string) => { names.push(name) })
    names.sort()
    return JSON.stringify([value.classIdentity, names.map((name: string): string => JSON.stringify(name) + ':' + stateKey(value.fields.get(name)!))])
  }
  if (value instanceof VeraArrayValue) { return '[' + value.elements.map((v: RuntimeValue): string => stateKey(v)).join(',') + ']' }
  return JSON.stringify(encodeRuntimeValue(value))
}

/** Match native Tabs: only the selected child's controls are available. When(false) is already a spacer. */
function visible(roots: VeraUiNode[]): VeraUiNode[] {
  let out: VeraUiNode[] = []
  let visit = (node: VeraUiNode): void => {
    out.push(node)
    if (node.kind === 'tabs') {
      let index = Math.max(0, Math.min(Math.floor(node.eventValue), node.children.length - 1))
      if (index >= 0 && node.children[index] !== undefined) { visit(node.children[index]) }
    } else {
      for (let child of node.children) { visit(child) }
    }
  }
  for (let root of roots) { visit(root) }
  return out
}

function isInput(node: VeraUiNode): boolean {
  return ['field', 'numberfield', 'datefield', 'timefield', 'slider', 'select', 'toggle', 'checkbox'].indexOf(node.kind) >= 0
}

function isControl(node: VeraUiNode): boolean {
  if (!node.enabled || node.action.length === 0) { return false }
  // These components only render their action button when its label is nonempty.
  if ((node.kind === 'emptystate' || node.kind === 'insetbanner') && node.value.length === 0) { return false }
  return isInput(node) || ['button', 'cell', 'listitem', 'numberlistitem', 'emptystate', 'insetbanner',
    'backhandler', 'tabs', 'path', 'keyvalueitem'].indexOf(node.kind) >= 0
}

function inputValue(node: VeraUiNode): RuntimeValue {
  if (node.kind === 'field') {
    let text = node.value.length > 0 ? node.value : (node.email || node.keyboardType === 'email' ? 'test@example.com' : '12')
    while (text.length < Math.min(node.minLength, 128)) { text += '1' }
    if (node.maxLength >= 0) { text = text.substring(0, node.maxLength) }
    return new VeraStringValue(text)
  }
  if (node.kind === 'toggle' || node.kind === 'checkbox') { return new VeraBooleanValue(!node.checked) }
  if (node.kind === 'select') { return new VeraNumberValue(0) }
  if (node.kind === 'datefield') { return new VeraNumberValue(node.numberValue || 20454) }
  if (node.kind === 'timefield') { return new VeraNumberValue(node.numberValue || 720) }
  return new VeraNumberValue(Math.max(node.minimum, Math.min(node.maximum, node.kind === 'slider' ? 1 : (node.numberValue || 1))))
}

function note(result: ReachabilityResult, text: string): void {
  if (result.observations.indexOf(text) < 0) {
    result.observations.push(text)
    if (result.observations.length > 12) { result.observations.shift() }
  }
}

/** Runs on fresh disposable state; every branch is deep-cloned, including apps that mutate arrays in place. */
export function checkScreenReachability(vbc2: string, screens: string[]): ReachabilityResult {
  let result = new ReachabilityResult()
  if (screens.length < 2) { return result }
  let host = new ReachHost()
  let vm = new VirtualMachine(deserializeVbc2(vbc2), host, 100000)
  let queue: ReachState[] = []
  let seen = new Set<string>()
  let run = (name: string, args: RuntimeValue[]): RuntimeValue => {
    try { return vm.execute(name, args) } finally { result.steps += vm.stepsExecuted() }
  }
  let draw = (state: RuntimeValue): VeraUiNode[] => visible(decodeVeraUi(run('view', [clone(state)])))
  let enqueue = (state: RuntimeValue, path: string[]): void => {
    let key = stateKey(state)
    if (key.length > MAX_STATE_SIZE) { if (result.limits.indexOf('state size') < 0) { result.limits.push('state size') }; return }
    if (seen.has(key)) { return }
    if (queue.length >= MAX_STATES) { if (result.limits.indexOf('states') < 0) { result.limits.push('states') }; return }
    seen.add(key); queue.push(new ReachState(state, path))
  }
  let act = (state: RuntimeValue, node: VeraUiNode, value: RuntimeValue): RuntimeValue => {
    result.actions++
    host.effectsAllowed = true
    try {
      let next = run(node.action, [clone(state), value])
      if (host.pendingEffects.length > 0) { note(result, node.action + ' requested an external effect (not executed)') }
      return next
    } finally { host.effectsAllowed = false; host.pendingEffects = [] }
  }
  try {
    enqueue(run('init', []), [])
    for (let index = 0; index < queue.length && result.actions < MAX_ACTIONS && result.steps < MAX_STEPS; index++) {
      let current = queue[index]
      result.states++
      let nodes: VeraUiNode[]
      try { nodes = draw(current.state) } catch (e) { note(result, 'view: ' + (e as Error).message); continue }
      for (let node of nodes) {
        if (node.kind !== 'screen') { continue }
        for (let id of screens) {
          if ((node.screenId === id || node.screenId.startsWith(id + ':')) && result.reached.indexOf(id) < 0) {
            result.reached.push(id); result.paths.push(id + ': ' + (current.path.length > 0 ? current.path.join(' -> ') : 'init'))
          }
        }
      }
      if (result.reached.length === screens.length) { return result }
      if (current.path.length >= MAX_DEPTH) { if (result.limits.indexOf('depth') < 0) { result.limits.push('depth') }; continue }
      // One deterministic form-fill shortcut avoids exploring every permutation of independent field edits.
      // Each setter still comes from a fresh render; hidden/disappearing fields are never invoked.
      let filled = clone(current.state)
      let filledNames: string[] = []
      let inputs = nodes.filter((n: VeraUiNode): boolean => isInput(n) && n.enabled && n.action.length > 0)
      for (let input of inputs) {
        if (result.actions >= MAX_ACTIONS || result.steps >= MAX_STEPS) { break }
        try {
          let live = draw(filled).find((n: VeraUiNode): boolean => n.kind === input.kind && n.action === input.action && n.enabled)
          if (live === undefined) { continue }
          filled = act(filled, live, inputValue(live)); filledNames.push(live.action)
        } catch (e) { note(result, input.action + ': ' + (e as Error).message) }
      }
      if (filledNames.length > 0) { enqueue(filled, current.path.concat(['fill(' + filledNames.join(', ') + ')'])) }
      let choices = nodes.filter((n: VeraUiNode): boolean => isControl(n))
      let tried = new Set<string>()
      for (let node of choices) {
        let values: RuntimeValue[] = [isInput(node) ? inputValue(node) : new VeraNumberValue(node.eventValue)]
        if (node.kind === 'tabs' || node.kind === 'select') {
          values = node.options.map((_s: string, i: number): RuntimeValue => new VeraNumberValue(i))
        }
        for (let value of values) {
          if (result.actions >= MAX_ACTIONS || result.steps >= MAX_STEPS) { break }
          let label = node.action + '(' + JSON.stringify(encodeRuntimeValue(value)) + ')'
          if (tried.has(label)) { continue }
          tried.add(label)
          try {
            let next = act(current.state, node, value)
            if (!isInput(node) && stateKey(next) === stateKey(current.state)) { note(result, label + ' left state unchanged') }
            enqueue(next, current.path.concat([label]))
          } catch (e) { note(result, label + ': ' + (e as Error).message) }
        }
      }
    }
  } catch (e) { note(result, (e as Error).message) }
  if (result.actions >= MAX_ACTIONS) { result.limits.push('actions') }
  if (result.steps >= MAX_STEPS) { result.limits.push('VM steps') }
  result.missing = screens.filter((id: string): boolean => result.reached.indexOf(id) < 0)
  result.diagnostic = 'Screen reachability check failed. No executed UI path reached: ' + result.missing.join(', ') +
    '. Reached: ' + result.reached.join(', ') + '. Explored ' + result.states.toString() + ' states and ' + result.actions.toString() + ' actions.' +
    '\n' + result.paths.join('\n') + '\nObserved: ' + result.observations.join('; ') +
    (result.limits.length > 0 ? '\nSearch limits: ' + result.limits.join(', ') : '') +
    '\nRepair the actual navigation controls and their payloads. Row/action IDs must match stored record IDs; do not convert prefixed string IDs to numbers. ' +
    'Keep every planned screen and requested function. Tests start from init(), fill visible inputs and execute only rendered callbacks with their real payloads; external effects are not executed.'
  return result
}
