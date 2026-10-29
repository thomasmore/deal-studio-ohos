import { formBindingData, formProvider } from '@kit.FormKit'
import { store } from './ProjectStore'

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

export async function refreshForms(): Promise<void> {
  try {
    let infos = await formProvider.getPublishedRunningFormInfos()
    let data = buildFormBinding()
    for (let info of infos) {
      try {
        await formProvider.updateForm(info.formId, data)
      } catch (_e) {}
    }
  } catch (_e) {}
}
