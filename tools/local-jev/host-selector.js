// Host adapter for the application's shared selector boundary, not just playground comparisons.
'use strict'
const {LayaStream, localFailureMessage} = require('../vera-playground/laya-stream')
const {specification, metadata} = require('../vera-playground/local-selector')
function installLocalSelector({loadVera, stream = new LayaStream(), onEvent = () => {}}) {
  const settings = loadVera('SettingsStore').settings
  globalThis.__veraLocalJev = {
    async status() {
      try {
        await stream.warm()
        return JSON.stringify({ready:true,abi:1,productionAllowed:false,diagnostic:true,source:metadata(specification())})
      } catch (_) { return JSON.stringify({ready:false,reason:'local_model_unavailable'}) }
    },
    async experimentalDecisions(body) {
      const started = performance.now()
      let result
      try {
        result = await stream.query(body)
      } catch (error) {
        onEvent({body, error:localFailureMessage(error), ms:performance.now()-started})
        throw error
      }
      onEvent({body, request:JSON.parse(body), response:result.response, source:result.source,
        timings:result.timings, requestId:result.requestId, ms:performance.now()-started})
      return JSON.stringify(result.response)
    },
  }
  settings.setLocalSelector(true)
  return {stream, prepare:() => loadVera('LocalJev').localJev.prepare(), close() {
    settings.setLocalSelector(false)
    delete globalThis.__veraLocalJev
    stream.close()
  }}
}
module.exports = {installLocalSelector}
