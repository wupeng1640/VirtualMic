//
//  VMRoute.h
//  虚拟麦克风 App —— 把「文件」接到「虚拟声卡」
//
//  信号流：
//
//       ┌──────────────┐        （我们只做这一步）
//       │ 音频文件      │ ───────────────────────────┐
//       └──────────────┘                            │
//                                                   ▼
//                                      ┌────────────────────────┐
//                                      │  虚拟声卡 (HAL 插件)     │
//                                      │  Output 侧 ← 我们写入   │
//                                      │  Input  侧 → App 读取   │  ← OBS/浏览器/微信 在这里拿到"麦克风"
//                                      └────────────────────────┘
//
//  技术上就是一个 AudioUnit（kAudioUnitSubType_HALOutput）：
//    · 打开输出侧（EnableIO: bus0=1）
//    · 渲染回调里从 VMAudioFilePlayer 拉数据填进去
//  剩下的事由 HAL 插件完成 —— 它把写进 Output 的样本在 Input 侧暴露出来。
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "VMAudioDevice.h"
#import "VMAudioFilePlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface VMRoute : NSObject

/// 目标虚拟声卡（必须有 Output 侧）
@property (nonatomic, strong, readonly, nullable) VMDeviceInfo *sinkDevice;

/// 是否同时从该设备的 Input 侧读回来（用于自检：证明环回真的通了）
@property (nonatomic, assign) BOOL captureLoopback;

/// 读回来的帧数（captureLoopback=YES 时有意义）
@property (nonatomic, readonly) uint64_t loopbackFramesCaptured;

/// 读回来时的峰值（证明环回真的通了）
@property (nonatomic, readonly) float loopbackPeak;

/// 峰值电平 0..1（喂给 UI 做电平表）
@property (nonatomic, readonly) float peakLevel;

/// 已经写进设备的总帧数（UI 用来显示"正在推送"的活性）
@property (nonatomic, readonly) uint64_t framesSentToDevice;

/// 运行中？
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (nullable instancetype)initWithSinkDevice:(VMDeviceInfo *)device;

/// 开始把 player 的内容往设备里送。player 必须已经 openFileAtPath: 成功。
- (BOOL)startWithPlayer:(VMAudioFilePlayer *)player error:(NSError **)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
