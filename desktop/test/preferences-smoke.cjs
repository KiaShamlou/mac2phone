'use strict';
process.env.M2P_UI_TEST='1';
const {app,BrowserWindow,ipcMain}=require('electron'),{once}=require('node:events');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict');
const {Host}=require('../core/host.cjs'),startup=require('../startup.cjs');
const profile=fs.mkdtempSync(path.join(os.tmpdir(),'m2p-preferences-test-'));
app.setPath('userData',profile);require('../main.cjs');
const host=new Host({platform:'win32',requireApproval:true}),sleep=ms=>new Promise(r=>setTimeout(r,ms));
let window;
const js=code=>window.webContents.executeJavaScript(code,true);
async function until(fn,label){for(let n=0;n<100;n++){if(await fn())return;await sleep(30);}throw Error('Timed out: '+label);}
app.whenReady().then(async()=>{
 try{
  window=BrowserWindow.getAllWindows()[0];if(window.webContents.isLoading())await once(window.webContents,'did-finish-load');
  await js('preferencesReady');
  assert.deepEqual(await js('mac2phone.preferences()'),{quality:'auto',fps:60,autoFullscreen:true});
  assert.deepEqual(await js('mac2phone.savePreferences({control:true,sound:true})'),{ok:false});
  await js(`$('video-quality').value='sharp';$('video-fps').value='30';$('video-quality').onchange();$('auto-fullscreen').click()`);
  await until(async()=>JSON.stringify(await js('mac2phone.preferences()'))===JSON.stringify({quality:'sharp',fps:30,autoFullscreen:false}),'saved choices');
  console.log('PASS production preferences IPC saves display choices and rejects persistent control/sound');
  window.reload();await once(window.webContents,'did-finish-load');await js('preferencesReady');
  assert.deepEqual(await js(`({quality:$('video-quality').value,fps:$('video-fps').value,fullscreen:$('auto-fullscreen').checked,control:$('control').checked,sound:$('audio').checked})`),{quality:'sharp',fps:'30',fullscreen:false,control:false,sound:false});
  assert.match(await js(`$('preferences-status').textContent`),/remembered/);
  console.log('PASS renderer reload restores stream preferences while Control and Sound remain off');
  const fullscreen=[];window.setFullScreen=on=>fullscreen.push(on);startup.options.test=false; // Intercept OS fullscreen; never create a Space.
  await js(`$('video-quality').value='auto';$('video-quality').onchange()`);
  await until(()=>js(`mac2phone.preferences().then(p=>p.quality==='auto')`),'Auto saved');
  await host.start({bind:'127.0.0.1',port:0});
  await js(`mac2phone.connect(${JSON.stringify(host.grant('127.0.0.1'))})`);
  await until(()=>js('connected'),'legacy session');assert.equal(fullscreen.at(-1),false);
  assert.equal(await js(`$('video-quality').value`),'fast');assert.equal(await js(`$('video-fps').value`),'60');
  await js(`$('disconnect').click()`);await until(()=>js('!connected'),'disconnect');
  assert.equal(await js(`$('video-quality').value`),'auto');assert.equal(await js(`$('video-fps').value`),'30');
  console.log('PASS compatibility adjustments do not overwrite remembered Auto/30 FPS preferences');
  await js(`$('auto-fullscreen').click()`);await until(()=>js(`mac2phone.preferences().then(p=>p.autoFullscreen)`),'fullscreen preference');
  await js(`mac2phone.connect(${JSON.stringify(host.grant('127.0.0.1'))})`);await until(()=>js('connected'),'second session');
  assert.equal(fullscreen.at(-1),true);
  await js(`$('disconnect').click()`);await until(()=>js('!connected'),'last disconnect');
  assert.equal(fullscreen.at(-1),false);
  console.log('PASS fullscreen preference controls the production session lifecycle without toggling OS fullscreen in the test');
  const stored=JSON.parse(fs.readFileSync(path.join(profile,'viewer-preferences.json'),'utf8'));
  assert.deepEqual(Object.keys(stored.preferences).sort(),['autoFullscreen','fps','quality']);
  const pending=[];ipcMain.removeHandler('m2p:control');ipcMain.handle('m2p:control',()=>new Promise(resolve=>pending.push(resolve)));
  const connected={state:'connected',capabilities:{control:true,platform:'win32'}};
  window.webContents.send('m2p:state',connected);await sleep(50);await js(`$('control').click()`);await until(()=>pending.length===1,'delayed enable');
  window.webContents.send('m2p:state',{state:'idle'});await sleep(50);pending.shift()(true);await sleep(50);
  assert.equal(await js(`controlling||$('control').checked`),false);
  window.webContents.send('m2p:state',connected);await sleep(50);await js(`$('control').click();$('control').click()`);await until(()=>pending.length===2,'reordered toggles');
  pending.pop()(false);pending.shift()(true);await sleep(50);assert.equal(await js(`controlling||$('control').checked`),false);
  await js(`$('control').click()`);await until(()=>pending.length===1,'pending control before release');
  await js(`canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',shiftKey:true}))`);await until(()=>pending.length===2,'local release');
  pending.shift()(true);pending.shift()(false);await sleep(50);assert.equal(await js(`controlling||$('control').checked`),false);
  console.log('PASS late control replies never re-enable input after disconnect, a newer toggle or Shift-Escape');
  console.log('PREFERENCES SMOKE: 5 groups passed');await host.stop();app.exit(0);
 }catch(error){console.error(error);await host.stop();app.exit(1);}
});
setTimeout(()=>{console.error('Preferences test timed out');app.exit(1);},25000).unref();
