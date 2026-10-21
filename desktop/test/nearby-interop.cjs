'use strict';
const {spawn}=require('node:child_process'),{once}=require('node:events'),net=require('node:net'),assert=require('node:assert/strict');
const {Nearby}=require('../core/nearby.cjs'),{Host}=require('../core/host.cjs'),{Session}=require('../core/session.cjs');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
function child(command,args){const p=spawn(command,args,{stdio:['ignore','pipe','pipe']});p.log='';p.stderr.on('data',b=>p.log+=b);p.stdout.on('data',b=>p.log+=b);p.on('error',()=>{});return p;}
async function until(fn){for(let i=0;i<150;i++){if(fn())return;await sleep(50);}throw Error('Fixture did not respond');}
(async()=>{const [swift,classpath]=process.argv.slice(2);
 for(const [label,cmd,prefix]of[['Apple',swift,[]],['Android JVM','java',['-cp',classpath,'io.mac2phone.app.NearbyFixture']]]){
  const host=new Host({requireApproval:true});await host.start({port:0,bind:'127.0.0.1'});let hostCode;const nearby=new Nearby({name:'Node fixture',platform:'linux',approve:async r=>{hostCode=r.code;return host.grant('127.0.0.1');}});await nearby.start({bind:'127.0.0.1',discover:false});
  let p=child(cmd,[...prefix,'client',String(nearby.port)]);
  try{await until(()=>p.log.includes(label==='Apple'?'LINK ':'PASS Java'));assert.match(p.log,new RegExp(`CODE ${hostCode}`));if(label==='Apple'){const link=p.log.match(/LINK (mac2phone:\/\/\S+)/)[1],session=new Session();const ready=new Promise((resolve,reject)=>session.on('state',s=>{if(s.state==='connected')resolve();if(s.state==='error')reject(Error(s.message));}));session.connect(link);await ready;session.disconnect();}console.log(`PASS ${label} requester → Node approval, matching code, one-use grant and TLS`);}finally{p.kill();await nearby.stop();await host.stop();}
  p=child(cmd,[...prefix,'host',String(await port())]);const client=new Nearby({name:'Node fixture',platform:'linux'});let code;client.on('request-state',r=>code=r.code);
  try{await until(()=>p.log.includes('READY '));const requestPort=Number(p.log.match(/READY (\d+)/)[1]);client.peers.set('fixture',{name:label,host:'127.0.0.1',port:requestPort});const link=await client.request('fixture');assert.match(p.log,new RegExp(`CODE ${code}`));const session=new Session();const ready=new Promise((resolve,reject)=>session.on('state',s=>{if(s.state==='connected')resolve();if(s.state==='error')reject(Error(s.message));}));session.connect(link);await ready;session.disconnect();console.log(`PASS Node requester → ${label} approval, matching code, one-use grant and TLS`);}catch(e){console.error(p.log.replace(/mac2phone:\/\/\S+/g,'[synthetic grant]'));throw e;}finally{p.kill();await client.stop();}
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
