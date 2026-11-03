#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# Proves a secret reached the job, without ever showing it: the SHA-256 of
# BK_SECRET, which Vigil sets from a store, must be BK_SECRET_SHA256.
if (-not $env:BK_SECRET) { Write-Output 'no secret in BK_SECRET'; exit 2 }
$sha = [System.Security.Cryptography.SHA256]::Create()
$got = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($env:BK_SECRET)) | ForEach-Object { $_.ToString('x2') })
if ($got -ceq $env:BK_SECRET_SHA256) {
    Write-Output 'secret matched'
    Write-Output 'metric secret_matched 1'
    exit 0
}
Write-Output 'secret did not match'
exit 1
