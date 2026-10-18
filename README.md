# PathLight

PathLight is an iPhone prototype that combines obstacle awareness with walking and movement tracking. It helps users notice nearby objects and keep a visual record of changes during their walks.

## Features

- Detects chairs and tables with YOLO11n and estimates nearby walls using LiDAR and ARKit.
- Announces object direction and distance, with faster beeps as an object gets closer.
- Focuses audio alerts on one selected object to reduce confusing announcements.
- Records a short speed and gyroscope baseline, then tracks a walk until the user ends it.
- Flags movement changes and notes when a slowdown occurs near an obstruction.
- Displays walk summaries and charts, with PDF export for sharing.

## Requirements

- A LiDAR-equipped iPhone Pro running iOS 17 or later.
- A Mac with Xcode compatible with the phone’s iOS version.
- A chest mount that keeps the rear camera facing forward.
- Stereo headphones for left and right audio cues.

## Setup

1. Open `PathLight.xcodeproj` in Xcode.
2. Select your development team under **Signing & Capabilities**.
3. Connect your iPhone, select it as the run destination, and press **Run**.
4. Allow camera and motion access when prompted.

## Using PathLight

1. Open **Navigate**, start the sensors, and test the left and right audio cues.
2. Open **Walking** and record a five-second baseline on a clear, level route.
3. Tap **Start walk**. Keep the phone mounted consistently and the app open.
4. Tap **End walk & save**, then open **Summary** to review charts or share a PDF.

## Important

PathLight is an experimental prototype. It can miss obstacles and does not diagnose medical conditions. Test with a sighted partner and continue using your usual mobility aid. Walk records stay on the phone unless you share a report.
