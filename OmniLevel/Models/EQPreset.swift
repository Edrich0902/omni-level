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

    public static let builtIn: [EQPreset] = [
        EQPreset(
            name: "Flat",
            gainsdB: Array(repeating: 0, count: 16),
            isBuiltIn: true
        ),
        EQPreset(
            name: "Bass Boost",
            gainsdB: [6, 5.5, 4.5, 3, 1.5, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            isBuiltIn: true
        ),
        EQPreset(
            name: "Vocal Clarity",
            gainsdB: [-2, -1.5, -1, 0, 1, 2.5, 3.5, 4, 3.5, 2, 0.5, 0, -0.5, -1, -1.5, -2],
            isBuiltIn: true
        ),
        EQPreset(
            name: "Acoustic",
            gainsdB: [3, 2.5, 1.5, 0.5, 0, 0.5, 1.5, 2, 1.5, 1, 0.5, 1, 1.5, 1, 0.5, 0],
            isBuiltIn: true
        ),
        EQPreset(
            name: "Podcast",
            gainsdB: [-4, -3, -2, -1, 0, 1.5, 3, 4, 3.5, 2.5, 1, 0, -1, -2, -3, -4],
            isBuiltIn: true
        )
    ]
}
