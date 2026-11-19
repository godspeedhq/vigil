# 60. A run that ends during a tick can be taken for uncertain past max_runtime

Seen on 2026-11-19 in CI, macOS, `tests/integration/max-runtime.sh`, on the
pull request for docs-only CI (#211, which changes no code):

```text
FAIL  orphan never taken for uncertain while its worker waits
... WARN supervisor job orphan: run 20261119T113422Z-20075-20 is uncertain (past max_runtime, but its job process cannot be proven to be the run's); holding it, killing nothing (on_uncertain = wait)
```

The run itself was right: recorded `timed_out` after its grace, nothing
left running, no lock left behind. Only the uncertain verdict was wrong.

## Reproduced

On the Intel Mac: 25 rounds of the test alone all passed. Three loops at
once beside four CPU burners: 1 of 36 rounds failed the same way. With a
line added (in that copy only) that logs, at the verdict, the job
process, the worker and the job's lock files:

```text
WARN supervisor DIAG job orphan pid 77300:  | worker 76911:  | held=no | locks:
```

By then the run was over: no job process, no worker, no run token and no
timeout marker.

## Cause

Both twins. A tick first gathers the evidence: the run token is held, the
state says `running`, the deadline has passed. Only then does it try to stop
the run (`_vigil_sup_timeout`, `$timeout`). In between, the worker can
finish: after the grace it sends the group KILL, writes the final state,
deletes the marker and lets go of the token. The stop then finds no marker,
tries to prove the job process, finds it gone, and the tick holds the run
as uncertain on evidence that is no longer true. The next tick finds the
run concluded and clears it, so a job is held for one tick and an
`uncertain` is counted for nothing.

## Fix

When the stop cannot prove the job process, look at the run token again.
If no one holds it any more, the run has just ended: leave it alive for
this tick, and the next concludes it from its final state. Only a token
still held, with a job process that cannot be proven, makes the run
uncertain. Nothing unproven is ever killed either way.

Test: the loaded loop above, again, on the Mac; and the max_runtime tests
on every platform.
