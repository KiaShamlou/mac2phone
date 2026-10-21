'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const policy=require('../renderer/stream-policy.js'),{budget,CaptureBudget}=require('../renderer/capture-budget.js');
const diagnostics=require('../renderer/diagnostics.js'),{validSignal}=require('../core/realtime.cjs');
const healthy={frames:120,reason:'none',encodeMs:3,sendDelayMs:1};
test('capture budget follows largest viewer, preserves aspect and keeps legacy delivery at 1080p/30',()=>{
 const native={width:3840,height:2160};
 assert.deepEqual(budget(native),{width:960,height:540,fps:15});
 assert.deepEqual(budget(native,[policy.profiles.fast]),{width:1280,height:720,fps:60});
 assert.deepEqual(budget(native,[policy.profiles.fast,policy.profiles.sharp]),{width:3840,height:2160,fps:60});
 assert.deepEqual(budget(native,[policy.profiles.fast],1),{width:1920,height:1080,fps:60});
 assert.deepEqual(budget(native,[],1),{width:1920,height:1080,fps:30});
 assert.deepEqual(budget({width:1080,height:1920},[policy.profiles.fast]),{width:720,height:1280,fps:60});
 assert.deepEqual(budget({width:800,height:600},[policy.profiles.sharp]),{width:800,height:600,fps:60});
});
test('capture changes serialize, skip superseded work, retain cursor constraints and restore native detail',async()=>{
 const calls=[],waiters=[];let concurrent=0,max=0,applied=0;
 const track={readyState:'live',getSettings:()=>({width:3840,height:2160}),getConstraints:()=>({cursor:'always'}),applyConstraints:async value=>{
  calls.push(value);max=Math.max(max,++concurrent);await new Promise(r=>waiters.push(r));concurrent--;
 }};
 const c=new CaptureBudget(track,{applied:()=>applied++});
 c.update([policy.profiles.fast]);await Promise.resolve();
 c.update([policy.profiles.balanced]);c.update([policy.profiles.sharp]);
 waiters.shift()();await new Promise(r=>setImmediate(r));
 assert.equal(calls.length,2);assert.equal(calls[0].width.max,1280);assert.equal(calls[1].width.max,3840);assert.equal(calls[1].cursor,'always');
 waiters.shift()();await c.queue;assert.equal(max,1);assert.equal(applied,2);
 c.update();c.stop();await c.queue;assert.equal(calls.length,2);
});
test('unsupported capture constraints do not terminate capture and stop invalidates late completions',async()=>{
 let failure=0,applied=0,resolve;
 const track={readyState:'live',getSettings:()=>({width:1920,height:1080}),getConstraints:()=>({}),applyConstraints:async()=>{throw Error('unsupported');}};
 const c=new CaptureBudget(track,{failed:()=>failure++,applied:()=>applied++});
 await c.update();assert.equal(failure,1);assert.equal(track.readyState,'live');
 track.applyConstraints=()=>new Promise(r=>resolve=r);c.update();await Promise.resolve();c.stop();resolve();await c.queue;assert.equal(applied,0);
});
test('two-way Auto responds to viewer load, not idle or missing metrics, and reaches a bounded 30 fps rescue tier',()=>{
 const auto=new policy.Adaptive(),receiver={frames:60,bufferMs:90,decodeMs:3,dropPercent:0,lossPercent:0};
 assert.equal(policy.pressure(healthy,receiver),'receiver');
 assert.equal(auto.sample(healthy,receiver),false);assert.equal(auto.sample(healthy,receiver),true);assert.equal(auto.profile.width,960);
 auto.sample(healthy,receiver);auto.sample(healthy,receiver);assert.deepEqual(auto.profile,{width:640,fps:30,bitrate:1200000});
 for(let n=0;n<20;n++)auto.sample(healthy,{...receiver,frames:0});
 assert.equal(auto.profile.width,640);
 for(let n=0;n<6;n++)auto.sample(healthy,{frames:60,bufferMs:3,decodeMs:3,dropPercent:0,lossPercent:0});
 assert.equal(auto.profile.width,960);
 assert.equal(policy.pressure(healthy,{frames:0,decodeMs:999}),'none');
});
test('sender ignores expired receiver feedback and never changes a manual profile',async()=>{
 const context={window:{M2PStreamPolicy:policy},setTimeout,clearTimeout,setInterval,clearInterval};
 vm.runInNewContext(fs.readFileSync(require.resolve('../renderer/realtime.js'),'utf8'),context);
 const pool=new context.window.M2PRealtime.Senders({getStream:()=>{},send:()=>{}});let serial=0,changes=0;
 pool.quality=async()=>changes++;
 const peer={adaptive:true,feedback:true,quality:'fast',fps:30,auto:new policy.Adaptive(),queue:Promise.resolve(),
  pc:{getStats:async()=>{serial++;return new Map([['out',{type:'outbound-rtp',kind:'video',timestamp:serial*2000,framesEncoded:serial*120,totalEncodeTime:serial*.36,totalPacketSendDelay:serial*.2,packetsSent:serial*200,qualityLimitationReason:'none'}]]);}}};
 pool.peers.set('one',peer);
 pool.handle('one',{type:'feedback',frames:60,bufferMs:100});peer.receiverAt=Date.now()-4000;
 for(let i=0;i<3;i++){await pool.measure('one',peer);await peer.queue;}
 assert.equal(changes,0);assert.equal(peer.auto.profile.width,1280);
 peer.receiverAt=Date.now();
 for(let i=0;i<2;i++){await pool.measure('one',peer);await peer.queue;}
 assert.equal(changes,1);assert.equal(peer.auto.profile.width,960);
 peer.adaptive=false;
 for(let i=0;i<3;i++){await pool.measure('one',peer);await peer.queue;}
 assert.equal(changes,1);assert.equal(pool.profile(peer).fps,30);assert.equal(pool.profile(peer).width,1280);
});
test('feedback is direction-specific, bounded, and frame-rate requests are an explicit finite enum',()=>{
 assert(validSignal({type:'feedback',frames:60,decodeMs:5,bufferMs:8,dropPercent:1,lossPercent:0},'viewer'));
 assert(!validSignal({type:'feedback',frames:60},'host'));
 for(const frames of [undefined,-1,1001,Infinity,'60'])assert(!validSignal({type:'feedback',frames},'viewer'));
 for(const dropPercent of [101,-1,NaN])assert(!validSignal({type:'feedback',frames:60,dropPercent},'viewer'));
 for(const fps of [0,29,120,Infinity,'60'])assert(!validSignal({type:'quality',quality:'balanced',fps},'viewer'));
 assert(validSignal({type:'start',quality:'balanced',feedback:true,fps:30},'viewer'));
 assert(validSignal({type:'telemetry',reason:'none',pressure:'receiver',targetFPS:30},'host'));
});
test('diagnostics allowlists values, bounds history and excludes keys, names, IPs, SDP and encoder free text',()=>{
 const secret='private-fixture-secret';
 const sample={fps:59.999,mbps:NaN,codec:'H264',host:secret,sdp:secret,token:secret,sender:{encodeMs:5,encoder:secret,pressure:'receiver'}};
 const report=diagnostics.report({clientVersion:'0.5.2',hostVersion:'0.5.1',hostPlatform:'win32',transport:'webrtc',quality:'auto',samples:Array(100).fill(sample),link:secret,ip:secret});
 assert.equal(report.samples.length,60);assert.equal(report.samples[0].fps,60);assert.equal(report.samples[0].mbps,null);
 assert(!JSON.stringify(report).includes(secret));assert.equal(report.hostVersion,'0.5.1');
 assert.equal(diagnostics.report({hostVersion:secret}).hostVersion,'unknown');
 assert.equal(diagnostics.health({bufferMs:90}).label,'Viewer catching up');
 assert.equal(diagnostics.health({}).label,'Live');
});
