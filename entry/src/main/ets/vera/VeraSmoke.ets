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
import { checkScreenReachability } from './VeraReachability'

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
export function smokeRun(compiled: CompileResult, requireContent: boolean = true, expectedScreens: string[] = [], startScreen: string = ''): string {
  let host = new UiHostEnvironment()
  let module = deserializeVbc2(compiled.vbc2)
  let vm = new VirtualMachine(module, host)
  let names = module.functions.map((fn): string => fn.name)
  // Generic refinements have no stored plan; generated c_view_ functions still retain the bounded view gate.
  let inferred = names.filter((name: string): boolean => name.startsWith('c_view_')).map((name: string): string => name.substring(7))
  let screens = expectedScreens.length > 0 ? expectedScreens : (inferred.length > 1 ? inferred : [])
  let state: RuntimeValue
  try {
    state = vm.execute('init')
    let roots = decodeVeraUi(vm.execute('view', [state]))
    if (screens.length > 0) {
      let shape = appTreeProblem(roots, screens, startScreen)
      if (shape.length > 0) { return shape }
      // Every declared view, including an editor with no selection, is invoked once on the SAME initial state.
      for (let id of screens) {
        let name = 'c_view_' + id
        if (names.indexOf(name) < 0) { return 'Missing planned screen function ' + name + '(state: AppState): ui.View' }
        try {
          let drawn = decodeVeraUi(vm.execute(name, [state]))
          if (drawn.length !== 1 || drawn[0].kind !== 'screen' || !screenIs(drawn[0].screenId, id) || !hasContent(drawn[0]) ||
              countKind(drawn[0], 'screen') !== 1 || countKind(drawn[0], 'apptheme') !== 0) {
            return name + ' must return a nonempty ui.Screen("' + id + '", children), with an optional :recordId suffix'
          }
          drawSurfaces(vm, drawn[0], state)
        } catch (e) { return diagnostic(e as Error, 'drawing ' + name + ' with empty/missing selection') }
      }
    }
    let nodes = 0
    for (let root of roots) { nodes += countNodes(root) }
    for (let root of roots) { drawSurfaces(vm, root, state) }
    // Nothing to see is a mistake whatever the person types.
    if (requireContent && nodes === 0) { return 'The program compiled, but view() drew nothing' }
    if (requireContent && nodes < 2) { return 'The program compiled, but view() drew an empty screen' }
  } catch (e) {
    return diagnostic(e as Error, 'when the program starts')
  }
  // Reachability starts from fresh state and uses only rendered controls, never the synthetic
  // all-handler state below. Return its diagnostic through the same existing repair loop.
  if (screens.length > 1) {
    let reach = checkScreenReachability(compiled.vbc2, screens)
    if (reach.diagnostic.length > 0) { return reach.diagnostic }
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
        let roots = decodeVeraUi(vm.execute('view', [state]))
        if (screens.length > 0) {
          let shape = appTreeProblem(roots, screens)
          if (shape.length > 0) { return shape + after(tapped) }
        }
        for (let root of roots) { drawSurfaces(vm, root, state) }
      } catch (e) {
        return diagnostic(e as Error, 'drawing the screen' + after(tapped))
      }
    }
  }
  // A program with a widget may be on the home screen: a change that breaks the card is refused like one that breaks the app,
  // and said to be about the widget, so the repair -- and the person -- knows where to look.
  if (deserializeVbc2(compiled.vbc2).functions.some((fn): boolean => fn.name === 'widget')) {
    let card = checkWidget(compiled.vbc2)
    if (card.length > 0) {
      return 'The app\'s home-screen widget (function widget and what it calls) no longer works: ' + card +
        '\nKeep the widget working with the card-safe components and limits; change it only as far as the request needs.'
    }
  }
  return ''
}

function hasContent(node: VeraUiNode): boolean {
  for (let child of node.children) { if (hasContent(child)) { return true } }
  // Wrappers and invisible lifecycle nodes alone do not make a usable screen.
  return ['screen', 'apptheme', 'column', 'row', 'section', 'adaptivecolumns', 'actionbar', 'listgroup', 'metricgroup',
    'when', 'empty', 'backhandler', 'ticker', 'spacer'].indexOf(node.kind) < 0
}

function countKind(node: VeraUiNode, kind: string): number {
  let count = node.kind === kind ? 1 : 0
  for (let child of node.children) { count += countKind(child, kind) }
  return count
}

function screenIs(actual: string, id: string): boolean {
  return actual === id || actual.startsWith(id + ':')
}

/** One theme and one active, declared screen, not eagerly built inactive screens. */
function appTreeProblem(roots: VeraUiNode[], screens: string[], start: string = ''): string {
  let themes = 0
  let active: VeraUiNode[] = []
  let visit = (node: VeraUiNode): void => {
    if (node.kind === 'apptheme') { themes++ }
    if (node.kind === 'screen') { active.push(node) }
    for (let child of node.children) { visit(child) }
  }
  for (let root of roots) { visit(root) }
  if (roots.length !== 1 || roots[0].kind !== 'apptheme' || themes !== 1 || active.length !== 1) {
    return 'The shared app must draw exactly one AppTheme containing exactly one active Screen'
  }
  if (countNodes(active[0]) < 2) { return 'The active planned Screen is empty: ' + active[0].screenId }
  if (!hasContent(active[0])) { return 'The active planned screen is empty: ' + active[0].screenId }
  if (!screens.some((id: string): boolean => screenIs(active[0].screenId, id))) { return 'The active Screen has an undeclared id: ' + active[0].screenId }
  if (start.length > 0 && !screenIs(active[0].screenId, start)) { return 'The app must start on screen ' + start }
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
