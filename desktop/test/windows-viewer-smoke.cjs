'use strict';
// Real Mac renderer/IPC/approval/TLS against a synthetic Windows-protocol host.
// The fixture records input in memory and sends generated pixels and silence.
process.env.M2P_UI_TEST='1';
const {app,BrowserWindow,nativeImage}=require('electron');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {once}=require('node:events');
const application=process.env.M2P_VIEWER_APP||path.resolve(__dirname,'..');
const {Host}=require(path.join(application,'core/host.cjs'));
const nearbyModule=require(path.join(application,'core/nearby.cjs'));
const RealNearby=nearbyModule.Nearby;
let viewer;
// Keep normal application logic; replace only the test's discovery inventory.
nearbyModule.Nearby=class extends RealNearby {
 constructor(options){super(options);viewer=this;}
};
app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'m2p-windows-viewer-')));
require(path.join(application,'main.cjs'));
const input=[];
const host=new Host({platform:'win32',requireApproval:true,input:value=>input.push(value)});
let approve,request,frames,window;
const peer=new RealNearby({name:'Windows test display',platform:'win32',approve:value=>{
 request=value;return new Promise(resolve=>approve=resolve);
}});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(predicate,label){
 for(let i=0;i<120;i++){if(await predicate())return;await sleep(50);}
 throw Error('Timed out: '+label);
}
const js=source=>window.webContents.executeJavaScript(source,true);
const deadline=setTimeout(()=>{console.error('Windows viewer test timed out');app.exit(1);},30000);
app.whenReady().then(async()=>{
 let exit=0;
 try{
  window=BrowserWindow.getAllWindows()[0];
  if(window.webContents.isLoading())await once(window.webContents,'did-finish-load');
  await host.start({bind:'127.0.0.1',port:0,control:true,audio:true});
  await peer.start({bind:'127.0.0.1',discover:false});
  viewer.found({txt:{v:'1',id:peer.id,name:peer.name,platform:'win32'},addresses:['127.0.0.1'],port:peer.port});
  await until(()=>js(`document.querySelector('.device-button strong')?.textContent==='Windows test display'`),'device card');
  await js(`document.querySelector('.device-button').click()`);
  await until(()=>approve&&js(`document.getElementById('nearby-status').textContent.includes(${JSON.stringify(request.code)})`),'matching verification code');
  assert.equal(host.clients.size,0,'No stream before the host accepts');
  assert.equal(await js(`document.getElementById('screen').hidden`),true);
  assert.equal(await js(`document.getElementById('control').disabled`),true);
  console.log('PASS Windows device card, real request and matching code; no connection before approval');

  approve(host.grant('127.0.0.1'));
  await until(()=>js(`document.getElementById('status').textContent==='Paired · encrypted'`),'approved TLS session');
  const bitmap=Buffer.alloc(96*64*4);
  for(let i=0;i<bitmap.length;i+=4){bitmap[i]=180;bitmap[i+1]=90;bitmap[i+2]=45;bitmap[i+3]=255;}
  const jpeg=nativeImage.createFromBitmap(bitmap,{width:96,height:64}).toJPEG(95);
  frames=setInterval(()=>{host.jpeg(jpeg);host.pcm(Buffer.alloc(1920));},40);
  await until(()=>js(`document.getElementById('screen').width===96`),'JPEG rendering');
  assert.deepEqual(await js(`({height:canvas.height,hidden:canvas.hidden,control:$('control').checked,audio:$('audio').checked,cmd:$('cmd-map').checked})`),{height:64,hidden:false,control:false,audio:false,cmd:false});
  assert.equal(await js(`$('health-label').textContent`),'Compatibility video');
  assert.equal(await js(`$('video-fps').disabled`),true);
  const pixel=await js(`[...ctx.getImageData(48,32,1,1).data]`);
  assert(pixel.every((value,index)=>Math.abs(value-[45,90,180,255][index])<8),'Generated JPEG pixels match');
  assert.equal(input.some(value=>value.t!=='cancel'),false);
  console.log('PASS accepted one-use grant, encrypted Windows protocol and JPEG rendering; view-only by default');

  await js(`$('control').click()`);
  await until(()=>js(`controlling===true`),'control opt-in');
  await js(`{
   const r=canvas.getBoundingClientRect();
   canvas.dispatchEvent(new PointerEvent('pointermove',{clientX:r.left+r.width/2,clientY:r.top+r.height/2,bubbles:true}));
   canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'c',ctrlKey:true,bubbles:true}));
   canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
   $('text').value='Mac to Windows fixture سلام';$('text-form').requestSubmit();
   canvas.dispatchEvent(new WheelEvent('wheel',{deltaY:40,bubbles:true,cancelable:true}));
  }`);
  await until(()=>input.some(value=>value.t==='s')&&input.some(value=>value.t==='m'),'input delivery');
  assert(input.some(value=>value.t==='m'&&Math.abs(value.x-.5)<.01&&Math.abs(value.y-.5)<.01));
  assert(input.some(value=>value.t==='key'&&value.k==='c'&&value.m.length===1&&value.m[0]==='ctrl'));
  assert(input.some(value=>value.t==='key'&&value.k==='right'));
  assert(input.some(value=>value.t==='txt'&&value.s==='Mac to Windows fixture سلام'));
  assert(input.some(value=>value.t==='s'&&value.dy===-40));
  console.log('PASS Mac viewer pointer, scroll, Windows Control shortcut, arrow key and Unicode text delivery');

  await js(`$('audio').click()`);
  await until(()=>js(`audioContext?.state==='running'&&format?.rate===48000&&audioAt>0`),'48 kHz sound scheduling');
  await js(`canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',shiftKey:true,bubbles:true}))`);
  assert.equal(await js(`$('control').checked`),false);
  await until(()=>input.some(value=>value.t==='cancel'),'input release');
  await js(`$('disconnect').click()`);
  await until(()=>host.state().viewers===0&&js(`canvas.hidden&&$('audio').checked===false&&audioAt===0`),'disconnect cleanup');
  console.log('PASS opt-in PCM sound playback, Shift-Escape control release and disconnect cleanup');
  console.log('WINDOWS VIEWER: 4 groups passed; synthetic host only; no real desktop capture or input');
 }catch(error){exit=1;console.error(error);}
 finally{
  clearInterval(frames);clearTimeout(deadline);approve?.(null);
  await peer.stop();await host.stop();app.exit(exit);
 }
}).catch(error=>{console.error(error);app.exit(1);});
