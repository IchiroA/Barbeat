# Barbeat

https://ichiroa.github.io/Barbeat/

A macOS menu bar app that turns the strip behind the menu bar into a live light show
driven by whatever your Mac is playing.

- **Screen colors**: the menu bar, the glow around the screen and your lights take their colors from what you're
  watching, like a TV's backlight. Stage beams and lasers spill out of the screen, into your room too.
- **Ten styles**, a screen edge glow, palettes or your own colors, and narrower bars on ultrawide screens.
- **Scenes**: whole looks in one click, switching on their own when an app plays or you're on a call.
- **Voice**: colors and a glow that follow the singer.
- **Lights**: Philips Hue and WLED / Art-Net lights in the same colors, with mirror, sparkles and a sleep timer.
- **`barbeat://` links** for Shortcuts, Stream Deck and Raycast, and updates that install themselves (with your OK).

Made by **Ichiro Ashihara** (@IchiroA). © 2026 Ichiro Ashihara.

The code is open source under the [MIT License](LICENSE). The name "Barbeat" and the app icon aren't covered by
the license: if you publish your own version, please give it its own name and icon.

## Download

Get the latest version from the [Releases](../../releases) page: download `Barbeat-<version>.zip`, unzip it and drag
**Barbeat** into Applications. It's signed and notarized by Apple, so it opens without warnings.
Needs a Mac with Apple Silicon (M1 or newer) and macOS 14.2 or later.

**Guide:** [ichiroa.github.io/Barbeat](https://ichiroa.github.io/Barbeat/) has a quick start, every setting, Scenes, Voice,
Lights setup, `barbeat://` links, help and the [privacy policy](https://ichiroa.github.io/Barbeat/privacy.html). It's built from the `docs` folder.

## What it does

- Listens to system audio with Core Audio process taps (macOS 14.2+). No extra audio driver is needed, and sound plays normally.
- **Listen to**: everything the Mac plays, **one app** only (e.g. Spotify, so calls and alerts don't move the bars;
  helper processes such as Chrome's and Safari's WebKit audio process count as the app), or any **input device**
  (built-in mic, audio interface, loopback devices like BlackHole). An unplugged input falls back to system audio
  until it's back. Bluetooth mics get a warning: using one puts the headset in low-quality call mode.
- Draws in a click-through window one level below the menu bar, so menus and icons stay on top. Runs at 60 fps,
  or 30 fps on battery to save power, and stops redrawing while it's silent.
- Styles: **LED**, **Bars**, **Center**, **Glow** (soft color wash per frequency), **Pulse** (the whole menu bar
  color pulses with the beat), **VU** (a stereo meter that shoots out of the notch), **Aura** (light hugging the
  notch that flares with the bass), **Waterfall** (the music's recent history flowing outward), **Scope** (a live
  waveform) and **Sparks** (particles bursting out of the notch on every beat).
- **Screen edge glow**: an optional ambient glow along the left, right and bottom screen edges, and (**Top edge
  too**, on by default) along the top just below the menu bar, combinable with any style. **Depth** sets how far it reaches into the screen (16–480 pt, at most a third of the screen). **Wallpaper** colors pick a palette from your desktop picture.
- **Custom** colors: four color blocks with an in-panel picker (hue / saturation / brightness, quick picks, hex),
  colored by frequency or by bar height, Shuffle, From Wallpaper, and four preset slots. **Customize** copies any
  built-in palette into Custom. **Color drift** slowly turns any palette around the color wheel.
- **Screen** colors follow what's on screen, via ScreenCaptureKit (needs Screen Recording permission; macOS shows
  its recording indicator meanwhile). **Main colors** turns the strongest colors on screen into the palette;
  **Ambient light** colors each part of the strip and edge glow like the screen next to it, like TV backlighting.
  It reads at most 6 tiny frames (192 px wide) a second, about 0.25 ms of work each, with Barbeat's own windows
  left out. Listening to one app watches that app's biggest window instead of the whole screen. Copy-protected
  video shows up black, so the last colors stay.
  **Follow light beams** (on by default, with a Strength slider) picks out light that stands well above the
  picture's own level and has just appeared or moved, like stage beams sweeping across a concert or a strobe. In
  Ambient light the beam's own color takes over the strip and edge glow next to it and lights them up even when the
  music is quiet, fading over half a second so sweeps leave a trail; in Main colors it tints the brightest colors.
  Each part of the screen gets used to steady bright things (a white window, title text) within a few seconds, so
  only changes count. Frames go up to 15 a second (10 on battery) while it's on, about 0.3 ms of work each.
- **Panel and Settings window** (v1.11): the menu bar panel holds quick controls only (on/off, Screen colors card
  with the live colors it sees, style, palette when Screen colors is off, brightness, Lights and Voice rows).
  **Settings…** (⌘, while the panel is open) opens a window with a sidebar: Screen colors (first, with the stage
  picture and before/after beam pictures from `Resources/Images`, copied into the app by `build.sh`), Look, Sound,
  Glow and screens, Lights, Voice and General. The old Lights and Voice windows are pages there now.
- **Screen colors is its own switch** (`screenColors`), no longer a palette: off goes back to `palette`. Upgrading
  keeps it on for anyone who had the Screen palette (or never changed the old default); their Custom colors (or Neon)
  become the palette for when it's off. New users start with it off: a **welcome window** (once, `welcome.shown`;
  General › Show the Welcome Window) offers it, and turning it on the first time explains what Barbeat reads before
  macOS asks for Screen Recording.
- **Scenes** (v1.11, `Scenes.swift`): a scene is a `SceneLook` (visuals, palette, Screen colors and beams,
  brightness, opacity, edge glow, lights, voice; nil fields are left alone) plus triggers: while one of these apps
  plays (Core Audio process output, helpers counted as their app) or while you're on a call (any real input device
  running somewhere, from `kAudioDevicePropertyDeviceIsRunningSomewhere`; Barbeat's own tap, aggregate and virtual
  devices don't count). Checked every 2 s; switches after 3 s, goes back 8 s after the trigger ends, restoring a
  snapshot of the look from before. Picking a scene by hand wins until the trigger ends. Starters: On a call,
  Concert, Chill, Focus. Saved as `scenes` (JSON). The panel's Scene row says why it switched.
- **Light beams to the lights**: with Screen colors and Follow light beams on, `screenBeamsToLights` (default on)
  lets beam strength along the top and bottom edges light the Hue/Art-Net light at the same left-right spot, in the
  beam's color, before the 3-flashes-a-second cap.
- **Sleep timer** (Lights page, or the moon in the panel's Lights row): 15–90 min; the lights fade out over the last
  minute and the give-back ends with them off (Hue: the saved state with every light off and no scene recall; WLED:
  black plus its JSON API `on: false`). With a timer running, music stopping is bedtime too.
- **Menu bar icon** (`MenuBarIcon.swift`): four template-image bars following bass to treble at ~12 fps while music
  plays; still with Reduce motion or when switched off under General.
- **`barbeat://` links** (`LinkCommands.swift`, `CFBundleURLTypes` in Info.plist): `on`, `off`, `toggle`,
  `scene/<name>`, `style/<name>`, `screen-colors|lights|voice/on|off|toggle`, `sleep/<minutes>|off`,
  `settings/<page>`.
- **Voice** (switch and Options… in the panel): reacts to singing, speech or both. Per frame it measures the sound
  panned to the middle in the voice range, mostly how strongly one pitch stands out (a sung syllable), and Apple's
  sound recognizer (SoundAnalysis, 1 s windows every 0.5 s) gates it, so instrumentals stay quiet. About 0.12 ms per
  frame including the recognizer (~0.7% of a core, measured offline with `scripts/tune-voice`). Effects: **Voice
  color** or **Pitch color** (low notes blue → high notes orange) spreads out from the middle of the screen, further
  with louder singing (Strength sets how far); **Voice glow** swells out of the notch with each word; **Show on**
  menu bar / edge glow / lights. Each light device also has Voice: **Follow the singer** or **Sparkles on words**.
  Settings live in `voice.*`.
- **Updates**: about once a day (and from "Check for Updates…" in the panel footer) Barbeat reads
  `api.github.com/repos/IchiroA/Barbeat/releases/latest`, compares the tag (`v1.11` → 1.11) with its own version,
  and offers it. Update downloads the release's `Barbeat*.zip`, unzips it next to the app, and installs it only if it
  is signed by the same Developer ID team as the running copy (read from its own signature), has the bundle ID
  `com.ia.MenuBarEQ` and is notarized and has the offered version; then it quits (handing the lights back) and reopens. So a release must
  be tagged `vX.Y` with the notarized zip attached. A Mac App Store build must leave this out.
- **Ultrawide screens**: the analyzer has at most 128 bands, so on a screen wider than 16:9 (a 32:9 Samsung G9, say)
  the Bars, Center and LED styles keep the bar width they'd have on a 16:9 screen of the same height and draw extra
  bars in between, following a smooth curve through the neighbouring bands (never above or below them). It's done
  per pixel on the GPU, so it costs no memory and next to no time.
- **Show over full-screen apps** keeps the edge glow on in full screen, on all four sides (the top glow starts right
  at the top of the picture, below the black band around the notch on notched Macs). **Menu bar visuals too** (off
  by default) also draws the strip where the hidden menu bar would be. Over a full-screen app the hidden menu bar is
  still there (black beside the notch) and would cover the strip, so the strip sits just above it, and drops back
  below it while the pointer is at the top or a menu is open, so menus stay usable.
- **Keep menu bar text readable** (on by default) tones down strip colors bright enough to wash out the menu bar's
  own text and icons: under white menu bar text, white, yellow and cyan are eased down while reds, blues and purples
  stay as they are (under dark text, the darkest colors are lifted instead). The edge glow keeps its full colors.
  macOS draws the menu bar itself, so apps can't outline its text; this is the next best thing.
- First launch (v1.10): 128 stereo Center bars in Screen › Ambient light colors with Follow light beams, 74% opacity,
  sensitivity −5 dB, 136% brightness, Low −4 / Mid −2 / High 0 dB, no peak caps, screen edge glow 241 pt deep on all
  sides, shown over full-screen apps (glow only), menu bar text kept readable.
- **Lights** (v1.7): Philips Hue and Art-Net (WLED strips, DMX fixtures) lights move with the music in the same
  colors as the menu bar. They have their own switch, so Barbeat also works as a lights-only controller. Set up under
  **Lights › Set Up…** in the panel (the Lights window has a live preview that works without hardware).
  - Modes: **Auto** (default) picks per device: **Pulse** for 1 light (the Pulse style as a bulb), **Stereo** for 2,
    **Bands** for 3–9 (a room-sized EQ, bass left → treble right, with a room-wide punch on kicks), **Mirror** for
    strips and Gradient segments (each light copies the menu bar at its spot). Colors follow the palette's rule:
    by frequency (Neon, Spectrum…) or by loudness (Classic, Fire…); Screen › Ambient light colors each light like
    the screen next to it.
  - Each device (Hue Bridge or Art-Net device) has its own on/off switch in the Lights window: off hands its lights back
    (Hue restored) and leaves them alone while the others keep playing; it stays set up. Saved as `lights.switchedOff`
    (output IDs), apart from the device lists, so older saved devices still load.
  - Each device also has **Mirror** (the two halves match: Bands and Mirror fold around the middle, with bass in the
    middle or at both ends, and sparkles come in pairs) and **White sparkles on the beat** (each beat flashes a few
    random lights white, more on harder beats, up to **Max sparkles** at once, fading over **Fade**, 0.1–2 s). Sparkles
    count toward the 3-flashes-a-second limit: a light that's had its 3 is skipped. Saved per output ID as
    `lights.effects`.
  - Base glow, Beat flash, Brightness, Delay (0–2000 ms, for AirPlay/Bluetooth speakers) and "Give back after"
    silence (10 s / 30 s / 2 min / Never). Never more than 3 big flashes a second per light; Reduce motion halves flashes.
  - **Hue**: Bonjour discovery (or Philips' discovery service, or an IP), pairing by the bridge button, keys in the
    Keychain, certificate pinned on first use. Streams to a Hue **Entertainment area** (made in the Hue app) over
    DTLS 1.2 PSK (UDP 2100, HueStream v2, XY + brightness), using the area's light positions for left/right.
  - **Giving the lights back** (silence, Lights off, quit, sleep, removing a device): Hue lights are saved first
    (on/off, brightness, color or color temperature, gradient, active scenes) and restored after the bridge's own
    post-stream update, then checked and re-applied. The snapshot is kept on disk until restored, so after a crash
    the next launch puts the lights back. Art-Net devices hand back (WLED returns to its own effect), fade out or hold.
  - **Art-Net**: ArtDmx unicast from an ephemeral port, RGB/GRB/RGBW/Dimmer profiles, strips continue onto the next
    universe (170 RGB pixels each), gamma correction, ArtPoll "Find Nodes" and "Detect WLED".
  - macOS asks for **Local Network** permission the first time.
- **Stereo L | R** layout: left channel to the left of the notch, right channel to the right, bass hugging the
  notch. Uses the real notch position on notched Macs and splits at the center elsewhere.
- Settings live under the bar-chart icon in the menu bar: style, layout, colors, band count, opacity,
  sensitivity, auto level, peak hold, readable menu bar text, all displays, full screen, launch at login.

## Build and run

```bash
./scripts/build.sh
open "build/Barbeat.app"
```

The first time it runs, macOS asks for permission to record system audio. Click Allow. If the bars stay
still afterwards, open the menu bar panel and click **Try Again**. You can change the permission later in
System Settings › Privacy & Security › Screen & System Audio Recording.

Each rebuild is signed ad-hoc, so macOS may ask for the permission again after a rebuild.

## Sharing it

```bash
./scripts/release.sh
```

This makes `build/Barbeat-<version>.zip` containing the app and a "How to install" note. With a
Developer ID Application certificate and saved notarization credentials (one-time setup, described at the top
of `scripts/release.sh`), the app is signed, notarized by Apple and opens on any Apple Silicon Mac without
warnings. Without them, the zip is ad-hoc signed and friends approve it once under
System Settings › Privacy & Security › Open Anyway.

`./scripts/sandbox-test.sh` builds "Barbeat Sandbox Test.app": the same app running in the App Sandbox (required for
the Mac App Store) under its own bundle ID. Tested 2026-10-26: system audio capture, GPU drawing, edge glow and
wallpaper colors all work sandboxed.

The icon is drawn by `scripts/make-icon.swift` (`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`).

## Developer options

| Flag | What it does |
| --- | --- |
| `--demo` | Animates a built-in test signal instead of system audio |
| `--verbose` | Prints audio status every 1.5 s |
| `--snapshot out.png` | Saves what the overlay is drawing after ~3 s, then quits |
| `--snapshot-clear` | With `--snapshot`, leaves the background transparent |
| `--snapshot-scale 2` | Draws at that pixel density whatever the screen's (sharp snapshots from a 1× screen) |
| `--panel-snapshot out.png` | Renders the settings panel offscreen and saves it (add `--dark` for dark mode), then quits |
| `--source system\|app:<bundle id>\|device:<uid>` | Listens to that instead of the saved choice; `--verbose` lists input UIDs and what's playing |
| `--lights-log` | Prints each device's light colors 4×/s, plus take-over / give-back steps |
| `--lights-virtual N` | N virtual lights (no network), on for this run, e.g. with `--demo` |
| `--lights-snapshot out.png` | Renders the Lights window offscreen and saves it, then quits |
| `--hue-pair <address>` | Pairs with a Hue Bridge at launch (press its button), printing progress |
| `--hue-keys-file keys.json` | Keeps Hue keys in that file instead of the Keychain (testing) |
| `--demo-seconds N` | The demo music stops after N seconds (to test silence and give-back) |
| `--quit-after N` | Quits normally after N seconds (to test putting the lights back on quit) |
| `--screen-image picture.png` | Screen colors read that picture instead of the screen (no permission needed); `--verbose` prints the colors and the time per frame |
| `--pretend-full-screen <gap>` | Lays out the windows as if an app were in full screen, with a band of `gap` points above it (49 on a notched screen, 0 without); `--verbose` prints each screen's layout |
| `--voice-demo` | A made-up singer (phrases, words, a wandering melody) drives the Voice effects, without music |
| `--voice-snapshot out.png` | Renders the Voice window offscreen and saves it, then quits |
| `--update-test` | Checks for an update now, downloads and verifies it, prints what happened and quits (never installs or shows a dialog) |
| `--update-feed URL` | Reads that JSON instead of GitHub's latest release (to test the updater) |
| `--settings-snapshot out.png [page]` | Renders the Settings window offscreen at that page (screen, look, sound, glow, lights, voice, general), then quits |
| `--welcome-snapshot out.png` | Renders the welcome window offscreen, then quits |
| `--open-url barbeat://…` | Runs a `barbeat://` link at launch, as if it were opened |
| `--pretend-trigger call:3:12` | Acts as if a call (or `<bundle id>` playing) ran from 3 s to 12 s after launch, to test scene switching |
| `--sleep-in N` | Starts the lights' sleep timer for N seconds |
| `--icon-snapshot out.png` | Renders three menu bar icon samples, then quits |
| `--bar-columns N` | Draws N bar columns per band, as on a screen N times wider than 16:9 (to test in-between bars on any screen) |
| `--screen-video clip.mp4` | Screen colors play that video's frames instead of the screen, looping, 15 a second (no permission needed); `--verbose` prints each frame's light beams |

Example: `"build/Barbeat.app/Contents/MacOS/Barbeat" --demo --snapshot /tmp/eq.png`

`scripts/tune-voice/main.swift` plays a song through the voice detector and prints a timeline (sound-only signal, the recognizer's singing/speech confidence, the gated level, words, pitch) and the time per frame.

`scripts/tune-analyzer/main.swift` plays a song file through the analyzer offline (no sound) and prints
bar, VU meter and pulse statistics (`.build/tune song.mp3 64 stereo 0`), plus the light show's brightness and flash
rate for 1 light (Pulse), 3 lights (Bands) and 9 lights with sparkles at their busiest; every light must stay at
or under 3 flashes a second. The tuning constants are at the top of `Sources/MenuBarEQ/SpectrumAnalyzer.swift`.

## Code map

| File | Role |
| --- | --- |
| `AudioCapture.swift` | Capture from system audio / one app (process tap + private aggregate device) or an input device; the source lists for the panel |
| `SampleRingBuffer.swift` | Thread-safe stereo buffer between the audio thread and the render loop |
| `SpectrumAnalyzer.swift` | FFT, log-spaced bands, auto level, smoothing, peak caps, VU meter, pulse |
| `OverlayController.swift` | Overlay windows per display, 60 fps render loop, idle when silent |
| `EQView.swift` | Metal view: per-frame parameters, notch-aware layout, and the overlay window |
| `Shaders.swift` | The Metal shader that draws every style on the GPU (compiled at launch) |
| `Effects.swift` | Spark particles and the waterfall's history texture |
| `Palette.swift`, `Settings.swift`, `SettingsView.swift` | Colors (incl. custom gradient and drift), saved preferences, menu bar panel |
| `GradientEditor.swift` | The Custom colors editor and its color picker |
| `Lights/LightShow.swift` | The light show: modes, colors from the palette, envelopes, safety cap (Foundation only) |
| `Lights/LightHub.swift` | Runs the show for every device, delay, take-over / give-back, sleep, preview |
| `Lights/Hue.swift`, `Lights/HueOutput.swift` | Hue client, discovery, pairing, DTLS stream, snapshot and restore |
| `Lights/ArtNet.swift` | Art-Net packets, DMX layout, node search, WLED detection, output |
| `Lights/LightSettings.swift`, `Lights/LightsView.swift` | Light settings and Keychain, the Lights window and panel row |
| `ScreenColors.swift` | Screen colors: ScreenCaptureKit streams per display (or one app's window), frame analysis, smoothing |
