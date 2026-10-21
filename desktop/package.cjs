'use strict';
// Use the API instead of shell regex arguments, which differ between cmd and sh.
const path=require('node:path');
const fs=require('node:fs');
(async()=>{
  const {packager}=await import('@electron/packager');
  const platform=process.argv[2];
  if(!['win32','linux','darwin'].includes(platform))throw new Error('Choose win32, linux or darwin');
  const outputs=await packager({dir:__dirname,name:platform==='darwin'?'Mac2PhoneDesktop':'Mac2Phone',platform,arch:process.argv[3]??(platform==='darwin'?'arm64':'x64'),
    out:path.resolve(process.env.M2P_RELEASE_DIR||path.join(__dirname,'release')),overwrite:true,prune:true,asar:{unpackDir:'native'},
    extraResource:[path.join(__dirname,'../LICENSE')],
    ...(platform==='darwin'?{
      appBundleId:'io.mac2phone.desktop',
      icon:path.join(__dirname,'../Branding/Mac2Phone.icns'),
      extendInfo:{
        NSLocalNetworkUsageDescription:'Find nearby Mac2Phone devices and ask before sharing.',
        NSBonjourServices:['_m2p-nearby._tcp'],
        NSAudioCaptureUsageDescription:'Share system sound with your paired devices.',
        NSMicrophoneUsageDescription:'Audio capture for a sharing session you start.'
      }
    }:{}),
    ignore:[/^\/(test|release|windows)(\/|$)/,/^\/package\.cjs$/]});
  for(const output of outputs){
    if(platform==='win32')for(const name of fs.readdirSync(path.join(__dirname,'windows')))
      fs.copyFileSync(path.join(__dirname,'windows',name),path.join(output,name));
    console.log(output);
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
