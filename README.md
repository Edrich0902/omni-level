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

The app is an `LSUIElement` (no Dock icon). Look for the waveform icon in the menu bar.

## Usage

1. Click the menu bar icon to open the popover.
2. Use **Demo** to verify the DSP path with a test tone.
3. Press **play** to start the engine, then tap **○** on an app card to create a CoreAudio process tap.
4. Adjust volume (0–200%), balance, mute, and solo per app.
5. Expand **Equalizer** for 16-band gains, presets, AutoEQ CSV import, and auto pre-amp.

## Offline DSP checks

```bash
chmod +x Scripts/run-dsp-validation.sh
./Scripts/run-dsp-validation.sh
```

## Architecture

| Layer | Role |
|-------|------|
| `AppAudioTapManager` | App discovery, per-app taps, gain/pan/mute/solo |
| `ProcessTapIO` | `CATapDescription` + aggregate device |
| `TapCaptureSession` | HAL input from tap → mixer → engine buffer |
| `EqualizerDSP` | 16 peaking biquads via Accelerate `vDSP_biquad` |
| `AutoPreAmpLimiter` | Headroom from peak boost + soft brickwall |
| `SpectrumAnalyzer` | 2048-pt FFT for the glass visualizer |

## Bundle ID

`com.omnilevel.app` — App Sandbox off for HAL process-tap access.
