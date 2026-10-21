package io.mac2phone.app;
import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import org.bouncycastle.tls.*;
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto;
public final class Wire implements AutoCloseable {
 public static final int HELLO=8,JPEG=9,INPUT=16,SETTINGS=17,ACK=18,PING=20,PONG=4,AUDIO_ON=22,AUDIO_CONFIG=6,AUDIO=7;
 public final Socket socket; public final InputStream input; private final OutputStream output;
 private Wire(Socket socket,TlsProtocol protocol)throws IOException{this.socket=socket;input=protocol.getInputStream();output=protocol.getOutputStream();}
 private static ProtocolVersion[] versions(){return new ProtocolVersion[]{ProtocolVersion.TLSv12};}
 private static int[] ciphers(){return new int[]{CipherSuite.TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256};}
 public static Wire connect(Pairing pairing)throws IOException {
  Socket socket=new Socket();try{socket.connect(new InetSocketAddress(pairing.host.replace("[","").replace("]",""),pairing.port),8000);socket.setSoTimeout(8000);socket.setTcpNoDelay(true);
   TlsClientProtocol protocol=new TlsClientProtocol(socket.getInputStream(),socket.getOutputStream());
   protocol.connect(new PSKTlsClient(new BcTlsCrypto(new SecureRandom()),pairing.identityBytes(),pairing.key){@Override protected ProtocolVersion[] getSupportedVersions(){return versions();}@Override protected int[] getSupportedCipherSuites(){return ciphers();}});
   Wire result=new Wire(socket,protocol);if(pairing.ticket!=null){result.output.write("M2PG".getBytes(StandardCharsets.US_ASCII));result.output.write(pairing.ticket);}result.output.write("M2PJ".getBytes(StandardCharsets.US_ASCII));result.output.flush();return result;
  }catch(IOException|RuntimeException e){socket.close();throw e;}
 }
 public static Wire accept(Socket socket,Pairing pairing)throws IOException {
  try{socket.setSoTimeout(8000);socket.setTcpNoDelay(true);TlsServerProtocol protocol=new TlsServerProtocol(socket.getInputStream(),socket.getOutputStream());
   TlsPSKIdentityManager keys=new TlsPSKIdentityManager(){public byte[] getHint(){return null;}public byte[] getPSK(byte[] identity){return MessageDigest.isEqual(identity,pairing.identityBytes())?pairing.key.clone():null;}};
   protocol.accept(new PSKTlsServer(new BcTlsCrypto(new SecureRandom()),keys){
    // PSK sessions have no certificate/OCSP response. AbstractTlsServer's default
    // status_request echo causes Apple Network.framework to reject ServerHello.
    @Override protected boolean allowCertificateStatus(){return false;}
    @Override protected boolean allowMultiCertStatus(){return false;}
    @Override protected ProtocolVersion[] getSupportedVersions(){return versions();}@Override protected int[] getSupportedCipherSuites(){return ciphers();}});return new Wire(socket,protocol);
  }catch(IOException|RuntimeException e){socket.close();throw e;}
 }
 public synchronized void send(int type,byte[] bytes)throws IOException{if(bytes.length>4194304)throw new IOException("Frame too large");DataOutputStream out=new DataOutputStream(output);out.writeByte(type);out.writeInt(bytes.length);out.write(bytes);out.flush();}
 public Frame read(int max)throws IOException{return read(input,max);}
 public static Frame read(InputStream stream,int max)throws IOException{DataInputStream in=new DataInputStream(stream);int type=in.readUnsignedByte();int n=in.readInt();if(n<0||n>max)throw new IOException("Frame too large");byte[] bytes=new byte[n];in.readFully(bytes);return new Frame(type,bytes);}
 public static final class Frame {public final int type;public final byte[] data;Frame(int type,byte[] data){this.type=type;this.data=data;}}
 public void close(){try{socket.close();}catch(IOException ignored){}}
}
