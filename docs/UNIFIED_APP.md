# One Mac2Phone app, desktop-first interface

## Accepted direction

The desktop interface is the main UI for Mac2Phone. Devices, Share screen and
Session should be the same product experience across desktop platforms. On Mac,
the existing native host must become an integrated engine behind that interface,
not a second app users need to launch. Preserve the current desktop UI rather
than redesigning the main app independently again.

This is an architecture decision, not a claim that integration has shipped.
Desktop 0.5.3 still runs separately from the native Mac host. Its new WebRTC path
works between desktop peers; native Apple and Android clients retain their
existing negotiated transports. Do not rename the desktop package as a merged
app until the native behavior below is connected and tested.

## Features the merge must retain

- Native ScreenCaptureKit capture and the existing iPhone/iPad video path.
- Direct-touch routing, cursor-free touch mode, window gestures and cancellation.
- Display reshape, resolution restoration after disconnect or abnormal exit,
  and the existing explicit power-helper setup.
- Permission status, optional sound, keyboard/input control and emergency stop.
- Nearby requests, explicit acceptance, one-use grants and pairing revocation.
- Desktop fullscreen viewing, quality controls and realtime transport.

## Integration boundary

Bundle the Swift engine inside one Mac application. Give it a worker mode with
no competing dashboard, login item, discovery publisher or approval dialog.
The desktop shell owns navigation and lifecycle; the native engine owns macOS
capture, Accessibility input, touch routing and display/power operations.

Use a versioned, bounded local IPC interface between the trusted main process
and its child engine. Expose named operations and status events, not arbitrary
commands or renderer access to native APIs. Select one owner for listeners,
discovery and approvals; never run two hosts competing for port 8765.

Expose native options in Share screen and settings using the desktop design.
Permission prompts remain tied to a user action. Stop sharing, revocation,
renderer failure and app exit must terminate input and restore the display.
Native worker failure must be visible in the UI and trigger restoration too.

## Completion gates

1. One installed app and one startup entry; no separate native app required.
2. A single nearby identity and approval flow; Windows-to-Mac viewing still works.
3. iPhone touch mode, display reshape and recovery pass physical-device checks.
4. Keyboard, sound and permission flows work from the desktop UI on Mac.
5. Worker crash, renderer crash, Stop sharing and Quit restore input/display state.
6. Migration preserves user settings and signing/permission identity deliberately.

Keep the native implementation until these gates pass. A visual reskin or
package rename alone does not complete this merge.
