'use strict';
const fs=require('node:fs'),path=require('node:path'),{randomUUID}=require('node:crypto');
const defaults=Object.freeze({quality:'auto',fps:60,autoFullscreen:true});
const validators={quality:v=>['auto','fast','balanced','sharp'].includes(v),fps:v=>v===30||v===60,autoFullscreen:v=>typeof v==='boolean'};
function validPatch(value){return !!value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).every(key=>Object.hasOwn(validators,key)&&validators[key](value[key]));}
class Preferences {
 constructor(file){
  this.file=file;this.value={...defaults};
  try{
   if(fs.statSync(file).size>4096)return;
   const data=JSON.parse(fs.readFileSync(file,'utf8'));
   if(data?.version!==1||!validPatch(data.preferences))return;
   this.value={...defaults,...data.preferences};
  }catch{} // First launch, corrupt settings or a full disk must not break startup.
 }
 get(){return {...this.value};}
 update(patch){
  if(!validPatch(patch))return {ok:false};
  const next={...this.value,...patch},temporary=this.file+'.'+randomUUID()+'.tmp';
  try{
   fs.mkdirSync(path.dirname(this.file),{recursive:true});
   fs.writeFileSync(temporary,JSON.stringify({version:1,preferences:next})+'\n',{mode:0o600,flag:'wx'});
   fs.renameSync(temporary,this.file);this.value=next;
   return {ok:true,preferences:this.get()};
  }catch{try{fs.unlinkSync(temporary);}catch{}return {ok:false};}
 }
}
module.exports={Preferences,defaults,validPatch};
