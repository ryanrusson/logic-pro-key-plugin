import AVFoundation
import KeyFinderCore

/// Owns one Rust `KFAnalyzer`.
final class AnalyzerHandle {
    let raw: OpaquePointer

    init?(sampleRate: Double) {
        guard let p = kf_analyzer_new(sampleRate) else { return nil }
        raw = p
    }

    deinit { kf_analyzer_free(raw) }

    func result(for mode: SourceMode) -> KeyResult {
        var r = KFKeyResult()
        _ = kf_analyzer_result(raw, mode.rawValue, &r)
        return KeyResult(r)
    }

    enum FileError: LocalizedError {
        case unsupported
        var errorDescription: String? { "The file could not be decoded as audio." }
    }

    /// Decode and analyse an audio file (any format AVFoundation reads),
    /// streaming it through the same pipeline used for live input.
    static func analyzing(fileAt url: URL) throws -> AnalyzerHandle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // always deinterleaved Float32
        let chunk: AVAudioFrameCount = 1 << 16
        guard let handle = AnalyzerHandle(sampleRate: format.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
        else { throw FileError.unsupported }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let right: UnsafePointer<Float>? = format.channelCount > 1 ? UnsafePointer(channels[1]) : nil
            _ = kf_analyzer_push(handle.raw, channels[0], right, Int(buffer.frameLength))
            _ = kf_analyzer_process(handle.raw)
        }
        return handle
    }
}
