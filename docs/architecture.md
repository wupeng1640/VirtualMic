# Architecture

Why this project is shaped the way it is.

## The one hard constraint

macOS cannot inject audio into a physical microphone. The signal path from a
built-in mic runs one way, mic → system; there is no software entry point. This
is a design property of the OS, not a missing permission, so no amount of
signing or entitlement work changes it.

Therefore the problem reduces to: **produce audio somewhere that apps will
accept as a microphone.** macOS supports exactly one such place —
a *loopback* (virtual) audio device, a HAL plugin that presents an output side
and an input side internally wired together.

That gives the whole design:

```
file → decode → resample → write to loopback's output → loopback's input → app
```

Everything this project does is the first four steps. The last two are the
driver's job and already work.

## Why not write a driver

A HAL plugin means: code signing with a Developer ID, notarisation, a reboot or
a `coreaudiod` restart, and for some configurations disabling SIP. The result
would be functionally identical to BlackHole. That is a large amount of
irreversible friction for zero functional gain, so this project depends on an
existing driver instead and keeps its own scope narrow.

`scripts/install_blackhole.sh` exists because installing that dependency should
still be one command. It builds BlackHole from source unprompted for a mundane
reason: the project's download page sits behind Cloudflare, and only the source
tarball is reliably reachable. BlackHole is a single C file, so compiling it is
one `clang` invocation.

## Module boundaries

The four source modules correspond to four distinct problems, and the seams
between them are where the interesting decisions live.

### `VMAudioDevice` — finding the device

Writes the device *lookup* logic. The important decision:

**Never store an `AudioDeviceID`.** IDs are assigned by `coreaudiod` and change
whenever a device is plugged, unplugged, or the daemon restarts. A tool that
hardcodes an ID works until the first reboot and then silently writes to the
wrong device. This module resolves by **UID** (stable) or by name (fuzzy,
convenient), every time.

It also classifies devices by transport type, which is what makes
`vmic --loops` possible and what the aggregate-device workaround is built on —
see [aggregate-device.md](aggregate-device.md).

### `VMAudioFilePlayer` — decoding without blocking

Converts an arbitrary file into a stream of frames at the target rate, format
and channel count.

The implementation constraint that shapes this whole module: **the render
callback runs on a real-time thread owned by CoreAudio.** It is called on
CoreAudio's schedule, and it must return the requested number of frames
immediately. It cannot allocate, take locks, hit the filesystem, or block.

So the player is written as a *pull* source — `renderFrames:into:` returns
exactly what is asked — rather than a background thread pushing data. A pushing
thread would either starve the callback (silence, clicks) or overrun it (dropped
frames). `renderFrames:` never blocks: the file is read ahead into a ring buffer
on a separate thread, and if the buffer does run dry it emits silence rather than
waiting, because a callback that returns late is worse than a brief gap.

Two decoders are tried in order:

1. **`ExtAudioFile`** (AudioToolbox) — preferred; handles rate conversion and
   channel mapping natively via a single `AudioConverter`.
2. **`AVAssetReader`** (AVFoundation) — fallback for files whose extension lies
   about their container. An `.mp3` that is really an M4A/AAC container is
   common enough that `ExtAudioFileOpenURL` failing is not a rare edge case.

A third `ffmpeg` fallback was considered and rejected: it adds an external
dependency for genuinely malformed input, and such a file is better converted
once by the user.

### `VMRoute` — writing to the device

Owns the HAL output `AudioUnit` bound to the chosen device, and copies frames
from the player into CoreAudio's buffer in the render callback.

It also implements the honest verification path. Counting frames we *sent* only
proves the callback ran; it says nothing about whether audio reached the device.
`captureLoopback` therefore opens the same device's **input** side and measures
the peak of what comes back. If the send counter climbs while the read-back peak
stays at zero, the audio is going nowhere — and `--verify` reports that instead
of a reassuring frame count.

### GUI vs CLI — one core, two front ends

`VMMainWindowController` and `main.m` both drive the same three classes. The GUI
adds a file picker, a level meter and a progress bar; the CLI adds argument
parsing, `--duration` and the headless self-test. Neither contains audio logic.

This is deliberate: a bug report can be reproduced from the command line, and
the self-test mode runs where there is no window server.

## Build system

A `Makefile`, not an Xcode project. The entire program is four frameworks' worth
of Objective-C and about 2,000 lines; an `.xcodeproj` would be a larger artifact
than the code, unreviewable in a diff, and unusable over SSH. `make` targets are
readable and the build is reproducible with the command line tools alone.

`-mmacosx-version-min=10.13` is set explicitly so the tool runs on machines older
than the build machine.

## What is deliberately absent

- **No network code.** Not a single socket. Files are decoded and written to a
  local device, which is worth stating plainly since "virtual microphone"
  naturally raises the question of where the audio goes.
- **No preference file.** Device and file are chosen per run. Persisting them
  adds a stale-state failure mode — a saved device ID that no longer exists —
  for very little convenience.
- **No bundled driver.** See above.
