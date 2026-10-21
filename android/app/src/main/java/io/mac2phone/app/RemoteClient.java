package io.mac2phone.app;
import android.graphics.*;
import android.media.*;
import org.json.JSONObject;
import java.nio.ByteBuffer;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
public final class RemoteClient {
 public interface Listener{void state(String text,JSONObject capabilities);void image(Bitmap bitmap,Runnable ack);}
 private final Listener listener;private final AtomicInteger generation=new AtomicInteger();private volatile Wire wire;private volatile boolean ready=false,audio=false;
 private final ExecutorService reader=Executors.newSingleThreadExecutor();
 private final ThreadPoolExecutor writer=new ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(64),r->{Thread t=new Thread(r,"m2p-writer");t.setDaemon(true);return t;},new ThreadPoolExecutor.AbortPolicy());
 private final ScheduledExecutorService timer=Executors.newSingleThreadScheduledExecutor();private ScheduledFuture<?> ping;private AudioTrack track;
 public RemoteClient(Listener listener){this.listener=listener;}
 public void connect(Pairing pairing){disconnect();int id=generation.get();listener.state("Connecting…",null);reader.execute(()->{
  Wire candidate=null;try{candidate=Wire.connect(pairing);if(id!=generation.get()){candidate.close();return;}wire=candidate;
   while(id==generation.get()){
    Wire.Frame f=candidate.read(4194304);if(!ready&&f.type!=Wire.HELLO)throw new Exception("Missing hello");
    if(f.type==Wire.HELLO){JSONObject hello=new JSONObject(new String(f.data,java.nio.charset.StandardCharsets.UTF_8));if(ready||hello.optInt("version")!=2||!hello.optString("video").equals("jpeg")||!hello.optString("transport").equals("tls-psk"))throw new Exception("Incompatible host");ready=true;listener.state("Paired · encrypted",hello);ping=timer.scheduleAtFixedRate(()->send(Wire.PING,ByteBuffer.allocate(8).putLong(System.currentTimeMillis()*1000).array()),0,1,TimeUnit.SECONDS);}
    else if(f.type==Wire.JPEG){BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(f.data,0,f.data.length,bounds);if(bounds.outWidth<=0||bounds.outHeight<=0||(long)bounds.outWidth*bounds.outHeight>8000000)throw new Exception("Invalid image size");Bitmap image=BitmapFactory.decodeByteArray(f.data,0,f.data.length);if(image==null)throw new Exception("Invalid image");listener.image(image,()->{if(id==generation.get())send(Wire.ACK,new byte[0]);});}
    else if(f.type==Wire.AUDIO_CONFIG){if(f.data.length!=5)throw new Exception("Audio format");int rate=ByteBuffer.wrap(f.data).getInt(),channels=f.data[4];if(rate<8000||rate>192000||(channels!=1&&channels!=2))throw new Exception("Audio format");synchronized(this){releaseAudio();if(audio){int mask=channels==2?AudioFormat.CHANNEL_OUT_STEREO:AudioFormat.CHANNEL_OUT_MONO;track=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()).setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(mask).build()).setBufferSizeInBytes(Math.max(AudioTrack.getMinBufferSize(rate,mask,AudioFormat.ENCODING_PCM_16BIT),rate*channels/5)).setTransferMode(AudioTrack.MODE_STREAM).build();track.play();}}}
    else if(f.type==Wire.AUDIO){if(f.data.length<8||f.data.length>65544)throw new Exception("Audio size");synchronized(this){if(audio&&track!=null)track.write(f.data,8,f.data.length-8,AudioTrack.WRITE_NON_BLOCKING);}}
   }
  }catch(Exception error){if(id==generation.get()){disconnect();listener.state("Disconnected. Check Wi-Fi and the pairing link.",null);}}
  finally{if(candidate!=null)candidate.close();}
 });}
 public void input(JSONObject value){send(Wire.INPUT,value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));}
 public void send(int type,byte[] data){Wire current=wire;if(!ready||current==null)return;try{writer.execute(()->{if(wire!=current)return;try{current.send(type,data);}catch(Exception e){current.close();}});}catch(RejectedExecutionException e){disconnect();listener.state("Connection overloaded. Reconnect to resume.",null);}}
 public synchronized void audio(boolean on){audio=on;if(!on)releaseAudio();send(Wire.AUDIO_ON,new byte[]{(byte)(on?1:0)});}
 private void releaseAudio(){if(track!=null){try{track.stop();}catch(Exception ignored){}track.release();track=null;}}
 public synchronized void disconnect(){generation.incrementAndGet();ready=false;audio=false;if(ping!=null)ping.cancel(false);ping=null;Wire old=wire;wire=null;if(old!=null)old.close();writer.getQueue().clear();releaseAudio();}
 public void destroy(){disconnect();reader.shutdownNow();writer.shutdownNow();timer.shutdownNow();}
}
