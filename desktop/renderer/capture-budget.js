'use strict';
(()=>{
 // Constrain the selected capture track, never the physical monitor. The
 // highest-demand viewer wins; a small viewer cannot shrink another's stream.
 function budget(native,profiles=[],legacy=0){
  const wanted=profiles.length||legacy?{width:legacy?1920:0,fps:legacy?30:0}:{width:960,fps:15};
  for(const profile of profiles){wanted.width=Math.max(wanted.width,profile.width);wanted.fps=Math.max(wanted.fps,profile.fps);}
  const scale=Math.min(1,wanted.width/Math.max(native.width,native.height));
  return {width:Math.max(1,Math.floor(native.width*scale)),height:Math.max(1,Math.floor(native.height*scale)),fps:wanted.fps};
 }
 class CaptureBudget {
  constructor(track,{applied=()=>{},failed=()=>{}}={}){
   this.track=track;this.native=track.getSettings();this.applied=applied;this.failed=failed;this.live=true;
   this.queue=Promise.resolve();this.revision=0;this.last=null;
  }
  update(profiles=[],legacy=0){
   if(!this.live||!this.native.width||!this.native.height)return this.queue;
   const next=budget(this.native,profiles,legacy),key=JSON.stringify(next);
   if(key===this.requested)return this.queue;
   this.requested=key;const revision=++this.revision;
   this.queue=this.queue.then(async()=>{
    if(!this.live||revision!==this.revision||this.track.readyState!=='live')return;
    try{
     // Preserve cursor/display-selection constraints from the granted track.
     await this.track.applyConstraints({...this.track.getConstraints(),width:{max:next.width},height:{max:next.height},frameRate:{max:next.fps}});
     if(!this.live)return;
     this.last=next;this.applied(this.track.getSettings());
    }catch(error){
     // Unsupported capture constraints must not end an approved session.
     if(this.live){this.requested=null;this.failed(error);}
    }
   });
   return this.queue;
  }
  stop(){this.live=false;++this.revision;}
 }
 const value={budget,CaptureBudget};
 if(typeof module!=='undefined')module.exports=value;else window.M2PCaptureBudget=value;
})();
