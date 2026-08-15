# rdp-display

Switches your desktop resolution when you connect over GNOME Remote Desktop, and
switches it back when you disconnect.

```
connected  ->  a resolution and scale that suit the machine you connect from
idle       ->  whatever your monitor normally runs
```

## Why

A 4K desktop viewed over RDP on a laptop is hard to use. The client shrinks the
image to fit its screen, so everything is small — but the mouse pointer arrives
on a separate RDP channel as a fixed-size bitmap that the shrink doesn't touch.
You get a small desktop with a very large cursor.

Lowering the session resolution fixes both at once, because it removes the
shrink. But leaving the monitor at that resolution when you're back at your desk
is no good, so it has to change on its own.

## How it works

A systemd user service polls twice a second for established TCP connections
owned by the `gnome-remote-desktop` process. When one appears it applies the
remote profile; when the last one goes it applies the local profile. Display
changes go through mutter's `ApplyMonitorsConfig` D-Bus method, the same one the
Settings panel uses.

Four platform behaviours shaped the design. Each explains a piece of the code
that otherwise looks unnecessary.

**Fractional scaling breaks hardware encoding.** Mutter implements fractional
scales by rendering into a larger framebuffer and scaling down: 4K at 150%
becomes 5120x2880. NVIDIA's Pascal H.264 encoder stops at 4096px, so it fails
with `Frame Dimension greater than the maximum supported value` and falls back to
CPU encoding without saying so. Integer scales keep the framebuffer at native
size. This only constrains the profile being encoded — the local one is free.

**GNOME Remote Desktop negotiates its graphics pipeline once, at connect.**
Resizing under a live session leaves the encoder sized for the old framebuffer:
the picture freezes while the keyboard still works. The resize has to land before
that negotiation, about a second after the TCP connection, which is why the poll
interval is short. If it misses, the only cure is reconnecting.

**The "Keep Changes" dialog reverts your config.** `ApplyMonitorsConfig` with
method 2 is documented as persistent and still raises the confirmation dialog.
Unattended, it times out and rolls the change back, so an automated switch
applies, reverts and reapplies forever. This sends a synthetic `Return`, which
is the dialog's default action.

**Use Desktop Sharing, not Remote Login.** Remote Login authenticates and then
redirects the client to a handover daemon, where NLA fails against some clients
with `MIC verification failed`. That is a FreeRDP interoperability bug, not a bad
password. Desktop Sharing has no handover step. Disable the system unit too, or
it holds port 3389 and the user daemon moves itself to 3390.

## Requirements

- GNOME 46+ on X11 (the confirmation keystroke uses `xdotool`; Wayland is not
  supported)
- `gnome-remote-desktop` with Desktop Sharing enabled
- Python 3.11+
- `xdotool`, `python3-gi`, `iproute2`

```sh
sudo apt install xdotool python3-gi iproute2
```

## Install

```sh
git clone https://github.com/LuisAhumadaMartens/rdp-display.git
cd rdp-display
./install.sh
```

`install.sh` creates `~/.config/rdp-display/config.toml` from the example on
first run and never overwrites it afterwards. Edit it, then start the service:

```sh
systemctl --user enable --now rdp-display
```

## Configuration

Everything lives in `~/.config/rdp-display/config.toml`. Override the path with
`RDP_DISPLAY_CONFIG`. Nothing needs editing inside the script, so upgrades leave
your settings alone.

Mode IDs differ per monitor. List yours — this works without a config:

```sh
rdp-display modes
```

```
DP-1  (<vendor> <model>)
   3840x2160@60.000    scales=[1.0, 1.25, 1.5, 2.0, ...] is-preferred
   2560x1440@60.000    scales=[1.0, 1.25, 1.5, 2.0, ...]
```

Then write them in. Mode IDs must be copied exactly from your own output — the
values below are only an example:

```toml
connector = ""

remote_profile = "remote"
local_profile = "local"

[profiles.local]
mode = "3840x2160@60.000"
scale = 1.5

[profiles.remote]
mode = "2560x1440@60.000"
scale = 2.0
```

`connector = ""` picks the primary monitor. The scale must appear in that mode's
`scales=` list.

Check it parsed before starting the service:

```sh
rdp-display config
```

### Choosing a remote profile

What matters is how far your client has to shrink the image. Match the session
width to your client window's width and both problems go away together.

Scale is the second lever. A mode at scale 1.0 gives you its full resolution as
working space. The same mode at scale 2.0 gives you a quarter of the pixels as
working space, drawn twice as large — sharp and easy to read on a high-density
laptop screen, with less room to work in. Try a few; the example config includes
several to compare.

### Settings

| Key | Default | Notes |
|---|---|---|
| `connector` | `""` | Empty picks the primary monitor |
| `poll_seconds` | `0.5` | Fast enough to resize before the pipeline is negotiated |
| `connect_ticks` | `2` | ~1s. Higher loses that race and forces a reconnect |
| `disconnect_ticks` | `30` | ~15s. Slow on purpose, so reconnects don't flap the monitor |
| `bounce_after_resize` | `false` | Set `true` if the picture freezes on connect |
| `confirm_delay_seconds` | `2.0` | How long to wait for the dialog before answering it |
| `reconnect_grace_seconds` | `60` | Ignores the session gap a deliberate restart causes |
| `max_asserts` | `3` | Give up after this many applies within the window below |
| `assert_window_seconds` | `900` | Window the giveup budget is counted over |

## Commands

```sh
rdp-display status          # current mode, scale, profile, session count
rdp-display modes           # every mode this monitor offers, and its scales
rdp-display config          # the loaded configuration and where it came from
rdp-display apply <name>    # set a profile by hand
rdp-display watch           # the watcher, which the service runs
```

```sh
journalctl --user -u rdp-display -f
systemctl --user stop rdp-display
```

## Troubleshooting

**Picture frozen on connect, keyboard still works.** The resize missed the
negotiation window. Set `bounce_after_resize = true`, which guarantees a
correctly sized session at the cost of one manual reconnect.

**The monitor keeps switching back and forth.** The confirmation keystroke isn't
landing. Check `xdotool` is installed and that the service has `DISPLAY` and
`XAUTHORITY` (`systemctl --user show-environment`). The watcher gives up after
`max_asserts` rather than looping, and logs `keeps reverting`.

**Nothing happens on connect.** Sessions are counted by looking for established
connections owned by `gnome-remote-de`, so port changes don't matter. Check
`rdp-display status`.

**Encoding is slow.** Look for `NVENC: Frame Dimension greater than the maximum
supported value` in `journalctl --user -u gnome-remote-desktop`. A fractional
scale has pushed the framebuffer past the encoder's limit.

## If you only want one resolution

If your remote and local profiles would be the same, you don't need the service:

```sh
systemctl --user disable --now rdp-display
rdp-display apply remote
```

`ApplyMonitorsConfig` writes persistently, so that survives reboots on its own.
The service is worth running when you move between sitting at the machine and
connecting to it; for a machine you're away from for a week, a fixed profile has
nothing that can go wrong.

## Attribution

Written by Claude (Anthropic's Claude Opus 5) running autonomously in Claude
Code. Claude did the investigation, wrote the code and this README, and diagnosed
each of the four platform behaviours described above from logs and D-Bus
introspection. The repository owner set the goals and tested every iteration on
real hardware.

## License

MIT
