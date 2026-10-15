//
//  VMAudioFilePlayer.m
//  虚拟麦克风 App —— 本地音频文件播放器
//
//  实现要点（都是踩过的坑）：
//   1. 解码目标格式直接设成虚拟声卡的格式（48kHz/2ch/Float32），
//      让解码器自己重采样，比我们手写重采样器稳得多。
//   2. 音频回调里绝对不能有 @autoreleasepool / malloc / 文件 IO。
//      所以缓冲区在 openFileAtPath: 里一次性分配好，回调里只做 memcpy。
//   3. AVAudioFile.readIntoBuffer: 会分配内存且可能阻塞，
//      不能在实时线程调用 —— 改用解码器读入预分配缓冲。
//   4. 【重要】文件后缀会骗人。有人把 m4a 内容存成 .mp3 后缀，
//      ExtAudioFile 只按后缀/魔数挑解析器，遇到这种会直接报
//      1685348671 (0x6474613f 'dta?')。所以这里实现了两级解码：
//        首选 ExtAudioFile（能 seek、拿得到总帧数、支持所有原生格式）
//        失败则回退 AVAssetReader（按容器探测，容错强得多）
//      参考：苹果自家 afconvert 也打不开这类文件（报错 dta?）。
//

#import "VMAudioFilePlayer.h"
#import <AudioToolbox/ExtendedAudioFile.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Accelerate/Accelerate.h>

/// 每次从文件预读的帧数。比单个回调的 512 帧大，
/// 这样回调里大多数时候只是从缓存里 memcpy，偶尔才碰一次磁盘。
static const UInt32 kChunkFrames = 16384;

/// 解码后端
typedef NS_ENUM(NSInteger, VMDecoderKind) {
    VMDecoderKindNone = 0,
    VMDecoderKindExtAudioFile,   ///< 首选：AudioToolbox
    VMDecoderKindAssetReader,    ///< 回退：AVFoundation
};

@implementation VMAudioFilePlayer {
    // ---- 解码端 ----
    VMDecoderKind               _decoder;
    ExtAudioFileRef             _file;          // 仅 ExtAudioFile 后端
    AVAssetReader              *_reader;        // 仅 AssetReader 后端
    AVAssetReaderTrackOutput   *_readerOut;
    AudioStreamBasicDescription _fileFormat;

    // ---- 预读缓存（Float32 interleaved，目标格式）----
    float   *_chunk;            // kChunkFrames * targetChannels
    UInt32   _chunkFilled;      // 缓存里已有多少帧
    UInt32   _chunkCursor;      // 已经消费到缓存里的第几帧

    // ---- 进度 ----
    uint64_t _framesAtTargetRate;
    uint64_t _framesReadFromFile;   // 从文件读出的帧数（用于判断 EOF / 循环）

    NSString *_sourcePath;          // AssetReader 后端 rewind 时需要

    BOOL _reachedEOF;
}

#pragma mark - 生命周期

- (instancetype)init {
    if ((self = [super init])) {
        _targetSampleRate = 48000.0;
        _targetChannels   = 2;
        _loop             = NO;
        _gain             = 1.0f;
        _chunkFilled      = 0;
        _chunkCursor      = 0;
    }
    return self;
}

- (void)dealloc {
    [self closeFile];
    if (_chunk) {
        free(_chunk);
        _chunk = NULL;
    }
}

- (void)closeFile {
    if (_file) {
        ExtAudioFileDispose(_file);
        _file = NULL;
    }
    if (_reader) {
        [_reader cancelReading];
        _reader = nil;
    }
    _readerOut = nil;
    _decoder = VMDecoderKindNone;
}

- (void)rewind {
    _chunkFilled = 0;
    _chunkCursor = 0;
    _framesReadFromFile = 0;
    _reachedEOF = NO;
    if (_decoder == VMDecoderKindExtAudioFile && _file) {
        ExtAudioFileSeek(_file, 0);
    } else if (_decoder == VMDecoderKindAssetReader) {
        // AssetReader 不支持 seek，只能重建。这里记下路径，重新打开。
        if (_sourcePath) {
            [self _openWithAssetReader:_sourcePath error:NULL];
        }
    }
}

#pragma mark - 打开文件

/// 把「客户端格式」设成虚拟声卡的格式，让解码器负责重采样。
/// 两个后端用同一个目标格式，保证输出一致。
- (AudioStreamBasicDescription)_targetFormat {
    AudioStreamBasicDescription t = {0};
    t.mSampleRate       = _targetSampleRate;
    t.mFormatID         = kAudioFormatLinearPCM;
    t.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;  // Float32
    t.mChannelsPerFrame = _targetChannels;
    t.mBitsPerChannel   = 32;
    t.mBytesPerFrame    = sizeof(float) * _targetChannels;
    t.mFramesPerPacket  = 1;
    t.mBytesPerPacket   = t.mBytesPerFrame;
    return t;
}

/// 分配预读缓存（两个后端共用）
- (BOOL)_allocateChunkWithError:(NSError **)error {
    if (_chunk) { free(_chunk); _chunk = NULL; }
    _chunk = (float *)calloc(kChunkFrames * _targetChannels, sizeof(float));
    if (!_chunk) {
        if (error) *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"内存分配失败"}];
        return NO;
    }
    _chunkFilled = 0;
    _chunkCursor = 0;
    _framesReadFromFile = 0;
    _reachedEOF = NO;
    return YES;
}

- (void)_logOpenedWithPath:(NSString *)path backend:(NSString *)backend {
    NSLog(@"[播放器] 已打开 %@（解码器：%@）", path.lastPathComponent, backend);
    NSLog(@"        源格式 %.0f Hz / %u ch / %u bit",
          _fileFormat.mSampleRate, _fileFormat.mChannelsPerFrame, _fileFormat.mBitsPerChannel);
    NSLog(@"        输出格式 %.0f Hz / %u ch / Float32  (交给虚拟声卡)",
          _targetSampleRate, _targetChannels);
    if (_framesAtTargetRate > 0) {
        NSLog(@"        时长约 %.1f 秒", (double)_framesAtTargetRate / _targetSampleRate);
    }
}

- (BOOL)openFileAtPath:(NSString *)path error:(NSError **)error {
    [self closeFile];
    if (_chunk) { free(_chunk); _chunk = NULL; }
    _sourcePath = [path copy];

    // ---- 第一级：ExtAudioFile（首选，功能最全）----
    NSError *extErr = nil;
    if ([self _openWithExtAudioFile:path error:&extErr]) {
        if (![self _allocateChunkWithError:error]) { [self closeFile]; return NO; }
        [self _logOpenedWithPath:path backend:@"ExtAudioFile"];
        return YES;
    }

    // ---- 第二级：回退 AVAssetReader ----
    // 触发场景：后缀与实际容器不符（例如 .mp3 里装的是 m4a/AAC），
    // ExtAudioFile 只按后缀/魔数挑解析器，此时会报 1685348671 ('dta?')。
    NSLog(@"[播放器] ExtAudioFile 打不开（%d），改用 AVAssetReader 重试：%@",
          (int)extErr.code, path.lastPathComponent);

    NSError *avErr = nil;
    if ([self _openWithAssetReader:path error:&avErr]) {
        if (![self _allocateChunkWithError:error]) { [self closeFile]; return NO; }
        [self _logOpenedWithPath:path backend:@"AVAssetReader"];
        return YES;
    }

    // ---- 两个都失败：报一个能看懂的错 ----
    if (error) {
        NSString *detail = [self _looksLikeMismatchedContainer:path]
            ? @"文件后缀与实际格式不符（例如 .mp3 里其实是 m4a/AAC），且系统解码器无法处理"
            : @"系统无法解码此文件（格式不支持或文件已损坏）";
        *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:extErr.code ?: -1
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"打不开文件：%@。\nExtAudioFile=%d，AVAssetReader=%@",
                                                 detail, (int)extErr.code,
                                                 avErr.localizedDescription ?: @"失败"]}];
    }
    return NO;
}

/// 粗略判断「后缀和真实容器对不上」：读文件头几个字节看品牌串。
/// 用于把报错信息说得更具体，不影响解码流程。
- (BOOL)_looksLikeMismatchedContainer:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:64];
    [fh closeFile];
    if (head.length < 12) return NO;

    NSString *headStr = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
    BOOL isMP4Family = [headStr containsString:@"ftyp"] &&
                       ([headStr containsString:@"M4A "] || [headStr containsString:@"mp42"] ||
                        [headStr containsString:@"isom"] || [headStr containsString:@"M4B "]);
    NSString *ext = path.pathExtension.lowercaseString;
    return isMP4Family && ![ext isEqualToString:@"m4a"] && ![ext isEqualToString:@"mp4"];
}

#pragma mark - 后端一：ExtAudioFile

- (BOOL)_openWithExtAudioFile:(NSString *)path error:(NSError **)error {
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
    OSStatus st = ExtAudioFileOpenURL(url, &_file);
    if (st != noErr || _file == NULL) {
        if (error) *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:st
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"ExtAudioFileOpenURL=%d", (int)st]}];
        return NO;
    }

    AudioStreamBasicDescription target = [self _targetFormat];
    st = ExtAudioFileSetProperty(_file,
                                 kExtAudioFileProperty_ClientDataFormat,
                                 sizeof(target), &target);
    if (st != noErr) {
        if (error) *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:st
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"设置输出格式失败（%d）", (int)st]}];
        [self closeFile];
        return NO;
    }

    // 读一下源文件信息（用于日志和进度）
    UInt32 fmtSize = sizeof(_fileFormat);
    ExtAudioFileGetProperty(_file, kExtAudioFileProperty_FileDataFormat, &fmtSize, &_fileFormat);

    SInt64 fileFrames = 0;
    UInt32 ffSize = sizeof(fileFrames);
    if (ExtAudioFileGetProperty(_file, kExtAudioFileProperty_FileLengthFrames,
                                &ffSize, &fileFrames) == noErr && _fileFormat.mSampleRate > 0) {
        // 把文件长度折算到目标采样率，用于进度百分比
        _framesAtTargetRate = (uint64_t)((double)fileFrames * _targetSampleRate / _fileFormat.mSampleRate);
    } else {
        _framesAtTargetRate = 0;
    }

    _decoder = VMDecoderKindExtAudioFile;
    return YES;
}

#pragma mark - 后端二：AVAssetReader（回退）

/// 回退路径。AVFoundation 按容器内容探测格式，对「后缀骗人」的文件容错好得多。
/// 代价：不支持 seek，rewind 需要重建 reader。
- (BOOL)_openWithAssetReader:(NSString *)path error:(NSError **)error {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *track = tracks.firstObject;
    if (!track) {
        if (error) *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"文件里没有音频轨"}];
        return NO;
    }

    // 让 AVFoundation 直接吐 48kHz/2ch/Float32 interleaved，与我们统一
    NSDictionary *settings = @{
        AVFormatIDKey                    : @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey           : @32,
        AVLinearPCMIsFloatKey            : @YES,
        AVLinearPCMIsBigEndianKey        : @NO,
        AVLinearPCMIsNonInterleavedKey   : @NO,
        AVSampleRateKey                  : @(_targetSampleRate),
        AVNumberOfChannelsKey            : @(_targetChannels),
    };

    NSError *e = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&e];
    if (!reader) {
        if (error) *error = e ?: [NSError errorWithDomain:@"VMAudioFilePlayer" code:-3
                                                 userInfo:@{NSLocalizedDescriptionKey: @"创建 AVAssetReader 失败"}];
        return NO;
    }

    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    out.alwaysCopiesSampleData = NO;   // 减少一次拷贝，实时播放够用
    if (![reader canAddOutput:out]) {
        if (error) *error = [NSError errorWithDomain:@"VMAudioFilePlayer" code:-4
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法为音频轨添加输出"}];
        return NO;
    }
    [reader addOutput:out];

    if (![reader startReading]) {
        if (error) *error = reader.error ?: [NSError errorWithDomain:@"VMAudioFilePlayer" code:-5
                                                            userInfo:@{NSLocalizedDescriptionKey: @"启动解码失败"}];
        return NO;
    }

    _reader    = reader;
    _readerOut = out;

    // 源格式信息：从 track 的格式描述里取，用于 UI 显示
    CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    if (desc) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(desc);
        if (asbd) {
            _fileFormat = *asbd;
        } else {
            memset(&_fileFormat, 0, sizeof(_fileFormat));
        }
    } else {
        memset(&_fileFormat, 0, sizeof(_fileFormat));
    }

    // 总时长 → 目标采样率的帧数（AVAssetReader 拿不到精确帧数，用时长折算）
    CMTime dur = asset.duration;
    if (CMTIME_IS_VALID(dur) && dur.timescale > 0) {
        double secs = CMTimeGetSeconds(dur);
        _framesAtTargetRate = (secs > 0) ? (uint64_t)(secs * _targetSampleRate) : 0;
    } else {
        _framesAtTargetRate = 0;
    }

    _decoder = VMDecoderKindAssetReader;
    return YES;
}

#pragma mark - 预读（ExtAudioFile 后端）

/// 把下一块数据读进 _chunk。返回是否有新数据。
/// ⚠️ 这个函数会碰磁盘，只能从音频回调里"偶尔"调用；
///    但因为每块有 16384 帧（≈340ms @48k），实际频率很低。
///    真正的生产级实现应该用一个独立线程预读 + 环形缓冲；
///    这里为了代码可读性做了简化，如果遇到爆音，请往这个方向优化。
- (BOOL)refillChunk {
    if (_paused) return NO;
    if (_decoder == VMDecoderKindExtAudioFile) return [self _refillFromExtAudioFile];
    if (_decoder == VMDecoderKindAssetReader)  return [self _refillFromAssetReader];
    return NO;
}

/// 把 AssetReader 吐出的 CMSampleBuffer 拷进 _chunk。
/// 注意：SampleBuffer 里的数据可能是「非连续」的（CMBlockBuffer 分段），
/// 所以必须用 CMBlockBufferCopyDataBytes 拷，不能直接取指针算偏移。
- (BOOL)_refillFromAssetReader {
    if (!_readerOut) return NO;

    CMSampleBufferRef sb = [_readerOut copyNextSampleBuffer];
    if (!sb) {
        // 读完了（或出错）。先看是不是要循环。
        if (_loop && _reader) {
            [_reader cancelReading];
            _reader = nil;
            _readerOut = nil;
            if (_sourcePath && [self _openWithAssetReader:_sourcePath error:NULL]) {
                sb = [_readerOut copyNextSampleBuffer];
            }
        }
        if (!sb) {
            _reachedEOF = YES;
            _chunkFilled = 0;
            _chunkCursor = 0;
            return NO;
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) {
        CFRelease(sb);
        _chunkFilled = 0;
        _chunkCursor = 0;
        return NO;
    }

    size_t len      = CMBlockBufferGetDataLength(bb);
    size_t expected = (size_t)kChunkFrames * _targetChannels * sizeof(float);
    size_t toCopy   = (len < expected) ? len : expected;

    OSStatus st = CMBlockBufferCopyDataBytes(bb, 0, toCopy, _chunk);
    CFRelease(sb);

    if (st != noErr || toCopy == 0) {
        _chunkFilled = 0;
        _chunkCursor = 0;
        return NO;
    }

    UInt32 frames = (UInt32)(toCopy / (_targetChannels * sizeof(float)));
    _chunkFilled = frames;
    _chunkCursor = 0;
    _framesReadFromFile += frames;
    _reachedEOF = NO;
    return frames > 0;
}

/// ExtAudioFile 后端的预读
- (BOOL)_refillFromExtAudioFile {
    if (_file == NULL) return NO;

    AudioBufferList bufList = {0};
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = _targetChannels;
    bufList.mBuffers[0].mDataByteSize   = kChunkFrames * _targetChannels * sizeof(float);
    bufList.mBuffers[0].mData           = _chunk;

    UInt32 framesToRead = kChunkFrames;
    OSStatus st = ExtAudioFileRead(_file, &framesToRead, &bufList);

    if (st != noErr) {
        NSLog(@"[播放器] 读取失败 status=%d，按 EOF 处理", (int)st);
        framesToRead = 0;
    }

    if (framesToRead == 0) {
        _reachedEOF = YES;
        if (_loop) {
            // 循环：重新 seek 回开头再读一次
            ExtAudioFileSeek(_file, 0);
            framesToRead = kChunkFrames;
            bufList.mBuffers[0].mDataByteSize = kChunkFrames * _targetChannels * sizeof(float);
            if (ExtAudioFileRead(_file, &framesToRead, &bufList) != noErr) {
                framesToRead = 0;
            }
            _framesReadFromFile = 0;
            _reachedEOF = NO;
            if (framesToRead == 0) return NO;   // 空文件，防死循环
        } else {
            _chunkFilled = 0;
            _chunkCursor = 0;
            return NO;
        }
    }

    _chunkFilled = framesToRead;
    _chunkCursor = 0;
    _framesReadFromFile += framesToRead;
    return YES;
}

#pragma mark - 实时取帧

- (UInt32)renderFrames:(UInt32)frames into:(AudioBufferList *)outData {
    // 目标缓冲是 interleaved Float32
    if (outData->mNumberBuffers == 0) return 0;

    float *dst = (float *)outData->mBuffers[0].mData;
    if (dst == NULL) return 0;

    // 暂停：输出静音，且不推进文件游标（所以恢复后是从原地继续）
    if (_paused) {
        memset(dst, 0, (size_t)frames * _targetChannels * sizeof(float));
        return 0;
    }

    UInt32 totalSamples = frames * _targetChannels;
    UInt32 writtenFrames = 0;

    while (writtenFrames < frames) {
        // 缓存空了就再读一块
        if (_chunkCursor >= _chunkFilled) {
            if (![self refillChunk]) {
                break;      // 文件结束（且不循环）
            }
            if (_chunkFilled == 0) break;
        }

        UInt32 avail = _chunkFilled - _chunkCursor;
        UInt32 want  = frames - writtenFrames;
        UInt32 take  = (avail < want) ? avail : want;

        const float *src = _chunk + (size_t)_chunkCursor * _targetChannels;
        float *out = dst + (size_t)writtenFrames * _targetChannels;

        if (_gain == 1.0f) {
            memcpy(out, src, (size_t)take * _targetChannels * sizeof(float));
        } else {
            // vDSP 做增益比手写循环快，且不会因为编译器优化产生差异
            vDSP_vsmul(src, 1, &_gain, out, 1, (vDSP_Length)(take * _targetChannels));
        }

        _chunkCursor += take;
        writtenFrames += take;
    }

    // 没写满的部分补静音 —— 不补的话会听到上一轮的残留数据（爆音）
    if (writtenFrames < frames) {
        size_t offsetSamples = (size_t)writtenFrames * _targetChannels;
        memset(dst + offsetSamples, 0,
               ((size_t)totalSamples - offsetSamples) * sizeof(float));
    }

    _framesDelivered += writtenFrames;
    return writtenFrames;
}

#pragma mark - 进度

- (double)sourceSampleRate      { return _fileFormat.mSampleRate; }
- (UInt32)sourceChannels        { return _fileFormat.mChannelsPerFrame; }
- (UInt32)sourceBitsPerChannel  { return _fileFormat.mBitsPerChannel; }
- (BOOL)reachedEnd              { return _reachedEOF; }
- (double)durationSeconds {
    if (_targetSampleRate <= 0) return 0.0;
    return (double)_framesAtTargetRate / _targetSampleRate;
}

- (double)progress {
    if (_framesAtTargetRate == 0) return 0.0;
    double p = (double)_framesDelivered / (double)_framesAtTargetRate;
    if (_loop) {
        p = p - floor(p);       // 循环时显示当前这一轮的位置
    }
    return (p < 0.0) ? 0.0 : (p > 1.0 ? 1.0 : p);
}

@end
