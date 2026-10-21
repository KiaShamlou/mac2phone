'use strict';
// Shared by JPEG and realtime video, in a window or fullscreen, at any DPI.
function remotePoint(box,width,height,event){
 const scale=Math.min(box.width/width,box.height/height),w=width*scale,h=height*scale;
 if(!Number.isFinite(scale)||scale<=0||!w||!h)return{x:0,y:0,inside:false};
 const x=(event.clientX-box.left-(box.width-w)/2)/w,y=(event.clientY-box.top-(box.height-h)/2)/h;
 return{x:Math.max(0,Math.min(1,x)),y:Math.max(0,Math.min(1,y)),inside:x>=0&&x<=1&&y>=0&&y<=1};
}
if(typeof module!=='undefined')module.exports={remotePoint};
else window.M2PViewport={remotePoint};
