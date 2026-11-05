# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# One line per Windows fleet host under -Dir (its https and sftp folders),
# as fleet.sh status prints the Docker ones. With -Log, the supervisor's
# lines about configuration and updates, and the job's metric, instead.
param([string]$Dir, [switch]$Log)
foreach ($d in 'https', 'sftp') {
    $r = Join-Path $Dir "$d\root"
    if ($Log) {
        foreach ($f in Get-ChildItem -LiteralPath "$r\logs\supervisor" -Filter '2*.log' -ErrorAction SilentlyContinue) {
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                if ($l -match 'as the configuration asks|could not be|reloading|staying on|configuration revision') { "win-$d  $l" }
            }
        }
        try { [IO.File]::ReadAllLines("$r\metrics\vigil.prom") | Where-Object { $_ -like 'beat_beats*' } | ForEach-Object { "win-$d  $_" } } catch { }
        continue
    }
    $u = @{}
    try { foreach ($l in [IO.File]::ReadAllLines("$r\state\update.state")) { if ($l -match '^(\w+) *= ?(.*)$') { $u[$Matches[1]] = $Matches[2] } } } catch { }
    $a = try { [IO.File]::ReadAllText("$r\app\VERSION").Trim() } catch { '' }
    $s = try { [IO.File]::ReadAllText("$r\state\supervisor.version").Trim() } catch { '' }
    $why = if ($u['reason']) { ": $($u['reason'])" } else { '' }
    '{0,-4} {1,-8} {2,-10} {3,-10} {4,-11} {5}' -f 'win', $d, $a, $s, $u['version'], "$($u['result'])$why"
}
