'use strict';
const tls=require('node:tls');
const {EventEmitter}=require('node:events');
const {parsePairing,CIPHER}=require('./pairing.cjs');
const {T,frame,Parser,audioFormat}=require('./protocol.cjs');
const {validateInput}=require('./input.cjs');
const {CAPABILITY,validSignal,peerSignal}=require('./realtime.cjs');
class Session extends EventEmitter {
  constructor() { super(); this.socket=null; this.timer=null; this.ready=false; this.control=false; this.audio=false; this.audioPending=0; this.format=null; }
  connect(link) {
    const pairing=parsePairing(link); // Invalid links must not destroy a current session.
    this.disconnect(); this.emit('state',{state:'connecting',host:pairing.host});
    const socket=tls.connect({host:pairing.host,port:pairing.port,
      minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER,
      pskCallback:()=>({identity:pairing.identity,psk:pairing.key}),
      // PSK authentication has no X.509 certificate or hostname to verify.
      // Only the PSK cipher above is enabled; certificate suites are excluded.
      checkServerIdentity:()=>undefined});
    this.socket=socket; this.started=Date.now(); this.lastHeard=Date.now();
    const fail=()=>{
      if(this.socket!==socket) return;
      this.disconnect();
      this.emit('state',{state:'error',message:'Connection ended. Check the LAN connection and copy a fresh pairing link from the Mac.'});
    };
    const parser=new Parser((type,data)=>{
      if(this.socket!==socket) return;
      this.lastHeard=Date.now(); this.receive(type,data,pairing.host);
    });
    socket.on('secureConnect',()=>{
      if(this.socket!==socket) return;
      if(!socket.authorized || socket.getProtocol()!=='TLSv1.2' || socket.getCipher().name!==CIPHER) { fail(); return; }
      socket.setNoDelay(true); socket.write(Buffer.concat([...(pairing.ticket?[Buffer.from('M2PG'),pairing.ticket]:[]),Buffer.from('M2PJ')]));
    });
    socket.on('data',data=>{ try { parser.push(data); } catch { fail(); } });
    socket.on('error',fail); socket.on('close',fail);
    this.timer=setInterval(()=>{
      if(this.socket!==socket) return;
      if(Date.now()-this.lastHeard>8000 || (!this.ready && Date.now()-this.started>10000)) { fail(); return; }
      if(this.ready) { const ping=Buffer.alloc(8); ping.writeBigUInt64BE(BigInt(Date.now())*1000n); this.send(T.ping,ping); }
    },1000); this.timer.unref();
  }
  receive(type,data,host) {
    if(!this.ready && type!==T.hello) throw new Error('Missing hello');
    if(type===T.hello) {
      const hello=JSON.parse(data.toString('utf8'));
      if(this.ready || hello.version!==2 || hello.video!=='jpeg' || hello.audio!=='pcm-s16le' || hello.transport!=='tls-psk') throw new Error('Incompatible host');
      this.ready=true; this.capabilities=hello;
      this.emit('state',{state:'connected',host,capabilities:hello});
    } else if(type===T.realtime) {
      const signal=JSON.parse(data);if(this.capabilities.realtime!==CAPABILITY||!validSignal(signal,'host'))throw Error('Invalid realtime signal');
      this.emit('realtime',peerSignal(signal,this.socket?.remoteAddress));
    } else if(type===T.jpeg) {
      if(data.length<4 || data[0]!==255 || data[1]!==216) throw new Error('Invalid JPEG');
      this.emit('video',data);
    } else if(type===T.audioConfig) {
      this.format=audioFormat(data); this.emit('audio-format',this.format);
    } else if(type===T.audioFrame) {
      if(!this.format || data.length<=8 || (data.length-8)%(2*this.format.channels)) throw new Error('Invalid PCM');
      if(this.audio && this.audioPending<4) { this.audioPending++; this.emit('audio',data.subarray(8)); }
    } else if(type===T.pong) {
      if(data.length!==16) throw new Error('Invalid pong');
      this.emit('latency',Math.max(0,Math.min(8000,Date.now()-Number(data.readBigUInt64BE(0))/1000)));
    } else if(type===T.status) {
      const value=JSON.parse(data.toString('utf8'));
      if(value.t==='warn'&&typeof value.m==='string') this.emit('notice',value.m.slice(0,1000));
    }
  }
  send(type,data=Buffer.alloc(0)) {
    if(!this.ready || !this.socket || this.socket.destroyed) return false;
    if(this.socket.writableLength>128*1024) { this.disconnect(); return false; }
    return this.socket.write(frame(type,data));
  }
  setControl(enabled) {
    const next=enabled===true&&this.ready&&this.capabilities?.control===true;
    if(!next) this.send(T.input,Buffer.from('{"t":"cancel"}'));
    this.control=next; return next;
  }
  signal(value){return this.ready&&this.capabilities?.realtime===CAPABILITY&&validSignal(value,'viewer')&&
    (value.type!=='feedback'||this.capabilities.realtimeFeedback===1)&&this.send(T.realtime,Buffer.from(JSON.stringify(value)));}
  input(value) {
    if(!validateInput(value) || (!this.control && value.t!=='cancel')) return false;
    return this.send(T.input,Buffer.from(JSON.stringify(value)));
  }
  setAudio(enabled) { this.audio=enabled===true&&this.ready; this.audioPending=0; this.send(T.audioOn,Buffer.from([this.audio?1:0])); }
  ackVideo() { this.send(T.ack); }
  ackAudio() { this.audioPending=Math.max(0,this.audioPending-1); }
  disconnect() {
    clearInterval(this.timer); this.timer=null;
    const socket=this.socket;
    if(socket) this.send(T.input,Buffer.from('{"t":"cancel"}'));
    this.socket=null; this.ready=false; this.control=false; this.audio=false; this.audioPending=0; this.format=null;
    if(socket) { socket.end(); const timeout=setTimeout(()=>socket.destroy(),250); timeout.unref(); }
    this.emit('state',{state:'idle'});
  }
}
module.exports={Session};
