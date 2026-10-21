package io.mac2phone.app;
import java.nio.charset.StandardCharsets;import java.security.*;import java.util.*;import javax.crypto.*;import javax.crypto.spec.*;
import org.bouncycastle.crypto.params.*;import org.bouncycastle.crypto.generators.HKDFBytesGenerator;import org.bouncycastle.crypto.digests.SHA256Digest;
/** Cross-platform request envelope. Names are self-asserted; compare the code. */
public final class NearbyCrypto {
 public static final byte[] INFO="Mac2Phone Nearby v1".getBytes(StandardCharsets.UTF_8);
 private final X25519PrivateKeyParameters privateKey=new X25519PrivateKeyParameters(new SecureRandom());
 public final String publicKey=Base64.getEncoder().encodeToString(privateKey.generatePublicKey().getEncoded());
 public byte[] key;public String code;
 public static byte[] decode(String s,int size){if(s==null||s.length()>6000)throw new IllegalArgumentException();byte[] bytes=Base64.getDecoder().decode(s);if(!Base64.getEncoder().encodeToString(bytes).equals(s)||(size>0&&bytes.length!=size))throw new IllegalArgumentException();return bytes;}
 public static boolean validName(String s){return s!=null&&!s.trim().isEmpty()&&s.getBytes(StandardCharsets.UTF_8).length<=128&&s.codePoints().noneMatch(c->{int t=Character.getType(c);return t==Character.CONTROL||t==Character.FORMAT||t==Character.SURROGATE||t==Character.PRIVATE_USE||t==Character.UNASSIGNED;});}
 public static boolean platform(String s){return Arrays.asList("macos","darwin","win32","linux","android","ios").contains(s);}
 private static byte[] concat(byte[]... parts){int n=0;for(byte[] b:parts)n+=b.length;byte[] out=new byte[n];int at=0;for(byte[] b:parts){System.arraycopy(b,0,out,at,b.length);at+=b.length;}return out;}
 public void agree(String name,String platform,String clientKey,String hostKey)throws Exception{
  if(!validName(name)||!platform(platform))throw new IllegalArgumentException();byte[] client=decode(clientKey,32),host=decode(hostKey,32),secret=new byte[32];
  privateKey.generateSecret(new X25519PublicKeyParameters(publicKey.equals(clientKey)?host:client,0),secret,0);
  byte[] transcript=concat((name+"\n"+platform+"\n").getBytes(StandardCharsets.UTF_8),client,host);
  HKDFBytesGenerator hkdf=new HKDFBytesGenerator(new SHA256Digest());hkdf.init(new HKDFParameters(secret,new byte[32],concat(INFO,transcript)));key=new byte[32];hkdf.generateBytes(key,0,32);Arrays.fill(secret,(byte)0);
  byte[] digest=MessageDigest.getInstance("SHA-256").digest(concat(key,transcript));code=String.format(Locale.ROOT,"%06d",(((digest[0]&255)<<16)|((digest[1]&255)<<8)|(digest[2]&255))%1000000);
 }
 public static byte[] nonce(){byte[] b=new byte[32];new SecureRandom().nextBytes(b);return b;}
 public static String commit(String key,byte[] nonce)throws Exception{return Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(concat(decode(key,32),nonce)));}
 public String seal(String value)throws Exception{byte[] nonce=new byte[12];new SecureRandom().nextBytes(nonce);Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce));cipher.updateAAD(INFO);return Base64.getEncoder().encodeToString(concat(nonce,cipher.doFinal(value.getBytes(StandardCharsets.UTF_8))));}
 public String open(String value)throws Exception{byte[] b=decode(value,0);if(b.length<28||b.length>4096)throw new IllegalArgumentException();Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,Arrays.copyOf(b,12)));cipher.updateAAD(INFO);return new String(cipher.doFinal(Arrays.copyOfRange(b,12,b.length)),StandardCharsets.UTF_8);}
 public void close(){if(key!=null)Arrays.fill(key,(byte)0);}
}
