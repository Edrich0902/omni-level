import Foundation

/// Single parametric peaking filter as produced by AutoEQ-style exports.
public struct AutoEQFilter: Equatable, Sendable {
    public var frequency: Float
    public var gaindB: Float
    public var qFactor: Float

    public init(frequency: Float, gaindB: Float, qFactor: Float) {
        self.frequency = frequency
        self.gaindB = gaindB
        self.qFactor = qFactor
    }
}

public struct AutoEQProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var filters: [AutoEQFilter]
    /// Optional pre-amp gain from profile header (dB).
    public var preAmpdB: Float?

    public init(
        id: UUID = UUID(),
        name: String,
        filters: [AutoEQFilter],
        preAmpdB: Float? = nil
    ) {
        self.id = id
        self.name = name
        self.filters = filters
        self.preAmpdB = preAmpdB
    }
}
