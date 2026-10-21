# Test the Mac desktop viewer with Windows

Use **Mac2PhoneDesktop.app 0.5.3** (Apple Silicon), not the older Mac2Phone
menu-bar host. The apps can coexist. The desktop viewer includes the updated
Devices, Share screen, and Session interface and the same protocol as Windows
0.4.2. Desktop 0.5.0 already supports WebRTC. Install **0.5.3 on both computers**
for two-way Auto adaptation, capture budgeting and 30/60 FPS controls.
An older desktop or native Apple client still uses compatibility video.

1. Open Mac2Phone on Windows and Mac2PhoneDesktop on your Mac, on the same LAN.
   Allow Local Network access if macOS asks.
2. On Windows, choose **Share screen**, select a display, and enable remote
   control and system sound if you want them. Choose **Allow screen & preview**, then
   **Start sharing**. A preview by itself is not a shared session.
3. On the Mac, open **Devices** and select the Windows computer to request access.
4. Compare the six-digit code on both devices, then accept on Windows.
5. The session opens fullscreen. Enable **Control** and **Sound** separately. Click
   the screen before typing. Use Control-key shortcuts for Windows; Command is
   not translated to Control. **Shift–Escape** releases remote control.
   Move to the top edge or press **F8** to show the toolbar; **F11** or
   **Exit fullscreen** returns to the app. Pick **Sharp** for text or
   **Auto** for low latency or **Fast** for a fixed lower stream cap. Sharp
   prioritizes text and may reduce FPS. The lower-left overlay shows measured
   resolution, codec, FPS, bitrate, buffer/decode/encode time and frame drops. The 60 fps setting is a target, not a
   guaranteed rate; it depends on capture, hardware and your LAN.
6. Quality and Motion are remembered locally. Outside fullscreen, the Session panel also lets you choose whether future connections open fullscreen. Control and Sound remain off on each new connection.
7. After an active video interruption, the viewer makes at most two recovery attempts per minute; compatibility video remains available. F8 → Copy diagnostics includes the attempt count. Disconnect on the Mac or stop sharing on Windows when finished.

The Mac re-queries nearby devices every five seconds and after network-interface
changes. **Refresh** sends a new query immediately (limited to one per second),
without cancelling requests or interrupting a session.

If the Windows device does not appear, select **Refresh**, then check that both devices use the same
non-guest LAN and that Mac2Phone is allowed on the Windows private-network
firewall and in macOS Local Network settings. You can also copy a fresh one-use
link from the Windows sharing screen and paste it into the Mac's manual
connection field. The link expires after 60 seconds and is private.

Viewing Windows does not require Mac Screen Recording or Accessibility access.
Sharing the Mac's own screen is a separate action. Continue using the native
Mac2Phone menu-bar host when you need remote control of the Mac itself.

## Rebuild locally on an Apple Silicon Mac

```sh
npm --prefix desktop ci
npm --prefix desktop run package:mac
codesign --force --deep --sign - desktop/release/Mac2PhoneDesktop-darwin-arm64/Mac2PhoneDesktop.app
codesign --verify --deep --strict desktop/release/Mac2PhoneDesktop-darwin-arm64/Mac2PhoneDesktop.app
node desktop/test/package-check.cjs mac
node desktop/test/startup-smoke.cjs --executable="$PWD/desktop/release/Mac2PhoneDesktop-darwin-arm64/Mac2PhoneDesktop.app/Contents/MacOS/Mac2PhoneDesktop"
M2P_VIEWER_APP="$PWD/desktop/release/Mac2PhoneDesktop-darwin-arm64/Mac2PhoneDesktop.app/Contents/Resources/app.asar" desktop/node_modules/.bin/electron desktop/test/windows-viewer-smoke.cjs
```

The local build is ad-hoc signed, not Developer ID signed or notarized. The
automated viewer test uses a synthetic Windows-protocol host on loopback; it
never captures or controls a real desktop. Complete the two-device test above
for actual Windows capture, input injection, audio, and LAN behavior.
