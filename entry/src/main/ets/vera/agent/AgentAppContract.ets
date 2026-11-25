/** The one shared-module writer contract. No new router, store, fragment format or per-screen pipeline. */
import { NeedsPlan } from '../NeedsPlan'
import { BytecodeModule } from '../VeraInterpreter'
import { describeComponents } from '../VeraUiCatalog'

export const APP_CONTRACT: string = '\n\nWrite ONE shared contribution implementing the whole planned app, not a program per screen. ' +
  'The host supplies AppState, init(), view() and exactly one AppTheme. Answer only in this existing section format:\n' +
  '<classes>\nany @jsonable record classes, named C_...\n</classes>\n' +
  '<fields>\none shared state field per line: c_name: type = initial value\n</fields>\n' +
  '<functions>\nnamed screen views, shared handlers and helpers\n</functions>\n' +
  '<view>\nif/else choosing only the active c_view_<screenId>(state), then sections.push(active);\n</view>\n' +
  'Rules:\n' +
  '- Every requested user action must have a reachable control on an appropriate screen, including deletion when requested. ' +
  'Declaring a handler is not enough: bind the control to it and pass the stable record ID. Before answering, trace each requested action from control to handler to visible result. Do not add unrequested actions.\n' +
  '- Every field and function starts with c_; every class with C_. Reserve c_view_ for declared screens. Each declared screen has function c_view_<screenId>(state: AppState): ui.View. ' +
  'It returns ui.Screen("<screenId>", children); for an editor of a selected record the identity may be "<screenId>:" + the stable record id. ' +
  'These functions contain no AppTheme; the host wraps only the active Screen in one AppTheme. Start on startScreen.\n' +
  '- Navigation is ordinary handlers changing c_screen: string. Dispatch with if/else, never eager ui.When or a list of prebuilt screens. ' +
  'A secondary screen includes one BackHandler that returns to the appropriate screen or cancels its draft. The start screen has none.\n' +
  '- A handler returns only changed fields followed by __PASSTHROUGH__ just before its closing brace: return {c_screen: "home"__PASSTHROUGH__}; ' +
  'This placeholder preserves EVERY other shared field. A helper view is pure and all screen views take the SAME AppState.\n' +
  '- Each need owns its data once. Actions on app-owned records change AppState, not records in another phone app unless explicitly requested. ' +
  'uses names that same data on another screen: a summary, detail or editor may legitimately show the same records. ' +
  'Never make a separate authoritative collection for each presentation. Use stable generated record IDs, never positions, for selection, edits and callbacks.\n' +
  '- Opening an editor copies record fields into isolated draft fields. Typing never changes a saved record. Save validates and commits a copied record/array. ' +
  'Cancel and Back discard the draft. A new editor starts fresh. Domain Save is required when requested; project persistence itself needs no Save button.\n' +
  '- New-record date drafts start at time.daysSinceEpoch() and reset to time.daysSinceEpoch() after Add/Save/reset, unless another default is explicitly requested. ' +
  'Never use 0 as an empty date or today: it means 1 Jan 1970. Editing copies the saved date unchanged, including an intentional 0. Read the clock in init or handlers, not views.\n' +
  '- Every named view must draw safely with the initial empty state or a missing/deleted selection, even when it is not the starting view: show an empty state or a return path, never index an absent record. ' +
  'Keep validation near the action and show errors only after a commit attempt. Empty user-owned collections have a way to add records.\n' +
  '- Keep immutable state: copy arrays and records before changes. Async results update shared records by stable ID, keep failure/pending states visible, ' +
  'and do not navigate away from whatever screen the person is now on. Do not invent platform calls or data.\n' +
  '- Implement the supplied needs, shared references and transitions together; do not add unrelated screens or features. ' +
  'A repair or refinement preserves the declared views and shared ownership unless the person explicitly requests a change.\n' +
  '\nScreen and BackHandler are available without discovery:\n' + describeComponents(['Screen', 'BackHandler'])

/** Same app writer for either entry point; presentation changes the shell, not state ownership. */
export function appPresentation(plan: NeedsPlan): string {
  let compact = plan.compact ? '\nThis is a compact Chat widget: no header of its own; keep each active view short. ' : ''
  if (plan.presentation !== 'tabs') { return compact + '\nUse page navigation: push only the active named Screen. Do not add Tabs.\n' }
  return compact + '\nUse one ui.Tabs for the planned peer views. Its labels follow screens order; its numeric selection handler maps the index to c_screen. ' +
    'Build a children array with the active c_view_<id>(state) at its index and ui.Column("default", []) at every inactive index. ' +
    'Only the selected Screen is constructed; never eagerly call inactive views. Keep one AppTheme and one active Screen. ' +
    'Use startScreen as the initial selected tab. Record-specific detail/editor flows should use pages, not peer tabs.\n' + describeComponents(['Tabs'])
}

/** A cheap sanity check, not semantic coverage: a generated mutation must at least have a reference. */
export function unboundAppAction(module: BytecodeModule): string {
  let references: Set<string> = new Set<string>()
  for (let fn of module.functions) {
    for (let op of fn.instructions) {
      if (op.op === 'load-function') { references.add(op.name) }
      if (op.op === 'push-string') { references.add(op.value) }
      if (op.op === 'make-closure') { references.add(op.functionName) }
    }
  }
  for (let fn of module.functions) {
    if (!fn.name.startsWith('c_') || references.has(fn.name)) { continue }
    if (fn.instructions.some((op): boolean => op.op === 'make-object' && op.classIdentity === 'local:AppState')) {
      return 'State-changing handler ' + fn.name + ' has no control or caller reference. ' +
        'If it implements a requested action, bind a reachable control to it. Do not simply remove requested functionality.'
    }
  }
  return ''
}

/** The authoritative, filtered needs, not their lossy projection onto one list and one clock. */
export function appContext(plan: NeedsPlan): string {
  let needs: Record<string, Object>[] = []
  for (let n of plan.needs) {
    let raw: Record<string, Object> = {}
    for (let key of Object.keys(n.raw)) { raw[key] = n.raw[key] }
    raw['id'] = n.id; raw['type'] = n.type; raw['uses'] = n.uses
    needs.push(raw)
  }
  let value: Record<string, Object> = {}
  for (let key of Object.keys(plan.base)) { value[key] = plan.base[key] }
  value['needs'] = needs
  value['screens'] = plan.screens
  value['startScreen'] = plan.startScreen
  value['presentation'] = plan.presentation
  value['compact'] = plan.compact
  value['transitions'] = plan.transitions
  return '\n\nAuthoritative shared app plan (uses are references, not duplicate owners):\n' + JSON.stringify(value)
}
