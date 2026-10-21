# Desktop realtime video (0.5.3)

## What changes

The desktop viewer now opens an approved session in fullscreen. Its video and
pointer overlay share the same aspect-fit rectangle. Black bars are not remote
screen coordinates. Normalized coordinates remain independent of Retina/DPI
scale. While Control is enabled, the local cursor is hidden so it does not appear
beside the captured remote cursor. Pointer movement keeps only the latest sample
per animation frame; press, release, keyboard and cancellation stay ordered.

New desktop peers negotiate `webrtc-video-v1`. Captured frames go directly from
the selected display's MediaStreamTrack into the WebRTC encoder and decoder,
instead of canvas JPEG encoding, byte-copy IPC, TCP and JPEG image decoding for
every frame. H.264 is preferred when supported; Chromium negotiates a supported
codec and chooses its available encoder. Hardware acceleration is not assumed.

The active capture target follows viewer demand, up to 60 fps. Quality profiles cap the longest dimension
and encoder bitrate, without upscaling:

| Profile | Maximum dimension | Maximum bitrate | Adaptation preference |
| --- | --- | --- | --- |
| Auto (default) | 640–1920 pixels | 1.2–8 Mbps | Start at 1280/60; rescue tier 640/30 |
| Fast | 1280 pixels | 4 Mbps | Preserve frame rate |
| Balanced | 1920 pixels | 8 Mbps | Preserve frame rate |
| Sharp | 3840 pixels | 24 Mbps | Preserve text detail, potentially lower FPS |

These are upper bounds, not achieved-performance promises. The live overlay uses
WebRTC receiver statistics for actual FPS, resolution, codec, bitrate and media
round-trip time. RTT is not glass-to-glass capture/display latency. Static scenes
can legitimately produce low bitrate or frame rates. The pixel dimensions are stream caps, not changes to the host monitor mode.
System sound remains
opt-in PCM and control remains on the existing encrypted TLS connection.

## Negotiation and lifecycle

The existing v2 hello retains JPEG/PCM compatibility and adds the optional
`realtime: "webrtc-video-v1"` field. A client without this capability never
receives new messages. A supported viewer sends frame type **24**, with a
UTF-8 JSON payload bounded to **65,536 bytes**, after the approved TLS session:

1. Viewer: `start` with a named quality profile.
2. Host: `offer`; viewer: `answer`; both: bounded ICE `candidate` messages.
3. Viewer: `active` only after its first decoded video frame. The host then
   stops JPEG transmission for that viewer. Other legacy viewers keep JPEG.
4. Viewer: `quality` changes sender parameters without restarting capture.
5. Either side: `fallback` restores compatibility video after failure. A
   10–12 second setup timeout prevents an indefinitely blank screen.
6. Disconnect, revocation or Stop sharing closes the peer connections and
   releases the captured tracks. No approved viewers means no JPEG encoding.

Message direction, type, SDP/candidate lengths, quality names, peer identifiers,
state transitions and signaling rate are checked before relaying to a renderer.
Peer identifiers are generated per authenticated connection. Signaling from
another renderer or a stale peer is rejected.

## Network and authentication

The existing request, code comparison, host acceptance, one-use grant and
TLS-PSK authentication remain mandatory. SDP fingerprints travel inside that
authenticated session. WebRTC protects media using **DTLS-SRTP**; this does not
introduce custom cryptography. ICE servers are empty: no public STUN, TURN,
account, relay or external signaling service is configured.

Some LAN/VPN setups do not resolve Chromium's ephemeral `.local` host candidates.
Only those host-candidate names are replaced with the remote IP from the
already-authenticated TLS socket. No arbitrary hostname lookup or subnet scan
is performed; numeric candidates, fingerprints and ICE credentials are unchanged.
UDP still needs to work between the two computers. If it does not, compatibility
video resumes. Discovery also retries every five seconds and has a Refresh button.

Compatibility video is paced at up to 30 fps (rather than waiting 50 ms after
each encode), at up to 1920-pixel width and JPEG quality 0.8. New WebRTC-only
sessions avoid that encoding work entirely. Active sessions disable Electron
background throttling; idle windows return to normal throttling.

## Validation

```sh
npm --prefix desktop test
npm --prefix desktop run test:realtime
npm --prefix desktop run test:sharing-integration
```

The realtime test uses generated 1080p motion between two Chromium renderers on
one Mac's LAN interface, approved TLS signaling, intercepted input, synthetic
silence, live profile changes and forced compatibility recovery. It never
captures or controls a real desktop. Physical Windows encode, input injection,
firewall behavior, multi-display DPI and two-device latency require device QA.

Implementation references: [WebRTC specification](https://www.w3.org/TR/webrtc/),
[sender parameters](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpSender/setParameters),
and [Electron fullscreen lifecycle](https://www.electronjs.org/docs/latest/api/browser-window).

## Low-latency changes in 0.5.1

The receiver requests `jitterBufferTarget = 0` when supported. This is a
best-effort minimum-buffer preference: the browser still accounts for packet
arrival and loss, so actual buffering may be higher. Initial sender encodings
now include their resolution/bitrate caps before negotiation finishes. Fast,
Balanced and Auto favor frame rate; Sharp deliberately favors readable text.

Auto starts at a 1280-pixel longest edge / 4 Mbps cap. The sender samples real
outbound statistics every two seconds. Two consecutive active samples with CPU
or bandwidth limitation, encode time over 22 ms, or packet-send delay over 35 ms
lower one step. Six consecutive healthy active samples recover one step, up to
1920 / 8 Mbps. The lowest step is 960 / 2.5 Mbps. Idle screens and missing counters
never trigger changes. These conservative heuristics need further physical LAN
validation; they do not guarantee a particular frame rate or latency.

The overlay shows interval-average jitter-buffer, decode and encode time,
packet-send queue delay, dropped frames, packet loss and source frame rate.
Missing measurements show a dash, not a fabricated zero. These are distinct
pipeline measurements; do not add them and call that glass-to-glass latency.
CPU/network hints describe reported sender limitations, not a full diagnosis.

`realtimeTelemetry: 1` in the hello advertises the extension. An updated viewer
opts in with `telemetry: true` on `start`. Bounded host-only `telemetry` messages
travel over the same approved TLS session; older viewers never receive them.
Auto uses the existing `balanced` wire quality plus `adaptive: true`, retaining
0.5.0 compatibility. With an older sender, the UI offers manual modes rather
than advertising Auto support. No SDP, pairing secrets or addresses are included
in telemetry. Stop/disconnect clears peer sampling timers.

Compatibility JPEG decoding now retains one in-flight decode and only the newest
pending frame, acknowledging dropped frames without accumulating stale work.
The viewer resizes its canvas only when frame dimensions change. In compatibility
mode, stream controls explain why they are inactive; after WebRTC fails, they
stay disabled rather than silently accepting settings that have no effect.

The synthetic test embeds a millisecond clock in generated image pixels and
reads it after decoding on the same computer. This measures that fixture's frame
age; it does not represent Windows-to-Mac LAN latency. Load-adaptation checks
inject explicit encoder-pressure statistics and confirm the real outgoing video
changes resolution. They are simulations, not claims of testing a congested LAN.

For a physical-device report, choose Auto, keep the screen moving for ten seconds,
and capture the complete overlay. Include both app versions and whether Sound
is enabled. Use Fast for a fixed lower cap; Sharp trades smoothness for text detail.

References: [receiver buffering and sender parameters](https://www.w3.org/TR/webrtc/)
and [interval statistics definitions](https://www.w3.org/TR/webrtc-stats/).


## Two-way adaptation and capture budgeting in 0.5.2

Auto now considers the viewer, not only the encoder. The host advertises
`realtimeFeedback: 1`; the viewer explicitly opts in with `feedback: true` on
`start`. Once media is active, bounded `feedback` messages contain interval
frame count, decode time, jitter-buffer time, drop percentage and packet-loss
percentage. No SDP or device identity is part of feedback. Old hosts never
receive this message; the host rejects feedback before activation or without
opt-in. Manual profiles remain manual.

The sender evaluates the most recent feedback only when it is at most three
seconds old. Active viewer samples with decode time above 18 ms, buffering above
60 ms, drops above 8%, or loss above 3% count as pressure. Two consecutive pressured
sender sampling intervals lower Auto one tier. Recovery requires six healthy
active samples, including healthy receiver metrics when present. Missing or idle
receiver metrics do not count as a recovery signal. Sender CPU/network heuristics
from 0.5.1 remain. The ladder is now 1920/60/8 Mbps, 1280/60/4 Mbps,
960/60/2.5 Mbps, and a 640/30/1.2 Mbps rescue tier. These are heuristics, not a
measured-network model or a guaranteed fix for every source of delay.

**Capture budget:** the selected display track receives serialized, latest-wins
`applyConstraints` calls before encoding. It follows the highest-demand connected
viewer, preserving aspect ratio and never upscaling. Legacy viewers retain a
1920-pixel / 30 FPS budget. With no viewer, the local preview uses at most 960
pixels / 15 FPS. As capture dimensions change, every encoder's downscale ratio
is recalculated. Sharp can restore the original captured dimensions; closing
one viewer never reduces another's requested cap. Unsupported constraints leave
sharing active with encoder-side caps. This changes captured pixels, not the
physical monitor mode. A 4K-to-720p capture budget has nine times fewer pixels
per frame; this is **not** a measured nine-fold CPU or latency improvement.

**Motion:** the viewer can select a 30 or 60 FPS ceiling with a 0.5.2 host.
The cap applies to both sender encodings and shared capture demand; another
60 FPS viewer can keep the common capture at 60 while this viewer receives 30.
Auto's rescue tier may lower the ceiling further. The overlay always reports
actual received FPS separately from the target.

**Session controls:** a health pill distinguishes reported sender load,
network load and receiver backlog. Reduce delay switches a manual profile to
Auto (or Fast for an older host). Retry realtime renegotiates video after
compatibility fallback without repeating pairing. Copy diagnostics exports
at most 60 numeric samples, fixed enums, versions, quality and Sound state.
Both renderer and main process allowlist fields: no pairing links, addresses,
SDP, hostnames, screen pixels, typed text or free-form encoder names enter the
report. The clipboard is written only when the user clicks the button.

### Reproduce and report

1. Update both desktop applications to 0.5.2 and reconnect.
2. Choose Auto / 60 FPS and move or scroll a window for ten seconds.
3. Reveal the toolbar with F8 and choose **Copy diagnostics**. Include that report
   when reporting delay. Try 30 FPS when a steadier, lighter stream is preferable.
4. Compare at the same source resolution, content, Sound setting and LAN setup.
   Do not treat media RTT or the sum of interval averages as display latency.

Tests cover native browser capture constraints using a generated WebContents
source, multi-viewer budget arbitration, late capture completion, missing/stale
feedback, protocol opt-in, old peers, 30/60 FPS switching, diagnostics filtering,
retry and disconnect. The real-video test injects explicit receiver pressure to
verify that it changes the real encoder output; it is not a real congested LAN.

API references: [capture downscaling and frame decimation](https://www.w3.org/TR/screen-capture/#downscaling-and-frame-decimation),
[track constraints](https://www.w3.org/TR/mediacapture-streams/), and
[WebRTC statistics](https://www.w3.org/TR/webrtc-stats/).


## Session reliability in 0.5.3

The receiver checks interval decoded-frame progress after video becomes active.
Three seconds without a decoded frame count as a possible stall only when media
bytes keep arriving or recent sender telemetry reports active encoding. Static
screens, hidden windows, missing/reset counters and long timer gaps do not count
as decoder stalls. Sender activity used for this decision expires after three
seconds. This is a heuristic, not a way to detect every frozen source.

After an already-working stream fails or stalls, the viewer sends the existing
fallback signal and closes the old peer connection. Compatibility JPEG resumes
while a fresh WebRTC peer is negotiated on the same approved TLS session. No new
authorization, capture permission or control grant is created. Automatic attempts
are limited to two in a rolling minute, with 600/1200 ms delays. Initial setup
failures do not loop automatically. A failed retry consumes the same budget;
manual Retry realtime starts a fresh budget. Disconnect, Stop sharing and app
exit cancel pending retries. Input held during video interruption is released.

The main process now saves a bounded, versioned preferences file under its own
user-data directory. Only quality, 30/60 FPS target and automatic fullscreen are
accepted. Writes replace a private temporary file atomically; malformed settings
fall back to defaults and write errors leave the previous file intact. Pairing
links, device identities, Control and Sound are never stored there. Compatibility
adjustments do not overwrite the user's preferred Auto/FPS values. The fullscreen
preference takes effect on the next connection, not halfway through a session.

Control replies are gated by both session generation and request revision. A late
reply cannot turn the UI back on after a disconnect, a newer toggle, or Shift-Escape.
Disabling Control releases input immediately instead of waiting for IPC.

Tests: `npm --prefix desktop test`, `npm --prefix desktop run test:realtime` and
`npm --prefix desktop run test:preferences`. Recovery tests inject explicit
stalled counters into the real receiver path and verify real video renegotiation;
they do not simulate a complete physical Windows GPU/network failure. Preferences
smoke tests use isolated storage, a synthetic TLS host and intercepted fullscreen
calls, including reload and deliberately reordered control replies. Diagnostics
include a bounded numeric recovery-attempt count, without new identity fields.
