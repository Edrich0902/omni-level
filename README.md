# OmniLevel

Native macOS **menu bar** audio utility for Apple Silicon: per-app routing and mixing, a 16-band parametric EQ, AutoEQ headphone profiles, a notch Now Playing island, and a full Monitor analyzer suite.

OmniLevel sits in the menu bar (`LSUIElement` — no Dock icon). Click the waveform icon to open the popover; eligible apps are **auto-routed** on launch.

## What it does

| Area | Features |
|------|----------|
| **Per-app mixer** | Volume 0–200%, balance/pan, mute, solo, On/Off through OmniLevel, per-app output device, live RMS meters |
| **Organization** | Favorites, custom groups, drag-and-drop reorder (grip), Mute/Unmute all, group Bypass/Route all — persisted |
| **Equalizer** | 16 peaking bands, presets, AutoEQ library + CSV import, auto pre-amp / soft ceiling, live spectrum under the response curve |
| **Per-app EQ** | Override the global curve per process; in/out band meters while editing |
| **Monitor** | True-peak + crest, limiter GR, correlation, Mid/Side width, LUFS (M/S/I), loudness history, session stats |
| **Visualizers** | Spectrum, Liquid, Mirror, 1/3-octave RTA, spectrogram, goniometer/scope — optional EQ curve overlay |
| **Now Playing** | Popover transport + **Dynamic Island–style notch** island (hover expand). Spotify via AppleScript; browsers/Music/etc via MediaRemote Adapter (works on macOS 15.4+) |
| **Routing** | Core Audio process taps (including browser helpers e.g. Arc/Chrome/Safari), multi-destination output buses, global bypass |

## Requirements

- macOS 14.2+
- Apple Silicon (arm64)
- Xcode 16+

## Permissions

Grant these in **System Settings → Privacy & Security** (app ⋯ menu → Privacy):

- **Audio Capture** — Core Audio process taps (required)
- **Automation** — Spotify transport / Now Playing (AppleScript)
- **Microphone** — only if you use the input device path

## Build & run

```bash
open OmniLevel.xcodeproj
# or
xcodebuild -project OmniLevel.xcodeproj -scheme OmniLevel -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData build
open ./DerivedData/Build/Products/Debug/OmniLevel.app
```

For day-to-day testing, install a signed copy to `/Applications/OmniLevel.app` (optional).

## Usage

1. Click the menu bar icon. OmniLevel **auto-routes** eligible apps (no manual play / tap bootstrap).
2. **Apps** — mix and organize: grip-drag into Favorites / a group / Other; Control-click for the same actions. Toggle **Hide quiet** to collapse silent routed apps. Mixer + list layout persist across relaunch.
3. **Equalizer** — shape the global curve; load presets or AutoEQ profiles; enable Auto Pre-Amp. Session EQ restores on launch. Spectrum underlay shows pre/post energy under the curve.
4. **Monitor** — scrollable analyzer dashboard (popover ~480×820): meters + LUFS, viz modes (Spectrum / Liquid / Mirror / RTA / Spectro / Scope), loudness history, session peak / time above −3 dBTP / limiter hits / loudest app (Reset clears session counters). Toggle **EQ** to overlay the response curve on Spectrum / RTA / Spectro.
5. **⋯ menu** — Bypass OmniLevel for dry system audio; privacy shortcuts.
6. **Notch Now Playing** — transport and artwork at the top of the screen; expands on hover.

Browsers are tapped via helper processes registered with Core Audio — YouTube in Arc (and similar) is supported.

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
| `AutoPreAmpLimiter` | Auto headroom + soft ceiling with gain-reduction metering |
| `SpectrumAnalyzer` | Realtime FFT, log bars, 1/3-octave RTA, spectrogram columns |
| `MixAnalyzer` | Post-mix LUFS, true peak, crest, correlation, Mid/Side, goniometer, session stats |
| `MixerStateStore` / `AppListStore` / `PerAppEQStore` / `AppRouteStore` | Durable mixer, list organization, EQ overrides, output routing |
| `NowPlayingService` / notch UI | Media Remote + Spotify bridge, island chrome |

## Bundle ID

`com.omnilevel.app` — App Sandbox off for HAL process-tap access.
