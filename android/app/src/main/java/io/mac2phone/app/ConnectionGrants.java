package io.mac2phone.app;
import java.util.*;import java.security.SecureRandom;import java.util.function.LongSupplier;
/** Bounded, single-use, short-lived approval; independent of TLS bearer credentials. */
public final class ConnectionGrants {
 private final Map<String,Long> values=new HashMap<>();private final LongSupplier clock;
 public ConnectionGrants(){this(System::currentTimeMillis);}public ConnectionGrants(LongSupplier clock){this.clock=clock;}
 private void prune(){values.entrySet().removeIf(v->v.getValue()<=clock.getAsLong());}
 public synchronized byte[] issue(){prune();if(values.size()>=8)throw new IllegalStateException("Too many approvals");byte[] token=new byte[32];new SecureRandom().nextBytes(token);values.put(Base64.getEncoder().encodeToString(token),clock.getAsLong()+60000);return token;}
 public synchronized boolean consume(byte[] token){prune();return values.remove(Base64.getEncoder().encodeToString(token))!=null;}
 public synchronized void clear(){values.clear();}
}
