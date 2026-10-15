//
//  VMMainWindowController.m
//  虚拟麦克风 App —— 主窗口
//

#import "VMMainWindowController.h"
#import "VMAudioDevice.h"
#import "VMAudioFilePlayer.h"
#import "VMRoute.h"

// ---------- 自绘电平表 / 进度条 ----------
// 用自定义 NSView 而不是 NSProgressIndicator，因为要同时画两条不同颜色的条，
// 而且要实时刷新（NSProgressIndicator 做动画会有额外开销）。

@interface VMMeterView : NSView
@property (nonatomic, assign) float level;      // 0..1 电平
@property (nonatomic, assign) double progress;  // 0..1 进度
@end

@implementation VMMeterView

- (BOOL)isFlipped { return YES; }

- (void)setLevel:(float)level {
    _level = level;
    self.needsDisplay = YES;
}

- (void)setProgress:(double)progress {
    _progress = progress;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGFloat barH = 14.0;
    CGFloat gap  = 8.0;

    // 上半：电平表
    NSRect levelRect = NSMakeRect(0, 0, b.size.width, barH);
    [[NSColor controlBackgroundColor] setFill];
    NSBezierPath *levelBg = [NSBezierPath bezierPathWithRoundedRect:levelRect xRadius:3 yRadius:3];
    [levelBg fill];

    float lv = _level;
    if (lv > 1.0f) lv = 1.0f;
    if (lv < 0.0f) lv = 0.0f;
    if (lv > 0.001f) {
        NSRect fillRect = NSMakeRect(0, 0, b.size.width * lv, barH);
        // 电平越高越"暖"：绿 → 黄 → 红
        NSColor *c = (lv > 0.9f) ? [NSColor systemRedColor]
                   : (lv > 0.7f) ? [NSColor systemYellowColor]
                                 : [NSColor systemGreenColor];
        [c setFill];
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:3 yRadius:3];
        [fill fill];
    }

    // 下半：进度条
    NSRect progRect = NSMakeRect(0, barH + gap, b.size.width, barH);
    [[NSColor controlBackgroundColor] setFill];
    NSBezierPath *progBg = [NSBezierPath bezierPathWithRoundedRect:progRect xRadius:3 yRadius:3];
    [progBg fill];

    if (_progress > 0.001) {
        NSRect fillRect = NSMakeRect(0, barH + gap, b.size.width * MIN(_progress, 1.0), barH);
        [[NSColor systemBlueColor] setFill];
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:3 yRadius:3];
        [fill fill];
    }
}

@end


// ---------- 主窗口 ----------

@interface VMMainWindowController () <NSApplicationDelegate>
@property (nonatomic, strong) NSPopUpButton   *devicePopUp;
@property (nonatomic, strong) NSTextField     *fileField;
@property (nonatomic, strong) NSTextField     *fileInfoLabel;
@property (nonatomic, strong) NSSlider        *volumeSlider;
@property (nonatomic, strong) NSTextField     *volumeLabel;
@property (nonatomic, strong) NSButton        *loopCheckbox;
@property (nonatomic, strong) VMMeterView     *meterView;
@property (nonatomic, strong) NSTextField     *timeLabel;
@property (nonatomic, strong) NSButton        *startButton;
@property (nonatomic, strong) NSButton        *pauseButton;
@property (nonatomic, strong) NSButton        *stopButton;
@property (nonatomic, strong) NSTextField     *statusLabel;

@property (nonatomic, strong) VMAudioFilePlayer *player;
@property (nonatomic, strong) VMRoute           *route;
@property (nonatomic, strong) NSTimer           *uiTimer;
@property (nonatomic, copy, nullable) NSString *filePath;

/// 只是用来在读文件前解析格式做预览，不参与播放
@property (nonatomic, strong, nullable) VMAudioFilePlayer *probePlayer;
@end

@implementation VMMainWindowController

#pragma mark - 构造

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 560, 420);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"虚拟麦克风";
    [w center];
    [w setReleasedWhenClosed:NO];

    if ((self = [super initWithWindow:w])) {
        [self buildUI];
        [self reloadDevices];
        [self updateButtonStates];
    }
    return self;
}

/// 创建一个统一样式的说明标签
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold {
    NSTextField *l = [[NSTextField alloc] initWithFrame:frame];
    l.stringValue = text;
    l.bezeled = NO;
    l.drawsBackground = NO;
    l.editable = NO;
    l.selectable = NO;
    l.font = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:12];
    l.textColor = bold ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    return l;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat W = content.bounds.size.width;
    CGFloat y = 380;

    // ---------- 标题 ----------
    NSTextField *title = [self labelWithText:@"把本地音频文件变成麦克风" frame:NSMakeRect(20, y, W - 40, 20) bold:YES];
    title.font = [NSFont boldSystemFontOfSize:15];
    [content addSubview:title];
    y -= 34;

    // ---------- 虚拟声卡 ----------
    [content addSubview:[self labelWithText:@"虚拟声卡" frame:NSMakeRect(20, y + 4, 70, 20) bold:NO]];

    self.devicePopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(92, y, 330, 26) pullsDown:NO];
    [content addSubview:self.devicePopUp];

    NSButton *refreshBtn = [[NSButton alloc] initWithFrame:NSMakeRect(430, y, 110, 26)];
    refreshBtn.title = @"重新扫描";
    refreshBtn.bezelStyle = NSBezelStyleRounded;
    refreshBtn.target = self;
    refreshBtn.action = @selector(reloadDevices);
    [content addSubview:refreshBtn];
    y -= 42;

    // ---------- 文件 ----------
    [content addSubview:[self labelWithText:@"音频文件" frame:NSMakeRect(20, y + 4, 70, 20) bold:NO]];

    self.fileField = [[NSTextField alloc] initWithFrame:NSMakeRect(92, y, 330, 26)];
    self.fileField.placeholderString = @"还没选择文件";
    self.fileField.editable = NO;
    self.fileField.selectable = YES;
    [content addSubview:self.fileField];

    NSButton *chooseBtn = [[NSButton alloc] initWithFrame:NSMakeRect(430, y, 110, 26)];
    chooseBtn.title = @"选择文件…";
    chooseBtn.bezelStyle = NSBezelStyleRounded;
    chooseBtn.target = self;
    chooseBtn.action = @selector(chooseFile);
    [content addSubview:chooseBtn];
    y -= 24;

    self.fileInfoLabel = [self labelWithText:@"" frame:NSMakeRect(92, y, 440, 18) bold:NO];
    [content addSubview:self.fileInfoLabel];
    y -= 32;

    // ---------- 分隔线 ----------
    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(20, y, W - 40, 1)];
    sep1.boxType = NSBoxSeparator;
    [content addSubview:sep1];
    y -= 34;

    // ---------- 音量 ----------
    [content addSubview:[self labelWithText:@"音量" frame:NSMakeRect(20, y + 2, 70, 20) bold:NO]];

    self.volumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(92, y, 260, 24)];
    self.volumeSlider.minValue = 0.0;
    self.volumeSlider.maxValue = 2.0;
    self.volumeSlider.doubleValue = 1.0;
    self.volumeSlider.continuous = YES;
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(volumeChanged:);
    [content addSubview:self.volumeSlider];

    self.volumeLabel = [self labelWithText:@"100%" frame:NSMakeRect(360, y + 2, 60, 20) bold:NO];
    [content addSubview:self.volumeLabel];

    self.loopCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(430, y, 120, 24)];
    self.loopCheckbox.buttonType = NSButtonTypeSwitch;
    self.loopCheckbox.title = @"循环播放";
    self.loopCheckbox.target = self;
    self.loopCheckbox.action = @selector(loopChanged:);
    [content addSubview:self.loopCheckbox];
    y -= 40;

    // ---------- 电平 + 进度 ----------
    self.meterView = [[VMMeterView alloc] initWithFrame:NSMakeRect(20, y, W - 40, 36)];
    [content addSubview:self.meterView];
    y -= 22;

    self.timeLabel = [self labelWithText:@"0:00 / 0:00" frame:NSMakeRect(20, y, W - 40, 18) bold:NO];
    self.timeLabel.alignment = NSTextAlignmentRight;
    [content addSubview:self.timeLabel];
    y -= 34;

    // ---------- 按钮 ----------
    self.startButton = [[NSButton alloc] initWithFrame:NSMakeRect(110, y, 130, 34)];
    self.startButton.title = @"▶ 开始推送";
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.keyEquivalent = @"\r";       // 回车键
    self.startButton.target = self;
    self.startButton.action = @selector(startPressed);
    [content addSubview:self.startButton];

    self.pauseButton = [[NSButton alloc] initWithFrame:NSMakeRect(250, y, 100, 34)];
    self.pauseButton.title = @"⏸ 暂停";
    self.pauseButton.bezelStyle = NSBezelStyleRounded;
    self.pauseButton.target = self;
    self.pauseButton.action = @selector(pausePressed);
    [content addSubview:self.pauseButton];

    self.stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(360, y, 100, 34)];
    self.stopButton.title = @"⏹ 停止";
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopPressed);
    [content addSubview:self.stopButton];
    y -= 36;

    // ---------- 状态栏 ----------
    self.statusLabel = [self labelWithText:@"请选择虚拟声卡和音频文件" frame:NSMakeRect(20, y, W - 40, 18) bold:NO];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:self.statusLabel];
}

#pragma mark - 设备

- (void)reloadDevices {
    [self.devicePopUp removeAllItems];

    NSArray<VMDeviceInfo *> *devices = [VMAudioDevice loopbackDevices];
    if (devices.count == 0) {
        [self.devicePopUp addItemWithTitle:@"⚠️ 没找到虚拟声卡"];
        self.devicePopUp.enabled = NO;
        self.statusLabel.stringValue = @"没找到虚拟声卡。请先安装 BlackHole / Loopback / NeCastAudio 其中之一。";
        [self updateButtonStates];
        return;
    }
    self.devicePopUp.enabled = YES;

    for (VMDeviceInfo *d in devices) {
        NSString *title = [NSString stringWithFormat:@"%@  (%.0f Hz, %u→%u ch)",
                           d.name, d.sampleRate, d.outputChannels, d.inputChannels];
        [self.devicePopUp addItemWithTitle:title];
        self.devicePopUp.lastItem.representedObject = d.uid;   // 存 UID，不存索引
    }
    [self updateButtonStates];
}

- (nullable VMDeviceInfo *)selectedDevice {
    NSString *uid = self.devicePopUp.selectedItem.representedObject;
    if (uid.length == 0) return nil;
    return [VMAudioDevice deviceWithUID:uid];
}

#pragma mark - 文件

- (void)chooseFile {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.message = @"选择一个音频文件，它的声音会被推送到虚拟麦克风";
    panel.prompt = @"选择";

    // 限定常见音频类型（不给限定也行，让用户自己选）
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[];
    }

    if ([panel runModal] != NSModalResponseOK) return;

    self.filePath = panel.URL.path;
    self.fileField.stringValue = self.filePath;

    // 立刻解析一下，把格式信息显示出来（顺便提前发现坏文件）
    VMAudioFilePlayer *probe = [[VMAudioFilePlayer alloc] init];
    probe.targetSampleRate = 48000.0;
    probe.targetChannels = 2;

    NSError *err = nil;
    if ([probe openFileAtPath:self.filePath error:&err]) {
        self.fileInfoLabel.stringValue = [NSString stringWithFormat:
            @"源 %.0f Hz · %u 声道 · %u bit   →   输出 48000 Hz · 立体声      时长 %@",
            probe.sourceSampleRate, probe.sourceChannels, probe.sourceBitsPerChannel,
            [self formatTime:probe.durationSeconds]];
        self.fileInfoLabel.textColor = [NSColor secondaryLabelColor];
        self.statusLabel.stringValue = @"就绪，点「开始推送」";
        self.probePlayer = probe;
    } else {
        self.fileInfoLabel.stringValue = err.localizedDescription;
        self.fileInfoLabel.textColor = [NSColor systemRedColor];
        self.statusLabel.stringValue = @"文件打不开";
        self.probePlayer = nil;
    }
    [self updateButtonStates];
}

- (NSString *)formatTime:(double)seconds {
    if (seconds <= 0 || !isfinite(seconds)) return @"0:00";
    int total = (int)seconds;
    return [NSString stringWithFormat:@"%d:%02d", total / 60, total % 60];
}

#pragma mark - 播放控制

- (void)startPressed {
    if (self.route.isRunning) return;

    VMDeviceInfo *dev = [self selectedDevice];
    if (!dev) {
        [self alert:@"请先选择一个虚拟声卡" info:@"在顶部下拉框里选择。如果列表是空的，说明系统里还没装环回音频驱动。"];
        return;
    }
    if (self.filePath.length == 0) {
        [self alert:@"请先选择一个音频文件" info:@"点右侧的「选择文件…」按钮。"];
        return;
    }

    // ---- 播放器 ----
    VMAudioFilePlayer *player = [[VMAudioFilePlayer alloc] init];
    player.targetSampleRate = dev.sampleRate > 0 ? dev.sampleRate : 48000.0;
    player.targetChannels   = 2;
    player.loop             = (self.loopCheckbox.state == NSControlStateValueOn);
    player.gain             = (float)self.volumeSlider.doubleValue;

    NSError *err = nil;
    if (![player openFileAtPath:self.filePath error:&err]) {
        [self alert:@"打不开音频文件" info:err.localizedDescription];
        return;
    }

    // ---- 路由 ----
    VMRoute *route = [[VMRoute alloc] initWithSinkDevice:dev];
    if (!route) {
        [self alert:@"无法使用该虚拟声卡" info:@"设备没有输出通道，或者被别的程序独占。"];
        return;
    }
    if (![route startWithPlayer:player error:&err]) {
        [self alert:@"启动失败" info:err.localizedDescription];
        return;
    }

    self.player = player;
    self.route  = route;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"正在推送到 %@", dev.name];
    self.statusLabel.textColor = [NSColor systemGreenColor];

    [self startUITimer];
    [self updateButtonStates];
}

- (void)pausePressed {
    if (!self.player) return;
    BOOL nowPaused = !self.player.isPaused;
    self.player.paused = nowPaused;
    self.pauseButton.title = nowPaused ? @"▶ 继续" : @"⏸ 暂停";
    self.statusLabel.stringValue = nowPaused ? @"已暂停（推送静音）" : @"继续推送";
}

- (void)stopPressed {
    [self.route stop];
    self.route  = nil;
    self.player = nil;
    [self stopUITimer];

    self.meterView.level = 0;
    self.meterView.progress = 0;
    self.pauseButton.title = @"⏸ 暂停";
    self.statusLabel.stringValue = @"已停止";
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [self updateButtonStates];
}

- (void)volumeChanged:(id)sender {
    double v = self.volumeSlider.doubleValue;
    self.volumeLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100];
    if (self.player) self.player.gain = (float)v;
}

- (void)loopChanged:(id)sender {
    if (self.player) self.player.loop = (self.loopCheckbox.state == NSControlStateValueOn);
}

- (void)updateButtonStates {
    BOOL running = self.route.isRunning;
    self.startButton.enabled = !running;
    self.pauseButton.enabled = running;
    self.stopButton.enabled  = running;
    self.devicePopUp.enabled = (self.devicePopUp.numberOfItems > 1) || running == NO;
}

#pragma mark - UI 刷新

- (void)startUITimer {
    [self stopUITimer];
    // 30fps 刷新电平表，足够顺眼，开销也小
    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                    target:self
                                                  selector:@selector(tick)
                                                  userInfo:nil
                                                   repeats:YES];
    // 让 timer 在滚动/拖拽时也能触发
    [[NSRunLoop currentRunLoop] addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUITimer {
    [self.uiTimer invalidate];
    self.uiTimer = nil;
}

- (void)tick {
    if (!self.route || !self.player) return;

    self.meterView.level = self.route.peakLevel;
    self.meterView.progress = self.player.progress;

    double elapsed = self.player.progress * self.player.durationSeconds;
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
                                  [self formatTime:elapsed],
                                  [self formatTime:self.player.durationSeconds]];

    // 不循环且播完了 → 自动停止
    if (!self.player.isPaused && self.player.reachedEnd && !self.player.loop) {
        [self stopPressed];
        self.statusLabel.stringValue = @"文件播放完毕";
    }
}

#pragma mark - 提示

- (void)alert:(NSString *)title info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = info;
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"知道了"];
    [a runModal];
}

@end
