# Contributing

Start with a small, focused change and describe the behavior it fixes. Include the Mac/iOS versions, device model, transport, control mode, and a reproduction sequence for bugs. Do not attach private desktop recordings, addresses, signing material, or tokens to public issues.

## Local checks

Run `swift test` and `Scripts/check.sh`. Use an unsigned Simulator build for review; deployment scripts modify installed applications and are not test runners. CI runs the same checks on macOS. No external Swift packages are required.

## Interaction rules

- Cancellation is never a tap and never launches momentum.
- Exactly one remote gesture owns the mouse button or scroll session.
- Finish the old gesture before changing finger count, mode, or surface geometry.
- Keep normalized touch coordinates separate from video pixels and Mac display points.
- Hide the video cursor in Touch mode without overwriting the user's cursor preference.
- Never let a late callback from an old connection tear down a new one.
- Bound protocol lengths before allocating memory or slicing buffers.
- Changes to the wire protocol must update both copies of `Protocol.swift` and their tests.

## Review and testing

Test small iPhones, landscape layouts, and iPad. Check larger text and VoiceOver. Follow `docs/TESTING.md` for gestures, disconnections, and display recovery. Document measurements and limitations rather than promising universal latency or compatibility.

## Licensing

Mac2Phone is licensed under the [MIT License](LICENSE). Submit contributions under the same license, and preserve applicable copyright and license notices.
