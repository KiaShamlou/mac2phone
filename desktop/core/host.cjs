'use strict';
const tls=require('node:tls'),crypto=require('node:crypto'),os=require('node:os');
const {EventEmitter}=require('node:events');
const {Grants}=require('./grants.cjs');
const {CIPHER}=require('./pairing.cjs');
const {T}=require('./protocol.cjs');
const {normalizeInput}=require('./input.cjs');
const {CAPABILITY,validSignal,peerSignal}=require('./realtime.cjs');
function encode(type,payload=Buffer.alloc(0)){const h=Buffer.alloc(5);h[0]=type;h.writeUInt32BE(payload.length,1);return Buffer.concat([h,payload]);}
function addresses(){return Object.values(os.networkInterfaces()).flat().filter(v=>v&&!v.internal&&v.family==='IPv4').map(v=>v.address);}
class Host extends EventEmitter{
  constructor({input=()=>{},platform=process.platform,requireApproval=false,realtime=false}={}){super();this.realtime=realtime;this.requireApproval=requireApproval;this.grants=new Grants();this.input=input;this.platform=platform;this.server=null;this.clients=new Set();this.sockets=new Set();this.audioConfig=null;this.control=false;this.key=null;this.starting=false;}
  async start({port=8765,bind='0.0.0.0',control=false,audio=false,key=crypto.randomBytes(32),identity=crypto.randomUUID()}={}){
    if(this.server||this.starting)throw new Error('Sharing is already active');
    if(!Number.isInteger(port)||port<0||port>65535||key.length!==32)throw new Error('Invalid host configuration');
    this.starting=true;this.key=Buffer.from(key);this.identity=identity;this.control=control;this.audioAvailable=audio;
    const server=tls.createServer({minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER,
      pskCallback:(_socket,name)=>name===identity?this.key:null,handshakeTimeout:8000,
      // TLS session resumption is deliberately disabled across host sessions.
      secureOptions:require('node:constants').SSL_OP_NO_TICKET},socket=>this.accept(socket));
    this.server=server;server.maxConnections=16;server.on('connection',socket=>{this.sockets.add(socket);socket.once('close',()=>this.sockets.delete(socket));});server.on('tlsClientError',()=>{});
    server.on('error',error=>this.emit('notice',error.code==='EADDRINUSE'?'Port 8765 is in use. Stop the other host before sharing.':'Sharing listener failed.'));
    try{await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,bind,()=>{server.removeListener('error',reject);resolve();});});}
    catch(e){this.server=null;this.key=null;throw e;}finally{this.starting=false;}
    this.port=server.address().port;
    this.timer=setInterval(()=>{for(const c of this.clients)if(Date.now()-c.heard>8000||(!c.ready&&Date.now()-c.created>8000))c.socket.destroy();},1000);this.timer.unref();
    return this.state();
  }
  state(){return{active:!!this.server,port:this.port,viewers:[...this.clients].filter(c=>c.ready).length,control:this.control,audio:this.audioAvailable,
    links:this.server?addresses().map(host=>`mac2phone://${host}:${this.port}#v2.${this.identity}.${this.key.toString('base64url')}`):[]};}
  grant(address=addresses()[0]){if(!this.server||!address)throw Error("Start sharing first");const ticket=this.grants.issue();return `mac2phone://${address.includes(":")?`[${address}]`:address}:${this.port}#v3.${this.identity}.${this.key.toString("base64url")}.${ticket.toString("base64url")}`;}
  accept(socket){
    if(this.clients.size>=16||!this.server){socket.destroy();return;}
    socket.setNoDelay(true);
    const c={id:crypto.randomUUID(),rtc:false,negotiating:false,signals:0,signalWindow:Date.now(),socket,rx:Buffer.alloc(0),ready:false,approved:false,credit:0,audio:false,heard:Date.now(),created:Date.now(),count:0,window:Date.now()};
    this.clients.add(c);
    socket.on('error',()=>{});socket.on('close',()=>{this.clients.delete(c);if(c.ready)this.input({t:'cancel'});this.emit('realtime-close',c.id);this.demand();this.emit('viewers',[...this.clients].filter(c=>c.ready).length);});
    socket.on('data',bytes=>{try{c.rx=Buffer.concat([c.rx,bytes]);this.drain(c);}catch{socket.destroy();}});
  }
  drain(c){
    if(!c.ready){if(c.rx.length<4)return;let magic=c.rx.subarray(0,4).toString();if(magic==='M2PG'){if(c.approved)throw Error('repeated grant');if(c.rx.length<40)return;if(!this.grants.consume(c.rx.subarray(4,36)))throw Error('approval');c.approved=true;c.rx=c.rx.subarray(36);magic=c.rx.subarray(0,4).toString();}if(this.requireApproval&&!c.approved)throw Error('approval required');if(!['M2P2','M2PJ'].includes(magic))throw Error('protocol');c.rx=c.rx.subarray(4);c.ready=true;
      this.send(c,T.hello,Buffer.from(JSON.stringify({version:2,appVersion:require('../package.json').version,video:'jpeg',audio:'pcm-s16le',transport:'tls-psk',platform:this.platform,control:this.control,screen:true,audioAvailable:this.audioAvailable,touchMode:'pointer',...(this.realtime?{realtime:CAPABILITY,realtimeTelemetry:1,realtimeFeedback:1}:{})})));
      this.demand();
      this.emit('viewers',[...this.clients].filter(c=>c.ready).length);
    }
    while(c.rx.length>=5){
      const type=c.rx[0],length=c.rx.readUInt32BE(1);if(length>65536)throw Error('size');if(c.rx.length<length+5)return;
      const data=c.rx.subarray(5,length+5);c.rx=c.rx.subarray(length+5);c.heard=Date.now();
      if(Date.now()-c.window>1000){c.window=Date.now();c.count=0;}if(++c.count>2000)throw Error('rate');
      if(type===T.realtime){
        const signal=JSON.parse(data);if(!this.realtime||!validSignal(signal,'viewer'))throw Error('realtime');
        if(Date.now()-c.signalWindow>=1000){c.signalWindow=Date.now();c.signals=0;}if(++c.signals>80)throw Error('signaling rate');
        if(signal.type==='start'){if(c.negotiating||c.rtc)throw Error('repeated negotiation');c.negotiating=true;c.telemetry=signal.telemetry===true;c.feedback=signal.feedback===true;}
        else if(signal.type==='active'){if(!c.negotiating)throw Error('missing negotiation');c.rtc=true;this.demand();}
        else if(signal.type==='fallback'){c.rtc=false;c.negotiating=false;c.credit=0;this.demand();}
        else if(!c.negotiating)throw Error('missing negotiation');
        if(signal.type==='feedback'&&(!c.rtc||!c.feedback))throw Error('feedback not negotiated');
        this.emit('realtime',{id:c.id,signal:peerSignal(signal,c.socket.remoteAddress)});
      }
      else if(type===T.ack){if(data.length)throw Error('ack');c.credit=Math.max(0,c.credit-1);}
      else if(type===T.ping){if(data.length!==8)throw Error('ping');const now=Buffer.alloc(8);now.writeBigUInt64BE(BigInt(Date.now())*1000n);this.send(c,T.pong,Buffer.concat([data,now]));}
      else if(type===T.audioOn){if(data.length!==1||data[0]>1)throw Error('audio');c.audio=data[0]===1;if(c.audio&&this.audioConfig)this.send(c,T.audioConfig,this.audioConfig);}
      else if(type===T.input){const input=normalizeInput(JSON.parse(data.toString()));if(this.control&&input)this.input(input);}
      else if(type!==T.settings&&type!==T.keyframe)throw Error('type');
    }
  }
  send(c,type,payload){if(c.socket.writableLength>4*1024*1024){c.socket.destroy();return;}c.socket.write(encode(type,payload));}
  demand(){this.emit('video-demand',[...this.clients].filter(c=>c.ready&&!c.rtc).length);}
  signal(id,value){
    const c=[...this.clients].find(c=>c.id===id&&c.ready&&c.negotiating);
    if(!c||!this.realtime||!validSignal(value,'host')||value.type==='telemetry'&&!c.telemetry)return false;
    if(value.type==='fallback'){c.rtc=false;c.negotiating=false;c.credit=0;this.demand();}
    this.send(c,T.realtime,Buffer.from(JSON.stringify(value)));return true;
  }
  jpeg(data){if(!Buffer.isBuffer(data)||data.length<4||data.length>4194304||data[0]!==255||data[1]!==216)return false;
    for(const c of this.clients)if(c.ready&&!c.rtc&&c.credit<2&&c.socket.writableLength<524288){c.credit++;this.send(c,T.jpeg,data);}return true;}
  pcm(data,rate=48000,channels=2){if(!this.audioAvailable||!Buffer.isBuffer(data)||data.length>65536||data.length%(2*channels)||![1,2].includes(channels)||!Number.isInteger(rate)||rate<8000||rate>192000)return false;
    const config=Buffer.alloc(5);config.writeUInt32BE(rate);config[4]=channels;
    if(!this.audioConfig||!this.audioConfig.equals(config)){this.audioConfig=config;for(const c of this.clients)if(c.ready&&c.audio)this.send(c,T.audioConfig,config);}
    const pts=Buffer.alloc(8);pts.writeBigUInt64BE(BigInt(Date.now())*1000n);
    for(const c of this.clients)if(c.ready&&c.audio&&c.socket.writableLength<131072)this.send(c,T.audioFrame,Buffer.concat([pts,data]));return true;}
  async stop(){this.grants.clear();clearInterval(this.timer);this.timer=null;for(const socket of this.sockets)socket.destroy();this.sockets.clear();for(const c of this.clients)c.socket.destroy();this.clients.clear();this.input({t:'cancel'});
    const s=this.server;this.server=null;this.audioConfig=null;this.control=false;
    if(s)await new Promise(resolve=>s.close(resolve));this.key?.fill(0);this.key=null;this.emit('viewers',0);}
}
module.exports={Host,encode,addresses};
