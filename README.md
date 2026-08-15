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

Then edit the profiles (see below) and start it:

```sh
systemctl --user enable --now rdp-display
```

## Configuring profiles

Mode IDs are specific to your monitor. List them:

```sh
rdp-display modes
```

```
DP-0  (AUS PG32UCDM)
   3840x2160@119.999   scales=[1.0, 1.25, 1.5, 2.0, ...] is-preferred
   2560x1440@120.000   scales=[1.0, 1.25, 1.495, 2.0, ...]
```

Then edit the `PROFILES` block at the top of `rdp-display`:

```python
PROFILES = {
    "local":        {"mode": "3840x2160@119.999", "scale": 1.5},
    "remote":       {"mode": "1920x1080@119.879", "scale": 1.0},
    "remote-1440":  {"mode": "2560x1440@120.000", "scale": 1.0},
    "remote-hidpi": {"mode": "2560x1440@120.000", "scale": 2.0},
}

REMOTE_PROFILE = "remote-hidpi"
LOCAL_PROFILE = "local"
```

The scale must appear in that mode's `scales=` list. Prefer integers — see the
NVENC note above.

**Picking a remote profile.** What matters is how far your client has to shrink
the image. Match the session width to your client window's width and both the
tiny-desktop and giant-cursor problems disappear together. `remote-hidpi`
streams a 1280x720 logical desktop at 1440p: large, sharp, Retina-like, at the
cost of workspace. `remote-1440` gives the most workspace. `remote` sits between.

## Commands

```sh
rdp-display status          # current mode, scale, profile, live session count
rdp-display modes           # every mode this monitor offers, and its scales
rdp-display apply <name>    # force a profile by hand
rdp-display watch           # the watcher (what the systemd unit runs)
```

```sh
journalctl --user -u rdp-display -f    # what it's thinking
systemctl --user stop rdp-display      # kill switch
```

## Tuning

| Setting | Default | Notes |
|---|---|---|
| `POLL_SECONDS` | `0.5` | Fast enough to resize before RDPGFX negotiates |
| `CONNECT_TICKS` | `2` | ~1s. Raising this loses the race and forces a bounce |
| `DISCONNECT_TICKS` | `30` | ~15s. Deliberately slow so reconnects don't flap the monitor |
| `BOUNCE_AFTER_RESIZE` | `False` | Set `True` if video freezes on connect |
| `CONFIRM_DELAY_SECONDS` | `2` | How long to wait for the dialog before pressing Keep |
| `MAX_ASSERTS` | `3` | Give up after this many failed applies in `ASSERT_WINDOW_SECONDS` |

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
