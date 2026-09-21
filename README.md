# flutter_reality
[![pub package](https://img.shields.io/pub/v/flutter_reality.svg)](https://pub.dev/packages/flutter_reality)



This version is a direct adaptation of the original ar_flutter_plugin (https://pub.dev/packages/ar_flutter_plugin), 
migrating the Android component from Sceneform to sceneview_android, enabling the use of animated models.<br>
This fork was created because the original plugin had not been updated since 2022. <br><br>
➡ Changes include an update to the AR Core endpoint, a gradle upgrade, and compatibility with FlutterFlow.<br>
➡ Migration has been done from sceneform to sceneview_android; any contribution is welcome.

## Scope and optimization

This plugin provides a unified Flutter API over native ARCore and ARKit capabilities. It
currently focuses on the core AR session, plane detection, hit testing, anchors, model
placement, and object interaction features.

The current version does not include:

* an advanced model cache or preloading pipeline;
* GPU or memory optimization;
* LOD, texture compression, or automatic model reduction;
* enhanced occlusion or depth processing;
* advanced placement stabilization;
* device-specific dynamic quality adjustment;
* FPS, memory, GPU-time, or temperature instrumentation;
* a redesign of frequent Flutter-to-native communication.

These are deliberate boundaries rather than guarantees of production-level AR performance.
Future optimization can be implemented in the native Android and iOS layers while
preserving the existing Dart API. Possible directions include native model loading and
caching, device-adaptive session configuration, improved placement filtering, depth and
occlusion support, native interaction handling, lifecycle and memory improvements, and
performance instrumentation on representative devices.

## Development roadmap

The project is developed in the following order:

1. Keep the Dart API stable while fixing lifecycle, placement, and error-handling bugs.
2. Run formatting, static analysis, unit tests, package validation, and dependency checks
   on every pull request through GitHub Actions.
3. Use the [example application](./example) on physical ARCore and ARKit devices to
   reproduce issues and validate changes.
4. Add native performance improvements one measurable area at a time, with tests and
   device-level debug feedback before changing the public API.

The repository does not claim that a desktop, simulator, or ordinary emulator can
execute an AR session. Those environments can run package checks, but runtime AR
validation requires a compatible physical device.

## Local development and debugging

Run the automated checks from the repository root:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test example/lib
flutter analyze lib test example/lib
flutter test --no-pub
```

### Running the example app on a physical device

The [example app](./example) is a small AR scene: it requests camera
permission, shows detected planes, places a model on tap, and lets you
drag/rotate it or remove the last one placed. See its own
[README](example/README.md) for what it exercises in more detail.

1. Connect an ARCore-certified Android device (or an ARKit-capable iPhone)
   over USB, with USB debugging / developer mode enabled, and confirm it's
   detected: `flutter devices` should list it.
2. From the repository root:
   ```bash
   cd example
   flutter pub get
   flutter run
   ```
3. On first launch, grant the camera permission prompt. The status card at
   the bottom of the screen will read "AR session ready" once
   initialization completes.
4. Move the device slowly over a textured, well-lit surface (floor, desk,
   or wall) until the status card reports a detected plane.
5. Tap a detected surface to place a model. Drag it (touch and hold, then
   move the device) to reposition it, use a two-finger twist to rotate it,
   or tap "Remove last model" to take it back out.

**Simulators, emulators, and desktop builds cannot run this** — there's no
camera or motion tracking to feed ARCore/ARKit. Use `flutter run` against a
real, connected device.

When reporting a problem, include the device model, OS version, Flutter version,
steps to reproduce, expected behavior, actual behavior, and the relevant section
of `flutter run -v` output.

### Troubleshooting

**Camera permission prompt doesn't appear, or the app is stuck on "Waiting
for camera permission..."**
Check that the permission is actually declared: Android apps inherit it
from this plugin's manifest automatically, but iOS apps need
`NSCameraUsageDescription` in their own `Info.plist` (see
[iOS Permissions](#ios-permissions) above) or the OS silently refuses to
show the prompt. If you previously denied the permission, it won't
re-prompt — grant it from the OS app settings instead.

**The AR view is black even though permission was granted**
Confirm the device is actually AR-capable (see
[Requirements and device compatibility](#requirements-and-device-compatibility)
above) — a non-ARCore/ARKit device or an emulator will get this far and
still show nothing, since there's no real camera feed to track. On
Android, if you're embedding the AR view yourself rather than using this
plugin's `ARView` widget as-is, make sure your `AndroidView` requests true
Hybrid Composition (see `lib/widgets/ar_view.dart` for the pattern) — the
underlying `ARSceneView` is a `SurfaceView`, and Flutter's other platform
view composition modes don't reliably keep a `SurfaceView`'s rendering
surface attached, especially after the app returns from the background.

**No planes are ever detected**
Move the device slowly and continuously over the surface — ARCore/ARKit
need a few seconds of parallax motion to build a depth estimate. Plain,
reflective, transparent, or very dark surfaces (glass tables, mirrors,
glossy floors, plain white walls in low light) are hard or impossible to
track; try a textured surface with good, even lighting instead.

**A tap doesn't place a model, or the status shows "No plane or point
detected under the tap"**
The tap needs to land on an area ARCore/ARKit has already registered as a
tracked plane or feature point — tapping empty space or an
not-yet-detected area won't hit-test successfully. Wait for the plane
detection status to update first, then tap within the area that's been
scanned.

**A model doesn't load / addNode returns false**
Check `flutter run -v`'s output for the actual native error — the model
`uri` needs to point to an asset that's registered in your app's
`pubspec.yaml` `assets:` section (for `NodeType.localGLTF2`) or a reachable
URL (for `NodeType.webGLB`); a typo'd path or an unregistered asset fails
silently from the UI's perspective but logs the real reason natively.


<b>❤️ I invite you to collaborate and contribute to the improvement of this plugin.</b><br>
To contribute code and discuss ideas, [create a pull request](https://github.com/Jardineo-EIP-EpitechNIce/flutter_reality/compare), [open an issue](https://github.com/Jardineo-EIP-EpitechNIce/flutter_reality/issues/new), or [start a discussion](https://github.com/Jardineo-EIP-EpitechNIce/flutter_reality/discussions).

## Fluterflow demo app
<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td>
<b> You can find a complete example running on FlutterFlow here :</b><br>
<a href="https://app.flutterflow.io/project/a-r-flutter-lib-ipqw3k">https://app.flutterflow.io/project/a-r-flutter-lib-ipqw3k</a>
</td>
</table>

### Installing

Add the Flutter package to your project by running:

```bash
flutter pub add flutter_reality
```

Or manually add this to your `pubspec.yaml` file (and run `flutter pub get`):

```yaml
dependencies:
  flutter_reality: ^0.0.3
```

Or in FlutterFlow : 

<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td> Simply add : <br> <b>flutter_reality: ^0.0.3 </b> <br> in pubspecs dependencies of your widget.
</td>
</table>

### Importing

Add this to your code:

```dart
import 'package:flutter_reality/ar_flutter_plugin.dart';
```

## Requirements and device compatibility

| | Android | iOS |
| --- | --- | --- |
| Minimum OS version | API 28 (Android 9) | iOS 13 |
| AR framework | [ARCore](https://developers.google.com/ar/devices) | ARKit (built into iOS, no separate install) |
| Runtime dependency | [Google Play Services for AR](https://play.google.com/store/apps/details?id=com.google.ar.core) must be installed — Play Store installs/updates it automatically on ARCore-certified devices | none beyond the OS itself |
| Device certification | Device must be on Google's [ARCore supported devices list](https://developers.google.com/ar/devices) | Device needs an A9 chip or newer (iPhone 6s / iPad 2017 and later) |

Notes from testing this plugin on real hardware (see
[`docs/device-testing-log.md`](docs/device-testing-log.md) for the full
session):

* `android/src/main/AndroidManifest.xml` declares
  `<uses-feature android:name="android.hardware.camera.ar" android:required="true"/>`.
  This means **Google Play will hide your app entirely** from devices
  that don't support ARCore — it won't show up in search or as
  installable. This is usually what you want for an AR-only app; if your
  app also has a non-AR mode, override this feature to
  `android:required="false"` in your own app's manifest and check AR
  availability at runtime instead.
* Desktop, web, and plain Android/iOS simulators or emulators cannot run
  an AR session — there's no camera or motion sensor to track. Use a
  physical device.
* Devices without Google Play Services (common on some China-market
  Android phones) cannot install Google Play Services for AR and will
  not be able to run this plugin on Android, even if the SoC would
  otherwise support ARCore.
* On Android devices with 16 KB memory pages (mandatory for new devices
  launching with Android 15+, e.g. recent Pixels), you may see a debug
  "App compatibility" warning about native libraries not being 16 KB
  page-aligned. This comes from the underlying `arsceneview`/Filament/
  ARCore native libraries, not from this plugin's own code, and is a
  known unresolved upstream limitation as of this writing — see
  `docs/device-testing-log.md` for the investigation. It hasn't caused
  functional problems in testing so far, but it's worth knowing if you
  see it and aren't sure where it's coming from.

## IOS Permissions
* To prevent your application from crashing when launching augmented reality on iOS, you need to add the following permission to the Info.plist file (located under ios/Runner) :

  ```
  <key>NSCameraUsageDescription</key>
  <string>This application requires camera access for augmented reality functionality.</string>
  
  ```
  <br>
<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td><b> If you're using FlutterFlow, go to "App Settings" > "Permissions"<br>
 For the "Camera" line, toggle the switch to "On" and add the description :<br> "This application requires access to the camera to enable augmented reality features."  </b><br>
<br>

</td></table>

If you have problems with permissions on iOS (e.g. with the camera view not showing up even though camera access is allowed), add this to the ```podfile``` of your app's ```ios``` directory:

```pod
  post_install do |installer|
    installer.pods_project.targets.each do |target|
      flutter_additional_ios_build_settings(target)
      target.build_configurations.each do |config|
        # Additional configuration options could already be set here

        # BEGINNING OF WHAT YOU SHOULD ADD
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
          '$(inherited)',

          ## dart: PermissionGroup.camera
          'PERMISSION_CAMERA=1',

          ## dart: PermissionGroup.photos
          'PERMISSION_PHOTOS=1',

          ## dart: [PermissionGroup.location, PermissionGroup.locationAlways, PermissionGroup.locationWhenInUse]
          'PERMISSION_LOCATION=1',

          ## dart: PermissionGroup.sensors
          'PERMISSION_SENSORS=1',

          ## dart: PermissionGroup.bluetooth
          'PERMISSION_BLUETOOTH=1',

          # add additional permission groups if required
        ]
        # END OF WHAT YOU SHOULD ADD
      end
    end
  end
```

In FlutterFlow :

<table>
<td style="min-width:30px">
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td>
Unfortunately, at this stage, it is not possible to carry out the procedure above within FlutterFlow.  <br>
Therefore, it is necessary to publish your project with github and make the modifications manually. <br> And then publish wih Github selected in Deployment Sources : <br> <a href="https://docs.flutterflow.io/customizing-your-app/manage-custom-code-in-github#id-9.-deploy-from-the-main-branch">FlutterFlow Publish from Github</a>
</td>
</table>

## Android Setup

The plugin's own `android/src/main/AndroidManifest.xml` already declares the
camera permission and the ARCore hardware feature requirement, so most apps
don't need to add anything manually. Two things worth checking in your app:

* **`minSdkVersion`**: set it to at least `28` in your app's
  `android/app/build.gradle` (or `build.gradle.kts`), matching this plugin's
  requirement.
* **Google Play Services for AR**: it's installed automatically from the
  Play Store on certified devices the first time an ARCore app runs, but if
  you're testing on a device that never had an AR app installed before, make
  sure `com.google.ar.core` is present (`adb shell pm list packages | grep
  ar.core`) or let the OS prompt the user to install/update it.

If you hit a build error mentioning `SurfaceTextureWrapper` or
`RegisterNatives with FlutterJNI`, check `CHANGELOG.md` — both were fixed
issues from the original fork with links to the relevant discussions.

### Example Applications

| Example Name                 | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Link to Code                                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |------------------------------------------------------------------------------------------------------------------------------------------------------|
| Debug Options                | Simple AR scene with toggles to visualize the world origin, feature points and tracked planes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [Debug Options Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/debug_options.dart)                                   |
| Local & Online Objects        | AR scene with buttons to place GLTF objects from the flutter asset folders, GLB objects from the internet, or a GLB object from the app's Documents directory at a given position, rotation and scale. Additional buttons allow to modify scale, position and orientation with regard to the world origin after objects have been placed.                                                                                                                                                                                                                                                                | [Local & Online Objects Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/local_and_web_objects.dart)                  |
| Objects & Anchors on Planes  | AR Scene in which tapping on a plane creates an anchor with a 3D model attached to it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [Objects & Anchors on Planes Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/objects_on_planes.dart)                 |
| Object Transformation Gestures | Same as Objects & Anchors on Planes example, but objects can be panned and rotated using gestures after being placed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [Objects Gestures](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/object_gestures.dart)                                   |
| Screenshots                  | Same as Objects & Anchors on Planes Example, but the snapshot function is used to take screenshots of the AR Scene                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [Screenshots Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/screenshot.dart)                            |
| Cloud Anchors                | AR Scene in which objects can be placed, uploaded and downloaded, thus creating an interactive AR experience that can be shared between multiple devices. Currently, the example allows to upload the last placed object along with its anchor and download all anchors within a radius of 100m along with all the attached objects (independent of which device originally placed the objects). As sharing the objects is done by using the Google Cloud Anchor Service and Firebase, this requires some additional setup, please read [Getting Started with cloud anchors](cloudAnchorSetup.md)        | [Cloud Anchors Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/cloud_anchor.dart)                         |
| External Object Management   | Similar to the Cloud Anchors example, but contains UI to choose between different models. Rather than being hard-coded, an external database (Firestore) is used to manage the available models. As sharing the objects is done by using the Google Cloud Anchor Service and Firebase, this requires some additional setup, please read [Getting Started with cloud anchors](cloudAnchorSetup.md). Also make sure that in your Firestore database, the collection "models" contains some entries with the fields "name", "image", and "uri", where "uri" points to the raw file of a model in GLB format | [External Model Management Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/external_model_management.dart) |


## Screenshots and video

_Not yet added._ Once the example app has been validated on a physical
ARCore/ARKit device (see
[Running the example app on a physical device](#running-the-example-app-on-a-physical-device)),
add screenshots or a short screen recording here showing plane detection
and model placement in action. Save image files under `docs/screenshots/`
and embed them with `![description](docs/screenshots/filename.png)`; for a
video, either link to a hosted clip or add a GIF the same way.

## Plugin Architecture

This is a rough sketch of the architecture the plugin implements:

![ar_plugin_architecture](https://github.com/hlefe/ar_flutter_plugin_2/raw/main/AR_Plugin_Architecture_highlevel.svg)