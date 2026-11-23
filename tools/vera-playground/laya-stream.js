// One serialized Rust stream for the playground server or standalone harness.
'use strict'
const cp=require('node:child_process'),readline=require('node:readline'),crypto=require('node:crypto')
const {specification,metadata,diagnosticDecisions}=require('./local-selector')
const localFailureMessage = error => /^(Local model unavailable|Laya (process (failed|exited)|startup (failed|timed out)|stream (write failed|closed)|inference timed out|response identity mismatch|call cancelled|frame too large|request too large)|Invalid Laya frame)$/.test(error.message)
  ? error.message : 'Selector transport or response failure'
function localOperationalReason(response) {
  const {status, reason} = response?.local || {}
  if (status === 'uncertain' && reason && !['uncalibrated_model','laya_not_human_calibrated','option_token_budget','head_token_budget','state_token_budget','call_token_budget','option_tokens_collapsed'].includes(reason)) return reason
  return ''
}
class LayaStream {
  constructor(){this.timeoutMs=30000;this.state=null;this.queue=Promise.resolve();this.closed=false}
  start(){
    const spec=specification()
    if(!spec.available)throw Error('Local model unavailable')
    let source
    try { source=metadata(spec) } catch (_) { throw Error('Local model unavailable') }
    const started=performance.now()
    const child=cp.spawn(spec.cli,spec.args,{env:{},stdio:['pipe','pipe','pipe']})
    // The public base model can take more than 30 seconds on a wide request.
    const inferenceTimeoutMs = source.model === 'jhu-clsp/mmBERT-base' ? 120000 : this.timeoutMs
    const state={child,source,inferenceTimeoutMs,pending:null,started,readyDone:false,failed:false,bytes:0}
    state.exited=new Promise(resolve=>child.once('close',resolve))
    state.ready=new Promise((resolve,reject)=>{state.readyResolve=resolve;state.readyReject=reject})
    this.state=state
    const fail=message=>this.fail(state,message)
    state.timer=setTimeout(()=>fail('Laya startup timed out'),this.timeoutMs)
    child.on('error',()=>fail('Laya process failed'));child.on('exit',()=>fail('Laya process exited'))
    child.stdin.on('error',()=>fail('Laya stream write failed'));child.stderr.resume()
    child.stdout.setEncoding('utf8')
    child.stdout.on('data',chunk=>{state.bytes+=Buffer.byteLength(chunk);if(state.bytes>2*1024*1024)fail('Laya frame too large');if(chunk.includes('\n'))state.bytes=Buffer.byteLength(chunk.slice(chunk.lastIndexOf('\n')+1))})
    state.lines=readline.createInterface({input:child.stdout,crlfDelay:Infinity})
    state.lines.on('line',line=>{
      if(state.failed)return
      let frame
      try{frame=JSON.parse(line)}catch(_){return fail('Invalid Laya frame')}
      if(!frame||typeof frame!=='object')return fail('Invalid Laya frame')
      if(!state.readyDone){
        if(frame.kind!=='ready'||frame.protocol!==1||frame.ready!==true||!Number.isFinite(frame.startup_ms))return fail('Laya startup failed')
        state.readyDone=true;state.coldStartMs=performance.now()-state.started;state.modelStartupMs=frame.startup_ms
        clearTimeout(state.timer);state.readyResolve();return
      }
      const pending=state.pending
      if(!pending||frame.kind!=='result'||frame.id!==pending.id||!frame.response||!Number.isFinite(frame.inference_ms))return fail('Laya response identity mismatch')
      state.pending=null;clearTimeout(pending.timer)
      pending.resolve({response:frame.response,source:state.source,timings:{pid:state.child.pid,cold:pending.cold,coldStartMs:state.coldStartMs,
        modelStartupMs:state.modelStartupMs,warmInferenceMs:frame.inference_ms,roundtripMs:performance.now()-pending.sent,
        queueMs:pending.sent-pending.entered},requestId:frame.id})
    })
    return state
  }
  fail(state,message){
    if(state.failed)return
    state.failed=true;clearTimeout(state.timer);state.lines?.close()
    const error=Error(message)
    state.readyReject(error)
    if(state.pending){clearTimeout(state.pending.timer);state.pending.reject(error);state.pending=null}
    state.child.kill('SIGTERM')
    if(this.state===state){this.retiring=state.exited;this.state=null}
  }
  async warm(){
    await this.retiring
    if(this.closed)throw Error('Laya stream closed')
    return (this.state||this.start()).ready
  }
  query(body,signal){
    const entered=performance.now()
    const run=async()=>{
      await this.retiring
      if(this.closed||signal?.aborted)throw Error('Laya call cancelled')
      if(Buffer.byteLength(body)>262144)throw Error('Laya request too large')
      const request=JSON.parse(body),state=this.state||this.start(),cold=!state.readyDone
      const abort=()=>this.fail(state,'Laya call cancelled')
      signal?.addEventListener('abort',abort,{once:true})
      try{
        await state.ready
        if(signal?.aborted)throw Error('Laya call cancelled')
        const result = await new Promise((resolve,reject)=>{
          const id=crypto.randomUUID(),sent=performance.now()
          const timer=setTimeout(()=>this.fail(state,'Laya inference timed out'),state.inferenceTimeoutMs)
          state.pending={id,resolve,reject,timer,sent,entered,cold}
          state.child.stdin.write(`{"id":${JSON.stringify(id)},"request":${body.replace(/[\r\n]/g,' ')}}\n`)
        })
        result.response=diagnosticDecisions(result.response,request)
        result.timings.totalMs=performance.now()-entered
        return result
      }finally{signal?.removeEventListener('abort',abort)}
    }
    const result=this.queue.then(run,run)
    this.queue=result.catch(()=>{})
    return result
  }
  close(){this.closed=true;if(this.state)this.fail(this.state,'Laya stream closed')}
}
module.exports={LayaStream,localFailureMessage,localOperationalReason}
