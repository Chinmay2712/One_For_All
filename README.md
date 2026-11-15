# One For All Studio

Photo and video editing in one Flutter app for Android and iOS.

## Photo editor (`lib/photo/`)
- Light, colour, effects, detail sliders (GPU shader in `shaders/develop.frag`)
- Tone curve (RGB + per channel), colour mixer (8 bands), colour grading
- Crop with ratios, straighten, rotate, flip
- Masks: linear, radial, brush, AI "select person"
- Healing / clone spots
- Presets (built-in groups + your own, share/import as `.preset.json`)
- Copy/paste settings, batch edit, collage, AI background removal
- Export JPEG/PNG at full size or smaller

## Video editor (`lib/video/`)
- Main track + overlay (picture-in-picture), text, and audio tracks
- Trim, split, duplicate, reorder, speed (0.125x–8x), reverse, freeze frame
- Volume, fades, mute, extract audio
- Filters, colour adjustments, blur, opacity, transform, keyframes
- In/out animations, 10 transitions, captions (typed or `.srt`)
- Canvas ratios and background colour, templates
- Export MP4 480p–4K at 24–60 fps through FFmpeg

## Run
```bash
flutter run            # on a connected phone or emulator
flutter test           # export command tests
```
FFmpeg, ML Kit and gallery saving only work on Android/iOS. In the web
preview, editing works but video export and AI tools are disabled.

## iPhone build (GitHub Actions)
Every push to `main` builds the iOS app on a GitHub-hosted Mac
(`.github/workflows/ios.yml`); it can also be started by hand from the
Actions tab ("Run workflow").
1. Open the finished run under **Actions** and download the
   `OneForAllStudio-ios` artifact (a zip containing `OneForAllStudio.ipa`).
2. On Windows, install [Sideloadly](https://sideloadly.io) and iTunes
   (Apple's website version), plug in the iPhone and tap "Trust".
3. Drag the `.ipa` into Sideloadly, enter your Apple ID, and click Start.
4. On the iPhone: Settings → General → VPN & Device Management → trust your
   Apple ID. On iOS 16+ also turn on Settings → Privacy & Security →
   Developer Mode.

With a free Apple ID the app stops opening after 7 days; reinstall it with
Sideloadly to refresh it.

## Notes
- Minimum Android 7.0 (API 24), minimum iOS 15.5.
- `ffmpeg_kit_flutter_new` is the GPL build; publishing the app with it means
  releasing under GPL 3.0. Swap to `ffmpeg_kit_flutter_new_full` (LGPL, no
  x264) if that matters — export already falls back to the hardware encoder.
- iOS builds need a Mac with Xcode (or a cloud build service).
