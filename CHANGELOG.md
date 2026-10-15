# Changelog

Notable changes per release. This project follows
[Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-02

First public release.

### Added

- `VirtualMic.app` — GUI with file picker, level meter and progress display.
- `vmic` — command-line tool: `--list`, `--loops`, `--play` with `--device`,
  `--loop`, `--gain`, `--verify`, `--duration`, `--rate`.
- `aggdev` — lists audio devices with transport types and creates aggregate
  devices, as a workaround for apps that filter out `'virt'` transport devices.
- `--selftest` headless verification mode: pushes for three seconds and checks
  the measured frame rate against the device sample rate.
- `scripts/install_blackhole.sh` — builds and installs BlackHole 2ch from
  source, universal `arm64` + `x86_64`.
- `scripts/install-agent.sh` — LaunchAgent that recreates the aggregate device at
  login, since aggregates do not persist.
- Two-stage decoding: `ExtAudioFile` first, `AVAssetReader` as fallback for
  files whose container does not match their extension.

### Notes

- Requires an external loopback device; none is bundled.
- macOS 10.13 or later.
