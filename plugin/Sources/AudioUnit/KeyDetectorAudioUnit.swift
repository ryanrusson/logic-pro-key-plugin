import AudioToolbox
import AVFoundation
import KeyFinderCore

/// Input buffers the render block pulls into. AURenderPullInputBlock needs
/// caller-owned buffers, and the host's output buffers may have NULL mData
/// (in-place request), so they can't be used for the pull.
private struct RenderInput {
    var maxFrames: AUAudioFrameCount = 0
    var channelCount = 0
    var samples: UnsafeMutablePointer<Float>? // planar, channelCount * maxFrames
    let bufferList = AudioBufferList.allocate(maximumBuffers: 2)
}

/// Pass-through audio effect that listens to its track and estimates the key.
/// Audio is untouched; the render block only copies samples into the Rust
/// core's wait-free ring buffer.
public final class KeyDetectorAudioUnit: AUAudioUnit {
    let engine: AnalysisEngine
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    /// Fixed address for the AU's lifetime: hosts may fetch the render block
    /// before allocateRenderResources sizes the storage.
    private let input: UnsafeMutablePointer<RenderInput> = {
        let p = UnsafeMutablePointer<RenderInput>.allocate(capacity: 1)
        p.initialize(to: RenderInput())
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
    }

    deinit {
        // -[AUAudioUnit dealloc] runs after this body and calls our
        // deallocateRenderResources if resources are still allocated, which
        // would touch `input` after it is freed. Release them first.
        if renderResourcesAllocated { deallocateRenderResources() }
        input.pointee.samples?.deallocate()
        free(input.pointee.bufferList.unsafeMutablePointer)
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
        let channels = Int(inputBus.format.channelCount)
        input.pointee.samples?.deallocate()
        input.pointee.samples = .allocate(capacity: channels * Int(maximumFramesToRender))
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

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Capture only raw pointers, so the body does no ARC, locking or
        // allocation. `engine` (and so the analyzer) and `input` outlive
        // rendering because this AU owns them. Swift still bridges the host's
        // pullInputBlock into a closure on every call (a small malloc/free
        // plus refcounting); only a render block written in C/ObjC avoids that.
        let analyzer = engine.live.raw
        let input = self.input
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            let state = input.pointee
            guard frameCount <= state.maxFrames, let samples = state.samples else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }

            // Point the input list at our storage every cycle: the previous
            // pull may have replaced mData with upstream's own buffers.
            let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            let inBuffers = state.bufferList
            inBuffers.count = state.channelCount
            for ch in 0..<state.channelCount {
                inBuffers[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize,
                                            mData: samples + ch * Int(state.maxFrames))
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inBuffers.unsafeMutablePointer)
            guard status == noErr else { return status }

            // Pass through: in place when the host asked for it (NULL mData), else copy.
            let outBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            for ch in 0..<min(outBuffers.count, inBuffers.count) {
                guard let src = inBuffers[ch].mData else { return kAudioUnitErr_NoConnection }
                if let dst = outBuffers[ch].mData {
                    if dst != src { memcpy(dst, src, Int(byteSize)) }
                } else {
                    outBuffers[ch].mData = src
                }
                outBuffers[ch].mDataByteSize = byteSize
            }

            guard let left = inBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = inBuffers.count > 1 ? inBuffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
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
