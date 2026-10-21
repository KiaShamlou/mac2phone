'use strict';
// Electron 44 requests `media` with an empty mediaTypes array for display
// capture. Camera/microphone requests have non-empty mediaTypes and stay denied.
// A permission check is not consent: only an explicit, short-lived selected
// display grant may reach the display-media handler.
class CapturePolicy {
 constructor({getContents,page,now=Date.now}){this.getContents=getContents;this.page=page;this.now=now;this.clear();}
 clear(){this.grant=null;this.approved=false;}
 trusted(contents,details){return !!contents&&!contents.isDestroyed()&&contents===this.getContents()&&contents.mainFrame.url===this.page&&details?.isMainFrame===true&&details.requestingUrl===this.page;}
 prepare(source,{audio=false}={}){this.clear();this.grant={source,audio,expires:this.now()+120000};}
 pending(){return !!this.grant&&this.grant.expires>this.now();}
 permission(contents,permission,details,kind){
  if(!this.pending()||!this.trusted(contents,details))return false;
  if(permission==='display-capture')return true;
  if(permission!=='media')return false;
  return kind==='request'?Array.isArray(details.mediaTypes)&&details.mediaTypes.length===0:details.mediaType==='unknown';
 }
 consume(request){
  const contents=this.getContents();
  if(!this.pending()||!contents||contents.isDestroyed()||request.frame!==contents.mainFrame||request.frame.url!==this.page||request.videoRequested!==true||request.userGesture!==true)return null;
  const grant=this.grant;this.grant=null;
  // Only the chosen screen and explicitly selected system audio are granted.
  this.approved=true;
  return {video:grant.source,...(grant.audio&&request.audioRequested?{audio:'loopback'}:{})};
 }
}
function installCapturePermissions(session,policy,{record=()=>{}}={}){
 session.setPermissionRequestHandler((contents,permission,callback,details)=>{
  const allowed=policy.permission(contents,permission,details,'request');
  record('request',{permission,allowed});callback(allowed);
 });
 session.setPermissionCheckHandler((contents,permission,_origin,details)=>{
  const allowed=policy.permission(contents,permission,details,'check');record('check',{permission,allowed});return allowed;
 });
 session.setDisplayMediaRequestHandler((request,callback)=>{
  const streams=policy.consume(request);record('display',{allowed:!!streams});callback(streams);
 });
}
module.exports={CapturePolicy,installCapturePermissions};
