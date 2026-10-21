package io.mac2phone.app;
/** Bounded UI dispatch with generation-based revocation across sharing sessions. */
public final class InputGrant {
 private long generation;private boolean enabled;private int pending;
 public synchronized void setEnabled(boolean value){enabled=value;generation++;}
 public synchronized long acquire(){if(!enabled||pending>=128)return -1;pending++;return generation;}
 public synchronized boolean current(long token){return enabled&&token==generation;}
 public synchronized void release(){pending=Math.max(0,pending-1);}
}
