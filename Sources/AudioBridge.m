#import "AudioBridge.h"
#import <AudioToolbox/AudioFormat.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <unistd.h>

static AudioObjectPropertyAddress address(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){sel, scope, kAudioObjectPropertyElementMain};
}
static OSStatus readGlobal(AudioObjectID obj, AudioObjectPropertySelector sel, void *dst, UInt32 size) {
    AudioObjectPropertyAddress a = address(sel, kAudioObjectPropertyScopeGlobal);
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, dst);
}
NSArray<NSNumber *> *LXObjects(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = address(sel, scope);
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &bytes) || !bytes) return @[];
    NSMutableData *storage = [NSMutableData dataWithLength:bytes];
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &bytes, storage.mutableBytes)) return @[];
    const AudioObjectID *items = storage.bytes;
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < bytes / sizeof(*items); i++) [result addObject:@(items[i])];
    return result;
}
NSString *LXString(AudioObjectID obj, AudioObjectPropertySelector sel) {
    CFStringRef result = NULL;
    return readGlobal(obj, sel, &result, sizeof(result)) ? nil : CFBridgingRelease(result);
}
UInt32 LXNumber(AudioObjectID obj, AudioObjectPropertySelector sel) {
    UInt32 result = 0;
    readGlobal(obj, sel, &result, sizeof(result));
    return result;
}
double LXRate(AudioObjectID device) {
    double rate = 0;
    readGlobal(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate));
    return rate;
}
static BOOL fail(NSError **error, NSString *operation, OSStatus code) {
    if (error) *error = [NSError errorWithDomain:@"audio.larix" code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (Core Audio %d).", operation, (int)code]
    }];
    return NO;
}
NSString *LXInputUID(NSString *appKey) { return [@"audio.larix.input." stringByAppendingString:appKey]; }

static AudioDeviceID deviceForUID(NSString *uid) {
    for (NSNumber *item in LXObjects(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)) {
        if ([LXString(item.unsignedIntValue, kAudioDevicePropertyDeviceUID) isEqual:uid]) return item.unsignedIntValue;
    }
    return kAudioObjectUnknown;
}
static OSStatus setMembers(AudioDeviceID aggregate, NSArray *members) {
    CFArrayRef list = (__bridge CFArrayRef)members;
    AudioObjectPropertyAddress a = address(kAudioAggregateDevicePropertyFullSubDeviceList, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(aggregate, &a, 0, NULL, sizeof(list), &list);
}

@implementation LXInput
+ (BOOL)configure:(NSString *)appKey name:(NSString *)name source:(NSString *)source error:(NSError **)error {
    NSString *uid = LXInputUID(appKey);
    AudioDeviceID existing = deviceForUID(uid);
    BOOL created = !existing;
    NSArray *previous = nil;
    OSStatus status = noErr;
    if (!source) {
        if (existing) status = AudioHardwareDestroyAggregateDevice(existing);
    } else if (existing) {
        // A single subdevice is its own clock source. Keep the endpoint UID across switches.
        CFArrayRef saved = NULL;
        status = readGlobal(existing, kAudioAggregateDevicePropertyFullSubDeviceList, &saved, sizeof(saved));
        if (!status) {
            previous = CFBridgingRelease(saved);
            status = setMembers(existing, @[source]);
        }
    } else {
        NSDictionary *config = @{
            @kAudioAggregateDeviceUIDKey: uid, @kAudioAggregateDeviceNameKey: name,
            @kAudioAggregateDeviceIsPrivateKey: @NO,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: source}]
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &existing);
    }
    if (!status && source) {
        // The HAL publishes the device and activates its streams asynchronously.
        AudioDeviceID physical = deviceForUID(source);
        for (unsigned attempt = 0; attempt < 75; attempt++) {
            if (deviceForUID(uid) == existing && physical &&
                [LXObjects(existing, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal) containsObject:@(physical)] &&
                LXObjects(existing, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count) return YES;
            usleep(20000);
        }
        if (created) AudioHardwareDestroyAggregateDevice(existing);
        else if (previous) setMembers(existing, previous);
        return fail(error, @"The microphone did not become available", kAudioHardwareNotRunningError);
    }
    return status == noErr || fail(error, @"Couldn’t update the microphone route", status);
}
@end

typedef struct {
    LXSignal *signal;
    unsigned channels;
    bool planar;
} Capture;

static OSStatus captureAudio(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                             const AudioTimeStamp *inputTime, AudioBufferList *out,
                             const AudioTimeStamp *outTime, void *context) {
    Capture *c = context;
    if (!input || !input->mNumberBuffers) return noErr;
    const AudioBuffer *first = &input->mBuffers[0];
    const float *left = first->mData, *right = left;
    if (!left || !first->mNumberChannels) return noErr;
    unsigned stride = first->mNumberChannels, frames = first->mDataByteSize / (stride * sizeof(float));
    if (c->planar && c->channels > 1) {
        if (input->mNumberBuffers < 2 || !input->mBuffers[1].mData) return noErr;
        right = input->mBuffers[1].mData;
        frames = MIN(frames, input->mBuffers[1].mDataByteSize / sizeof(float));
    } else if (stride > 1) right = left + 1;
    LXSignalPush(c->signal, left, right, stride, frames);
    return noErr;
}
static OSStatus renderAudio(void *ctx, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (data && data->mNumberBuffers == 1) {
        AudioBuffer *b = &data->mBuffers[0];
        if (b->mData && b->mNumberChannels && frames <= b->mDataByteSize / (sizeof(float) * b->mNumberChannels))
            LXSignalRender(ctx, b->mData, b->mNumberChannels, frames);
    }
    return noErr;
}

@implementation LXRoute {
    AudioObjectID _tap, _aggregate, _output;
    AudioDeviceIOProcID _captureProc;
    AudioUnit _player;
    Capture _capture;
    double _sourceRate, _outputRate;
}
- (BOOL)startWithProcesses:(NSArray<NSNumber *> *)processes output:(AudioDeviceID)output
                    volume:(float)volume muted:(BOOL)muted bands:(NSArray<NSNumber *> *)bands error:(NSError **)error {
    [self stop];
    CATapDescription *desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    desc.name = @"Larix playback";
    desc.privateTap = YES;
    desc.muteBehavior = CATapMutedWhenTapped;
    NSString *operation = @"Allow Larix in Privacy & Security → Screen & System Audio Recording, then retry";
    OSStatus status = AudioHardwareCreateProcessTap(desc, &_tap);
    if (status) goto failed;
    {
        NSDictionary *config = @{
            @kAudioAggregateDeviceUIDKey: [@"audio.larix.playback." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceNameKey: @"Larix playback", @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: desc.UUID.UUIDString,
                                                   @kAudioSubTapDriftCompensationKey: @YES}]
        };
        operation = @"Couldn’t open the playback tap";
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &_aggregate);
        if (status) goto failed;
    }
    {
        AudioStreamBasicDescription format = {0};
        for (unsigned attempt = 0; attempt < 75; attempt++) {
            AudioObjectID stream = LXObjects(_aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).firstObject.unsignedIntValue;
            status = readGlobal(stream, kAudioStreamPropertyVirtualFormat, &format, sizeof(format));
            if (!status && format.mSampleRate > 0) break;
            usleep(20000);
        }
        if (status) goto failed;
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat)
            || format.mBitsPerChannel != 32 || !format.mChannelsPerFrame || format.mChannelsPerFrame > 2) {
            operation = @"The playback tap supplied an unsupported sample format";
            status = kAudioFormatUnsupportedDataFormatError;
            goto failed;
        }
        _sourceRate = format.mSampleRate;
        _capture.planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        _capture.channels = format.mChannelsPerFrame;
    }
    {
        operation = @"Couldn’t open the output device";
        AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(NULL, &desc);
        if (!component) { status = kAudioUnitErr_FailedInitialization; goto failed; }
        status = AudioComponentInstanceNew(component, &_player);
        if (status) goto failed;
        _output = output;
        status = AudioUnitSetProperty(_player, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &output, sizeof(output));
        if (status) goto failed;
        AudioStreamBasicDescription format = {0};
        UInt32 bytes = sizeof(format);
        status = AudioUnitGetProperty(_player, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &bytes);
        if (status) goto failed;
        _outputRate = format.mSampleRate;
        UInt32 channels = MIN(2u, format.mChannelsPerFrame);
        if (!channels) { status = kAudioUnitErr_FormatNotSupported; goto failed; }
        format = (AudioStreamBasicDescription){_outputRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked,
                                               channels * 4, 1, channels * 4, channels, 32, 0};
        status = AudioUnitSetProperty(_player, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
        if (status) goto failed;
        _capture.signal = LXSignalCreate(_sourceRate, _outputRate);
        if (!_capture.signal) { status = kAudioUnitErr_FormatNotSupported; goto failed; }
        [self adjust:volume muted:muted bands:bands];
        AURenderCallbackStruct callback = {renderAudio, _capture.signal};
        status = AudioUnitSetProperty(_player, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
        if (status) goto failed;
        status = AudioUnitInitialize(_player);
        if (status) goto failed;
        status = AudioOutputUnitStart(_player);
        if (status) goto failed;
    }
    operation = @"Couldn’t start playback capture. Check System Audio Recording permission";
    status = AudioDeviceCreateIOProcID(_aggregate, captureAudio, &_capture, &_captureProc);
    if (status) goto failed;
    status = AudioDeviceStart(_aggregate, _captureProc);
    if (!status) return YES;
failed:
    [self stop];
    return fail(error, operation, status);
}
- (void)adjust:(float)volume muted:(BOOL)muted bands:(NSArray<NSNumber *> *)bands {
    if (!_capture.signal) return;
    float gains[LX_BANDS] = {0};
    for (unsigned i = 0; i < MIN(LX_BANDS, bands.count); i++) gains[i] = bands[i].floatValue;
    LXSignalSet(_capture.signal, volume, muted, gains);
}
- (float)peak { return _capture.signal ? LXSignalPeak(_capture.signal) : 0; }
- (BOOL)clockChanged {
    return _aggregate && (LXRate(_aggregate) != _sourceRate || LXRate(_output) != _outputRate);
}
- (void)stop {
    if (_captureProc) {
        AudioDeviceStop(_aggregate, _captureProc);
        AudioDeviceDestroyIOProcID(_aggregate, _captureProc);
        _captureProc = NULL;
    }
    if (_player) {
        AudioOutputUnitStop(_player);
        AudioUnitUninitialize(_player);
        AudioComponentInstanceDispose(_player);
        _player = NULL;
    }
    if (_aggregate) { AudioHardwareDestroyAggregateDevice(_aggregate); _aggregate = 0; }
    if (_tap) { AudioHardwareDestroyProcessTap(_tap); _tap = 0; }
    LXSignalDestroy(_capture.signal);
    _capture.signal = NULL;
}
- (void)dealloc { [self stop]; }
@end
