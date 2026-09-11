import Foundation

public struct EQPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var gainsdB: [Float]
    public var qFactors: [Float]?
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        gainsdB: [Float],
        qFactors: [Float]? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.gainsdB = gainsdB
        self.qFactors = qFactors
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, gainsdB, qFactors, isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        gainsdB = try c.decode([Float].self, forKey: .gainsdB)
        qFactors = try c.decodeIfPresent([Float].self, forKey: .qFactors)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Stable UUIDs so selection survives app relaunch.
    public static let builtIn: [EQPreset] = [
        EQPreset(
            id: UUID(uuidString: "A1E00100-0000-4000-8000-000000000001")!,
            name: "Flat",
            gainsdB: Array(repeating: 0, count: 16),
            isBuiltIn: true
        ),
        EQPreset(
            id: UUID(uuidString: "A1E00100-0000-4000-8000-000000000002")!,
            name: "Bass Boost",
            gainsdB: [6, 5.5, 4.5, 3, 1.5, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            isBuiltIn: true
        ),
        EQPreset(
            id: UUID(uuidString: "A1E00100-0000-4000-8000-000000000003")!,
            name: "Vocal Clarity",
            gainsdB: [-2, -1.5, -1, 0, 1, 2.5, 3.5, 4, 3.5, 2, 0.5, 0, -0.5, -1, -1.5, -2],
            isBuiltIn: true
        ),
        EQPreset(
            id: UUID(uuidString: "A1E00100-0000-4000-8000-000000000004")!,
            name: "Acoustic",
            gainsdB: [3, 2.5, 1.5, 0.5, 0, 0.5, 1.5, 2, 1.5, 1, 0.5, 1, 1.5, 1, 0.5, 0],
            isBuiltIn: true
        ),
        EQPreset(
            id: UUID(uuidString: "A1E00100-0000-4000-8000-000000000005")!,
            name: "Podcast",
            gainsdB: [-4, -3, -2, -1, 0, 1.5, 3, 4, 3.5, 2.5, 1, 0, -1, -2, -3, -4],
            isBuiltIn: true
        )
    ]
}

// MARK: - Last session

/// Restored EQ state after relaunch (preset selection + full curve).
public struct EQSessionState: Codable, Equatable, Sendable {
    public var name: String
    public var presetID: UUID?
    public var gainsdB: [Float]
    public var qFactors: [Float]?
    public var autoPreAmpEnabled: Bool
    public var targetCurveGains: [Float]?
    /// Wall-clock save time (seconds since reference date) for UD vs file freshness.
    public var savedAt: TimeInterval?

    public init(
        name: String,
        presetID: UUID? = nil,
        gainsdB: [Float],
        qFactors: [Float]? = nil,
        autoPreAmpEnabled: Bool = false,
        targetCurveGains: [Float]? = nil,
        savedAt: TimeInterval? = nil
    ) {
        self.name = name
        self.presetID = presetID
        self.gainsdB = gainsdB
        self.qFactors = qFactors
        self.autoPreAmpEnabled = autoPreAmpEnabled
        self.targetCurveGains = targetCurveGains
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, presetID, gainsdB, qFactors, autoPreAmpEnabled, targetCurveGains, savedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        presetID = try c.decodeIfPresent(UUID.self, forKey: .presetID)
        gainsdB = try c.decode([Float].self, forKey: .gainsdB)
        qFactors = try c.decodeIfPresent([Float].self, forKey: .qFactors)
        // Missing key (and legacy accidental on) → default OFF.
        autoPreAmpEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoPreAmpEnabled) ?? false
        targetCurveGains = try c.decodeIfPresent([Float].self, forKey: .targetCurveGains)
        savedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .savedAt)
    }
}
