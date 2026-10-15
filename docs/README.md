# Documentation

| File | Covers |
|---|---|
| [architecture.md](architecture.md) | Module boundaries, the real-time callback constraint, why no driver is bundled, what is deliberately absent |
| [aggregate-device.md](aggregate-device.md) | Why some apps ignore BlackHole (`kAudioDeviceTransportTypeVirtual`) and the aggregate-device workaround, with evidence |
| [faq.md](faq.md) | Physical-mic injection, latency, Apple Silicon, SSH, recording, container mismatches |

## Screenshot

`README.md` and `README.zh-CN.md` reference `docs/screenshot.png`. Drop a
screenshot of the running app there to enable the image; the reference is inside
an HTML comment until then, so a missing file breaks nothing.

Suggested content: the main window with a virtual device selected, a file loaded,
and the level meter showing activity during playback.

Recommended: PNG, ~1200px wide, no personal file paths visible in the UI.
