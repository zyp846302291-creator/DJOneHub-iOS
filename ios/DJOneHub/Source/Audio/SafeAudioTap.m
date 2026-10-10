#import "SafeAudioTap.h"

@implementation SafeAudioTap

+ (BOOL)safeInstallTapWithNode:(AVAudioInputNode *)node
                           bus:(AVAudioFrameCount)bus
                    bufferSize:(AVAudioFrameCount)bufferSize
                        format:(AVAudioFormat *)format
                         block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[SafeAudioTap] installTap exception: %@ - %@", exception.name, exception.reason);
        return NO;
    }
}

@end