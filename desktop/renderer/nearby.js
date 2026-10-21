'use strict';
(()=>{
 const api=window.mac2phone,$=id=>document.getElementById(id);if(!api)return;
 let incoming=null,waiting=false,devices=[],refreshTimer;
 const platform=name=>({win32:'Windows',darwin:'Mac',macos:'Mac',ios:'iPhone / iPad',android:'Android',linux:'Linux'}[name]||'Device');
 function icon(name){const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.classList.add('icon');svg.setAttribute('aria-hidden','true');const use=document.createElementNS(svg.namespaceURI,'use');use.setAttribute('href','#i-'+name);svg.append(use);return svg;}
 function render(){const list=$('nearby-list');list.replaceChildren();$('nearby-count').textContent=devices.length;
  if(!devices.length){const empty=document.createElement('div');empty.className='empty-devices';const title=document.createElement('strong'),text=document.createElement('p');title.textContent='No devices found yet';text.textContent='Open Mac2Phone on another device on the same Wi-Fi or LAN. Devices appear here automatically.';empty.append(icon('devices'),title,text);list.append(empty);}
  for(const device of devices){const button=document.createElement('button');button.className='device-button';button.disabled=waiting;const avatar=document.createElement('span');avatar.className='device-avatar';avatar.append(icon('devices'));const title=document.createElement('span');title.className='device-copy';const label=document.createElement('strong'),detail=document.createElement('small');label.textContent=device.name;detail.textContent=platform(device.platform)+' · Request access';title.append(label,detail);button.append(avatar,title,icon('arrow'));button.onclick=async()=>{waiting=true;render();$('nearby-cancel').hidden=false;$('nearby-status').textContent='Sending request…';try{const result=await api.nearbyRequest(device.id);$('nearby-status').textContent=result.ok?'Accepted. Connecting…':result.message||'The request ended.';}catch{$('nearby-status').textContent='The device is no longer available. Try again.';}finally{waiting=false;render();$('nearby-cancel').hidden=true;}};list.append(button);}
 }
 api.nearbyList().then(value=>{devices=value;render();}).catch(()=>{$('nearby-status').textContent='Discovery needs a moment. You can also use a one-use link.';});
 api.on('nearby-devices',value=>{devices=value;render();});
 $('nearby-refresh').onclick=async()=>{
  const button=$('nearby-refresh');button.disabled=true;button.querySelector('span').textContent='Refreshing…';
  try{const result=await api.nearbyRefresh();if(!result.ok&&!waiting)$('nearby-status').textContent='Check local-network access, then try again.';}
  catch{if(!waiting)$('nearby-status').textContent='Discovery is not ready yet. Try again in a moment.';}
  finally{clearTimeout(refreshTimer);refreshTimer=setTimeout(()=>{button.disabled=false;button.querySelector('span').textContent='Refresh';},1000);}
 };
 api.on('nearby-request-state',value=>{$('nearby-status').textContent=`Waiting for ${value.name}. Compare ${value.code} on both devices.`;});
 $('nearby-cancel').onclick=()=>api.nearbyCancel();
 api.on('nearby-incoming',value=>{incoming=value;$('nearby-incoming').hidden=!value;if(value){$('request-name').textContent=`${value.name} · ${platform(value.platform)}`;$('request-code').textContent=value.code;$('request-note').textContent='Compare this code. Accept shares your chosen screen and enabled controls.';$('nearby-incoming').scrollIntoView({block:'nearest'});}});
 async function respond(accept){if(!incoming)return;try{const result=await api.nearbyRespond(incoming.id,accept);if(!result.ok){$('request-note').textContent=result.message||'This request expired.';if(accept)window.m2pUI.show('share');}}catch{$('request-note').textContent='This request ended. Ask the device to try again.';}}
 $('request-decline').onclick=()=>respond(false);$('request-accept').onclick=()=>respond(true);
})();
