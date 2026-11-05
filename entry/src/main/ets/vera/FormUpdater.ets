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

let refreshTimer: number = -1
/** Coalesce frequent app state writes; never lose the final refresh. */
export function scheduleFormRefresh(): void {
  if (refreshTimer >= 0) { return }
  refreshTimer = setTimeout(() => {
    refreshTimer = -1
    refreshForms()
  }, 1000)
}
