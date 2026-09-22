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
- Vertical plane detection: pointing the device at a wall detects a
  vertical plane (confirmed visually on-device), and tapping it places a
  model correctly oriented against the wall rather than lying flat as it
  would on a horizontal surface.
- Pan and rotation gestures on placed nodes, after a real fix (see
  "Rotation gesture did nothing visually" below) — dragging a node
  (touch and hold on it, then move the device so the raycast tracks a
  new surface point, not a finger swipe while the device stays still —
  see that section for why) relocates it via `AnchorNode`'s own
  move-and-recreate-anchor mechanism; the two-finger twist gesture
  visibly rotates it now. Both fire `onPanEnd`/`onRotationEnd`, wired to
  the status card in the example app (`example/lib/main.dart`).

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
- Two native memory leaks in repeated node/anchor placement and removal
  found and fixed this session (see "Memory leak in repeated anchor
  add/remove" below) — verified with a controlled before/after
  comparison that Filament/GPU memory (`EGL mtrack`/`GL mtrack`) is flat
  across repeated cycles. `Native Heap` still grows modestly per cycle,
  plausibly from ARCore's own session data rather than this plugin's
  code, but that wasn't independently confirmed — worth revisiting if
  it turns into a real complaint.

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

### Rotation gesture did nothing visually — FIXED, with a regression along the way

After enabling `handleRotation` (see "What works" above), the status card
did read "Rotated model." after a two-finger twist, which was initially
taken as confirmation the gesture worked and the rotation was just hard
to see on a near-symmetric duck model. On a closer test asking
specifically "does the model visibly rotate", the answer was no — not
even with a real twist gesture, not just a slide. The status card firing
was real (the native `onRotateEnd` callback did run) but the model's
actual orientation never changed.

**Root cause**, found by decompiling the exact `arsceneview:2.2.1` AAR
classes with [CFR](https://github.com/leibnitz27/cfr) (the library's
GitHub source uses a newer, differently-organized API than 2.2.1, so
reading `main` branch source directly would have been misleading):
`io.github.sceneview.node.Node` gates `isRotationEditable`/
`isPositionEditable`/`isScaleEditable` behind a separate `isEditable`
master flag — the actual getters are `isEditable() && field`. This
plugin's `ArView.kt` was setting `isRotationEditable = handleRotation`
but never setting `isEditable`, so the getter always evaluated to
`false` regardless, and the base `Node.onRotate(detector, e)`
implementation's very first check (`if (this.isRotationEditable())`)
always failed — silently falling through to delegate to the parent node,
which does nothing with rotation. This matches a known upstream report
([SceneView/sceneview-android#100](https://github.com/SceneView/sceneview-android/issues/100),
closed stale in 2022 without a confirmed fix landing) describing rotation
"confused with" scale gesture handling.

**Fix:** set `isEditable = handleRotation` alongside
`isRotationEditable = handleRotation` in the node's `.apply {}` block
(`ArView.kt`).

**Regression introduced by that fix, then corrected:** `isEditable = true`
also unmasks `isScaleEditable`'s getter, which defaults to `true` in the
base class and isn't exposed as a Dart-configurable option in this
plugin at all — pinch-to-zoom started working but scaled the model
exponentially with no bound, an uncontrolled capability this plugin
never tested or intended to expose. Fixed by explicitly setting
`isScaleEditable = false`.

That second fix caused a *third* regression: dragging a placed model
(pan) stopped working entirely. Root cause, again found by decompiling
(this time `AnchorNode`, the parent of the placed model, from the
`arsceneview` AAR): `AnchorNode` overrides `isPositionEditable` with its
own independent field, hardcoded to `true` in its constructor — it is
never gated by `isEditable` at all. Panning was always working via
delegation: the base `Node.onMove(detector, e)` checks the *child*
node's `isPositionEditable()`, and since that was `false` before any of
this session's changes (same `isEditable` gating as rotation), it always
delegated to the parent `AnchorNode`, whose overridden `onMoveBegin`/
`onMoveEnd` detach and recreate the anchor at the new position — moving
the model by moving its anchor, not by editing the model node's own
local transform. Setting `isEditable = true` on the child (done for the
rotation fix) unmasked the child's own `isPositionEditable` getter,
which — because nothing had ever explicitly set that field to `true` —
still evaluated to `false`... except the code as written at that point
also explicitly set `isPositionEditable = handlePans` (`true`), which
switched pan from the reliable anchor-delegation path to the base
class's local-node path. That path requires the touch's raycast hit
result's node to equal `this.getParent()` by reference, a condition that
doesn't hold for this plugin's node hierarchy in practice, so every pan
attempt silently failed at that check.

**Final fix:** stopped setting `isPositionEditable` at all on the model
node, leaving it at its default (`false`), which keeps pan on the
anchor-delegation path that was already working. Only `isEditable`
(needed for rotation) and `isRotationEditable`/`isScaleEditable` are set
explicitly now.

**Verified on the Pixel 9a**, after each of the three fixes above, in
this final state: two-finger twist visibly rotates the model; dragging
(touch and hold the model, then move the device so the tracked surface
point under it changes — not a finger swipe with the device held still,
which is how this plugin's pan has always worked, via the anchor being
recreated at the new hit location) visibly relocates it; pinch does
nothing (deliberately, since scale isn't a supported/tested capability
of this plugin).

### Two native memory leaks in repeated node/anchor add/remove — FIXED and verified

A temporary stress-test button was added to the example app (touch a
plane once to capture a hit transform, then loop 20x: add a plane anchor
+ a `duck.glb` node on it, remove the node, remove the anchor — not
committed, removed after use) to check node/anchor destruction under
load, per the roadmap's "verify correct destruction of nodes and
anchors" item. No crashes or `addAnchor`/`addNode` failures across
several hundred iterations, but `adb shell dumpsys meminfo`'s `TOTAL PSS`
grew steadily and did not plateau: roughly +90-230 MB per ~80-100
create/destroy cycles, with `TOTAL SWAP PSS` also climbing (up to
~104 MB at one point) — consistent with a genuine native leak, not
just pending-GC noise (which would plateau).

**Root cause found for one contributor:** `handleRemoveAnchor` in
`ArView.kt` never called `.destroy()` on the removed `AnchorNode`, and
never removed its entry from `anchorNodesMap`. Confirmed via CFR
decompilation of the actual `arsceneview:2.2.1` classes (not the
newer, differently-structured GitHub `main` branch, which would have
been misleading) that `Node.destroy()` calls
`EngineKt.safeDestroyTransformable`/`safeDestroyEntity`, i.e. it
releases the Filament engine entity — without it, every created anchor's
native entity stays allocated forever, and the never-cleared map keeps a
strong Kotlin-side reference on top of that. Fixed by calling
`anchor.destroy()` and `anchorNodesMap.remove(anchorName)` in
`handleRemoveAnchor`.

**Second leak found and fixed**: re-running the same stress test after
the anchor fix showed `TOTAL PSS` still growing at roughly the same
rate. Suspected source: each `addNode` call does
`sceneView.modelLoader.loadModelInstance(fileLocation)` to load
`duck.glb`, and `ModelLoader` exposes a `destroyModel(FilamentAsset)`
method that `handleRemoveNode` never called (it only called
`node.destroy()`, which — per the same decompiled `Node.destroy()` —
releases the root entity's transform, not the underlying
`FilamentAsset`'s mesh/texture buffers).

Before fixing it, confirmed the safety concern that blocked doing this
blind: in Filament's gltfio, a `FilamentAsset` *can* be shared across
multiple `FilamentInstance`s, so destroying it under a still-visible
node sharing it would corrupt rendering — worse than the leak. Decompiled
`ModelLoader.createModel(String, ...)` (the method `loadModelInstance`
calls internally) with CFR: it re-reads the file and calls
`assetLoader.createAsset(buffer)` on **every single call**, appending to
an internal list with no lookup-before-create — there is no cache, no
sharing by path. Each `addNode` call gets its own independent
`FilamentAsset`. Safe to destroy on removal.

**Fix**: added `sceneView.modelLoader.destroyModel(node.model)` right
after `node.destroy()` in `handleRemoveNode`.

**Verified with a controlled, single-round-at-a-time comparison** (the
earlier multi-round stress runs were too noisy to attribute growth
cleanly — real background activity on a shared device adds variance):
placed one model, took a full `dumpsys meminfo` breakdown, ran exactly
one 20-iteration stress round, re-measured, ran a second round,
re-measured again.

| | Baseline | After round 1 (+20) | After round 2 (+20) |
|---|---|---|---|
| EGL mtrack (KB) | 282832 | 279792 | 282832 |
| GL mtrack (KB) | 155312 | 151808 | 153568 |
| Native Heap (KB) | 243167 | 255255 | 272507 |
| TOTAL PSS (KB) | 937233 | 941693 | 962143 |

`EGL mtrack`/`GL mtrack` — the Filament/GPU-side memory that would
directly reflect a leaked `FilamentAsset` or Filament entity — are flat
within noise across both rounds (round 2 ends essentially at the
baseline). This is strong evidence both leaks are actually fixed.
`Native Heap` grows a modest ~12-17 MB per 20-cycle round; the most
likely explanation is ARCore's own plane/feature-point tracking data
accumulating as the camera keeps scanning during the test (expected
session behavior, not code we control), rather than a leak in this
plugin, but this wasn't independently isolated and confirmed — worth
another look if memory growth becomes a real-world complaint.

### Pigeon migration — Android smoke test (Pixel 9a)

After rewriting every platform channel to use generated Pigeon `HostApi`/`FlutterApi`
code (see CHANGELOG for the full rationale and bug fixes this surfaced), ran a clean
`flutter build apk --debug` + `flutter run -d 63281JEBF11630 --debug` on the Pixel 9a
and monitored `adb logcat` throughout:

- Build and install succeeded with no Kotlin compile errors (after fixing a real
  issue: `ARSessionHostApi.dispose()` and `PlatformView.dispose()` share a name but
  are unrelated contracts — Kotlin rejects a class inheriting two conflicting
  `dispose()` members from different supertypes, so `ARSessionHostApi` is now
  implemented by a small private inner class instead of directly on `ArView`).
- App launched cleanly: ARCore session created, no crashes or exceptions in logcat
  during startup.
- Confirmed the `ARSessionHostApi.initialize(config)` round-trip actually works
  end-to-end on-device: the ARCore session's `plane_finding_mode` visibly changed
  from `DISABLED` to `HORIZONTAL_AND_VERTICAL` in the native ARCore debug log,
  matching the `PlaneDetectionConfig.horizontalAndVertical` the example app passes
  from Dart — this is real evidence the new typed Dart → native call path works, not
  just that it compiles.
- Ran for ~40s with no exceptions, `FlutterError`s, or `MissingPluginException`s in
  the log.
- Could not complete a full interactive pass (tap-to-place, pan, rotate, node
  removal, anchor upload/download) in this session: the device's screen went into a
  locked/dozing state mid-session and `adb`-driven unlock attempts got stuck on the
  notification shade, and place/pan/rotate testing fundamentally needs a human
  moving the physical device for ARCore to track a real plane, which automated
  `adb input tap` cannot substitute for. This remains open for a follow-up manual
  session — the smoke test above is solid evidence the plumbing works, but it is not
  a substitute for exercising every callback path from real gestures.

iOS was not touched physically at all this session (no iPhone available, consistent
with the whole session's plan) — the only verification for the Swift rewrite is the
`ios-build` CI job's `flutter build ios --no-codesign --debug`, which compiles but
does not run the code. Two things worth flagging for whoever does the first real
iOS test pass: `ARSessionHostApi.disableCamera`/`enableCamera` are new on iOS this
migration (previously unimplemented, now backed by `ARSession.pause()/run()`) and
have never been exercised at all; and `addPlaneAnchor`'s existing busy-wait loop
(`while sceneView.node(for: arAnchor) == nil { usleep(1) }`) blocks the calling
thread until SceneKit's own render-loop delegate callback attaches the anchor's
node — this is pre-existing behavior, not something this migration touched, but on
the main actor under Pigeon's structured concurrency it's worth a first look in
case it behaves differently than the old completion-handler-based dispatch.
