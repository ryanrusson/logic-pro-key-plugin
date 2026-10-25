import Foundation
import KeyFinderCore

/// Bridges the Rust analyzer to SwiftUI. Live audio arrives through
/// `live.raw` from the render thread; a serial background queue drains it
/// every 100 ms and the published result is refreshed on the main thread.
final class AnalysisEngine: ObservableObject {
    enum Source: Equatable {
        case live
        case file(name: String)
    }

    @Published private(set) var result: KeyResult?
    @Published private(set) var source: Source = .live
    @Published private(set) var isAnalyzingFile = false
    @Published private(set) var fileError: String?
    @Published var mode: SourceMode = .auto {
        didSet { withStateLock { savedMode = mode }; refresh() }
    }
    @Published var isListening = true {
        didSet { kf_analyzer_set_listening(live.raw, isListening ? 1 : 0) }
    }

    /// Fed by the Audio Unit's render block.
    let live: AnalyzerHandle
    private var file: AnalyzerHandle?
    private var saved: KeyResult? // from the Logic project, shown until new audio arrives

    private let queue = DispatchQueue(label: "KeyFinder.analysis", qos: .userInitiated)
    private var timer: DispatchSourceTimer? // accessed on `queue` only

    // State read by AUAudioUnit.fullState, which hosts may call on any thread.
    private let stateLock = NSLock()
    private var savedMode: SourceMode = .auto
    private var savedResult: KeyResult?

    init?(sampleRate: Double) {
        guard let handle = AnalyzerHandle(sampleRate: sampleRate) else { return nil }
        live = handle
    }

    deinit { timer?.cancel() }

    // MARK: Live analysis lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self, kf_analyzer_process(self.live.raw) > 0 else { return }
                DispatchQueue.main.async { self.liveAudioArrived() }
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Called when the host changes sample rate (allocateRenderResources).
    func prepare(sampleRate: Double) {
        kf_analyzer_reset(live.raw, sampleRate)
        start()
    }

    func reset() {
        saved = nil
        withStateLock { savedResult = nil }
        kf_analyzer_reset(live.raw, 0)
        queue.async { [weak self] in
            guard let self else { return }
            _ = kf_analyzer_process(self.live.raw) // applies the reset
            DispatchQueue.main.async { self.showLive() }
        }
    }

    private func liveAudioArrived() {
        saved = nil
        if source == .live { refresh() }
    }

    // MARK: File analysis

    func analyzeFile(at url: URL) {
        isAnalyzingFile = true
        fileError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try AnalyzerHandle.analyzing(fileAt: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAnalyzingFile = false
                switch outcome {
                case .success(let handle):
                    self.file = handle
                    self.source = .file(name: url.lastPathComponent)
                    self.refresh()
                case .failure(let error):
                    self.fileError = error.localizedDescription
                }
            }
        }
    }

    func showLive() {
        source = .live
        file = nil
        refresh()
    }

    // MARK: Results

    private func refresh() {
        switch source {
        case .file:
            result = file?.result(for: mode)
        case .live:
            let current = live.result(for: mode)
            if current.secondsAnalyzed == 0, let saved {
                result = saved
            } else {
                result = current
                if current.key != nil { withStateLock { savedResult = current } }
            }
        }
    }

    // MARK: Persistence

    var persistentState: [String: Any] {
        withStateLock {
            var d: [String: Any] = ["mode": Int(savedMode.rawValue)]
            if let savedResult { d["lastResult"] = savedResult.dictionary }
            return d
        }
    }

    func restore(_ d: [String: Any]) {
        DispatchQueue.main.async { [self] in
            if let raw = (d["mode"] as? NSNumber)?.uint32Value, let m = SourceMode(rawValue: raw) {
                mode = m
            }
            if let rd = d["lastResult"] as? [String: Any], let r = KeyResult(dictionary: rd) {
                saved = r
                withStateLock { savedResult = r }
                refresh()
            }
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
