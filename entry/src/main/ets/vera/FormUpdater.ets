import { formBindingData, formProvider } from '@kit.FormKit'
import { store } from './ProjectStore'
import { formBindings } from './FormBindings'
import { liveBinding } from './LiveFormService'

export function buildFormBinding(): formBindingData.FormBindingData {
  let projects = store.listProjects()
  let arr: Record<string, string>[] = []
  for (let p of projects) {
    let item: Record<string, string> = {}
    item['id'] = p.id
    item['name'] = p.name
    item['icon'] = p.icon
    arr.push(item)
  }
  let obj: Record<string, Object> = {}
  obj['count'] = arr.length
  obj['hasProjects'] = arr.length > 0
  obj['projects'] = arr
  return formBindingData.createFormBindingData(obj)
}

export async function refreshForms(excludeFormId: string = ''): Promise<void> {
  try {
    let infos = await formProvider.getPublishedRunningFormInfos()
    let data = buildFormBinding()
    for (let info of infos) {
      if (info.formId === excludeFormId) { continue }
      try {
        if (info.formName !== 'widget' && info.formName !== 'live') { continue }
        await formProvider.updateForm(info.formId, info.formName === 'live' ?
          liveBinding(formBindings.projectFor(info.formId), info.formId) : data)
      } catch (e) { console.warn('VERA-FORM refresh: ' + (e as Error).message) }
    }
  } catch (e) { console.warn('VERA-FORM list: ' + (e as Error).message) }
}

/** Redraws this project's own live cards (and no other card) from its saved state; `excludeFormId` is already drawn. */
export async function refreshProjectCards(projectId: string, excludeFormId: string = ''): Promise<void> {
  for (let formId of formBindings.formsFor(projectId)) {
    if (formId === excludeFormId) { continue }
    try {
      await formProvider.updateForm(formId, liveBinding(projectId, formId))
    } catch (e) { console.warn('VERA-FORM refresh ' + formId + ': ' + (e as Error).message) }
  }
}

/** How often a running app's saves may redraw its cards: a ticker saves every second, a card needs nothing like that. */
export const CARD_REFRESH_MS: number = 5000

let refreshTimer: number = -1
let pendingProjects: Set<string> = new Set<string>()
/**
 * A running app saved its state: its cards are redrawn, at most once per CARD_REFRESH_MS, and only when it has any. The
 * last save in a burst is never lost. A project with no card costs one read of the bindings and nothing else.
 */
export function scheduleCardRefresh(projectId: string): void {
  if (projectId.length === 0 || formBindings.formsFor(projectId).length === 0) { return }
  pendingProjects.add(projectId)
  if (refreshTimer >= 0) { return }
  refreshTimer = setTimeout(() => {
    refreshTimer = -1
    let projects = Array.from(pendingProjects)
    pendingProjects.clear()
    for (let id of projects) { refreshProjectCards(id) }
  }, CARD_REFRESH_MS)
}
