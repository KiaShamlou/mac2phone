'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const allowed=new Set(['state','video','audio','audio-format','latency','notice','blur','host-viewers','host-stopped','nearby-devices','nearby-request-state','nearby-incoming','realtime','host-realtime','host-realtime-close','host-video-demand','fullscreen']);
contextBridge.exposeInMainWorld('mac2phone',{
  preferences:()=>ipcRenderer.invoke('m2p:preferences'),
  savePreferences:value=>ipcRenderer.invoke('m2p:save-preferences',value),
  fullscreen:on=>ipcRenderer.invoke('m2p:fullscreen',on),
  copyDiagnostics:value=>ipcRenderer.invoke('m2p:copy-diagnostics',value),
  realtime:value=>ipcRenderer.invoke('m2p:realtime',value),
  hostRealtime:(id,value)=>ipcRenderer.invoke('m2p:host-realtime',id,value),
  nearbyList:()=>ipcRenderer.invoke('m2p:nearby-list'),
  nearbyRefresh:()=>ipcRenderer.invoke('m2p:nearby-refresh'),
  nearbyRequest:id=>ipcRenderer.invoke('m2p:nearby-request',id),
  nearbyCancel:()=>ipcRenderer.invoke('m2p:nearby-cancel'),
  nearbyRespond:(id,accept)=>ipcRenderer.invoke('m2p:nearby-respond',id,accept),
  hostCapabilities:()=>ipcRenderer.invoke('m2p:host-capabilities'),
  hostSettings:()=>ipcRenderer.invoke('m2p:host-settings'),
  hostReset:()=>ipcRenderer.invoke('m2p:host-reset'),
  hostSources:()=>ipcRenderer.invoke('m2p:host-sources'),
  hostPrepare:options=>ipcRenderer.invoke('m2p:host-prepare',options),
  hostStart:options=>ipcRenderer.invoke('m2p:host-start',options),
  hostStop:()=>ipcRenderer.invoke('m2p:host-stop'),
  hostCopy:()=>ipcRenderer.invoke('m2p:host-copy'),
  hostVideo:data=>ipcRenderer.invoke('m2p:host-video',data),
  hostAudio:(data,rate,channels)=>ipcRenderer.invoke('m2p:host-audio',data,rate,channels),
  connect:link=>ipcRenderer.invoke('m2p:connect',link),
  disconnect:()=>ipcRenderer.send('m2p:disconnect'),
  control:on=>ipcRenderer.invoke('m2p:control',on),
  input:value=>ipcRenderer.send('m2p:input',value),
  audio:on=>ipcRenderer.send('m2p:audio',on),
  ackVideo:()=>ipcRenderer.send('m2p:ack-video'),ackAudio:()=>ipcRenderer.send('m2p:ack-audio'),
  on:(name,callback)=>{
    if(!allowed.has(name)||typeof callback!=='function') return ()=>{};
    const listener=(_event,value)=>callback(value); ipcRenderer.on(`m2p:${name}`,listener);
    return ()=>ipcRenderer.removeListener(`m2p:${name}`,listener);
  }
});
