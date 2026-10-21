'use strict';
// Exercise production IPC, permission policy, renderer and encrypted transport.
// Substitute the OS display source with a dedicated synthetic app frame,
// and bind the sharing listener to loopback on an ephemeral port.
process.env.M2P_UI_TEST='1';
const {app,BrowserWindow,desktopCapturer,nativeImage}=require('electron');
const path=require('node:path'),fs=require('node:fs'),os=require('node:os'),assert=require('node:assert/strict');
const {Host}=require('../core/host.cjs'),{Session}=require('../core/session.cjs');
const start=Host.prototype.start;let host,starts=0,viewer,windowUnderTest;
Host.prototype.start=function(options){host=this;starts++;return start.call(this,{...options,bind:'127.0.0.1',port:0});};
app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'m2p-share-integration-')));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
app.whenReady().then(async()=>{
 try{
  const sourceWindow=new BrowserWindow({show:false,width:1920,height:1080,useContentSize:true,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  await sourceWindow.loadFile(path.join(__dirname,'fixtures/capture.html'));
  const source=sourceWindow.webContents.mainFrame;
  desktopCapturer.getSources=async()=>[{id:'fixture:display',name:'Synthetic display'}];
  const {CapturePolicy}=require('../core/capture-policy.cjs'),prepare=CapturePolicy.prototype.prepare;
  CapturePolicy.prototype.prepare=function(selection,options){assert.equal(selection.id,'fixture:display');return prepare.call(this,source,options);};
  require('../main.cjs');await sleep(200);
  const win=BrowserWindow.getAllWindows().find(w=>w!==sourceWindow);windowUnderTest=win;win.webContents.setBackgroundThrottling(false);
  const js=(code,gesture=false)=>win.webContents.executeJavaScript(code,gesture);
  async function until(code){for(let i=0;i<150;i++){if(await js(code))return;await sleep(30);}throw Error('Timed out: '+code);}
  await until(`typeof mac2phone==='object'&&document.readyState==='complete'`);
  assert.deepEqual(await js('mac2phone.hostStart({audio:false})'),{ok:false});assert.equal(starts,0);
  await js(`m2pUI.show('share');document.getElementById('share-sources').click()`,true);
  await until(`!document.getElementById('share-preview').disabled`);
  await js(`document.getElementById('share-preview').click()`,true);
  await until(`!document.getElementById('share-start').disabled`);
  assert.equal(starts,0);assert.equal(await js(`document.getElementById('share-video').videoWidth>0`),true);
  await until(`document.getElementById('share-video').srcObject.getVideoTracks()[0].getSettings().width<=960&&document.getElementById('share-video').srcObject.getVideoTracks()[0].getSettings().frameRate<=15`);
  console.log('PASS actual display-capture constraints reduce synthetic local preview to <=960px and <=15 FPS');
  console.log('PASS production screen-selection IPC and real display permission create a local-only synthetic preview');
  await js(`document.getElementById('share-start').click()`,true);
  await until(`document.getElementById('share-badge').textContent==='Sharing'`);
  assert.equal(starts,1);assert.equal(host.requireApproval,true);assert.equal(host.server.address().address,'127.0.0.1');
  viewer=new Session();let jpeg,connected=false;viewer.on('state',s=>{if(s.state==='connected')connected=true;});viewer.on('video',data=>{jpeg=data;viewer.ackVideo();});viewer.connect(host.grant('127.0.0.1'));
  for(let i=0;i<150&&!jpeg;i++)await sleep(30);assert.equal(connected,true);assert(jpeg?.length>100);assert.equal(jpeg[0],255);assert.equal(jpeg[1],216);
  for(let i=0;i<150&&nativeImage.createFromBuffer(jpeg).getSize().width<=960;i++)await sleep(30);
  const size=nativeImage.createFromBuffer(jpeg).getSize();assert(size.width>960&&size.width<=1920);
  console.log(`MEASURED compatibility demand restores real capture to ${size.width}×${size.height}`);
  console.log('PASS explicit Start sharing sends real synthetic-page JPEG frames over approved TLS loopback transport');
  await js(`document.getElementById('share-stop').click()`,true);await until(`document.getElementById('sidebar-sharing').hidden`);
  assert.equal(host.server,null);assert.equal(await js(`document.getElementById('share-video').srcObject===null`),true);
  viewer.disconnect();console.log('PASS Stop sharing releases local capture and closes the production host');console.log('SHARING INTEGRATION: 4 groups passed');app.exit(0);
 }catch(e){console.error(e);if(windowUnderTest)console.error(await windowUnderTest.webContents.executeJavaScript(`({status:document.getElementById('share-status').textContent,error:document.getElementById('share-error').textContent,video:{ready:document.getElementById('share-video').readyState,width:document.getElementById('share-video').videoWidth,paused:document.getElementById('share-video').paused}})`));const log=path.join(app.getPath('userData'),'startup-test-logs/startup.log');if(fs.existsSync(log))console.error(fs.readFileSync(log,'utf8'));viewer?.disconnect();await host?.stop();app.exit(1);}
});
setTimeout(()=>{console.error('Sharing integration timed out');viewer?.disconnect();app.exit(1);},25000).unref();
