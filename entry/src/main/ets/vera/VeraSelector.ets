// Shared transport boundary for generation and structural edits.
import { http } from '@kit.NetworkKit'
import { OperationCancellation, throwIfCancelled } from './OperationCancellation'
import { requestWithCancellation } from './VeraWebSearch'
import { noteService, httpFailure, SERVICE_JEV } from './ServiceHealth'
import { settings } from './SettingsStore'
import { askJevViaCloud } from './JevProxy'
import { localJev } from './LocalJev'
import { trace } from './VeraTiming'

const JEV_ENDPOINT: string = 'https://api.typesafe.ai/v1/systemone'

export async function askSelector(body: string, apiKey: string, cancellation?: OperationCancellation): Promise<string> {
  throwIfCancelled(cancellation)
  if (settings.useLocalSelector()) {
    let started = Date.now()
    let reply = await localJev.ask(body, cancellation)
    throwIfCancelled(cancellation)
    let fields: Record<string, Object> = {}
    fields['backend'] = 'local-experimental'
    fields['body'] = body
    fields['response'] = reply
    fields['source'] = localJev.identity()
    fields['ms'] = Date.now() - started
    trace('selector', fields)
    return reply
  }
  if (settings.useJevProxy()) { return askJevViaCloud(body, cancellation) }
  if (apiKey.length === 0) { return '' }
  try {
    let headers: Record<string, string> = {}
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ' + apiKey
    let response = await requestWithCancellation(JEV_ENDPOINT, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 5000,
      readTimeout: 15000
    }, cancellation)
    throwIfCancelled(cancellation)
    if ((response.responseCode as number) !== 200) {
      console.warn('VERA-JEV http ' + (response.responseCode as number).toString() + ' bytes=' + body.length.toString() + ' ' +
        String(response.result).substring(0, 300))
      noteService(SERVICE_JEV, false, httpFailure(response.responseCode as number, String(response.result)))
      return ''
    }
    noteService(SERVICE_JEV, true)
    return response.result as string
  } catch (e) {
    throwIfCancelled(cancellation)
    if ((e as Error).name === 'OperationCancelledError') { throw (e as Error) }
    console.warn('VERA-JEV failed bytes=' + body.length.toString() + ': ' + (e as Error).message)
    noteService(SERVICE_JEV, false, (e as Error).message)
    return ''
  }
}
