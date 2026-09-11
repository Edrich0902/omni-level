import Foundation
import SwiftUI
import Combine
import os

/// Observable bridge between EqualizerDSP and SwiftUI.
@MainActor
public final class EqualizerViewModel: ObservableObject {
    @Published public var bands: [EqualizerBand]
    @Published public var autoPreAmpEnabled: Bool = false
    @Published public var autoPreAmpdB: Float = 0
    @Published public var targetCurveGains: [Float]?
    @Published public var selectedPresetName: String = "Flat"
    @Published public var selectedPresetID: UUID?

    public let dsp: EqualizerDSP
    public let limiter: AutoPreAmpLimiter
    private let presetStore: PresetStore
    private var onChange: (() -> Void)?
    private let log = Logger(subsystem: "com.omnilevel.app", category: "eq")

    /// When false, band edits do not write the global last-session (used for per-app EQ editors).
    public var persistsGlobalSession = true

    private var cachedCurve: [(frequency: Float, magnitudedB: Float)] = []
    private var cachedCurveSignature: UInt64 = 0
    private var cachedCurveCount: Int = 0
    private var isRestoring = false

    public init(
        dsp: EqualizerDSP,
        limiter: AutoPreAmpLimiter,
        presetStore: PresetStore,
        persistsGlobalSession: Bool = true,
        onChange: (() -> Void)? = nil
    ) {
        self.dsp = dsp
        self.limiter = limiter
        self.presetStore = presetStore
        self.persistsGlobalSession = persistsGlobalSession
        self.onChange = onChange
        self.bands = dsp.snapshotBands()
        // Always start with auto pre-amp off; restore may re-enable explicitly.
        dsp.setAutoPreAmpEnabled(false)
        self.autoPreAmpEnabled = false
        self.autoPreAmpdB = 0
        limiter.setPreAmpdB(0)
    }

    /// Whether restore applied a real session (or selected preset) vs cold Flat defaults.
    public private(set) var didRestoreRealSession = false

    /// Apply last session, or selectedPresetID, or last user preset, or leave Flat + auto off.
    public func restoreLastSessionIfAvailable() {
        didRestoreRealSession = false

        if let session = presetStore.loadSession() {
            let peak = session.gainsdB.map { abs($0) }.max() ?? 0
            log.info(
                "restoring session “\(session.name, privacy: .public)” id=\(session.presetID?.uuidString ?? "nil", privacy: .public) peak=\(peak)"
            )
            restoreSession(session)
            didRestoreRealSession = true
            return
        }

        // Prefer last selected preset (built-in or user) over “last user preset only”.
        if let id = presetStore.selectedPresetID,
           let preset = presetStore.preset(id: id) {
            log.info("no session — restoring selectedPresetID “\(preset.name, privacy: .public)”")
            applyPreset(preset, persist: true, forceAutoPreAmp: false)
            didRestoreRealSession = true
            return
        }

        if let lastUser = presetStore.presets.last(where: { !$0.isBuiltIn }) {
            log.info("no session/selection — applying last user preset “\(lastUser.name, privacy: .public)”")
            applyPreset(lastUser, persist: true, forceAutoPreAmp: false)
            didRestoreRealSession = true
            return
        }

        // Cold start: Flat + auto pre-amp off — do not write a fake “preference”.
        log.info("cold start — Flat defaults (not persisting)")
        dsp.setAutoPreAmpEnabled(false)
        autoPreAmpEnabled = false
        autoPreAmpdB = 0
        limiter.setPreAmpdB(0)
        selectedPresetName = "Flat"
        selectedPresetID = EQPreset.builtIn.first?.id
        onChange?()
    }

    public func restoreSession(_ session: EQSessionState) {
        isRestoring = true
        defer { isRestoring = false }

        dsp.applyGains(session.gainsdB, qFactors: session.qFactors)
        bands = dsp.snapshotBands()
        selectedPresetName = session.name
        selectedPresetID = session.presetID
        targetCurveGains = session.targetCurveGains

        applyAutoPreAmpState(session.autoPreAmpEnabled)
        cachedCurveSignature = 0
        onChange?()
    }

    public func updateGain(at index: Int, value: Float) {
        dsp.updateBandGain(at: index, gaindB: value)
        if bands.indices.contains(index) {
            bands[index].gaindB = max(
                EqualizerBand.gainRange.lowerBound,
                min(EqualizerBand.gainRange.upperBound, value)
            )
        } else {
            bands = dsp.snapshotBands()
        }
        refreshPreAmpReadout()
        selectedPresetName = "Custom"
        selectedPresetID = nil
        cachedCurveSignature = 0
        onChange?()
        persistSession()
    }

    public func setAutoPreAmpEnabled(_ enabled: Bool) {
        applyAutoPreAmpState(enabled)
        onChange?()
        if !isRestoring {
            persistSession()
        }
    }

    public func applyPreset(_ preset: EQPreset) {
        applyPreset(preset, persist: true, forceAutoPreAmp: nil)
    }

    private func applyPreset(_ preset: EQPreset, persist: Bool, forceAutoPreAmp: Bool?) {
        dsp.applyGains(preset.gainsdB, qFactors: preset.qFactors)
        bands = dsp.snapshotBands()
        selectedPresetName = preset.name
        selectedPresetID = preset.id
        targetCurveGains = nil
        if let forceAutoPreAmp {
            applyAutoPreAmpState(forceAutoPreAmp)
        } else {
            refreshPreAmpReadout()
        }
        cachedCurveSignature = 0
        onChange?()
        if persist {
            persistSession()
        }
    }

    public func applyAutoEQ(_ profile: AutoEQProfile) {
        let mapped = AutoEQImporter.mapToSixteenBands(profile)
        dsp.applyGains(mapped.gains, qFactors: mapped.qFactors)
        bands = dsp.snapshotBands()
        selectedPresetName = profile.name
        selectedPresetID = nil
        targetCurveGains = mapped.gains
        refreshPreAmpReadout()
        cachedCurveSignature = 0
        onChange?()
        persistSession()
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

    public func flushSessionToDisk() {
        persistSession()
    }

    private func applyAutoPreAmpState(_ enabled: Bool) {
        autoPreAmpEnabled = enabled
        dsp.setAutoPreAmpEnabled(enabled)
        refreshPreAmpReadout()
    }

    private func refreshPreAmpReadout() {
        autoPreAmpdB = dsp.currentAutoPreAmpdB()
        limiter.setPreAmpdB(autoPreAmpEnabled ? autoPreAmpdB : 0)
    }

    private func persistSession() {
        guard !isRestoring, persistsGlobalSession else { return }
        let gains = bands.map(\.gaindB)
        guard gains.count == EqualizerDSP.bandCount else { return }
        presetStore.saveSession(
            EQSessionState(
                name: selectedPresetName,
                presetID: selectedPresetID,
                gainsdB: gains,
                qFactors: bands.map(\.qFactor),
                autoPreAmpEnabled: autoPreAmpEnabled,
                targetCurveGains: targetCurveGains,
                savedAt: Date().timeIntervalSinceReferenceDate
            )
        )
    }
}
