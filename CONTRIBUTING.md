# Contributing

Thanks for considering a contribution.

## Before you open a pull request

```bash
make            # must build clean
make test FILE=<some audio file> DEVICE="BlackHole 2ch"
```

`make test` runs the headless path: it pushes for three seconds and verifies that
the frame rate matches the device's sample rate within 5%. A change that breaks
audio delivery should fail this.

If you cannot run the audio test (no loopback device installed), say so in the
PR description — it is fine, but it must be stated rather than implied.

## What is welcome

- Bug fixes, especially around decoding odd containers or device lookup
- Support for other loopback devices beyond BlackHole
- Documentation improvements — including corrections to anything that turned
  out to be wrong
- Ports of the aggregate-device workaround to other affected apps, with evidence

## What needs discussion first

Open an issue before writing code for:

- **Adding a dependency.** The project deliberately uses system frameworks only.
- **Writing a HAL driver.** The reasoning against it is in
  [docs/architecture.md](docs/architecture.md); argue with that reasoning first.
- **Adding a preference file or persistent state.**
- **Renaming public classes or the CLI flags.**

## Style

- Objective-C with ARC. Match the surrounding file.
- Comments explain **why**, not what. A comment restating the code is noise; a
  comment recording a constraint (why a lookup is by UID, why a callback cannot
  block) is the valuable kind. Existing files show the intended tone.
- Keep files under ~500 lines. If one grows past that, it is usually doing two
  jobs.
- No new compiler warnings.

## Reporting a bug

Include:

- macOS version and CPU architecture
- Which loopback device, and `./build/aggdev --list` output
- The exact command or the GUI steps
- What you expected, what happened
- If it is about a file: `file <the file>` and `ffprobe <the file>` output

For "the app does not see the device", run `./build/aggdev --list` first — if
your device shows `'virt'`, that is the documented issue in
[docs/aggregate-device.md](docs/aggregate-device.md), not a new bug.

## License

Contributions are accepted under the MIT license, matching [LICENSE](LICENSE).
