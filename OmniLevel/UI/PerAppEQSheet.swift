import SwiftUI

/// Owns a dedicated EqualizerViewModel for editing one app’s override (does not touch global session).
@MainActor
final class PerAppEQEditorState: ObservableObject {
    let pid: pid_t
    let appName: String
    let viewModel: EqualizerViewModel

    init(
        pid: pid_t,
        appName: String,
        seedGains: [Float],
        seedQ: [Float]?,
        seedName: String?,
        presetStore: PresetStore,
        sampleRate: Double,
        onLiveChange: @escaping ([Float], [Float]?) -> Void
    ) {
        self.pid = pid
        self.appName = appName

        let dsp = EqualizerDSP()
        dsp.setSampleRate(sampleRate > 0 ? sampleRate : 48_000)
        dsp.applyGains(seedGains, qFactors: seedQ)

        let limiter = AutoPreAmpLimiter()
        limiter.setSampleRate(sampleRate > 0 ? sampleRate : 48_000)

        var vm: EqualizerViewModel!
        vm = EqualizerViewModel(
            dsp: dsp,
            limiter: limiter,
            presetStore: presetStore,
            persistsGlobalSession: false,
            onChange: {
                let gains = vm.bands.map(\.gaindB)
                let qs = vm.bands.map(\.qFactor)
                onLiveChange(gains, qs)
            }
        )
        vm.selectedPresetName = seedName ?? "Custom"
        vm.selectedPresetID = nil
        self.viewModel = vm
    }
}

/// Inline editor that reuses the main `EqualizerView` and expands under an app card.
struct PerAppEQEditorPanel: View {
    @ObservedObject var editor: PerAppEQEditorState
    @ObservedObject var presetStore: PresetStore
    var engine: AudioEngineController
    var onDone: () -> Void
    var onUseGlobal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("EQ · \(editor.appName)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(OmniTheme.textPrimary)
                        .lineLimit(1)
                    Text("Override applies only to this app")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(OmniTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Button("Use Global", action: onUseGlobal)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(OmniTheme.accent)

                Button("Done", action: onDone)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .buttonStyle(.borderedProminent)
                    .tint(OmniTheme.accent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)

            EqualizerView(
                viewModel: editor.viewModel,
                presetStore: presetStore,
                engine: engine,
                title: "App Equalizer",
                subtitleOverride: "Live for \(editor.appName)",
                showsLibraryControls: true,
                meterSpectrumInput: engine.focusedSpectrumInput,
                meterSpectrum: engine.focusedSpectrum
            )
        }
        .padding(.top, 4)
    }
}
