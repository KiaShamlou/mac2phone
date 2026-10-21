'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {launchOptions,windowOptions,redact,createDiagnostics,missingRuntime,MAX_LOG}=require('../core/startup.cjs');
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'m2p-startup-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return dir;}
test('normal window is immediately visible; test windows stay hidden',()=>{
 assert.equal(windowOptions().show,true);assert.equal(windowOptions(true).show,false);
 assert.equal(windowOptions().minWidth,760);
});
test('launch flags keep diagnostic directory overrides exclusive to smoke tests',()=>{
 const dir=path.resolve('fixture');
 assert.deepEqual(launchOptions([],{}),{smoke:false,test:false,software:false,directory:null});
 assert.equal(launchOptions(['--m2p-diagnostics-dir='+dir],{}).directory,null);
 assert.equal(launchOptions(['--m2p-startup-smoke','--m2p-diagnostics-dir=relative'],{}).directory,null);
 assert.deepEqual(launchOptions(['--m2p-startup-smoke','--m2p-software-rendering','--m2p-diagnostics-dir='+dir],{}),{smoke:true,test:true,software:true,directory:dir});
 assert.equal(launchOptions([],{M2P_UI_TEST:'1'}).test,true);
});
test('startup logs redact pairing credentials and home paths',()=>{
 const credential='v3.00000000-0000-4000-8000-000000000001.'+'A'.repeat(43)+'.'+'B'.repeat(43);
 assert.equal(redact('Error mac2phone://192.0.2.1:8765#'+credential,'/home/test'),'Error [private pairing link]');
 assert.equal(redact(credential+' /home/test/app','/home/test'),'[pairing credentials] [home]/app');
 assert.equal(redact('x'.repeat(17000)).length,16000);
});
test('diagnostics persist results and rotate bounded logs',t=>{
 const dir=temporary(t),log=createDiagnostics(dir,{home:'/home/test',now:()=> 'FIXED'});
 assert.equal(log.available,true);log.record('launch','/home/test/app');
 assert.equal(fs.readFileSync(log.file,'utf8'),'FIXED launch [home]/app\n');
 fs.writeFileSync(log.file,'x'.repeat(MAX_LOG+1));log.record('rotated','ok');
 assert.equal(fs.statSync(log.file+'.previous').size,MAX_LOG+1);
 assert.equal(fs.readFileSync(log.file,'utf8'),'FIXED rotated ok\n');
 log.result({ok:true});assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir,'startup-result.json'))),{ok:true});
});
test('unwritable diagnostics never block startup',t=>{
 const file=path.join(temporary(t),'file');fs.writeFileSync(file,'not a folder');
 const log=createDiagnostics(path.join(file,'logs'));
 assert.equal(log.available,false);assert.doesNotThrow(()=>{log.record('launch');log.result({ok:true});});
});
test('EXE-only Windows distribution is rejected; complete runtime passes',t=>{
 const dir=temporary(t);fs.writeFileSync(path.join(dir,'Mac2Phone.exe'),'fixture');
 const missing=missingRuntime(dir);assert(missing.includes('resources/app.asar'));assert(missing.includes('ffmpeg.dll'));
 for(const file of missing){const target=path.join(dir,file);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,'fixture');}
 assert.deepEqual(missingRuntime(dir),[]);
});
