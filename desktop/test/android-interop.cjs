'use strict';
const {spawn}=require('node:child_process'),assert=require('node:assert/strict'),tls=require('node:tls');
const {Host,encode}=require('../core/host.cjs'),{Parser,T}=require('../core/protocol.cjs'),{CIPHER}=require('../core/pairing.cjs');
const cp=process.argv[2],java=process.env.JAVA_HOME?process.env.JAVA_HOME+'/bin/java':'java';
const key=Buffer.alloc(32,65),identity='00000000-0000-4000-8000-000000000001';
const link=port=>`mac2phone://127.0.0.1:${port}#v2.${identity}.${key.toString('base64url')}`;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
 let host,child,timer;try{
 const input=[];host=new Host({input:v=>input.push(v)});await host.start({port:0,bind:'127.0.0.1',key,identity,control:true,audio:true});
 timer=setInterval(()=>{host.jpeg(Buffer.from([255,216,255,217]));host.pcm(Buffer.alloc(64));},30);
 child=spawn(java,['-cp',cp,'io.mac2phone.app.InteropFixture','client',link(host.port)],{stdio:['ignore','pipe','inherit']});let output='';child.stdout.on('data',b=>output+=b);
 assert.equal(await new Promise(r=>child.once('exit',r)),0);assert.match(output,/PASS JVM TLS client/);assert(input.some(v=>v.s==='JVM fixture سلام'));console.log('PASS JVM/Bouncy Castle client ↔ desktop TLS host: JPEG, PCM, Unicode');
 clearInterval(timer);await host.stop();host=null;
 child=spawn(java,['-cp',cp,'io.mac2phone.app.InteropFixture','host',link(18769)],{stdio:['ignore','pipe','inherit']});let log='';child.stdout.on('data',b=>log+=b);
 for(let i=0;i<200&&!log.includes('READY');i++)await sleep(20);assert.match(log,/READY/);
 const socket=tls.connect({host:'127.0.0.1',port:18769,ciphers:CIPHER,minVersion:'TLSv1.2',maxVersion:'TLSv1.2',rejectUnauthorized:false,pskCallback:()=>({identity,psk:key})});
 await new Promise((r,j)=>{socket.once('secureConnect',r);socket.once('error',j)});
 let jpeg=false,audio=false,hello=false;const parser=new Parser((t,b)=>{if(t===T.hello){hello=JSON.parse(b).platform==='android';socket.write(encode(T.audioOn,Buffer.from([1])));socket.write(encode(T.input,Buffer.from('{"t":"txt","s":"fixture"}')));}if(t===T.jpeg){jpeg=true;socket.write(encode(T.ack));}if(t===T.audioFrame)audio=true;});socket.on('data',b=>parser.push(b));socket.write('M2P2');
 for(let i=0;i<200&&!(jpeg&&audio&&hello&&log.includes('INPUT OK'));i++)await sleep(20);
 assert(hello&&jpeg&&audio&&log.includes('INPUT OK'));socket.destroy();child.kill();console.log('PASS desktop TLS client ↔ Android JVM host: native hello, JPEG, PCM, input');
 }finally{clearInterval(timer);child?.kill();await host?.stop();}
})().catch(e=>{console.error(e);process.exitCode=1;});
