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

### 1. Black camera feed after returning from background — FIXED (see below)

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
`ARSceneView` as `sharedLifecycle` (see `android/src/main/kotlin/com/flutterreality/flutter_reality/ArView.kt`),
so pause/resume of the GL surface and ARCore session is handled
automatically inside `io.github.sceneview:arsceneview:2.2.1`
(`android/build.gradle:54`). That library version predates Android 17 and
this device; the resume path does not appear to successfully recreate the
rendering surface. Needs reproduction against a newer `arsceneview`
release before attempting a fix here.

### 2. Intermittent native crash (SIGSEGV) on resume, under load — no longer reproduced after the fix below

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

### Root cause found: prebuilt native libraries are not 16 KB page aligned

Android surfaced its own "App compatibility" warning on launch (debug
builds only) naming several native libraries as incompatible with 16 KB
memory pages — mandatory on newer devices/kernels including this Pixel
9a: `libarcore_sdk_jni.so`, `libfilament-jni.so`, `libfilament-utils-jni.so`,
`libgltfio-jni.so`, `libarcore_sdk_c.so`, `libVkLayer_khronos_validation.so`,
and even `libflutter.so`.

Verified independently with `readelf -lW` on the merged
`libfilament-jni.so` (arm64-v8a, from `arsceneview:2.2.1`): its `LOAD`
segments declare `p_align = 0x4000` (16 KB) but their file offsets are not
actually multiples of that (e.g. `0x220520`, which is not divisible by
`0x4000`) — the library's segments are genuinely misaligned, not just
under a stale OS warning.

This is consistent with, and a very plausible root cause of, both bug #1
and bug #2: on a 16 KB-page device, the dynamic linker has to fall back to
compatibility handling for these libraries, which is exactly the kind of
condition that produces the garbage-looking fault address seen in the
SIGSEGV tombstone (`0x0000043800000780`).

**Tried:** bumping `io.github.sceneview:arsceneview` from `2.2.1` to the
latest available release, `2.3.0` (also required raising `compileSdk` from
34 to 35, since `2.3.0` transitively depends on `androidx.core:core-ktx:1.16.0`).
Build succeeded and ran on-device, but the black-screen-after-resume bug
reproduced identically — `2.3.0` still bundles a Filament build with the
same non-16-KB-aligned native libraries. **Reverted** both changes
(`android/build.gradle`) since the bump added risk (a `compileSdk` change,
a newer transitive dependency graph) without fixing anything.

**Why not fixed here:** the misaligned `.so` files are prebuilt and shipped
inside the `arsceneview`/ARCore/Filament AARs; this plugin has no control
over how they were linked. A real fix needs one of:
- an upstream `arsceneview`/Filament/ARCore release built with
  16 KB-aligned native libraries (worth checking again periodically —
  this was an active, industry-wide migration at the time of testing), or
- re-linking the bundled `.so` files with `-Wl,-z,max-page-size=16384`
  during the plugin's own build (nontrivial: these are prebuilt binaries,
  not compiled from source in this repo), or
- moving off `arsceneview` for the rendering backend, which is a much
  larger change than "stabilize the lifecycle" and out of scope for now.

### Second root cause found: the platform view itself is recreated on resume, not just paused

Wired `ARSceneView.onSessionFailed` (previously unused; exposed by the
library but never connected) through to Dart's `onError`, so a native
session failure is no longer silent
(`android/src/main/kotlin/com/flutterreality/flutter_reality/ArView.kt`). Re-ran
the exact background/foreground repro to check it: no crash, but also no
`onError` fired — and the status text reset to the very first message
("AR session ready. Move the device to scan surfaces.", 0 planes), even
though the app process kept the same pid throughout.

That reset only happens from `example/lib/main.dart`'s `_onARViewCreated`,
which the plugin only calls once per platform view instance. Seeing it
fire again on resume, in the same process, means Flutter recreated the
`ArView` platform view itself when the app came back to the foreground —
this is a difference in kind from a simple ARCore session pause/resume
bug: the GL surface is black because it belongs to a brand new,
not-yet-composited platform view, not because an existing session failed
to resume. This is a known category of issue with Flutter's Android
hybrid composition (`PlatformViewsController` logged
`"Hosting view in a virtual display for platform view: 0"` /
`"PlatformView is using SurfaceProducer backend"` on the very first
launch), not something specific to ARCore/Filament — the 16 KB-alignment
issue above may still contribute to the SIGSEGV crash variant, but does
not fully explain this view-recreation behavior on its own.

The `onSessionFailed` wiring is kept regardless: it's a real gap (a
native session that fails to resume was silently swallowed before), and
it stays useful for whatever fraction of failures happen inside an
existing view.

### Correction: the view-recreation theory was a red herring; bug #1 is fixed

Added logging to `ArViewFactory.create`, `ArView`'s init block, and
`ArFlutterPlugin`'s activity-lifecycle callbacks
(`android/src/main/kotlin/com/flutterreality/flutter_reality/ArViewFactory.kt`,
`ArView.kt`, `ArFlutterPlugin.kt`) to check the view-recreation theory
above directly instead of inferring it from Dart-side state. Re-running
the repro with a *fast* background → foreground cycle (a couple of
seconds, avoiding the OS killing the backgrounded process — which is what
had actually happened in the earlier trial and explains the Dart state
reset) showed: same process pid throughout, **no** `dispose`/`create`
log lines at all, so the platform view is never destroyed or recreated —
yet the camera feed was still black. So the "platform view recreated"
theory was wrong; bug #1 is a single-view rendering problem after resume,
which matches the original, simpler hypothesis.

The actual cause: `ARSceneView` (from `arsceneview`) extends
`android.view.SurfaceView`. `lib/widgets/ar_view.dart`'s `AndroidARView`
carried a doc comment claiming it "Uses Hybrid Composition" but its
`build()` actually called the plain `AndroidView(...)` constructor, which
does not request Hybrid Composition — it uses Flutter's default
composition mode for platform views (Virtual Display or Texture Layer
Hybrid Composition depending on Flutter version; logs showed
`"PlatformView is using SurfaceProducer backend"`, i.e. TLHC). Flutter's
own platform-views documentation states that embedded `SurfaceView`s need
true Hybrid Composition to render reliably; TLHC/Virtual Display are
known to not always keep a `SurfaceView`'s content attached and
repainting after the app returns from background.

**Fix:** `lib/widgets/ar_view.dart`'s `AndroidARView.build()` now
requests Hybrid Composition explicitly via `PlatformViewLink` +
`PlatformViewsService.initSurfaceAndroidView`, matching Flutter's
documented pattern for `SurfaceView`-based platform views.

**Verified fixed** on the Pixel 9a: ran the background → foreground repro
three times after the fix — twice with an empty scene, once with 6
models placed (the load condition that previously triggered the SIGSEGV
crash) — camera feed rendered correctly and no crash occurred in all
three runs (confirmed visually; visual re-verification was needed for
this session because it exceeded its own screenshot budget partway
through this investigation).

## Not yet tested

- iOS / ARKit (no iPhone available in this session).
- Vertical plane detection specifically (only horizontal surfaces were
  used in this session).
- Gesture-based pan/rotate on placed nodes (not wired into the example
  app yet).

## Next steps (step 3 of the roadmap)

Done this session:
- Wired `ARSceneView.onSessionFailed` to Dart's `onError` so a native
  session that fails to resume is no longer silent.
- Root-caused and fixed bug #1 (black camera feed on resume): switched
  `AndroidARView` to true Hybrid Composition (`lib/widgets/ar_view.dart`),
  since `ARSceneView` is `SurfaceView`-based and Flutter's default
  platform-view composition mode doesn't reliably keep such views
  attached and rendering after the app returns from background. Verified
  fixed with 3 repro runs (2 empty scene, 1 with 6 models placed).
- Bug #2 (the SIGSEGV crash) did not reproduce in the loaded-scene repro
  run after the fix — plausible, since Filament touching a torn-down/
  invalid `Surface` on resume is consistent with both bugs sharing the
  same underlying trigger. Not yet confirmed over enough runs to call it
  fixed outright; keep an eye out for it in future testing.

Still open:
- Run more background/foreground cycles over a longer testing session
  (this session's repro runs were short, deliberate cycles) to build
  confidence bug #2 is actually resolved and not just less frequent.
- The 16 KB native-library page-misalignment issue (see above) is still
  present regardless of this fix — it didn't turn out to be bug #1's
  cause, but it's a real latent risk on 16 KB-page devices. Keep watching
  for an `arsceneview`/Filament release that ships aligned libraries.
- iOS/ARKit has its own lifecycle to verify (`IosARView.swift`) — nothing
  in this session touched or tested it; still fully open per "Not yet
  tested" below.

### `MissingPluginException` on `arobjects_$id`'s `init` call — FIXED, and the "startup race" theory below was wrong

Package/namespace rename (`ar_flutter_plugin_2` → `flutter_reality`,
`com.uhg0.ar_flutter_plugin_2` → `com.flutterreality.flutter_reality`)
required a full clean reinstall to validate, which surfaced a
`MissingPluginException` on `ARObjectManager.onInitialize()`'s `init`
call. First hypothesis was a startup race (native channel handler not
yet registered when the first message arrives) — reproduced 3/3 times, so
a bounded exponential-backoff retry (`lib/utils/channel_retry.dart`) was
written and wired into `onInitialize()`/`dispose()` in both
`ARObjectManager` and `ARSessionManager`.

**That diagnosis was wrong.** With retries in place, the exception still
occurred after exhausting ~1.5s of backoff — a race would have resolved
in milliseconds, not persisted past 1.5 real seconds. Checking the native
handler directly (`onObjectMethodCall` in `ArView.kt`) showed the real
cause: **there was no `"init"` case at all** — every call fell through to
`else -> result.notImplemented()`, which Flutter surfaces to Dart as
`MissingPluginException` regardless of timing. This was a pre-existing
gap (unrelated to the rename or the earlier Hybrid Composition change),
just never noticed because the call is fire-and-forget in the example app
and nothing else depends on it succeeding — `addNode` and other object
methods are implemented and always worked.

**Fix:** added `"init" -> result.success(null)` to `onObjectMethodCall`
(`ArView.kt`), matching what iOS already does for the same channel/method
(`IosARView.swift`'s `onObjectMethodCalled`). While in that file, also
fixed two more misses caught during the correction:
- Android's `onSessionMethodCall`'s `"dispose"` case called `dispose()`
  but never called `result.success(...)`, so `ARSessionManager.dispose()`
  would hang forever if awaited (nothing awaits it today, so this was
  silent — now fixed regardless).
- iOS's `onObjectMethodCalled` and `onAnchorMethodCalled` `"init"` cases
  had leftover debug code firing a fake `onError("ObjectTEST from iOS")`
  on every init (the anchor one even sent it on the *wrong* channel,
  `objectManagerChannel` instead of `anchorManagerChannel` — a copy-paste
  artifact). Removed; not verified on a real device since no iPhone was
  available this session, but the change is a pure deletion.

Reverted the retry/backoff mechanism and its tests
(`lib/utils/channel_retry.dart`) once the real cause was fixed — it was
solving a problem that didn't exist, and keeping speculative defensive
code around after the actual bug is understood and fixed would just be
unjustified complexity.

**Verified on the Pixel 9a**: full clean reinstall, zero
`MissingPluginException` anywhere in the log, tap-to-place and
remove-last-model work immediately (not just "moments later"), and a
background/foreground cycle afterward still renders the camera correctly
with the same process pid throughout.
