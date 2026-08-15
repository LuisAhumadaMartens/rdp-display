# rdp-display — contributor guide

Automatic display profiles for GNOME Remote Desktop. See `README.md` for what it
does and why the design is shaped the way it is.

## Making changes

**Never commit directly to `main` or `dev`.** Work on a branch and open a pull
request against **`dev`**.

Every PR description must state **what changed and why**. The *why* matters more
than usual here: this project exists to work around undocumented platform
behaviour, and several pieces of it look redundant until you know what they
prevent. A PR that only says what it changed is not reviewable.

### Choosing the base branch

Check where you are before creating a branch:

```sh
git rev-parse --abbrev-ref HEAD        # which branch am I on
git fetch origin
git log --oneline origin/main..HEAD    # commits I have that main doesn't
git log --oneline HEAD..origin/main    # commits main has that I don't
```

Then pick the base:

- **On `main`, level with origin** — branch from `main`.
- **Ahead of `main` on a feature branch, and the new change is independent** —
  go back to `main` and branch fresh. Otherwise the PR drags along unrelated
  commits and can't be reviewed or merged on its own.
- **Ahead of `main`, and the new change depends on that unmerged work** — branch
  from the current branch, and say so explicitly in the PR description so the
  reviewer knows it must merge after its parent.

If it isn't obvious which case applies, ask before branching. Rebasing onto the
right base afterwards is more painful than choosing it correctly.

## Commits

**Every single commit must credit the repository owner as co-author:**

```
Co-Authored-By: Luis Ahumada <luis@ahumada.dev>
```

Commits authored by Claude keep their own trailer in addition:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

Both trailers go at the end of the message, after a blank line.

## Code style

**No comments in source files.** Not inline comments, not explanatory block
comments. Let the names carry the meaning — if a line needs explaining, rename
things or extract a function until it doesn't.

The only prose kept in the source is the module docstring in `rdp-display`,
because it's printed as the command's help text. It is functional output, not
commentary.

Everything a reader would otherwise learn from a comment goes in `README.md`
(user-facing) or this file (contributor-facing). That makes the section below
load-bearing rather than a nicety: with no comments in the code, it is the only
record of why several non-obvious pieces exist. **Keep it updated when you change
them.**

**Configuration does not belong in the source.** All tunables live in
`~/.config/rdp-display/config.toml`, with defaults in `DEFAULTS` and a shipped
`config.example.toml`. Adding a new setting means updating all three plus the
README tuning table. Never reintroduce a constant that a user would want to edit.

## Testing a change

Display changes affect the live session, so they can't be tested in isolation:

```sh
rdp-display status                      # mode, scale, profile, session count
rdp-display modes                       # valid mode IDs and their scales
journalctl --user -u rdp-display -f     # what the watcher is doing
systemctl --user restart rdp-display    # pick up an edit
```

Test **both** directions — connect and disconnect. Most bugs here only appear on
one of the two, and the disconnect path is the one nobody is watching.

Be aware that resizing under a live RDP session freezes video while input keeps
working. If that happens while testing, reconnect; it isn't a hang.

## Things that look removable and are not

Each of these was added to fix a specific, reproducible failure. Don't simplify
any of them away without reading the README section that explains it:

- **An integer scale on the remote profile.** Fractional scaling inflates the
  framebuffer past the GPU encoder's limit and silently drops to CPU encoding.
  This only constrains the profile being encoded; the local profile is free.
- **The synthetic `Return` after applying.** gnome-shell's confirmation dialog
  rolls back even a persistent apply, which turns an automated switch into an
  infinite apply/revert loop.
- **The windowed apply counter (`max_asserts` over `assert_window_seconds`).** A
  consecutive-failure counter does not work: a reverted config reads back correct
  during the dialog's countdown, so the counter resets every cycle and never
  trips.
- **Session detection by process name, not port.** GRD negotiates its own port
  and will move off 3389 if anything else holds it.
- **`poll_seconds = 0.5` with `connect_ticks = 2`.** The resize has to land
  before GRD negotiates its graphics pipeline, roughly one second after the TCP
  connection. Polling slower means every connect needs a reconnect.
