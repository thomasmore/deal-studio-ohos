import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { store, Project } from '../vera/ProjectStore'
import { buildFormBinding } from '../vera/FormUpdater'

export default class VeraFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    store.init(this.context.filesDir)
    return buildFormBinding()
  }

  onUpdateForm(formId: string): void {
    store.init(this.context.filesDir)
    try {
      formProvider.updateForm(formId, buildFormBinding())
    } catch (_e) {}
  }

  onFormEvent(formId: string, message: string): void {
    let projectId = ''
    try {
      let params = JSON.parse(message) as Record<string, Object>
      let id = params['projectId']
      if (typeof id === 'string') {
        projectId = id
      }
    } catch (_e) {}
    if (projectId.length === 0) { return }
    let want: Want = {
      bundleName: 'com.vera.probe.dyn',
      abilityName: 'EntryAbility',
      parameters: { 'projectId': projectId } as Record<string, Object>
    }
    try {
      this.context.startAbility(want)
    } catch (e) {
      console.error('VeraFormAbility startAbility failed: ' + (e as Error).message)
    }
  }
}
