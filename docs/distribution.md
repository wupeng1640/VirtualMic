# Distribution: why the prebuilt app needs one extra step

## The short version

The released `.app` is **not** code-signed with an Apple Developer ID and **not**
notarised. macOS therefore refuses to launch it on first open. To run it:

- **Right-click (or Control-click) the app → Open → Open.** This works once, and
  macOS remembers the choice.
- Or clear the quarantine flag:

  ```bash
  xattr -dr com.apple.quarantine /Applications/VirtualMic.app
  ```

If you would rather not do that — reasonably so — build from source instead:

```bash
make app && open build/VirtualMic.app
```

A locally built binary carries no quarantine attribute and launches normally.

## Why it is not signed

Signing a distributable macOS app requires:

- an **Apple Developer Program** membership (99 USD/year) for a Developer ID
  Application certificate;
- notarisation through Apple's servers, which requires that membership.

This is a self-funded open-source utility, so neither is in place. The
`Makefile` signs with an **ad-hoc** signature (`codesign --sign -`) purely so the
bundle is internally consistent and runs from a local build; ad-hoc signatures
are not a substitute for a Developer ID and Gatekeeper does not accept them.

## What we verified

`spctl` rejects the app **whether or not** the quarantine attribute is present,
because the problem is the missing Developer ID, not the download:

```
$ ditto -x -k VirtualMic-1.0.0-macos.zip .
$ spctl -a -vvv -t exec build/VirtualMic.app
build/VirtualMic.app: rejected

$ xattr -w com.apple.quarantine "0081;...;Safari;" build/VirtualMic.app
$ spctl -a -vvv -t exec build/VirtualMic.app
build/VirtualMic.app: rejected
```

Removing the quarantine attribute does let it run — confirmed by running the
headless self-test on an un-quarantined copy, which passed at 48469 frames/sec
against a 48000 Hz device — but the right-click → Open route is what a normal
user should use, because it keeps macOS's provenance bookkeeping intact.

## Architectures

Releases are **universal** (`arm64` + `x86_64`):

```
$ lipo -info VirtualMic.app/Contents/MacOS/VirtualMic
Architectures in the fat file: ... are: x86_64 arm64
```

`make` builds both by default. For quicker local iteration:

```bash
make ARCHS=arm64
```

## What a release contains

| Asset | Contents |
|---|---|
| `VirtualMic-<version>-macos.zip` | `VirtualMic.app` — the GUI |
| `VirtualMic-<version>-cli-macos.zip` | `vmic` and `aggdev` command-line tools |

The CLI tools are unsigned binaries run from a terminal, so no Gatekeeper prompt
applies; they work as soon as they are unpacked and made executable.

## If you want to sign your own build

With a Developer ID in your keychain:

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" build/VirtualMic.app

xcrun notarytool submit build/VirtualMic.app.zip \
  --keychain-profile "your-profile" --wait

xcrun stapler staple build/VirtualMic.app
```

That is the only way to make the download open with a plain double-click, and it
is the largest known gap between this project and a polished release.
