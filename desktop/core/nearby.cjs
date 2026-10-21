'use strict';
const net=require('node:net'),crypto=require('node:crypto'),os=require('node:os');
const {EventEmitter}=require('node:events');
const {parsePairing}=require('./pairing.cjs');
const INFO=Buffer.from('Mac2Phone Nearby v1');
const platforms=new Set(['macos','darwin','win32','linux','android','ios']);
function name(value){if(typeof value!=='string'||!value.trim()||Buffer.byteLength(value)>128||/[\p{C}]/u.test(value))throw Error('Invalid device name');return value;}
function hello(value,revealed=false){if(value?.v!==1||!platforms.has(value.platform))throw Error('Incompatible request');name(value.name);decode(revealed?value.key:value.commit,32);return value;}
function decode(value,size){if(typeof value!=='string'||value.length>6000)throw Error('Invalid encoding');const b=Buffer.from(value,'base64');if(b.toString('base64')!==value||(size&&b.length!==size))throw Error('Invalid encoding');return b;}
function keypair(){const {publicKey,privateKey}=crypto.generateKeyPairSync('x25519');return {privateKey,publicKey:publicKey.export({format:'der',type:'spki'}).subarray(-32)};}
function agreement(privateKey,request,hostKey){hello(request,true);const clientKey=decode(request.key,32),serverKey=decode(hostKey,32);
 const own=crypto.createPublicKey(privateKey).export({format:'der',type:'spki'}).subarray(-32);
 const peer=own.equals(clientKey)?serverKey:clientKey;
 const shared=crypto.diffieHellman({privateKey,publicKey:crypto.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b656e032100','hex'),peer]),format:'der',type:'spki'})});
 const transcript=Buffer.concat([Buffer.from(`${request.name}\n${request.platform}\n`),clientKey,serverKey]);
 const key=Buffer.from(crypto.hkdfSync('sha256',shared,Buffer.alloc(32),Buffer.concat([INFO,transcript]),32));shared.fill(0);
 const digest=crypto.createHash('sha256').update(key).update(transcript).digest();
 return {key,code:String(digest.readUIntBE(0,3)%1000000).padStart(6,'0')};
}
function seal(key,value){const nonce=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(INFO);const ciphertext=Buffer.concat([cipher.update(JSON.stringify(value)),cipher.final()]);return Buffer.concat([nonce,ciphertext,cipher.getAuthTag()]).toString('base64');}
function open(key,value){const b=decode(value);if(b.length<28||b.length>4096)throw Error('Invalid envelope');const d=crypto.createDecipheriv('aes-256-gcm',key,b.subarray(0,12));d.setAAD(INFO);d.setAuthTag(b.subarray(-16));return JSON.parse(Buffer.concat([d.update(b.subarray(12,-16)),d.final()]).toString());}
class Channel {
 constructor(socket){this.socket=socket;this.buffer=Buffer.alloc(0);this.messages=[];this.waiter=null;this.dead=false;
 socket.on('data',b=>{try{this.buffer=Buffer.concat([this.buffer,b]);if(this.buffer.length>4100)throw Error('Size');while(this.buffer.length>=4){const n=this.buffer.readUInt32BE();if(n<2||n>4096)throw Error('Size');if(this.buffer.length<n+4)break;const value=JSON.parse(this.buffer.subarray(4,n+4));this.buffer=this.buffer.subarray(n+4);if(this.waiter){const w=this.waiter;this.waiter=null;w.resolve(value);}else{if(this.messages.length>=1)throw Error('Unexpected message');this.messages.push(value);}}}catch{socket.destroy();}});
 const fail=()=>{this.dead=true;this.waiter?.reject(Error('Request ended'));this.waiter=null;};socket.on('error',fail);socket.on('close',fail);socket.setTimeout(120000,()=>socket.destroy());socket.setNoDelay(true);
 }
 read(){if(this.messages.length)return Promise.resolve(this.messages.shift());if(this.dead||this.waiter)return Promise.reject(Error('Request ended'));return new Promise((resolve,reject)=>this.waiter={resolve,reject});}
 send(value){const b=Buffer.from(JSON.stringify(value));if(this.dead||b.length>4096)throw Error('Request ended');const h=Buffer.alloc(4);h.writeUInt32BE(b.length);this.socket.write(Buffer.concat([h,b]));}
}
class Nearby extends EventEmitter {
 constructor({name:label=os.hostname().split('.')[0],platform=process.platform,approve=async()=>null}={}){super();this.name=name(label);this.platform=platform;this.approve=approve;this.id=crypto.randomUUID();this.peers=new Map();this.sockets=new Set();this.recent=new Map();this.active=false;}
 async start({bind='0.0.0.0',port=0,discover=true}={}){if(this.server)return;this.active=true;const server=net.createServer(s=>this.accept(s));this.server=server;server.maxConnections=4;server.on('error',()=>this.emit('notice','Nearby discovery is unavailable. Check your local-network access.'));
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,bind,()=>{server.removeListener('error',reject);resolve();});});this.port=server.address().port;
 if(discover){const {Bonjour}=require('bonjour-service');this.bonjour=new Bonjour({},()=>this.emit('notice','Nearby discovery is unavailable on this network.'));
 this.service=this.bonjour.publish({name:`${this.name.slice(0,24)} ${this.id.slice(0,8)}`,type:'m2p-nearby',port:this.port,txt:{v:'1',id:this.id,name:this.name,platform:this.platform}});this.service.on('error',()=>this.emit('notice','Nearby advertising failed.'));
 this.browser=this.bonjour.find({type:'m2p-nearby'});this.browser.on('up',s=>this.found(s));this.browser.on('down',s=>{this.peers.delete(s.txt?.id);this.changed();});this.browser.on('srv-update',s=>this.found(s));this.browser.on('txt-update',s=>this.found(s));
 // Bonjour's browser queries only once. Retry after a lost startup packet,
 // a newly granted LAN permission, sleep, or a Wi-Fi/network transition.
 this.bonjour.server.mdns.on('networkInterface',()=>this.refresh());
 this.expiry=setInterval(()=>{this.browser?.expire();this.refresh();},5000);this.expiry.unref();}
 }
 refresh(){
  if(!this.active||!this.browser)return false;
  const now=Date.now();if(this.lastQuery&&now-this.lastQuery<1000)return true;this.lastQuery=now;
  try{this.browser.update();return true;}catch{this.emit('notice','Discovery could not refresh. Check local-network access.');return false;}
 }
 found(s){try{const t=s.txt;if(t?.v!=='1'||t.id===this.id||!(/^[0-9a-f-]{36}$/).test(t.id)||!platforms.has(t.platform)||this.peers.size>=128&&!this.peers.has(t.id))return;name(t.name);const host=s.addresses?.find(a=>net.isIP(a)===4);if(!host||!Number.isInteger(s.port)||s.port<1||s.port>65535)return;this.peers.set(t.id,{id:t.id,name:t.name,platform:t.platform,host,port:s.port});this.changed();}catch{}}
 changed(){this.emit('devices',[...this.peers.values()].sort((a,b)=>a.name.localeCompare(b.name)).map(({host,port,...v})=>v));}
 async accept(socket){if(!this.active||this.sockets.size>=4){socket.destroy();return;}const now=Date.now();for(const [ip,time]of this.recent)if(now-time>10000)this.recent.delete(ip);const address=socket.remoteAddress;if(this.recent.has(address)||this.recent.size>=128){socket.destroy();return;}this.recent.set(address,now);this.sockets.add(socket);socket.on('close',()=>this.sockets.delete(socket));const ch=new Channel(socket);const initial=setTimeout(()=>socket.destroy(),8000);let key;
 try{const request=hello(await ch.read());const pair=keypair();ch.send({v:1,key:pair.publicKey.toString('base64')});
 const reveal=await ch.read(),publicKey=decode(reveal.key,32),nonce=decode(reveal.nonce,32);
 const commitment=crypto.createHash('sha256').update(publicKey).update(nonce).digest();
 if(!crypto.timingSafeEqual(commitment,decode(request.commit,32)))throw Error('Commitment mismatch');
 request.key=reveal.key;const state=agreement(pair.privateKey,request,pair.publicKey.toString('base64'));key=state.key;clearTimeout(initial);
 const controller=new AbortController(),abort=()=>controller.abort();socket.once('close',abort);const timer=setTimeout(()=>socket.destroy(),120000);
 try{const link=await this.approve({name:request.name,platform:request.platform,code:state.code,signal:controller.signal});if(!this.active||socket.destroyed)return;if(link)parsePairing(link);ch.send({box:seal(key,link?{status:'accepted',link}:{status:'declined'})});socket.end();}finally{clearTimeout(timer);socket.removeListener('close',abort);}
 }catch{socket.destroy();}finally{clearTimeout(initial);key?.fill(0);}
 }
 async request(id){const p=this.peers.get(id);if(!p||this.outgoing)throw Error('Device unavailable or a request is already pending');const socket=net.connect(p.port,p.host);this.outgoing=socket;const ch=new Channel(socket);let key;const timer=setTimeout(()=>socket.destroy(),120000);
 try{await new Promise((resolve,reject)=>{socket.once('connect',resolve);socket.once('error',reject);});const pair=keypair(),request={v:1,name:this.name,platform:this.platform,key:pair.publicKey.toString('base64')};const nonce=crypto.randomBytes(32),commit=crypto.createHash('sha256').update(pair.publicKey).update(nonce).digest('base64');const {key:unused,...publicRequest}=request;ch.send({...publicRequest,commit});const reply=await ch.read();if(reply.v!==1)throw Error('Incompatible device');const state=agreement(pair.privateKey,request,reply.key);key=state.key;ch.send({key:request.key,nonce:nonce.toString('base64')});this.emit('request-state',{state:'waiting',name:p.name,code:state.code});const result=open(key,(await ch.read()).box);if(result.status!=='accepted')throw Error('Request declined');parsePairing(result.link);const url=new URL(result.link);url.hostname=p.host.includes(':')?`[${p.host}]`:p.host;parsePairing(url.href);return url.href;
 }finally{clearTimeout(timer);key?.fill(0);socket.destroy();if(this.outgoing===socket)this.outgoing=null;}
 }
 cancel(){this.outgoing?.destroy();this.outgoing=null;}
 async stop(){this.active=false;this.cancel();clearInterval(this.expiry);this.browser?.stop();if(this.service){const service=this.service;this.service=null;await new Promise(resolve=>service.stop(resolve));}this.bonjour?.destroy();this.bonjour=null;for(const s of this.sockets)s.destroy();this.sockets.clear();this.peers.clear();this.changed();const s=this.server;this.server=null;if(s)await new Promise(r=>s.close(r));}
}
module.exports={Nearby,Channel,keypair,agreement,seal,open,hello};
