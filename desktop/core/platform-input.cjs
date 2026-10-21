'use strict';
const {spawn,spawnSync}=require('node:child_process');
const path=require('node:path');
// External processes do not understand Electron's virtual ASAR filesystem.
function helperPath(directory=__dirname){return path.join(directory,'../native/input-windows.ps1').replace(/app\.asar([/\\])/,'app.asar.unpacked$1');}
class PlatformInput{
 constructor(){this.process=null;this.bounds={x:0,y:0,width:1,height:1};this.queue=[];this.busy=false;this.active=false;}
 available(){return process.platform==='win32'||(process.platform==='linux'&&!process.env.WAYLAND_DISPLAY&&spawnSync('which',['xdotool']).status===0);}
 async start(bounds){if(!this.available())return false;this.bounds=bounds;this.active=true;
  if(process.platform==='win32'){
   this.process=spawn('powershell.exe',['-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helperPath()],{windowsHide:true,stdio:['pipe','pipe','pipe']});
   const child=this.process;
   try{await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Input helper timeout')),10000);child.stdout.once('data',b=>{clearTimeout(timer);b.toString().includes('READY')?resolve():reject(Error('Input helper failed'));});child.once('error',reject);child.once('exit',()=>reject(Error('Input helper stopped')));});}
   catch{this.stop();return false;}
   child.on('error',()=>{this.active=false;});child.on('exit',()=>{this.active=false;});child.stdin.on('error',()=>{this.active=false;});
  }return true;
 }
 send(value){if(!this.active)return;const v={...value};
  if(['click','drag-start','drag-end'].includes(v.t)){
   this.send({...v,t:'m'});
   if(v.t!=='drag-end')this.send({t:'d',b:v.b});
   if(v.t!=='drag-start')this.send({t:'u',b:v.b});return;
  }
  if(v.x!==undefined){v.x=Math.round(this.bounds.x+v.x*Math.max(0,this.bounds.width-1));v.y=Math.round(this.bounds.y+v.y*Math.max(0,this.bounds.height-1));}
  if(this.process){if(this.process.stdin.writableLength>32768){this.stop();return;}this.process.stdin.write(JSON.stringify(v)+'\n');}
  else{if(this.queue.length>128){this.stop();return;}this.queue.push(v);this.pump();}
 }
 pump(){if(this.busy||!this.queue.length||!this.active)return;this.busy=true;const v=this.queue.shift();let args=[];
  const b=[1,3,2][v.b??0];
  if(['m','g'].includes(v.t))args=['mousemove','--sync',String(v.x),String(v.y)];
  if(v.t==='d'||v.t==='u')args=[v.t==='d'?'mousedown':'mouseup',String(b)];
  if(v.t==='txt')args=['type','--clearmodifiers','--delay','0','--',v.s];
  if(v.t==='s'){const amount=Math.min(20,Math.max(1,Math.round(Math.max(Math.abs(v.dx),Math.abs(v.dy))/40)));args=['click','--repeat',String(amount),'--delay','0',String(Math.abs(v.dy)>=Math.abs(v.dx)?(v.dy>0?4:5):(v.dx>0?6:7))];}
  if(v.t==='key'){const keys={return:'Return',enter:'Return',backspace:'BackSpace',delete:'BackSpace',forwarddelete:'Delete',escape:'Escape',pageup:'Prior',pagedown:'Next',space:'space',equal:'equal',minus:'minus',rightbracket:'bracketright',leftbracket:'bracketleft',backslash:'backslash',quote:'apostrophe',semicolon:'semicolon',comma:'comma',slash:'slash',period:'period',grave:'grave'};const mods={cmd:'super',ctrl:'ctrl',alt:'alt',shift:'shift'};const key=keys[v.k]??(/^(left|right|up|down|home|end|tab|f\d+)$/.test(v.k)?v.k[0].toUpperCase()+v.k.slice(1):v.k);args=['key','--clearmodifiers',[...v.m.map(m=>mods[m]),key].join('+')];}
  if(v.t==='cancel')args=['mouseup','1','mouseup','2','mouseup','3'];
  if(!args.length){this.busy=false;this.pump();return;}
  const child=spawn('xdotool',args,{stdio:'ignore'});const next=()=>{this.busy=false;this.pump();};child.once('close',next);child.once('error',()=>{this.active=false;});
 }
 stop(){if(this.process){this.process.stdin.end('{"t":"cancel"}\n');const p=this.process;setTimeout(()=>p.kill(),1000).unref();this.process=null;}
  else if(this.active)spawn('xdotool',['mouseup','1','mouseup','2','mouseup','3'],{stdio:'ignore'}).on('error',()=>{});
  this.active=false;this.queue=[];
 }
}
module.exports={PlatformInput,helperPath};
