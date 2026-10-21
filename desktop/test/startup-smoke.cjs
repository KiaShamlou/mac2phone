'use strict';
// Launch the real bootstrap/UI without discovery, capture, or remote input.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawn}=require('node:child_process');
const assert=require('node:assert/strict');
const args=process.argv.slice(2),option=name=>args.find(a=>a.startsWith(name+'='))?.slice(name.length+1);
const executable=option('--executable')?path.resolve(option('--executable')):require('electron');
const application=option('--app')?path.resolve(option('--app')):option('--executable')?null:path.resolve(__dirname,'..');
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'m2p-launch-smoke-'));
const env={...process.env};delete env.ELECTRON_RUN_AS_NODE;
const parameters=[...(application?[application]:[]),'--m2p-startup-smoke','--m2p-diagnostics-dir='+directory,...(args.includes('--software')?['--m2p-software-rendering']:[])];
const child=spawn(executable,parameters,{env,stdio:['ignore','pipe','pipe']});
let output='',timedOut=false;
for(const stream of [child.stdout,child.stderr])stream.on('data',data=>{output=(output+data).slice(-16000);});
const timer=setTimeout(()=>{timedOut=true;child.kill('SIGKILL');},35000);
child.on('error',error=>{clearTimeout(timer);console.error(error);process.exitCode=1;});
child.on('close',(code,signal)=>{
 clearTimeout(timer);
 try{
  assert.equal(timedOut,false,'Electron launch timed out');assert.equal(signal,null);
  const result=JSON.parse(fs.readFileSync(path.join(directory,'startup-result.json'),'utf8'));
  if(args.includes('--expect-failure')){assert.equal(code,1);assert.equal(result.ok,false);assert.equal(result.phase,option('--phase'));console.log('PASS startup failure produces diagnostic result and exit 1');}
  else{assert.equal(code,0,output);assert.equal(result.ok,true);assert.equal(result.sandbox,true);assert.equal(result.contextIsolation,true);assert.equal(result.ui.bridge,'object');assert.equal(result.ui.node,'undefined');assert.equal(result.ui.nearby,true);assert.equal(result.ui.controlsDisabled,true);assert.equal(result.softwareRendering,args.includes('--software'));console.log('PASS real bootstrap, renderer, preload, sandbox, TLS and discovery dependency');}
  console.log(JSON.stringify(result));
 }catch(error){console.error(error);console.error(output);process.exitCode=1;}
 finally{console.log('Diagnostics: '+directory);}
});
