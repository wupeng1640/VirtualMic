# Documentation

| File | Covers |
|---|---|
| [architecture.md](architecture.md) | Module boundaries, the real-time callback constraint, why no driver is bundled, what is deliberately absent |
| [aggregate-device.md](aggregate-device.md) | Why some apps ignore BlackHole (`kAudioDeviceTransportTypeVirtual`) and the aggregate-device workaround, with evidence |
| [faq.md](faq.md) | Physical-mic injection, latency, Apple Silicon, SSH, recording, container mismatches |

## Screenshot

`screenshot.png` is the main window during playback:

- **虚拟声卡** — the target device, showing rate and channel counts
- **音频文件** — the chosen file, with a source → target conversion summary
  (`24000 Hz · 1 ch · 0 bit` → `48000 Hz · stereo`) and the duration
- **音量 / 循环播放** — gain slider and loop toggle
- **电平表** — the two bars are the send level and the read-back level
- **状态行** — `正在推送到 BlackHole 2ch`

To regenerate it, capture the window at about 1200px wide, with no personal file
paths visible in the UI, and save it here as `screenshot.png`.
