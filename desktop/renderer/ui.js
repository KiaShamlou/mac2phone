'use strict';
(()=>{
 const names={devices:'Devices',share:'Share screen',session:'Session'};
 function show(view,{focus=true}={}){
  if(!names[view])return;
  document.querySelectorAll('[data-panel]').forEach(panel=>panel.hidden=panel.dataset.panel!==view);
  document.querySelectorAll('nav [data-go]').forEach(button=>{if(button.dataset.go===view)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');});
  const title=document.getElementById('page-title');title.textContent=names[view];if(focus)title.focus({preventScroll:true});document.querySelector('main').scrollTop=0;
 }
 document.querySelectorAll('[data-go]').forEach(button=>button.addEventListener('click',event=>{event.preventDefault();show(button.dataset.go);}));
 window.m2pUI={show};
 window.mac2phone?.on('state',value=>{document.getElementById('nav-connected').hidden=value.state!=='connected';if(value.state==='connected'||value.state==='connecting')show('session',{focus:false});});
})();
