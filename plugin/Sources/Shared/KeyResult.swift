import Foundation
import KeyFinderCore

/// Which analysis to show. All three are computed simultaneously by the Rust
/// core, so switching is instant and never requires replaying the track.
enum SourceMode: UInt32, CaseIterable, Identifiable {
    case bass = 0
    case guitar = 1
    case fullMix = 2
    case auto = 3

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .bass: return "Bass"
        case .guitar: return "Guitar"
        case .fullMix: return "Full Mix"
        case .auto: return "Auto"
        }
    }
}

struct MusicalKey: Hashable {
    static let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// Pitch class of the tonic, 0 = C.
    let tonic: Int
    let isMinor: Bool

    var name: String { "\(Self.noteNames[tonic]) \(isMinor ? "minor" : "major")" }

    var relative: MusicalKey {
        isMinor ? MusicalKey(tonic: (tonic + 3) % 12, isMinor: false)
                : MusicalKey(tonic: (tonic + 9) % 12, isMinor: true)
    }

    /// Camelot wheel code (8B = C major, 8A = A minor), handy for DJ software.
    var camelot: String {
        let majorTonic = isMinor ? (tonic + 3) % 12 : tonic
        let number = ((majorTonic * 7) % 12 + 7) % 12 + 1
        return "\(number)\(isMinor ? "A" : "B")"
    }

    /// Scale pitch classes (natural minor for minor keys).
    var scale: Set<Int> {
        let steps = isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return Set(steps.map { ($0 + tonic) % 12 })
    }
}

struct KeyCandidate: Hashable {
    let key: MusicalKey
    let score: Float
}

struct KeyResult: Equatable {
    var key: MusicalKey?
    var mode: SourceMode
    var confidence: Float
    var tuningCents: Float
    var tonality: Float
    var secondsAnalyzed: Float
    var chroma: [Float]
    var alternatives: [KeyCandidate]
    /// Restored from the saved Logic project rather than analysed this session.
    var isSaved = false

    init(_ r: KFKeyResult) {
        key = r.has_key != 0 ? MusicalKey(tonic: Int(r.tonic), isMinor: r.is_minor != 0) : nil
        mode = SourceMode(rawValue: r.mode) ?? .fullMix
        confidence = r.confidence
        tuningCents = r.tuning_cents
        tonality = r.tonality
        secondsAnalyzed = r.seconds_analyzed
        chroma = withUnsafeBytes(of: r.chroma) { Array($0.bindMemory(to: Float.self)) }
        let candidates = withUnsafeBytes(of: r.candidates) { Array($0.bindMemory(to: KFKeyCandidate.self)) }
        alternatives = r.has_key != 0
            ? candidates.dropFirst().map {
                KeyCandidate(key: MusicalKey(tonic: Int($0.tonic), isMinor: $0.is_minor != 0), score: $0.score)
            }
            : []
    }

    /// Reference pitch for A implied by the measured tuning offset.
    var referenceA: Double { 440 * pow(2, Double(tuningCents) / 1200) }

    // MARK: Persistence (stored in the Logic project via AUAudioUnit.fullState)

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "mode": Int(mode.rawValue),
            "confidence": Double(confidence),
            "tuningCents": Double(tuningCents),
            "seconds": Double(secondsAnalyzed),
        ]
        if let key {
            d["tonic"] = key.tonic
            d["minor"] = key.isMinor
        }
        return d
    }

    init?(dictionary d: [String: Any]) {
        guard let tonic = (d["tonic"] as? NSNumber)?.intValue, (0..<12).contains(tonic) else { return nil }
        key = MusicalKey(tonic: tonic, isMinor: (d["minor"] as? NSNumber)?.boolValue ?? false)
        mode = SourceMode(rawValue: (d["mode"] as? NSNumber)?.uint32Value ?? 3) ?? .auto
        confidence = (d["confidence"] as? NSNumber)?.floatValue ?? 0
        tuningCents = (d["tuningCents"] as? NSNumber)?.floatValue ?? 0
        tonality = 0
        secondsAnalyzed = (d["seconds"] as? NSNumber)?.floatValue ?? 0
        chroma = []
        alternatives = []
        isSaved = true
    }
}
