// The Audio Unit's render path, in Objective-C so the host's blocks never
// pass through Swift. Also the AU target's Swift bridging header.
#import <AudioToolbox/AudioToolbox.h>
#include <keyfinder.h>

NS_ASSUME_NONNULL_BEGIN

/// Input buffers the render block pulls into. AURenderPullInputBlock needs
/// caller-owned buffers, and the host's output buffers may have NULL mData
/// (in-place request), so they can't be used for the pull.
typedef struct {
    AUAudioFrameCount maxFrames;
    UInt32 channelCount;
    float *_Nullable samples;    // planar, channelCount * maxFrames
    AudioBufferList *bufferList; // room for 2 buffers
} KFRenderInput;

/// Pass-through render block that also pushes the input to `analyzer`. It
/// captures only these two pointers, so a render call does no ARC, locking
/// or allocation. Both must outlive rendering.
AUInternalRenderBlock KFMakeRenderBlock(KFRenderInput *input, const KFAnalyzer *analyzer);

/// Vends KFMakeRenderBlock's block as internalRenderBlock. A Swift override
/// can't: Swift turns the block into a closure and back into a new block,
/// whose invoke converts the host's pullInputBlock to a closure on every
/// render call (_Block_copy, swift_allocObject, swift_retain/release).
@interface KFAudioUnitBase : AUAudioUnit
/// Abstract: subclasses override both. Read when the host fetches the
/// render block, possibly before allocateRenderResources.
@property (nonatomic, readonly) KFRenderInput *renderInput;
@property (nonatomic, readonly) const KFAnalyzer *renderAnalyzer;
@end

NS_ASSUME_NONNULL_END
