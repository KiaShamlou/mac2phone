'use strict';
const api=window.mac2phone;
const $=id=>document.getElementById(id);
const canvas=$('screen'),ctx=canvas.getContext('2d',{alpha:false});
let connected=false,controlling=false,button=null,generation=0,controlRevision=0;
let audioContext=null,format=null,audioAt=0,sources=new Set();
let pendingMove=null,moveFrame=null;
let fullscreen=false,hudTimer,jpegFrames=0,jpegSince=performance.now();
let sessionCaps={},samples=[],copyTimer;
let viewerPreferences={quality:'auto',fps:60,autoFullscreen:true},localPreferencePatch={},preferenceRevision=0;
function showPreferences(){
 $('video-quality').value=viewerPreferences.quality;$('video-fps').value=String(viewerPreferences.fps);
 $('auto-fullscreen').checked=viewerPreferences.autoFullscreen;
}
const preferencesReady=api?.preferences?api.preferences().then(value=>{
 if(!value)return;viewerPreferences={...value,...localPreferencePatch};
 $('auto-fullscreen').checked=viewerPreferences.autoFullscreen;
 if(!connected)showPreferences();
}).catch(()=>{$('preferences-status').textContent='Preferences did not load. Current session settings still work.';}):Promise.resolve();
async function rememberPreferences(patch){
 const own=++preferenceRevision;localPreferencePatch={...localPreferencePatch,...patch};viewerPreferences={...viewerPreferences,...patch};
 if(!api?.savePreferences)return;
 try{
  const result=await api.savePreferences(patch);if(own!==preferenceRevision)return;
  $('preferences-status').textContent=result.ok?'Preferences saved on this computer. Control and Sound remain session-only.':'Preferences not saved. Current settings still apply until you quit.';
 }catch{if(own===preferenceRevision)$('preferences-status').textContent='Preferences not saved. Current settings still apply until you quit.';}
}
$('auto-fullscreen').onchange=()=>rememberPreferences({autoFullscreen:$('auto-fullscreen').checked});
const remoteVideo=$('remote-video');
const realtime=new M2PRealtime.Receiver({video:remoteVideo,send:value=>api.realtime(value).catch(()=>{}),
 display:(active,message,{recovering=false}={})=>{
  canvas.classList.toggle('realtime',active);remoteVideo.hidden=!active;
  $('video-quality').disabled=!active;
  $('video-fps').disabled=!active||sessionCaps.realtimeFeedback!==1;
  $('retry-video').hidden=active||recovering||sessionCaps.realtime!=='webrtc-video-v1';
  if(!active){$('stream-message').textContent=message||'Compatibility video';$('performance-details').textContent='';$('optimize-stream').hidden=true;}
  if(!active&&controlling)release();
  if(active){canvas.width=remoteVideo.videoWidth;canvas.height=remoteVideo.videoHeight;ctx.clearRect(0,0,canvas.width,canvas.height);$('video-stats').textContent='WebRTC · encrypted realtime video';}
  else $('video-stats').textContent=message||'Compatibility video';
  $('health-label').textContent=active?'Live':recovering?'Recovering video…':'Compatibility video';
  $('health-label').dataset.state=active?'live':'pressure';
 },
 stats:value=>{
  samples.push(M2PDiagnostics.sample(value));if(samples.length>60)samples.shift();
  const health=M2PDiagnostics.health(value);
  $('health-label').textContent=health.label;$('health-label').dataset.state=health.state;
  $('optimize-stream').hidden=health.state!=='pressure'||$('video-quality').value==='auto';
  const number=(v,digits=0)=>Number.isFinite(v)?v.toFixed(digits):'—';
  $('video-stats').textContent=`WebRTC · ${value.codec} · ${value.width}×${value.height} · ${number(value.fps)} fps · ${number(value.mbps,1)} Mbps${Number.isFinite(value.rtt)?' · '+number(value.rtt)+' ms media RTT':''}`;
  const sender=value.sender;
  $('performance-details').textContent=`Buffer ${number(value.bufferMs)} ms · decode ${number(value.decodeMs)} ms · drops ${number(value.dropPercent,1)}% · loss ${number(value.lossPercent,1)}%`+(sender?` · encode ${number(sender.encodeMs)} ms · send queue ${number(sender.sendDelayMs)} ms · source ${number(sender.sourceFPS)} fps`:value.telemetrySupported?' · waiting for sender metrics':' · sender diagnostics need 0.5.1');
  const advice=sender?.adaptive?'Auto adjusts stream resolution.':'Select Auto or Fast for lower load.';
  $('stream-message').textContent=sender?.pressure==='receiver'?'Viewer decoding or network reception is under load · '+advice:sender?.reason==='cpu'?'Sender CPU pressure · '+advice:sender?.reason==='bandwidth'?'Network-limited · '+advice:sender?.adaptive?`Auto · current maximum ${sender.targetWidth}px · ${sender.targetFPS||60} FPS target · ${number(sender.bitrate/1e6,1)} Mbps`:'';
 }
});
const jpegQueue=new M2PLatestFrame({
 decode:data=>createImageBitmap(new Blob([data],{type:'image/jpeg'})),
 valid:token=>connected&&token===generation&&!realtime.active,
 ack:token=>{if(token===generation)api?.ackVideo();},
 error:()=>notice('A video frame could not be decoded.'),
 draw:bitmap=>{
  // Reallocating the canvas on every frame also reallocates its drawing buffer.
  if(canvas.width!==bitmap.width)canvas.width=bitmap.width;
  if(canvas.height!==bitmap.height)canvas.height=bitmap.height;
  ctx.drawImage(bitmap,0,0);
  jpegFrames++;const elapsed=performance.now()-jpegSince;
  if(elapsed>=1000){$('video-stats').textContent=`Compatibility · ${canvas.width}×${canvas.height} · ${Math.round(jpegFrames*1000/elapsed)} fps`;jpegFrames=0;jpegSince=performance.now();}
 }
});
remoteVideo.onresize=()=>{if(realtime.active){canvas.width=remoteVideo.videoWidth;canvas.height=remoteVideo.videoHeight;}};
function hud(){document.body.classList.add('show-session-controls');clearTimeout(hudTimer);hudTimer=setTimeout(()=>document.body.classList.remove('show-session-controls'),2200);}
$('fullscreen').onclick=()=>api.fullscreen(!fullscreen);
$('video-quality').onchange=$('video-fps').onchange=()=>{
 const quality=$('video-quality').value,fps=Number($('video-fps').value);
 realtime.setQuality(quality,fps);rememberPreferences({quality,fps});
};
$('optimize-stream').onclick=()=>{
 $('video-quality').value=sessionCaps.realtimeTelemetry===1?'auto':'fast';
 $('video-quality').onchange();$('optimize-stream').hidden=true;
};
function startRealtime(){realtime.start($('video-quality').value,{telemetry:sessionCaps.realtimeTelemetry===1,feedback:sessionCaps.realtimeFeedback===1,fps:Number($('video-fps').value)});}
$('retry-video').onclick=()=>{
 if(!connected||realtime.pc||realtime.recovering)return;
 $('retry-video').hidden=true;$('health-label').textContent='Starting realtime…';startRealtime();
};
$('copy-diagnostics').onclick=async()=>{
 const own=generation;
 try{
  const ok=await api.copyDiagnostics(M2PDiagnostics.report({hostVersion:sessionCaps.appVersion,hostPlatform:sessionCaps.platform,transport:realtime.active?'webrtc':'compatibility',quality:$('video-quality').value,requestedFPS:Number($('video-fps').value),sound:$('audio').checked,recoveryAttempts:realtime.recoveryAttempts,samples}));
  if(own!==generation)return;
  $('copy-diagnostics').textContent=ok?'Copied':'Try again';
 }catch{if(own===generation)$('copy-diagnostics').textContent='Try again';}
 clearTimeout(copyTimer);copyTimer=setTimeout(()=>$('copy-diagnostics').textContent='Copy diagnostics',2000);
};
document.addEventListener('keydown',event=>{if(event.key==='F11'&&connected){event.preventDefault();event.stopPropagation();api.fullscreen(!fullscreen);}if(event.key==='F8'&&fullscreen){event.preventDefault();event.stopPropagation();hud();}},true);
document.addEventListener('pointermove',event=>{if(fullscreen&&(event.clientY<70||event.clientY>innerHeight-60))hud();});
function notice(message){$('notice').textContent=message;$('notice').hidden=!message;}
function clearMove(){if(moveFrame!==null)cancelAnimationFrame(moveFrame);moveFrame=null;pendingMove=null;}
function release(){clearMove();button=null;api?.input({t:'cancel'});}
function stopAudio(){for(const source of sources){try{source.stop();}catch{}}sources.clear();audioAt=0;}
function point(event){
  return M2PViewport.remotePoint(canvas.getBoundingClientRect(),canvas.width,canvas.height,event);
}
function sendPointer(type,event){const p=point(event);api.input({t:type,x:p.x,y:p.y,b:button??0});}
$('pair-form').addEventListener('submit',async event=>{
  event.preventDefault();notice('');const link=$('pair-link').value;$('pair-link').value='';
  const result=await api.connect(link);if(!result.ok)notice(result.message);
});
$('disconnect').onclick=()=>api.disconnect();
$('control').onchange=async()=>{
  const own=++controlRevision,token=generation,requested=$('control').checked;
  // Release locally immediately; a delayed IPC response must not resurrect
  // input after disconnect, Shift-Escape, or a newer toggle.
  if(!requested){controlling=false;release();canvas.style.cursor='default';$('text').disabled=$('send-text').disabled=true;}
  let accepted;
  try{accepted=await api.control(requested);}catch{accepted=false;}
  if(own!==controlRevision||token!==generation||!connected)return;
  controlling=accepted===true;$('control').checked=controlling;
  canvas.style.cursor=controlling?'none':'default';
  $('text').disabled=$('send-text').disabled=!controlling;
  if(controlling)canvas.focus();else release();
};
$('audio').onchange=async()=>{
  try{
    if($('audio').checked){audioContext??=new AudioContext({latencyHint:'interactive'});await audioContext.resume();}
    else stopAudio();api.audio($('audio').checked);
  }catch{ $('audio').checked=false;api.audio(false);notice('Audio output could not start. Check your output device.'); }
};
$('text-form').onsubmit=event=>{event.preventDefault();if(controlling&&$('text').value){api.input({t:'txt',s:$('text').value});$('text').value='';canvas.focus();}};
canvas.onpointerdown=event=>{
  if(!controlling||event.button>2||!point(event).inside)return;
  clearMove();
  event.preventDefault();canvas.focus();button=event.button===2?1:event.button===1?2:0;
  sendPointer('m',event);api.input({t:'d',b:button});canvas.setPointerCapture(event.pointerId);
};
canvas.onpointermove=event=>{
 if(!controlling||button===null&&!point(event).inside)return;
 const p=point(event);pendingMove={t:button===null?'m':'g',x:p.x,y:p.y,b:button??0};
 if(moveFrame===null)moveFrame=requestAnimationFrame(()=>{moveFrame=null;const value=pendingMove;pendingMove=null;if(controlling&&value)api.input(value);});
};
canvas.onpointerup=event=>{clearMove();if(button!==null){sendPointer('g',event);api.input({t:'u',b:button});button=null;}if(canvas.hasPointerCapture(event.pointerId))canvas.releasePointerCapture(event.pointerId);};
canvas.onpointercancel=canvas.onlostpointercapture=release;
canvas.oncontextmenu=event=>event.preventDefault();
canvas.addEventListener('wheel',event=>{
  if(!controlling)return;event.preventDefault();
  const scale=event.deltaMode===1?16:event.deltaMode===2?canvas.clientHeight:1;
  api.input({t:'s',dx:Math.max(-1000,Math.min(1000,-event.deltaX*scale)),dy:Math.max(-1000,Math.min(1000,-event.deltaY*scale))});
},{passive:false});
const keys={Enter:'return',Backspace:'backspace',Delete:'forwarddelete',Escape:'escape',Tab:'tab',ArrowLeft:'left',ArrowRight:'right',ArrowUp:'up',ArrowDown:'down',Home:'home',End:'end',PageUp:'pageup',PageDown:'pagedown',' ':'space','=':'equal','-':'minus',']':'rightbracket','[':'leftbracket','\\':'backslash',"'":'quote',';':'semicolon',',':'comma','/':'slash','.':'period','`':'grave'};
canvas.onkeydown=event=>{
  if(event.key==='Escape'&&event.shiftKey){
    event.preventDefault();++controlRevision;controlling=false;api.control(false);release();
    canvas.style.cursor='default';hud();$('control').checked=false;$('text').disabled=$('send-text').disabled=true;$('control').focus();return;
  }
  if(!controlling||event.isComposing||['Shift','Control','Meta','Alt','CapsLock'].includes(event.key))return;
  const modifiers=[];
  if(event.ctrlKey)modifiers.push($('cmd-map').checked?'cmd':'ctrl');if(event.metaKey&&!modifiers.includes('cmd'))modifiers.push('cmd');
  if(event.altKey)modifiers.push('alt');if(event.shiftKey)modifiers.push('shift');
  if(!event.ctrlKey&&!event.metaKey&&!event.altKey&&[...event.key].length===1){event.preventDefault();api.input({t:'txt',s:event.key});return;}
  const key=keys[event.key]??event.key.toLowerCase();
  if(keys[event.key]||/^[a-z0-9]$|^f([1-9]|1[0-2])$/.test(key)){event.preventDefault();api.input({t:'key',k:key,m:modifiers});}
};
canvas.onblur=release;window.addEventListener('blur',release);
if(!api){$('connect').disabled=true;notice('Layout preview. Run the desktop app to pair with your Mac.');}
else{
  api.on('realtime',value=>realtime.handle(value));
  api.on('fullscreen',value=>{fullscreen=value;document.body.classList.toggle('session-fullscreen',value);$('fullscreen').textContent=value?'Exit fullscreen':'Fullscreen';if(value){m2pUI.show('session',{focus:false});hud();canvas.focus();}});
  api.on('state',value=>{
    const wasConnected=connected;
    ++controlRevision;
    clearMove();
    generation++;jpegQueue.clear();
    realtime.stop();canvas.classList.remove('realtime');remoteVideo.hidden=true;canvas.style.cursor='default';
    connected=value.state==='connected';controlling=false;button=null;stopAudio();format=null;
    if(!connected&&wasConnected)showPreferences();
    sessionCaps=value.capabilities||{};samples=[];clearTimeout(copyTimer);
    $('copy-diagnostics').textContent='Copy diagnostics';
    $('session-health').hidden=!connected;$('retry-video').hidden=true;$('optimize-stream').hidden=true;
    $('health-label').textContent=sessionCaps.realtime==='webrtc-video-v1'?'Connecting video…':'Compatibility video';$('health-label').dataset.state=sessionCaps.realtime==='webrtc-video-v1'?'live':'pressure';
    $('session-versions').textContent=connected?`Host ${M2PDiagnostics.report({hostVersion:sessionCaps.appVersion}).hostVersion} · ${sessionCaps.realtimeFeedback===1?'Two-way Auto':sessionCaps.realtimeTelemetry===1?'Sender-only Auto':'Basic stream controls'}`:'';
    $('video-fps').disabled=true;
    if(connected&&sessionCaps.realtimeFeedback!==1)$('video-fps').value='60';
    $('video-fps').title=sessionCaps.realtimeFeedback===1?'Frame-rate ceiling, not a guaranteed rate. Auto can reduce it under load.':'Update the sharing app to 0.5.2 for frame-rate controls.';
    $('fullscreen').disabled=!connected;$('video-quality').disabled=true;
    const enhanced=value.capabilities?.realtimeTelemetry===1;
    $('video-quality').querySelector('[value=auto]').disabled=!enhanced;
    if(connected&&!enhanced&&$('video-quality').value==='auto')$('video-quality').value='fast';
    $('video-quality').title=connected&&value.capabilities?.realtime!=='webrtc-video-v1'?'This sender uses fixed compatibility video. Update the sharing app for stream resolution controls.':'Maximum streamed resolution; the host monitor resolution is unchanged.';
    $('performance-details').textContent='';
    $('stream-message').textContent=connected&&value.capabilities?.realtime!=='webrtc-video-v1'?'Compatibility video · fixed stream size · update the sharing app for WebRTC and resolution controls.':'';
    jpegFrames=0;jpegSince=performance.now();
    $('video-stats').textContent=value.capabilities?.realtime==='webrtc-video-v1'?'Starting realtime video…':'Compatibility video · update both desktop apps for WebRTC';
    $('control').checked=$('audio').checked=false;
    $('control').disabled=!connected||value.capabilities?.control!==true;
    $('audio').disabled=!connected||value.capabilities?.audioAvailable!==true;
    $('text').disabled=$('send-text').disabled=true;
    $('disconnect').disabled=value.state==='idle'||value.state==='error';
    $('connect').disabled=value.state==='connecting';
    $('host-name').textContent=value.host??'No device connected';
    if(connected)$('cmd-map').checked=value.capabilities?.platform==='darwin'||value.capabilities?.platform==='macos'||!value.capabilities?.platform;
    $('status').textContent={connected:'Paired · encrypted',connecting:'Connecting…',idle:'Ready to pair',error:'Disconnected'}[value.state];
    $('status').className='badge'+(connected?' connected':'');
    $('empty').hidden=connected;canvas.hidden=!connected;$('stream-info').hidden=!connected;
    ctx.clearRect(0,0,canvas.width,canvas.height);$('latency').textContent='';
    notice(value.message??(connected&&value.capabilities?.screen!==true?'Enable screen sharing on the host device.':connected&&value.capabilities?.control!==true?'View-only: remote input is not enabled or supported on this host.':''));
    if(connected&&value.capabilities?.audioAvailable!==true)$('audio').title='This host is not advertising system audio. Check its sharing options.';
    if(connected&&value.capabilities?.realtime==='webrtc-video-v1')startRealtime();
  });
  api.on('video',data=>jpegQueue.push(data,generation));
  api.on('audio-format',value=>{format=value;stopAudio();});
  api.on('audio',data=>{
    try{
      if(!$('audio').checked||!format||!audioContext||audioContext.state!=='running')return;
      if(audioAt>audioContext.currentTime+.2)return; // Drop stale samples instead of growing latency.
      const bytes=new Uint8Array(data),view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
      const count=bytes.length/(2*format.channels),buffer=audioContext.createBuffer(format.channels,count,format.rate);
      for(let c=0;c<format.channels;c++){const out=buffer.getChannelData(c);for(let i=0;i<count;i++)out[i]=view.getInt16(2*(i*format.channels+c),true)/32768;}
      const source=audioContext.createBufferSource();source.buffer=buffer;source.connect(audioContext.destination);
      audioAt=Math.max(audioAt,audioContext.currentTime+.02);source.start(audioAt);audioAt+=buffer.duration;
      sources.add(source);source.onended=()=>{sources.delete(source);source.disconnect();};
    }finally{api.ackAudio();}
  });
  api.on('latency',ms=>$('latency').textContent=`· ${Math.round(ms)} ms RTT`);
  api.on('notice',notice);api.on('blur',release);
}
