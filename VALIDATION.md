# Delivery validation

Performed in the build workspace on 2026-10-17:

- All eight Swift source files parsed with the tree-sitter Swift grammar without syntax errors.
- `project.pbxproj` parsed using the Python `pbxproj` library. App and unit-test targets were found.
- Source and resource build references resolved to bundled files.
- `Info.plist` parsed with Python `plistlib`; camera and motion descriptions and portrait orientation were present.
- The shared Xcode scheme parsed as XML.
- `beep.wav` was checked as a 44,100 Hz, 16-bit stereo file with equal source channels for panning and no clipped samples.
- The source contains 11 XCTest test methods that exercise app logic; these tests are included for execution in Xcode.

**Not performed:** Swift type checking against the Apple SDK, an Xcode build, XCTest execution, simulator launch, PDF rendering by the app, physical-device testing, latency/accuracy measurements, or clinical validation. Parsing is not compilation. Follow `DEVICE_TEST_CHECKLIST.md` after opening the project on your Mac.

No simulated measurements, fake detections, or prerecorded reports are presented as sensor results in the app.
