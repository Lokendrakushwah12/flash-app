<p align="center"><img src="assets/icon.png" width="160" alt="FlashEdit icon"></p>

<h1 align="center">FlashEdit</h1>

<p align="center">Meitu-style flash edits for your Mac: darker, moodier backgrounds and a flash-lit person,<br>
rendered on your Mac, offline, and identical every time.</p>

<p align="center">
  <a href="https://github.com/Lokendrakushwah12/flash-app/releases/latest/download/FlashEdit.zip"><b>Download for macOS</b></a> ·
  <a href="https://lokendrakushwah12.github.io/flash-app/">Website</a> ·
  <a href="https://github.com/Lokendrakushwah12/flash-app/releases">All releases</a>
</p>

## Install

1. Download **FlashEdit.zip** from the [latest release](https://github.com/Lokendrakushwah12/flash-app/releases/latest) and double-click it.
2. Drag **FlashEdit.app** into Applications and open it.
3. The app isn't notarized yet, so macOS asks the first time: open **System Settings → Privacy & Security** and click
   **Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/FlashEdit.app`).

Requires macOS 14 or later, Apple silicon or Intel.

## What it does

- **Flash looks**: four looks learned from reference edits, plus **None**, a **Strength** slider and your own **saved presets**.
- **Isolate**: edit the whole photo, only the background or only the person (Apple Vision finds them).
- **Light**: exposure, contrast, highlights, shadows, whites, blacks and **Auto**. **Presence**: texture, clarity, dehaze, vibrance, saturation.
- **Tone Curve** you draw on (RGB, red, green, blue) over the histogram, **Color Mixer** (HSL for eight colours) and
  **Color Grading** wheels for shadows, midtones and highlights.
- **Blur** behind the person: lens with round bokeh, gaussian, motion, zoom and tilt-shift. The person stays sharp.
- **Detail** (sharpening with masking, noise reduction) and **Effects** (vignette, grain, fog).
- **Skin**: face and body tone, **plastic shine** (glossy ↔ matte) and **pink lips** (from Vision's lip outline).
- **Crop**: aspect ratios, straighten, rotate, flip and a box you drag on the photo.
- **Organised like Lightroom**: a histogram, Edit / Crop / Chat tabs, panels that fold away (a dot marks the ones with
  edits) and **search** across every adjustment (⌘F).
- **Chat with Claude**: describe the edit ("teal and orange grade, blur the background") and Claude changes the sliders.
  It never touches pixels, so you can keep tweaking. Pick **Fable, Opus, Sonnet or Haiku**; it runs on your local
  [Claude Code](https://claude.com/claude-code).
- **Library**: every photo keeps its edit, chat, **versions** (⌘S) and **undo/redo** (⌘Z). Add the same photo as many
  times as you like or make a **virtual copy** (⌘'), **copy and paste edits** between photos (⇧⌘C / ⇧⌘V), and **rate**
  with 1–5 and filter by stars.
- **Canvas**: before/after side by side or after only (⌘B), hold to compare, pinch to zoom, Space-drag to pan, Fit / 100%.
- **Formats**: JPEG, PNG, **HEIC** and more in (drag from Finder or straight from Photos). Export as JPEG, HEIC, PNG or
  TIFF at full size or smaller, with your camera info, date and location kept.

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/build.sh          # -> dist/FlashEdit.app (universal) and dist/FlashEdit.zip
open dist/FlashEdit.app
```

Or open the folder in Xcode (`Package.swift`) and press Run.

## How it works

The edit pipeline is a Swift port of [`reference/flashgrade.py`](reference/flashgrade.py), the numpy/scipy prototype
it was designed in: dark-channel dehaze, a guided-filter refine of Vision's person mask, flash spill, separate
ambient and flash tone curves (9-knot monotone PCHIP), white balance and saturation, shine with white neutralisation,
fog behind the person, Lab skin shifts and guided skin smoothing. Parameters scale with the photo
(`s = min(H, W) / 720`), so previews match full-resolution exports.

`scripts/parity.sh` renders four photos with both the Python reference and the app and compares them pixel by pixel
(mean difference about 0.01 %), then runs the app's self-test. Put any four photos with a person in
`samples/before1.png` … `before4.png` first (they aren't in the repo); it needs [uv](https://docs.astral.sh/uv/).

## Releasing

```sh
git tag v1.1.0 && git push origin v1.1.0
```

GitHub Actions builds the universal app and publishes `FlashEdit.zip` on a release; the website's download button
always points at the latest one. The icon is drawn by `swift scripts/make_icon.swift assets`.

## Layout

```
Sources/FlashEdit/   Engine.swift (flash look + Vision), Develop.swift (Lightroom-style stages), Library.swift (catalog,
                     presets, preview, chat), App.swift (window, library), Canvas.swift, Inspector.swift (panels)
reference/           the Python prototype the engine is checked against
scripts/             build.sh, parity.sh, make_icon.swift
assets/              app icon
index.html           the website (GitHub Pages)
```
