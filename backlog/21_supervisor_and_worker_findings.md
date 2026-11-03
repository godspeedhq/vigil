# 21. Two findings from commenting the supervisor and worker

Neither has been seen to go wrong. Both are differences between the twins, found while reading the code.

## The supervisor lock on Linux and macOS is two steps

`vigil_supervise` in `app/lib/posix/supervisor.sh` checks whether another process holds `supervisor.lock`, then opens it. Two supervisors started at the same moment could both pass the check. On Windows, `Supervisor.ps1` opens the lock exclusively in one step, so the second one fails.

The service manager starts one supervisor, so this only matters if someone also runs `vigil supervise` by hand at that same moment. Two supervisors would launch every job twice.

To do: make taking the lock one step. `flock` isn't on macOS by default, so look at `mkdir` or `set -o noclobber`, while keeping the rule that a crashed supervisor leaves nothing to clean up.

## The Windows worker holds a job's output in memory

`Worker.ps1` reads a job's output with `ReadToEndAsync` and keeps it all until the job ends. `worker.sh` sends it to files as it comes. A job that prints a lot uses that much memory on Windows.

To do: stream the output to `<run id>.out` and `<run id>.err` as `worker.sh` does, or cap what is kept. Metrics are already capped at `VigilMetricLinesMax` lines, but that cap doesn't limit what is read.
