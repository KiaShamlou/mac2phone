# Mac2Phone Android preview

Native Android 10+ viewer and foreground screen-sharing host. Uses paired TLS with the same framing as the Apple and desktop apps. Java 17, Android SDK 36 and the pinned Gradle wrapper are required to build.

```sh
./gradlew testDebugUnitTest assembleDebug
```

Output: `app/build/outputs/apk/debug/app-debug.apk`, debug-signed for testing. To view, paste a private host link. To host, choose sharing options and approve the system MediaProjection prompt. Remote touch/text additionally requires explicitly enabling Mac2Phone in Android Accessibility settings. Stop via the app or the ongoing notification to revoke the link.

System playback capture is limited to eligible apps. Microphone capture and password-field remote editing are not implemented. Accessibility gesture paths execute on release; arbitrary keyboard injection is not promised. Physical Android testing remains required.

See [the cross-platform guide](../docs/CROSS_PLATFORM.md) and [security model](../SECURITY.md). Bouncy Castle dependencies retain their own license; their license resources are merged into the APK.
