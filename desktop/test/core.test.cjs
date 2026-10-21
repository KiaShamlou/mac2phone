'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {T,frame,Parser,audioFormat}=require('../core/protocol.cjs');
const {parsePairing,CIPHER}=require('../core/pairing.cjs');
const {validateInput}=require('../core/input.cjs');
const {Session}=require('../core/session.cjs');
const link='mac2phone://192.168.1.20:8765#v2.00000000-0000-4000-8000-000000000001.'+Buffer.alloc(32,65).toString('base64url');
function hostFrame(type,data){const h=Buffer.alloc(5);h[0]=type;h.writeUInt32BE(data.length,1);return Buffer.concat([h,data]);}
test('pairing parses host, port, identity and exactly 256 bits',()=>{
  const p=parsePairing(link);assert.equal(p.host,'192.168.1.20');assert.equal(p.port,8765);assert.equal(p.key.length,32);
  assert.equal(p.identity,'00000000-0000-4000-8000-000000000001');assert.equal(CIPHER,'ECDHE-PSK-CHACHA20-POLY1305');
});
test('hostname and bracketed IPv6 endpoints',()=>{
  assert.equal(parsePairing(link.replace('192.168.1.20','mac.local')).host,'mac.local');
  assert.equal(parsePairing(link.replace('192.168.1.20','[::1]')).host,'::1');
});
test('rejects insecure, ambiguous, truncated and overlong pairing links',()=>{
  for(const bad of ['',null,{},'a'.repeat(1025),link.replace('mac2phone:','http:'),link.replace('8765','0'),link.replace('8765','65536'),link.replace('//','//user@'),link.replace('#','/#'),link.replace('#','?key='),link+'=',link.slice(0,-1),link.replace('v2.','v1.'),link+'\nX']) assert.throws(()=>parsePairing(bad));
});
test('noncanonical base64url padding bits rejected',()=>{assert.throws(()=>parsePairing(link.slice(0,-1)+'F'));});
test('framing across every split position',()=>{
  const bytes=hostFrame(T.status,Buffer.from('{"t":"warn","m":"hello"}'));
  for(let split=0;split<=bytes.length;split++){
    const got=[],parser=new Parser((t,b)=>got.push([t,b.toString()]));
    parser.push(bytes.subarray(0,split));parser.push(bytes.subarray(split));
    assert.deepEqual(got,[[T.status,'{"t":"warn","m":"hello"}']]);
  }
});
test('coalesced and one-byte fragmented frames',()=>{
  const got=[],parser=new Parser((t,b)=>got.push([t,b.length]));
  const bytes=Buffer.concat([hostFrame(T.hello,Buffer.from('{}')),hostFrame(T.pong,Buffer.alloc(16))]);
  for(const b of bytes)parser.push(Buffer.from([b]));assert.deepEqual(got,[[T.hello,2],[T.pong,16]]);
});
test('unknown and oversized frame headers rejected before allocation',()=>{
  for(const [type,size] of [[255,0],[T.hello,4097],[T.jpeg,4194305],[T.audioFrame,65545],[T.pong,17]]){
    const header=Buffer.alloc(5);header[0]=type;header.writeUInt32BE(size,1);
    assert.throws(()=>new Parser(()=>{}).push(header));
  }
});
test('zero-length payload does not stall next frame',()=>{
  const got=[],p=new Parser(t=>got.push(t));p.push(Buffer.concat([hostFrame(T.status,Buffer.alloc(0)),hostFrame(T.pong,Buffer.alloc(16))]));assert.deepEqual(got,[T.status,T.pong]);
});
test('outgoing control frames bounded',()=>{assert.equal(frame(T.ack).length,5);assert.throws(()=>frame(T.input,Buffer.alloc(65537)));});
test('audio format must be bounded stereo or mono PCM',()=>{
  const value=Buffer.from([0,0,187,128,2]);assert.deepEqual(audioFormat(value),{rate:48000,channels:2});
  for(const bad of [Buffer.alloc(4),Buffer.alloc(5),Buffer.from([0,0,187,128,8])])assert.throws(()=>audioFormat(bad));
});
test('pointer, keyboard, Unicode text and release validation',()=>{
  for(const v of [{t:'m',x:.5,y:1},{t:'d',b:1},{t:'g',b:0,x:0,y:0},{t:'key',k:'c',m:['cmd']},{t:'key',k:'f12',m:[]},{t:'txt',s:'سلام 👋'},{t:'cancel'}]) assert.equal(validateInput(v),true);
  for(const v of [null,[],{t:'shell',s:'x'},{t:'m',x:Infinity,y:0},{t:'d',b:5},{t:'s',dx:2000,dy:0},{t:'txt',s:'x'.repeat(8193)},{t:'key',k:'c',m:['bad']}])assert.equal(validateInput(v),false);
});
function ready(){const s=new Session();s.receive(T.hello,Buffer.from(JSON.stringify({version:2,video:'jpeg',audio:'pcm-s16le',transport:'tls-psk',control:true})),'fixture');s.sent=[];s.send=(type,data)=>{s.sent.push({type,data});return true;};return s;}
test('hello is required and duplicate/incorrect protocol fails closed',()=>{
  const s=new Session();assert.throws(()=>s.receive(T.jpeg,Buffer.from([255,216,255,217]),'x'));
  assert.throws(()=>s.receive(T.hello,Buffer.from('{"version":1}'),'x'));
  const r=ready();assert.throws(()=>r.receive(T.hello,Buffer.from('{}'),'x'));
});
test('control opt-in and cancellation',()=>{
  const s=ready();assert.equal(s.input({t:'txt',s:'x'}),false);assert.equal(s.setControl(true),true);
  assert.equal(s.input({t:'txt',s:'x'}),true);s.setControl(false);
  assert.deepEqual(JSON.parse(s.sent.at(-1).data),{t:'cancel'});
});
test('host-denied control stays disabled',()=>{const s=ready();s.capabilities.control=false;assert.equal(s.setControl(true),false);});
test('audio IPC has bounded pending chunks and validates alignment',()=>{
  const s=ready();s.setAudio(true);s.receive(T.audioConfig,Buffer.from([0,0,187,128,2]));
  let chunks=0;s.on('audio',()=>chunks++);for(let i=0;i<20;i++)s.receive(T.audioFrame,Buffer.alloc(16));
  assert.equal(chunks,4);s.ackAudio();s.receive(T.audioFrame,Buffer.alloc(16));assert.equal(chunks,5);
  assert.throws(()=>s.receive(T.audioFrame,Buffer.alloc(11)));
});
test('disconnect resets controls, audio, formats and ready state',()=>{const s=ready();s.setControl(true);s.setAudio(true);s.disconnect();assert.equal(s.ready,false);assert.equal(s.control,false);assert.equal(s.audio,false);assert.equal(s.format,null);});
test('invalid replacement link leaves existing session intact',()=>{const s=ready();assert.throws(()=>s.connect('bad'));assert.equal(s.ready,true);});
