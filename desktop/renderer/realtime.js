'use strict';
(()=>{
 const policy=window.M2PStreamPolicy,profiles=policy.profiles;
 const config={iceServers:[],bundlePolicy:'max-bundle',rtcpMuxPolicy:'require'};
 const candidate=value=>({type:'candidate',candidate:value?.toJSON()??null});
 async function remote(pc,description,pending){await pc.setRemoteDescription(description);for(const c of pending.splice(0))await pc.addIceCandidate(c);}
 class Senders {
  constructor({getStream,send,demand=()=>{}}){this.getStream=getStream;this.send=send;this.demand=demand;this.peers=new Map();}
  profile(peer){const value=peer.adaptive?peer.auto.profile:profiles[peer.quality]||profiles.balanced;return {...value,fps:Math.min(value.fps,peer.fps||60)};}
  changed(){this.demand([...this.peers.values()].map(peer=>this.profile(peer)));}
  captureChanged(){
   for(const [id,peer] of this.peers){
    peer.queue=peer.queue.then(async()=>{if(this.peers.get(id)===peer)await this.quality(peer);}).catch(()=>this.fail(id,peer));
   }
  }
  handle(id,signal){
   if(signal.type==='fallback'){this.close(id);return;}
   let peer=this.peers.get(id);
   if(signal.type==='feedback'){
    if(peer?.feedback){peer.receiverStats=signal;peer.receiverAt=Date.now();}
    return;
   }
   if(signal.type==='start'){
    this.close(id);const track=this.getStream()?.getVideoTracks()[0];
    if(!track||track.readyState!=='live'){this.send(id,{type:'fallback'});return;}
    const pc=new RTCPeerConnection(config);peer={pc,quality:signal.quality,fps:signal.fps||60,feedback:signal.feedback===true,adaptive:signal.adaptive===true,telemetry:signal.telemetry===true,auto:new policy.Adaptive(),pending:[],queue:Promise.resolve()};this.peers.set(id,peer);
    const initial=this.profile(peer),settings=track.getSettings();
    peer.sender=pc.addTransceiver(track,{direction:'sendonly',streams:[new MediaStream([track])],sendEncodings:[{
     maxBitrate:initial.bitrate,maxFramerate:initial.fps,scaleResolutionDownBy:Math.max(1,Math.max(settings.width||1920,settings.height||1080)/initial.width)
    }]}).sender;
    // Prefer H.264 where supported, while retaining browser-negotiated codecs.
    const transceiver=pc.getTransceivers()[0],codecs=RTCRtpSender.getCapabilities('video')?.codecs||[];
    if(transceiver.setCodecPreferences&&codecs.length)transceiver.setCodecPreferences([...codecs.filter(c=>c.mimeType==='video/H264'),...codecs.filter(c=>c.mimeType!=='video/H264')]);
    pc.onicecandidate=event=>{if(this.peers.get(id)===peer)this.send(id,candidate(event.candidate));};
    pc.onconnectionstatechange=()=>{
     if(pc.connectionState==='connected'){
      clearTimeout(peer.timeout);
      if(!peer.statsTimer)peer.statsTimer=setInterval(()=>this.measure(id,peer).catch(()=>{}),2000);
     }
     if(pc.connectionState==='failed')this.fail(id,peer);
    };
    peer.timeout=setTimeout(()=>this.fail(id,peer),10000);
    this.changed();
   }
   if(!peer)return;
   peer.queue=peer.queue.then(async()=>{
    if(this.peers.get(id)!==peer)return;
    const pc=peer.pc;
    if(signal.type==='start'){
     await pc.setLocalDescription(await pc.createOffer());
     if(this.peers.get(id)===peer)this.send(id,{type:'offer',sdp:pc.localDescription.sdp});
    }else if(signal.type==='answer'){await remote(pc,{type:'answer',sdp:signal.sdp},peer.pending);await this.quality(peer);}
    else if(signal.type==='candidate'){if(pc.remoteDescription)await pc.addIceCandidate(signal.candidate);else if(peer.pending.length<64)peer.pending.push(signal.candidate);else throw Error('Too many ICE candidates');}
    else if(signal.type==='quality'){peer.quality=signal.quality;peer.fps=signal.fps||60;peer.adaptive=signal.adaptive===true;peer.auto=new policy.Adaptive();await this.quality(peer);this.changed();}
   }).catch(error=>{this.lastFailure=error.name+': '+error.message;this.fail(id,peer);});
  }
  async quality(peer){
   const profile=this.profile(peer),parameters=peer.sender.getParameters();
   if(!parameters.encodings?.length)return;
   const settings=peer.sender.track.getSettings(),width=Math.max(settings.width||1920,settings.height||1080);
   for(const encoding of parameters.encodings){encoding.maxBitrate=profile.bitrate;encoding.maxFramerate=profile.fps;encoding.scaleResolutionDownBy=Math.max(1,width/profile.width);}
   // Remote interaction favors current frames over preserving pixels at 5 fps.
   parameters.degradationPreference=!peer.adaptive&&peer.quality==='sharp'?'maintain-resolution':'maintain-framerate';
   await peer.sender.setParameters(parameters);
  }
  async measure(id,peer){
   if(peer.measuring||this.peers.get(id)!==peer)return;
   peer.measuring=true;
   try{
    const report=await peer.pc.getStats();if(this.peers.get(id)!==peer)return;
    for(const stat of report.values())if(stat.type==='outbound-rtp'&&stat.kind==='video'&&!stat.isRemote){
     const value=policy.outbound(stat,peer.previous);peer.previous=stat;
     // Serialize adaptation with user quality changes and SDP operations.
     peer.queue=peer.queue.then(async()=>{
      if(this.peers.get(id)!==peer)return;
      const receiver=peer.receiverAt&&Date.now()-peer.receiverAt<=3000?peer.receiverStats:undefined;
      if(peer.adaptive&&peer.auto.sample(value,receiver)){await this.quality(peer);this.changed();}
      if(peer.telemetry){
       const profile=this.profile(peer),source=report.get(stat.mediaSourceId);
       const telemetry={type:'telemetry',reason:value.reason,pressure:policy.pressure(value,receiver),adaptive:peer.adaptive,targetWidth:profile.width,targetFPS:profile.fps,bitrate:profile.bitrate};
       for(const [key,n] of Object.entries({fps:value.fps,encodeMs:value.encodeMs,sendDelayMs:value.sendDelayMs,width:stat.frameWidth,height:stat.frameHeight,sourceFPS:source?.framesPerSecond}))
        if(Number.isFinite(n)&&n>=0)telemetry[key]=n;
       if(typeof stat.encoderImplementation==='string')telemetry.encoder=stat.encoderImplementation.slice(0,100);
       this.send(id,telemetry);
      }
     }).catch(error=>{this.lastFailure=error.name+': '+error.message;this.fail(id,peer);});
    }
   }finally{peer.measuring=false;}
  }
  fail(id,peer){if(this.peers.get(id)!==peer)return;this.send(id,{type:'fallback'});this.close(id);}
  close(id){const peer=this.peers.get(id);if(!peer)return;this.peers.delete(id);clearTimeout(peer.timeout);clearInterval(peer.statsTimer);peer.pc.close();this.changed();}
  stop(){for(const id of this.peers.keys())this.close(id);}
 }
 class Receiver {
  constructor({video,send,display,stats}){Object.assign(this,{video,send,display,stats});this.active=false;}
  start(quality='auto',{telemetry=false,feedback=false,fps=60}={}){
   this.stop();this.quality=quality;this.telemetry=telemetry;this.feedback=feedback;this.fps=fps;
   this.recovery=new policy.RetryBudget();this.recoveryAttempts=0;this.hadVideo=false;this.lastFailure=null;this.open();
  }
  open(){
   this.closeConnection();this.pending=[];this.queue=Promise.resolve();this.stall=new policy.StallWatch();
   const pc=this.pc=new RTCPeerConnection(config);
   pc.onicecandidate=event=>{if(this.pc===pc)this.send(candidate(event.candidate));};
   pc.ontrack=event=>{
    if(this.pc!==pc)return;
    // This is a best-effort browser target, not a promise of zero latency.
    try{if('jitterBufferTarget' in event.receiver)event.receiver.jitterBufferTarget=0;}catch{}
    this.video.srcObject=event.streams[0]||new MediaStream([event.track]);
    this.video.hidden=false;
    const ready=()=>{
     if(this.pc!==pc||this.active||!this.video.videoWidth)return;
     this.active=true;this.hadVideo=true;this.recovering=false;clearTimeout(this.timeout);this.send({type:'active'});this.display(true);
     this.statsTimer=setInterval(()=>this.measure(pc).catch(()=>{}),1000);
    };
    if(this.video.requestVideoFrameCallback)this.frame=this.video.requestVideoFrameCallback(ready);else this.video.onloadeddata=ready;
    this.video.play().catch(()=>this.fail(pc));
   };
   pc.onconnectionstatechange=()=>{
    if(this.pc!==pc)return;
    if(pc.connectionState==='failed')this.fail(pc);
    if(pc.connectionState==='disconnected')this.disconnected=setTimeout(()=>{if(pc.connectionState==='disconnected')this.fail(pc);},3000);
    else clearTimeout(this.disconnected);
   };
   this.timeout=setTimeout(()=>this.fail(pc),12000);this.send({type:'start',quality:this.quality==='auto'?'balanced':this.quality,adaptive:this.quality==='auto',...(this.telemetry?{telemetry:true}:{}),...(this.feedback?{feedback:true,fps:this.fps}:{})});
  }
  handle(signal){
   if(signal.type==='telemetry'){if(this.pc){this.senderStats=signal;this.senderAt=Date.now();}return;}
   if(signal.type==='fallback'){if(this.pc)this.fail(this.pc,'sender',false);return;}
   const pc=this.pc;if(!pc)return;
   this.queue=this.queue.then(async()=>{
    if(this.pc!==pc)return;
    if(signal.type==='offer'){
     await remote(pc,{type:'offer',sdp:signal.sdp},this.pending);
     await pc.setLocalDescription(await pc.createAnswer());
     if(this.pc===pc)this.send({type:'answer',sdp:pc.localDescription.sdp});
    }else if(signal.type==='candidate'){if(pc.remoteDescription)await pc.addIceCandidate(signal.candidate);else if(this.pending.length<64)this.pending.push(signal.candidate);else throw Error('Too many ICE candidates');}
   }).catch(error=>{this.lastFailure=error.name+': '+error.message;this.fail(pc);});
  }
  setQuality(quality,fps=this.fps){this.quality=quality;this.fps=fps;if(this.pc)this.send({type:'quality',quality:quality==='auto'?'balanced':quality,adaptive:quality==='auto',...(this.feedback?{fps}:{})});}
  async measure(pc){
   if(this.measuring===pc)return;this.measuring=pc;
   try{
   const report=await pc.getStats();if(this.pc!==pc)return;
   for(const stat of report.values())if(stat.type==='inbound-rtp'&&stat.kind==='video'){
    const measured=policy.inbound(stat,this.previous);
    const codec=report.get(stat.codecId)?.mimeType?.replace('video/','')||'video';
    let rtt;for(const pair of report.values())if(pair.type==='candidate-pair'&&pair.nominated&&pair.state==='succeeded')rtt=pair.currentRoundTripTime*1000;
    const sender=Date.now()-this.senderAt<=6000?this.senderStats:undefined;
    this.previous=stat;this.stats({...measured,codec,width:stat.frameWidth||this.video.videoWidth,height:stat.frameHeight||this.video.videoHeight,rtt,sender,telemetrySupported:this.telemetry,recoveryAttempts:this.recoveryAttempts});
    if(this.stall.sample(stat,{sender:Date.now()-this.senderAt<=3000?sender:undefined,visible:typeof document==='undefined'||!document.hidden})){this.fail(pc,'stalled');return;}
    if(this.feedback&&this.active&&Number.isFinite(measured.frames)){
     const feedback={type:'feedback',frames:Math.min(1000,Math.max(0,measured.frames))};
     for(const key of ['decodeMs','bufferMs','dropPercent','lossPercent'])if(Number.isFinite(measured[key]))feedback[key]=Math.min(key.endsWith('Percent')?100:60000,Math.max(0,measured[key]));
     this.send(feedback);
    }
   }
   }finally{if(this.measuring===pc)this.measuring=null;}
  }
  fail(pc,reason='connection',notify=true){
   if(this.pc!==pc)return;
   if(notify)this.send({type:'fallback'});
   this.closeConnection();
   const delay=this.hadVideo?this.recovery.next():undefined;
   if(delay!==undefined){
    this.recoveryAttempts++;this.recovering=true;
    this.display(false,reason==='stalled'?'Video paused · recovering realtime…':'Connection interrupted · recovering realtime…',{recovering:true});
    this.retryTimer=setTimeout(()=>{this.retryTimer=null;this.open();},delay);
   }else{
    this.recovering=false;this.display(false,'Compatibility video · retry realtime when ready');
   }
  }
  stop(){
   clearTimeout(this.retryTimer);this.retryTimer=null;this.recovering=false;this.closeConnection();
  }
  closeConnection(){
   clearTimeout(this.timeout);clearTimeout(this.disconnected);clearInterval(this.statsTimer);
   if(this.frame!==undefined)this.video.cancelVideoFrameCallback?.(this.frame);
   const pc=this.pc;this.pc=null;pc?.close();this.active=false;this.previous=null;this.senderStats=null;this.senderAt=0;
   this.video.pause();this.video.srcObject=null;this.video.onloadeddata=null;
  }
 }
 window.M2PRealtime={Senders,Receiver,profiles};
})();
