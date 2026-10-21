package io.mac2phone.app;
import java.io.*;import java.net.*;import java.nio.charset.StandardCharsets;
/** Synthetic interop only: never starts capture, audio or accessibility services. */
public final class InteropFixture {
 public static void main(String[] args)throws Exception{
  String mode=args[0];Pairing pairing=Pairing.parse(args[1]);
  if(mode.equals("client")){
   try(Wire wire=Wire.connect(pairing)){
    Wire.Frame hello=wire.read(4096);if(hello.type!=Wire.HELLO||!new String(hello.data,StandardCharsets.UTF_8).contains("jpeg"))throw new IOException("hello");
    wire.send(Wire.INPUT,"{\"t\":\"txt\",\"s\":\"JVM fixture سلام\"}".getBytes(StandardCharsets.UTF_8));wire.send(Wire.AUDIO_ON,new byte[]{1});
    boolean jpeg=false,audio=false;while(!jpeg||!audio){Wire.Frame f=wire.read(4194304);if(f.type==Wire.JPEG){jpeg=true;wire.send(Wire.ACK,new byte[0]);}if(f.type==Wire.AUDIO)audio=true;}
    System.out.println("PASS JVM TLS client received JPEG and PCM and sent Unicode input");
   }
  }else if(mode.equals("host")){
   RemoteHost host=new RemoteHost(pairing,true,true,value->{if(value.contains("fixture"))System.out.println("INPUT OK");});host.start();System.out.println("READY");System.out.flush();
   long end=System.currentTimeMillis()+12000;while(System.currentTimeMillis()<end){host.jpeg(new byte[]{(byte)255,(byte)216,(byte)255,(byte)217});host.pcm(new byte[64]);Thread.sleep(50);}host.close();
  }else throw new IllegalArgumentException();
 }
}
