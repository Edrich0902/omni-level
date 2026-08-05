import Foundation
import SwiftUI
import Combine

/// Observable bridge between EqualizerDSP and SwiftUI.
@MainActor
public final class EqualizerViewModel: ObservableObject {
    @Published public var bands: [EqualizerBand]
    @Published public var autoPreAmpEnabled: Bool = true
    @Published public var autoPreAmpdB: Float = 0
    @Published public var targetCurveGains: [Float]?
    @Published public var selectedPresetName: String = "Flat"

    public let dsp: EqualizerDSP
    public let limiter: AutoPreAmpLimiter
    private var onChange: (() -> Void)?

    /// Cached magnitude curve; rebuilt only when DSP fingerprint changes.
    private var cachedCurve: [(frequency: Float, magnitudedB: Float)] = []
    private var cachedCurveSignature: UInt64 = 0
    private var cachedCurveCount: Int = 0

    public init(dsp: EqualizerDSP, limiter: AutoPreAmpLimiter, onChange: (() -> Void)? = nil) {
        self.dsp = dsp
        self.limiter = limiter
        self.onChange = onChange
        self.bands = dsp.snapshotBands()
        self.autoPreAmpEnabled = dsp.isAutoPreAmpEnabled()
        self.autoPreAmpdB = dsp.currentAutoPreAmpdB()
    }

    public func updateGain(at index: Int, value: Float) {
        dsp.updateBandGain(at: index, gaindB: value)
        // Patch local state without full DSP snapshot allocation when possible.
        if bands.indices.contains(index) {
            bands[index].gaindB = max(
                EqualizerBand.gainRange.lowerBound,
                min(EqualizerBand.gainRange.upperBound, value)
            )
        } else {
            bands = dsp.snapshotBands()
        }
        autoPreAmpdB = dsp.currentAutoPreAmpdB()
        limiter.setPreAmpdB(autoPreAmpEnabled ? autoPreAmpdB : 0)
        selectedPresetName = "Custom"
        cachedCurveSignature = 0
        onChange?()
    }

    public func setAutoPreAmpEnabled(_ enabled: Bool) {
        autoPreAmpEnabled = enabled
        dsp.setAutoPreAmpEnabled(enabled)
        autoPreAmpdB = dsp.currentAutoPreAmpdB()
        limiter.setPreAmpdB(enabled ? autoPreAmpdB : 0)
        onChange?()
    }

    public func applyPreset(_ preset: EQPreset) {
        dsp.applyGains(preset.gainsdB, qFactors: preset.qFactors)
        bands = dsp.snapshotBands()
        autoPreAmpdB = dsp.currentAutoPreAmpdB()
        limiter.setPreAmpdB(autoPreAmpEnabled ? autoPreAmpdB : 0)
        selectedPresetName = preset.name
        targetCurveGains = nil
        cachedCurveSignature = 0
        onChange?()
    }

    public func applyAutoEQ(_ profile: AutoEQProfile) {
        let mapped = AutoEQImporter.mapToSixteenBands(profile)
        dsp.applyGains(mapped.gains, qFactors: mapped.qFactors)
        bands = dsp.snapshotBands()
        autoPreAmpdB = dsp.currentAutoPreAmpdB()
        limiter.setPreAmpdB(autoPreAmpEnabled ? autoPreAmpdB : 0)
        selectedPresetName = profile.name
        targetCurveGains = mapped.gains
        cachedCurveSignature = 0
        onChange?()
    }

    public func magnitudePoints(count: Int = 128) -> [(frequency: Float, magnitudedB: Float)] {
        let sig = dsp.curveSignature()
        if sig == cachedCurveSignature, count == cachedCurveCount, !cachedCurve.isEmpty {
            return cachedCurve
        }
        let points = dsp.magnitudeResponse(pointCount: count)
        cachedCurve = points
        cachedCurveSignature = sig
        cachedCurveCount = count
        return points
    }
}
