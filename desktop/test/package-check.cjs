'use strict';
// Inspect actual distributables, not just the source package.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const {extractFile,statFile}=await import('@electron/asar');
 const root=path.resolve(__dirname,'..');
 const selected=process.argv.slice(2);
 assert(selected.every(value=>['windows','linux','mac'].includes(value)),'Choose windows, linux or mac');
 for(const [platform,dir,resources] of [
  ['Windows','Mac2Phone-win32-x64','resources'],['Linux','Mac2Phone-linux-x64','resources'],
  ['Mac','Mac2PhoneDesktop-darwin-arm64','Mac2PhoneDesktop.app/Contents/Resources']]){
  if(selected.length&&!selected.includes(platform.toLowerCase()))continue;
  const base=path.join(process.env.M2P_RELEASE_DIR||path.join(root,'release'),dir,resources),archive=path.join(base,'app.asar');
  const files=['bootstrap.cjs','startup.cjs','main.cjs','preload.cjs'];
  // ASAR's filesystem API splits paths using the host OS separator.
  assert(statFile(archive,path.join('node_modules','bonjour-service','dist','index.js')),`${platform}: discovery dependency`);
  const metadata=JSON.parse(extractFile(archive,'package.json')),source=JSON.parse(fs.readFileSync(path.join(root,'package.json')));
  for(const key of ['name','version','description','license','main','dependencies'])assert.deepEqual(metadata[key],source[key],`${platform}: ${key}`);
  for(const folder of ['core','native','renderer'])for(const name of fs.readdirSync(path.join(root,folder),{recursive:true})){
   const relative=path.join(folder,name);if(fs.statSync(path.join(root,relative)).isFile())files.push(relative);
  }
  for(const file of files)assert.deepEqual(extractFile(archive,file),fs.readFileSync(path.join(root,file)),`${platform}: ${file}`);
  assert.equal(statFile(archive,path.join('native','input-windows.ps1')).unpacked,true);
  assert.deepEqual(fs.readFileSync(path.join(base,'app.asar.unpacked/native/input-windows.ps1')),fs.readFileSync(path.join(root,'native/input-windows.ps1')));
  assert.deepEqual(fs.readFileSync(path.join(base,'LICENSE')),fs.readFileSync(path.join(root,'../LICENSE')));
  if(platform==='Mac'){
   const info=require('plist').parse(fs.readFileSync(path.join(base,'../Info.plist'),'utf8'));
   assert.equal(info.CFBundleShortVersionString,source.version);
   assert.equal(info.CFBundleIdentifier,'io.mac2phone.desktop');
   assert.equal(info.CFBundleDisplayName,'Mac2PhoneDesktop');
   assert.deepEqual(info.NSBonjourServices,['_m2p-nearby._tcp']);
   assert(info.NSLocalNetworkUsageDescription);
   assert.deepEqual(fs.readFileSync(path.join(base,info.CFBundleIconFile)),fs.readFileSync(path.join(root,'../Branding/Mac2Phone.icns')));
   console.log(`PASS Mac version ${source.version}, desktop identity, branded icon and LAN declarations`);
  }
  if(platform==='Windows'){
   const output=path.dirname(base);
   assert.deepEqual(require('../core/startup.cjs').missingRuntime(output),[]);
   for(const file of fs.readdirSync(path.join(root,'windows')))
    assert.deepEqual(fs.readFileSync(path.join(output,file)),fs.readFileSync(path.join(root,'windows',file)),`Windows: ${file}`);
  }
  console.log(`PASS ${platform} packaged source parity, external input helper and MIT license`);
 }
})().catch(error=>{console.error(error);process.exitCode=1;});
