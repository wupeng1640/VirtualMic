//
//  main.m
//  虚拟麦克风 App —— 命令行入口
//
//  用法：
//    vmic --list                          列出所有音频设备
//    vmic --loops                         只列出可用的虚拟麦克风（环回设备）
//    vmic --play <文件> [选项]             把文件推到虚拟麦克风
//
//  常用选项：
//    --device <名字或UID>   指定虚拟声卡（默认自动挑第一个环回设备）
//    --loop                 循环播放
//    --gain <倍数>          增益（默认 1.0，想小声点用 0.5）
//    --verify               同时从输入侧读回来，验证环回是否真的通了
//    --duration <秒>        播够这么多秒就退出（默认一直播到文件结束）
//

#import <Foundation/Foundation.h>
#import "VMAudioDevice.h"
#import "VMAudioFilePlayer.h"
#import "VMRoute.h"

#pragma mark - 参数解析

@interface VMOptions : NSObject
@property (nonatomic, assign) BOOL listDevices;
@property (nonatomic, assign) BOOL listLoopback;
@property (nonatomic, copy,   nullable) NSString *filePath;
@property (nonatomic, copy,   nullable) NSString *deviceSpec;
@property (nonatomic, assign) BOOL loop;
@property (nonatomic, assign) BOOL verify;
@property (nonatomic, assign) float gain;
@property (nonatomic, assign) double duration;   // <=0 表示不限制
@property (nonatomic, assign) double sampleRate;
@end

@implementation VMOptions
- (instancetype)init {
    if ((self = [super init])) {
        _gain = 1.0f;
        _duration = 0.0;
        _sampleRate = 48000.0;
    }
    return self;
}
@end

static void VMPrintUsage(void) {
    printf(
        "\n"
        "虚拟麦克风 v1.0 —— 把本地音频文件推给「虚拟麦克风」\n"
        "\n"
        "用法:\n"
        "  vmic --list                     列出所有音频设备\n"
        "  vmic --loops                    只列出可用的虚拟麦克风\n"
        "  vmic --play <文件> [选项]        开始推送\n"
        "\n"
        "选项:\n"
        "  --device <名字|UID>  指定虚拟声卡（默认自动选）\n"
        "  --loop               循环播放\n"
        "  --gain <倍数>        增益，默认 1.0\n"
        "  --verify             从输入侧读回来验证环回\n"
        "  --duration <秒>      播够就退出，默认播完文件\n"
        "  --rate <Hz>          目标采样率，默认 48000\n"
        "  -h, --help           显示本帮助\n"
        "\n"
        "例子:\n"
        "  vmic --play ~/Music/test.mp3 --loop\n"
        "  vmic --play ./voice.wav --device NeCastAudio --verify\n"
        "\n");
}

static VMOptions *VMParseOptions(int argc, const char *argv[], NSError **error) {
    VMOptions *o = [[VMOptions alloc] init];
    for (int i = 1; i < argc; i++) {
        NSString *a = @(argv[i]);

        if ([a isEqualToString:@"--list"]) {
            o.listDevices = YES;
        } else if ([a isEqualToString:@"--loops"]) {
            o.listLoopback = YES;
        } else if ([a isEqualToString:@"--play"]) {
            if (i + 1 >= argc) {
                if (error) *error = [NSError errorWithDomain:@"vmic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"--play 后面需要跟文件路径"}];
                return nil;
            }
            o.filePath = @(argv[++i]);
        } else if ([a isEqualToString:@"--device"]) {
            if (i + 1 >= argc) {
                if (error) *error = [NSError errorWithDomain:@"vmic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"--device 后面需要跟设备名或 UID"}];
                return nil;
            }
            o.deviceSpec = @(argv[++i]);
        } else if ([a isEqualToString:@"--loop"]) {
            o.loop = YES;
        } else if ([a isEqualToString:@"--verify"]) {
            o.verify = YES;
        } else if ([a isEqualToString:@"--gain"]) {
            if (i + 1 >= argc) {
                if (error) *error = [NSError errorWithDomain:@"vmic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"--gain 后面需要跟数字"}];
                return nil;
            }
            o.gain = (float)atof(argv[++i]);
        } else if ([a isEqualToString:@"--duration"]) {
            if (i + 1 >= argc) {
                if (error) *error = [NSError errorWithDomain:@"vmic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"--duration 后面需要跟秒数"}];
                return nil;
            }
            o.duration = atof(argv[++i]);
        } else if ([a isEqualToString:@"--rate"]) {
            if (i + 1 >= argc) {
                if (error) *error = [NSError errorWithDomain:@"vmic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"--rate 后面需要跟采样率"}];
                return nil;
            }
            o.sampleRate = atof(argv[++i]);
        } else if ([a isEqualToString:@"-h"] || [a isEqualToString:@"--help"]) {
            VMPrintUsage();
            exit(0);
        } else {
            if (error) *error = [NSError errorWithDomain:@"vmic" code:1
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                              [NSString stringWithFormat:@"未知参数: %@", a]}];
            return nil;
        }
    }
    return o;
}

#pragma mark - 选设备

/// 挑一个可以用来做虚拟麦克风的设备。
/// 优先用用户指定的；没指定就挑第一个"既有输入又有输出"的设备。
static VMDeviceInfo *VMSelectRouteDevice(VMOptions *o) {
    if (o.deviceSpec.length > 0) {
        VMDeviceInfo *d = [VMAudioDevice deviceWithUID:o.deviceSpec];
        if (!d) d = [VMAudioDevice deviceMatchingName:o.deviceSpec];
        if (!d) {
            printf("❌ 找不到设备: %s\n", o.deviceSpec.UTF8String);
            printf("   用 --list 看看有哪些设备。\n");
            return nil;
        }
        if (d.outputChannels == 0) {
            printf("❌ 设备 \"%s\" 没有输出通道，无法往它里面写声音。\n", d.name.UTF8String);
            printf("   虚拟麦克风必须是「既有输入又有输出」的环回设备。\n");
            return nil;
        }
        return d;
    }

    NSArray<VMDeviceInfo *> *lb = [VMAudioDevice loopbackDevices];
    if (lb.count == 0) {
        printf("❌ 没找到可用的虚拟声卡。\n\n");
        printf("   本工具不自己造驱动 —— 它只负责「往虚拟声卡里写声音」。\n");
        printf("   你需要先装一个环回音频驱动，比如：\n");
        printf("     · BlackHole (免费开源)  https://existential.audio/blackhole/\n");
        printf("     · Loopback  (付费)      https://rogueamoeba.com/loopback/\n");
        printf("     · 网易 NeCastAudio（你机器上已经有一个）\n\n");
        return nil;
    }
    if (lb.count > 1) {
        printf("ℹ️  发现 %lu 个可用的虚拟声卡，自动选用第一个：\"%s\"\n",
               (unsigned long)lb.count, lb.firstObject.name.UTF8String);
        printf("   想换一个用 --device <名字> 指定。\n\n");
    }
    return lb.firstObject;
}

#pragma mark - 主流程

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *err = nil;
        VMOptions *o = VMParseOptions(argc, argv, &err);
        if (!o) {
            printf("参数错误: %s\n", err.localizedDescription.UTF8String);
            VMPrintUsage();
            return 2;
        }

        if (o.listDevices) {
            [VMAudioDevice printDeviceTable];
            return 0;
        }

        if (o.listLoopback) {
            NSArray<VMDeviceInfo *> *lb = [VMAudioDevice loopbackDevices];
            if (lb.count == 0) {
                printf("\n❌ 没有可用的虚拟麦克风设备。\n");
                printf("   需要先安装环回音频驱动（BlackHole / Loopback / NeCastAudio）。\n\n");
                return 1;
            }
            printf("\n✅ 可用的虚拟麦克风：\n\n");
            for (VMDeviceInfo *d in lb) {
                printf("   %-28s  %.0f Hz  %u→%u ch  (id=%u)\n",
                       d.name.UTF8String, d.sampleRate,
                       d.outputChannels, d.inputChannels, d.deviceID);
                printf("   %-28s  UID = %s\n\n", "", d.uid.UTF8String);
            }
            return 0;
        }

        if (o.filePath.length == 0) {
            VMPrintUsage();
            return 2;
        }

        printf("\n");
        printf("╔══════════════════════════════════════════════════════════╗\n");
        printf("║        虚拟麦克风 —— 本地音频文件 → 麦克风                ║\n");
        printf("╚══════════════════════════════════════════════════════════╝\n\n");

        // ---- 1. 确认文件存在 ----
        NSString *path = o.filePath.stringByExpandingTildeInPath;
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            printf("❌ 文件不存在: %s\n\n", path.UTF8String);
            return 1;
        }

        // ---- 2. 选虚拟声卡 ----
        VMDeviceInfo *dev = VMSelectRouteDevice(o);
        if (!dev) return 1;
        printf("🎯 目标虚拟声卡: %s\n", dev.name.UTF8String);
        printf("   UID: %s    %.0f Hz\n", dev.uid.UTF8String, dev.sampleRate);
        printf("   写入 Output 侧 (%u ch) → 别的 App 从 Input 侧 (%u ch) 读取\n\n",
               dev.outputChannels, dev.inputChannels);

        // ---- 3. 打开文件 ----
        VMAudioFilePlayer *player = [[VMAudioFilePlayer alloc] init];
        player.targetSampleRate = o.sampleRate;
        player.targetChannels   = 2;
        player.loop             = o.loop;
        player.gain             = o.gain;

        if (![player openFileAtPath:path error:&err]) {
            printf("❌ %s\n\n", err.localizedDescription.UTF8String);
            return 1;
        }
        printf("\n");

        // ---- 4. 建立路由并开始 ----
        VMRoute *route = [[VMRoute alloc] initWithSinkDevice:dev];
        if (!route) {
            printf("❌ 无法创建到该设备的路由\n\n");
            return 1;
        }
        route.captureLoopback = o.verify;

        if (![route startWithPlayer:player error:&err]) {
            printf("❌ 启动失败: %s\n\n", err.localizedDescription.UTF8String);
            return 1;
        }

        printf("▶️  正在推送...  (Ctrl-C 停止)\n");
        if (o.loop) printf("   🔁 循环模式\n");
        if (o.gain != 1.0f) printf("   🔊 增益 %.2fx\n", o.gain);
        if (o.verify) printf("   🔍 已开启环回自检\n");
        printf("\n");

        // ---- 5. 主循环：每 2 秒刷一次进度 ----
        NSDate *started = [NSDate date];
        uint64_t lastFrames = 0;
        while (YES) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];

            uint64_t frames = player.framesDelivered;
            double elapsed = -started.timeIntervalSinceNow;
            double rate = (elapsed > 0) ? ((double)(frames - lastFrames) / 2.0) : 0;
            lastFrames = frames;

            // 进度条
            double p = player.progress;
            int bars = (int)(p * 30);
            char bar[40];
            for (int i = 0; i < 30; i++) bar[i] = (i < bars) ? '=' : ' ';
            bar[30] = '\0';

            printf("\r   [%s] %5.1f%%  已送 %llu 帧  ~%.0f 帧/秒  电平 %.3f",
                   bar, p * 100.0, (unsigned long long)frames, rate, route.peakLevel);

            if (o.verify) {
                printf("  环回已收到 %llu 帧 (峰值 %.3f)",
                       (unsigned long long)route.loopbackFramesCaptured, route.loopbackPeak);
            }
            fflush(stdout);

            // 播完了？
            if (!o.loop && player.totalFramesAtTargetRate > 0
                && frames >= player.totalFramesAtTargetRate) {
                printf("\n\n✅ 文件播放完毕。\n");
                if (o.verify) {
                    if (route.loopbackFramesCaptured > 0) {
                        printf("   ✅ 环回自检通过：写进去的声音确实能从另一侧读出来。\n");
                    } else {
                        printf("   ⚠️  环回自检没收到数据 —— 声音可能没真正进到虚拟声卡。\n");
                    }
                }
                break;
            }

            if (o.duration > 0 && elapsed >= o.duration) {
                printf("\n\n✅ 已播放 %.1f 秒，按时退出。\n", elapsed);
                break;
            }
        }

        [route stop];
        printf("\n");
        return 0;
    }
}
