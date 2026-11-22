#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "Signal.h"

NS_ASSUME_NONNULL_BEGIN
NSArray<NSNumber *> *LXObjects(AudioObjectID object, AudioObjectPropertySelector selector,
                               AudioObjectPropertyScope scope);
NSString * _Nullable LXString(AudioObjectID object, AudioObjectPropertySelector selector);
UInt32 LXNumber(AudioObjectID object, AudioObjectPropertySelector selector);
double LXRate(AudioObjectID device);
NSString *LXInputUID(NSString *appKey);

@interface LXInput : NSObject
+ (BOOL)configure:(NSString *)appKey name:(NSString *)name source:(NSString * _Nullable)source
            error:(NSError **)error NS_SWIFT_NAME(configure(appKey:name:source:));
@end

@interface LXRoute : NSObject
- (BOOL)startWithProcesses:(NSArray<NSNumber *> *)processes output:(AudioDeviceID)output
                    volume:(float)volume muted:(BOOL)muted bands:(NSArray<NSNumber *> *)bands
                     error:(NSError **)error NS_SWIFT_NAME(start(processes:output:volume:muted:bands:));
- (void)adjust:(float)volume muted:(BOOL)muted bands:(NSArray<NSNumber *> *)bands;
- (void)stop;
@property (nonatomic, readonly) float peak;
@property (nonatomic, readonly) BOOL clockChanged;
@end
NS_ASSUME_NONNULL_END
