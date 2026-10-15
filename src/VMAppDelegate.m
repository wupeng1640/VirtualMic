//
//  VMAppDelegate.m
//  虚拟麦克风 App —— 应用入口
//

#import "VMAppDelegate.h"
#import "VMMainWindowController.h"
#import "VMAudioDevice.h"
#import "VMAudioFilePlayer.h"
#import "VMRoute.h"

@implementation VMAppDelegate {
    VMMainWindowController *_main;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _main = [[VMMainWindowController alloc] init];
    [_main showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end


#pragma mark - 无头自检

/// GUI 走的是「选设备 → 开文件 → VMRoute 推送」这条路。
/// 这个自检把同一条路跑一遍但不建窗口，用于在没有图形界面的环境下验证功能。
/// deviceSpec 可以是设备名或 UID 的一部分（不区分大小写）；传 nil 则挑第一个环回设备。
static int VMRunSelfTest(NSString *filePath, NSString *deviceSpec) {
    printf("\n=== 虚拟麦克风 无头自检 ===\n\n");

    // 1. 选设备
    NSArray<VMDeviceInfo *> *lb = [VMAudioDevice loopbackDevices];
    if (lb.count == 0) {
        printf("❌ 没有可用虚拟声卡\n");
        return 1;
    }

    VMDeviceInfo *dev = nil;
    if (deviceSpec.length > 0) {
        for (VMDeviceInfo *d in lb) {
            if ([d.name rangeOfString:deviceSpec options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [d.uid  rangeOfString:deviceSpec options:NSCaseInsensitiveSearch].location != NSNotFound) {
                dev = d;
                break;
            }
        }
        if (!dev) {
            printf("❌ 没找到匹配 \"%s\" 的设备。可用的有：\n", deviceSpec.UTF8String);
            for (VMDeviceInfo *d in lb) {
                printf("     - %s  (%s)\n", d.name.UTF8String, d.uid.UTF8String);
            }
            return 1;
        }
    } else {
        dev = lb.firstObject;
    }
    printf("✅ 虚拟声卡: %s (%.0f Hz, %u→%u ch)\n",
           dev.name.UTF8String, dev.sampleRate, dev.outputChannels, dev.inputChannels);

    // 2. 开文件
    VMAudioFilePlayer *player = [[VMAudioFilePlayer alloc] init];
    player.targetSampleRate = dev.sampleRate > 0 ? dev.sampleRate : 48000.0;
    player.targetChannels   = 2;
    NSError *err = nil;
    if (![player openFileAtPath:filePath error:&err]) {
        printf("❌ 打开文件失败: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    printf("✅ 文件: %.0f Hz %u ch → %.0f Hz %u ch, 时长 %.1fs\n",
           player.sourceSampleRate, player.sourceChannels,
           player.targetSampleRate, player.targetChannels, player.durationSeconds);

    // 3. 路由推送
    VMRoute *route = [[VMRoute alloc] initWithSinkDevice:dev];
    if (!route || ![route startWithPlayer:player error:&err]) {
        printf("❌ 启动路由失败: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    printf("✅ 路由已启动，推送 3 秒...\n\n");

    NSDate *t0 = [NSDate date];
    uint64_t sent0 = 0;
    while (-t0.timeIntervalSinceNow < 3.0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        uint64_t sent = route.framesSentToDevice;
        double el = -t0.timeIntervalSinceNow;
        printf("   t=%4.1fs  已送 %8llu 帧  速率 %6.0f 帧/秒  电平 %.3f\n",
               el, (unsigned long long)sent,
               el > 0 ? (double)(sent - sent0) / 0.5 : 0, route.peakLevel);
        sent0 = sent;
    }

    uint64_t total = route.framesSentToDevice;
    double rate = (double)total / 3.0;

    printf("\n--- 结果 ---\n");
    printf("总送帧: %llu\n", (unsigned long long)total);
    printf("平均速率: %.0f 帧/秒 (设备采样率 %.0f)\n", rate, dev.sampleRate);

    BOOL rateOK = fabs(rate - dev.sampleRate) < dev.sampleRate * 0.05;
    printf("速率检查: %s\n", rateOK ? "✅ 通过（误差 <5%）" : "❌ 未达标");

    [route stop];
    printf("\n%s\n\n", rateOK ? "✅ 自检通过：音频正在稳定地送入虚拟声卡。" : "❌ 自检未通过");
    return rateOK ? 0 : 1;
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 无头自检模式：
        //   vmic-gui --selftest <音频文件> [设备名或UID]
        if (argc >= 3 && strcmp(argv[1], "--selftest") == 0) {
            NSString *spec = (argc >= 4) ? @(argv[3]) : nil;
            return VMRunSelfTest(@(argv[2]), spec);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        VMAppDelegate *delegate = [[VMAppDelegate alloc] init];
        app.delegate = delegate;

        // 手写一个最小菜单栏 —— 没有它，Cmd+Q / Cmd+W 不会工作
        NSMenu *menubar = [[NSMenu alloc] init];

        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
        [app setMainMenu:menubar];

        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"关于虚拟麦克风"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"隐藏"
                           action:@selector(hide:)
                    keyEquivalent:@"h"];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"退出虚拟麦克风"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;

        [app run];
    }
    return 0;
}
