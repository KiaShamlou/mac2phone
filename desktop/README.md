# Mac2Phone desktop preview

Electron viewer and selected-display host for protocol-v2 devices. Windows supports opt-in Win32 mouse/keyboard input and loopback audio. Linux capture is experimental, with X11 `xdotool` control and `parec` output-monitor audio; Wayland is view-only. The Mac desktop app provides viewing and view-only capture; use the native Mac host for full control.

```sh
npm ci
npm run setup
npm test
npm start
npm run package:windows
npm run package:linux
npm run package:mac
```

Use Node 24+ for development. `setup` installs the pinned Electron runtime explicitly. Keep the full generated app folder, including its Chromium/Electron license files. Target users launch `Mac2Phone.exe` without installing Node. Packaging and physical Windows tests are separate from the local Mac integration tests.

## Opening the Windows download

**Right-click the ZIP → Extract All → open the extracted folder → Mac2Phone.exe.**
The EXE is not standalone: keep every DLL, the `resources` directory, and all other files beside it. Do not run it inside the ZIP or copy only the EXE. Create a shortcut to the extracted EXE if you want a desktop icon.

If nothing opens, run **Diagnose Mac2Phone.cmd** in that folder. It checks for missing runtime files and prints the launch exit code after the app exits. Send the exit code and `%LOCALAPPDATA%\Mac2Phone\logs\startup.log` with the bug report. If the log is absent, mention that too: native loader failures can happen before JavaScript starts. For a graphics-related blank/crashing window, the optional **Start Mac2Phone (software rendering).cmd** launcher changes rendering for that launch only.

Startup failures in the main process, preload, or renderer now produce a visible error and a bounded, credential-redacted log. Normal windows are shown immediately instead of depending solely on a `ready-to-show` event. A second launch focuses the existing window.

`npm run test:startup` launches the real bootstrap, preload and UI in an isolated smoke test without discovery or screen capture. Windows CI also launches the packaged EXE with this test; a workflow definition is not a substitute for a successful CI run or testing on a Windows laptop.

Connect through Nearby devices in the Devices view, or use a one-use link copied from the sharing device. Turn on Control and Sound separately. Shift+Esc releases local keyboard capture. A link is a credential: share it privately, never in an issue. Desktop pairings stay in memory; Reset Pairing on the host revokes all devices.

To host, open **Share screen**, choose a display and optional input/sound, allow a local preview, then click **Start sharing**. **Stop sharing** closes connections and invalidates that session’s private link. Keep the application visible so sharing controls remain accessible.

See [the cross-platform guide](../docs/CROSS_PLATFORM.md) for setup, test steps, platform status and protocol details, and [SECURITY.md](../SECURITY.md) for the current security model. Original application code is MIT; Electron and bundled third-party code retain their own licenses.

## Screen sharing: access before connection

The desktop UI now separates **Devices**, **Share screen**, and **Session**. To share:

1. Open **Share screen → Check & choose**. On macOS, allow Screen Recording if the OS asks; a settings button is shown when access needs attention.
2. Select a display. Choose **Keyboard & mouse** and/or **System sound** if wanted; both are opt-in.
3. Click **Allow screen & preview**. Capture permission is requested in this click's user-activation task, after the display is prepared. This is a local preview: the sharing listener and media sender have not started.
4. Click **Start sharing**. Accept a nearby device request after comparing codes, or copy a one-use link.
5. **Stop sharing** remains available in the sidebar from any view. It closes connections, clears capture and revokes grants. Access changes require stopping or discarding the preview first.

Windows does not use the macOS Screen Recording prompt. The app's explicit selection/preview consent and Electron's media permission handler govern this flow; a Windows or organization policy can still deny capture. Camera and microphone access are not requested for screen sharing. System sound is loopback audio. If no audio track is provided, the UI says so and the host does not advertise audio.

### Permission regression

Electron 44.9.0 reports display capture to the permission-request handler as `media` with an empty `mediaTypes` array before invoking the display-media handler. The previous display-capture-only allowlist rejected that request with `NotAllowedError: Permission denied`. The new policy accepts that specific request only from the app's main frame with an unexpired selected-display grant; ordinary camera/microphone requests and unrelated origins remain denied. The display handler also requires a user gesture and consumes the grant once.

Reference: [Electron's pinned media permission implementation](https://github.com/electron/electron/blob/v44.9.0/shell/browser/web_contents_permission_helper.cc), [session permission API](https://www.electronjs.org/docs/latest/api/session#sessetdisplaymediarequesthandlerhandler-opts).

```sh
npm test
npm run test:capture       # Real getDisplayMedia; synthetic app page, not the desktop
npm run test:sharing-ui    # Setup, preview, denial, cancellation, audio and compact layout
npm run test:sharing-integration # Production IPC + capture + approved TLS, loopback only
npm run test:startup
npm run package:windows
node test/package-check.cjs windows
```

Physical Windows capture, input and audio still need a Windows laptop test. The synthetic tests verify the permission regression and app workflow, not Windows graphics drivers or system policy.
