'use strict';
const {contextBridge}=require('electron');
const listeners={},state={sources:0,prepares:[],starts:[],stops:0,resets:0,frames:0,audio:0,copies:0};
const emit=(name,value)=>(listeners[name]||[]).forEach(callback=>callback(value));
const caps={platform:'win32',name:'Windows laptop',screenStatus:'needs-selection',control:true,audio:true,settings:false};
contextBridge.exposeInMainWorld('mac2phone',{
 hostCapabilities:async()=>caps,hostSettings:async()=>false,
 hostSources:async()=>{state.sources++;return {ok:true,...caps,sources:[{id:'fixture:1',name:'Built-in display'},{id:'fixture:2',name:'External display'}]};},
 hostPrepare:async options=>{state.prepares.push(options);return {ok:true,control:options.control,audio:options.audio};},
 hostStart:async options=>{state.starts.push(options);emit('host-video-demand',1);return {ok:true,viewers:1,control:state.prepares.at(-1).control,audio:options.audio};},
 hostStop:async()=>{state.stops++;emit('host-stopped',true);},hostReset:async()=>{state.resets++;return true;},
 hostVideo:async()=>{state.frames++;return true;},hostAudio:async()=>{state.audio++;return true;},hostCopy:async()=>{state.copies++;return true;},
 nearbyList:async()=>[{id:'test-mac',name:'Studio Mac',platform:'macos'},{id:'test-phone',name:'My iPhone',platform:'ios'}],nearbyRefresh:async()=>({ok:true}),nearbyCancel:async()=>{},nearbyRespond:async()=>({ok:false,message:'Set up your screen first.'}),
 input:()=>{},ackVideo:()=>{},ackAudio:()=>{},audio:()=>{},control:async()=>false,disconnect:()=>{},
 on:(name,callback)=>{(listeners[name]??=[]).push(callback);return()=>{};}
});
contextBridge.exposeInMainWorld('sharingFixture',{snapshot:()=>state,emit});
