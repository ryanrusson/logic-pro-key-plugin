import AudioToolbox
import AVFoundation
import KeyFinderCore

/// Pass-through audio effect that listens to its track and estimates the key.
/// Audio is untouched; the render block only copies samples into the Rust
/// core's wait-free ring buffer.
public final class KeyDetectorAudioUnit: AUAudioUnit {
    let engine: AnalysisEngine
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

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
        engine.prepare(sampleRate: outputBus.format.sampleRate)
    }

    public override func deallocateRenderResources() {
        engine.stop()
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Capture only the raw pointer: no ARC traffic or Swift runtime calls
        // on the realtime thread. `engine` (and so the analyzer) outlives
        // rendering because this AU owns it.
        let analyzer = engine.live.raw
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            _ = kf_analyzer_push(analyzer, left, right.map { UnsafePointer($0) }, Int(frameCount))
            return noErr
        }
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
