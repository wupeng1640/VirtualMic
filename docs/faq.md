# FAQ

### Why can't it just write into my built-in microphone?

Because that is physical hardware and the audio path is one-directional: samples
travel from the microphone to the system, never the reverse. There is no software
injection point regardless of permissions or entitlements. Every tool in this
space works around it the same way — with a virtual device.

### Do I need a driver?

You need *a* loopback device; you do not need one written by this project.
BlackHole is the usual pick. Writing a HAL plugin from scratch requires a
Developer ID, notarisation, and a reboot — for output identical to BlackHole's.
See [architecture.md](architecture.md) for the full reasoning.

### Which apps does this work with?

Anything that lets you choose an input device: Zoom, Teams, Meet, Discord, OBS,
Tencent Meeting, WeChat, QuickTime, Audacity, browsers. If an app ignores virtual
devices specifically, see [aggregate-device.md](aggregate-device.md).

### Can I send a file and still use my real microphone at the same time?

Not with a single device — the affected app reads one input. Two common
approaches:

- include your real microphone **and** BlackHole as sub-devices of the aggregate,
  then let the app capture both channels;
- or keep the tool for pre-recorded segments and toggle the app's input when you
  switch.

### Does it work on Apple Silicon?

Yes, and `scripts/install_blackhole.sh` builds a universal (`arm64` + `x86_64`)
driver so the same install works on both.

### Does it work over SSH / in CI?

Audio device *access* does not exist in a session with no audio context, so this
is not useful over plain SSH. The headless self-test
(`VirtualMic --selftest <file>`) is meant for a logged-in session without an
interactive window, for example a local CI runner.

### How much latency is there?

The dominant term is the device's own buffer size, typically a few milliseconds.
`VMRoute` uses a 512-frame callback for the local send path. For prerecorded
audio this is irrelevant, since nothing is synchronised to a live source.

### Can it record what the virtual device receives?

`--verify` reads the input side and reports a peak level, which is enough to
prove the loopback is live. It is not a recorder — deliberately, since writing
audio to disk raises a different set of questions and OBS or Audacity already do
that job well.

### What happens if the file ends mid-sentence?

Playback stops and the device goes quiet. With `--loop` it restarts. There is no
automatic crossfade or filler, because silence is the honest behaviour when the
source is merely a file that has finished.

### Is any of my audio uploaded?

No. There is no networking code in this project at all. Decoding and writing both
happen locally, to a local device.

### Why is `ExtAudioFile` preferred over `AVAssetReader`?

`ExtAudioFile` handles sample-rate conversion and channel mapping in one
`AudioConverter`, with no intermediate object graph, and it reads incrementally
without buffering the whole file. `AVAssetReader` is the fallback for containers
whose extension misrepresents them — common with `.mp3` files that are actually
M4A/AAC.

### A `.mp3` fails to open. What now?

Check whether it is really an MP3:

```bash
file your-audio.mp3
ffprobe your-audio.mp3
```

If it reports M4A/AAC, the fallback decoder should handle it; if both decoders
refuse the container is malformed. Convert it once:

```bash
ffmpeg -i in.mp3 -ar 48000 -ac 2 out.wav
```

There is no bundled `ffmpeg` fallback — see [architecture.md](architecture.md).

### Does changing the macOS output device affect this?

No. `VMRoute` binds the AudioUnit to a specific device by ID at start time and
does not follow the system default. Changing your output device does not
interrupt an in-flight push.
