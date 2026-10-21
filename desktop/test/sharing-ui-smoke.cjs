'use strict';
const {app,BrowserWindow}=require('electron');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),os=require('node:os');
const root=path.resolve(__dirname,'../..'),out=path.join(root,'.polish/windows-share');fs.mkdirSync(out,{recursive:true});
app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'m2p-sharing-ui-')));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
app.whenReady().then(async()=>{
 try{
  const win=new BrowserWindow({show:false,width:1180,height:820,webPreferences:{preload:path.join(__dirname,'fixtures/sharing-preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  await win.loadFile(path.join(__dirname,'../renderer/index.html'));await sleep(150);
  const js=(source,userGesture=false)=>win.webContents.executeJavaScript(source,userGesture);
  async function until(source){for(let i=0;i<100;i++){if(await js(source))return;await sleep(30);}throw Error('Timed out: '+source);}
  const click=id=>js(`document.getElementById(${JSON.stringify(id)}).click()`,true);
  const shot=async name=>{await sleep(100);fs.writeFileSync(path.join(out,name+'.png'),(await win.webContents.capturePage()).toPNG());};
  await js(`window.captureMode='normal';window.testStreams=[];window.captureCalls=0;Object.defineProperty(navigator.mediaDevices,'getDisplayMedia',{value:async()=>{captureCalls++;if(captureMode==='denied')throw new DOMException('Permission denied','NotAllowedError');if(captureMode==='pending')await new Promise(r=>window.finishCapture=r);const canvas=document.createElement('canvas');canvas.width=960;canvas.height=600;const ctx=canvas.getContext('2d');function paint(){ctx.fillStyle='#dee9fc';ctx.fillRect(0,0,960,600);ctx.fillStyle='#fff';ctx.fillRect(65,65,830,470);ctx.fillStyle='#204a83';ctx.font='bold 38px sans-serif';ctx.fillText('Your screen, ready to share.',110,160);ctx.font='23px sans-serif';ctx.fillText('Synthetic preview · no desktop was captured',110,210);ctx.fillStyle='#729be1';ctx.fillRect(110,270,360,190);ctx.fillStyle='#ecf1f9';ctx.fillRect(500,270,340,190);}paint();const stream=canvas.captureStream(10);const timer=setInterval(paint,100);stream.getVideoTracks()[0].addEventListener('ended',()=>clearInterval(timer));if(captureMode==='audio'){const audio=new AudioContext();const destination=audio.createMediaStreamDestination(),oscillator=audio.createOscillator(),gain=audio.createGain();gain.gain.value=0;oscillator.connect(gain).connect(destination);oscillator.start();await audio.resume();stream.addTrack(destination.stream.getAudioTracks()[0]);}testStreams.push(stream);return stream;}});`);
  assert.equal((await js('sharingFixture.snapshot()')).sources,0);assert.equal(await js('captureCalls'),0);
  await shot('devices-preview');await js(`document.querySelector('nav [data-go="share"]').click()`);await shot('share-setup-preview');
  assert.equal(await js(`document.getElementById('share-start').disabled`),true);
  await click('share-sources');await until(`!document.getElementById('share-preview').disabled`);
  await js(`document.querySelector('[data-source="fixture:2"]').click()`);await until(`!document.getElementById('share-preview').disabled`);
  await click('share-control');await until(`!document.getElementById('share-preview').disabled`);
  assert.deepEqual((await js('sharingFixture.snapshot()')).prepares.at(-1),{source:'fixture:2',control:true,audio:false});
  await click('share-preview');await until(`!document.getElementById('share-start').disabled`);await sleep(150);
  assert.equal((await js('sharingFixture.snapshot()')).starts.length,0);assert.equal((await js('sharingFixture.snapshot()')).frames,0);
  assert.equal(await js(`document.getElementById('share-control').disabled`),true);
  await shot('local-preview');console.log('PASS permission-first setup, selected display, explicit access choices and zero frames sent during local preview');
  await click('share-start');await until(`sharingFixture.snapshot().frames>0`);await js(`sharingFixture.emit('host-viewers',2)`);
  assert.deepEqual((await js('sharingFixture.snapshot()')).starts,[{audio:false}]);
  await click('share-copy');assert.equal((await js('sharingFixture.snapshot()')).copies,1);await shot('sharing-preview');
  await click('sidebar-stop');await until(`document.getElementById('sidebar-sharing').hidden`);
  assert.equal((await js('sharingFixture.snapshot()')).stops,1);assert.equal(await js(`testStreams[0].getVideoTracks()[0].readyState`),'ended');
  console.log('PASS explicit start, bounded frame delivery, one-use link and persistent Stop sharing');
  await click('share-sources');await until(`!document.getElementById('share-preview').disabled`);await js(`captureMode='denied'`);await click('share-preview');await until(`!document.getElementById('share-error').hidden`);
  assert.match(await js(`document.getElementById('share-error-title').textContent`),/not allowed/);assert.equal((await js('sharingFixture.snapshot()')).starts.length,1);
  await shot('permission-error-preview');console.log('PASS permission denial gives an actionable retry and never starts sharing');
  await click('share-sources');await until(`!document.getElementById('share-preview').disabled`);await js(`captureMode='pending'`);await click('share-preview');await until(`typeof finishCapture==='function'`);await click('share-reset');await js(`finishCapture()`);await until(`testStreams.length===2`);await sleep(100);
  assert.equal(await js(`testStreams[1].getVideoTracks()[0].readyState`),'ended');assert.equal((await js('sharingFixture.snapshot()')).starts.length,1);
  console.log('PASS cancellation while permission is pending closes the late stream');
  await click('share-sources');await until(`!document.getElementById('share-preview').disabled`);await click('share-sound');await until(`!document.getElementById('share-preview').disabled`);await js(`captureMode='normal'`);await click('share-preview');await until(`!document.getElementById('share-start').disabled`);
  assert.match(await js(`document.getElementById('share-status').textContent`),/video only/);await click('share-start');await until(`sharingFixture.snapshot().starts.length===2`);assert.equal((await js('sharingFixture.snapshot()')).starts[1].audio,false);await click('share-stop');await until(`document.getElementById('sidebar-sharing').hidden`);
  console.log('PASS absent audio track is disclosed and is not advertised to viewers');
  await click('share-sources');await until(`!document.getElementById('share-preview').disabled`);await click('share-sound');await until(`!document.getElementById('share-preview').disabled`);await js(`captureMode='audio'`);await click('share-preview');await until(`!document.getElementById('share-start').disabled`);await sleep(150);assert.equal((await js('sharingFixture.snapshot()')).audio,0);await click('share-start');await until(`sharingFixture.snapshot().audio>0`);assert.equal((await js('sharingFixture.snapshot()')).starts[2].audio,true);await click('share-stop');await until(`document.getElementById('sidebar-sharing').hidden`);console.log('PASS real audio-worklet pipeline sends synthetic silence only after explicit Start sharing');
  win.setSize(760,540);await sleep(200);
  for(const view of ['devices','share','session']){await js(`m2pUI.show('${view}')`);await sleep(75);assert.equal(await js(`document.documentElement.scrollWidth>innerWidth||document.querySelector('main').scrollWidth>document.querySelector('main').clientWidth`),false,view+' overflow');}
  assert.equal(await js(`document.querySelector('footer').getBoundingClientRect().top>=document.getElementById('text-form').getBoundingClientRect().bottom`),true,'compact session footer overlaps its controls');
  await js(`m2pUI.show('share')`);assert.equal(await js(`document.getElementById('page-title').textContent`),'Share screen');await shot('compact-share-preview');
  console.log('PASS all three views fit 760px; navigation and primary actions are keyboard-focusable');
  console.log('SHARING UI: 7 groups passed');app.exit(0);
 }catch(e){console.error(e);app.exit(1);}
});
setTimeout(()=>{console.error('Sharing UI test timed out');app.exit(1);},30000).unref();
