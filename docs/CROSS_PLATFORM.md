# Cross-platform preview

**Windows and Android are Beta.** Linux remains experimental. See the [project introduction](INTRODUCTION.md) for the current release status.

Mac2Phone now has source implementations for macOS, Windows, Linux, Android, iPhone/iPad and Apple Watch. Devices use the same paired, encrypted LAN protocol. This is a development preview: successful builds and synthetic transport tests are not substitutes for real screen-capture, input, audio and permission testing on every operating system.

## Platform capabilities

| Device | View and control another host | Share its screen | Input when hosting | Audio when hosting |
| --- | --- | --- | --- | --- |
| macOS 14+ | Electron desktop app; native iOS client controls Mac | Native ScreenCaptureKit host; desktop app also offers capture | Native host supports mouse, keyboard and iPad-like gestures | Native virtual device; desktop loopback on supported macOS |
| Windows 11 | Electron app | Selected display through Electron | Opt-in Win32 pointer, drag, wheel, keys, shortcuts and Unicode text | System loopback |
| Linux | Electron app, experimental | Electron capture; compositor/portal dependent | X11 with `xdotool`; Wayland view-only | `parec` default output monitor, PulseAudio/PipeWire dependent |
| Android 10+ | Native JPEG viewer, pointer, text, keys and PCM playback | User-approved MediaProjection foreground service | Optional, explicitly enabled Accessibility service; taps, swipes, completed drags, editable-field text and basic actions | Eligible media/game app playback only |
| iPhone/iPad 17+ | Native hardware-video/JPEG viewer, touch and keyboard, PCM playback | User-started ReplayKit upload extension | View-only broadcast; no system-wide remote input injection | ReplayKit app audio; microphone ignored |
| Apple Watch watchOS 10+ | Companion keys, scrolling and text/dictation via iPhone | No screen broadcasting | No host | No streaming audio |

Mac2Phone's richer cursor-free Touch mode remains Mac-specific. Other hosts select direct Pointer mode in the iOS client. Command shortcuts map to Control on Windows/Linux/Android. This version sends discrete key presses, not gaming-style held keys. Android text actions work in exposed editable fields, not password fields; protected windows, custom canvases and app-specific controls vary. Android drag paths are dispatched on release, not streamed continuously.

The Watch relays live commands only while the iPhone app is foreground, connected, Control is on, and **Apple Watch remote** is enabled. It does not hold pairing keys, queue offline commands or mirror an entire desktop.

## Nearby devices and approval

1. Open the updated Mac2Phone apps on the same reachable LAN and allow local-network access. **Nearby devices** lists their advertised device names and platforms, not user accounts.
2. Tap a device to send a connection request. Both screens show a six-digit verification code. Compare it before accepting; names alone are not verified identities.
3. On the receiving device, choose **Decline** or **Accept & share**. Nothing is streamed and no input is processed before a one-use grant is accepted by the encrypted stream server.
4. The host's capture and input permissions still apply. On desktop, choose a display and start sharing before accepting. Android asks for system capture approval; input requires its explicit Accessibility opt-in. On iPhone/iPad, start the visible system broadcast and return to Mac2Phone to finish the accepted request; broadcasting remains view-only.
5. Enable viewer Control and Sound separately. **Stop sharing** ends active streams. Every new connection needs a new approval. Requests expire after two minutes; a connection grant expires after 60 seconds and works once.

Discovery uses Bonjour/DNS-SD (`_m2p-nearby._tcp`) across Apple, desktop and Android. It shows reachable, running app instances, not every device on Wi-Fi: guest isolation, blocked multicast, sleeping devices, background mobile apps, VPNs and host firewalls can prevent discovery. Android/iOS discovery runs while the app is foreground; the Watch remains an iPhone companion, not an independently advertised screen-sharing host. The native Mac menu-bar app shows devices and accepts incoming requests; use the separate Mac desktop viewer to request another device's screen.

Manual pairing is still available as **Copy one-use link**: the host's explicit copy action grants one connection within 60 seconds. Treat it as a password. Existing persistent v2 links alone no longer authorize connections to these updated production hosts. Update both ends. No private key or connection grant is included in discovery announcements. There is no cloud relay, per-user directory, or automatic background acceptance.

The stream still uses one host-wide TLS PSK, but possession of that key is no longer sufficient: the server also consumes a separately approved, short-lived, single-use grant before sending its hello/media or accepting input. Multiple approved viewers share the host's input settings; exclusive-controller arbitration and per-connected-device revoke controls remain future work. Stop sharing / Reset Pairing revokes all viewers.

## Windows and Linux

```sh
cd desktop
npm ci
npm run setup
npm test
npm start
npm run package:windows
npm run package:linux
npm run package:mac
```

Use Node 24+ for development. The Windows output is a **portable folder** with `Mac2Phone.exe`; keep every DLL and resource alongside it. It is not an installer or a standalone EXE. Linux is a portable folder too; launching it requires the desktop's normal Chromium libraries and sandbox support. Do not work around launch failures by disabling the sandbox. The separate Mac desktop app is named `Mac2PhoneDesktop` to avoid replacing the native menu-bar host.

To host, expand **Share this computer**, choose a display, optionally enable remote input and system sound, then start. On Windows, accept the application's private-network firewall prompt if needed. The static PowerShell helper uses Win32 APIs at the app's existing privilege level; elevated/UAC screens remain protected. Its `-Check` mode compiles and validates the ABI without emitting input.

On Linux, install `xdotool` for X11 control and the utility providing `parec` for output-monitor audio. Wayland is deliberately view-only pending a tested remote-desktop portal implementation. A portal may restrict display selection. On Mac use the native host for remote input; the Electron capture host is view-only. Only one host can listen on TCP 8765 at a time.

## Android

Build with Java 17 and Android SDK 36:

```sh
android/gradlew -p android testDebugUnitTest assembleDebug
# Optional installation, after connecting your own device:
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The APK is debug-signed for testing, not Play Store distribution. `local.properties`, signing keys and build outputs are ignored. Gradle's distribution is checksum-pinned; Bouncy Castle TLS 1.86.2 and its 1.86 core/util dependencies are pinned.

For hosting, choose the sharing options, review the disclosure for optional remote input, enable **Mac2Phone remote input** in Android Accessibility settings yourself, then approve the system screen-capture prompt. A persistent foreground notification exposes **Stop**. Accessibility access alone does not allow control: an active, explicitly control-enabled sharing session is also required. A system capture-stop callback, closing the service or stopping sharing ends the session. Queued input is bounded and invalidated when the sharing grant changes. The viewing activity disconnects on backgrounding.

Audio requires the playback-capture permission and a source app that permits capture. Microphone recording is not used. Calls, protected media, password fields and secure windows are not general-purpose sharing targets. Devices with aggressive background-service policies need physical testing.

## iPhone, iPad and Watch

Open `iOS/Mac2Phone.xcodeproj`. The **Mac2Phone** scheme builds the app, **Mac2PhoneBroadcast** extension and **Mac2PhoneWatch** companion.

For device signing, configure all three bundle identifiers and the same development team. Enable the same App Group on the iOS app and broadcast extension, and set `M2P_APP_GROUP` consistently (default `group.com.kianoosh.mac2phone`). If changing bundle identifiers, update the Watch companion identifier and broadcast identifier together. App Group capability provisioning requires a suitable developer account. Simulator/unsigned builds do not prove device entitlements are provisioned.

In iPhone/iPad **Share this iPhone / iPad**, prepare a link, copy it privately, then use the visible system broadcast button. ReplayKit starts only after the system confirmation. Its recording indicator provides a system stop path. **Stop broadcast & revoke link** removes the protected app-group credential; the extension polls revocation every half second. Replacing the link ends the old session. Credentials are excluded from backup; normal viewer credentials remain in Keychain.

The broadcast sends JPEG at up to 10 fps and 960 pixels on its longest edge to respect extension memory limits. It does not implement Mac display reshaping or remote iPhone control. Protected content and app audio capture remain subject to ReplayKit. Performance and extension memory need real-device validation.

## Protocol contract

- TLS 1.2, only `ECDHE-PSK-CHACHA20-POLY1305`, authenticated by a random 32-byte PSK and UUID identity. No plaintext fallback or active raw UDP media path.
- Stream media remains protocol v2. Approval links use `mac2phone://HOST:PORT#v3.UUID.BASE64URL_KEY.BASE64URL_GRANT`; both key and grant are 32 bytes, no Base64 padding. Legacy v2 parsing exists for old-host interoperability, not bypassing approval on updated production hosts.
- Inside TLS, approved clients send `M2PG` + 32-byte grant + `M2P2`/`M2PJ`. Hosts consume the grant once before any stream hello, media or input. Stop/rotation clears outstanding grants. Ephemeral approval links are not saved in the iOS viewer Keychain.
- Discovery/request protocol: u32BE JSON length (2–4096 bytes); public name/platform/version and a SHA-256 commitment to the requester's X25519 key plus random 32-byte nonce; host returns its public key; requester reveals key/nonce. The host verifies the commitment before showing an approval. X25519 + HKDF-SHA256 derives an AES-256-GCM response key bound to both keys and request name/platform. A transcript-derived six-digit code must be compared by the people using the devices. Only an accepted response carries the private one-use link, encrypted with authenticated context. No screen, audio or input uses this request socket.
- Request sockets, pending dialogs, peer lists, frame sizes and approval stores are bounded; incomplete exchanges time out after eight seconds on hosts. UI cancellation, closing a request socket, backgrounding a mobile app or quitting closes pending requests. This new protocol is a preview implementation, not independently audited.
- PSK hosts omit certificate-status extensions; no certificate/OCSP response exists in this authentication mode. A direct Apple Network ↔ Android regression test covers this interoperability requirement.
- After TLS, client sends `M2P2` or `M2PJ`. The hello's `video` field is authoritative: JPEG-only hosts reply `jpeg` to either magic.
- Frames: `u8 type | u32 big-endian length | payload`. Hello `0x08` includes protocol/version, platform, video/audio, screen/control/audio availability and `touchMode`.
- JPEG `0x09`: maximum 4 MiB, at most two unacknowledged frames; ACK `0x12` has an empty payload. Native Mac hardware-video config/frame formats are unchanged.
- PCM config `0x06`: u32 rate + u8 channels; audio `0x07`: i64 timestamp + interleaved signed 16-bit little-endian samples. Sound opt-in `0x16`: byte 0/1.
- Input `0x10` and settings `0x11` contain JSON. Common input: normalized `m`, `d`, `u`, `g`, `s`, `txt`, `key`, `cancel`. Hosts validate bounds and supported actions. Native Mac semantic gestures remain an additional capability.
- Ping `0x14`: eight bytes; pong `0x04`: echo plus eight-byte host timestamp. Handshake/idle/rate/queue limits bound resource use. Clipboard sync and file transfer are not implemented.

## Verification and physical test checklist

```sh
Scripts/check.sh --static
swift test
Scripts/check-cross-platform.sh
android/gradlew -p android testDebugUnitTest assembleDebug
Scripts/check-android-interop.sh
# On macOS: direct Apple Network ↔ Android TLS regression
Scripts/check-apple-android.sh
Scripts/check-nearby.sh
node desktop/test/nearby-discovery.cjs
cd desktop
ELECTRON_RUN_AS_NODE=1 node_modules/.bin/electron --test test/host.test.cjs
npm run test:ui
```

The local checks exercise Swift/Node/Electron/Bouncy Castle encrypted transport using synthetic data, bad keys and malformed frames, audio subscription, frame credit, release/disconnect and revocation. Android JVM tests exercise the actual transport classes, not an Android screen-capture session. Xcode builds cover iOS, ReplayKit and Watch simulator/device compilation. GitHub workflow definitions add Windows helper compilation and Linux/Android packaging; a workflow file is not evidence that GitHub has run it.

Before calling a platform stable, test both directions on physical hardware: display scaling/rotation, letterbox coordinate mapping, keyboard/IME, right-click and drag cancellation, audio/mute/permission denial, multiple viewers, background/lock/stop, bad/old links, network loss/reconnect, CPU/memory/FPS and sustained 20-minute sessions. Test Windows 11 first, then Android ↔ iPhone and Android ↔ desktop. Linux remains experimental until tested there.

## Next improvements

Efficient cross-platform H.264/WebRTC media, per-device keys/revocation UI, exclusive-controller arbitration, Linux Wayland remote-desktop portals, continuous Android gesture streaming, accessibility/polish passes and signed distribution follow real-device measurements.

## Platform references

[Electron desktop capture](https://www.electronjs.org/docs/latest/api/desktop-capturer), [Android MediaProjection](https://developer.android.com/media/grow/media-projection), [Android playback capture](https://developer.android.com/media/platform/av-capture), [Apple ReplayKit security](https://support.apple.com/guide/security/replaykit-security-seca5fc039dd/1/web/1), [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity/wcsession).
