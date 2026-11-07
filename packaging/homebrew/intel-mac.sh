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
# To remove it all again, with everything installed through it:
#
#   curl -fsSL https://raw.githubusercontent.com/godspeedhq/vigil/main/packaging/homebrew/intel-mac.sh | bash -s -- --uninstall
#
# It says what it will remove and asks first; --yes skips the question.

set -u

prefix=$HOME/homebrew
line='eval "$(~/homebrew/bin/brew shellenv)"'

uninstall=0
yes=0
for a in "$@"; do
    case $a in
        --uninstall) uninstall=1 ;;
        --yes) yes=1 ;;
        *)
            echo "unknown option $a: the options are --uninstall and --yes"
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo 'Run this as yourself, not with sudo: Homebrew refuses to run as root.'
    exit 1
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'This is for macOS. On Linux, use the installer at https://brew.sh'
    exit 1
fi

# New terminals find brew through the shell profile.
case ${SHELL##*/} in
    bash) profile=$HOME/.bash_profile ;;
    *) profile=$HOME/.zprofile ;;
esac

if [ "$uninstall" = 1 ]; then
    # Only a Homebrew clone is ever deleted: a folder of that name holding
    # anything else is left alone.
    if [ -e "$prefix" ] && [ ! -x "$prefix/bin/brew" ]; then
        echo "$prefix is not a Homebrew clone: leaving it alone"
        exit 1
    fi
    echo 'This removes:'
    if [ -x "$prefix/bin/brew" ]; then
        echo "  $prefix, with everything installed through it and its data in $prefix/var:"
        formulae=$("$prefix/bin/brew" list --formula -1 2> /dev/null | xargs)
        casks=$("$prefix/bin/brew" list --cask -1 2> /dev/null | xargs)
        echo "    formulae: ${formulae:-none}"
        echo "    casks:    ${casks:-none}"
    fi
    # Homebrew's caches, logs and settings, unless another Homebrew (an
    # older one in /usr/local) shares them.
    shared=1
    if [ -x /usr/local/bin/brew ]; then
        shared=0
        echo '  (not the caches, logs and settings: the Homebrew in /usr/local uses them too)'
    fi
    [ "$shared" = 1 ] && for d in "$HOME/Library/Caches/Homebrew" "$HOME/Library/Logs/Homebrew" "$HOME/.homebrew"; do
        [ -e "$d" ] && echo "  $d"
    done
    for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
        [ -f "$f" ] && grep -qxF "$line" "$f" && echo "  the brew shellenv line in $f"
    done
    if [ "$yes" = 0 ]; then
        # Piped into bash, standard input is this script: ask the terminal.
        if ! (: < /dev/tty) 2> /dev/null; then
            echo 'No terminal to ask in: run it again with --yes to go ahead.'
            exit 1
        fi
        printf 'Remove? [y/N] '
        read -r answer < /dev/tty
        case $answer in
            y | Y | yes | YES) ;;
            *)
                echo 'Nothing was removed.'
                exit 0
                ;;
        esac
    fi
    if [ -x "$prefix/bin/brew" ]; then
        # Otherwise their LaunchAgents stay behind, failing at every login.
        "$prefix/bin/brew" services stop --all
        rm -rf "$prefix" || exit 1
        echo "removed $prefix"
    fi
    [ "$shared" = 1 ] && for d in "$HOME/Library/Caches/Homebrew" "$HOME/Library/Logs/Homebrew" "$HOME/.homebrew"; do
        [ -e "$d" ] && rm -rf "$d" && echo "removed $d"
    done
    for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
        [ -f "$f" ] && grep -qxF "$line" "$f" || continue
        # Rewritten in place, so the file keeps its owner and permissions; one
        # left empty held only this line, so it was this script's.
        rest=$(grep -vxF "$line" "$f")
        if [ -n "$rest" ]; then printf '%s\n' "$rest" > "$f"; else rm -f "$f"; fi
        echo "removed the brew shellenv line from $f"
    done
    echo
    echo 'Done. Open a new terminal: the one you have still has brew on its PATH.'
    exit 0
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

if [ -f "$profile" ] && grep -qxF "$line" "$profile"; then
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
echo 'To remove it all again: intel-mac.sh --uninstall'
