# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# A fragment of the kafka pack: tools/kafka/gen.py writes packs/kafka from it.

# Each broker's connections, per listener, from JMX: open now, and running
# totals of those made and of logins that succeeded and failed. Each of a
# listener's network processors counts its own: added up.
report() {
    printf '%s\n' "$out" | awk -F '\t' -v b="$broker" "$AWKFMT"'
        /type=socket-server-metrics,listener=/ {
            l = $1; sub(/.*listener=/, "", l); sub(/,.*/, "", l)
            a = $1; sub(/.*:/, "", a)
            if ((v = fmt($2)) == "") next
            seen[l] = 1; sum[l SUBSEP a] += v
        }
        END {
            for (l in seen) {
                t = " broker=" b " listener=" l
                printf "metric connections %.0f%s\n", sum[l SUBSEP "connection-count"], t
                printf "metric created_count %.0f%s\n", sum[l SUBSEP "connection-creation-total"], t
                printf "metric logins_count %.0f%s\n", sum[l SUBSEP "successful-authentication-total"], t
                printf "metric failed_logins_count %.0f%s\n", sum[l SUBSEP "failed-authentication-total"], t
                printf "metric failed_relogins_count %.0f%s\n", sum[l SUBSEP "failed-reauthentication-total"], t
            }
        }'
}
jmx_each report \
    --object-name 'kafka.server:type=socket-server-metrics,listener=*,networkProcessor=*' \
    --attributes Version,connection-count,connection-creation-total,successful-authentication-total,failed-authentication-total,failed-reauthentication-total
exit 0
