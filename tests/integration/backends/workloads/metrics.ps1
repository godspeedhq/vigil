#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# An application metric with a known value, tagged with the run so
# verify.sh can tell this run's data from an earlier one's.
$tag = if ($env:BK_RUN) { $env:BK_RUN } else { 'untagged' }
Write-Output "metric vigil_backend_probe 42 run=$tag"
