# PathLight physical-device acceptance checklist

Status on delivery: **not executed**. Record actual outcomes rather than treating these as passing tests. Use a sighted partner, normal mobility aid, and a clear level indoor space. Do not blindfold a tester or approach hazards to demonstrate proximity.

## Install and permissions

- [ ] Open project, choose team and unique bundle ID, build for the physical iPhone.
- [ ] Record Xcode version, exact iOS version, phone model, and AirPods model.
- [ ] Run the included XCTest suite (⌘U); record pass/fail and any compile errors.
- [ ] First launch: allow camera and motion; Start sensors reaches a live status.
- [ ] Denied camera: app explains the setting and stays stopped.
- [ ] Denied/unavailable motion: navigation state is understandable; no walking baseline is accepted without usable motion.
- [ ] Simulator: capability error is visible; no fake LiDAR readings appear.

## Stationary stereo and geometry

- [ ] Mount upright in portrait, camera forward. Verify lenses and LiDAR are not covered.
- [ ] Turn off Mono Audio and head-tracked processing; center audio balance.
- [ ] Test left is heard in the left ear; test right in the right ear. Stop if this fails.
- [ ] With tester stationary, partner places a large matte object left, center, then right. Confirm speech and beep side match physical position. Test the same object at marked 0.75, 1.5, 2, and 3 m distances from the camera. Record measured error; do not assume an accuracy specification.
- [ ] Partner changes object distance while tester remains stationary. Beep interval should decrease as it approaches; camera-to-surface distance should decrease.
- [ ] Place objects on both sides; both occupied sides should receive alternating cues. A left beep never means “walk left.”
- [ ] Slowly scan a chair/seat, table, and door. Confirm actual labels. Record failures and time-to-label. No label should be counted as a successful detection merely because “Obstacle” appears.
- [ ] Remove a labeled object or block the camera view with another surface. Check stale/occluded labels do not persist unreasonably. If they do, stop semantic demonstrations and fix before use.
- [ ] Look at an empty hallway. Confirm the floor does not dominate generic alerts; record any false alerts. There is intentionally no “path clear” claim.
- [ ] Cover the camera / point at a featureless wall. Alerts clear when tracking is lost or depth becomes unreliable. Stop if old alerts keep repeating.
- [ ] Tilt the harness substantially or rotate the phone landscape/upside down. Upright warning should replace measurements.

## Recording and report

- [ ] Record a normal 30-second walk after the countdown. With good tracking and sufficient walking, baseline is saved.
- [ ] Stand still for a baseline attempt. It must fail walking quality and must not overwrite an existing baseline.
- [ ] On a measured straight route, compare tracked distance/speed against a tape measure and stopwatch. Record differences across at least three walks. The app's metrics are phone estimates, not ground truth.
- [ ] Record a repeat walk with unchanged harness and route. Inspect speed, rotation, acceleration, coverage, and whether changes are plausible.
- [ ] Change harness angle by more than 15 degrees while keeping it generally upright and record again. Comparison should be unavailable if mean tilt differs by more than 15 degrees.
- [ ] Induce extended tracking loss during an assessment while stationary. Report should identify insufficient quality, not claim “No demo threshold crossed.”
- [ ] PDF exports, opens in Files, and contains the correct baseline/assessment dates, units, notes, quality percentages, and limitations with no clipped text.
- [ ] Close/relaunch: baseline and saved assessments remain. Images/video were not written to Photos.
- [ ] Baseline replacement asks for confirmation; bad replacement preserves existing data; successful replacement clears old assessments.
- [ ] Delete local data clears baseline, assessments, notes, and local reports. Shared files remain at their destination.

## Interruptions

- [ ] Switch apps / lock screen mid-recording: recording cancels, sensors and audio stop. Foreground return requires manual restart.
- [ ] Simulate a phone/audio interruption: app stops; no stale cue resumes automatically.
- [ ] Disconnect AirPods: output status updates and channel-check prompt appears. Reconnect and repeat the left/right tests.
- [ ] Stop sensors repeatedly, then restart: no duplicate beeps, timers, or recordings.
- [ ] Run for five minutes and observe responsiveness, audio latency, temperature, and battery use. Stop for overheating or excessive latency.

## Record demo limits

Write down tested object types, distances, lighting, placement, and failures. A completed checklist does not establish medical or navigation safety. The live presentation should say **nearby-surface awareness + walking-change observations**, with stairs and clinical validation as future work.
