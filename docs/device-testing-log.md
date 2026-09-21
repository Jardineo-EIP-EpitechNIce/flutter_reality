# Device testing log

Manual test session of `example/` on a real ARCore device, following the
"test on real hardware" step of the project roadmap. iOS/ARKit testing is
still outstanding (no iPhone available in this session).

## Test environment

- Device: Google Pixel 9a
- OS: Android 17 (API 37), build `google/tegu/tegu:17/CP2A.260805.005/15828068:user/release-keys`
- ARCore: 1.56.262080393 (Google Play Services for AR)
- Flutter: 3.44.2 (stable, channel `[user-branch]`), Dart 3.12.2
- Build: `flutter run` debug build from `example/`, commit `56f44a8`
  (branch `agents/flutter-ar-core-plugin-description`)

## What works

- Camera permission prompt appears on first launch and is correctly
  honored/denied by the plugin (`ARSessionManager`); after granting, the
  camera feed renders.
- Horizontal plane detection works and is reported through
  `onPlaneDetected`; the status card updates with the live plane count.
- Tapping a detected plane places the local `duck.glb` model
  (`NodeType.localGLTF2`) anchored at the tapped location, confirmed with
  up to 11 models placed simultaneously without a crash.
- "Remove last model" correctly removes the most recently placed node and
  its anchor (both count and rendered scene update, no native error in
  logcat for `removeNode`/`removeAnchor`).
- Backgrounding the app (home button) cleanly closes the camera
  (`WindowManager: AppCompatCamera ... Camera 0 is closed`), no error
  logged.

## Bugs found

### 1. Black camera feed after returning from background (reproducible)

**Steps to reproduce:**
1. Launch the example app, grant camera permission, let it detect at
   least one plane.
2. Press Home to background the app.
3. Return to the app (recent apps or relaunching the launcher icon).

**Observed:** The AR view stays black. The session is still logically
running — the status card keeps updating (e.g. "1 plane(s) detected" kept
incrementing) — but the camera/GL surface is never redrawn. No error is
surfaced to Dart (`onError` is never called) and logcat shows no
exception: the failure is silent.

**Suspected cause:** `ArView.kt` passes the Activity's `Lifecycle` to
`ARSceneView` as `sharedLifecycle` (see `android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArView.kt`),
so pause/resume of the GL surface and ARCore session is handled
automatically inside `io.github.sceneview:arsceneview:2.2.1`
(`android/build.gradle:54`). That library version predates Android 17 and
this device; the resume path does not appear to successfully recreate the
rendering surface. Needs reproduction against a newer `arsceneview`
release before attempting a fix here.

### 2. Intermittent native crash (SIGSEGV) on resume, under load

**Steps to reproduce:** Same as above, but observed once after 9 models
were placed in the scene before backgrounding. Not reproduced on a
follow-up attempt with 0 models placed, so it appears load/timing
dependent rather than 100% deterministic.

**Observed:** App process dies (`Fatal signal 11 (SIGSEGV)`), returning to
the home screen with no dialog, no Dart-side error.

**Tombstone excerpt** (`tid == pid`, i.e. crashed on the main thread):

```
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0000043800000780 (read)
backtrace:
  #00 pc 00000000001062f0  libfilament-jni.so (offset 0x24b8000)
      (BuildId: c1ee70bcc213bdfcce2421b7860127c85b755d6d)
```

The crash is inside Filament's native renderer (used internally by
`arsceneview`), consistent with bug #1: a rendering surface/engine handle
that is invalid by the time the resume path touches it. `libfilament-jni.so`
ships without exported symbols in this build, so only the offset is
available; deeper diagnosis needs a locally-built `arsceneview`/Filament
with symbols, or reproducing against a newer library version.

## Not yet tested

- iOS / ARKit (no iPhone available in this session).
- Vertical plane detection specifically (only horizontal surfaces were
  used in this session).
- Gesture-based pan/rotate on placed nodes (not wired into the example
  app yet).

## Next steps (step 3 of the roadmap)

- Reproduce bug #1 with `arsceneview` bumped to its latest 2.x release and
  see if the resume path is fixed upstream before patching around it here.
- Wire the plugin's `onError` callback (or a new lifecycle-specific
  callback) to report when the native session fails to resume, instead of
  failing silently — required before this can be called "handled" per the
  project's error-handling constraints.
- Once a fix is in place, re-run this exact repro (background → foreground,
  with and without placed models) to confirm both the black-screen case
  and the crash are resolved.
