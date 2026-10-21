'use strict';
const T = Object.freeze({ videoConfig:1, videoFrame:2, status:3, pong:4,
  audioConfig:6, audioFrame:7, hello:8, jpeg:9, input:16, settings:17,
  ack:18, keyframe:19, ping:20, audioOn:22, realtime:24 });
const limits = new Map([[T.status,65536],[T.pong,16],[T.audioConfig,5],
  [T.audioFrame,65544],[T.hello,4096],[T.jpeg,4*1024*1024],[T.realtime,65536]]);
function frame(type, payload=Buffer.alloc(0)) {
  if (!Buffer.isBuffer(payload) || payload.length > 65536) throw new Error('Invalid outgoing frame');
  const result=Buffer.alloc(5+payload.length); result[0]=type;
  result.writeUInt32BE(payload.length,1); payload.copy(result,5); return result;
}
// Incremental, bounded, linear-time parser, including one-byte TCP fragments.
class Parser {
  constructor(onFrame) { this.onFrame=onFrame; this.header=Buffer.alloc(5); this.h=0; this.body=null; this.n=0; }
  push(chunk) {
    let at=0;
    while(at<chunk.length) {
      if(this.h<5) {
        const n=Math.min(5-this.h,chunk.length-at); chunk.copy(this.header,this.h,at,at+n); at+=n; this.h+=n;
        if(this.h<5) return;
        const size=this.header.readUInt32BE(1), limit=limits.get(this.header[0]);
        if(limit===undefined || size>limit) throw new Error('Unexpected or oversized host message');
        this.body=Buffer.alloc(size); this.n=0;
      }
      const count=Math.min(this.body.length-this.n,chunk.length-at);
      chunk.copy(this.body,this.n,at,at+count); at+=count; this.n+=count;
      if(this.n===this.body.length) {
        const type=this.header[0],body=this.body; this.h=0; this.body=null;
        this.onFrame(type,body);
      }
    }
  }
}
function audioFormat(data) {
  if(data.length!==5) throw new Error('Invalid audio format');
  const rate=data.readUInt32BE(0), channels=data[4];
  if(rate<8000 || rate>192000 || ![1,2].includes(channels)) throw new Error('Unsupported audio format');
  return {rate,channels};
}
module.exports={T,frame,Parser,audioFormat};
