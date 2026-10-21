'use strict';
const {app,dialog}=require('electron');
const path=require('node:path'),os=require('node:os');
const {launchOptions,createDiagnostics}=require('./core/startup.cjs');
const options=launchOptions();
let diagnostics,window,installed=false,failed=false,finished=false;
function logging(){if(diagnostics)return diagnostics;
 let directory=options.directory;
 if(!directory){
  if(options.test)directory=path.join(app.getPath('userData'),'startup-test-logs');
  else if(process.platform==='win32'&&process.env.LOCALAPPDATA)directory=path.join(process.env.LOCALAPPDATA,'Mac2Phone','logs');
  else directory=path.join(app.getPath('userData'),'logs');
 }
 diagnostics=createDiagnostics(directory);
 if(!diagnostics.available)diagnostics=createDiagnostics(path.join(os.tmpdir(),'Mac2Phone-logs'));
 return diagnostics;
}
function record(event,detail){logging().record(event,detail);}
function fail(phase,error){if(failed)return;failed=true;
 const detail=error instanceof Error?(error.stack||error.message):String(error);
 record('startup-failed',`${phase}: ${detail}`);
 logging().result({ok:false,phase,version:app.getVersion(),platform:process.platform,arch:process.arch});
 if(options.smoke){app.exit(1);return;}
 try{dialog.showErrorBox('Mac2Phone did not start',`The app stopped during ${phase}.\n\nA startup log is saved here:\n${logging().file}\n\nOn Windows, extract the entire ZIP and keep Mac2Phone.exe beside its resources folder and DLLs. You can also run Diagnose Mac2Phone.cmd to collect a launch result.`);}finally{
  app.quit();setTimeout(()=>app.exit(1),3000).unref();
 }
}
function install(){if(installed)return true;installed=true;
 if(options.smoke){const profile=path.join(logging().directory,'profile');require('node:fs').mkdirSync(profile,{recursive:true});app.setPath('userData',profile);}
 if(options.software)app.disableHardwareAcceleration();
 if(process.platform==='win32')app.setAppUserModelId('io.mac2phone.desktop');
 record('launch',JSON.stringify({version:app.getVersion(),electron:process.versions.electron,node:process.versions.node,platform:process.platform,arch:process.arch,softwareRendering:options.software,packaged:app.isPackaged}));
 if(!options.test&&!app.requestSingleInstanceLock()){record('existing-instance','Requested existing window to come forward');app.quit();return false;}
 app.on('second-instance',()=>{if(window&&!window.isDestroyed()){if(window.isMinimized())window.restore();window.show();window.focus();}});
 process.on('uncaughtException',e=>fail('main process',e));
 process.on('unhandledRejection',e=>fail('startup task',e));
 app.on('child-process-gone',(_event,info)=>record('child-process-gone',JSON.stringify({type:info.type,reason:info.reason,exitCode:info.exitCode})));
 app.on('quit',(_event,code)=>record('quit',String(code)));
 return true;
}
function trackWindow(value){window=value;record('window-created',options.test?'hidden test window':'visible window');
 const timeout=setTimeout(()=>fail('page load',Error('The interface did not finish loading within 20 seconds')),20000);timeout.unref();
 function clear(){clearTimeout(timeout);}
 value.once('closed',clear);
 value.webContents.on('preload-error',(_event,_file,error)=>fail('preload',error));
 value.webContents.on('did-fail-load',(_event,code,description,_url,isMainFrame)=>{if(isMainFrame&&code!==-3){clear();fail('page load',Error(`${code}: ${description}`));}});
 value.webContents.on('render-process-gone',(_event,info)=>{clear();fail('renderer',Error(`${info.reason}; exit ${info.exitCode}`));});
 value.webContents.once('did-finish-load',async()=>{
  clear();record('page-loaded');if(!options.test&&!value.isDestroyed())value.show();
  if(!options.smoke||failed||finished)return;
  try{
   const prefs=value.webContents.getLastWebPreferences();
   const ui=await value.webContents.executeJavaScript(`({bridge:typeof window.mac2phone,node:typeof require,nearby:!!document.getElementById('nearby-list'),controlsDisabled:document.getElementById('control')?.disabled===true,scripts:[...document.scripts].map(s=>s.src.split('/').pop())})`);
   if(!prefs.sandbox||!prefs.contextIsolation||prefs.nodeIntegration||ui.bridge!=='object'||ui.node!=='undefined'||!ui.nearby||!ui.controlsDisabled)throw Error('Startup checks did not pass');
   const tls=require('node:tls'),{CIPHER}=require('./core/pairing.cjs');tls.createSecureContext({minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER});
   if(typeof require('bonjour-service').Bonjour!=='function')throw Error('Discovery dependency is missing');
   finished=true;record('startup-smoke-passed','UI, preload, sandbox, TLS and discovery dependency');
   logging().result({ok:true,version:app.getVersion(),platform:process.platform,arch:process.arch,sandbox:prefs.sandbox,contextIsolation:prefs.contextIsolation,ui,softwareRendering:options.software});
   app.exit(0);
  }catch(error){fail('startup smoke',error);}
 });
}
module.exports={install,trackWindow,record,fail,options};
