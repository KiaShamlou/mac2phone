package io.mac2phone.app;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.UUID;
public final class Pairing {
 public final String host,identity; public final int port; public final byte[] key; public byte[] ticket;
 public Pairing(String host,int port,String identity,byte[] key){this.host=host;this.port=port;this.identity=identity;this.key=key.clone();}
 public static Pairing generate(String host,int port){byte[] k=new byte[32];new SecureRandom().nextBytes(k);return new Pairing(host,port,UUID.randomUUID().toString(),k);}
 public String link(){return "mac2phone://"+(host.contains(":")&&!host.startsWith("[")?"["+host+"]":host)+":"+port+(ticket==null?"#v2.":"#v3.")+identity+"."+Base64.getUrlEncoder().withoutPadding().encodeToString(key)+(ticket==null?"":"."+Base64.getUrlEncoder().withoutPadding().encodeToString(ticket));}
 public static Pairing parse(String raw){
  if(raw==null||raw.length()>1024)throw new IllegalArgumentException("Paste a complete pairing link");
  try{String text=raw.trim();URI uri=new URI(text);String[] parts=uri.getRawFragment().split("\\.",-1);
   if(!"mac2phone".equals(uri.getScheme())||uri.getHost()==null||uri.getUserInfo()!=null||uri.getQuery()!=null||!uri.getPath().isEmpty()||uri.getPort()<1||uri.getPort()>65535||!((parts.length==3&&parts[0].equals("v2"))||(parts.length==4&&parts[0].equals("v3")))||!parts[1].matches("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")||!parts[2].matches("[A-Za-z0-9_-]{43}"))throw new Exception();
   byte[] key=Base64.getUrlDecoder().decode(parts[2]);Pairing value=new Pairing(uri.getHost(),uri.getPort(),parts[1],key);if(parts.length==4){value.ticket=Base64.getUrlDecoder().decode(parts[3]);if(value.ticket.length!=32)throw new Exception();}if(key.length!=32||!value.link().equals(text))throw new Exception();return value;
  }catch(Exception e){throw new IllegalArgumentException("Paste a complete private pairing link copied from the host");}
 }
 public byte[] identityBytes(){return identity.getBytes(StandardCharsets.UTF_8);}
}
