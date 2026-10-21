'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),tls=require('node:tls'),net=require('node:net');
const {once}=require('node:events');
const {Host,encode}=require('../core/host.cjs'),{normalizeInput}=require('../core/input.cjs'),{T,Parser}=require('../core/protocol.cjs'),{CIPHER}=require('../core/pairing.cjs');
const key=Buffer.alloc(32,65),identity='00000000-0000-4000-8000-000000000001';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function connect(host,{secret=key,magic='M2PJ'}={}){
 const socket=tls.connect({host:'127.0.0.1',port:host.port,minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER,rejectUnauthorized:false,pskCallback:()=>({identity,psk:secret})});
 socket.on('error',()=>{});const frames=[];const parser=new Parser((t,b)=>frames.push({t,b}));socket.on('data',b=>parser.push(b));
 await once(socket,'secureConnect');socket.write(magic);
 for(let i=0;i<100&&!frames.length;i++)await sleep(5);
 return{socket,frames};
}
test('semantic touch normalization bounds coordinates and rejects arbitrary commands',()=>{
 assert.deepEqual(normalizeInput({t:'tap',x:.25,y:.5}),{t:'click',x:.25,y:.5,b:0});
 assert.deepEqual(normalizeInput({t:'c',x:.5,y:1,b:1,n:2}),{t:'click',x:.5,y:1,b:1});
 assert.equal(normalizeInput({t:'c',x:0,y:0,b:3}),null);
 assert.equal(normalizeInput({t:'tap',x:2,y:0}),null);
 assert.equal(normalizeInput({t:'exec',s:'ignored'}),null);
 assert.equal(normalizeInput({t:'g',x:Infinity,y:0,b:0}),null);
});
test('desktop host authenticates native and desktop clients, bounds video credits, gates audio and releases input',async t=>{
 const input=[],host=new Host({input:v=>input.push(v),platform:'win32'});
 await host.start({port:0,bind:'127.0.0.1',key,identity,control:true,audio:true});t.after(()=>host.stop());
 const c=await connect(host,{magic:'M2P2'});t.after(()=>c.socket.destroy());
 const hello=JSON.parse(c.frames[0].b);assert.equal(hello.video,'jpeg');assert.equal(hello.platform,'win32');assert.equal(hello.control,true);
 const jpeg=Buffer.from([255,216,255,217]);for(let i=0;i<20;i++)host.jpeg(jpeg);await sleep(30);assert.equal(c.frames.filter(f=>f.t===T.jpeg).length,2);
 c.socket.write(encode(T.ack));await sleep(15);host.jpeg(jpeg);await sleep(20);assert.equal(c.frames.filter(f=>f.t===T.jpeg).length,3);
 host.pcm(Buffer.alloc(64));await sleep(15);assert.equal(c.frames.filter(f=>f.t===T.audioFrame).length,0);
 c.socket.write(encode(T.audioOn,Buffer.from([1])));await sleep(15);host.pcm(Buffer.alloc(64));await sleep(15);assert(c.frames.some(f=>f.t===T.audioFrame));assert(c.frames.some(f=>f.t===T.audioConfig));
 c.socket.write(encode(T.input,Buffer.from(JSON.stringify({t:'txt',s:'Hello سلام 👋'}))));await sleep(15);assert(input.some(v=>v.s==='Hello سلام 👋'));
 c.socket.destroy();await sleep(15);assert(input.some(v=>v.t==='cancel'));
});
test('desktop host rejects wrong keys, malformed frames and input while view-only; stop closes pending handshakes',async t=>{
 const input=[],host=new Host({input:v=>input.push(v)});await host.start({port:0,bind:'127.0.0.1',key,identity});t.after(()=>host.stop());
 await assert.rejects(connect(host,{secret:Buffer.alloc(32,66)}));
 const c=await connect(host);c.socket.write(encode(T.input,Buffer.from('{"t":"txt","s":"ignored"}')));await sleep(15);assert.equal(input.length,0);
 const closed=new Promise(r=>c.socket.once('close',r));c.socket.write(encode(T.ack,Buffer.from([1])));await closed;
 const pending=net.connect(host.port,'127.0.0.1');await once(pending,'connect');pending.on('error',()=>{});const gone=new Promise(r=>pending.once('close',r));await host.stop();await gone;assert.equal(host.state().active,false);assert.equal(host.key,null);
});

test('external input helper resolves outside ASAR while source development remains unchanged',()=>{
 const path=require('node:path'),{helperPath}=require('../core/platform-input.cjs');
 assert.equal(helperPath(path.join('/tmp','app.asar','core')),path.join('/tmp','app.asar.unpacked','native','input-windows.ps1'));
 assert.equal(helperPath(path.join('/tmp','desktop','core')),path.join('/tmp','desktop','native','input-windows.ps1'));
});
