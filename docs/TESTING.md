# Verification and device QA

## Automated coverage

`swift test` exercises the production pure touch rules, intercepted Mac input lifecycle, native framing/readers, and WebSocket decoding. Input observers prevent real desktop event injection. `Scripts/check.sh --static` checks shell/plist syntax and equality of protocol copies. The full script also builds the iOS Simulator target without signing.

These tests do not measure end-to-end latency, actual Accessibility window behavior, hardware video/audio, or physical multitouch. A successful Simulator compile is not a device test.

## Manual matrix

Run on a small iPhone and an iPad, portrait and landscape, with Wi-Fi and Personal Hotspot. Repeat with Control off and each of Touch, Pointer, and Trackpad.

| Check | Expected result |
| --- | --- |
| Tap/double-tap | One click / native double-click; no recognition delay for first tap |
| Touch in a letterbox | No edge click on the desktop |
| One-finger swipe | Content scroll; no held mouse button |
| Hold then drag | Left-button content drag; release once |
| Hold then release | One context menu |
| Add second or third finger mid-drag | Previous drag releases; new gesture does not leave a button held |
| Lift one of two fingers | End once; remaining finger does not suddenly become a click |
| Interrupt with notification/Control Center | Cancel without click or momentum |
| Fast flick, then touch | Momentum stops immediately |
| Scroll, pause, then lift | No stale momentum |
| Change control mode or rotation mid-gesture | Cancel; no cursor jump or stuck drag |
| Trackpad slide | Relative movement with no mouse-down; hold-slide drags |
| Background window in same app | First gesture only focuses that window |
| Two-finger scroll on title bar | Scroll, never move/resize the window |
| Disable control with keyboard open | Keyboard dismisses; remote input stops |
| Toggle Touch/Pointer | Cursor hides/shows according to mode and saved preference |
| Disconnect during drag | Mac releases buttons; display recovers |
| Connect A, immediately connect B | A's late callbacks do not reset B |
| Lose Wi-Fi | Session fails after watchdog; reconnect works without stale video/audio |
| Background/foreground | Stream closes; discovery resumes; remembered connection follows preference |
| Video loss before first keyframe | Bounded memory; keyframe recovery request |
| Audio on, reconnect | Audio format and playback resynchronize |
| Large text / VoiceOver | Controls readable, labeled, reachable; toolbar does not auto-hide under VoiceOver |
| Display fitting / multiple displays | Correct touch mapping and restoration after quit, pause, and failure |

## Evidence

For each hardware run record OS versions, device, build, network, mode, outcome, and measured latency if relevant. Keep recordings private unless the desktop has been prepared for public sharing. Do not mark an untested row as passing.

Interaction cancellation follows Apple's `UIResponder.touchesCancelled` contract. WebSocket validation follows RFC 6455 section 5:

- https://developer.apple.com/documentation/uikit/uiresponder/touchescancelled(_:with:)
- https://www.rfc-editor.org/rfc/rfc6455.html#section-5
# Keyboard visibility regression

- With a landscape Mac desktop on an upright iPhone, open Keyboard. The picture should move upward only as far as needed to clear the controls and accessory keys, without shrinking when it already fits.
- Dismiss the keyboard using both the toolbar and accessory chevron. The previous picture position and zoom should return; the Mac display resolution should not change.
- Tap the center and edges of the shifted picture. Remote input should match the visible position; the space underneath the picture should not click the desktop.
- Repeat with expanded window controls, landscape orientation, a portrait desktop, iPad split view, a floating keyboard, and a hardware keyboard. A docked keyboard should reserve space; a floating keyboard should not shrink the whole screen.
- Resize or dismiss the keyboard during a drag. The active remote gesture should cancel rather than remain held.


## Native interface checks

- Check the connection screen, address sheet, help sheet, and stream presets in light/dark appearance, on narrow phones and iPads, and with larger text. Keep connection progress and Cancel reachable.
- Check the compact remote toolbar, all five actions, and the 44-point shortcut keys. Keyboard dismissal stays visible even when the shortcut strip scrolls.
- Enable Reduce Motion and Reduce Transparency; controls remain legible without glass or motion. Test the standard-material path on iOS 17/18 as well as native glass on iOS 26.
- Check Mac Overview, Display & Power, Permissions, and menu-bar popover at minimum window size. Missing Screen Recording shows setup, not ready; missing Accessibility explains view-only availability.
- Verify pause/resume, address copy, permission navigation, display recovery, and optional audio/helper actions against the real system state.
