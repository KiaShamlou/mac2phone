'use strict';
const {randomBytes}=require('node:crypto');
/** One connection, 60 seconds, memory only. Stop/rotation clears every grant. */
class Grants {
  constructor(now=Date.now){this.now=now;this.entries=new Map();}
  prune(){for(const [key,expiry] of this.entries)if(expiry<=this.now())this.entries.delete(key);}
  issue(){this.prune();if(this.entries.size>=8)throw Error('Too many pending approvals');const token=randomBytes(32);this.entries.set(token.toString('hex'),this.now()+60000);return token;}
  consume(token){this.prune();const key=Buffer.from(token).toString('hex'),ok=this.entries.has(key);this.entries.delete(key);return ok;}
  clear(){this.entries.clear();}
}
module.exports={Grants};
