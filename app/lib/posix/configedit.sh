# shellcheck shell=bash
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
# configedit.sh - vigil config: edit the configuration as crontab -e does
# (SPECIFICATION.md 16.6).
#
#   vigil_config_edit <root>
#
# Opens a copy of config/vigil.config in $VISUAL, $EDITOR or vi, checks the
# copy with the supervisor's own parser and validation, and renames it over
# the configuration only when nothing in it is ERROR or INVALID. At a
# terminal a rejected copy can be edited again. The supervisor picks the
# file up at its next tick (16.1). Returns 0 when saved or unchanged, 1 when
# nothing was saved.
#
# Requires config.sh, validate.sh, worker.sh and precheck.sh.

_vigil_ce_err() {
    printf 'vigil: %s\n' "$1" >&2
}

vigil_config_edit() {
    local root=$1 cfg dir work copy orig editor rc answer
    cfg=$root/config/vigil.config
    if [ ! -f "$cfg" ]; then
        _vigil_ce_err "no configuration at $cfg: vigil init writes one"
        return 1
    fi
    # A pointer file only says where the configuration is (6.8): edit it there.
    # One that is broken is still opened here, to be fixed.
    _vw_root=$root
    vigil_config_parse "$cfg" 2> /dev/null
    _vigil_wk_get vigil config_source ''
    if [ -n "$_vw_value" ]; then
        _vigil_ce_err "this host's configuration comes from $_vw_value (config_source in $cfg): change it there; edit this file with any editor only to change where it comes from"
        return 1
    fi
    dir=$root/config
    if [ ! -w "$cfg" ] || [ ! -w "$dir" ]; then
        _vigil_ce_err "cannot write $cfg: run it as the configuration's owner (sudo vigil config for a system install)"
        return 1
    fi

    # Beside the configuration, so the save is a rename on one file system, and
    # private, since the configuration may name stores and accounts.
    work=$(mktemp -d "$dir/.vigil-config.XXXXXX") || {
        _vigil_ce_err "cannot make a folder in $dir"
        return 1
    }
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    trap 'exit 130' INT TERM
    copy=$work/vigil.config
    orig=$work/original
    cp -p "$cfg" "$copy" && cp -p "$cfg" "$orig" || {
        _vigil_ce_err "cannot copy $cfg"
        return 1
    }

    editor=${VISUAL:-${EDITOR:-vi}}
    while :; do
        # Split on spaces, so an editor with arguments works (code --wait),
        # unless the whole setting is the path of a program.
        if [ -f "$editor" ] && [ -x "$editor" ]; then
            "$editor" "$copy"
        else
            # shellcheck disable=SC2086
            $editor "$copy"
        fi
        rc=$?
        if [ "$rc" -ne 0 ]; then
            _vigil_ce_err "the editor ($editor) exited with $rc; nothing was changed"
            return 1
        fi
        if cmp -s "$copy" "$orig"; then
            printf 'no changes\n'
            return 0
        fi
        vigil_config_parse "$copy" 2> /dev/null
        vigil_config_validate
        if ! _vigil_ce_refused; then
            break
        fi
        printf 'The configuration has problems and was not saved:\n'
        vigil_config_report | sed 's/^/  /'
        if [ ! -t 0 ]; then
            printf 'nothing was changed\n'
            return 1
        fi
        printf 'Edit again? [Y/n] '
        IFS= read -r answer || answer=n
        case $answer in
            '' | [Yy]*) ;;
            *)
                printf 'nothing was changed\n'
                return 1
                ;;
        esac
    done

    # Warnings do not stop the save, but are worth seeing.
    if [ "${#VIGIL_VAL_KIND[@]}" -gt 0 ]; then
        vigil_config_report | sed 's/^/  /'
    fi
    if ! cmp -s "$cfg" "$orig"; then
        if mv -f "$copy" "$cfg.edited"; then
            _vigil_ce_err "$cfg changed while it was being edited, so it was left as it is; your version is in $cfg.edited"
        else
            _vigil_ce_err "$cfg changed while it was being edited, so it was left as it is"
        fi
        return 1
    fi
    if ! mv -f "$copy" "$cfg"; then
        _vigil_ce_err "cannot save $cfg; nothing was changed"
        return 1
    fi
    printf 'saved %s: the supervisor uses it from its next tick\n' "$cfg"
    return 0
}

# Whether the parsed copy would not be saved: any parser error, ERROR or
# INVALID record. A broken job would stop running unnoticed, so it is
# refused here even though the supervisor would only skip it.
_vigil_ce_refused() {
    local i=0
    [ "${#VIGIL_CFG_ERRORS[@]}" -eq 0 ] || return 0
    while [ "$i" -lt "${#VIGIL_VAL_KIND[@]}" ]; do
        case ${VIGIL_VAL_KIND[$i]} in ERROR | INVALID) return 0 ;; esac
        i=$((i + 1))
    done
    return 1
}
