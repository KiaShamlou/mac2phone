'use strict';
(()=>{
 const api=window.mac2phone,$=id=>document.getElementById(id);
 let caps={platform:'unknown',control:false,audio:false,settings:false},phase='idle',prepared=null;
 let stream=null,context=null,worklet=null,timer=null,hostActive=false,operation=0,stopTask=null;
 let prepareQueue=Promise.resolve();
 let legacyDemand=0,captureBudget=null,profiles=[];
 const realtime=new M2PRealtime.Senders({getStream:()=>hostActive?stream:null,send:(id,value)=>api.hostRealtime(id,value).catch(()=>{}),
  demand:values=>{profiles=values;captureBudget?.update(profiles,legacyDemand);}});
 api?.on('host-realtime',({id,signal})=>realtime.handle(id,signal));
 api?.on('host-realtime-close',id=>realtime.close(id));
 api?.on('host-video-demand',count=>{legacyDemand=count;captureBudget?.update(profiles,legacyDemand);});
 const video=$('share-video'),info=text=>$('share-status').textContent=text;
 function error(title,detail){$('share-error-title').textContent=title;$('share-error-detail').textContent=detail;$('share-error').hidden=false;$('share-settings').hidden=!caps.settings;}
 function clearError(){$('share-error').hidden=true;}
 function render(){
  const busy=['choosing','preparing','requesting','starting','stopping'].includes(phase),live=hostActive||phase==='starting';
  $('share-sources').disabled=!api||busy||!!stream;
  $('share-preview').hidden=!!stream||live;$('share-preview').disabled=phase!=='ready';
  $('share-preview').textContent=phase==='preparing'?'Preparing selection…':phase==='requesting'?'Waiting for screen access…':'Allow screen & preview';
  $('share-start').hidden=!stream||live;$('share-start').disabled=phase!=='preview';
  $('share-reset').hidden=live||!stream&&phase!=='requesting';$('share-reset').disabled=phase==='stopping'||live;
  $('share-stop').hidden=!live;$('share-stop').disabled=phase==='stopping';
  $('share-copy').hidden=!hostActive;$('share-copy').disabled=phase!=='sharing';
  $('share-control').disabled=!caps.control||busy||!!stream;$('share-sound').disabled=!caps.audio||busy||!!stream;
  document.querySelectorAll('.source-choice').forEach(button=>{button.disabled=busy||!!stream;button.setAttribute('aria-pressed',String(button.dataset.source===$('share-source').value));});
  if(!stream&&!prepared&&phase==='idle'&&$('share-source').value){$('access-title').textContent='Choose a display again';$('access-description').textContent='Select a display or refresh the list to begin a new local preview.';}
  if(stream){$('access-title').textContent='Selected screen is ready';$('access-description').textContent='Discard the preview or stop sharing to switch displays or change access.';}
  $('share-video').hidden=!stream;$('preview-empty').hidden=!!stream;$('preview-label').hidden=!stream;
  $('preview-label').textContent=hostActive?'Sharing · connections need your approval':'Local preview · only you can see this';
  $('share-badge').textContent=hostActive?'Sharing':stream?'Preview only':'Not sharing';$('share-badge').className='badge'+(hostActive?' live':'');
  $('sidebar-sharing').hidden=!live;$('nav-sharing').hidden=!live;$('sidebar-stop').disabled=phase==='stopping';
  const step=hostActive?2:stream||prepared?1:0;
  ['step-access','step-preview','step-share'].forEach((id,i)=>{const node=$(id);node.classList.toggle('complete',i<step);if(i===step)node.setAttribute('aria-current','step');else node.removeAttribute('aria-current');});
 }
 function updateCaps(value){if(!value)return;caps={...caps,...value};
  $('local-device-name').textContent=caps.name||'This computer';
  $('local-platform').textContent={win32:'Windows',darwin:'macOS',linux:'Linux'}[caps.platform]||'Desktop app';
  if(!caps.control){$('share-control').checked=false;$('control-description').textContent=caps.platform==='darwin'?'Use the native Mac host for remote input.':'Remote input is unavailable on this system.';}
  if(!caps.audio){$('share-sound').checked=false;$('sound-description').textContent=caps.platform==='linux'?'Install parec for output-monitor audio.':'System sound is unavailable on this system.';}
  if(['denied','restricted'].includes(caps.screenStatus)){$('permission-status').textContent='System access needs attention';$('access-description').textContent='Enable Screen Recording for Mac2Phone in System Settings, reopen the app if asked, then check again.';}
  render();
 }
 async function releaseLocal(){captureBudget?.stop();captureBudget=null;realtime.stop();legacyDemand=0;clearTimeout(timer);timer=null;const previous=stream;stream=null;previous?.getTracks().forEach(track=>{track.onended=null;track.stop();});video.pause();video.srcObject=null;worklet?.disconnect();worklet=null;const audio=context;context=null;try{await audio?.close();}catch{}}
 async function stop(){
  if(stopTask)return stopTask;
  const wasHosting=hostActive||phase==='starting';++operation;phase='stopping';prepared=null;render();
  stopTask=(async()=>{try{await releaseLocal();if(wasHosting)await api.hostStop();else await api.hostReset();}catch{error('Sharing cleanup needs attention','Close the app to end the session, then open it again.');}finally{hostActive=false;phase='idle';$('permission-status').textContent='No active capture';info(wasHosting?'Sharing stopped. Connections closed and links revoked.':'Preview discarded. Nothing was shared.');stopTask=null;render();}})();
  return stopTask;
 }
 async function prepare(){
  const own=++operation;prepared=null;phase='preparing';clearError();render();
  const options={source:$('share-source').value,control:$('share-control').checked,audio:$('share-sound').checked};
  const pending=prepareQueue.catch(()=>{}).then(()=>api.hostPrepare(options));prepareQueue=pending;
  try{const result=await pending;if(own!==operation)return;
   if(!result.ok)throw Error(result.message||'Choose a screen again.');
   prepared={...result,deadline:Date.now()+115000};phase='ready';$('permission-status').textContent='Display selected · preview not started';$('preview-description').textContent='Click Allow screen & preview to check access. This stays on your computer.';info('Ready for your approval. Nothing is being captured yet.');
  }catch(e){if(own!==operation)return;phase='idle';error('Screen selection needs attention',e.message||'Check access and choose a screen again.');info('Check screen access to retry.');}
  render();
 }
 $('share-sources').onclick=async()=>{
  const own=++operation;phase='choosing';prepared=null;clearError();render();info('Checking available displays…');
  try{
   const result=await api.hostSources();if(own!==operation)return;updateCaps(result);
   if(!result.ok||!result.sources?.length){phase='idle';error('No display is available',caps.settings?'Allow Screen Recording in System Settings, then return and check again.':'Unlock your Windows desktop and check again. If this is a managed computer, its screen-capture policy may need attention.');info('Screen access has not been granted.');render();return;}
   const select=$('share-source'),list=$('share-source-list');select.replaceChildren();list.replaceChildren();
   for(const source of result.sources){const option=document.createElement('option');option.value=source.id;option.textContent=source.name;select.append(option);const button=document.createElement('button');button.className='source-choice';button.dataset.source=source.id;button.type='button';const label=document.createElement('span');label.textContent=source.name;button.append(label);button.onclick=()=>{select.value=source.id;prepare();};list.append(button);}
   list.hidden=false;$('access-title').textContent='Choose the display to share';$('access-description').textContent='Only the selected display can appear in your preview. Approve it in the next step.';$('share-sources').textContent='Refresh displays';await prepare();
  }catch{if(own!==operation)return;phase='idle';error('Screen access needs attention','Check access and try again. If a system prompt appears, choose Allow for the screen you want to share.');render();}
 };
 $('share-control').onchange=$('share-sound').onchange=()=>{if($('share-source').value&&!stream)prepare();};
 $('share-preview').onclick=async()=>{
  if(!prepared||phase!=='ready')return;
  if(Date.now()>prepared.deadline){await prepare();info('Selection refreshed. Click Allow screen & preview again.');return;}
  const own=++operation,options=prepared;prepared=null;phase='requesting';clearError();render();
  info('Allow the selected screen. This preview stays local.');
  try{
   // Keep getDisplayMedia in this click's user-activation task: no awaited IPC
   // or source enumeration occurs before the permission request.
   const pending=navigator.mediaDevices.getDisplayMedia({video:{frameRate:{ideal:60,max:60},cursor:'always'},audio:options.audio});
   const acquired=await pending;
   if(own!==operation){acquired.getTracks().forEach(t=>t.stop());return;}
   stream=acquired;video.srcObject=stream;await video.play();if(own!==operation)return;
   const track=stream.getVideoTracks()[0];if(!track||track.readyState!=='live')throw Error('The selected screen stopped before preview was ready.');
   captureBudget=new M2PCaptureBudget.CaptureBudget(track,{applied:()=>realtime.captureChanged()});
   captureBudget.update(profiles,legacyDemand);
   track.onended=()=>{stop();};
   phase='preview';$('permission-status').textContent='Screen access allowed for this session';info('Preview ready. No screen data has left this computer.');
   if(options.audio&&!stream.getAudioTracks().length)info('Preview ready. No system-audio track was provided; this session will share video only.');
  }catch(e){if(own!==operation)return;await releaseLocal();await api.hostReset().catch(()=>{});phase='idle';
   const denied=['NotAllowedError','PermissionDeniedError'].includes(e.name),cancelled=e.name==='AbortError';
   error(denied?'Screen access was not allowed':cancelled?'Screen selection was cancelled':'Preview did not start',denied?(caps.settings?'Allow Mac2Phone in Screen Recording settings, then check access again.':'Check & choose again, then click Allow screen & preview. If sound was enabled, try a video-only preview. A managed computer may also block capture.'):cancelled?'Nothing was shared. Check & choose to try again.':'Check the display is available, refresh the selection and try a video-only preview.');
   $('permission-status').textContent='Preview needs approval';info('Nothing was shared. Check screen access to retry.');
  }
  render();
 };
 async function setupAudio(){
  if(!stream.getAudioTracks().length)return;
  context=new AudioContext({sampleRate:48000});await context.audioWorklet.addModule('capture-audio.js');
  const source=context.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));worklet=new AudioWorkletNode(context,'m2p-pcm');const silent=context.createGain();silent.gain.value=0;source.connect(worklet).connect(silent).connect(context.destination);
  let pending=0;worklet.port.onmessage=async({data})=>{if(!hostActive||pending>=4||!stream)return;pending++;try{await api.hostAudio(new Uint8Array(data),context.sampleRate,2);}catch{info('Audio delivery stopped. Stop sharing and try again.');}finally{pending--;}};await context.resume();
 }
 function startFrames(){const own=operation,surface=document.createElement('canvas'),ctx=surface.getContext('2d',{alpha:false});
  async function frame(){if(!stream||!hostActive||own!==operation)return;
   if(!legacyDemand){timer=setTimeout(frame,100);return;}
   const began=performance.now();
   try{const scale=Math.min(1,1920/video.videoWidth),width=Math.max(1,Math.round(video.videoWidth*scale)),height=Math.max(1,Math.round(video.videoHeight*scale));if(surface.width!==width)surface.width=width;if(surface.height!==height)surface.height=height;ctx.drawImage(video,0,0,width,height);const blob=await new Promise(r=>surface.toBlob(r,'image/jpeg',.8));if(blob&&stream&&hostActive&&own===operation)await api.hostVideo(new Uint8Array(await blob.arrayBuffer()));}
   catch{await stop();error('Screen capture ended','Check & choose to start a new preview.');return;}
   if(stream&&hostActive&&own===operation)timer=setTimeout(frame,Math.max(0,1000/30-(performance.now()-began)));
  }frame();
 }
 $('share-start').onclick=async()=>{
  if(phase!=='preview'||!stream)return;
  const own=++operation;phase='starting';clearError();render();info('Starting your sharing session…');
  try{
   await setupAudio();if(own!==operation)return;
   const result=await api.hostStart({audio:stream.getAudioTracks().length>0||caps.platform==='linux'&&$('share-sound').checked});
   if(own!==operation){if(result.ok)await api.hostStop();return;}
   if(!result.ok)throw Error(result.message||'Sharing did not start.');
   const requestedControl=$('share-control').checked;$('share-control').checked=result.control;$('share-sound').checked=result.audio;
   hostActive=true;phase='sharing';startFrames();$('sidebar-share-detail').textContent='Waiting for an approved connection';
   info('Sharing '+(result.control?'with keyboard & mouse':'view-only')+(result.audio?' and system sound':'')+'. Accept a device request or copy a one-use link.');
   if(requestedControl&&!result.control)info('Sharing video only. The input helper did not start; stop and retry to enable control.');
  }catch(e){if(own!==operation)return;await stop();error('Sharing did not start',e.message||'Check access and try again.');}
  render();
 };
 $('share-copy').onclick=async()=>{try{info(await api.hostCopy()?'One-use link copied. It expires in 60 seconds.':'Connect this computer to a LAN and try again.');}catch{info('The link was not copied. Try again.');}};
 $('share-settings').onclick=async()=>{try{await api.hostSettings();}catch{error('Open Screen Recording settings','Open System Settings → Privacy & Security → Screen Recording.');}};
 $('share-stop').onclick=$('sidebar-stop').onclick=$('share-reset').onclick=stop;
 if(api){api.hostCapabilities().then(updateCaps).catch(()=>info('Device checks did not finish. Check & choose to retry.'));api.on('host-viewers',count=>{if(hostActive){$('sidebar-share-detail').textContent=`${count} connected device${count===1?'':'s'}`;info(`Sharing · ${count} connected. Stop sharing ends every connection.`);}});api.on('host-stopped',()=>{if(hostActive&&!stopTask)stop();});}
 render();
})();
