'use strict';
process.env.M2P_UI_TEST='1';
const {app,BrowserWindow,ipcMain,nativeImage,clipboard}=require('electron');
const {Host}=require('../core/host.cjs'),{Session}=require('../core/session.cjs'),{T}=require('../core/protocol.cjs');
const path=require('node:path'),fs=require('node:fs'),os=require('node:os'),assert=require('node:assert/strict');
const {once}=require('node:events');
const output=path.resolve(process.env.M2P_TEST_OUTPUT||path.join(__dirname,'../../.polish/reliability-053'));fs.mkdirSync(output,{recursive:true});
app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'m2p-realtime-test-')));
const input=[],host=new Host({platform:'win32',requireApproval:true,realtime:true,input:v=>input.push(v)});
let source,viewer,legacyFrames=0,pump;
let copied='';clipboard.writeText=text=>{copied=text;}; // Never change the user's clipboard during a test.
const receive=Session.prototype.receive;Session.prototype.receive=function(type,...args){if(type===T.jpeg)legacyFrames++;return receive.call(this,type,...args);};
require('../main.cjs');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const js=code=>viewer.webContents.executeJavaScript(code,true);
async function until(fn,label){for(let i=0;i<300;i++){if(await fn())return;await sleep(50);}throw Error('Timed out: '+label);}
app.whenReady().then(async()=>{
 try{
  viewer=BrowserWindow.getAllWindows()[0];viewer.webContents.setBackgroundThrottling(false);
  if(viewer.webContents.isLoading())await once(viewer.webContents,'did-finish-load');
  source=new BrowserWindow({show:false,width:960,height:540,webPreferences:{preload:path.join(__dirname,'fixtures/realtime-preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  ipcMain.handle('fixture:realtime',(event,id,value)=>event.sender===source.webContents&&host.signal(id,value));
  host.on('realtime',value=>source.webContents.send('fixture:signal',value));host.on('realtime-close',id=>{if(!source.isDestroyed())source.webContents.send('fixture:close',id);});
  const lan=Object.values(os.networkInterfaces()).flat().find(v=>!v.internal&&v.family==='IPv4'&&v.mac!=='00:00:00:00:00:00')?.address;
  assert(lan,'A LAN interface is required for native WebRTC host candidates');
  await source.loadFile(path.join(__dirname,'fixtures/realtime-host.html'));await host.start({bind:lan,port:0,control:true,audio:true});
  const jpeg=nativeImage.createFromBitmap(Buffer.alloc(64*36*4,255),{width:64,height:36}).toJPEG(80);
  pump=setInterval(()=>{host.jpeg(jpeg);host.pcm(Buffer.alloc(1920));},33);
  await js(`$('video-quality').value='sharp';mac2phone.connect(${JSON.stringify(host.grant(lan))})`);
  await until(()=>js(`realtime.active&&remoteVideo.videoWidth===1920`),'real H.264/VP8 video');
  await sleep(3500);
  assert.equal([...host.clients][0].rtc,true);const before=legacyFrames;await sleep(300);assert.equal(legacyFrames,before,'no parallel JPEG stream after RTC activation');
  const stats=await js(`$('video-stats').textContent`);assert.match(stats,/WebRTC.*1920×1080.*fps/);console.log('MEASURED synthetic video on this Mac\'s LAN interface: '+stats);
  console.log('PASS approved TLS signaling, real WebRTC encode/decode, decoded 1080p frames and no duplicate JPEG traffic');
  await until(()=>js(`Number.isFinite(realtime.senderStats?.encodeMs)&&/encode [0-9]+ ms/.test($('performance-details').textContent)`),'approved sender telemetry');
  assert.equal(await js(`realtime.pc.getReceivers().find(r=>r.track.kind==='video').jitterBufferTarget`),0);
  assert.equal(await js(`$('video-quality').disabled`),false);
  console.log('MEASURED pipeline: '+await js(`$('performance-details').textContent`));

  viewer.webContents.send('m2p:fullscreen',true);await sleep(150);
  const layout=await js(`({viewport:[innerWidth,innerHeight],canvas:[canvas.getBoundingClientRect().width,canvas.getBoundingClientRect().height],center:point({clientX:innerWidth/2,clientY:innerHeight/2})})`);
  assert.deepEqual(layout.canvas,layout.viewport);assert.equal(layout.center.x,.5);assert.equal(layout.center.y,.5);
  await js(`$('control').click()`);await until(()=>js(`controlling`),'control');
  assert.equal(await js(`canvas.style.cursor`),'none');await js(`canvas.dispatchEvent(new PointerEvent('pointermove',{clientX:innerWidth/2,clientY:innerHeight/2}));canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'c',ctrlKey:true}))`);
  await until(()=>input.some(v=>v.t==='key'&&v.k==='c'&&v.m.includes('ctrl'))&&input.some(v=>v.t==='m'),'Windows input');assert(input.some(v=>v.t==='m'&&v.x===.5&&v.y===.5));
  await js(`hud()`);await sleep(200);fs.writeFileSync(path.join(output,'fullscreen-preview.png'),(await viewer.webContents.capturePage()).toPNG());
  console.log('PASS edge-to-edge fullscreen layout, aligned pointer coordinates, one cursor and Windows keyboard input');

  await js(`$('video-quality').value='fast';$('video-quality').dispatchEvent(new Event('change'))`);
  await until(()=>js(`remoteVideo.videoWidth>0&&remoteVideo.videoWidth<=1280`),'live 720p quality switch');
  await js(`$('video-quality').value='sharp';$('video-quality').dispatchEvent(new Event('change'))`);
  await until(()=>js(`remoteVideo.videoWidth===1920`),'live native quality switch');
  await js(`$('audio').click()`);await until(()=>js(`audioContext?.state==='running'&&format?.rate===48000&&audioAt>0`),'PCM sound');
  console.log('PASS live bitrate/resolution profiles and opt-in system-audio transport alongside WebRTC');

  await js(`$('video-quality').value='auto';$('video-quality').dispatchEvent(new Event('change'))`);
  await until(()=>source.webContents.executeJavaScript(`(()=>{const p=[...senderPool.peers.values()][0];return p.adaptive&&p.auto.profile.width===1280})()`),'Auto starts with a bounded 720p budget');
  await until(()=>js(`remoteVideo.videoWidth<=1280`),'Auto stream dimensions');
  const ages=[];
  for(let n=0;n<15;n++){
   await sleep(70);
   ages.push(await js(`(()=>{const c=document.createElement('canvas');c.width=1920;c.height=1080;const x=c.getContext('2d',{willReadFrequently:true});x.drawImage(remoteVideo,0,0,1920,1080);const row=x.getImageData(0,1020,1920,1).data;let stamp=0;for(let bit=0;bit<32;bit++)if(row[(124+bit*48)*4]>128)stamp=(stamp+(2**bit))>>>0;return ((Date.now()>>>0)-stamp)>>>0;})()`));
  }
  ages.sort((a,b)=>a-b);assert(ages.at(-1)<2000,'synthetic pixel clock decodes correctly');
  console.log(`MEASURED Auto synthetic pixel age: median ${ages[7]} ms; p95 ${ages[14]} ms (same machine, not Windows LAN latency)`);
  console.log('MEASURED Auto video: '+await js(`$('video-stats').textContent`));
  await until(()=>source.webContents.executeJavaScript(`Number.isFinite([...senderPool.peers.values()][0]?.receiverStats?.bufferMs)`),'viewer feedback reaches approved host');
  await js(`$('video-fps').value='30';$('video-fps').dispatchEvent(new Event('change'))`);
  await until(()=>source.webContents.executeJavaScript(`[...senderPool.peers.values()][0].sender.getParameters().encodings[0].maxFramerate===30`),'30 FPS sender cap');
  await sleep(2200);
  console.log('MEASURED 30 FPS mode: '+await js(`$('video-stats').textContent`));
  await js(`$('copy-diagnostics').click()`);
  await until(()=>copied.length>0,'sanitized report IPC');
  const report=JSON.parse(copied);assert.equal(report.clientVersion,'0.5.3');assert.equal(report.hostVersion,'0.5.3');assert.equal(report.requestedFPS,30);assert(report.samples.length>0);
  assert(!copied.includes(lan));assert(!copied.includes('v=0'));assert(!copied.includes('mac2phone://'));
  fs.writeFileSync(path.join(output,'session-diagnostics.json'),copied);
  await js(`hud()`);await sleep(150);fs.writeFileSync(path.join(output,'session-health-preview.png'),(await viewer.webContents.capturePage()).toPNG());
  viewer.setSize(760,540);await sleep(200);await js(`hud()`);await sleep(200);
  assert.equal(await js(`(()=>{const toolbar=document.querySelector('.controls').getBoundingClientRect(),health=$('session-health').getBoundingClientRect();return toolbar.left>=0&&toolbar.right<=innerWidth&&health.left>=0&&health.right<=innerWidth&&toolbar.bottom<=health.top&&document.documentElement.scrollWidth<=innerWidth;})()`),true,'compact fullscreen controls stay visible without overlap');
  fs.writeFileSync(path.join(output,'compact-session-preview.png'),(await viewer.webContents.capturePage()).toPNG());
  viewer.setSize(1180,820);await sleep(150);
  await js(`$('video-fps').value='60';$('video-fps').dispatchEvent(new Event('change'))`);
  await until(()=>source.webContents.executeJavaScript(`[...senderPool.peers.values()][0].sender.getParameters().encodings[0].maxFramerate===60`),'60 FPS restored before injecting pressure');
  console.log('PASS receiver feedback over approved TLS, live 30 FPS cap and bounded credential-free diagnostic report');
  await source.webContents.executeJavaScript(`(async()=>{
   const [id,peer]=[...senderPool.peers.entries()][0],original=peer.pc.getStats.bind(peer.pc);
   clearInterval(peer.statsTimer);while(peer.measuring)await new Promise(r=>setTimeout(r,10));await peer.queue;peer.previous=null;
   try{
    for(let n=0;n<3;n++){
     peer.pc.getStats=async()=>new Map([['test',{type:'outbound-rtp',kind:'video',timestamp:1000+n*2000,framesEncoded:n*120,totalEncodeTime:n*4,packetsSent:n*200,totalPacketSendDelay:n*.2,qualityLimitationReason:'cpu',frameWidth:1280,frameHeight:720}]]);
     await senderPool.measure(id,peer);await peer.queue;
    }
    if(peer.auto.profile.width!==960)throw Error('No CPU backoff');
   }finally{peer.pc.getStats=original;}
  })()`);
  await until(()=>js(`remoteVideo.videoWidth<=960&&realtime.senderStats?.targetWidth===960`),'simulated sustained load lowers real encoder resolution');
  console.log('PASS minimum-buffer receiver, opt-in telemetry, Auto quality and simulated-load encoder backoff');

  // Isolate receiver pressure from sender CPU/network pressure. Feedback takes
  // the real approved TLS path; only the measurement values are injected.
  await js(`clearInterval(realtime.statsTimer);$('video-quality').onchange();mac2phone.realtime({type:'feedback',frames:60,bufferMs:120,decodeMs:20,dropPercent:10,lossPercent:0})`);
  await until(()=>source.webContents.executeJavaScript(`[...senderPool.peers.values()][0]?.receiverStats?.bufferMs===120`),'synthetic receiver pressure over TLS');
  await source.webContents.executeJavaScript(`(async()=>{
   const [id,peer]=[...senderPool.peers.entries()][0],original=peer.pc.getStats.bind(peer.pc);await peer.queue;peer.previous=null;
   try{
    for(let n=0;n<3;n++){
     peer.pc.getStats=async()=>new Map([['test',{type:'outbound-rtp',kind:'video',timestamp:1000+n*2000,framesEncoded:n*120,totalEncodeTime:n*.36,packetsSent:n*200,totalPacketSendDelay:n*.2,qualityLimitationReason:'none',frameWidth:1280,frameHeight:720}]]);
     await senderPool.measure(id,peer);await peer.queue;
    }
    if(peer.auto.profile.width!==960)throw Error('No receiver-pressure backoff');
   }finally{peer.pc.getStats=original;}
  })()`);
  await until(()=>js(`remoteVideo.videoWidth<=960&&realtime.senderStats?.pressure==='receiver'`),'receiver-driven encoder backoff');
  console.log('PASS simulated receiver congestion lowers real encoder resolution despite a healthy sender');

  await js(`(async()=>{
   const pc=window.beforeRecovery=realtime.pc,original=pc.getStats.bind(pc),hidden=Object.getOwnPropertyDescriptor(document,'hidden');
   clearInterval(realtime.statsTimer);while(realtime.measuring===pc)await new Promise(r=>setTimeout(r,10));
   Object.defineProperty(document,'hidden',{configurable:true,value:false});realtime.stall=new M2PStreamPolicy.StallWatch();realtime.previous=null;
   try{
    for(let n=0;n<4;n++){
     pc.getStats=async()=>new Map([['stalled',{type:'inbound-rtp',kind:'video',timestamp:n*1000,framesDecoded:60,bytesReceived:n*10000,framesPerSecond:0}]]);
     await realtime.measure(pc);
    }
   }finally{pc.getStats=original;if(hidden)Object.defineProperty(document,'hidden',hidden);else delete document.hidden;}
  })()`);
  await until(()=>js(`realtime.recovering&&!realtime.active&&$('retry-video').hidden`),'automatic recovery state');
  await until(()=>js(`realtime.active&&realtime.pc!==window.beforeRecovery`),'automatic video recovery without pairing again');
  assert.equal(await js(`realtime.recoveryAttempts`),1);assert.equal(host.clients.size,1);
  console.log('PASS injected stalled-decode counters trigger automatic real video recovery within the existing approved session');
  await js(`realtime.recovery.times=[Date.now(),Date.now()];realtime.fail(realtime.pc)`);
  await until(()=>js(`!realtime.active&&canvas.width===64&&!canvas.classList.contains('realtime')`),'JPEG recovery');assert.equal([...host.clients][0].rtc,false);
  assert.equal(await js(`$('video-quality').disabled`),true,'quality control explains inactive RTC instead of silently doing nothing');
  assert.equal(await js(`$('retry-video').hidden`),false);
  await js(`$('retry-video').click()`);
  await until(()=>js(`realtime.active`),'retry realtime without pairing again');
  assert.equal([...host.clients][0].rtc,true);
  await js(`$('disconnect').click()`);await until(()=>host.clients.size===0,'disconnect');
  await until(()=>source.webContents.executeJavaScript(`senderPool.peers.size===0`),'sender cleanup');
  console.log('PASS realtime failure restores compatibility video, one-click retry works and disconnect closes both peers');
  console.log('REALTIME SMOKE: 8 groups passed');clearInterval(pump);await host.stop();app.exit(0);
 }catch(error){console.error(error);if(viewer)console.error(await js(`({status:$('status').textContent,video:$('video-stats').textContent,rtc:realtime.pc?.connectionState,ice:realtime.pc?.iceConnectionState,ready:remoteVideo.readyState,failure:realtime.lastFailure})`));if(source)console.error(await source.webContents.executeJavaScript(`({failure:senderPool.lastFailure,peers:[...senderPool.peers.values()].map(p=>({state:p.pc.connectionState,ice:p.pc.iceConnectionState,signaling:p.pc.signalingState}))})`));clearInterval(pump);await host.stop();app.exit(1);}
});
setTimeout(()=>{console.error('Realtime test timed out');app.exit(1);},60000).unref();
