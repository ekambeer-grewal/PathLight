# PathLight — HealthHack iPhone prototype

An on-device SwiftUI prototype for an iPhone 15 Pro Max mounted upright on a chest harness. It provides nearby-surface announcements, stereo proximity beeps, two 30-second walking recordings, and a shareable PDF of movement changes.

**Start here:** open `PathLight.xcodeproj` on your Mac. No API keys, CocoaPods, downloaded ML model, XcodeGen, or third-party app dependencies are needed.

## Build status

This delivery contains real Swift source and a checked-in Xcode project, not a precompiled app. Swift syntax, the project structure, resource references, plist, scheme, and audio asset were checked in a Linux environment. **An Apple SDK compile, XCTest run, and physical-device sensor/audio testing have not been performed.** The included device checklist is the next acceptance gate. Do not present the prototype as clinically validated or safe for independent navigation.

## Run on your iPhone

1. Unzip this folder on your Mac and open **PathLight.xcodeproj**.
2. Use an Xcode version that supports the iOS version actually installed on your phone. Your reported version is **26.6.2**; confirm it under **Settings → General → About → iOS Version**. The project targets iOS 17 or later and uses established APIs. An older deployment target does not guarantee an older Xcode can install/debug on a newer iOS device.
3. In Xcode Settings → Accounts, add your Apple account if needed.
4. Select the blue **PathLight** project, then the **PathLight** target → **Signing & Capabilities**. Enable **Automatically manage signing** and select your team. Change `com.healthhack.PathLight` to a unique identifier, for example `com.yourname.PathLight`. Do the same for the test target if running tests.
5. Connect the unlocked iPhone to your Mac with USB and trust the computer. Select your physical iPhone as the run destination, with the **PathLight** scheme.
6. Enable **Settings → Privacy & Security → Developer Mode** on the phone, restart, and confirm if prompted. If the setting is missing, begin pairing the device in Xcode's device manager first. The exact device-manager label depends on your Xcode version.
7. Press **⌘R**. Accept Camera and Motion permissions when requested. If iOS asks you to trust the developer, follow the on-device instructions in Settings → General → VPN & Device Management.
8. Connect both AirPods. Open **Navigate**, acknowledge the prototype notice, and tap **Start sensors**. Tap **Test left** and **Test right** before walking.

Xcode may show deprecation warnings for established orientation APIs or `onChange` overloads with a new SDK; warnings are not necessarily build failures. If the build fails, copy the **first red compiler error with its filename and line** for troubleshooting.

## How to use it

### Navigate

- Mount the phone **upright in portrait**, screen toward the chest, rear camera and LiDAR facing forward. Keep all rear lenses uncovered. Tighten the harness so it does not swing. An orientation gate pauses measurements when the phone is significantly tilted or upside down.
- Use a well-lit indoor demo space with a sighted partner. Keep using the participant's normal mobility aid. Do not demonstrate near stairs, roads, drop-offs, or crowds.
- Slowly scan a door, chair/seat, and table. Apple mesh labels may take several seconds to appear and may fail or be wrong. The app says **Seat**, since the built-in category does not distinguish a chair from every other kind of seat.
- The distance is **from the rear camera to sampled visible surfaces**, not clearance from the person's body, nearest extremity, or full object bounding box.
- An unclassified surface is announced as **Obstacle**. A generic obstacle beep is not proof that semantic recognition worked.
- A left/right tone indicates the surface's location, **not an instruction to turn**. Occupied left/center/right sectors alternate. The overall repeat interval decreases as the nearest detected surface approaches; center tones play in both channels.
- There is no “path clear” announcement. “No reliable reading” means missing information, not a safe route.
- Check the audio output name. Stereo requires both earbuds, Mono Audio off, and no head-tracked processing that changes the cues. In iOS audio accessibility settings, keep balance centered. Configure AirPods audio so surroundings remain audible; do the channel test while stationary. Bluetooth latency and system processing remain device-test concerns.
- Generic alerts sample a forward chest-height corridor: approximately 0.9 m below to 0.8 m above the camera. **Low, overhead, off-screen, transparent, reflective, and very close hazards can be missed. Stairs, drop-offs, curbs, traffic, and route planning are not implemented.**

### Walking baseline and comparison

1. Start the sensors and wait for live tracking and motion readiness.
2. In **Walking**, optionally note the route, shoes, fatigue, symptoms in the participant's own words, or harness setup. Notes are limited to 600 characters.
3. Tap **Record baseline**. There is a five-second countdown followed by a 30-second walk. Walk normally on a clear, level route with consistent placement. Use a route long enough to avoid repeated turns; fast turns are excluded. Do not change natural gait to manufacture a medical flag.
4. A baseline is saved only if its data passes the engineering quality gates. An unusable attempt preserves any previous baseline.
5. Tap **Record comparison walk** and repeat the protocol. An insufficient-quality assessment can be saved for inspection, but no change verdict is produced.
6. In **Reports**, review the result and tap **Share PDF report** to save to Files or share through iOS. It is never sent to a doctor automatically. You can stop scanning before sharing.

Replacing a baseline asks for confirmation. A successful replacement removes previous assessments so they cannot be compared with the wrong baseline. Up to 20 assessments are retained. **Delete all local walks and reports** removes the app's saved records and generated temporary PDFs; it cannot remove copies already shared elsewhere.

## What the app actually measures

| Feature | Implementation | Important limit |
|---|---|---|
| Surface labels | ARKit `.meshWithClassification`: door, seat, table | Built-in scene categories, not a custom trained object detector; labels can be wrong |
| Distance | Current, high-confidence LiDAR scene depth; camera intrinsics convert axial depth to radial range | Approximate visible-surface distance, capped at 4 m for alerts |
| Label freshness | Project sampled mesh faces into the current image and require depth agreement within 0.25 m | Helps reject stale/occluded surfaces; does not guarantee correct object identity |
| Generic proximity | Lower 20th percentile of depth samples in each forward sector | Thin/small hazards may be missed; corridor does not cover the whole body |
| Voice | AVSpeechSynthesizer, nearest surface and distance | Rate-limited to reduce overlapping speech |
| Stereo cues | Bundled stereo WAV through AVAudioPlayer pan | System mono audio, routing, and Bluetooth latency need testing |
| Speed | Horizontal displacement of ARKit camera pose over roughly 0.5 s | Camera/motion world tracking; **not** object-distance change or direct joint tracking |
| Rotation | Core Motion rotation-rate magnitude RMS, requested 50 Hz | Phone/chest motion, not a clinical joint measure |
| Acceleration | Core Motion gravity-removed acceleration magnitude RMS | Phone/chest motion in m/s²; influenced by placement and pace |
| Report | Native UIKit PDF renderer with quality, metrics, changes, notes, and methods | Descriptive, unvalidated observations only |

LiDAR supplies nearby scene geometry and distance in the shared AR session. Speed uses the world-tracked **camera pose**. It is not a separate LiDAR-only speed measurement. This is more appropriate than differentiating distance to an arbitrary object, which can move or leave view.

Speed below 0.05 m/s is treated as zero to suppress jitter. Position intervals with poor tracking, gaps over 0.8 s, speed at or above 3 m/s, stale motion, or rotation at/above 0.8 rad/s are excluded. Motion data during poor tracking or fast rotation is excluded. Reported distance is over accepted intervals only; missing intervals are not filled in.

### Movement-change rules

An engineering quality gate requires at least 25 seconds, at least 70% accepted position time, at least 70% motion coverage, and at least 60% walking within accepted position time. Baseline and assessment must reference the same baseline ID and mean phone tilt must agree within 15°. Position-tracking quality is necessary but does not establish measurement accuracy.

These **arbitrary demo thresholds are not medically validated**. Each flag must exceed both a relative and an absolute limit:

| Metric | Relative change | Absolute change | Direction |
|---|---:|---:|---|
| Mean speed | 20% | 0.15 m/s | Either |
| Within-walk speed SD | 40% | 0.08 m/s | Increase |
| Rotation RMS | 30% | 0.08 rad/s | Either |
| Acceleration RMS | 30% | 0.15 m/s² | Either |

The report says either **Movement change — review suggested**, **No demo threshold crossed**, or **Repeat recording — comparison unavailable**. No arthritis probability or diagnosis is produced. Absence of a flag does not mean normal movement or absence of disease. A single 30-second walk is only a demo reference; a meaningful personal baseline would require repeated, validated measurements. The app does not measure joint angles, gait symmetry, disease severity, or cadence.

## Privacy and lifecycle

- No backend, analytics, model download, API key, network requests, or account login.
- Frames are processed in memory; camera images/video are not saved.
- Sensor-derived records and participant notes are saved in Application Support with complete file protection and excluded from backup. Reports are protected temporary files. User-shared exports follow the chosen destination's storage rules.
- Reports include recording times and device/OS description but do not require patient names.
- Scanning stops when the app becomes inactive or moves to the background. Interrupted walks are canceled, not silently accepted. Resume manually with **Start sensors**.
- Fresh data is required for proximity beeps. Tracking failures clear cues. Audio interruptions pause the sensor session; route changes clear previous cues and prompt another channel check.
- The app keeps the screen awake only during a sensor session. LiDAR/camera use consumes power and may warm the device. Stop between demo runs.

## Tests and acceptance

Open the project in Xcode and run **Product → Test (⌘U)**. `PathLightTests` includes 11 tests covering baseline linkage, quality failures, motion gaps, stationary recordings, changed tilt, weighted measurements, threshold floors, storage round-trip, and direction boundaries. These tests exercise real app types. They have **not** been run in this environment.

Use `DEVICE_TEST_CHECKLIST.md` on your iPhone before the demo. That checklist covers things unit tests cannot: LiDAR alignment, device placement, stereo channel direction, sensor permissions, interruptions, and real measurements.

## Source map

| File | Responsibility |
|---|---|
| `PathLightApp.swift` | App lifecycle |
| `ContentView.swift` | Accessible SwiftUI screens, preview, audio routing, share sheet |
| `AppModel.swift` | AR session, Core Motion, recording, storage, lifecycle handling |
| `SceneScanner.swift` | Depth/mesh processing and screen-sector assignment |
| `AudioGuide.swift` | Speech, stereo pan, beep scheduling, stale-data expiry |
| `Models.swift` | Samples, summary metrics, quality gates, baseline comparison |
| `ReportWriter.swift` | PDF export |
| `Tests/PathLightTests.swift` | XCTest suite |
| `Tools/rebuild_project.py` | Optional project regeneration; Python standard library only |

## Suggested use of the remaining 38 hours

1. **First 2 hours:** compile, sign, install; fix any SDK-specific errors; verify camera/motion permissions and AirPods direction while stationary.
2. **Next 6 hours:** test door/seat/table labeling and measure distances at marked positions. Test phone mounting and tracking loss. If semantics fail in your space, label the demo honestly as generic proximity detection.
3. **Next 6 hours:** collect repeated walks on a fixed route, check speed against a measured distance and stopwatch, inspect report quality. Do not tune thresholds to imply arthritis detection.
4. **Remaining time:** address observed failures, rehearse with a spotter, prepare the pitch and an honest backup screen recording after a successful physical-device test. Do not add stairs before the core demonstration is stable.

## References

Apple documentation consulted for the implementation:

- [ARKit scene depth](https://developer.apple.com/documentation/arkit/arframe/scenedepth)
- [AR mesh classifications](https://developer.apple.com/documentation/arkit/armeshclassification)
- [Mesh geometry classification](https://developer.apple.com/documentation/arkit/armeshgeometry/classification)
- [Understanding world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking)
- [Audio session A2DP behavior](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp)
- [Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Arthritis clinical evaluation — National Institute on Aging](https://www.nia.nih.gov/health/osteoarthritis/osteoarthritis)

This is a hackathon prototype, not a navigation aid cleared for independent use or a medical device validated for arthritis detection.
