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
        didSet {
            withStateLock { savedMode = mode }
            refresh()
            if !isRestoring { onUserChange?() }
        }
    }
    /// Called on main when the user changes what is saved with the project.
    var onUserChange: (() -> Void)?
    private var isRestoring = false
    @Published var isListening = true {
        didSet { kf_analyzer_set_listening(live.raw, isListening ? 1 : 0) }
    }

    /// Fed by the Audio Unit's render block.
    let live: AnalyzerHandle
    private var file: AnalyzerHandle?
    private var fileRequest = 0 // bumped to discard superseded file analyses
    private var saved: KeyResult? // from the Logic project, shown until live analysis finds a key

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
        onUserChange?()
        kf_analyzer_reset(live.raw, 0)
        queue.async { [weak self] in
            guard let self else { return }
            _ = kf_analyzer_process(self.live.raw) // applies the reset
            DispatchQueue.main.async {
                // A refresh queued before the reset applied may have saved the old key again.
                self.saved = nil
                self.withStateLock { self.savedResult = nil }
                self.showLive()
            }
        }
    }

    private func liveAudioArrived() {
        if source == .live { refresh() }
    }

    // MARK: File analysis

    func analyzeFile(at url: URL) {
        fileRequest += 1
        let request = fileRequest
        isAnalyzingFile = true
        fileError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try AnalyzerHandle.analyzing(fileAt: url) }
            DispatchQueue.main.async {
                guard let self, self.fileRequest == request else { return }
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
        fileRequest += 1
        isAnalyzingFile = false
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
            // Silence or a few unanalysed samples mustn't hide the saved key.
            let current = live.result(for: mode)
            if current.key == nil, let saved {
                result = saved
            } else {
                saved = nil
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

    /// Applies the persisted state at once, so a host that reads fullState
    /// straight after setting it gets it back; the UI follows on main.
    func restore(_ d: [String: Any]) {
        let restoredMode = (d["mode"] as? NSNumber).flatMap { SourceMode(rawValue: $0.uint32Value) }
        let restoredResult = (d["lastResult"] as? [String: Any]).flatMap(KeyResult.init(dictionary:))
        withStateLock {
            if let restoredMode { savedMode = restoredMode }
            savedResult = restoredResult
        }
        DispatchQueue.main.async { [self] in
            isRestoring = true
            if let restoredMode { mode = restoredMode }
            isRestoring = false
            saved = restoredResult
            refresh()
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
