# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The etcd pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='etcd', E='ETCD', url='http://localhost:2381', version='1.0.0',
    description='etcd: healthy or not, a leader and quorum, leader changes, proposals failed and waiting, the '
                'database against its quota and its fragmentation, keys and revisions, watchers, the WAL\'s and '
                'the backend\'s disk latency, peers and gRPC requests that failed',
    works='etcd 3.5 and 3.6, a member of a cluster or one alone (tested: a 3.6.17 cluster of three, and 3.5.36), '
          'from its metrics listener (--listen-metrics-urls)',
    head=['etcd - an etcd member, from its own metrics page: is it healthy, does its',
          'cluster have a leader and quorum, how often does the leader change, do',
          'proposals fail, how full is its database against its quota, and is its',
          'disk fast enough.'],
    needs=['its metrics page: etcd serves /metrics and /health on its client port, where clients usually need a '
           "certificate; give it a plain one with --listen-metrics-urls=http://127.0.0.1:2381 (kubeadm's etcd has it "
           'already), and set env = ETCD_URL=... where it is elsewhere',
           'on each member: each reports itself and its view of the cluster',
           "for etcd's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, etcd's page about itself"

job(pack='etcd', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is this etcd member healthy, with a leader and quorum',
    what="Reports whether the member is healthy, whether its cluster has a leader (without one, it has lost "
         "quorum and takes no writes), whether this member is the leader or a learner, how often the leader has "
         "changed, the members it knows and the peers it can reach, the proposals committed, applied, waiting and "
         "failed, and applies and reads that were slow or failed.",
    reads=READS + ", and /health.",
    steps=[
        page('/metrics'),
        answers('healthy', '/health', '1 when /health answers 200, else 0: no leader, or an alarm (NOSPACE when the '
                                      'database is at its quota; etcdctl alarm list says which)'),
        table(
            ('version|info|etcd_server_version||server_version:version', 'always 1, tagged version=<its version>'),
            ('cluster_version|info?|etcd_cluster_version||cluster_version:version', "always 1, tagged version=<the cluster's version>"),
            ('has_leader|max|etcd_server_has_leader', '1 when the cluster has a leader, 0 when it has none: quorum is lost, and no write succeeds'),
            ('is_leader|max|etcd_server_is_leader', '1 when this member is the leader'),
            ('is_learner|max|etcd_server_is_learner', '1 when this member is a learner, not yet voting'),
            ('leader_changes_count|sum|etcd_server_leader_changes_seen_total', 'leader changes this member has seen (a running total)'),
            ('_peers|count|etcd_network_active_peers', None),
            ('members|add|_peers|1', 'members of its cluster, itself counted'),
            ('peers_active|count|etcd_network_active_peers|=1', 'other members it is connected to'),
            ('peers_unreachable|count|etcd_network_active_peers|=0', 'other members it is not connected to'),
            ('heartbeat_failures_count|sum|etcd_server_heartbeat_send_failures_total', 'heartbeats the leader failed to send (a running total)'),
            ('peer_send_failures_count|sum|etcd_network_peer_sent_failures_total', 'messages to peers that failed (a running total)'),
            ('proposals_committed_count|sum|etcd_server_proposals_committed_total', 'proposals committed (a running total)'),
            ('proposals_applied_count|sum|etcd_server_proposals_applied_total', 'proposals applied (a running total)'),
            ('apply_backlog|sub|proposals_committed_count|proposals_applied_count', 'committed and not yet applied'),
            ('proposals_pending|sum|etcd_server_proposals_pending', 'proposals waiting to be committed'),
            ('proposals_failed_count|sum|etcd_server_proposals_failed_total', 'proposals that failed: no leader, or a timeout (a running total)'),
            ('slow_applies_count|sum|etcd_server_slow_apply_total', 'applies that took over 100 ms (a running total)'),
            ('read_indexes_failed_count|sum|etcd_server_read_indexes_failed_total', 'linearizable reads that failed (a running total)'),
            ('slow_read_indexes_count|sum|etcd_server_slow_read_indexes_total', 'linearizable reads that were slow (a running total)'),
            ('health_failures_count|sum|etcd_server_health_failures', 'health checks that failed (a running total)'),
        ),
    ],
    healthy='up 1; healthy 1; has_leader 1; peers_unreachable 0; proposals_failed_count and leader_changes_count not moving.',
    watch='leader_changes_count moving: elections, from a slow disk or network (the disk job), or members restarting; '
          'apply_backlog or proposals_pending growing; slow_applies_count moving.',
    act='has_leader 0: quorum is lost, nothing can be written; healthy 0 with has_leader 1: an alarm (NOSPACE: the '
        'database job, then compact, defragment and etcdctl alarm disarm); peers_unreachable above 0: a member is '
        'down or cut off, and one more lost may cost quorum; proposals_failed_count moving.')

job(pack='etcd', job='database', metric='database', when='run_every   = 5m', runtime='30s',
    title="how full an etcd member's database is, against its quota",
    what="Reports the database's size against its quota (past it, etcd raises the NOSPACE alarm and takes no more "
         "writes), the space in use and the space a defragmentation would give back, the keys and revisions and "
         "how far the revision is past the last compaction, the requests that read and change keys, the watchers, "
         "and the leases.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('db_bytes|sum|etcd_mvcc_db_total_size_in_bytes', "the database file's size"),
            ('quota_bytes|sum|etcd_server_quota_backend_bytes', 'its quota (--quota-backend-bytes; 2 GiB by default)'),
            ('db_used_pct|pct|db_bytes|quota_bytes', 'the file, as a percent of the quota: near 100, the NOSPACE alarm (raised when a write would pass the quota)'),
            ('db_in_use_bytes|sum|etcd_mvcc_db_total_size_in_use_in_bytes', 'of the file, the space in use'),
            ('fragmented_bytes|sub|db_bytes|db_in_use_bytes', 'the space a defragmentation would give back'),
            ('keys|sum|etcd_debugging_mvcc_keys_total', 'keys'),
            ('revision|sum|etcd_debugging_mvcc_current_revision', 'the current revision'),
            ('compacted_revision|sum|etcd_debugging_mvcc_compact_revision', 'the revision compacted to'),
            ('revisions_kept|sub|revision|compacted_revision', 'revisions kept since the last compaction: history that fills the database'),
            ('last_compaction_seconds|age|etcd_debugging_mvcc_db_compaction_last', 'seconds since the last compaction (none since this member started: nothing)'),
            ('puts_count|sum|etcd_mvcc_put_total', 'puts (a running total)'),
            ('deletes_count|sum|etcd_mvcc_delete_total', 'deletes (a running total)'),
            ('ranges_count|sum|etcd_mvcc_range_total', 'reads (a running total)'),
            ('txns_count|sum|etcd_mvcc_txn_total', 'transactions (a running total)'),
            ('watchers|sum|etcd_debugging_mvcc_watcher_total', 'watchers'),
            ('watch_streams|sum|etcd_debugging_mvcc_watch_stream_total', 'watch streams'),
            ('slow_watchers|sum|etcd_debugging_mvcc_slow_watcher_total', 'watchers behind the events they watch'),
            ('leases_granted_count|sum|etcd_debugging_lease_granted_total', 'leases granted (a running total)'),
            ('leases_expired_count|sum|etcd_debugging_server_lease_expired_total', 'leases that expired (a running total)'),
            ('defrag_running|max|etcd_disk_defrag_inflight', '1 while a defragmentation runs: the member answers nothing meanwhile'),
        ),
    ],
    healthy='db_used_pct well below 80; revisions_kept steady (compaction runs); slow_watchers 0.',
    watch='db_used_pct above 80; fragmented_bytes a large share of db_bytes: a defragmentation would give it back; '
          'revisions_kept growing: nothing compacts (Kubernetes compacts every 5 minutes).',
    act='db_used_pct near 100: at the quota, etcd raises NOSPACE and takes no writes until it is compacted, '
        'defragmented and the alarm disarmed; slow_watchers above 0 for long.')

job(pack='etcd', job='disk', metric='disk', when='run_every   = 1m', runtime='30s',
    title="is an etcd member's disk fast enough",
    what="Reports how fast the member's disk is where etcd needs it: the WAL's fsyncs and the backend's commits, "
         "each on average and those that were slow, the bytes written to the WAL, and the round trip to its peers. "
         "A slow disk shows first as missed heartbeats and leader changes.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('wal_fsyncs_count|sum|etcd_disk_wal_fsync_duration_seconds_count', 'WAL fsyncs (a running total)'),
            ('_wf_s|sum|etcd_disk_wal_fsync_duration_seconds_sum', None),
            ('_wf_avg|div|_wf_s|wal_fsyncs_count', None),
            ('wal_fsync_avg_ms|mul|_wf_avg|1000', 'their average, in milliseconds, since the member started'),
            ('_wf_all|sum|etcd_disk_wal_fsync_duration_seconds_bucket|le=+Inf', None),
            ('_wf_fast|sum|etcd_disk_wal_fsync_duration_seconds_bucket|le=0.016', None),
            ('wal_fsyncs_slow_count|sub|_wf_all|_wf_fast', 'of them, over 16 ms (a running total): etcd wants most under 10'),
            ('backend_commits_count|sum|etcd_disk_backend_commit_duration_seconds_count', 'backend commits (a running total)'),
            ('_bc_s|sum|etcd_disk_backend_commit_duration_seconds_sum', None),
            ('_bc_avg|div|_bc_s|backend_commits_count', None),
            ('backend_commit_avg_ms|mul|_bc_avg|1000', 'their average, in milliseconds'),
            ('_bc_all|sum|etcd_disk_backend_commit_duration_seconds_bucket|le=+Inf', None),
            ('_bc_fast|sum|etcd_disk_backend_commit_duration_seconds_bucket|le=0.032', None),
            ('backend_commits_slow_count|sub|_bc_all|_bc_fast', 'of them, over 32 ms (a running total): etcd wants most under 25'),
            ('wal_written_bytes_count|sum|etcd_disk_wal_write_bytes_total', 'bytes written to the WAL (a running total)'),
            ('_rtt_s|sum?|etcd_network_peer_round_trip_time_seconds_sum', None),
            ('_rtt_n|sum?|etcd_network_peer_round_trip_time_seconds_count', None),
            ('_rtt_avg|div|_rtt_s|_rtt_n', None),
            ('peer_rtt_avg_ms|mul|_rtt_avg|1000', 'the round trip to its peers, on average, in milliseconds (none alone)'),
        ),
    ],
    healthy="wal_fsyncs_slow_count and backend_commits_slow_count rising slowly, if at all, against their totals.",
    watch='wal_fsync_avg_ms above 10 or backend_commit_avg_ms above 25; the slow counts rising with the totals.',
    act='the slow counts rising fast with leader changes (the status job): the disk is too slow for etcd. Give it '
        'an SSD of its own; peer_rtt_avg_ms above 50: the network between members.')

job(pack='etcd', job='requests', metric='requests', when='run_every   = 1m', runtime='30s',
    title='the gRPC requests an etcd member answered, and those that failed',
    what="Reports the gRPC requests the member handled and those that failed, for each gRPC code, and the bytes "
         "to and from its clients. etcd counts them once a client has asked: on a member nothing has asked yet, "
         "the counts are not there.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('requests_count|sum?|grpc_server_handled_total', 'requests handled (a running total)'),
            ('failed_count|sum?|grpc_server_handled_total|grpc_code!=OK', 'of them, failed (a running total)'),
            ('failed|by|grpc_server_handled_total|grpc_code!=OK|grpc_code:code',
             'the same, for each gRPC code, tagged code=<Unavailable, DeadlineExceeded, ResourceExhausted, '
             'PermissionDenied, Unauthenticated ...>'),
            ('requests_started_count|sum?|grpc_server_started_total', 'requests started (a running total)'),
            ('client_received_bytes_count|sum|etcd_network_client_grpc_received_bytes_total', 'bytes from clients (a running total)'),
            ('client_sent_bytes_count|sum|etcd_network_client_grpc_sent_bytes_total', 'bytes to clients (a running total)'),
        ),
    ],
    healthy='failed_count rising slowly, if at all, against requests_count.',
    watch='failed rising with code=DeadlineExceeded: requests that waited too long (a slow disk, or no leader).',
    act='failed rising with code=Unavailable (no leader), ResourceExhausted (NOSPACE: the database job), '
        'Unauthenticated or PermissionDenied (a client with the wrong credentials).')
