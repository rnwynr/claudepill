# Snappabl

A menu bar app for macOS 26 (Tahoe) that takes screenshots and screen recordings. The UI uses Liquid Glass throughout, and the app uses almost no CPU while idle.

| Shortcut | Action |
| --- | --- |
| **⌥⇧1** | Screenshot → **clipboard** |
| **⌥⇧2** | Screenshot → **folder** (`~/Pictures/Snappabl` by default) |
| **⌥⇧3** | Start / stop **screen recording** |

You can change all three in Settings: click the shortcut, then press the new combo. Esc cancels and ⌫ clears it.

After you press a shortcut, drag to select an area or click to capture the whole screen under the cursor. Esc or a right-click cancels.

| While selecting | Does |
| --- | --- |
| **⇧ Shift** | Locks the selection to a square |
| **⌥ Option** | Grows the selection from its center |
| **⌘ Command** | Window mode: hover highlights a window, click captures just that window with transparent rounded corners. Works for recordings too, and the recording follows the window. |
| **Space** (while dragging) | Moves the selection instead of resizing it |

The modifiers in your shortcut (⌥⇧ by default) are ignored until you let go of them, so the selection doesn't start squared and centered.

While a recording runs, a glass pill shows a timer and a stop button. If you're recording an area, a dashed red outline marks it. Neither shows up in the video.

## Build

You need macOS 26 and Xcode 26 (Swift 6.2).

```bash
scripts/build-app.sh --install --run
```

The script builds a release binary, bundles it into `dist/Snappabl.app`, signs it and copies it to `/Applications`. You can also run `open Package.swift` to work on the code in Xcode. Always run the app through the script so it picks up `Info.plist` (menu-bar-only, microphone usage string).

### Permissions

- **Screen Recording.** macOS asks on first launch. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch the app.
- **Microphone.** macOS asks only when you turn on "Microphone" for recordings.
- **Stable signing (important).** macOS ties the Screen Recording permission to the app's signature. An ad-hoc signature changes on every build, so the toggle in System Settings stays on but stops matching the new build, and the prompt keeps coming back. `build-app.sh` picks a stable identity on its own. Set one up once, either way:
  - Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+ Apple Development** (free), or
  - `scripts/make-signing-cert.sh`, which creates a local self-signed "Snappabl Local Signing" certificate.

  Then clear the stale entry once with `tccutil reset ScreenCapture app.snappabl.Snappabl`, rebuild, and allow access one more time. It sticks after that.

## Capture quality

- **Full native resolution.** Captures run at the display's backing scale (2× on Retina) with `captureResolution = .best`.
- **Lossless PNG**, tagged **Display P3** like macOS's own screenshots, so wide-gamut colors aren't clipped to sRGB.
- **Window mode** renders the window on its own. Anything overlapping it is left out, and the corners come out transparent.
- **Recordings** use the Media Engine's HEVC (or H.264) encoder at native resolution and up to 60 fps. `SCRecordingOutput` doesn't let you set the bitrate.

## Why it's light on CPU

- **Hotkeys** go through Carbon `RegisterEventHotKey`. The window server wakes the app only when one of its combos is pressed. Nothing polls the keyboard, there's no global key monitor, and it needs no Accessibility permission.
- **Nothing runs between captures.** The app sets no timers and runs no animation loops. It keeps no capture stream alive. The selection overlay is created when you press a shortcut and destroyed right after.
- **Screenshots** use a one-shot `SCScreenshotManager` call. The only heavy step is PNG encoding, which runs off the main thread.
- **Recordings** use `SCStream` + `SCRecordingOutput`. ScreenCaptureKit feeds frames straight to the hardware HEVC/H.264 encoder and writes the file itself, so the app never processes, copies or converts a pixel. Frames come in YUV 4:2:0, the encoder's native format, so there's no conversion step. ScreenCaptureKit also only sends a new frame when the screen changes.
- The **recording timer** uses `Text(.timer)`, which ticks once a second on its own.

## Layout

```
Sources/Snappabl/
  App/       SnappablApp (scenes), AppController (flow), Preferences
  Capture/   Screenshotter, RecordingService, models + file naming
  Hotkeys/   Carbon hotkey manager, Shortcut model
  UI/        Menu bar panel, Settings, selection overlay, HUD + recording pill, panels
Resources/   Info.plist, entitlements
scripts/     build-app.sh
```
