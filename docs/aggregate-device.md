# When an app ignores your virtual microphone

## The symptom

BlackHole 2ch (or any other virtual device) is installed and works — the system
Sound settings list it, `vmic --loops` finds it, you can play audio into it — but
one particular app's microphone dropdown simply does not offer it.

## The cause

Some apps do not enumerate audio devices naively. They filter the list, and the
filter rejects virtual devices. The usual implementation reads
`kAudioDevicePropertyTransportType` and keeps only known-good transports:

```objc
// representative of the filter found in affected apps
if (transportType == kAudioDeviceTransportTypeVirtual)
    continue;   // 'virt' → not a real microphone, skip
```

`BlackHole 2ch` reports `kAudioDeviceTransportTypeVirtual` (`'virt'`). So do
`Cast Audio`, `NeCastAudio`, and essentially every loopback device. They are all
dropped before the dropdown is populated.

This is a deliberate-looking choice by those apps (a `'virt'` device is not a
capture source a user would normally speak into), not a bug in BlackHole and not
something BlackHole can fix from its side.

## Seeing it for yourself

```bash
./build/aggdev --list
```

prints every device with its transport type, and marks the ones likely to be
ignored:

```
ID     名称                             transport
------------------------------------------------------------
106    Cast Audio                       'virt'   <- may be ignored by some apps
112    Cast Audio (UI Sounds)           'virt'   <- may be ignored by some apps
53     BlackHole 2ch                    'virt'   <- may be ignored by some apps
101    MacBook Pro麦克风                 'bltn'
94     MacBook Pro扬声器                 'bltn'
126    NeCastAudio B                    'virt'   <- may be ignored by some apps
132    BH Aggregate                     'grup'
```

`'bltn'` is built-in, `'virt'` is virtual, `'grup'` is an aggregate device. Note
that the aggregate at the bottom *is* visible to those apps.

## The workaround

An **aggregate device** reports `kAudioDeviceTransportTypeAggregate` (`'grup'`),
which survives the filter. Wrap BlackHole in one:

```bash
./scripts/make_agg.sh                 # creates "BH Aggregate"
./scripts/make_agg.sh "My Audio"      # custom name
./scripts/make_agg.sh --remove        # remove it
```

Then select **BH Aggregate** — not BlackHole — both as the target for
`vmic --play --device` and as the microphone inside the affected app.

The aggregate contains BlackHole 2ch as a sub-device, so the loopback still
happens; only the transport type in the device description changes.

```
        what the app sees                 what actually moves audio
   ┌──────────────────────┐          ┌───────────────────────────┐
   │  BH Aggregate        │          │  BlackHole 2ch            │
   │  transport = 'grup'  │  ──────► │  Output ← VMRoute writes  │
   │  ✓ passes the filter │          │  Input  → apps read       │
   └──────────────────────┘          └───────────────────────────┘
```

## Aggregates do not persist

`AudioHardwareCreateAggregateDevice` creates a transient object: it is gone
after a reboot, and `coreaudiod` restarting can drop it too. Two options:

**Recreate by hand** when needed:

```bash
./scripts/make_agg.sh
```

**Or automate it at login:**

```bash
./scripts/install-agent.sh      # installs a LaunchAgent
./scripts/uninstall-agent.sh    # removes it
```

The LaunchAgent runs `scripts/agent_wrapper.sh` at login. That script is
idempotent — it checks whether the aggregate already exists and only creates it
if not, so it is safe to run repeatedly and safe to run alongside a manual
`make_agg.sh`.

Logs go to `~/Library/Logs/VirtualMic-aggdev.log`.

## Caveats

- Creating an aggregate device needs no special permission, but it does require
  the process to be able to talk to `coreaudiod` — a normal user session is
  enough. It does **not** work over SSH in a session with no audio access.
- If the aggregate includes a physical device that is currently disconnected,
  macOS may keep a broken device in the list. `make_agg.sh --remove` followed by
  a recreate clears it.
- Some apps additionally require the device to have more than zero input
  channels. BlackHole 2ch has two, so the aggregate inherits two and this is not
  an issue here — but a loopback device with only output channels would still be
  filtered out.
