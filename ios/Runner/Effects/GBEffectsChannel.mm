#import "GBEffectsChannel.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#include "../../../native/mobile_effects/engine.h"
#include <map>

namespace {
void check(OSStatus code) {
    if (code != noErr) throw juce::String::fromUTF8("音频设备操作失败：") + juce::String(code);
}
class IOSEngine final : public guitarbook::Engine {
public:
    ~IOSEngine() override { close(); }
    void open() override {
        AVAudioSession* session = AVAudioSession.sharedInstance;
        NSError* error = nil;
        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeMeasurement
                         options:AVAudioSessionCategoryOptionMixWithOthers error:&error]
            || ![session setPreferredSampleRate:48000 error:&error]
            || ![session setPreferredIOBufferDuration:requestedBuffer / 48000.0 error:&error]
            || ![session setActive:YES error:&error])
            throw juce::String::fromUTF8(error.localizedDescription.UTF8String);
        if (!session.inputAvailable) throw juce::String::fromUTF8("没有可用音频输入，请连接声卡并检查麦克风权限。");
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_RemoteIO;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        auto component = AudioComponentFindNext(nullptr, &description);
        if (!component) throw juce::String::fromUTF8("无法创建 RemoteIO 音频设备。");
        check(AudioComponentInstanceNew(component, &unit));
        UInt32 enable = 1;
        check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, sizeof(enable)));
        const double sampleRate = session.sampleRate;
        AudioStreamBasicDescription format{};
        format.mSampleRate = sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
        format.mFramesPerPacket = 1;
        format.mBitsPerChannel = 32;
        format.mChannelsPerFrame = 1;
        format.mBytesPerFrame = format.mBytesPerPacket = sizeof(float);
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format)));
        format.mChannelsPerFrame = 2;
        format.mBytesPerFrame = format.mBytesPerPacket = 2 * sizeof(float);
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)));
        UInt32 maxFrames = capacity;
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)));
        AURenderCallbackStruct callback{render, this};
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)));
        prepare(sampleRate, int(std::round(session.IOBufferDuration * sampleRate)));
        check(AudioUnitInitialize(unit));
        check(AudioOutputUnitStart(unit));
    }
    void close() override {
        stopped(failed);
        if (unit) {
            AudioOutputUnitStop(unit);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
            unit = nullptr;
        }
        // The session is shared with drum/Looper playback. Closing RemoteIO
        // releases our input without deactivating another tool's audio session.
    }
    juce::var deviceStatus() override {
        if (failed && unit) close();
        AVAudioSession* session = AVAudioSession.sharedInstance;
        auto route = session.currentRoute;
        auto inputName = route.inputs.firstObject.portName ?: @"";
        auto outputName = route.outputs.firstObject.portName ?: @"";
        return guitarbook::object({{"audioOpen", unit != nullptr && !failed}, {"backend", "RemoteIO"},
            {"device", juce::String::fromUTF8(outputName.UTF8String)},
            {"inputDevice", juce::String::fromUTF8(inputName.UTF8String)},
            {"outputDevice", juce::String::fromUTF8(outputName.UTF8String)},
            {"inputLatencyMs", session.inputLatency * 1000}, {"outputLatencyMs", session.outputLatency * 1000},
            {"latencyMs", (session.inputLatency + session.outputLatency) * 1000},
            {"latencyAvailable", true}, {"cpuAvailable", false}, {"xruns", -1}});
    }
private:
    static OSStatus render(void* context, AudioUnitRenderActionFlags* flags,
                           const AudioTimeStamp* time, UInt32, UInt32 frames, AudioBufferList* output) {
        auto& self = *static_cast<IOSEngine*>(context);
        for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
            if (output->mBuffers[i].mData) std::memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
        if (!self.running || self.failed) return noErr;
        if (frames > capacity || output->mNumberBuffers != 1 || output->mBuffers[0].mNumberChannels != 2
            || output->mBuffers[0].mData == nullptr) { self.stopped(true); return noErr; }
        AudioBufferList input{};
        input.mNumberBuffers = 1;
        input.mBuffers[0] = {1, frames * UInt32(sizeof(float)), self.input.data()};
        if (AudioUnitRender(self.unit, flags, time, 1, frames, &input) != noErr) {
            self.stopped(true);
            return noErr;
        }
        self.process(self.input.data(), int(frames), static_cast<float*>(output->mBuffers[0].mData), int(frames));
        return noErr;
    }
    AudioUnit unit = nullptr;
    std::array<float, capacity> input{};
};
}

@implementation GBEffectsChannel {
    std::map<std::string, std::unique_ptr<IOSEngine>> _engines;
    FlutterMethodChannel* _channel;
    NSUInteger _revision;
    BOOL _foreground;
    BOOL _authorizing;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    GBEffectsChannel* instance = [[GBEffectsChannel alloc] init];
    instance->_foreground = YES;
    instance->_channel = [FlutterMethodChannel methodChannelWithName:@"guitarbook/effects" binaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:instance channel:instance->_channel];
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserver:instance selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:instance selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:instance selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:instance selector:@selector(route:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:instance selector:@selector(interruption:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [center addObserver:instance selector:@selector(interruption:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)background:(NSNotification*)note { _foreground = NO; [self interrupt]; }
- (void)foreground:(NSNotification*)note { _foreground = YES; }
- (void)interruption:(NSNotification*)note { [self interrupt]; }
- (void)route:(NSNotification*)note {
    NSInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable
        || reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable
        || reason == AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory) [self interrupt];
}
- (void)interrupt {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self interrupt]; });
        return;
    }
    ++_revision;
    for (auto& pair : _engines) pair.second->close();
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary* args = call.arguments;
    NSString* session = args[@"session"];
    if (![session isKindOfClass:NSString.class]) { result([FlutterError errorWithCode:@"session" message:@"无效效果器会话。" details:nil]); return; }
    std::string key(session.UTF8String);
    if ([call.method isEqualToString:@"dispose"]) {
        ++_revision;
        _engines.erase(key);
        result(nil);
        return;
    }
    if (![call.method isEqualToString:@"command"]) { result(FlutterMethodNotImplemented); return; }
    NSString* command = args[@"command"];
    if ([command isEqualToString:@"stop"]) ++_revision;
    if ([command isEqualToString:@"start"] || [command isEqualToString:@"probe"]) {
        if (!_foreground) { result([FlutterError errorWithCode:@"background" message:@"请回到前台后手动开始监听。" details:nil]); return; }
        if (AVAudioSession.sharedInstance.recordPermission != AVAudioSessionRecordPermissionGranted) {
            if (_authorizing) { result([FlutterError errorWithCode:@"permission" message:@"请先完成录音授权。" details:nil]); return; }
            _authorizing = YES;
            const NSUInteger revision = _revision;
            [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_authorizing = NO;
                    if (granted && self->_foreground && revision == self->_revision) [self handleMethodCall:call result:result];
                    else result([FlutterError errorWithCode:@"permission" message:@"未获得录音权限或监听已取消，请回到前台授权后重试。" details:nil]);
                });
            }];
            return;
        }
    }
    auto& engine = _engines[key];
    if (!engine) engine = std::make_unique<IOSEngine>();
    NSData* json = [NSJSONSerialization dataWithJSONObject:args options:0 error:nullptr];
    auto response = engine->dispatch(juce::String::fromUTF8(static_cast<const char*>(json.bytes), int(json.length)));
    result([NSString stringWithUTF8String:response.toRawUTF8()]);
}
@end
