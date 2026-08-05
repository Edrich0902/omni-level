import Foundation

public struct EqualizerBand: Identifiable, Equatable, Sendable {
    public let id: Int
    public let frequency: Float
    public var gaindB: Float
    public var qFactor: Float

    public static let standardFrequencies: [Float] = [
        25, 40, 63, 100, 160, 250, 400, 630,
        1000, 1600, 2500, 4000, 6300, 10000, 16000, 20000
    ]

    public static let gainRange: ClosedRange<Float> = -24.0...24.0
    public static let defaultQ: Float = 1.414

    public static func standardBands() -> [EqualizerBand] {
        standardFrequencies.enumerated().map { index, freq in
            EqualizerBand(id: index, frequency: freq, gaindB: 0.0, qFactor: defaultQ)
        }
    }

    public var frequencyLabel: String {
        if frequency >= 1000 {
            let k = frequency / 1000
            if k == floor(k) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(Int(frequency))"
    }
}
