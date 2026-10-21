'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),vm=require('node:vm');
const {Preferences,defaults,validPatch}=require('../core/preferences.cjs'),policy=require('../renderer/stream-policy.js');
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'m2p-prefs-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return dir;}
test('viewer preferences persist only display choices; input, sound, links and unknown fields are rejected',t=>{
 const file=path.join(temporary(t),'preferences.json'),store=new Preferences(file);
 assert.deepEqual(store.get(),defaults);
 for(const patch of [{control:true},{sound:true},{link:'fixture'},{quality:'ultra'},{fps:120},{fps:'60'},{autoFullscreen:1},[],null])assert.equal(store.update(patch).ok,false);
 assert(!validPatch(JSON.parse('{"__proto__":{}}')));
 assert.equal(store.update({quality:'sharp',fps:30,autoFullscreen:false}).ok,true);
 assert.deepEqual(new Preferences(file).get(),{quality:'sharp',fps:30,autoFullscreen:false});
 const copy=store.get();copy.quality='fast';assert.equal(store.get().quality,'sharp');
 if(process.platform!=='win32')assert.equal(fs.statSync(file).mode&0o777,0o600); // Windows uses ACLs, not POSIX mode bits.
 assert.deepEqual(fs.readdirSync(path.dirname(file)),['preferences.json']);
});
test('missing, oversized, invalid and future-version preferences fall back without breaking startup',t=>{
 const file=path.join(temporary(t),'preferences.json');
 for(const text of ['{','x'.repeat(5000),'null',JSON.stringify({version:2,preferences:{quality:'sharp'}}),JSON.stringify({version:1,preferences:{control:true}})]){
  fs.writeFileSync(file,text);assert.deepEqual(new Preferences(file).get(),defaults);
 }
 fs.writeFileSync(file,JSON.stringify({version:1,preferences:{fps:30}}));assert.equal(new Preferences(file).get().fps,30);
});
test('preference write failure preserves previous memory and disk and cleans its own temporary file',t=>{
 const dir=temporary(t),file=path.join(dir,'preferences.json'),store=new Preferences(file);
 assert(store.update({fps:30}).ok);const original=fs.readFileSync(file);
 // A directory at the destination makes atomic rename fail on every platform.
 fs.renameSync(file,file+'.original');fs.mkdirSync(file);
 assert.equal(store.update({fps:60}).ok,false);assert.equal(store.get().fps,30);
 assert.deepEqual(fs.readFileSync(file+'.original'),original);
 assert.deepEqual(fs.readdirSync(dir).sort(),['preferences.json','preferences.json.original']);
});
test('stalled video needs three seconds of continuing activity without decoded frames',()=>{
 const watch=new policy.StallWatch();
 for(let n=0;n<3;n++)assert.equal(watch.sample({timestamp:n*1000,framesDecoded:60,bytesReceived:n*10000}),false);
 assert.equal(watch.sample({timestamp:3000,framesDecoded:60,bytesReceived:30000}),true);
 assert.equal(watch.sample({timestamp:4000,framesDecoded:120,bytesReceived:40000}),false);
});
test('static desktops, hidden windows, missing counters and waking from sleep never count as stalls',()=>{
 for(const mode of ['idle','hidden','missing','sleep','reset']){
  const watch=new policy.StallWatch();
  for(let n=0;n<12;n++){
   const stat={timestamp:n*(mode==='sleep'?10000:1000),framesDecoded:mode==='missing'?undefined:mode==='reset'?120-n:120,bytesReceived:mode==='idle'?100:n*10000};
   assert.equal(watch.sample(stat,{visible:mode!=='hidden'}),false,mode);
  }
 }
});
test('fresh active sender telemetry can detect blocked incoming media, while absent activity cannot',()=>{
 const watch=new policy.StallWatch();
 for(let n=0;n<4;n++)assert.equal(watch.sample({timestamp:n*1000,framesDecoded:20,bytesReceived:50},{sender:{fps:60}}),n===3);
 assert.equal(watch.sample({timestamp:4000,framesDecoded:20,bytesReceived:50}),false);
});
test('automatic recovery has a rolling two-attempt-per-minute budget',()=>{
 const retry=new policy.RetryBudget();assert.equal(retry.next(1000),600);assert.equal(retry.next(2000),1200);
 assert.equal(retry.next(59000),undefined);assert.equal(retry.next(61000),1200);
});
function receiverRuntime(){
 let id=0;const timers=new Map(),signals=[],displays=[];
 const context={window:{M2PStreamPolicy:policy},setTimeout:(fn,ms)=>{timers.set(++id,{fn,ms});return id;},clearTimeout:id=>timers.delete(id),setInterval:()=>++id,clearInterval:()=>{},
  RTCPeerConnection:class{close(){this.closed=true;}},MediaStream:class{}};
 vm.runInNewContext(fs.readFileSync(require.resolve('../renderer/realtime.js'),'utf8'),context);
 const video={pause(){},play:async()=>{},cancelVideoFrameCallback(){}};
 const receiver=new context.window.M2PRealtime.Receiver({video,send:v=>signals.push(v),display:(...v)=>displays.push(v),stats:()=>{}});
 return {receiver,timers,signals,displays};
}
test('recovery closes stale media, preserves quality and FPS, and stop cancels a queued retry',()=>{
 const {receiver:r,timers,signals}=receiverRuntime();r.start('fast',{feedback:true,fps:30});r.hadVideo=true;
 const first=r.pc;r.fail(first,'stalled');assert(first.closed);assert(r.recovering);assert.equal(r.pc,null);assert.equal(signals.at(-1).type,'fallback');
 const timer=timers.get(r.retryTimer);assert.equal(timer.ms,600);timer.fn();
 assert.notEqual(r.pc,first);assert.equal(signals.at(-1).quality,'fast');assert.equal(signals.at(-1).fps,30);
 r.fail(r.pc);const pending=r.retryTimer;r.stop();assert(!timers.has(pending));assert.equal(r.pc,null);assert.equal(r.recovering,false);
});
test('no automatic loop before first video or after budget exhaustion; manual start renews the budget',()=>{
 const {receiver:r,timers,displays}=receiverRuntime();r.start();r.fail(r.pc);assert.equal(r.recovering,false);assert.equal(r.retryTimer,null);
 r.start();r.hadVideo=true;
 for(let n=0;n<2;n++){r.fail(r.pc);timers.get(r.retryTimer).fn();}
 r.fail(r.pc);assert.equal(r.recovering,false);assert.equal(displays.at(-1)[1],'Compatibility video · retry realtime when ready');
 r.start();assert.equal(r.recovery.times.length,0);assert.equal(r.recoveryAttempts,0);r.stop();
});
