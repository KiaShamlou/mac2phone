'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('fixtureHost',{
 send:(id,value)=>ipcRenderer.invoke('fixture:realtime',id,value),
 on:(name,callback)=>ipcRenderer.on('fixture:'+name,(_event,value)=>callback(value))
});
