'use strict';
(()=>{
 const numeric=['fps','mbps','rtt','width','height','decodeMs','bufferMs','dropPercent','lossPercent'];
 const senderNumeric=['fps','encodeMs','sendDelayMs','width','height','targetWidth','targetFPS','bitrate','sourceFPS'];
 const number=value=>Number.isFinite(value)&&value>=0&&value<=1e9?Math.round(value*100)/100:null;
 const version=value=>typeof value==='string'&&/^\d{1,4}\.\d{1,4}\.\d{1,4}$/.test(value)?value:'unknown';
 function sample(value={}){
  if(!value||typeof value!=='object')value={};
  const result=Object.fromEntries(numeric.map(key=>[key,number(value[key])]));
  result.codec=['H264','VP8','VP9','AV1'].includes(value.codec)?value.codec:'unknown';
  if(value.sender){
   result.sender=Object.fromEntries(senderNumeric.map(key=>[key,number(value.sender[key])]));
   result.sender.reason=['none','cpu','bandwidth','other','unknown'].includes(value.sender.reason)?value.sender.reason:'unknown';
   result.sender.pressure=['none','cpu','bandwidth','receiver'].includes(value.sender.pressure)?value.sender.pressure:'unknown';
   result.sender.adaptive=value.sender.adaptive===true;
  }
  return result;
 }
 function report(value={}){
  if(!value||typeof value!=='object')value={};
  return {application:'Mac2Phone',schema:1,clientVersion:version(value.clientVersion),hostVersion:version(value.hostVersion),
   hostPlatform:['darwin','macos','win32','linux'].includes(value.hostPlatform)?value.hostPlatform:'unknown',
   transport:value.transport==='webrtc'?'webrtc':'compatibility',
   quality:['auto','fast','balanced','sharp'].includes(value.quality)?value.quality:'unknown',
   requestedFPS:value.requestedFPS===30?30:60,sound:value.sound===true,recoveryAttempts:number(value.recoveryAttempts),
   samples:Array.isArray(value.samples)?value.samples.slice(-60).map(sample):[]};
 }
 function health(value){
  if(value.sender?.pressure==='cpu'||value.sender?.reason==='cpu')return {state:'pressure',label:'Sender under load'};
  if(value.sender?.pressure==='bandwidth'||value.sender?.reason==='bandwidth')return {state:'pressure',label:'Network under load'};
  if(value.sender?.pressure==='receiver'||value.bufferMs>60||value.decodeMs>18||value.dropPercent>8||value.lossPercent>3)return {state:'pressure',label:'Viewer catching up'};
  return {state:'live',label:'Live'};
 }
 const value={sample,report,health};
 if(typeof module!=='undefined')module.exports=value;else window.M2PDiagnostics=value;
})();
