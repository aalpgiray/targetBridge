# TargetBridge audio driver (optional)

Presents the receiver Mac's speakers as an ordinary output device on the sender
Mac, so they can be picked from the Sound menu or per app instead of only from
inside TargetBridge.

**This is entirely optional.** TargetBridge is fully functional without it. The
app does not install it. Build and install it by hand, then enable the
**Audio Driver** addon. Until both of those are true, nothing in Sound settings
changes.

## When the device is visible

The device is listed only while a sender session is actually streaming to a
connected receiver. A few seconds after the last session stops — link drop,
Stop, or quit — it leaves the Sound menu. A short reconnect that gets a stream
back inside that grace does not remove it and put it back, so the selected
output does not flicker.

The driver itself only knows whether something is answering its probe. The
sender decides when to answer. See `TBAudioDevicePresence`.

## What installing it changes on your Mac

| | |
|---|---|
| Adds | one bundle at `/Library/Audio/Plug-Ins/HAL/TargetBridge.driver` |
| Restarts | the system audio server, which briefly interrupts audio in **all** apps |
| Ends | any plug-in host process that has this driver's binary open (only this one — other vendors' audio drivers are left alone) |
| Needs | admin, for the two steps above |

It writes nothing else, installs no launch agent or daemon, and starts nothing
at login. Removal is `./uninstall.sh`, which deletes the bundle and restarts the
audio server.

The plugin starts with the device published and withdraws it after three
unanswered probes (about three seconds) if the sender is not streaming. That
is one appearance at audio-server start, then the device stays gone until a
receiver is actually streaming.

## Build and install

```sh
./build.sh
./install.sh      # asks for your password
```

`build.sh` produces a universal (arm64 + x86_64) bundle and stamps
`CFBundleVersion` with a hash of `Driver.cpp` and `build.sh`. To remove it:

```sh
./uninstall.sh
```

This tree does not copy the built bundle into the sender app, and there is no
in-app installer button. After `./install.sh`, coreaudiod (or audiomxd) loads
the plugin. Re-run install after a driver change; a stale plugin keeps playing
and looks like the change did nothing.

## How it works

Audio written to the device is forwarded over loopback UDP to the TargetBridge
app, which sends it to the receiver as the existing 16-bit audio frames. The
driver does not open a network connection to the receiver.

The driver withdraws its device when nothing answers the probe — a virtual
device that is still listed but silently dropping everything is worse than no
device at all. It detects this by probing the app's socket rather than
listening on one of its own; see the comments in `Driver.cpp` for why that
distinction matters.

| | |
|---|---|
| Probe | UDP `127.0.0.1:51710`, one byte, once a second |
| "Sender is here" | the probe is not refused |
| Withdraw | three refused probes in a row, then `RemoveDevice` |
| Sender grace | the app keeps the socket bound for 8 seconds after the last stream stops, so one refused probe during a redial does not reach three strikes |

The volume control reports its level and does not scale the samples. The sender
mirrors that level onto the receiver's existing volume packet, so the Sound
slider and the volume keys are the iMac's volume rather than a second digital
gain stage.

## Third-party code

`vendor/libASPL` is [libASPL](https://github.com/gavv/libASPL) by Victor Gaydov,
MIT licensed, vendored unmodified (only `src/` and `include/`; its CMake build,
tests and examples are not used). It implements the AudioServerPlugIn interface,
which is what keeps this driver at a few hundred lines instead of a few thousand
lines of vtable plumbing.

BlackHole was not usable here despite solving a similar problem: it is GPL-3.0
and TargetBridge is MIT.
