'use strict';
// Install diagnostics before loading app modules, including the discovery code.
const startup=require('./startup.cjs');
if(startup.install()){
 try{require('./main.cjs');}
 catch(error){startup.fail('loading application modules',error);}
}
