# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Shared by the reproductions: throwaway roots under $VV (default ~/vv),
# from a scratch copy of the repository's app/ and vendor/ in $VV/src.
VV=${VV:-$HOME/vv}
newroot() {
    local r
    r=$(mktemp -d "$VV/r.XXXXXX") || exit 1
    cp -R "$VV/src/app" "$VV/src/vendor" "$r/"
    bash "$r/app/vigil" --root "$r" init empty --instance t --backend file > /dev/null 2>&1
    mkdir -p "$r/scripts"
    printf '%s\n' "$r"
}
v() { bash "$R/app/vigil" --root "$R" "$@" < /dev/null; }
say() { printf '\n# %s\n' "$*"; }
