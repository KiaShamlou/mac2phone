# Public repository and release checklist

## Implemented in the polish pass

- [x] Regression test target and repeatable check script
- [x] Cursor-free Touch mode and local touch feedback
- [x] Gesture cancellation, finger-count cleanup, and cancellable momentum
- [x] Separate trackpad movement from click-and-drag
- [x] Bounded parsers and checked integer offsets
- [x] Connection callback isolation and disconnect teardown
- [x] Accessible primary toolbar, gesture guide, stream presets, Mac setup dashboard
- [x] Build-output/signing ignores and configurable development team
- [x] Documentation and CI workflow definitions
- [x] MIT license selected and added
- [x] Shared logo, iOS asset catalog, Mac icon, and HTML project website

## Required before calling this release-ready

- [x] Protocol v2 TLS-PSK pairing and host-wide key rotation implemented
- [ ] Independent transport/pairing review and per-device authorization/revocation
- [ ] Windows 11 physical LAN, mouse/keyboard and sound QA
- [ ] Linux desktop runtime/package QA (experimental)
- [ ] Physical iPhone/iPad gesture and keyboard matrix
- [ ] Screen/audio streaming and latency measurements under packet loss
- [ ] Display restoration and multiple-display testing on supported Macs
- [ ] Real-device signing, release packaging, and notarization strategy
- [ ] CI workflow validated by a real GitHub run
- [ ] Release screenshots, localization review, and accessibility device audit
- [ ] Public security contact and support/version policy

No GitHub repository, commit, tag, or release is created by the local polish pass.
