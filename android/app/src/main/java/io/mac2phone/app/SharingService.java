package io.mac2phone.app;
import android.app.*;import android.content.*;import android.content.pm.ServiceInfo;import android.graphics.*;import android.hardware.display.*;import android.media.*;import android.media.projection.*;import android.os.*;
import java.io.*;import java.net.*;import java.nio.*;import java.util.*;
public final class SharingService extends Service {
 public static volatile SharingService instance;public static volatile String link="",status="Sharing is off";
 private MediaProjection projection;private VirtualDisplay display;private ImageReader images;private HandlerThread thread;private Handler handler;private RemoteHost host;private AudioRecord audio;private volatile boolean running;private long lastFrame;
 public String grant(){if(!running||host==null)throw new IllegalStateException("Start sharing first");return host.grant();}
 public IBinder onBind(Intent intent){return null;}
 @Override public int onStartCommand(Intent intent,int flags,int startId){
  if(intent==null||"stop".equals(intent.getAction())){stopSelf();return START_NOT_STICKY;}if(running)return START_NOT_STICKY;
  try{
   getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("sharing","Active screen sharing",NotificationManager.IMPORTANCE_LOW));
   PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,SharingService.class).setAction("stop"),PendingIntent.FLAG_IMMUTABLE);
   PendingIntent open=PendingIntent.getActivity(this,2,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE);
   Notification notification=new Notification.Builder(this,"sharing").setSmallIcon(io.mac2phone.app.R.drawable.ic_app).setContentTitle("Mac2Phone is sharing your screen").setContentText("Paired devices can view this screen. Tap Stop to end and revoke the link.").setContentIntent(open).setOngoing(true).addAction(new Notification.Action.Builder(null,"Stop",stop).build()).build();
   startForeground(10,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
   Intent result=intent.getParcelableExtra("data");int code=intent.getIntExtra("code",Activity.RESULT_CANCELED);
   projection=getSystemService(MediaProjectionManager.class).getMediaProjection(code,result);if(projection==null)throw new IOException("Screen capture was not approved");
   thread=new HandlerThread("m2p-capture");thread.start();handler=new Handler(thread.getLooper());
   running=true;instance=this;
   projection.registerCallback(new MediaProjection.Callback(){@Override public void onStop(){stopSelf();}@Override public void onCapturedContentResize(int width,int height){if(running)configure(width,height);}},handler);
   String address=address();Pairing pairing=Pairing.generate(address,8765);
   boolean control=intent.getBooleanExtra("control",false)&&RemoteAccessibility.instance!=null;
   boolean sound=intent.getBooleanExtra("audio",false)&&checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED;
   RemoteAccessibility.setAllowed(control);
   host=new RemoteHost(pairing,control,sound,RemoteAccessibility::receive);host.requireApproval=true;host.start();link=pairing.link();status=control?"Sharing · remote touch and text allowed":"Sharing · view-only";
   android.util.DisplayMetrics metrics=getResources().getDisplayMetrics();handler.post(()->{try{configure(metrics.widthPixels,metrics.heightPixels);}catch(Exception e){stopSelf();}});
   if(sound)startAudio();
  }catch(Exception error){status="Sharing stopped: check screen/audio permission and LAN connection.";stopSelf();}
  return START_NOT_STICKY;
 }
 private static String address()throws SocketException{for(NetworkInterface network:Collections.list(NetworkInterface.getNetworkInterfaces()))if(network.isUp()&&!network.isLoopback())for(InetAddress a:Collections.list(network.getInetAddresses()))if(a instanceof Inet4Address&&!a.isLoopbackAddress())return a.getHostAddress();throw new SocketException("No LAN address");}
 private void configure(int width,int height){if(!running||width<=0||height<=0)return;double scale=Math.min(1,1280.0/Math.max(width,height));int w=Math.max(2,(int)(width*scale)),h=Math.max(2,(int)(height*scale));
  ImageReader next=ImageReader.newInstance(w,h,PixelFormat.RGBA_8888,2);
  next.setOnImageAvailableListener(reader->{try(Image image=reader.acquireLatestImage()){if(image==null||!running)return;long now=SystemClock.elapsedRealtime();if(now-lastFrame<80)return;lastFrame=now;
    Image.Plane plane=image.getPlanes()[0];int stride=plane.getRowStride()/plane.getPixelStride();Bitmap padded=Bitmap.createBitmap(stride,image.getHeight(),Bitmap.Config.ARGB_8888);padded.copyPixelsFromBuffer(plane.getBuffer());Bitmap cropped=Bitmap.createBitmap(padded,0,0,image.getWidth(),image.getHeight());ByteArrayOutputStream out=new ByteArrayOutputStream();cropped.compress(Bitmap.CompressFormat.JPEG,65,out);if(host!=null)host.jpeg(out.toByteArray());if(cropped!=padded)cropped.recycle();padded.recycle();
   }catch(Exception error){if(running)status="A capture frame was skipped";}},handler);
  ImageReader old=images;images=next;
  if(display==null)display=projection.createVirtualDisplay("Mac2Phone",w,h,getResources().getDisplayMetrics().densityDpi,DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,next.getSurface(),null,handler);
  else{display.resize(w,h,getResources().getDisplayMetrics().densityDpi);display.setSurface(next.getSurface());}
  if(old!=null)old.close();
 }
 private void startAudio(){try{AudioPlaybackCaptureConfiguration config=new AudioPlaybackCaptureConfiguration.Builder(projection).addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME).build();
  audio=new AudioRecord.Builder().setAudioPlaybackCaptureConfig(config).setAudioFormat(new AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()).setBufferSizeInBytes(Math.max(16384,AudioRecord.getMinBufferSize(48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_16BIT))).build();audio.startRecording();
  new Thread(()->{byte[] data=new byte[8192];while(running){AudioRecord recorder=audio;if(recorder==null)break;int count;try{count=recorder.read(data,0,data.length,AudioRecord.READ_BLOCKING);}catch(IllegalStateException e){break;}if(count>0&&host!=null)host.pcm(Arrays.copyOf(data,count-count%4));else if(count<0)break;}},"m2p-playback-audio").start();
 }catch(Exception error){status="Screen sharing is active; this app's audio is not capturable.";}}
 @Override public void onDestroy(){running=false;instance=null;RemoteAccessibility.setAllowed(false);link="";if(host!=null){host.close();host=null;}if(audio!=null){try{audio.stop();}catch(Exception ignored){}audio.release();audio=null;}if(display!=null)display.release();if(images!=null)images.close();if(projection!=null)projection.stop();if(thread!=null)thread.quitSafely();status="Sharing is off · previous link revoked";stopForeground(STOP_FOREGROUND_REMOVE);super.onDestroy();}
}
