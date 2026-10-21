'use strict';
// Capture only a dedicated synthetic WebContents, never the OS desktop.
const {app,BrowserWindow,session}=require('electron');
const {pathToFileURL}=require('node:url');
const path=require('node:path'),assert=require('node:assert/strict');
const {CapturePolicy,installCapturePermissions}=require('../core/capture-policy.cjs');
const baseline=process.argv.includes('--baseline');
app.setPath('userData',require('node:fs').mkdtempSync(path.join(require('node:os').tmpdir(),'m2p-capture-test-')));
app.whenReady().then(async()=>{
 try{
  const fixture=path.join(__dirname,'fixtures/capture.html'),page=pathToFileURL(fixture).href;
  const win=new BrowserWindow({show:false,width:640,height:480,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false}});
  await win.loadFile(fixture);const trace=[];
  const policy=new CapturePolicy({getContents:()=>win.webContents,page});
  if(baseline){
   session.defaultSession.setPermissionRequestHandler((contents,permission,callback,details)=>{trace.push({permission,mediaTypes:details.mediaTypes});callback(contents===win.webContents&&permission==='display-capture');});
   session.defaultSession.setPermissionCheckHandler((contents,permission)=>contents===win.webContents&&permission==='display-capture');
   session.defaultSession.setDisplayMediaRequestHandler((_r,callback)=>{throw Error('Baseline should deny before display handler');});
  }else{
   installCapturePermissions(session.defaultSession,policy,{record:(event,detail)=>trace.push({event,...detail})});
   policy.prepare(win.webContents.mainFrame);
   const denied=await win.webContents.executeJavaScript(`navigator.mediaDevices.getUserMedia({video:true}).then(s=>{s.getTracks().forEach(t=>t.stop());return 'unexpected';},e=>e.name)`,true);assert.equal(denied,'NotAllowedError');
  }
  const result=await win.webContents.executeJavaScript(`(async()=>{try{const stream=await navigator.mediaDevices.getDisplayMedia({video:true,audio:false});const video=document.createElement('video');video.muted=true;video.srcObject=stream;document.body.append(video);await video.play();const canvas=document.createElement('canvas');canvas.width=video.videoWidth;canvas.height=video.videoHeight;const ctx=canvas.getContext('2d');ctx.drawImage(video,0,0);const pixel=[...ctx.getImageData(2,2,1,1).data];const value={ok:true,width:video.videoWidth,height:video.videoHeight,pixel};stream.getTracks().forEach(t=>t.stop());return value;}catch(error){return {ok:false,name:error.name,message:error.message};}})()`,true);
  if(baseline){assert.equal(result.ok,false);assert.equal(result.name,'NotAllowedError');assert(trace.some(v=>v.permission==='media'&&v.mediaTypes.length===0));console.log('BASELINE CAPTURE: NotAllowedError reproduced; media permission was rejected before display selection');}
  else{
   assert.equal(result.ok,true,JSON.stringify({result,trace}));assert(result.width>0);assert(result.pixel.every((value,index)=>Math.abs(value-[20,90,180,255][index])<=8),'Synthetic frame pixels should survive capture color conversion');assert.equal(policy.approved,true);
   console.log('MODIFIED CAPTURE: selected synthetic screen captured; frame pixels verified; camera/microphone still denied');
   const camera=await win.webContents.executeJavaScript(`navigator.mediaDevices.getUserMedia({video:true}).then(s=>{s.getTracks().forEach(t=>t.stop());return 'unexpected';},e=>e.name)`,true);assert.equal(camera,'NotAllowedError');
  }
  console.log(JSON.stringify({result,trace}));app.exit(0);
 }catch(e){console.error(e);app.exit(1);}
});
setTimeout(()=>{console.error('Capture permission test timed out');app.exit(1);},20000).unref();
