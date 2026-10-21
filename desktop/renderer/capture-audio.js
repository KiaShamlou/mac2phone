class PCMProcessor extends AudioWorkletProcessor{
 constructor(){super();this.samples=new Int16Array(4096);this.offset=0;}
 process(inputs){const input=inputs[0];if(!input?.length)return true;
  for(let i=0;i<input[0].length;i++){for(let c=0;c<2;c++){const sample=Math.max(-1,Math.min(1,(input[c]??input[0])[i]));this.samples[this.offset++]=Math.round(sample*(sample<0?32768:32767));}if(this.offset===4096){this.port.postMessage(this.samples.buffer,[this.samples.buffer]);this.samples=new Int16Array(4096);this.offset=0;}}
  return true;
 }
}
registerProcessor('m2p-pcm',PCMProcessor);
