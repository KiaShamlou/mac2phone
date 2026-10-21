'use strict';
const named=new Set(['return','enter','tab','space','delete','backspace','escape','forwarddelete',
  'left','right','down','up','home','end','pageup','pagedown','equal','minus','rightbracket','leftbracket',
  'backslash','quote','semicolon','comma','slash','period','grave',...Array.from({length:12},(_,i)=>`f${i+1}`)]);
function validateInput(input) {
  if(!input || typeof input!=='object' || Array.isArray(input)) return false;
  const unit=k=>Number.isFinite(input[k])&&input[k]>=0&&input[k]<=1;
  const button=()=>Number.isInteger(input.b)&&input.b>=0&&input.b<=2;
  switch(input.t) {
    case 'm': return unit('x')&&unit('y');
    case 'g': return unit('x')&&unit('y')&&button();
    case 'd': case 'u': return button();
    case 's': return ['dx','dy'].every(k=>Number.isFinite(input[k])&&Math.abs(input[k])<=1000);
    case 'txt': return typeof input.s==='string'&&input.s.length>0&&Buffer.byteLength(input.s)<=8192;
    case 'key': return typeof input.k==='string'&&(/^[a-z0-9]$/.test(input.k)||named.has(input.k))&&
      Array.isArray(input.m)&&input.m.length<=4&&input.m.every(v=>['cmd','ctrl','alt','shift'].includes(v));
    case 'cancel': return true;
    default: return false;
  }
}
module.exports={validateInput};

// Native touch clients use semantic gestures; desktop hosts adapt them to pointers.
function normalizeInput(value){
  if(validateInput(value))return value;
  if(!value||typeof value!=='object')return null;
  const pos=()=>Number.isFinite(value.x)&&Number.isFinite(value.y)&&value.x>=0&&value.x<=1&&value.y>=0&&value.y<=1;
  if(value.t==='c'&&pos()&&Number.isInteger(value.b)&&value.b>=0&&value.b<=2)return {t:'click',x:value.x,y:value.y,b:value.b};
  if(['tap','tap2'].includes(value.t)&&pos())return {t:'click',x:value.x,y:value.y,b:value.t==='tap2'?1:0};
  if(['dbeg','dmov','dend'].includes(value.t)&&pos())return {t:({dbeg:'drag-start',dmov:'g',dend:'drag-end'})[value.t],x:value.x,y:value.y,b:0};
  return null;
}
module.exports.normalizeInput=normalizeInput;
