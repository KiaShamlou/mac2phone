package io.mac2phone.app;
import android.app.*;import android.content.*;import android.graphics.*;import android.graphics.drawable.GradientDrawable;import android.media.projection.*;import android.os.*;import android.provider.Settings;import android.text.InputType;import android.view.*;import android.widget.*;import org.json.JSONObject;
public final class MainActivity extends Activity implements RemoteClient.Listener {
 private Nearby nearby;private LinearLayout nearbyList;private TextView nearbyStatus;private AlertDialog incomingDialog;private Nearby.Request acceptedRequest;private boolean preparingCapture,foreground;private int captureAttempt;
 private RemoteClient client;private TextView status,shareStatus;private ImageView screen;private CheckBox control,sound,allowInput,shareAudio;private EditText pairing,text;private boolean connected,allowedControl;private final Handler handler=new Handler(Looper.getMainLooper());
 private int dp(float v){return Math.round(v*getResources().getDisplayMetrics().density);}
 private GradientDrawable background(int color){GradientDrawable bg=new GradientDrawable();bg.setColor(color);bg.setCornerRadius(dp(18));return bg;}
 private Button button(String title,Runnable action){Button b=new Button(this);b.setText(title);b.setAllCaps(false);b.setOnClickListener(v->action.run());return b;}
 private TextView label(String s,int size){TextView v=new TextView(this);v.setText(s);v.setTextSize(size);v.setTextColor(0xffeaf6f2);v.setPadding(0,dp(8),0,dp(8));return v;}
 private LinearLayout row(){LinearLayout l=new LinearLayout(this);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
 private CheckBox check(String name){CheckBox c=new CheckBox(this);c.setText(name);c.setTextColor(0xffd7e8e3);return c;}
 @Override public void onCreate(Bundle saved){super.onCreate(saved);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);client=new RemoteClient(this);
  ScrollView scroll=new ScrollView(this);LinearLayout body=new LinearLayout(this);body.setOrientation(LinearLayout.VERTICAL);body.setPadding(dp(20),dp(24),dp(20),dp(28));scroll.addView(body);body.addView(label("Mac2Phone",28));body.addView(label("Your devices. One local network.",14));
  body.addView(label("Nearby devices",23));body.addView(label("Tap a device to ask for its screen. It chooses whether to share. Compare the code on both devices before accepting.",13));nearbyList=new LinearLayout(this);nearbyList.setOrientation(LinearLayout.VERTICAL);body.addView(nearbyList);nearbyStatus=label("Looking for devices with Mac2Phone open…",13);body.addView(nearbyStatus);body.addView(button("Cancel connection request",()->nearby.cancel()));
  nearby=new Nearby(this,new Nearby.UI(){
   public void devices(java.util.List<Nearby.Device> values){nearbyList.removeAllViews();for(Nearby.Device d:values)nearbyList.addView(button(d.name+" · "+d.platform+" ↗",()->nearby.request(d)));}
   public void state(String message){nearbyStatus.setText(message);}
   public void approved(String link){client.connect(Pairing.parse(link));nearbyStatus.setText("Accepted. Connecting…");}
   public void incoming(Nearby.Request request){
    if(incomingDialog!=null){incomingDialog.dismiss();incomingDialog=null;}
    if(request==null){acceptedRequest=null;return;}
    if(isFinishing()){request.respond(null);return;}
    incomingDialog=new AlertDialog.Builder(MainActivity.this).setTitle("Connection request").setMessage(request.name+" · "+request.platform+"\n\n"+request.code+"\n\nCompare this code on both devices. Accept shares your screen and any input/sound enabled in sharing settings. Android will also ask you to approve screen capture.")
     .setNegativeButton("Decline",(d,w)->request.respond(null)).setPositiveButton("Accept & share",(d,w)->{acceptedRequest=request;if(SharingService.instance!=null)finishApproval();else startSharing();}).setOnCancelListener(d->request.respond(null)).show();
   }
  });
  pairing=new EditText(this);pairing.setHint("Paste a private pairing link");pairing.setSingleLine(true);pairing.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);body.addView(pairing);
  LinearLayout connect=row();connect.addView(button("Connect",()->{try{Pairing value=Pairing.parse(pairing.getText().toString());pairing.setText("");client.connect(value);}catch(Exception e){status.setText(e.getMessage());}}));connect.addView(button("Disconnect",()->{client.disconnect();state("Disconnected",null);}));body.addView(connect);
  status=label("Ready to pair · encrypted LAN",13);body.addView(status);
  screen=new ImageView(this);screen.setScaleType(ImageView.ScaleType.FIT_CENTER);screen.setBackground(background(0xff060d0e));body.addView(screen,new LinearLayout.LayoutParams(-1,dp(280)));
  screen.setOnTouchListener((v,event)->{if(!connected||!control.isChecked()||screen.getDrawable()==null)return false;RectF rect=new RectF(0,0,screen.getDrawable().getIntrinsicWidth(),screen.getDrawable().getIntrinsicHeight());screen.getImageMatrix().mapRect(rect);float x=(event.getX()-rect.left)/rect.width(),y=(event.getY()-rect.top)/rect.height();boolean inside=x>=0&&x<=1&&y>=0&&y<=1;x=Math.max(0,Math.min(1,x));y=Math.max(0,Math.min(1,y));
   if(event.getActionMasked()==MotionEvent.ACTION_DOWN){if(!inside)return false;v.getParent().requestDisallowInterceptTouchEvent(true);input("m","x",x,"y",y);input("d","b",0);}
   else if(event.getActionMasked()==MotionEvent.ACTION_MOVE)input("g","x",x,"y",y,"b",0);
   else if(event.getActionMasked()==MotionEvent.ACTION_UP){input("g","x",x,"y",y,"b",0);input("u","b",0);v.getParent().requestDisallowInterceptTouchEvent(false);}
   else if(event.getActionMasked()==MotionEvent.ACTION_CANCEL)input("cancel");return true;});
  LinearLayout toggles=row();control=check("Control");sound=check("Sound");control.setEnabled(false);sound.setEnabled(false);toggles.addView(control);toggles.addView(sound);body.addView(toggles);control.setOnCheckedChangeListener((b,on)->{if(!on)input("cancel");});sound.setOnCheckedChangeListener((b,on)->client.audio(on));
  LinearLayout keys=row();for(String[] key:new String[][]{{"Esc","escape"},{"Tab","tab"},{"⌫","backspace"},{"↵","return"}})keys.addView(button(key[0],()->{if(control.isChecked())input("key","k",key[1],"m",new org.json.JSONArray());}));body.addView(keys);
  text=new EditText(this);text.setHint("Type or paste text to send");text.setSingleLine(true);body.addView(text);body.addView(button("Send text",()->{if(connected&&control.isChecked()&&text.length()>0){input("txt","s",text.getText().toString());text.setText("");}}));
  LinearLayout wheels=row();wheels.addView(button("Scroll up",()->{if(control.isChecked())input("s","dx",0,"dy",180);}));wheels.addView(button("Scroll down",()->{if(control.isChecked())input("s","dx",0,"dy",-180);}));body.addView(wheels);
  body.addView(label("Share this Android",23));body.addView(label("A visible sharing notification stays on. Stop sharing revokes the link. Apps can exclude their own audio and protected screens.",13));allowInput=check("Allow remote touch & focused text");shareAudio=check("Share capturable app sound");body.addView(allowInput);body.addView(shareAudio);
  body.addView(button("Enable optional remote input",()->new AlertDialog.Builder(this).setTitle("Remote input access").setMessage("During sharing, paired devices may tap, swipe, navigate and edit non-password focused text using Accessibility. Nothing is controlled when sharing is off. Enable Mac2Phone only if you want this access.").setNegativeButton("Cancel",null).setPositiveButton("Open settings",(d,w)->startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))).show()));
  body.addView(button("Start screen sharing",this::startSharing));body.addView(button("Copy one-use Android link",()->{if(SharingService.instance!=null){try{getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Private Mac2Phone pairing link",SharingService.instance.grant()));shareStatus.setText("One-use link copied · connect within 60 seconds");}catch(Exception e){shareStatus.setText("Start sharing or wait for older approvals to expire.");}}else shareStatus.setText("Start sharing first");}));body.addView(button("Stop sharing & revoke",()->stopService(new Intent(this,SharingService.class))));shareStatus=label(SharingService.status,13);body.addView(shareStatus);
  setContentView(scroll);handler.postDelayed(refresh,1000);
 }
 private final Runnable refresh=new Runnable(){public void run(){finishApproval();shareStatus.setText(SharingService.status);handler.postDelayed(this,1000);}};
 private void finishApproval(){if(acceptedRequest!=null&&SharingService.instance!=null){try{acceptedRequest.respond(SharingService.instance.grant());acceptedRequest=null;preparingCapture=false;}catch(Exception ignored){}}}
 @Override protected void onStart(){super.onStart();foreground=true;nearby.start();}
 private void startSharing(){if(SharingService.instance!=null)return;if(allowInput.isChecked()&&RemoteAccessibility.instance==null){shareStatus.setText("Enable optional remote input in Accessibility, or turn off Allow input.");return;}
  if(shareAudio.isChecked()&&checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)!=android.content.pm.PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{android.Manifest.permission.RECORD_AUDIO},20);return;}
  if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},21);return;}
  MediaProjectionManager manager=getSystemService(MediaProjectionManager.class);Intent intent=Build.VERSION.SDK_INT>=34?manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()):manager.createScreenCaptureIntent();preparingCapture=true;int attempt=++captureAttempt;handler.postDelayed(()->{if(preparingCapture&&captureAttempt==attempt){preparingCapture=false;if(acceptedRequest!=null){acceptedRequest.respond(null);acceptedRequest=null;}if(!foreground)nearby.close();}},60000);startActivityForResult(intent,10);
 }
 @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==10&&result==RESULT_OK&&data!=null)startForegroundService(new Intent(this,SharingService.class).putExtra("code",result).putExtra("data",data).putExtra("control",allowInput.isChecked()).putExtra("audio",shareAudio.isChecked()));else if(request==10){preparingCapture=false;if(acceptedRequest!=null){acceptedRequest.respond(null);acceptedRequest=null;}}}
 private void input(String type,Object... fields){try{JSONObject value=new JSONObject();value.put("t",type);for(int i=0;i<fields.length;i+=2)value.put((String)fields[i],fields[i+1]);client.input(value);}catch(Exception ignored){}}
 @Override public void state(String message,JSONObject caps){runOnUiThread(()->{connected=caps!=null;allowedControl=connected&&caps.optBoolean("control");status.setText(message);control.setChecked(false);sound.setChecked(false);control.setEnabled(allowedControl);sound.setEnabled(connected&&caps.optBoolean("audioAvailable"));if(!connected)screen.setImageDrawable(null);});}
 @Override public void image(Bitmap bitmap,Runnable ack){runOnUiThread(()->{if(connected)screen.setImageBitmap(bitmap);ack.run();});}
 @Override protected void onStop(){super.onStop();foreground=false;if(!preparingCapture)nearby.close();input("cancel");client.disconnect();state("Viewer paused. Reconnect when ready.",null);}
 @Override protected void onDestroy(){handler.removeCallbacks(refresh);nearby.close();client.destroy();super.onDestroy();}
}
