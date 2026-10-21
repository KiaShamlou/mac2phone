'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const MAX_LOG=512*1024;
function launchOptions(argv=process.argv,env=process.env){const smoke=argv.includes('--m2p-startup-smoke');const output=smoke?argv.find(a=>a.startsWith('--m2p-diagnostics-dir='))?.slice('--m2p-diagnostics-dir='.length):null;
 return{smoke,test:smoke||env.M2P_UI_TEST==='1',software:argv.includes('--m2p-software-rendering'),directory:output&&path.isAbsolute(output)?output:null};}
function windowOptions(test=false){return{width:1180,height:820,minWidth:760,minHeight:540,backgroundColor:'#111718',title:'Mac2Phone',autoHideMenuBar:true,show:!test};}
function redact(value,home=os.homedir()){
 let s=String(value??'').replace(/mac2phone:\/\/[^\s"'<>]+/gi,'[private pairing link]')
  .replace(/\bv[23]\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}(?:\.[A-Za-z0-9_-]{43})?/gi,'[pairing credentials]');
 if(home)s=s.split(home).join('[home]');return s.slice(0,16000);
}
function createDiagnostics(directory,{home=os.homedir(),now=()=>new Date().toISOString()}={}){
 const file=path.join(directory,'startup.log');let available=false;
 try{fs.mkdirSync(directory,{recursive:true});if(fs.existsSync(file)&&fs.statSync(file).size>MAX_LOG)fs.renameSync(file,file+'.previous');available=true;}catch{}
 function record(event,detail=''){if(!available)return;try{if(fs.existsSync(file)&&fs.statSync(file).size>MAX_LOG)fs.renameSync(file,file+'.previous');fs.appendFileSync(file,`${now()} ${redact(event,home)} ${redact(detail,home)}\n`,{mode:0o600});}catch{available=false;}}
 function result(value){if(!available)return;try{fs.writeFileSync(path.join(directory,'startup-result.json'),JSON.stringify(value,null,2)+'\n',{mode:0o600});}catch{}}
 return {file,directory,record,result,get available(){return available;}};
}
function missingRuntime(directory){return ['Mac2Phone.exe','resources/app.asar','resources.pak','icudtl.dat','ffmpeg.dll','chrome_100_percent.pak','chrome_200_percent.pak','v8_context_snapshot.bin','locales/en-US.pak'].filter(f=>!fs.existsSync(path.join(directory,f)));}
module.exports={launchOptions,windowOptions,redact,createDiagnostics,missingRuntime,MAX_LOG};
