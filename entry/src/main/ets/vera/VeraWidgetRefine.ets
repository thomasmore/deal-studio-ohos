import { CATALOG, describeComponents } from './VeraUiCatalog'
import { widgetRefinementError } from './VeraCompiler'
import { VirtualMachine, deserializeVbc2, decodeRuntimeValue } from './VeraInterpreter'
import { decodeVeraUi, UiHostEnvironment } from './VeraUi'
import { WidgetSession, CardNode, LIVE_MAX_DEPTH, LIVE_MAX_NODES, LIVE_MAX_TEXT, LIVE_MAX_JSON, LIVE_MAX_STEPS } from './VeraLiveWidget'

/** The components a card draws: only these are shown to the widget writer, and only these may a widget use. */
export const CARD_KINDS: string[] = CATALOG.filter((component): boolean => component.card).map((component): string => component.name)

/**
 * Only Make widget receives these instructions. Fullscreen UI is not restricted.
 *
 * The person's request says what the widget shows ("The home-screen widget should show: ..."); this says what a widget is:
 * a second, small view of the same state, read at a glance, with only the few things that matter most.
 */
export function widgetRefinementPrompt(whole: boolean = true): string {
  return (whole ? 'Add a home-screen widget to this existing program. Return the complete program.\n' :
    'Write a home-screen widget for this existing program.\n') +
    'The widget is a second view of the same app: function widget(state) draws the very state view(state) draws, on a small ' +
    'card on the phone\'s home screen. The person\'s request says what it should show; follow it. ' +
    'A widget is read at a glance, in a second: show only the few things that matter most -- one to three figures or short ' +
    'lines, each with a label of a word or two -- and at most two buttons, for the actions worth doing without opening the app. ' +
    'Leave out everything else: lists and history, settings, inputs, explanations, and the app\'s name or any title or ' +
    'heading -- the space is too small for them. When the request asks for more than fits, keep what matters most and drop ' +
    'the rest. If the program already has a widget, replace it with the one asked for.\n' +
    'The card is redrawn about every 30 minutes without the app being opened, so a figure widget works out from the clock ' +
    '(time left until something) stays current by itself. If the state itself goes out of date with the time -- the day\'s ' +
    'figures start again after midnight, a countdown that is over should end, a streak breaks after a missed day -- also add ' +
    'function widgetRefresh(state: the init return type): the init return type. The card runs it before redrawing, and the ' +
    'app when it opens and when it comes back, and both save what it returns: bring the state up to date with the clock ' +
    '(std/time) and return it, changing only ' +
    'what the time has made out of date. Running it twice in a row must give the same state as running it once, so never ' +
    'add to a figure in it. No phone effects, but one: if the program gets live figures with sdk.call("Vera.Source.fetch", ...), ' +
    'widgetRefresh makes that same call, copied exactly with the same handler, and returns the state; the card makes the call ' +
    'and passes the answer to that handler before it redraws, so the card shows the figures as they are now. A button may ' +
    'make the same call (a Refresh), the same way. A program that reads its figures off a search (sdk.call("Vera.Live.fetch", ' +
    '...)) is not refreshed on the card -- a search is too slow for it -- so neither widgetRefresh nor a widget button makes ' +
    'that call: the widget shows the figures the app fetched last, with their time, and no Refresh button. ' +
    'Leave widgetRefresh out when nothing in the state goes out of date.\n' +
    (whole ? 'Preserve every existing class, init, view and handler unchanged, including their signatures and bodies. ' +
    'Add or replace only function widget(state: the init return type): ui.View, widgetRefresh, and new uniquely named ' +
    'helpers/number handlers. ' : WIDGET_ONLY) +
    'Share the existing state; do not add fields or reset data. ' +
    'Keep the existing import lines; add import * as time from "std/time" only if widget or widgetRefresh reads the clock. ' +
    'If an action needs SDK/intent effects, omit it. Do not add a button that opens the app: a tap on the card outside a ' +
    'button already does. ' +
    'widget must be synchronous and side-effect free, with no ticker, scrolling, inputs, images, or networking. ' +
    'Use ONLY the card-safe constructors below in widget and its helpers; the fullscreen view keeps its full catalogue. ' +
    'AppTheme is optional and root-only; light theme only. The whole 2x2 card is the widget\'s; nothing is drawn above it. ' +
    'Prefer one Column with a summary and one Row of buttons; avoid long lists. ' +
    'Limits: depth ' + LIVE_MAX_DEPTH.toString() + ' excluding root AppTheme, ' + LIVE_MAX_NODES.toString() +
    ' nodes, ' + LIVE_MAX_TEXT.toString() + ' UTF-16 characters/text, ' + LIVE_MAX_JSON.toString() +
    ' UTF-16 units/frame including state token, ' + LIVE_MAX_STEPS.toString() + ' VM steps/entry.\n' +
    (whole ? describeComponents(CARD_KINDS) : '')
}

/**
 * The answer when only the widget is written (AgentWidget): the program around it is kept as it is, so nothing of it is
 * written again -- most of what made the whole-program reply slow.
 */
const WIDGET_ONLY: string = 'Answer with only what the widget adds, in one fenced block: function widget(state: the init ' +
  'return type): ui.View, widgetRefresh when it is needed, new uniquely named helpers or number handlers, and an import line ' +
  'only when it is new. Do not write anything else of the program again: its classes, init, view and handlers stay exactly ' +
  'as they are and cannot be changed from here. '

/** A widget is read at a glance: what widgetRefinementPrompt asks for, held to. */
export const WIDGET_MAX_BUTTONS: number = 2
export const WIDGET_MAX_TEXTS: number = 8

/** Structural preservation is checked separately from runtime validation so repair gets precise feedback. */
export function validateWidgetRefinement(base: string, source: string, vbc2: string, saved: string = ''): string {
  try {
    let preservation = widgetRefinementError(base, source)
    if (preservation.length > 0) { return preservation }
    let runtime = checkWidget(vbc2, saved)
    if (runtime.length > 0) { return runtime }
    return glanceError(vbc2, saved)
  } catch (e) { return 'Widget validation: ' + (e as Error).message }
}

/**
 * More than a glance: too many buttons or lines for the few things a widget shows. Only Make widget is held to it; the card
 * itself draws any frame within its budget. Said so the model can cut the widget down on the next attempt.
 */
function glanceError(vbc2: string, saved: string): string {
  let frame = new WidgetSession(vbc2, 'validation', saved).frame('project', 'App', '')
  let buttons = 0
  let texts = 0
  let count = (nodes: CardNode[]): void => {
    for (let node of nodes) {
      if (node.kind === 'button') { buttons++ } else if (node.text.length > 0) { texts++ }
      count(node.children)
    }
  }
  count(frame.nodes)
  if (buttons > WIDGET_MAX_BUTTONS) {
    return 'The widget has ' + buttons.toString() + ' buttons; a widget has at most ' + WIDGET_MAX_BUTTONS.toString() +
      ', for the actions that matter most. Not one per item: drop the rest, they stay in the app.'
  }
  if (texts > WIDGET_MAX_TEXTS) {
    return 'The widget shows ' + texts.toString() + ' texts; a widget shows at most ' + WIDGET_MAX_TEXTS.toString() +
      ' (one to three figures with short labels). No lists or history: keep what matters most, the rest stays in the app.'
  }
  return ''
}

/** Also used by smokeRun for any program that declares widget. Never executes phone effects. */
export function checkWidget(vbc2: string, saved: string = ''): string {
  try {
    let session = new WidgetSession(vbc2, 'validation', saved)
    let frame = session.frame('project', 'App', '')
    if (!frame.live) { return 'Missing function widget(state): ui.View' }
    let state = session.encodedState()
    // Each actual visible button, twice: includes distinct repeated-row payloads and redraw validation.
    let buttons: CardNode[] = []
    let collect = (nodes: CardNode[]): void => {
      for (let node of nodes) {
        if (node.kind === 'button' && node.enabled && node.action.length > 0) { buttons.push(node) }
        collect(node.children)
      }
    }
    collect(frame.nodes)
    let refreshError = checkRefresh(vbc2, state)
    if (refreshError.length > 0) { return refreshError }
    for (let button of buttons) {
      let branch = new WidgetSession(vbc2, 'validation', state)
      for (let pass = 0; pass < 2; pass++) {
        let current = branch.frame('project', 'App', '')
        let available = (nodes: CardNode[]): boolean => nodes.some((node: CardNode): boolean =>
          (node.kind === 'button' && node.enabled && node.action === button.action && node.value === button.value) || available(node.children))
        if (!available(current.nodes)) { break }
        // A Refresh button's live source is not fetched here: its handler is given a failure, which it must take and still draw.
        for (let request of branch.tap(current, current.token, button.action, button.value)) {
          branch.answer(request.handler, 'error: the source is not reached while checking')
        }
        branch.frame('project', 'App', '')
        let host = new UiHostEnvironment()
        let vm = new VirtualMachine(deserializeVbc2(vbc2), host, LIVE_MAX_STEPS)
        // The same state must still draw in the app, not only on the card.
        decodeVeraUi(vm.execute('view', [decodeRuntimeValue(JSON.parse(branch.encodedState()) as Object)]))
      }
    }
    return ''
  } catch (e) { return 'Widget validation: ' + (e as Error).message }
}

/**
 * A widget that reads or builds state the app does not keep (E2031 no such field, E2022 unknown field). The reply's changes to
 * the app's own declarations are dropped (spliceWidget), so adding the field again cannot work: the next attempt is told so.
 */
export function widgetRepairNote(errors: string): string {
  if (!/\bE20(31|22)\b/.test(errors)) { return errors }
  return 'The widget cannot add fields to the state or change the app\'s existing classes and functions: they are kept ' +
    'exactly as the app has them, and any change to them is dropped. Show and change only what the state already holds; ' +
    'leave out what it does not.\n' + errors
}

/**
 * widgetRefresh, as the card runs it: twice from the saved state. Both times the widget and the app still draw it, and the
 * second run changes nothing the first did not -- the card may run it any number of times. A clock reading the program keeps
 * (a timestamp in ms) may differ between the two runs by up to a minute.
 */
function checkRefresh(vbc2: string, saved: string): string {
  let session = new WidgetSession(vbc2, 'validation', saved)
  if (!session.refreshes()) { return '' }
  let states: string[] = []
  for (let run = 0; run < 2; run++) {
    // A live source is not fetched here: its handler is given a failure, which it must take and still draw.
    for (let request of session.refresh()) { session.answer(request.handler, 'error: the source is not reached while checking') }
    session.frame('project', 'App', '')
    let host = new UiHostEnvironment()
    let vm = new VirtualMachine(deserializeVbc2(vbc2), host, LIVE_MAX_STEPS)
    decodeVeraUi(vm.execute('view', [decodeRuntimeValue(JSON.parse(session.encodedState()) as Object)]))
    states.push(session.encodedState())
  }
  if (!sameState(JSON.parse(states[0]) as Object, JSON.parse(states[1]) as Object)) {
    return 'widgetRefresh changed the state again when run a second time. The card runs it about every 30 minutes, any ' +
      'number of times: bring the state up to date with the clock (a new day starts the day\'s figures again, a countdown ' +
      'that is over ends), so that running it twice gives the same state as running it once. Never add to a figure in it.'
  }
  return ''
}

/** Two encoded states alike, but for timestamps (std/time.nowMillis over 1e12, nowSeconds over 1e9) under a minute apart. */
function sameState(a: Object | null, b: Object | null): boolean {
  if (typeof a === 'number' && typeof b === 'number') {
    let x = a as number
    let y = b as number
    return x === y || (x > 1e12 && y > 1e12 && Math.abs(x - y) < 60000) ||
      (x > 1e9 && y > 1e9 && x < 1e11 && y < 1e11 && Math.abs(x - y) < 60)
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    let left = a as Object[]
    let right = b as Object[]
    return left.length === right.length && left.every((item: Object, i: number): boolean => sameState(item, right[i]))
  }
  if (a !== null && b !== null && typeof a === 'object' && typeof b === 'object') {
    let left = a as Record<string, Object>
    let right = b as Record<string, Object>
    let keys = Object.keys(left)
    return keys.length === Object.keys(right).length && keys.every((key: string): boolean => sameState(left[key], right[key]))
  }
  return a === b
}
