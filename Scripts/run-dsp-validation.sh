#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/DerivedData/dsp_check"
mkdir -p "$ROOT/DerivedData"
swiftc -O -o "$OUT" \
  OmniLevel/Models/EqualizerBand.swift \
  OmniLevel/Models/EQPreset.swift \
  OmniLevel/Models/AutoEQProfile.swift \
  OmniLevel/Audio/EqualizerDSP.swift \
  OmniLevel/Audio/AutoPreAmpLimiter.swift \
  OmniLevel/Audio/GainPanMixer.swift \
  OmniLevel/Services/AutoEQImporter.swift \
  OmniLevel/Audio/DSPValidation.swift \
  Tools/DSPCheckMain.swift \
  -framework Accelerate
"$OUT"
