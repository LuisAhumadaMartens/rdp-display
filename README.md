# rdp-display

Automatic display profiles for GNOME Remote Desktop.

When you connect over RDP, your desktop switches to a resolution and scale that
suits the machine you're connecting *from*. When you disconnect, the monitor
goes back to its native setup. No dialogs, no manual steps.

```
connected  ->  2560x1440 @120Hz, scale 200%   (looks native on a MacBook)
idle       ->  3840x2160 @120Hz, scale 150%   (the monitor's own setup)
```

## The problem

Sharing a 4K desktop over RDP to a laptop is unpleasant. The client shrinks the
image to fit its window, so everything is tiny — but the mouse pointer travels
over RDP's *separate pointer channel* as a fixed-size bitmap that the shrink
never touches. You end up with a doll's-house desktop and an enormous cursor.

Lowering the resolution fixes it, but nobody wants their monitor stuck at 1080p
permanently. So: switch on connect, switch back on disconnect.

That turns out to be much harder than it sounds, for four reasons that are not
documented anywhere obvious.

## Four things that make this hard

**Fractional scaling breaks hardware encoding.** Mutter implements fractional
scales by rendering into an oversized framebuffer and downscaling — 4K at 150%
becomes 5120x2880. NVIDIA's Pascal H.264 encoder caps at 4096px, so it fails
with `Frame Dimension greater than the maximum supported value` and silently
falls back to CPU encoding. **Only integer scales (100%, 200%) keep the
framebuffer at native size.** Every profile here uses one.

**GNOME Remote Desktop negotiates its graphics pipeline once, at connect.**
Resize the display under a live session and the encoder stays sized for the old
framebuffer: the picture freezes while the keyboard still works. The only cure
is a reconnect — so the resize has to land *before* the pipeline is negotiated,
about a second after the TCP connection. That's why this polls twice a second
and reacts to a new session in ~1s.

**gnome-shell's "Keep Changes" dialog reverts your config even when you asked
for a persistent apply.** `ApplyMonitorsConfig` with method 2 is documented as
persistent, and it still raises the confirmation OSD. Unattended, the OSD times
out and rolls the change back — so an automated switch applies, reverts,
re-applies, forever. This sends a synthetic `Return` to press "Keep Changes",
which is the dialog's default action (`Escape` is bound to "Revert Settings").

**Don't use "Remote Login" (the headless system daemon) for this.** It
authenticates and then redirects the client to a handover daemon where NLA
fails against some clients with `MIC verification failed` /
`SEC_E_MESSAGE_ALTERED`. That's a FreeRDP interop bug, not a bad password.
"Desktop Sharing" — the per-user service — has no handover step and works.
Disable the system unit or it holds port 3389 and your user daemon quietly
negotiates itself onto 3390.

## Requirements

- GNOME 46+ on **X11** (the confirmation keystroke uses `xdotool`)
- `gnome-remote-desktop` with **Desktop Sharing** enabled
- Python 3.11+ (for `tomllib`)
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
first run, and never overwrites it afterwards. Edit it, then start the watcher:

```sh
systemctl --user enable --now rdp-display
```

## Configuration

All settings live in `~/.config/rdp-display/config.toml` (override the path with
`RDP_DISPLAY_CONFIG`). Nothing needs editing inside the script, so upgrades don't
clobber your setup.

Mode IDs are specific to your monitor. List them — this works without a config:

```sh
rdp-display modes
```

```
DP-0  (AUS PG32UCDM)
   3840x2160@119.999   scales=[1.0, 1.25, 1.5, 2.0, ...] is-preferred
   2560x1440@120.000   scales=[1.0, 1.25, 1.495, 2.0, ...]
```

Then write them into the config:

```toml
connector = ""

remote_profile = "remote-hidpi"
local_profile = "local"

[profiles.local]
mode = "3840x2160@119.999"
scale = 1.5

[profiles.remote-hidpi]
mode = "2560x1440@120.000"
scale = 2.0
```

`connector = ""` auto-detects the primary monitor. The scale must appear in that
mode's `scales=` list.

Only the **remote** profile has to use an integer scale — it's the one being
encoded. The local profile is whatever you like at your desk; a fractional scale
there costs nothing because nothing is streaming it.

Check it parsed before starting the service:

```sh
rdp-display config
```

**Picking a remote profile.** What matters is how far your client has to shrink
the image. Match the session width to your client window's width and both the
tiny-desktop and giant-cursor problems disappear together. `remote-hidpi`
streams a 1280x720 logical desktop at 1440p: large, sharp, Retina-like, at the
cost of workspace. `remote-1440` gives the most workspace. `remote` sits between.

## Commands

```sh
rdp-display status          # current mode, scale, profile, live session count
rdp-display modes           # every mode this monitor offers, and its scales
rdp-display config          # the loaded configuration and where it came from
rdp-display apply <name>    # force a profile by hand
rdp-display watch           # the watcher (what the systemd unit runs)
```

```sh
journalctl --user -u rdp-display -f    # what it's thinking
systemctl --user stop rdp-display      # kill switch
```

## Tuning

| Key | Default | Notes |
|---|---|---|
| `poll_seconds` | `0.5` | Fast enough to resize before RDPGFX negotiates |
| `connect_ticks` | `2` | ~1s. Raising this loses the race and forces a bounce |
| `disconnect_ticks` | `30` | ~15s. Deliberately slow so reconnects don't flap the monitor |
| `bounce_after_resize` | `false` | Set `true` if video freezes on connect |
| `confirm_delay_seconds` | `2.0` | How long to wait for the dialog before pressing Keep |
| `reconnect_grace_seconds` | `60` | Ignore the session gap caused by a deliberate bounce |
| `max_asserts` | `3` | Give up after this many applies within `assert_window_seconds` |
| `assert_window_seconds` | `900` | Window the giveup budget is counted over |

## Troubleshooting

**Picture frozen on connect, keyboard still works.** The resize lost the race
against pipeline negotiation. Set `BOUNCE_AFTER_RESIZE = True` — it guarantees a
correctly-sized session at the cost of one manual reconnect.

**Monitor flips back and forth after disconnect.** The confirmation keystroke
isn't landing. Check `xdotool` is installed and that the service has `DISPLAY`
and `XAUTHORITY` (`systemctl --user show-environment`). The watcher gives up
after `MAX_ASSERTS` rather than looping forever, and logs `keeps getting
reverted`.

**Nothing happens on connect.** Session detection counts established TCP
connections owned by `gnome-remote-de` — matching the process rather than a port,
so it survives GRD's port negotiation. Verify with `rdp-display status`.

**Encoding is slow / high CPU.** Check for `NVENC: Frame Dimension greater than
the maximum supported value` in `journalctl --user -u gnome-remote-desktop`. That
means a fractional scale inflated the framebuffer past your encoder's limit.

## Do you even need this?

If your remote and idle profiles are the same, you don't. Pin one and skip the
moving parts entirely:

```sh
systemctl --user disable --now rdp-display
rdp-display apply remote-hidpi
```

`ApplyMonitorsConfig` writes persistently, so that survives reboots and power
cuts on its own. The watcher earns its keep when you move between sitting at the
machine and connecting remotely; for "I'm away for a week and want my desktop
occasionally," a pinned profile has no failure modes at all.

## Wayland

Not supported. The confirmation keystroke uses `xdotool`, which is X11-only.
A Wayland port would need to answer the dialog through AT-SPI instead.

## License

MIT
