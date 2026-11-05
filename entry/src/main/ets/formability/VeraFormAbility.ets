import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { store } from '../vera/ProjectStore'
import { buildFormBinding, refreshForms } from '../vera/FormUpdater'
import { formBindings, refreshLedger } from '../vera/FormBindings'
import { liveBinding, liveFormTap, liveFormRefresh, LiveRefresh } from '../vera/LiveFormService'

export default class VeraFormAbility extends FormExtensionAbility {
  private init(): void {
    store.init(this.context.filesDir)
    formBindings.init(this.context.filesDir)
    refreshLedger.init(this.context.filesDir)
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    this.init()
    let params = want.parameters as Record<string, Object>
    if (params !== null && params !== undefined && params['ohos.extra.param.key.form_name'] === 'live') {
      let id = params['ohos.extra.param.key.form_identity']
      // requestPublishForm passes the project; a card placed in the system widget manager takes the one Add widget offered.
      let passed = params['projectId']
      let projectId = typeof passed === 'string' && passed.length > 0 ? passed : formBindings.takeOffer()
      if (typeof id === 'string' && typeof projectId === 'string' && store.getProject(projectId) !== null) {
        formBindings.bind(id, projectId)
      }
      return liveBinding(typeof id === 'string' ? formBindings.projectFor(id) : '', typeof id === 'string' ? id : '')
    }
    return buildFormBinding()
  }

  async onUpdateForm(formId: string): Promise<void> {
    this.init()
    try {
      let info = await formProvider.getPublishedRunningFormInfoById(formId)
      if (info.formName !== 'live') {
        await formProvider.updateForm(formId, buildFormBinding())
        return
      }
      // The periodic update: the program's widgetRefresh, if it has one, brings the state up to date with the clock.
      let refreshed: LiveRefresh = liveFormRefresh(formId)
      await formProvider.updateForm(formId, refreshed.binding)
      if (refreshed.ran) { await refreshForms(formId) }
    } catch (e) { console.warn('VERA-FORM update: ' + (e as Error).message) }
  }

  onCastToNormalForm(formId: string): void { this.onUpdateForm(formId) }

  onRemoveForm(formId: string): void {
    this.init()
    formBindings.unbind(formId)
  }

  async onFormEvent(formId: string, message: string): Promise<void> {
    this.init()
    if (formBindings.projectFor(formId).length === 0) { return }
    try {
      await formProvider.updateForm(formId, liveFormTap(formId, message))
      await refreshForms(formId)
    } catch (e) { console.error('VERA-FORM event: ' + (e as Error).message) }
  }
}
