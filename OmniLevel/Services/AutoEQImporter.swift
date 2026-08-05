import Foundation

/// Imports AutoEQ-style parametric CSV / ParametricEQ.txt into OmniLevel's fixed 16-band layout.
///
/// Supported formats:
/// - AutoEQ `ParametricEQ.txt` (`Preamp:` + `Filter N: ON PK Fc … Gain … Q …`)
/// - `Type,Fc,Gain,Q`  (AutoEQ parametric.csv)
/// - `Fc,Gain,Q` / space-separated rows
public enum AutoEQImporter {
    public static func importFile(at url: URL) throws -> AutoEQProfile {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text: text, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(text: String, name: String) -> AutoEQProfile {
        var filters: [AutoEQFilter] = []
        var preAmp: Float?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Preamp: -6.2 dB
            if line.lowercased().hasPrefix("preamp") {
                if let match = line.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression) {
                    preAmp = Float(line[match])
                }
                continue
            }

            // Filter 1: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
            if line.lowercased().hasPrefix("filter"),
               let filter = parseParametricEQLine(line) {
                filters.append(filter)
                continue
            }

            let lower = line.lowercased()
            if lower.contains("frequency") && lower.contains("gain") { continue }
            if lower.hasPrefix("type,") { continue }

            let parts = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
                .map { String($0).trimmingCharacters(in: .whitespaces) }

            if let filter = parseRow(parts) {
                filters.append(filter)
            }
        }

        return AutoEQProfile(name: name, filters: filters, preAmpdB: preAmp)
    }

    /// Map arbitrary parametric filters onto the 16 fixed center frequencies.
    public static func mapToSixteenBands(_ profile: AutoEQProfile) -> (gains: [Float], qFactors: [Float]) {
        let centers = EqualizerBand.standardFrequencies
        var gains = [Float](repeating: 0, count: centers.count)
        var qs = [Float](repeating: EqualizerBand.defaultQ, count: centers.count)
        var weight = [Float](repeating: 0, count: centers.count)

        for filter in profile.filters {
            var bestIdx = 0
            var bestDist = Float.greatestFiniteMagnitude
            for (i, c) in centers.enumerated() {
                let dist = abs(log2(max(filter.frequency, 1)) - log2(max(c, 1)))
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            let influence = max(0, 1 - bestDist)
            if influence > 0.15 {
                gains[bestIdx] += filter.gaindB * influence
                qs[bestIdx] = filter.qFactor
                weight[bestIdx] += influence
            } else {
                gains[bestIdx] = filter.gaindB
                qs[bestIdx] = filter.qFactor
                weight[bestIdx] = 1
            }
        }

        for i in gains.indices {
            gains[i] = max(EqualizerBand.gainRange.lowerBound,
                           min(EqualizerBand.gainRange.upperBound, gains[i]))
            if weight[i] == 0 {
                qs[i] = EqualizerBand.defaultQ
            }
        }
        return (gains, qs)
    }

    /// `Filter 3: ON PK Fc 118 Hz Gain -3.1 dB Q 0.50`
    private static func parseParametricEQLine(_ line: String) -> AutoEQFilter? {
        guard let fcRange = line.range(of: #"Fc\s+(-?\d+(?:\.\d+)?)"#, options: [.regularExpression, .caseInsensitive]),
              let gainRange = line.range(of: #"Gain\s+(-?\d+(?:\.\d+)?)"#, options: [.regularExpression, .caseInsensitive]),
              let qRange = line.range(of: #"Q\s+(-?\d+(?:\.\d+)?)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }

        func number(from match: Range<String.Index>) -> Float? {
            let segment = String(line[match])
            guard let numRange = segment.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression) else {
                return nil
            }
            return Float(segment[numRange])
        }

        guard let fc = number(from: fcRange),
              let gain = number(from: gainRange),
              let q = number(from: qRange),
              fc > 0
        else { return nil }

        return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
    }

    private static func parseRow(_ parts: [String]) -> AutoEQFilter? {
        if parts.count >= 4 {
            if let fc = Float(parts[1]), let gain = Float(parts[2]), let q = Float(parts[3]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        if parts.count >= 3 {
            if let fc = Float(parts[0]), let gain = Float(parts[1]), let q = Float(parts[2]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        if parts.count >= 4, Float(parts[0]) == nil {
            if let fc = Float(parts[1]), let gain = Float(parts[2]), let q = Float(parts[3]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        return nil
    }
}
