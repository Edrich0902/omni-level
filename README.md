# OmniLevel

Native macOS menu bar utility for per-app audio routing, 16-band parametric EQ, auto pre-amp, and real-time visualization.

## Requirements

- macOS 14.2+
- Apple Silicon (arm64)
- Xcode 16+

## Build & Run

```bash
open OmniLevel.xcodeproj
# or
xcodebuild -project OmniLevel.xcodeproj -scheme OmniLevel -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData build
open ./DerivedData/Build/Products/Debug/OmniLevel.app
```

For day-to-day testing, install a signed copy to `/Applications/OmniLevel.app` (optional).

The app is an `LSUIElement` (no Dock icon). Look for the waveform icon in the menu bar.

## Permissions

Grant these in **System Settings → Privacy & Security** (⋯ menu → Privacy in the app):

- **Audio Capture** — required for Core Audio process taps
- **Automation** — Spotify transport / Now Playing (AppleScript)
- **Microphone** — only if you use the input device path

## Usage

1. Click the menu bar icon to open the popover. OmniLevel **auto-routes** eligible apps on launch (no manual play / tap bootstrap).
2. **Apps** pane: per-app volume (0–200%), balance, mute, solo, On/Off through OmniLevel, output device, and per-app EQ. Use the **grip** on a card to drag into **Favorites** / a **group** / **Other**, or reorder within a section. Control-click also works. Group and Favorites menus support Mute all / Unmute all (groups also Bypass all / Route all). Toggle **Hide quiet** to collapse quiet routed apps. Mixer controls and list organization persist across relaunch.
3. **Equalizer** pane: 16-band gains, presets, AutoEQ library / CSV import, and auto pre-amp. Session EQ restores on launch.
4. **Monitor** pane: spectrum / visualizer and meters.
5. Use **Bypass OmniLevel** in the ⋯ menu for dry system audio. Notch Now Playing sits at the top of the screen for transport.

Browsers (Arc, Chrome, Safari, etc.) are tapped via helper processes registered with Core Audio — YouTube in Arc is supported.

## Offline DSP checks

```bash
chmod +x Scripts/run-dsp-validation.sh
./Scripts/run-dsp-validation.sh
```

## Architecture

| Layer | Role |
|-------|------|
| `AppAudioTapManager` | App discovery, per-app taps, gain/pan/mute/solo, mixer persistence |
| `ProcessTapIO` | `CATapDescription` clusters + aggregate devices |
| `AudioEngineController` | Multi-stream mix → EQ → limiter → output buses |
| `EqualizerDSP` | 16 peaking biquads via Accelerate `vDSP_biquad` |
| `AutoPreAmpLimiter` | Headroom from peak boost + soft brickwall |
| `SpectrumAnalyzer` | 2048-pt FFT for the glass visualizer |
| `MixerStateStore` / `AppListStore` / `PerAppEQStore` / `AppRouteStore` | Durable mixer, list organization, EQ override, and output routing |

## Bundle ID

`com.omnilevel.app` — App Sandbox off for HAL process-tap access.
