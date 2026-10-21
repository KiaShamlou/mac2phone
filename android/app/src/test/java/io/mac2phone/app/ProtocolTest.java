package io.mac2phone.app;
import org.junit.Test;
import static org.junit.Assert.*;
import java.io.*;
import java.util.Arrays;
public class ProtocolTest {
 @Test public void inputRevocationInvalidatesQueuedCommands(){InputGrant g=new InputGrant();assertEquals(-1,g.acquire());g.setEnabled(true);long old=g.acquire();assertTrue(g.current(old));g.setEnabled(false);assertFalse(g.current(old));g.setEnabled(true);assertFalse(g.current(old));g.release();assertTrue(g.current(g.acquire()));}
 @Test public void inputQueueIsBounded(){InputGrant g=new InputGrant();g.setEnabled(true);for(int i=0;i<128;i++)assertTrue(g.acquire()>=0);assertEquals(-1,g.acquire());g.release();assertTrue(g.acquire()>=0);}
 @Test public void pairingRoundTrip(){Pairing p=Pairing.generate("192.168.1.2",8765);Pairing q=Pairing.parse(p.link());assertEquals(p.identity,q.identity);assertArrayEquals(p.key,q.key);}
 @Test public void uniqueKeys(){assertFalse(Arrays.equals(Pairing.generate("localhost",8765).key,Pairing.generate("localhost",8765).key));}
 @Test public void malformedLinks(){String link=Pairing.generate("127.0.0.1",8765).link();for(String s:new String[]{"",link+"=",link.replace("mac2phone:","http:"),link.replace(":8765",":0"),link.replace("#","/#"),link.replace("//","//user@")}){try{Pairing.parse(s);fail(s);}catch(IllegalArgumentException expected){}}}
 @Test public void boundedFrames()throws Exception{byte[] b={8,0,0,0,2,123,125};assertEquals(8,Wire.read(new ByteArrayInputStream(b),100).type);try{Wire.read(new ByteArrayInputStream(new byte[]{9,127,0,0,0}),100);fail();}catch(IOException expected){}}
 @Test public void truncatedFrames()throws Exception{try{Wire.read(new ByteArrayInputStream(new byte[]{9,0,0,0,4,1}),100);fail();}catch(EOFException expected){}}
}
