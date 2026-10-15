//
//  VMAudioDevice.m
//  虚拟麦克风 App —— CoreAudio 设备定位工具
//

#import "VMAudioDevice.h"

#pragma mark - 属性读取小工具

/// 读一个 CFString 属性（如 name / UID）
static NSString *VMCopyStringProperty(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress addr = {
        .mSelector = sel,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus st = AudioObjectGetPropertyData(obj, &addr, 0, NULL, &size, &value);
    if (st != noErr || value == NULL) return @"";
    NSString *s = [NSString stringWithString:(__bridge NSString *)value];
    CFRelease(value);
    return s;
}

/// 读一个 UInt32 属性
static UInt32 VMReadUInt32(AudioObjectID obj, AudioObjectPropertySelector sel,
                           AudioObjectPropertyScope scope, BOOL *ok) {
    AudioObjectPropertyAddress addr = {
        .mSelector = sel, .mScope = scope, .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 value = 0, size = sizeof(value);
    OSStatus st = AudioObjectGetPropertyData(obj, &addr, 0, NULL, &size, &value);
    if (ok) *ok = (st == noErr);
    return value;
}

/// 统计某个方向的通道数：把 StreamConfiguration 里所有 buffer 的通道数加起来
static UInt32 VMChannelCount(AudioDeviceID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope    = scope,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size) != noErr || size == 0) return 0;

    // 用 alloca 风格的可变长度缓冲；设备通道数不会大到需要堆分配
    AudioBufferList *list = (AudioBufferList *)malloc(size);
    if (!list) return 0;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            channels += list->mBuffers[i].mNumberChannels;
        }
    }
    free(list);
    return channels;
}


#pragma mark - VMDeviceInfo

@implementation VMDeviceInfo

- (NSString *)description {
    return [NSString stringWithFormat:@"<VMDeviceInfo id=%u \"%@\" in=%u out=%u %.0fHz virtual=%@>",
            self.deviceID, self.name, self.inputChannels, self.outputChannels,
            self.sampleRate, self.isVirtual ? @"YES" : @"NO"];
}

/// 一个设备是否"像"虚拟声卡：双层（既输入又输出）+ 传输方式是 Virtual
- (BOOL)looksLikeLoopback {
    return self.inputChannels > 0 && self.outputChannels > 0;
}

@end


#pragma mark - VMAudioDevice

@implementation VMAudioDevice

+ (NSArray<VMDeviceInfo *> *)allDevices {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) {
        return @[];
    }
    UInt32 count = size / sizeof(AudioDeviceID);
    if (count == 0) return @[];

    AudioDeviceID *ids = (AudioDeviceID *)malloc(size);
    if (!ids) return @[];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids) != noErr) {
        free(ids);
        return @[];
    }

    NSMutableArray<VMDeviceInfo *> *result = [NSMutableArray arrayWithCapacity:count];
    for (UInt32 i = 0; i < count; i++) {
        VMDeviceInfo *info = [[VMDeviceInfo alloc] init];
        info.deviceID       = ids[i];
        info.name           = VMCopyStringProperty(ids[i], kAudioObjectPropertyName);
        info.uid            = VMCopyStringProperty(ids[i], kAudioDevicePropertyDeviceUID);
        info.inputChannels  = VMChannelCount(ids[i], kAudioObjectPropertyScopeInput);
        info.outputChannels = VMChannelCount(ids[i], kAudioObjectPropertyScopeOutput);

        AudioObjectPropertyAddress rateAddr = {
            .mSelector = kAudioDevicePropertyNominalSampleRate,
            .mScope    = kAudioObjectPropertyScopeGlobal,
            .mElement  = kAudioObjectPropertyElementMain,
        };
        Float64 rate = 0;
        UInt32 rateSize = sizeof(rate);
        if (AudioObjectGetPropertyData(ids[i], &rateAddr, 0, NULL, &rateSize, &rate) == noErr) {
            info.sampleRate = rate;
        }

        // Transport Type: kAudioDevicePropertyTransportType == 'vir ' 时是虚拟设备
        BOOL ok = NO;
        UInt32 transport = VMReadUInt32(ids[i], kAudioDevicePropertyTransportType,
                                        kAudioObjectPropertyScopeGlobal, &ok);
        info.isVirtual = ok && (transport == kAudioDeviceTransportTypeVirtual);

        [result addObject:info];
    }
    free(ids);
    return result;
}

+ (NSArray<VMDeviceInfo *> *)loopbackDevices {
    NSMutableArray<VMDeviceInfo *> *out = [NSMutableArray array];
    for (VMDeviceInfo *d in [self allDevices]) {
        if ([d looksLikeLoopback]) [out addObject:d];
    }
    return out;
}

+ (nullable VMDeviceInfo *)deviceWithUID:(NSString *)uid {
    for (VMDeviceInfo *d in [self allDevices]) {
        if ([d.uid isEqualToString:uid]) return d;
    }
    return nil;
}

+ (nullable VMDeviceInfo *)deviceMatchingName:(NSString *)name {
    // 先精确匹配，再大小写不敏感的子串匹配
    NSArray<VMDeviceInfo *> *all = [self allDevices];
    for (VMDeviceInfo *d in all) {
        if ([d.name isEqualToString:name]) return d;
    }
    NSString *needle = [name lowercaseString];
    for (VMDeviceInfo *d in all) {
        if ([[d.name lowercaseString] containsString:needle]) return d;
    }
    return nil;
}

+ (void)printDeviceTable {
    NSArray<VMDeviceInfo *> *all = [self allDevices];
    NSLog(@"");
    NSLog(@"  %-4s %-4s %-4s %-7s %-8s %s", "ID", "IN", "OUT", "RATE", "VIRTUAL", "NAME");
    NSLog(@"  -------------------------------------------------------------------------------");
    for (VMDeviceInfo *d in all) {
        // 只有同时有输入和输出的才可能是虚拟麦克风
        NSString *mark = [d looksLikeLoopback] ? @"打勾" : @"";
        NSLog(@"  %-4u %-4u %-4u %-7.0f %-8@ %@",
              d.deviceID, d.inputChannels, d.outputChannels, d.sampleRate, mark, d.name);
        if (d.uid.length > 0) {
            NSLog(@"       UID = %@", d.uid);
        }
    }
    NSLog(@"");
    NSArray<VMDeviceInfo *> *lb = [self loopbackDevices];
    if (lb.count == 0) {
        NSLog(@"  ⚠️  没找到「既有输入又有输出」的虚拟声卡。");
        NSLog(@"      请先安装一个环回驱动（BlackHole / Loopback / 网易 NeCastAudio），");
        NSLog(@"      否则本工具没有地方可以推送虚拟麦克风。");
    } else {
        NSLog(@"  ✅ 可用的虚拟麦克风候选（既有输入又有输出）：");
        for (VMDeviceInfo *d in lb) {
            NSLog(@"      · %@  (UID=%@, %.0fHz, %u→%u ch)",
                  d.name, d.uid, d.sampleRate, d.outputChannels, d.inputChannels);
        }
        NSLog(@"");
        NSLog(@"      用法：把声音「播」到它的 Output 侧，别的 App 就能从 Input 侧读到。");
    }
    NSLog(@"");
}

+ (BOOL)getStreamFormat:(AudioStreamBasicDescription *)outFormat
              forDevice:(AudioDeviceID)deviceID
                  scope:(AudioObjectPropertyScope)scope {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamFormat,
        .mScope    = scope,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(AudioStreamBasicDescription);
    return AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, outFormat) == noErr;
}

+ (BOOL)bindDevice:(AudioDeviceID)deviceID toUnit:(AudioUnit)unit bus:(UInt32)bus {
    AudioDeviceID dev = deviceID;
    OSStatus st = AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       bus,
                                       &dev,
                                       sizeof(dev));
    if (st != noErr) {
        NSLog(@"[VMAudioDevice] 绑定设备失败 (unit bus=%u, status=%d)", bus, (int)st);
        return NO;
    }
    return YES;
}

@end
