//
//  VMAudioDevice.h
//  虚拟麦克风 App —— CoreAudio 设备定位工具
//
//  为什么需要它：往"虚拟声卡"喂声音，前提是先找到那个设备。
//  设备 ID 在每次插拔/重启后都可能变，所以必须按 UID 定位，不能写死数字。
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个 CoreAudio 设备的基本信息
@interface VMDeviceInfo : NSObject

@property (nonatomic, assign) AudioDeviceID deviceID;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *uid;
@property (nonatomic, assign) UInt32 inputChannels;
@property (nonatomic, assign) UInt32 outputChannels;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) BOOL isVirtual;   ///< Transport = Virtual

@end


@interface VMAudioDevice : NSObject

/// 列出系统里所有音频设备的概况
+ (NSArray<VMDeviceInfo *> *)allDevices;

/// 只列出"既有输入又有输出"的设备 —— 虚拟声卡（环回设备）的典型特征
+ (NSArray<VMDeviceInfo *> *)loopbackDevices;

/// 按 UID 精确查找；找不到返回 nil
+ (nullable VMDeviceInfo *)deviceWithUID:(NSString *)uid;

/// 按名字模糊查找（用于 `--device NeCastAudio` 这种写法）
+ (nullable VMDeviceInfo *)deviceMatchingName:(NSString *)name;

/// 打印一张设备表，方便用户在命令行里挑
+ (void)printDeviceTable;

/// 读取某设备某个方向的 StreamBasicDescription
+ (BOOL)getStreamFormat:(AudioStreamBasicDescription *)outFormat
              forDevice:(AudioDeviceID)deviceID
                  scope:(AudioObjectPropertyScope)scope;

/// 把 AudioDeviceID 绑到 AudioUnit 的某个 bus 上
+ (BOOL)bindDevice:(AudioDeviceID)deviceID toUnit:(AudioUnit)unit bus:(UInt32)bus;

@end

NS_ASSUME_NONNULL_END
