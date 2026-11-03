#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# Writes to standard output and standard error, carrying the run's tag so
# verify.sh can find these lines in a log backend.
$tag = if ($env:BK_RUN) { $env:BK_RUN } else { 'untagged' }
Write-Output "bk_output stdout $tag"
[Console]::Error.WriteLine("bk_output stderr $tag")
