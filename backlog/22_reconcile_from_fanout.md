# 22. Reconciling a run should look in the fan-out too

When a worker dies after writing its events but before its final state, the supervisor reconciles the run from its spool file. That file proves the run finished, and how (`_vigil_sup_spool` in `supervisor.sh`, `Find-VigilSpoolOutcome` in `Supervisor.ps1`). It looks in `spool/incoming/` and in each backend's queue under `spool/backends/`. It doesn't look in `spool/fanout/`, where the sender moves each file while it copies it to the queues.

If the supervisor checks at the very moment a run's file is in `fanout/`, a run that finished is recorded as crashed, and counted in `<metric>.crashes`. Its metrics are still delivered: only the record of how it ended is wrong.

Found while commenting the sender; never seen to happen. The window is the time the sender takes to copy one file to each queue.

## To do
- Look in `spool/fanout/` as well, in both twins.
- A test in `supervise.sh` and `Supervise.ps1`: a run with no final state whose events sit in `fanout/` is recorded as finished, not crashed.
