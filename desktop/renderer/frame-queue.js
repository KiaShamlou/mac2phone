'use strict';
(()=>{
 // At most one decode plus one newest pending JPEG, even if a sender bursts.
 class LatestFrame {
  constructor({decode,draw,ack,valid,error=()=>{}}){Object.assign(this,{decode,draw,ack,valid,error});this.pending=null;this.busy=false;}
  push(data,token){
   if(this.pending)this.ack(this.pending.token);
   this.pending={data,token};
   if(!this.busy)this.run();
  }
  clear(){if(this.pending)this.ack(this.pending.token);this.pending=null;}
  async run(){
   this.busy=true;
   while(this.pending){
    const item=this.pending;this.pending=null;let image;
    try{
     if(!this.valid(item.token))continue;
     image=await this.decode(item.data);
     if(this.valid(item.token))this.draw(image);
    }catch(error){if(this.valid(item.token))this.error(error);}
    finally{image?.close();this.ack(item.token);}
   }
   this.busy=false;
  }
 }
 if(typeof module!=='undefined')module.exports={LatestFrame};else window.M2PLatestFrame=LatestFrame;
})();
