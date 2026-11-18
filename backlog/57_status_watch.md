# 57. `vigil status --watch`

Asked for on 2026-11-18: a live view of what Vigil is doing, like `ps` or
`top` for its jobs, without rerunning `vigil status` by hand.

## Why not a `vigil ps`

Everything a `ps` would show is in `jobs.log` already: each running job's
PID, how long it has run and how long it has left before `max_runtime`
(§13.2), and the supervisor has proven each of those processes is that run's
(§11). A command that looked at processes itself would be a second, weaker
answer to the same question. What is missing is only the refresh: Linux has
`watch -n2 vigil status`, but macOS and Windows have no `watch`.

## What it does

- `vigil status --watch` prints what `vigil status` prints, again every
  2 seconds, until Ctrl+C.
- Each frame starts with a line saying so, and the time:
  `every 2 s, Ctrl+C to stop: <time>`. At a terminal the screen is cleared
  before each frame, so it reads as one live view; in a pipe the frames
  follow one another.
- It does not change how often the supervisor writes `jobs.log`: once a tick,
  60 seconds by default. A new `jobs.log` shows within 2 seconds of being
  written, and its own first line says when that was.
- When this account cannot read `jobs.log` (§16, a system install on
  Windows), it says so once and exits 1, as `vigil status` does.
- No update notice: it would be cleared with the frame.

Nothing new is stored and nothing is read that `vigil status` does not read.

## Tests

On both platforms: `--watch` against a root with a running supervisor
prints at least two frames in 5 seconds, each with `jobs.log`; with an extra
argument it is a usage error; where `jobs.log` cannot be read it exits 1
after one message, without looping.
