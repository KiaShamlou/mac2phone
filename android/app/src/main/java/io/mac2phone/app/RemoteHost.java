package io.mac2phone.app;
import java.net.*;
import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;
public final class RemoteHost implements AutoCloseable {
 public boolean requireApproval=false;private final ConnectionGrants grants=new ConnectionGrants();
 public String grant(){if(!active)throw new IllegalStateException("Start sharing first");Pairing p=new Pairing(pairing.host,pairing.port,pairing.identity,pairing.key);p.ticket=grants.issue();return p.link();}
 private final Pairing pairing;private final boolean control,audio;private final Consumer<String> input;
 private final Set<Peer> peers=ConcurrentHashMap.newKeySet();private final Set<Socket> pending=ConcurrentHashMap.newKeySet();
 private final ExecutorService workers=Executors.newFixedThreadPool(8);private ServerSocket listener;private volatile boolean active;
 private volatile byte[] audioConfig;
 private final class Peer {final Wire wire;int credit=0;volatile boolean sound=false;final ThreadPoolExecutor output=new ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(6),new ThreadPoolExecutor.AbortPolicy());Peer(Wire w){wire=w;}
  void send(int t,byte[] b){try{output.execute(()->{try{wire.send(t,b);}catch(IOException e){wire.close();}});}catch(RejectedExecutionException e){wire.close();}}
  void close(){wire.close();output.shutdownNow();}
 }
 public RemoteHost(Pairing pairing,boolean control,boolean audio,Consumer<String> input){this.pairing=pairing;this.control=control;this.audio=audio;this.input=input;}
 public void start()throws IOException{listener=new ServerSocket();listener.setReuseAddress(true);listener.bind(new InetSocketAddress(pairing.port));active=true;Thread thread=new Thread(()->{while(active)try{Socket socket=listener.accept();if(peers.size()+pending.size()>=4){socket.close();continue;}pending.add(socket);workers.execute(()->accept(socket));}catch(Exception e){if(active)close();}},"m2p-listener");thread.start();}
 private void accept(Socket socket){Peer p=null;try{Wire w=Wire.accept(socket,pairing);if(!active){w.close();return;}byte[] magic=new byte[4];new DataInputStream(w.input).readFully(magic);String mode=new String(magic,StandardCharsets.US_ASCII);boolean approved=false;if(mode.equals("M2PG")){byte[] token=new byte[32];new DataInputStream(w.input).readFully(token);if(!grants.consume(token))throw new IOException("Expired approval");approved=true;new DataInputStream(w.input).readFully(magic);mode=new String(magic,StandardCharsets.US_ASCII);}if(requireApproval&&!approved)throw new IOException("Approval required");if(!mode.equals("M2PJ")&&!mode.equals("M2P2"))throw new IOException();
  if(!active){w.close();return;}p=new Peer(w);peers.add(p);pending.remove(socket);p.send(Wire.HELLO,("{\"version\":2,\"video\":\"jpeg\",\"audio\":\"pcm-s16le\",\"transport\":\"tls-psk\",\"platform\":\"android\",\"screen\":true,\"control\":"+control+",\"audioAvailable\":"+audio+",\"touchMode\":\"pointer\",\"keyboard\":\"text-actions\"}").getBytes(StandardCharsets.UTF_8));
  long start=System.currentTimeMillis();int count=0;
  while(active){Wire.Frame f=w.read(65536);long now=System.currentTimeMillis();if(now-start>1000){start=now;count=0;}if(++count>1000)throw new IOException();
   if(f.type==Wire.ACK){if(f.data.length!=0)throw new IOException();synchronized(p){p.credit=Math.max(0,p.credit-1);}}
   else if(f.type==Wire.PING){if(f.data.length!=8)throw new IOException();byte[] pong=ByteBuffer.allocate(16).put(f.data).putLong(now*1000).array();p.send(Wire.PONG,pong);}
   else if(f.type==Wire.AUDIO_ON){if(f.data.length!=1||(f.data[0]!=0&&f.data[0]!=1))throw new IOException();p.sound=f.data[0]==1;if(p.sound&&audioConfig!=null)p.send(Wire.AUDIO_CONFIG,audioConfig);}
   else if(f.type==Wire.INPUT){if(control)input.accept(new String(f.data,StandardCharsets.UTF_8));}
   else if(f.type!=Wire.SETTINGS&&f.type!=19)throw new IOException();
  }
 }catch(Exception ignored){}finally{pending.remove(socket);try{socket.close();}catch(IOException ignored){}if(p!=null){peers.remove(p);p.close();if(control)input.accept("{\"t\":\"cancel\"}");}}}
 public void jpeg(byte[] bytes){if(bytes.length>4194304)return;for(Peer p:peers)synchronized(p){if(p.credit<2){p.credit++;p.send(Wire.JPEG,bytes);}}}
 public void pcm(byte[] bytes){if(!audio||bytes.length>65536||bytes.length%4!=0)return;byte[] config=ByteBuffer.allocate(5).putInt(48000).put((byte)2).array();boolean first=audioConfig==null;audioConfig=config;byte[] frame=ByteBuffer.allocate(8+bytes.length).putLong(System.currentTimeMillis()*1000).put(bytes).array();for(Peer p:peers)if(p.sound){if(first)p.send(Wire.AUDIO_CONFIG,config);p.send(Wire.AUDIO,frame);}}
 public void close(){active=false;grants.clear();if(listener!=null)try{listener.close();}catch(IOException ignored){}for(Socket s:pending)try{s.close();}catch(IOException ignored){}pending.clear();for(Peer p:peers)p.close();peers.clear();workers.shutdownNow();if(control)input.accept("{\"t\":\"cancel\"}");}
}
