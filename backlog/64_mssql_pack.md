# 64. A pack for Microsoft SQL Server

Asked for on 2026-11-20: "very detailed". A pack, `mssql`, for SQL Server
2019, 2022 and 2025, on Linux and Windows, watched from Linux, macOS and
Windows, read-only, with everything SQL Server says about itself that is
cheap to read and carries no query text.

## How it reads SQL Server

- **Linux and macOS:** `sqlcmd`, either Microsoft's ODBC one
  (`mssql-tools18`) or the Go one (`go-sqlcmd`). The scripts use only the
  options both share, and read rows as tab-separated text.
- **Windows:** .NET's own SQL Server client, `System.Data.SqlClient`, with
  nothing to install, where the PowerShell running the job has it. Where it
  has not, `sqlcmd`. Which shells have it is checked first.
- **The login:** `MSSQL_USER` (default `vigil_monitor`) with its password in
  the environment, `SQLCMDPASSWORD`, from `secret:MSSQL_MONITOR_PASSWORD`:
  never on a command line. Or, on Windows, the account Vigil runs as
  (`MSSQL_AUTH=windows`), with no password at all.
- **TLS:** encrypted, with the server's certificate verified, always.
  `MSSQL_CACERT` names a CA file on Linux and macOS; Windows uses its own
  certificate store. There is no setting that turns verification off.
- **One query per job**, short, with a lock timeout and a query timeout, at
  `READ UNCOMMITTED` where SQL Server allows, so a job never waits behind a
  blocked server and never blocks one.

## The login, and its rights

Read-only. Created once by an administrator:

```sql
CREATE LOGIN vigil_monitor WITH PASSWORD = '...';
-- 2022 and later:
GRANT VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE, VIEW ANY DATABASE TO vigil_monitor;
-- 2019:
GRANT VIEW SERVER STATE, VIEW ANY DATABASE TO vigil_monitor;
```

and for `mssql_agent`, a user in `msdb` with `SELECT` on `sysjobs`,
`sysjobhistory`, `sysjobactivity` and `syssessions` (`SQLAgentReaderRole`
does not give it: it works through Agent's procedures). Backups need
nothing more: `public` may read `msdb`'s backup history. Each grant is checked against 2019,
2022 and 2025 before it is written into `needs`; a job whose right is
missing fails, saying which.

## Jobs and metrics

Metric names are `mssql.<job>.<name>`; per-database lines carry `db=`,
per-file `db=` and `file=`. Counts of things like waits are capped (the top
N, the rest summed), so a server with many databases or files sends more
lines, but never without bound. Counters are running totals since SQL
Server started: graph them as rates.

### On by default

| Job | Every | What |
| --- | --- | --- |
| `mssql_status` | 1m | up; info (version, CU, edition, engine, Linux or Windows, clustered, Always On enabled, current cluster node); uptime; CPUs and schedulers; user connections and the most allowed; whether SQL Agent's service runs |
| `mssql_performance` | 1m | from SQL Server's counters: batch requests, transactions, compilations, recompilations, logins, logouts, errors, page life expectancy, buffer cache hit ratio, lazy writes, checkpoint pages, pages read and written, lock waits, lock timeouts, deadlocks, page splits, full scans, memory grants pending and outstanding, processes blocked; missing-index suggestions (count, biggest estimated gain) |
| `mssql_activity` | 1m | sessions by state; requests running and blocked; head blockers; the longest request, the oldest open transaction, the longest wait and its type; sessions asleep with a transaction open, and for how long; long snapshot transactions |
| `mssql_cpu` | 1m | CPU used by SQL Server and by the rest of the machine (its scheduler history); runnable tasks waiting; worker threads in use and the most allowed; pending disk I/O on the schedulers |
| `mssql_replication` | 1m | Always On: each replica's role, connection, synchronization state and health; each database's log send and redo queues and rates, and estimated lag. Quiet with no availability group |
| `mssql_waits` | 5m | the top wait types, and totals by kind: CPU (signal), disk reads, locks, log writes, memory grants, network, other |
| `mssql_io` | 5m | for each database file: reads, writes, bytes, stall time (latency per read and write as rates) |
| `mssql_memory` | 5m | server memory target and total; process memory; the memory-low flags; buffer pool; plan cache and its single-use plans; the biggest memory clerks; In-Memory OLTP; Windows' or Linux's memory state |
| `mssql_tempdb` | 5m | free space; version store; user and internal objects |
| `mssql_connections` | 5m | encrypted or not; Kerberos, NTLM or SQL logins; connections per database (counts only: never a host or program name) |
| `mssql_databases` | 15m | for each database: state, recovery model, read-only, data and log size, log used, why the log cannot be reused, active transactions, Query Store state, compatibility level against the server's |
| `mssql_health` | 15m | for each database: days since the last good DBCC CHECKDB, virtual log files, files near their maximum or growing by percent, encryption (TDE) state and certificate expiry; free space on each volume with database files; size against Express's 10 GB limit; suspect pages |
| `mssql_config` | 15m | settings at risk or drifted, as numbers: max server memory left at its default, MAXDOP, cost threshold for parallelism, xp_cmdshell, CLR, OLE automation, `sa` enabled, sysadmin logins, instant file initialization, locked pages in memory |

### Off until their access is given (a `needs` line each)

| Job | Every | What |
| --- | --- | --- |
| `mssql_backups` | 15m | for each database: the age of its last full, differential and log backup; never backed up; log shipping's last copy and restore |
| `mssql_agent` | 15m | SQL Agent jobs failed in the last 24 hours, running now, and the longest running |

### Left out

Query text, or anything that can carry it; index fragmentation and unused
indexes (they scan the indexes); the error log (it needs `securityadmin`);
deadlock details (the count is in `mssql_performance`); transactional
replication, Service Broker and full-text search (another pack, if wanted).

## Testing

- SQL Server 2019, 2022 and 2025 (Developer edition) in Docker on the Fedora
  test machine, one version at a time: a primary and a secondary in a
  read-scale availability group (no cluster), and a third with TLS signed by
  a test CA. `tests/integration/backends`, as the other service packs.
- Through Vigil, `service-packs.sh` and `Service-Packs.ps1`, with load to
  make the numbers move: blocking, a long transaction, a backup, a failed
  Agent job, a full log.
- Linux and macOS with both `sqlcmd`s; Windows under Windows PowerShell 5.1
  and PowerShell 7, against the same servers.
- CI: one SQL Server container in the service-packs job.
