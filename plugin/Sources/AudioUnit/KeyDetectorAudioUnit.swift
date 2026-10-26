import AudioToolbox
import AVFoundation
import KeyFinderCore

/// Pass-through audio effect that listens to its track and estimates the key.
/// Audio is untouched; the render block (RenderBlock.m) only copies samples
/// into the Rust core's wait-free ring buffer.
public final class KeyDetectorAudioUnit: KFAudioUnitBase {
    let engine: AnalysisEngine
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    /// Fixed address for the AU's lifetime: hosts may fetch the render block
    /// before allocateRenderResources sizes the storage.
    private let input: UnsafeMutablePointer<KFRenderInput> = {
        let p = UnsafeMutablePointer<KFRenderInput>.allocate(capacity: 1)
        p.initialize(to: KFRenderInput(maxFrames: 0, channelCount: 0, samples: nil,
                                       bufferList: AudioBufferList.allocate(maximumBuffers: 2).unsafeMutablePointer))
        return p
    }()

    private static let stateKey = "KeyFinder"

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        guard let engine = AnalysisEngine(sampleRate: format.sampleRate) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
        }
        self.engine = engine
        try super.init(componentDescription: componentDescription, options: options)

        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 2
        outputBus.maximumChannelCount = 2
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
        engine.onUserChange = { [weak self] in self?.stateChangedByUser() }
    }

    deinit {
        // -[AUAudioUnit dealloc] runs after this body and calls our
        // deallocateRenderResources if resources are still allocated, which
        // would touch `input` after it is freed. Release them first.
        if renderResourcesAllocated { deallocateRenderResources() }
        input.pointee.samples?.deallocate()
        free(input.pointee.bufferList)
        input.deinitialize(count: 1)
        input.deallocate()
    }

    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    /// Mono→mono and stereo→stereo.
    public override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }
    public override var canProcessInPlace: Bool { true }
    public override var latency: TimeInterval { 0 }
    public override var tailTime: TimeInterval { 0 }

    public override func allocateRenderResources() throws {
        guard inputBus.format.channelCount == outputBus.format.channelCount else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        // Rendering is stopped here, so the render block can't see a half-updated buffer.
        let channels = inputBus.format.channelCount
        input.pointee.samples?.deallocate()
        input.pointee.samples = .allocate(capacity: Int(channels) * Int(maximumFramesToRender))
        input.pointee.channelCount = channels
        input.pointee.maxFrames = maximumFramesToRender
        engine.prepare(sampleRate: outputBus.format.sampleRate)
    }

    public override func deallocateRenderResources() {
        engine.stop()
        input.pointee.maxFrames = 0
        input.pointee.samples?.deallocate()
        input.pointee.samples = nil
        super.deallocateRenderResources()
    }

    // The render block is KFMakeRenderBlock's, vended by KFAudioUnitBase so it
    // never passes through Swift. It captures only these raw pointers;
    // `engine` (and so the analyzer) and `input` outlive rendering because
    // this AU owns them.
    public override var renderInput: UnsafeMutablePointer<KFRenderInput> { input }
    public override var renderAnalyzer: OpaquePointer { engine.live.raw }

    /// Logic restores a project by setting fullStateForDocument, which sets
    /// fullState in turn. With automatic KVO both sets were reported back to
    /// Logic as changes made by the plug-in, so every project with KeyFinder
    /// opened as modified. Only changes the user makes here are reported.
    public override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        Self.stateKeyPaths.contains(key) ? false : super.automaticallyNotifiesObservers(forKey: key)
    }

    private static let stateKeyPaths: Set<String> = ["fullState", "fullStateForDocument"]

    /// Tells the host the saved state changed (mode switch, Reset), so Logic
    /// marks the project as modified and saves it.
    private func stateChangedByUser() {
        for key in Self.stateKeyPaths { willChangeValue(forKey: key) }
        for key in Self.stateKeyPaths { didChangeValue(forKey: key) }
    }

    /// Saved in the Logic project: the selected mode and last detected key,
    /// so reopening a session shows the key without replaying it.
    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            state[Self.stateKey] = engine.persistentState
            return state
        }
        set {
            super.fullState = newValue
            if let d = newValue?[Self.stateKey] as? [String: Any] { engine.restore(d) }
        }
    }
}
