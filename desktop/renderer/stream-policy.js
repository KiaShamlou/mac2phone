'use strict';
// Pure, interval-based measurements. Lifetime averages hide recent congestion.
(()=>{
 const profiles={fast:{width:1280,fps:60,bitrate:4000000},balanced:{width:1920,fps:60,bitrate:8000000},sharp:{width:3840,fps:60,bitrate:24000000}};
 const ladder=[{width:640,fps:30,bitrate:1200000},{width:960,fps:60,bitrate:2500000},profiles.fast,profiles.balanced];
 function delta(current,previous,key){
  if(!previous||!Number.isFinite(current[key])||!Number.isFinite(previous[key])||current[key]<previous[key])return undefined;
  return current[key]-previous[key];
 }
 function average(current,previous,total,count){
  const n=delta(current,previous,count),sum=delta(current,previous,total);
  return n>0&&sum!==undefined?sum*1000/n:undefined;
 }
 function inbound(current,previous){
  const seconds=delta(current,previous,'timestamp')/1000,decoded=delta(current,previous,'framesDecoded'),dropped=delta(current,previous,'framesDropped');
  const lost=delta(current,previous,'packetsLost'),received=delta(current,previous,'packetsReceived');
  return {
   fps:current.framesPerSecond??(seconds>0&&decoded!==undefined?decoded/seconds:undefined),
   mbps:seconds>0?delta(current,previous,'bytesReceived')*8/seconds/1e6:undefined,
   decodeMs:average(current,previous,'totalDecodeTime','framesDecoded'),
   bufferMs:average(current,previous,'jitterBufferDelay','jitterBufferEmittedCount'),
   dropPercent:decoded+dropped>0?100*dropped/(decoded+dropped):undefined,
   lossPercent:lost+received>0?100*lost/(lost+received):undefined,
   frames:decoded===undefined?undefined:decoded+(dropped||0)
  };
 }
 function outbound(current,previous){
  const seconds=delta(current,previous,'timestamp')/1000,frames=delta(current,previous,'framesEncoded');
  return {
   fps:current.framesPerSecond??(seconds>0&&frames!==undefined?frames/seconds:undefined),
   encodeMs:average(current,previous,'totalEncodeTime','framesEncoded'),
   sendDelayMs:average(current,previous,'totalPacketSendDelay','packetsSent'),
   frames,reason:current.qualityLimitationReason||'unknown'
  };
 }
 function pressure(sender,receiver){
  if(sender.reason==='cpu'||sender.encodeMs>22)return 'cpu';
  if(sender.reason==='bandwidth'||sender.sendDelayMs>35)return 'bandwidth';
  if(receiver?.frames>=10&&(receiver.decodeMs>18||receiver.bufferMs>60||receiver.dropPercent>8||receiver.lossPercent>3))return 'receiver';
  return 'none';
 }
 class Adaptive {
  constructor(){this.level=2;this.bad=0;this.good=0;}
  get profile(){return ladder[this.level];}
  sample(value,receiver){
   // Static screens and missing statistics must not trigger quality reduction.
   if(!(value.frames>=10)){this.good=0;this.bad=0;return false;}
   const overloaded=pressure(value,receiver)!=='none';
   this.bad=overloaded?this.bad+1:0;
   const receiverHealthy=!receiver||receiver.frames>=10&&receiver.decodeMs<10&&receiver.bufferMs<30&&receiver.dropPercent<2&&receiver.lossPercent<1;
   this.good=!overloaded&&receiverHealthy&&value.reason==='none'&&value.encodeMs<12&&value.sendDelayMs<10?this.good+1:0;
   if(this.bad>=2&&this.level>0){this.level--;this.bad=0;this.good=0;return true;}
   if(this.good>=6&&this.level<ladder.length-1){this.level++;this.good=0;this.bad=0;return true;}
   return false;
  }
 }
 class StallWatch {
  constructor(){this.previous=null;this.blockedMs=0;}
  sample(current,{visible=true,sender}={}){
   const previous=this.previous;this.previous=current;
   const elapsed=delta(current,previous,'timestamp'),decoded=delta(current,previous,'framesDecoded'),bytes=delta(current,previous,'bytesReceived');
   // A still desktop, hidden window, suspended timer or reset counter is not
   // evidence of a failed decoder. Require ongoing media activity.
   if(!visible||!Number.isFinite(elapsed)||elapsed<=0||elapsed>4000||decoded!==0){this.blockedMs=0;return false;}
   const active=bytes>1024||sender?.fps>=5;
   this.blockedMs=active?this.blockedMs+elapsed:0;
   return this.blockedMs>=3000;
  }
 }
 class RetryBudget {
  constructor(){this.times=[];}
  next(now=Date.now()){
   this.times=this.times.filter(time=>now-time<60000);
   if(this.times.length>=2)return undefined;
   this.times.push(now);return 600*this.times.length;
  }
 }
 const policy={profiles,delta,average,inbound,outbound,pressure,Adaptive,StallWatch,RetryBudget};
 if(typeof module!=='undefined')module.exports=policy;else window.M2PStreamPolicy=policy;
})();
