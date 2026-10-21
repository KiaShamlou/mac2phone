'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const policy=require('../renderer/stream-policy.js'),{LatestFrame}=require('../renderer/frame-queue.js');
const {validSignal}=require('../core/realtime.cjs');
const sourceRoot=process.env.M2P_LATENCY_SOURCE||path.resolve(__dirname,'..');
function runtime(){
 const context={window:{M2PStreamPolicy:policy},setTimeout,clearTimeout,setInterval,clearInterval,
  RTCPeerConnection:class{close(){this.closed=true;}},MediaStream:class{}};
 vm.runInNewContext(fs.readFileSync(path.join(sourceRoot,'renderer/realtime.js'),'utf8'),context);
 return context.window.M2PRealtime;
}
test('interactive quality profiles preserve frame rate while Sharp explicitly prioritizes text detail',async()=>{
 const {Senders}=runtime(),pool=new Senders({getStream:()=>{},send:()=>{}});
 for(const quality of ['fast','balanced','sharp']){
  let actual;
  await pool.quality({quality,sender:{track:{getSettings:()=>({width:3840,height:2160})},getParameters:()=>({encodings:[{}]}),setParameters:async p=>{actual=p;}}});
  assert.equal(actual.degradationPreference,quality==='sharp'?'maintain-resolution':'maintain-framerate');
  assert(actual.encodings[0].maxBitrate<=24000000);
  assert.equal(actual.encodings[0].scaleResolutionDownBy,3840/policy.profiles[quality].width);
 }
});
test('receiver asks for minimum playout buffering without failing unsupported browsers',()=>{
 const {Receiver}=runtime();
 for(const receiver of [{jitterBufferTarget:100},{}]){
  const video={pause(){},play:async()=>{},requestVideoFrameCallback:()=>1,cancelVideoFrameCallback(){}};
  const r=new Receiver({video,send:()=>{},display:()=>{},stats:()=>{}});
  r.start('fast');const pc=r.pc;
  try{pc.ontrack({receiver,streams:[{}],track:{}});if('jitterBufferTarget' in receiver)assert.equal(receiver.jitterBufferTarget,0);}
  finally{r.stop();}
  assert.equal(pc.closed,true);
 }
});
test('Auto backs off persistent encoder/network pressure, recovers slowly and ignores idle screens',()=>{
 const adaptive=new policy.Adaptive();
 assert.equal(adaptive.profile.width,1280);
 assert.equal(adaptive.sample({frames:60,reason:'cpu',encodeMs:30,sendDelayMs:1}),false);
 assert.equal(adaptive.sample({frames:60,reason:'cpu',encodeMs:30,sendDelayMs:1}),true);
 assert.equal(adaptive.profile.width,960);
 for(let i=0;i<20;i++)adaptive.sample({frames:0,reason:'cpu',encodeMs:100});
 assert.equal(adaptive.profile.width,960);
 for(let i=0;i<5;i++)assert.equal(adaptive.sample({frames:100,reason:'none',encodeMs:4,sendDelayMs:1}),false);
 assert.equal(adaptive.sample({frames:100,reason:'none',encodeMs:4,sendDelayMs:1}),true);
 assert.equal(adaptive.profile.width,1280);
 for(let i=0;i<30;i++)adaptive.sample({frames:100,reason:'none',encodeMs:4,sendDelayMs:1});
 assert.equal(adaptive.profile.width,1920);
});
test('interval measurements use counter differences and never invent absent decode/buffer statistics',()=>{
 const before={timestamp:1000,framesDecoded:50,framesDropped:5,bytesReceived:100000,totalDecodeTime:.5,jitterBufferDelay:1,jitterBufferEmittedCount:50,packetsLost:1,packetsReceived:100};
 const current={timestamp:2000,framesDecoded:110,framesDropped:5,bytesReceived:200000,totalDecodeTime:.62,jitterBufferDelay:1.6,jitterBufferEmittedCount:110,packetsLost:3,packetsReceived:198};
 const v=policy.inbound(current,before);
 assert.equal(v.fps,60);assert.equal(v.mbps,.8);assert(Math.abs(v.decodeMs-2)<.001);assert(Math.abs(v.bufferMs-10)<.001);assert.equal(v.dropPercent,0);assert.equal(v.lossPercent,2);
 const empty=policy.inbound({timestamp:0},null);assert.equal(empty.decodeMs,undefined);assert.equal(empty.bufferMs,undefined);
 assert.equal(policy.delta({framesDecoded:0},{framesDecoded:100},'framesDecoded'),undefined);
 const out=policy.outbound({timestamp:2000,framesEncoded:120,totalEncodeTime:.9,totalPacketSendDelay:.7,packetsSent:300,qualityLimitationReason:'cpu'},{timestamp:1000,framesEncoded:60,totalEncodeTime:.3,totalPacketSendDelay:.1,packetsSent:100});
 assert(Math.abs(out.encodeMs-10)<.001);assert(Math.abs(out.sendDelayMs-3)<.001);assert.equal(out.reason,'cpu');
});
test('compatibility decode retains only the newest queued frame and acknowledges every dropped frame',async()=>{
 const decoded=[],drawn=[],acked=[],closed=[],resolvers=[];
 const q=new LatestFrame({decode:async value=>{decoded.push(value);await new Promise(r=>resolvers.push(r));return {value,close:()=>closed.push(value)};},draw:v=>drawn.push(v.value),ack:t=>acked.push(t),valid:()=>true});
 for(let n=1;n<=8;n++)q.push(n,n);
 assert.deepEqual(decoded,[1]);assert.equal(q.pending.data,8);assert.deepEqual(acked,[2,3,4,5,6,7]);
 resolvers.shift()();await new Promise(r=>setImmediate(r));
 assert.deepEqual(decoded,[1,8]);resolvers.shift()();await new Promise(r=>setImmediate(r));
 assert.deepEqual(drawn,[1,8]);assert.deepEqual(closed,[1,8]);assert.equal(acked.length,8);assert.equal(q.busy,false);
});
test('disconnect invalidates in-flight JPEGs and releases pending images without drawing into a new session',async()=>{
 let resolve,valid=true;const drawn=[],acked=[],closed=[];
 const q=new LatestFrame({decode:()=>new Promise(r=>resolve=()=>r({close:()=>closed.push(true)})),draw:v=>drawn.push(v),ack:t=>acked.push(t),valid:()=>valid});
 q.push(1,1);q.push(2,1);valid=false;q.clear();resolve();await new Promise(r=>setImmediate(r));
 assert.equal(drawn.length,0);assert.equal(acked.length,2);assert.equal(closed.length,1);
});
test('telemetry and adaptive settings validate direction, finite values and bounded encoder names',()=>{
 assert(validSignal({type:'telemetry',reason:'cpu',encodeMs:22,fps:40,encoder:'test encoder'},'host'));
 assert(!validSignal({type:'telemetry',reason:'cpu',encodeMs:22},'viewer'));
 for(const encodeMs of [-1,Infinity,NaN,60001])assert(!validSignal({type:'telemetry',reason:'cpu',encodeMs},'host'));
 assert(!validSignal({type:'telemetry',reason:'cpu',encoder:'a'.repeat(101)},'host'));
 assert(!validSignal({type:'start',quality:'balanced',adaptive:'yes'},'viewer'));
 assert(validSignal({type:'start',quality:'balanced',adaptive:true,telemetry:true},'viewer'));
});
