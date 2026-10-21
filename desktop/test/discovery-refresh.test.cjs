'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const crypto=require('node:crypto');
test('discovery retries the lost startup query, refreshes on network changes, accepts TXT updates and stops cleanly',async t=>{
 const module=require('bonjour-service'),Original=module.Bonjour;
 let instance;
 class FakeBonjour {
  constructor(){instance=this;this.queries=0;this.expires=0;this.server={mdns:new EventEmitter()};this.browser=new EventEmitter();this.browser.update=()=>this.queries++;this.browser.expire=()=>this.expires++;this.browser.stop=()=>{};}
  publish(){const service=new EventEmitter();service.stop=callback=>callback();return service;}
  find(){this.browser.update();return this.browser;}
  destroy(){}
 }
 module.Bonjour=FakeBonjour;t.after(()=>module.Bonjour=Original);
 t.mock.timers.enable({apis:['setInterval','Date'],now:1000});
 const {Nearby}=require(process.env.M2P_NEARBY_MODULE||'../core/nearby.cjs');
 const viewer=new Nearby({name:'Fixture Mac',platform:'darwin'});
 t.after(()=>viewer.stop());
 await viewer.start({bind:'127.0.0.1'});
 assert.equal(instance.queries,1,'initial query');
 t.mock.timers.tick(5000);
 assert.equal(instance.queries,2,'a lost initial query is retried without restarting');
 assert.equal(instance.expires,1);
 t.mock.timers.tick(5000);assert.equal(instance.queries,3);
 t.mock.timers.tick(1001);instance.server.mdns.emit('networkInterface');assert.equal(instance.queries,4);
 assert.equal(viewer.refresh(),true);assert.equal(instance.queries,4,'manual clicks are rate limited');
 t.mock.timers.tick(1001);assert.equal(viewer.refresh(),true);assert.equal(instance.queries,5);
 const id=crypto.randomUUID();
 instance.browser.emit('txt-update',{txt:{v:'1',id,name:'Windows fixture',platform:'win32'},addresses:['192.168.59.115'],port:12345});
 assert.equal(viewer.peers.get(id)?.name,'Windows fixture');
 await viewer.stop();const count=instance.queries;
 t.mock.timers.tick(15000);assert.equal(instance.queries,count);assert.equal(viewer.refresh(),false);
});
