#!/usr/bin/env bash
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
# run-pack.sh - the service packs against the servers in compose.services.yaml,
# on this host: tests/integration/service-packs.sh, with its evidence kept
# like the other runs'.
#
#   scripts/start.sh postgres-pack nginx-pack
#   scripts/run-pack.sh               both packs
#   scripts/run-pack.sh postgres      one of them
#
# The postgres pack needs PostgreSQL's client tools (psql, pg_isready) here,
# as on any server it monitors. Linux and macOS.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

packs=${*:-postgres nginx}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-pk.XXXXXX") || exit 1
root=$work/none
trap 'evidence_save "${POSTGRES_MONITOR_PASSWORD-}" "${POSTGRES_PASSWORD-}"; rm -rf "$work"' EXIT

evidence_start "pack-${packs// /-}" "$bk_dir/compose.services.yaml" "$0" "$@"
printf 'psql     %s\n\n' "$(psql --version 2> /dev/null || echo none)"
case " $packs " in
    *' postgres '*)
        export VIGIL_IT_PG_HOST=127.0.0.1 VIGIL_IT_PG_PORT=15432 VIGIL_IT_PG_PASSWORD=${POSTGRES_MONITOR_PASSWORD-}
        ;;
esac
case " $packs " in *' nginx '*) export VIGIL_IT_NGINX_URL=http://127.0.0.1:9082/nginx_status ;; esac
bash "$bk_repo/tests/integration/service-packs.sh"
