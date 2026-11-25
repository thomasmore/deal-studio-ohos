/** Preserve pre-edit screen identities, not just the functions a replacement happened to leave behind. */
import { CompileResult, sourceFunctionNames } from './VeraCompiler'
import { deserializeVbc2 } from './VeraInterpreter'
import { smokeRun } from './VeraSmoke'
import { describeComponents } from './VeraUiCatalog'

export function sourceScreenIds(source: string): string[] {
  if (source.trim().length === 0) { return [] }
  try {
    return sourceFunctionNames(source).filter((name: string): boolean => name.startsWith('c_view_')).map((name: string): string => name.substring(7))
  } catch (_e) {
    // Saved/server source can use syntax a newer parser understands. Introspection is best-effort, not a refinement gate.
    return []
  }
}

/** Empty for the existing single-screen path. Removal requires explicit confirmation by the person. */
export function removedAppScreens(previous: string, candidate: CompileResult): string[] {
  let ids = sourceScreenIds(previous)
  if (ids.length < 2) { return [] }
  let names = deserializeVbc2(candidate.vbc2).functions.map((fn): string => fn.name)
  return ids.filter((id: string): boolean => names.indexOf('c_view_' + id) < 0)
}

export function smokeRefinement(candidate: CompileResult, previous: string, allowedRemoved: string[] = []): string {
  let old = sourceScreenIds(previous)
  if (old.length < 2) { return smokeRun(candidate) }
  let required = old.filter((id: string): boolean => allowedRemoved.indexOf(id) < 0)
  // Newly added screens are checked too. A wholly single-screen replacement is allowed only after confirmation.
  for (let fn of deserializeVbc2(candidate.vbc2).functions) {
    if (fn.name.startsWith('c_view_') && required.indexOf(fn.name.substring(7)) < 0) { required.push(fn.name.substring(7)) }
  }
  return smokeRun(candidate, true, required)
}

export function appRefinementNote(previous: string): string {
  let ids = sourceScreenIds(previous)
  if (ids.length < 2) { return '' }
  return '\n\nThis is a shared-state multi-screen app. Existing screen functions: ' + ids.map((id: string): string => 'c_view_' + id).join(', ') +
    '. Preserve unrelated screens, stable record IDs, shared ownership, draft Save/Cancel and Back behavior. ' +
    'Do not flatten the app into a single screen. Removing screen functions requires the person to confirm it.\n' +
    describeComponents(['Screen', 'BackHandler'])
}
