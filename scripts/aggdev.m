// aggdev —— 创建/删除一个把 BlackHole 2ch 包住的聚合音频设备。
//
// 背景：有些 App（如部分 RTC SDK）枚举音频设备时会丢弃
//       transportType == 'virt' 的设备，导致 BlackHole 等虚拟声卡
//       不出现在它们的麦克风下拉里。聚合设备的 transportType 是
//       'grup'，不在丢弃范围内，所以能绕过这个限制。
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

static const char *kSubUID = "BlackHole2ch_UID";
static const char *kAggUID = "com.wupeng.blackhole.agg";

static void usage(void) {
    fprintf(stderr,
        "用法:\n"
        "  aggdev --create [名字]     创建聚合设备（默认 \"BH Aggregate\"）\n"
        "  aggdev --remove            删除聚合设备\n"
        "  aggdev --list              列出所有音频设备及其 transportType\n");
}

static NSString *nameOf(AudioDeviceID d) {
    CFStringRef s = NULL; UInt32 sz = sizeof(s);
    AudioObjectPropertyAddress a = {kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &s) != noErr || !s) return @"?";
    return (__bridge_transfer NSString *)s;
}

static UInt32 transportOf(AudioDeviceID d) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 v = 0, sz = sizeof(v);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v) != noErr) return 0;
    return v;
}

static void fourcc(UInt32 v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff); out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >> 8) & 0xff);  out[3] = (char)(v & 0xff); out[4] = 0;
}

static AudioDeviceID findAgg(void) {
    UInt32 sz = 0;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioDeviceID *ids = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    AudioDeviceID found = 0;
    for (int i = 0; i < (int)(sz / sizeof(AudioDeviceID)); i++) {
        CFStringRef u = NULL; UInt32 us = sizeof(u);
        AudioObjectPropertyAddress b = {kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(ids[i], &b, 0, NULL, &us, &u) == noErr && u) {
            NSString *s = (__bridge_transfer NSString *)u;
            if ([s isEqualToString:@(kAggUID)]) { found = ids[i]; break; }
        }
    }
    free(ids);
    return found;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { usage(); return 2; }
    NSString *cmd = @(argv[1]);

    if ([cmd isEqualToString:@"--list"]) {
        printf("%-6s %-32s %-10s\n", "ID", "名称", "transport");
        printf("%s\n", "------------------------------------------------------------");
        UInt32 sz = 0;
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
        AudioDeviceID *ids = malloc(sz);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
        for (int i = 0; i < (int)(sz / sizeof(AudioDeviceID)); i++) {
            char f[5]; UInt32 t = transportOf(ids[i]); fourcc(t, f);
            printf("%-6u %-32s '%s'%s\n", ids[i], nameOf(ids[i]).UTF8String, f,
                   t == kAudioDeviceTransportTypeVirtual
                       ? "   <- transportType 'virt'，可能被某些 App 忽略"
                       : "");
        }
        free(ids);
        return 0;
    }

    if ([cmd isEqualToString:@"--remove"]) {
        AudioDeviceID d = findAgg();
        if (!d) { fprintf(stderr, "没找到聚合设备（UID=%s）\n", kAggUID); return 1; }
        OSStatus st = AudioHardwareDestroyAggregateDevice(d);
        if (st != noErr) { fprintf(stderr, "删除失败: %d\n", (int)st); return 1; }
        printf("已删除聚合设备 id=%u\n", d);
        return 0;
    }

    if ([cmd isEqualToString:@"--create"]) {
        NSString *nm = (argc >= 3) ? @(argv[2]) : @"BH Aggregate";
        if (findAgg()) {
            fprintf(stderr, "聚合设备已存在（UID=%s）。先 --remove 再创建。\n", kAggUID);
            return 1;
        }
        NSDictionary *desc = @{
            @kAudioAggregateDeviceNameKey: nm,
            @kAudioAggregateDeviceUIDKey: @(kAggUID),
            @kAudioAggregateDeviceIsPrivateKey: @NO,
            @kAudioAggregateDeviceIsStackedKey: @NO,
            @kAudioAggregateDeviceMainSubDeviceKey: @(kSubUID),
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: @(kSubUID)}]
        };
        AudioDeviceID agg = 0;
        OSStatus st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc, &agg);
        if (st != noErr) { fprintf(stderr, "创建失败: %d\n", (int)st); return 1; }
        printf("✅ 已创建聚合设备 \"%s\" (id=%u, UID=%s)\n", nm.UTF8String, agg, kAggUID);
        printf("   子设备: BlackHole 2ch\n");
        printf("   需要它的 App 现在应该能在麦克风列表里看到这个名字。\n");
        return 0;
    }

    usage();
    return 2;
}}
