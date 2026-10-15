//
//  VMRoute.m
//  虚拟麦克风 App —— 把「文件」接到「虚拟声卡」
//

#import "VMRoute.h"
#import <Accelerate/Accelerate.h>

// 渲染回调每次要的帧数。512 在延迟和稳定性之间比较平衡；
// 太小（如 64）会频繁触发，太大（如 4096）会明显延迟。
static const UInt32 kRenderFrames = 512;

@implementation VMRoute {
    AudioUnit _outputUnit;      // 往虚拟声卡的 Output 侧写
    AudioUnit _inputUnit;       // 可选：从 Input 侧读回来做自检
    VMAudioFilePlayer *_player; // 不强引用，避免和持有者形成环

    BOOL _running;
    float _peak;
    float _loopbackPeakStore;
    uint64_t _loopbackFramesCaptured;
    uint64_t _framesSentToDevice;
}

#pragma mark - 初始化

- (nullable instancetype)initWithSinkDevice:(VMDeviceInfo *)device {
    if (device == nil || device.outputChannels == 0) {
        NSLog(@"[路由] 设备无效或没有输出通道");
        return nil;
    }
    if ((self = [super init])) {
        _sinkDevice = device;
        _peak = 0.0f;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_outputUnit) AudioComponentInstanceDispose(_outputUnit);
    if (_inputUnit)  AudioComponentInstanceDispose(_inputUnit);
}

#pragma mark - 渲染回调

/// 输出侧回调：CoreAudio 说"给我 kRenderFrames 帧"，我们从播放器拉。
static OSStatus VMRenderCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    VMRoute *self = (__bridge VMRoute *)inRefCon;
    return [self renderOutputWithFlags:ioActionFlags frames:inNumberFrames data:ioData];
}

- (OSStatus)renderOutputWithFlags:(AudioUnitRenderActionFlags *)flags
                           frames:(UInt32)frames
                             data:(AudioBufferList *)ioData {
    if (_player == nil) {
        // 没有播放器就输出静音（不要 return 错误，否则会 log 刷屏）
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    // 设备格式是 Float32 interleaved / 2ch（已实测确认），
    // 所以直接交给播放器填。如果换到别的设备格式，这里需要加转换。
    [_player renderFrames:frames into:ioData];

    // 顺便算一下峰值，给 UI 用电平表
    float peak = 0.0f;
    const float *samples = (const float *)ioData->mBuffers[0].mData;
    if (samples) {
        vDSP_maxmgv(samples, 1, &peak,
                    (vDSP_Length)(frames * self->_player.targetChannels));
    }
    // 平滑一下，否则电平表跳得厉害
    _peak = (_peak * 0.8f) + (peak * 0.2f);
    _framesSentToDevice += frames;

    return noErr;
}

/// 输入侧回调：只是把声音读回来丢掉，用来证明"写进去的东西确实能读出来"。
static OSStatus VMCaptureCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    VMRoute *self = (__bridge VMRoute *)inRefCon;

    // 必须先 render 才能拿到数据（输入侧的数据不是"送进来"的，是"拉出来"的）
    AudioBufferList bufList = {0};
    // 固定大小，不用 VLA —— 实时线程上 VLA 会带来不必要的栈操作
    float scratch[8192];
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = 2;
    bufList.mBuffers[0].mDataByteSize = inNumberFrames * 2 * sizeof(float);
    bufList.mBuffers[0].mData = scratch;

    AudioUnitRender(self->_inputUnit, ioActionFlags, inTimeStamp, inBusNumber,
                    inNumberFrames, &bufList);

    float peak = 0.0f;
    vDSP_maxmgv(scratch, 1, &peak, (vDSP_Length)(inNumberFrames * 2));
    if (peak > 0.0001f) {
        self->_loopbackFramesCaptured += inNumberFrames;
        self->_loopbackPeakStore = peak;
    }
    return noErr;
}

#pragma mark - 启动

- (BOOL)startWithPlayer:(VMAudioFilePlayer *)player error:(NSError **)error {
    if (_running) return NO;   // 已经在跑
    _player = player;

    AudioDeviceID devID = _sinkDevice.deviceID;

    // ---------- 1. 输出单元 ----------
    AudioComponentDescription desc = {0};
    desc.componentType         = kAudioUnitType_Output;
    desc.componentSubType      = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        if (error) *error = [self errorWithMessage:@"找不到 HALOutput AudioUnit"];
        return NO;
    }
    OSStatus st = AudioComponentInstanceNew(comp, &_outputUnit);
    if (st != noErr) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"创建 AudioUnit 失败 (%d)", (int)st]];
        return NO;
    }

    // 绑到目标设备
    if (![VMAudioDevice bindDevice:devID toUnit:_outputUnit bus:0]) {
        if (error) *error = [self errorWithMessage:@"绑定虚拟声卡失败（可能被别的 App 独占）"];
        return NO;
    }

    // HALOutput 默认输出侧就是开的，但显式设一遍更稳
    UInt32 enable = 1;
    AudioUnitSetProperty(_outputUnit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Output, 0, &enable, sizeof(enable));

    // 设成浮点 interleaved —— 与设备格式一致（实测 48000/2ch/Float32）
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate       = _sinkDevice.sampleRate > 0 ? _sinkDevice.sampleRate : 48000.0;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel   = 32;
    fmt.mBytesPerFrame    = sizeof(float) * 2;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = fmt.mBytesPerFrame;

    st = AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (st != noErr) {
        NSLog(@"[路由] 设置输出格式失败 (%d)，改用设备原生格式", (int)st);
        AudioStreamBasicDescription native = {0};
        if ([VMAudioDevice getStreamFormat:&native forDevice:devID
                                     scope:kAudioObjectPropertyScopeOutput]) {
            AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0, &native, sizeof(native));
        }
    }

    // 挂渲染回调
    AURenderCallbackStruct cb = {0};
    cb.inputProc       = VMRenderCallback;
    cb.inputProcRefCon = (__bridge void *)self;
    st = AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (st != noErr) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"挂渲染回调失败 (%d)", (int)st]];
        return NO;
    }

    // 缓冲大小：调大一点更稳（模拟"低延迟"需求不适用于推文件）
    UInt32 bufFrames = kRenderFrames;
    AudioObjectPropertyAddress bufAddr = {
        .mSelector = kAudioDevicePropertyBufferFrameSize,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    AudioObjectSetPropertyData(devID, &bufAddr, 0, NULL, sizeof(bufFrames), &bufFrames);

    // ---------- 2. 可选：输入侧自检 ----------
    if (self.captureLoopback) {
        AudioComponentInstanceNew(comp, &_inputUnit);
        if (_inputUnit) {
            if ([VMAudioDevice bindDevice:devID toUnit:_inputUnit bus:0]) {
                UInt32 on = 1;
                AudioUnitSetProperty(_inputUnit, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &on, sizeof(on));
                AudioUnitSetProperty(_inputUnit, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
                AURenderCallbackStruct icb = {0};
                icb.inputProc       = VMCaptureCallback;
                icb.inputProcRefCon = (__bridge void *)self;
                AudioUnitSetProperty(_inputUnit, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 1, &icb, sizeof(icb));
                if (AudioUnitInitialize(_inputUnit) != noErr) {
                    NSLog(@"[路由] 输入侧初始化失败，跳过自检");
                    AudioComponentInstanceDispose(_inputUnit);
                    _inputUnit = NULL;
                }
            } else {
                AudioComponentInstanceDispose(_inputUnit);
                _inputUnit = NULL;
            }
        }
    }

    // ---------- 3. 跑起来 ----------
    st = AudioUnitInitialize(_outputUnit);
    if (st != noErr) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"AudioUnitInitialize 失败 (%d)", (int)st]];
        return NO;
    }
    st = AudioOutputUnitStart(_outputUnit);
    if (st != noErr) {
        if (error) *error = [self errorWithMessage:[NSString stringWithFormat:@"AudioOutputUnitStart 失败 (%d)", (int)st]];
        return NO;
    }
    if (_inputUnit) AudioOutputUnitStart(_inputUnit);

    _running = YES;
    return YES;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_inputUnit) {
        AudioOutputUnitStop(_inputUnit);
        AudioUnitUninitialize(_inputUnit);
    }
    if (_outputUnit) {
        AudioOutputUnitStop(_outputUnit);
        AudioUnitUninitialize(_outputUnit);
    }
    _player = nil;
}

#pragma mark - 电平

- (float)peakLevel {
    return _peak;
}

- (uint64_t)framesSentToDevice {
    return _framesSentToDevice;
}

- (BOOL)isRunning {
    return _running;
}

- (float)loopbackPeak {
    return _loopbackPeakStore;
}

- (uint64_t)loopbackFramesCaptured {
    return _loopbackFramesCaptured;
}

- (NSError *)errorWithMessage:(NSString *)msg {
    return [NSError errorWithDomain:@"VMRoute" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
