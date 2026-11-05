/**
 * A first run of a program that just compiled, before it is served: it starts, draws, and has every handler
 * tapped once with a plain value -- twice over, drawing after each tap -- as a person trying it would. A
 * refined pill tracker once compiled with a list loop that never counted down: it drew fine empty and
 * stopped with "array length limit reached" at the first medicine added, on the phone, after it was served.
 *
 * What it reports goes back to the model as a repair, so only what is a mistake whatever the person types
 * counts: a trap while starting or drawing, a screen with nothing on it, and a handler that runs away. A handler that traps on the
 * made-up value (an index the list does not have) is set aside and the run goes on from the state before it.
 */

import { VirtualMachine, deserializeVbc2, RuntimeValue, RuntimeTrap, VeraNumberValue, VeraStringValue,
  VeraBooleanValue } from './VeraInterpreter'
import { UiHostEnvironment, decodeVeraUi, VeraUiNode } from './VeraUi'
import { CompileResult } from './VeraCompiler'
import { decodeGfx, pointerValue } from './VeraGfx'
import { checkWidget } from './VeraWidgetRefine'

/** Twice through the handlers: a list's second entry, a toggle switched back. */
const PASSES: number = 2

function countNodes(node: VeraUiNode): number {
  let count = 1
  for (let child of node.children) { count += countNodes(child) }
  return count
}

/** What a tap hands a handler: "12" reads as words and as a typed number alike; a finger lands near a corner. */
function plainValue(kind: string): RuntimeValue {
  if (kind === 'number') { return new VeraNumberValue(1) }
  if (kind === 'pointer') { return pointerValue('down', 0, 12, 12) }
  if (kind === 'boolean') { return new VeraBooleanValue(true) }
  return new VeraStringValue('12')
}

/** Draw every ui.Surface in the frame once, as its first frame on the phone would: a draw() that traps is caught here. */
function drawSurfaces(vm: VirtualMachine, node: VeraUiNode, state: RuntimeValue): void {
  if (node.kind === 'surface' && node.label.length > 0) { decodeGfx(vm.execute(node.label, [state])) }
  for (let child of node.children) { drawSurfaces(vm, child, state) }
}

function runaway(e: Object): boolean {
  return e instanceof RuntimeTrap && (e.trapCode === 'R0017' || e.trapCode === 'R0022')
}

/**
 * '' when the program runs, else its runtime error as diagnostics ("line:col CODE message"), for the repair
 * prompt to quote the lines from. A program whose view() draws fewer than two nodes is refused as empty, whoever wrote it
 * (the agent, a written section, the Generate screen's model, the chat's): nothing served is a blank screen. Every caller in the
 * app asks for that; `requireContent` is false only in the host checks (agent-check, parts-check, merge-check), which run a screen
 * that has nothing drawn yet to see that it starts and answers every handler.
 */
export function smokeRun(compiled: CompileResult, requireContent: boolean = true): string {
  let host = new UiHostEnvironment()
  let vm = new VirtualMachine(deserializeVbc2(compiled.vbc2), host)
  let state: RuntimeValue
  try {
    state = vm.execute('init')
    let roots = decodeVeraUi(vm.execute('view', [state]))
    let nodes = 0
    for (let root of roots) { nodes += countNodes(root) }
    for (let root of roots) { drawSurfaces(vm, root, state) }
    // Nothing to see is a mistake whatever the person types.
    if (requireContent && nodes === 0) { return 'The program compiled, but view() drew nothing' }
    if (requireContent && nodes < 2) { return 'The program compiled, but view() drew an empty screen' }
  } catch (e) {
    return diagnostic(e as Error, 'when the program starts')
  }
  let tapped: string[] = []
  for (let pass = 0; pass < PASSES; pass++) {
    let names: string[] = []
    compiled.handlers.forEach((_kind: string, name: string) => { names.push(name) })
    for (let name of names) {
      let before = state
      try {
        host.effectsAllowed = true
        state = vm.execute(name, [state, plainValue(compiled.handlers.get(name)!)])
      } catch (e) {
        if (runaway(e as Error)) { return diagnostic(e as Error, 'in ' + name + after(tapped)) }
        state = before
        continue
      } finally {
        host.effectsAllowed = false
        host.pendingEffects = []
      }
      tapped.push(name)
      try {
        for (let root of decodeVeraUi(vm.execute('view', [state]))) { drawSurfaces(vm, root, state) }
      } catch (e) {
        return diagnostic(e as Error, 'drawing the screen' + after(tapped))
      }
    }
  }
  if (deserializeVbc2(compiled.vbc2).functions.some((fn): boolean => fn.name === 'widget')) {
    return checkWidget(compiled.vbc2)
  }
  return ''
}

function after(tapped: string[]): string {
  if (tapped.length === 0) { return '' }
  let shown = tapped.length > 6 ? tapped.slice(tapped.length - 6) : tapped
  return ' after ' + (tapped.length > 6 ? '..., ' : '') + shown.join(', ')
}

function diagnostic(e: Error, when: string): string {
  let text = 'The program compiled, but stopped ' + when + ': ' + e.message
  if (!(e instanceof RuntimeTrap) || e.line <= 0) { return text }
  let lines = [e.line.toString() + ':1 ' + e.trapCode + ' ' + text]
  if (e.loopLine > 0 && e.loopLine !== e.line) {
    lines.push(e.loopLine.toString() + ':1 ' + e.trapCode + ' the loop it was in')
  }
  return lines.join('\n')
}
