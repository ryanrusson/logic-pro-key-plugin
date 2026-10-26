#import "RenderBlock.h"

// Without ARC, KFMakeRenderBlock would return a stack block.
#if !__has_feature(objc_arc)
#error RenderBlock.m must be compiled with -fobjc-arc
#endif

AUInternalRenderBlock KFMakeRenderBlock(KFRenderInput *input, const KFAnalyzer *analyzer) {
    // objc_externally_retained: the host keeps pullInputBlock alive for the
    // call, so ARC mustn't retain and release it on the render thread.
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber,
                              AudioBufferList *outputData, const AURenderEvent *_Nullable realtimeEventListHead,
                              AURenderPullInputBlock _Nullable pullInputBlock)
                              __attribute__((objc_externally_retained)) {
        const KFRenderInput state = *input;
        if (frameCount > state.maxFrames || !state.samples) return kAudioUnitErr_TooManyFramesToProcess;
        if (!pullInputBlock) return kAudioUnitErr_NoConnection;

        // Point the input list at our storage every cycle: the previous
        // pull may have replaced mData with upstream's own buffers.
        const UInt32 byteSize = frameCount * (UInt32)sizeof(float);
        AudioBufferList *inBuffers = state.bufferList;
        inBuffers->mNumberBuffers = state.channelCount;
        for (UInt32 ch = 0; ch < state.channelCount; ch++) {
            inBuffers->mBuffers[ch] = (AudioBuffer){
                .mNumberChannels = 1, .mDataByteSize = byteSize, .mData = state.samples + ch * state.maxFrames};
        }
        AudioUnitRenderActionFlags pullFlags = 0;
        const AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inBuffers);
        if (status != noErr) return status;

        // Pass through: in place when the host asked for it (NULL mData), else copy.
        const UInt32 channels = MIN(outputData->mNumberBuffers, inBuffers->mNumberBuffers);
        for (UInt32 ch = 0; ch < channels; ch++) {
            void *src = inBuffers->mBuffers[ch].mData;
            if (!src) return kAudioUnitErr_NoConnection;
            AudioBuffer *dst = &outputData->mBuffers[ch];
            if (!dst->mData) {
                dst->mData = src;
            } else if (dst->mData != src) {
                memcpy(dst->mData, src, byteSize);
            }
            dst->mDataByteSize = byteSize;
        }

        if (inBuffers->mNumberBuffers == 0 || !inBuffers->mBuffers[0].mData) return noErr;
        const float *right = inBuffers->mNumberBuffers > 1 ? inBuffers->mBuffers[1].mData : NULL;
        kf_analyzer_push(analyzer, inBuffers->mBuffers[0].mData, right, frameCount);
        return noErr;
    };
}

@implementation KFAudioUnitBase

- (KFRenderInput *)renderInput {
    [self doesNotRecognizeSelector:_cmd];
    __builtin_unreachable();
}

- (const KFAnalyzer *)renderAnalyzer {
    [self doesNotRecognizeSelector:_cmd];
    __builtin_unreachable();
}

- (AUInternalRenderBlock)internalRenderBlock {
    return KFMakeRenderBlock(self.renderInput, self.renderAnalyzer);
}

@end
