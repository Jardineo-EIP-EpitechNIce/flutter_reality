# AR Flutter Plugin example

This small app exercises the plugin on a physical AR-capable Android or iOS
device. It requests camera permission, starts an AR session, displays detected
planes, and reports tap and error events.

Tapping a detected plane or feature point places a small local 3D model
(`assets/models/duck.glb`, see its [notice](assets/models/NOTICE.md) for
attribution) at the tapped location. The status card at the bottom of the
screen shows how many models are currently placed, and the button below it
removes the most recently placed model (and its anchor) from the scene. The
logic that decides which hit-test result a tap should use — preferring a
tracked plane over a raw feature point, and the closest one when several
match — lives in [`lib/hit_test_selection.dart`](lib/hit_test_selection.dart)
and is covered by
[`test/hit_test_selection_test.dart`](test/hit_test_selection_test.dart).

Placed models can also be dragged (pan) and rotated with a two-finger
twist; the status card reports "Moved model."/"Rotated model." when a
gesture completes.

## Run

From the repository root:

```bash
cd example
flutter pub get
flutter run
```

AR features are not available on desktop, web, simulators, or emulators without
AR support. Android builds require API 28 or newer, and iOS builds require iOS
13 or newer. When reporting a bug, include the device model, OS version, Flutter
version, steps to reproduce, and the relevant output of `flutter run -v`.
