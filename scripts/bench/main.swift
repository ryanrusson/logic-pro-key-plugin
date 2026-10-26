// Apple Loops benchmark harness (built by scripts/bench-apple-loops.sh).
// Reads CAF paths from stdin and prints one tab-separated row per pitched,
// key-labelled loop: its labels, then every source mode's result. Files are
// decoded and analysed by the plugin's own AnalyzerHandle, so the Swift
// file-analysis path is measured along with the Rust core.
import Foundation

/// Apple Loops metadata, read from the CAF chunks after the audio data. An
/// `info` chunk holds a big-endian UInt32 count, then that many
/// NUL-terminated key/value string pairs; a `uuid` chunk holds a 16-byte
/// UUID, then the same layout (other UUIDs fail the checks and are skipped).
func loopMetadata(_ url: URL) -> [String: String] {
    guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.starts(with: Data("caff".utf8)) else { return [:] }
    func be(_ r: Range<Int>) -> UInt64 { d[r].reduce(0) { $0 << 8 | UInt64($1) } }
    var meta: [String: String] = [:]
    var off = 8
    while off + 12 <= d.count {
        let type = String(decoding: d[off..<off + 4], as: UTF8.self)
        let declared = Int64(bitPattern: be(off + 4..<off + 12))
        let size = declared < 0 ? d.count - off - 12 : Int(min(declared, Int64(d.count - off - 12)))
        var body = off + 12..<off + 12 + size
        off = body.upperBound
        if type == "uuid" { body = min(body.lowerBound + 16, body.upperBound)..<body.upperBound }
        guard type == "info" || type == "uuid", body.count >= 4 else { continue }
        let count = Int(be(body.lowerBound..<body.lowerBound + 4))
        let strings = d[body.lowerBound + 4..<body.upperBound].split(separator: 0, omittingEmptySubsequences: false)
        guard count < 1000, strings.count > 2 * count else { continue }
        for i in 0..<count {
            meta[String(decoding: strings[2 * i], as: UTF8.self)] = String(decoding: strings[2 * i + 1], as: UTF8.self)
        }
    }
    return meta
}

let skippedCategories: Set = ["Drums", "Percussion", "Sound Effect"]
let pitchClasses: [String: Int] = [
    "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
    "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11,
]
let modes: [SourceMode] = [.bass, .guitar, .fullMix, .auto]

func label(_ r: KeyResult) -> String {
    guard let k = r.key else { return "-" }
    return "\(MusicalKey.noteNames[k.tonic]):\(k.isMinor ? "min" : "maj")"
}

// Per-mode tonality and chroma let scripts/bench/train.py refit the key model.
var header = ["path", "category", "tonic", "type", "seconds"]
for m in modes { header += [m.label, "\(m.label) conf"] }
header.append("Auto source")
for m in modes.dropLast() { header += ["\(m.label) tonality", "\(m.label) chroma"] }
print(header.joined(separator: "\t"))

while let path = readLine(), !path.isEmpty {
    let meta = loopMetadata(URL(fileURLWithPath: path))
    let category = meta["category"] ?? ""
    guard !skippedCategories.contains(category),
          let tonic = meta["key signature"].flatMap({ pitchClasses[$0] }),
          let type = meta["key type"], ["major", "minor", "both"].contains(type)
    else { continue }
    let handle: AnalyzerHandle
    do { handle = try AnalyzerHandle.analyzing(fileAt: URL(fileURLWithPath: path)) } catch {
        FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
        continue
    }
    let results = modes.map { handle.result(for: $0) }
    var row = [path, category, MusicalKey.noteNames[tonic], type, String(format: "%.2f", results[0].secondsAnalyzed)]
    for r in results { row += [label(r), String(format: "%.3f", r.confidence)] }
    row.append(results[3].mode.label)
    for r in results.dropLast() {
        row += [String(format: "%.3f", r.tonality), r.chroma.map { String(format: "%.4f", $0) }.joined(separator: ",")]
    }
    print(row.joined(separator: "\t"))
}
