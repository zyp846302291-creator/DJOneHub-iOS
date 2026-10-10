#import <AVFoundation/AVFoundation.h>

/// ObjC wrapper that catches NSException from installTap,
/// which Swift's do-catch cannot handle.
@interface SafeAudioTap : NSObject
+ (BOOL)safeInstallTapWithNode:(AVAudioInputNode *)node
                           bus:(AVAudioFrameCount)bus
                    bufferSize:(AVAudioFrameCount)bufferSize
                        format:(AVAudioFormat *)format
                         block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block;
@end