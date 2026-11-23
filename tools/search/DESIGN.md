# The elasticsearch and opensearch packs

Two packs from one source, because OpenSearch began as a fork of Elasticsearch 7.10 and most of their REST API is still the same: cluster health, `_cat`, node stats, thread pools, circuit breakers, shards and the allocation explain API, tasks, snapshots. Each pack stands on its own (packs never depend on each other); they are written together so that the same reading means the same thing in both.

`py tools/search/gen.py .` writes both:

| File | What |
| --- | --- |
| `lib.sh`, `lib.ps1` | What every script shares, as `_elasticsearch.sh` / `_opensearch.sh` (Linux, macOS) and `_elasticsearch.ps1` / `_opensearch.ps1` (Windows), beside the scripts: the settings, the login, one GET to the REST API, the product check, and the helpers that print. |
| `jobs.py` ... `jobs5.py` | The jobs: what each reports, its metrics, how to read them, and its code for bash (with jq) and PowerShell. A job marked `only='es'` or `only='os'` is one pack's alone. |
| `gen.py` | Each pack's words (its name, its settings' prefix, its elected node: master or cluster manager, its login), the scripts' headers, and `pack.config`. |
| `examples-<pack>.txt` | Each job's example output, from the test runs, for its script's header. |

## Choices

- **Read-only, every request a GET.** A user (or, for Elasticsearch, an API key) that may only monitor. Nothing the packs ask for changes the cluster: no `_verify` of a repository (it writes files), no `_cache/clear`, no `_flush`.
- **No client to install.** Linux and macOS use curl and jq, as the jenkins pack does. Windows speaks HTTP itself over .NET's own TCP and TLS, as the redis pack speaks RESP: the same on Windows PowerShell 5.1 and PowerShell 7, and with a private CA (`*_CACERT`) checked the same way the redis pack checks it, which Invoke-WebRequest cannot do on PowerShell 7.
- **Every job reads `/` first.** It says the cluster is up (a reading: `up 0` when it does not answer, and the run succeeds), and that it is the right product: Elasticsearch sends `X-elastic-product: Elasticsearch` with every answer; OpenSearch says `version.distribution: opensearch`. The wrong one fails the run and names the other pack.
- **No JVM.** Heap and garbage collection are the jvm pack's; the packs say so in their `needs` lines. What the cluster itself counts about memory (circuit breakers, indexing pressure, caches) is theirs.
- **Bounded output.** Every list (nodes, pools, indices, shards, tasks, pipelines, repositories) stops at a limit, the worst first, and says how many it left out (`*_not_shown`).
- **Never a query.** The tasks job names what a reindex or a by-query task reads and writes, from its description; a search's description holds its query, and is never printed.

## Lessons from the test clusters

- OpenSearch's snapshot management skips every run while the cluster is red, and may then hold its lock for a long while; Index State Management ignores a policy given as an index setting (it wants `_plugins/_ism/add`).
- A write thread pool small enough to refuse a client's burst also refuses the cluster's own writes (the job scheduler's locks, query insights): the tests use one thread and a queue of ten, and burst after the lifecycles have run.
- Elasticsearch lifts a flood-stage `read_only_allow_delete` block by itself once the disk is below the high watermark; a `write` block stays.
- The disk watermarks may be percentages, ratios or free space, with a headroom that caps a percentage (Elasticsearch 8.5 and later); the allocation job reads them as the cluster does.
