#!/bin/bash
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# intel-mac.sh - Homebrew on an Intel Mac, in your home folder.
#
# Homebrew's installer refuses Intel Macs ("Homebrew on macOS is only
# supported on Apple Silicon processors!"), but Homebrew itself still runs on
# them, as a Tier 3 configuration, until September 2027. This clones it into
# ~/homebrew, which needs no sudo and leaves /usr/local alone, and adds it to
# your shell profile so new terminals find brew. Nothing in it is about Vigil:
# it is for anyone with an Intel Mac who wants Homebrew.
#
# Run it as yourself, not with sudo:
#
#   curl -fsSL https://raw.githubusercontent.com/godspeedhq/vigil/main/packaging/homebrew/intel-mac.sh | bash
#
# Running it again is safe: it skips what is already done.
#
# To undo it:
#   rm -rf ~/homebrew ~/Library/Caches/Homebrew
#   and delete the brew shellenv line from ~/.zprofile (or ~/.bash_profile)

set -u

prefix=$HOME/homebrew

if [ "$(id -u)" -eq 0 ]; then
    echo 'Run this as yourself, not with sudo: Homebrew refuses to run as root.'
    exit 1
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'This is for macOS. On Linux, use the installer at https://brew.sh'
    exit 1
fi
if [ "$(uname -m)" != x86_64 ]; then
    echo 'This Mac is not Intel: use the installer at https://brew.sh'
    exit 1
fi
echo "macOS $(sw_vers -productVersion), Intel"

# git comes with Apple's Command Line Tools.
if ! xcode-select -p > /dev/null 2>&1; then
    echo "Apple's Command Line Tools are missing. Run: xcode-select --install"
    echo 'then run this again once they are installed.'
    exit 1
fi

if [ -x "$prefix/bin/brew" ]; then
    echo "Homebrew is already in $prefix"
else
    echo "cloning Homebrew into $prefix"
    git clone https://github.com/Homebrew/brew "$prefix" || exit 1
    # The latest release, not whatever is on the main branch today.
    tag=$(git -C "$prefix" tag --list '[0-9]*' --sort=-v:refname | head -n 1)
    if [ -n "$tag" ]; then
        git -C "$prefix" checkout -q "$tag" && echo "on Homebrew $tag"
    fi
fi

# New terminals find brew through the shell profile.
case ${SHELL##*/} in
    bash) profile=$HOME/.bash_profile ;;
    *) profile=$HOME/.zprofile ;;
esac
line='eval "$(~/homebrew/bin/brew shellenv)"'
if [ -f "$profile" ] && grep -qF "$line" "$profile"; then
    echo "$profile already sets up brew"
else
    echo "$line" >> "$profile" || exit 1
    echo "added to $profile: $line"
fi

eval "$("$prefix/bin/brew" shellenv)"
brew --version || exit 1

echo
echo 'Done. Open a new terminal, or run this in the one you have:'
echo "  $line"
echo 'Homebrew warns that the Mac is Intel, the prefix is not /usr/local and,'
echo 'on an older macOS, that it is unsupported: formulae with nothing to build'
echo 'install as usual; others build from source, which takes longer.'
