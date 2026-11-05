import { formProvider } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { formBindings } from './FormBindings'
import { liveBinding } from './LiveFormService'
import { refreshForms } from './FormUpdater'

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
  if (!await formProvider.isRequestPublishFormSupported()) {
    formBindings.offer(projectId)
    formProvider.openFormManager(want)
    return 'Add VERA live app: it will show this project.'
  }
  let id = await formProvider.requestPublishForm(want, liveBinding(projectId))
  formBindings.bind(id, projectId)
  await refreshForms()
  return 'Widget added to home screen'
}
