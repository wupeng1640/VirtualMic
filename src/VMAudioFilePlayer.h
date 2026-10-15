//
//  VMAudioFilePlayer.h
//  虚拟麦克风 App —— 本地音频文件播放器
//
//  职责：把一个音频文件解码成 48kHz / 2ch / Float32 interleaved，
//        然后由音频回调按实时速率把它"拉"出去。
//
//  为什么是"拉"（pull）而不是"推"（push）：
//      AudioUnit 的渲染回调由 CoreAudio 按自己的节拍调用。
//      我们只能在这个回调里同步地给出下一段样本，
//      不能另起线程往设备里塞数据（会爆音/丢帧）。
//      所以播放器必须实现成"给你 N 帧，立刻返回 N 帧"。
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface VMAudioFilePlayer : NSObject

/// 目标格式：一般就填虚拟声卡的 (48000, 2)
@property (nonatomic, assign) double targetSampleRate;
@property (nonatomic, assign) UInt32 targetChannels;

/// 是否循环播放
@property (nonatomic, assign) BOOL loop;

/// 增益倍数（1.0 = 原音量）
@property (nonatomic, assign) float gain;

/// 已送出的帧数（用于进度显示和验证）
@property (nonatomic, readonly) uint64_t framesDelivered;

/// 文件总帧数（按目标采样率折算）
@property (nonatomic, readonly) uint64_t totalFramesAtTargetRate;

/// 打开文件并准备好解码器（不开始播放）
- (BOOL)openFileAtPath:(NSString *)path error:(NSError **)error;

/// 实时取帧：把 frames 个帧的 Float32 interleaved 数据写进 outData。
/// 这是音频回调里调用的，必须快、不能阻塞、不能分配内存。
/// 文件读完了就填静音（或者循环）。
/// @return 实际写入的帧数
- (UInt32)renderFrames:(UInt32)frames into:(AudioBufferList *)outData;

/// 从头开始
- (void)rewind;

/// 播放进度 0..1
@property (nonatomic, readonly) double progress;

/// 源文件的原始格式（用于在 UI 上显示"44.1kHz 立体声 → 48kHz"这种信息）
@property (nonatomic, readonly) double sourceSampleRate;
@property (nonatomic, readonly) UInt32 sourceChannels;
@property (nonatomic, readonly) UInt32 sourceBitsPerChannel;

/// 文件已经播完（且不循环）
@property (nonatomic, readonly) BOOL reachedEnd;

/// 播放时长（秒，按目标采样率折算）
@property (nonatomic, readonly) double durationSeconds;

/// 暂停：暂停后 renderFrames: 会输出静音，但仍在"消费"时间轴。
/// 用 __block 之外的原子标志实现，实时线程安全。
@property (nonatomic, assign, getter=isPaused) BOOL paused;

@end

NS_ASSUME_NONNULL_END
