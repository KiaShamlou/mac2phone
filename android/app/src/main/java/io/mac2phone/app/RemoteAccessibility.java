package io.mac2phone.app;
import android.accessibilityservice.*;
import android.view.accessibility.*;
import android.graphics.Path;
import android.os.*;
import org.json.JSONObject;
public final class RemoteAccessibility extends AccessibilityService {
 public static volatile RemoteAccessibility instance;private static final InputGrant grant=new InputGrant();
 public static void setAllowed(boolean enabled){grant.setEnabled(enabled);}
 private float x=.5f,y=.5f,startX,startY;private Path drag;private long started;private int dragButton;
 @Override protected void onServiceConnected(){instance=this;}
 @Override public void onAccessibilityEvent(AccessibilityEvent event){}
 @Override public void onInterrupt(){drag=null;}
 @Override public void onDestroy(){instance=null;setAllowed(false);super.onDestroy();}
 public static void receive(String json){RemoteAccessibility service=instance;if(service==null)return;long token=grant.acquire();if(token<0)return;new Handler(Looper.getMainLooper()).post(()->{try{if(grant.current(token)&&instance==service)service.input(json);}finally{grant.release();}});}
 private void gesture(Path path,long duration){dispatchGesture(new GestureDescription.Builder().addStroke(new GestureDescription.StrokeDescription(path,0,Math.max(30,Math.min(1500,duration)))).build(),null,null);}
 private float px(float x){return x*getResources().getDisplayMetrics().widthPixels;}
 private float py(float y){return y*getResources().getDisplayMetrics().heightPixels;}
 private void input(String text){try{JSONObject v=new JSONObject(text);String t=v.optString("t");if(text.length()>8192)return;
  if(v.has("x")){double a=v.optDouble("x"),b=v.optDouble("y");if(!Double.isFinite(a)||!Double.isFinite(b))return;x=(float)Math.max(0,Math.min(1,a));y=(float)Math.max(0,Math.min(1,b));}
  switch(t){
   case "m":break;
   case "c":case "tap":case "tap2":{Path p=new Path();p.moveTo(px(x),py(y));gesture(p,(t.equals("tap2")||v.optInt("b")==1)?650:50);break;}
   case "d":case "dbeg":dragButton=v.optInt("b");startX=x;startY=y;drag=new Path();drag.moveTo(px(x),py(y));started=System.currentTimeMillis();break;
   case "g":case "dmov":if(drag!=null)drag.lineTo(px(x),py(y));break;
   case "u":case "dend":if(drag!=null){gesture(drag,Math.max(dragButton==1?650:60,System.currentTimeMillis()-started));drag=null;}break;
   case "cancel":drag=null;break;
   case "s":{if(!Double.isFinite(v.optDouble("dx"))||!Double.isFinite(v.optDouble("dy")))return;float dx=(float)Math.max(-500,Math.min(500,v.optDouble("dx"))),dy=(float)Math.max(-500,Math.min(500,v.optDouble("dy")));Path p=new Path();float xx=px(.5f),yy=py(.5f);p.moveTo(xx,yy);p.lineTo(Math.max(1,Math.min(px(1)-1,xx+dx)),Math.max(1,Math.min(py(1)-1,yy+dy)));gesture(p,180);break;}
   case "txt":edit(v.optString("s"),false);break;
   case "key":switch(v.optString("k")){case "backspace":case "delete":edit("",true);break;case "escape":performGlobalAction(GLOBAL_ACTION_BACK);break;case "home":performGlobalAction(GLOBAL_ACTION_HOME);break;case "return":case "enter":if(Build.VERSION.SDK_INT>=30){AccessibilityNodeInfo n=focused();if(n!=null)n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.getId());}break;}break;
  }
 }catch(Exception ignored){drag=null;}}
 private AccessibilityNodeInfo focused(){AccessibilityNodeInfo root=getRootInActiveWindow();return root==null?null:root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);}
 private void edit(String insert,boolean backspace){if(insert.length()>2000)return;AccessibilityNodeInfo node=focused();if(node==null||!node.isEditable()||node.isPassword())return;String text=node.getText()==null?"":node.getText().toString();int a=Math.max(0,Math.min(text.length(),node.getTextSelectionStart())),b=Math.max(a,Math.min(text.length(),node.getTextSelectionEnd()));if(backspace&&a==b&&a>0)a=text.offsetByCodePoints(a,-1);String result=text.substring(0,a)+insert+text.substring(b);Bundle bundle=new Bundle();bundle.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,result);node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,bundle);Bundle select=new Bundle();select.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT,a+insert.length());select.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,a+insert.length());node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION,select);}
}
