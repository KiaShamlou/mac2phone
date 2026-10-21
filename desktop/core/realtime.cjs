'use strict';
const CAPABILITY='webrtc-video-v1';
const qualities=new Set(['fast','balanced','sharp']);
const net=require('node:net');
// Chromium masks host candidates with ephemeral .local names. Resolve only
// those host candidates to the peer address of this authenticated TLS socket.
// No subnet scan, public STUN, DNS lookup or unauthenticated address is used.
function peerSignal(value,address){
 if(address?.startsWith('::ffff:'))address=address.slice(7);
 if(!net.isIP(address))return value;
 function candidate(line){
  const fields=line.split(' ');
  if(/^(?:a=)?candidate:/.test(fields[0])&&fields[6]==='typ'&&fields[7]==='host'&&/\.local\.?$/i.test(fields[4]))fields[4]=address;
  return fields.join(' ');
 }
 if(value.type==='candidate'&&value.candidate)return {...value,candidate:{...value.candidate,candidate:candidate(value.candidate.candidate)}};
 if(value.type==='offer'||value.type==='answer')return {...value,sdp:value.sdp.split('\r\n').map(candidate).join('\r\n')};
 return value;
}
// SDP fingerprints and ICE candidates travel only inside the approved TLS
// session. Media uses WebRTC's DTLS-SRTP, never custom encryption or public ICE.
function validSignal(value,from){
 if(!value||typeof value!=='object'||Array.isArray(value)||!['host','viewer'].includes(from))return false;
 try{if(Buffer.byteLength(JSON.stringify(value))>65536)return false;}catch{return false;}
 switch(value.type){
  case 'start':case 'quality':return from==='viewer'&&qualities.has(value.quality)&&
   (value.adaptive===undefined||typeof value.adaptive==='boolean')&&(value.telemetry===undefined||typeof value.telemetry==='boolean')&&
   (value.feedback===undefined||typeof value.feedback==='boolean')&&(value.fps===undefined||[30,60].includes(value.fps));
  case 'feedback':{
   if(from!=='viewer'||!Number.isFinite(value.frames)||value.frames<0||value.frames>1000)return false;
   const bounds={decodeMs:60000,bufferMs:60000,dropPercent:100,lossPercent:100};
   return Object.entries(bounds).every(([key,max])=>value[key]===undefined||Number.isFinite(value[key])&&value[key]>=0&&value[key]<=max);
  }
  case 'telemetry':{
   if(from!=='host'||!['none','cpu','bandwidth','other','unknown'].includes(value.reason))return false;
   const bounds={fps:240,encodeMs:60000,sendDelayMs:60000,width:16384,height:16384,targetWidth:16384,bitrate:100000000,sourceFPS:240,targetFPS:60};
   return Object.entries(bounds).every(([key,max])=>value[key]===undefined||Number.isFinite(value[key])&&value[key]>=0&&value[key]<=max)&&
    (value.encoder===undefined||typeof value.encoder==='string'&&value.encoder.length<=100)&&
    (value.adaptive===undefined||typeof value.adaptive==='boolean')&&
    (value.pressure===undefined||['none','cpu','bandwidth','receiver'].includes(value.pressure));
  }
  case 'active':return from==='viewer';
  case 'fallback':return true;
  case 'offer':case 'answer':return value.type===(from==='host'?'offer':'answer')&&typeof value.sdp==='string'&&value.sdp.startsWith('v=0')&&value.sdp.length<=60000;
  case 'candidate':{
   const c=value.candidate;if(c===null)return true;
   return !!c&&typeof c==='object'&&typeof c.candidate==='string'&&c.candidate.length<=2048&&
    (c.sdpMid===null||typeof c.sdpMid==='string'&&c.sdpMid.length<=32)&&
    (c.sdpMLineIndex===null||Number.isInteger(c.sdpMLineIndex)&&c.sdpMLineIndex>=0&&c.sdpMLineIndex<=8);
  }
  default:return false;
 }
}
module.exports={CAPABILITY,validSignal,peerSignal};
