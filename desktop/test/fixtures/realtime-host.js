'use strict';
const surface=document.getElementById('source'),ctx=surface.getContext('2d');let frames=0;
function paint(){ctx.fillStyle='#102038';ctx.fillRect(0,0,1920,1080);ctx.fillStyle='#86c8ff';ctx.font='60px system-ui';ctx.fillText('Mac2Phone · realtime test',140,220);ctx.fillStyle='#f0f6ff';ctx.font='30px system-ui';ctx.fillText('Synthetic 1080p motion. No real desktop is captured.',140,290);ctx.fillStyle='#45a8ff';ctx.fillRect(140+(frames++%180)*8,520,170,170);
 // A same-machine clock encoded in pixels measures actual frame age, not RTT.
 const stamp=Date.now()>>>0;
 for(let bit=0;bit<32;bit++){ctx.fillStyle=(stamp>>>bit)&1?'#fff':'#000';ctx.fillRect(100+bit*48,990,48,60);}
}
paint();const sourceStream=surface.captureStream(60),animation=setInterval(paint,1000/60);
const senderPool=new M2PRealtime.Senders({getStream:()=>sourceStream,send:(id,value)=>fixtureHost.send(id,value)});
fixtureHost.on('signal',({id,signal})=>senderPool.handle(id,signal));fixtureHost.on('close',id=>senderPool.close(id));
window.addEventListener('beforeunload',()=>{clearInterval(animation);senderPool.stop();sourceStream.getTracks().forEach(t=>t.stop());});
