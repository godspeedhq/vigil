#Requires -Version 5.1

<#
.SYNOPSIS
    requests.ps1 - the gRPC requests an etcd member answered, and those that failed, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the gRPC requests the member handled and those that failed, for each
    gRPC code, and the bytes to and from its clients. etcd counts them once a
    client has asked: on a member nothing has asked yet, the counts are not
    there. It only reads: every request is a GET, and it changes nothing.

    Reads ETCD_URL (default http://localhost:2381): /metrics, etcd's page about
    itself.
    What the scripts share is in _etcd.ps1, beside this one.

    Metrics:
      up                           1 when etcd answered its metrics page, else 0
                                   (and nothing more is read)
      requests_count               requests handled (a running total)
      failed_count                 of them, failed (a running total)
      failed                       the same, for each gRPC code, tagged
                                   code=<Unavailable, DeadlineExceeded,
                                   ResourceExhausted, PermissionDenied,
                                   Unauthenticated ...>
      failed_not_shown             how many more there were than the 20 shown
      requests_started_count       requests started (a running total)
      client_received_bytes_count  bytes from clients (a running total)
      client_sent_bytes_count      bytes to clients (a running total)

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  failed_count rising slowly, if at all, against requests_count.
      Watch    failed rising with code=DeadlineExceeded: requests that waited
               too long (a slow disk, or no leader).
      Act      failed rising with code=Unavailable (no leader),
               ResourceExhausted (NOSPACE: the database job), Unauthenticated or
               PermissionDenied (a client with the wrong credentials).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when etcd does not answer (up 0 is the
      reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'requests'
. (Join-Path $PSScriptRoot '_etcd.ps1')

Read-Page '/metrics'
Get-Readings @'
requests_count|sum?|grpc_server_handled_total
failed_count|sum?|grpc_server_handled_total|grpc_code!=OK
failed|by|grpc_server_handled_total|grpc_code!=OK|grpc_code:code
requests_started_count|sum?|grpc_server_started_total
client_received_bytes_count|sum|etcd_network_client_grpc_received_bytes_total
client_sent_bytes_count|sum|etcd_network_client_grpc_sent_bytes_total
'@
exit 0
