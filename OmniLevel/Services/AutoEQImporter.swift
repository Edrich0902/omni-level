import Foundation

/// Imports AutoEQ-style parametric CSV / text into OmniLevel's fixed 16-band layout.
///
/// Supported row formats (header optional):
/// - `Type,Fc,Gain,Q`  (AutoEQ parametric.csv style; Type = PK / LSC / HSC / etc.)
/// - `Fc,Gain,Q`
/// - `frequency,gain,q`
///
/// Preamp lines like `Preamp: -6.2 dB` are captured when present.
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
                // Prefer signed value near "Preamp: -X"
                if let match = line.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression) {
                    preAmp = Float(line[match])
                }
                continue
            }

            // Skip obvious headers
            let lower = line.lowercased()
            if lower.contains("frequency") && lower.contains("gain") { continue }
            if lower.hasPrefix("type,") || lower.hasPrefix("filter") { continue }

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
            // Nearest band index on log scale
            var bestIdx = 0
            var bestDist = Float.greatestFiniteMagnitude
            for (i, c) in centers.enumerated() {
                let dist = abs(log2(max(filter.frequency, 1)) - log2(max(c, 1)))
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            // If very close, assign fully; else soft distribute to neighboring bands
            let influence = max(0, 1 - bestDist) // 1 when exact octave match 0, 0 after 1 octave
            if influence > 0.15 {
                gains[bestIdx] += filter.gaindB * influence
                qs[bestIdx] = filter.qFactor
                weight[bestIdx] += influence
            } else {
                // Force-assign to nearest to avoid losing info
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

        // Optional: blend preamp into overall by not applying here (handled by Auto Pre-Amp UI)
        return (gains, qs)
    }

    private static func parseRow(_ parts: [String]) -> AutoEQFilter? {
        // AutoEQ: Type, Fc, Gain, Q  OR  ON PK Fc 100 Gain -3.2 Q 1.4 (space form converted to parts)
        if parts.count >= 4 {
            // Try Type, Fc, Gain, Q
            if let fc = Float(parts[1]), let gain = Float(parts[2]), let q = Float(parts[3]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        if parts.count >= 3 {
            // Fc, Gain, Q
            if let fc = Float(parts[0]), let gain = Float(parts[1]), let q = Float(parts[2]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        // Space-separated "PK 100 -3.2 1.4"
        if parts.count >= 4, Float(parts[0]) == nil {
            if let fc = Float(parts[1]), let gain = Float(parts[2]), let q = Float(parts[3]), fc > 0 {
                return AutoEQFilter(frequency: fc, gaindB: gain, qFactor: max(0.1, q))
            }
        }
        return nil
    }
}
