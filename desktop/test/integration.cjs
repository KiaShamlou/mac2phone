'use strict';
// Only the synthetic loopback fixture is exercised; never controls a real desktop.
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const tls=require('node:tls'),net=require('node:net'),assert=require('node:assert/strict');
const {Session}=require('../core/session.cjs');
const {T,frame,Parser}=require('../core/protocol.cjs');
const {CIPHER}=require('../core/pairing.cjs');
const port=Number(process.env.M2P_TEST_PORT||18765);
const link=(key=65,id=1)=>`mac2phone://127.0.0.1:${port}#v2.00000000-0000-4000-8000-${String(id).padStart(12,'0')}.${Buffer.alloc(32,key).toString('base64url')}`;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const timeout=(promise,ms=8000)=>Promise.race([promise,new Promise((_,r)=>{const t=setTimeout(()=>r(new Error('Test timed out')),ms);t.unref();})]);
let output='';const fixture=spawn(process.argv[2],[String(port)],{stdio:['ignore','pipe','pipe']});
fixture.stdout.on('data',b=>output+=b);fixture.stderr.on('data',b=>output+=b);
const client=new Session();
function open({key=65,id=1,magic='M2PJ',plain=false}={}){
  return new Promise(resolve=>{
    let ready=false,settled=false;
    const socket=plain?net.connect({host:'127.0.0.1',port}):tls.connect({host:'127.0.0.1',port,minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER,
      pskCallback:()=>({identity:`00000000-0000-4000-8000-${String(id).padStart(12,'0')}`,psk:Buffer.alloc(32,key)}),checkServerIdentity:()=>undefined});
    const finish=()=>{if(settled)return;settled=true;socket.destroy();resolve(ready);};
    socket.on(plain?'connect':'secureConnect',()=>socket.write(Buffer.from(magic)));
    const parser=new Parser((type,body)=>{if(type===T.hello){const hello=JSON.parse(body);ready=hello.version===2&&(magic==='M2P2'?hello.video==='native':hello.video==='jpeg');finish();}});
    socket.on('data',b=>{try{parser.push(b);}catch{finish();}});socket.on('error',finish);socket.on('close',finish);
    socket.setTimeout(2500,finish);
  });
}
(async()=>{
  for(let i=0;i<100&&!output.includes('READY');i++)await sleep(50);
  assert.match(output,/READY/);
  const video=once(client,'video'),audio=once(client,'audio');
  const connected=new Promise(resolve=>client.on('state',s=>{if(s.state==='connected')resolve(s);}));
  client.connect(link());const state=await timeout(connected);
  assert.equal(state.capabilities.control,true);
  const [jpeg]=await timeout(video);assert.equal(jpeg[0],255);client.ackVideo();
  client.setControl(true);client.input({t:'m',x:.25,y:.75});client.input({t:'txt',s:'fixture only'});client.input({t:'key',k:'c',m:['cmd']});
  client.setAudio(true);const [pcm]=await timeout(audio);assert.equal(pcm.length,64);client.ackAudio();
  const ping=once(client,'latency');await timeout(ping);
  await sleep(100);assert.match(output,/fixture only/);assert.match(output,/"k":"c"/);assert.match(output,/"x":0.25/);
  console.log('PASS paired Swift host ↔ Node desktop: JPEG, mouse, keyboard, PCM audio and ping');
  assert.equal(await open({key:66}),false);assert.equal(await open({id:2}),false);
  assert.equal(await open({plain:true}),false);assert.equal(await open({magic:'M2P1'}),false);
  console.log('PASS wrong key, wrong identity, plaintext and protocol-v1 rejected');
  assert.equal(await open({magic:'M2P2'}),true);
  const native=spawn(process.argv[2],['--native-client',String(port)]);
  let nativeOutput='';native.stdout.on('data',b=>nativeOutput+=b);
  const [code]=await timeout(once(native,'exit'));assert.equal(code,0);assert.match(nativeOutput,/PASS Apple Network/);
  console.log('PASS authenticated native protocol hello and Apple Network TLS client');
  client.send(T.input,Buffer.from('{"t":"fixture-rotate"}'));
  for(let i=0;i<40&&!output.includes('ROTATED');i++)await sleep(50);
  assert.match(output,/ROTATED/);await sleep(400);
  assert.equal(client.ready,false);assert.equal(await open(),false);assert.equal(await open({key:66,id:2}),true);
  assert.match(output,/"t":"cancel"/);
  console.log('PASS rotation disconnects old sessions, rejects old key, accepts new key and releases input');
  console.log('INTEGRATION: 4 groups passed; real desktop capture/input were never invoked');
})().catch(error=>{console.error(error);console.error(output);process.exitCode=1;}).finally(()=>{client.disconnect();fixture.kill();});
