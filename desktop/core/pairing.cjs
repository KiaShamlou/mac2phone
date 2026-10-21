'use strict';
const CIPHER='ECDHE-PSK-CHACHA20-POLY1305';
function parsePairing(raw) {
  if(typeof raw!=='string' || raw.length>1024) throw new Error('Paste a complete Mac2Phone pairing link.');
  const text=raw.trim();
  const match=/^mac2phone:\/\/([a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\]):([1-9][0-9]{0,4})#(v2|v3)\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})(?:\.([A-Za-z0-9_-]{43}))?$/.exec(text);
  if(!match || Number(match[2])>65535) throw new Error('Paste a complete Mac2Phone pairing link.');
  const key=Buffer.from(match[5],'base64url');
  if(key.length!==32 || key.toString('base64url')!==match[5]) throw new Error('Invalid pairing key.');
  if((match[3]==='v3')!==!!match[6]) throw new Error('Invalid approval link');
  const ticket=match[6]?Buffer.from(match[6],'base64url'):null;
  if(ticket&&(ticket.length!==32||ticket.toString('base64url')!==match[6]))throw new Error('Invalid approval ticket');
  return {ticket,host:match[1].replace(/^\[|\]$/g,''),port:Number(match[2]),identity:match[4],key};
}
module.exports={parsePairing,CIPHER};
