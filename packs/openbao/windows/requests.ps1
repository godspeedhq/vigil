#Requires -Version 5.1

<#
.SYNOPSIS
    requests.ps1 - the requests and logins an OpenBao or Vault node handled, and those that failed, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the requests the node handled and those in flight, the logins and
    those that failed (a login that created no token), the users locked out
    after too many failures, the responses refused for each class of status
    (Vault), and requests its audit devices failed to log: when every audit
    device fails, it refuses requests. It only reads: every request is a GET,
    and it changes nothing.

    Reads OPENBAO_URL (default http://localhost:8200):
    /v1/sys/metrics?format=prometheus, with OPENBAO_TOKEN.
    What the scripts share is in _openbao.ps1, beside this one.

    Metrics:
      up                             1 when OpenBao answered its metrics page,
                                     else 0 (and nothing more is read)
      requests_count                 requests handled (a running total)
      in_flight                      requests being handled now
      logins_count                   login requests (a running total)
      logins_ok_count                of them, those that created a token (a
                                     running total)
      logins_failed_count            those that did not: a wrong password, a
                                     role unknown, a user locked out (a running
                                     total)
      locked_users                   users locked out after too many failed
                                     logins (updated every few minutes)
      responses_4xx_count            responses refused, 4xx (Vault; a running
                                     total)
      permission_denied_count        of them, 403: a token without the policy,
                                     or a user locked out (Vault)
      responses_5xx_count            responses that failed, 5xx (Vault; a
                                     running total)
      audit_request_failures_count   requests an audit device failed to log (a
                                     running total)
      audit_response_failures_count  responses an audit device failed to log (a
                                     running total)

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  logins_failed_count rising slowly, if at all; locked_users 0; the
               audit failure counts flat.
      Watch    logins_failed_count rising: a client with a stale secret, or
               someone guessing; permission_denied_count rising: a token without
               the policy it needs.
      Act      locked_users above 0: a user locked out (an application that
               cannot log in); the audit failure counts moving: with every audit
               device failing, it refuses every request; responses_5xx_count
               moving.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when OpenBao does not answer (up 0 is
      the reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'requests'
. (Join-Path $PSScriptRoot '_openbao.ps1')

Read-Page '/v1/sys/metrics?format=prometheus'
Get-Readings @'
requests_count|sum?|vault_core_handle_request_count
in_flight|max?|vault_core_in_flight_requests
logins_count|sum|vault_core_handle_login_request_count
logins_ok_count|sum|vault_token_creation|auth_method!=token
logins_failed_count|sub|logins_count|logins_ok_count
locked_users|max?|vault_core_locked_users
responses_4xx_count|sum?|vault_core_response_status_code|type=4xx
permission_denied_count|sum?|vault_core_response_status_code|code=403
responses_5xx_count|sum?|vault_core_response_status_code|type=5xx
audit_request_failures_count|sum?|vault_audit_log_request_failure
audit_response_failures_count|sum?|vault_audit_log_response_failure
'@
exit 0
