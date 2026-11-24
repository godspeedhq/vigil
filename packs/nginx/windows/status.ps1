#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - an nginx server's connections and requests, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads nginx's stub_status page and reports what it says: its connections,
    reading, writing and waiting, and the connections and requests since nginx
    last started. It only reads: it changes nothing.

    Reads the page at NGINX_STATUS_URL (default http://127.0.0.1/nginx_status),
    which you turn on once: location = /nginx_status { stub_status; allow
    127.0.0.1; deny all; }.
    What the scripts share is in _nginx.ps1, beside this one.

    Metrics:
      up                  1 when the page answers, else 0
      active_connections  client connections now, waiting ones included
      reading             connections reading a request
      writing             connections writing a response
      waiting             idle keep-alive connections
      accepts_count       connections accepted (a running total)
      handled_count       connections handled (a running total)
      requests_count      requests served (a running total)
      dropped_count       connections accepted but not handled (a running total)

    Example output (the rest are in the same form):
      metric up 1
      metric active_connections 6
      metric reading 0
      metric writing 5
      metric waiting 1
      metric accepts_count 262
      metric handled_count 262
      metric requests_count 339
      metric dropped_count 0

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; dropped_count not rising; requests_count rising at your
               usual rate (graph the _count totals as a rate).
      Watch    active_connections near worker_connections times the workers (the
               server job says how near).
      Act      up 0; dropped_count rising, which means nginx is turning
               connections away, usually at a resource limit.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, server up or down; 1 if the page answers but is not
      a stub_status page
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_nginx.ps1')

$url = if ($env:NGINX_STATUS_URL) { $env:NGINX_STATUS_URL } else { 'http://127.0.0.1/nginx_status' }
$r = Get-Http $url
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
$t = $r.Body
$a = [regex]::Match($t, 'Active connections:\s*(\d+)')
$n = [regex]::Match($t, '(?m)^\s*(\d+)\s+(\d+)\s+(\d+)\s*$')
$w = [regex]::Match($t, 'Reading:\s*(\d+)\s*Writing:\s*(\d+)\s*Waiting:\s*(\d+)')
if (-not ($a.Success -and $n.Success -and $w.Success)) { Stop-Run "$url is not a stub_status page" }
M 'up' 1
M 'active_connections' $a.Groups[1].Value
M 'reading' $w.Groups[1].Value
M 'writing' $w.Groups[2].Value
M 'waiting' $w.Groups[3].Value
M 'accepts_count' $n.Groups[1].Value
M 'handled_count' $n.Groups[2].Value
M 'requests_count' $n.Groups[3].Value
M 'dropped_count' ([int64]$n.Groups[1].Value - [int64]$n.Groups[2].Value)
exit 0
