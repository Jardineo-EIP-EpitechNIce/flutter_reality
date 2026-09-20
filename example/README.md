# AR Flutter Plugin example

This small app exercises the plugin on a physical AR-capable Android or iOS
device. It requests camera permission, starts an AR session, displays detected
planes, and reports tap and error events.

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
