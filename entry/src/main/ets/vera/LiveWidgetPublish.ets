import { formProvider } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { formBindings } from './FormBindings'
import { liveBinding } from './LiveFormService'
import { refreshForms } from './FormUpdater'

/** What publishLiveWidget answers when the card is on the home screen; anything else says what to do next. */
export const WIDGET_ADDED: string = 'Widget added to home screen'

export async function publishLiveWidget(projectId: string): Promise<string> {
  let want: Want = {
    bundleName: 'com.vera.probe.dyn', abilityName: 'VeraFormAbility',
    parameters: {
      'ohos.extra.param.key.form_name': 'live',
      'ohos.extra.param.key.module_name': 'entry',
      'ohos.extra.param.key.form_dimension': 2,
      'projectId': projectId
    }
  }
  try {
    if (!await formProvider.isRequestPublishFormSupported()) {
      formBindings.offer(projectId)
      formProvider.openFormManager(want)
      return 'Your launcher opened its widget list. Pick VERA live app: it will show this app.'
    }
    let id = await formProvider.requestPublishForm(want, liveBinding(projectId))
    formBindings.bind(id, projectId)
    await refreshForms()
    return WIDGET_ADDED
  } catch (e) {
    throw e as Error
  }
}

/** A live card placed with no app yet (WidgetBindPage) shows projectId from now on. Only our own live cards are taken. */
export async function bindLiveForm(formId: string, projectId: string): Promise<void> {
  // Do not accept arbitrary form IDs supplied as launch parameters.
  try {
    let info = await formProvider.getPublishedRunningFormInfoById(formId)
    if (info.formName !== 'live' || info.bundleName !== 'com.vera.probe.dyn') { throw new Error('Not a VERA live widget') }
    formBindings.bind(formId, projectId)
    await refreshForms()
  } catch (e) {
    throw e as Error
  }
}
