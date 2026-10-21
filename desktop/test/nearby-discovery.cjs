'use strict';
// Real mDNS on this host using synthetic names, with no capture or input.
const assert=require('node:assert/strict');const {Nearby}=require('../core/nearby.cjs');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{const a=new Nearby({name:'M2P Discovery Fixture A',platform:'linux'}),b=new Nearby({name:'M2P Discovery Fixture B',platform:'win32'});
try{await a.start();await b.start();for(let i=0;i<100&&(!a.peers.has(b.id)||!b.peers.has(a.id));i++)await sleep(100);assert(a.peers.has(b.id),'A finds B');assert(b.peers.has(a.id),'B finds A');assert(!a.peers.has(a.id));assert(!b.peers.has(b.id));console.log('PASS real Bonjour discovery, cross-instance presence, self exclusion');await b.stop();for(let i=0;i<50&&a.peers.has(b.id);i++)await sleep(100);assert(!a.peers.has(b.id),'goodbye removes offline device');console.log('PASS Bonjour goodbye removes offline device');}finally{await a.stop();await b.stop();}})().catch(e=>{console.error(e);process.exitCode=1;});
