'use strict';
const {app,BrowserWindow,ipcMain,session,desktopCapturer,screen,clipboard,systemPreferences,shell}=require('electron');
const path=require('node:path');
const startup=require('./startup.cjs');
const {Preferences}=require('./core/preferences.cjs');
const preferences=new Preferences(path.join(app.getPath('userData'),'viewer-preferences.json'));
const {windowOptions}=require('./core/startup.cjs');
const {CapturePolicy,installCapturePermissions}=require('./core/capture-policy.cjs');
const {pathToFileURL}=require('node:url');
const {Session}=require('./core/session.cjs');
const client=new Session();
const {Host}=require('./core/host.cjs');
const {Nearby}=require('./core/nearby.cjs');
const {randomUUID}=require('node:crypto');
const {PlatformInput}=require('./core/platform-input.cjs');
const {spawn,spawnSync}=require('node:child_process');
const adapter=new PlatformInput();
const host=new Host({requireApproval:true,realtime:true,input:value=>adapter.send(value)});
let pendingRequest=null;
const nearby=new Nearby({approve:request=>new Promise(resolve=>{
  if(pendingRequest||!window||window.isDestroyed()){resolve(null);return;}
  const id=randomUUID();pendingRequest={id,resolve,signal:request.signal};
  const cancel=()=>{if(pendingRequest?.id===id){pendingRequest=null;resolve(null);deliver('nearby-incoming',null);}};
  request.signal.addEventListener('abort',cancel,{once:true});
  deliver('nearby-incoming',{id,name:request.name,platform:request.platform,code:request.code});window.show();window.focus();
})});
for(const name of ['devices','request-state'])nearby.on(name,value=>deliver(`nearby-${name}`,value));
nearby.on('notice',message=>deliver('notice',message));
ipcMain.handle('m2p:nearby-list',event=>{if(!trusted(event))return [];return [...nearby.peers.values()].map(({host,port,...v})=>v);});
ipcMain.handle('m2p:nearby-refresh',event=>({ok:trusted(event)&&nearby.refresh()}));
ipcMain.handle('m2p:nearby-request',async(event,id)=>{
 if(!trusted(event)||typeof id!=='string')return {ok:false};
 try{const link=await nearby.request(id);if(!trusted(event))return {ok:false};client.connect(link);return {ok:true};}
 catch(error){return {ok:false,message:error.message==='Request declined'?'Request declined.':'Request ended. Check that the other device is open and try again.'};}
});
ipcMain.handle('m2p:nearby-cancel',event=>{if(trusted(event))nearby.cancel();});
ipcMain.handle('m2p:nearby-respond',(event,id,accept)=>{
 if(!trusted(event)||!pendingRequest||pendingRequest.id!==id||pendingRequest.signal.aborted)return {ok:false};
 if(accept===true&&!host.server)return {ok:false,message:'Set up your screen in Share screen, start sharing, then accept this request.'};
 let link=null;try{if(accept===true)link=host.grant();}catch{return {ok:false,message:'Connect to a LAN and start sharing first.'};}
 const request=pendingRequest;pendingRequest=null;request.resolve(link);deliver('nearby-incoming',null);return {ok:true};
});
let sharing=null,pulse=null,captureEpoch=0,hostStarting=false;
host.on('viewers',count=>deliver('host-viewers',count));
host.on('notice',message=>deliver('notice',message));
host.on('realtime',value=>deliver('host-realtime',value));
host.on('realtime-close',id=>deliver('host-realtime-close',id));
host.on('video-demand',count=>deliver('host-video-demand',count));
async function stopSharing(){++captureEpoch;if(pendingRequest){pendingRequest.resolve(null);pendingRequest=null;deliver("nearby-incoming",null);}capturePolicy.clear();sharing=null;pulse?.kill();pulse=null;await host.stop();adapter.stop();activity();deliver('host-stopped',true);}

let window;
const page=pathToFileURL(path.join(__dirname,'renderer/index.html')).href;
const capturePolicy=new CapturePolicy({getContents:()=>window?.webContents,page});
function trusted(event) { return window&&!window.isDestroyed()&&event.sender===window.webContents&&event.senderFrame===window.webContents.mainFrame&&event.senderFrame.url===page; }
function deliver(name,value) { if(window&&!window.isDestroyed()) window.webContents.send(`m2p:${name}`,value); }
function activity(){if(window&&!window.isDestroyed())window.webContents.setBackgroundThrottling(!(host.server||client.ready));}
for(const name of ['state','video','audio','audio-format','latency','notice','realtime']) client.on(name,value=>deliver(name,value));
client.on('state',value=>{activity();if(!startup.options.test&&window&&!window.isDestroyed())window.setFullScreen(value.state==='connected'&&preferences.get().autoFullscreen);});
ipcMain.handle('m2p:preferences',event=>trusted(event)?preferences.get():null);
ipcMain.handle('m2p:save-preferences',(event,value)=>trusted(event)?preferences.update(value):{ok:false});
ipcMain.handle('m2p:fullscreen',(event,on)=>{if(!trusted(event)||typeof on!=='boolean'||on&&!client.ready)return false;window.setFullScreen(on);return true;});
ipcMain.handle('m2p:copy-diagnostics',(event,value)=>{
 if(!trusted(event)||!value||typeof value!=='object'||Array.isArray(value))return false;
 try{
  if(JSON.stringify(value).length>100000)return false;
  const report=require('./renderer/diagnostics.js').report({...value,clientVersion:require('./package.json').version});
  clipboard.writeText(JSON.stringify(report,null,2));return true;
 }catch{return false;}
});
ipcMain.handle('m2p:realtime',(event,value)=>trusted(event)&&client.signal(value));
ipcMain.handle('m2p:host-realtime',(event,id,value)=>trusted(event)&&typeof id==='string'&&host.signal(id,value));
ipcMain.handle('m2p:connect',(event,link)=>{
  if(!trusted(event)) return {ok:false};
  try { client.connect(link); return {ok:true}; } catch { return {ok:false,message:'Paste a complete pairing link copied from the Mac app.'}; }
});
ipcMain.handle('m2p:control',(event,on)=>trusted(event)&&client.setControl(on));
for(const [name,fn] of Object.entries({disconnect:()=>client.disconnect(),input:v=>client.input(v),
  audio:v=>client.setAudio(v),'ack-video':()=>client.ackVideo(),'ack-audio':()=>client.ackAudio()})) {
  ipcMain.on(`m2p:${name}`,(event,value)=>{if(trusted(event)) fn(value);});
}
function capabilities(){
 const platform=process.platform;
 return {platform,name:require('node:os').hostname(),screenStatus:platform==='darwin'?systemPreferences.getMediaAccessStatus('screen'):'needs-selection',
  control:adapter.available(),audio:platform!=='linux'||spawnSync('which',['parec']).status===0,settings:platform==='darwin'};
}
ipcMain.handle('m2p:host-capabilities',event=>trusted(event)?capabilities():null);
ipcMain.handle('m2p:host-settings',async event=>{
 if(!trusted(event)||process.platform!=='darwin')return false;
 await shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture');return true;
});
ipcMain.handle('m2p:host-reset',event=>{if(!trusted(event)||host.server||hostStarting)return false;++captureEpoch;capturePolicy.clear();sharing=null;return true;});
ipcMain.handle('m2p:host-sources',async event=>{
 if(!trusted(event))return {ok:false,sources:[]};
 try{
  const sources=await desktopCapturer.getSources({types:['screen'],thumbnailSize:{width:0,height:0}});
  if(!trusted(event))return {ok:false,sources:[]};
  return {ok:true,sources:sources.map(source=>({id:source.id,name:source.name})),...capabilities()};
 }catch(error){startup.record('capture-source-failed',error?.name||'Error');return {ok:false,sources:[],...capabilities()};}
});
ipcMain.handle('m2p:host-prepare',async(event,options)=>{
  if(!trusted(event)||host.server||hostStarting||!options||typeof options.source!=='string')return {ok:false};
  const epoch=++captureEpoch;capturePolicy.clear();
  let source;try{source=(await desktopCapturer.getSources({types:['screen'],thumbnailSize:{width:0,height:0}})).find(v=>v.id===options.source);}catch{return {ok:false,message:'Screen access needs attention. Check access and choose a screen again.'};}
  if(!trusted(event)||host.server||!source||epoch!==captureEpoch)return {ok:false};
  capturePolicy.prepare(source,{audio:options.audio===true&&process.platform!=='linux'});
  const display=screen.getAllDisplays().find(d=>String(d.id)===source.display_id)??screen.getPrimaryDisplay();
  const bounds=process.platform==='win32'?screen.dipToScreenRect(null,display.bounds):display.bounds;
  sharing={control:options.control===true&&adapter.available(),audio:options.audio===true,bounds};
  return {ok:true,control:sharing.control,audio:sharing.audio&&process.platform!=='linux'};
});
ipcMain.handle('m2p:host-start',async(event,options)=>{
  if(!trusted(event)||!sharing||!capturePolicy.approved||host.server||hostStarting)return {ok:false};
  const selected=sharing,epoch=captureEpoch;hostStarting=true;
  try{
    const control=selected.control?await adapter.start(selected.bounds):false;
    if(epoch!==captureEpoch){adapter.stop();return {ok:false};}
    const audio=selected.audio&&options?.audio===true&&(process.platform!=='linux'||spawnSync('which',['parec']).status===0);
    const state=await host.start({control,audio});
    activity();
    if(epoch!==captureEpoch){await host.stop();adapter.stop();return {ok:false};}
    if(audio&&process.platform==='linux'){
      pulse=spawn('parec',['--device=@DEFAULT_MONITOR@','--format=s16le','--rate=48000','--channels=2','--latency-msec=40'],{stdio:['ignore','pipe','ignore']});
      let rest=Buffer.alloc(0);pulse.stdout.on('data',data=>{rest=Buffer.concat([rest,data]);while(rest.length>=8192){host.pcm(rest.subarray(0,8192));rest=rest.subarray(8192);}});pulse.on('error',()=>deliver('notice','System audio needs the PulseAudio/PipeWire parec utility.'));
    }
    return {ok:true,viewers:state.viewers,control:state.control,audio:state.audio};
  }catch(error){await stopSharing();return {ok:false,message:error.code==='EADDRINUSE'?'Port 8765 is already in use. Stop the other host.':'Screen sharing could not start.'};}finally{hostStarting=false;}
});
ipcMain.handle('m2p:host-copy',event=>{if(!trusted(event)||!host.server)return false;try{clipboard.writeText(host.grant());return true;}catch{return false;}});
ipcMain.handle('m2p:host-stop',event=>{if(trusted(event))return stopSharing();});
ipcMain.handle('m2p:host-video',(event,data)=>trusted(event)&&host.server&&data instanceof Uint8Array&&data.byteLength<=4194304&&host.jpeg(Buffer.from(data)));
ipcMain.handle('m2p:host-audio',(event,data,rate,channels)=>trusted(event)&&host.server&&data instanceof Uint8Array&&data.byteLength<=65536&&host.pcm(Buffer.from(data),rate,channels));
app.whenReady().then(()=>{
  installCapturePermissions(session.defaultSession,capturePolicy,{record:(event,detail)=>startup.record('capture-'+event,JSON.stringify(detail))});
  window=new BrowserWindow({...windowOptions(startup.options.test),
    webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true}});
  startup.trackWindow(window);
  window.on('enter-full-screen',()=>deliver('fullscreen',true));
  window.on('leave-full-screen',()=>deliver('fullscreen',false));
  window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  window.webContents.on('will-navigate',event=>event.preventDefault());
  window.webContents.on('will-attach-webview',event=>event.preventDefault());
  window.on('blur',()=>{client.input({t:'cancel'});deliver('blur',true);});
  window.webContents.on('render-process-gone',()=>{stopSharing();client.disconnect();});
  window.on('closed',()=>{client.disconnect();stopSharing();window=null;});
  window.loadFile(path.join(__dirname,'renderer/index.html')).catch(error=>startup.fail('loading interface',error));
  if(!startup.options.test)nearby.start().catch(error=>{startup.record('discovery-start-failed',error?.code||error?.message);deliver('notice','Nearby discovery did not start.');});
}).catch(error=>startup.fail('creating application window',error));
app.on('window-all-closed',()=>app.quit());
let quitting=false;
app.on('before-quit',event=>{if(quitting)return;event.preventDefault();quitting=true;client.disconnect();Promise.all([nearby.stop(),stopSharing()]).catch(error=>startup.record('shutdown',error?.code||error?.message)).finally(()=>app.quit());});
