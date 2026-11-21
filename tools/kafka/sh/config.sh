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

# The settings that matter most for safety, from every broker:
#   All configs for broker 1 are:
#     unclean.leader.election.enable=false sensitive=false synonyms={...}
# reported from the first, with a count of those that differ between
# brokers; then the topics whose own settings put their data at risk.
run kafka-configs "${conn[@]}" --describe --entity-type brokers --all || exit 0
brokers=$out
run kafka-topics "${conn[@]}" --describe || exit 0
{
    printf '%s\n' "$brokers" | awk '
        /^All configs for broker / { b = $5; next }
        /^  [a-z.]+=/ { line = substr($0, 3); k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v); sub(/ sensitive=(true|false) synonyms=.*/, "", v); print "B", b, k, v }'
    printf '%s\n' "$out" | grep '^Topic: ' | awk -F '\t' '
        function val(f,  i) { i = index(f, ": "); return i ? substr(f, i + 2) : "" }
        { t = val($1); rf = 0; mi = 1; u = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^ReplicationFactor: /) rf = val($i)
              else if ($i ~ /^Configs: /) {
                  if (match($i, /(^|[ ,])min\.insync\.replicas=[0-9]+/)) { v = substr($i, RSTART, RLENGTH); sub(/.*=/, "", v); mi = v + 0 }
                  if ($i ~ /(^|[ ,])unclean\.leader\.election\.enable=true/) u = 1
              }
          }
          print "T", t, rf, mi, u }'
} | awk '
    function bool(v) { return v == "true" ? 1 : 0 }
    $1 == "B" {
        b = $2; k = $3; v = $4; for (i = 5; i <= NF; i++) v = v " " $i
        if (first == "") first = b
        if (k in seen && seen[k] != v && k !~ /^(listeners|advertised\.listeners|broker\.id|node\.id|broker\.rack)$/) diff[k] = 1
        seen[k] = v
        if (b == first) cfg[k] = v
        next
    }
    $1 == "T" {
        if ($5) unclean++
        if ($3 > 1 && $4 >= $3) strict++
        if ($3 >= 3 && $4 <= 1) weak++
    }
    END {
        printf "metric unclean_leader_election %d\n", bool(cfg["unclean.leader.election.enable"])
        printf "metric auto_create_topics %d\n", bool(cfg["auto.create.topics.enable"])
        printf "metric auto_leader_rebalance %d\n", bool(cfg["auto.leader.rebalance.enable"])
        printf "metric authorizer %d\n", (cfg["authorizer.class.name"] != "" && cfg["authorizer.class.name"] != "null") ? 1 : 0
        if (cfg["min.insync.replicas"] ~ /^[0-9]+$/) printf "metric min_insync_replicas %d\n", cfg["min.insync.replicas"]
        if (cfg["default.replication.factor"] ~ /^[0-9]+$/) printf "metric default_replication_factor %d\n", cfg["default.replication.factor"]
        if (cfg["offsets.topic.replication.factor"] ~ /^[0-9]+$/) printf "metric offsets_replication_factor %d\n", cfg["offsets.topic.replication.factor"]
        if (cfg["transaction.state.log.replication.factor"] ~ /^[0-9]+$/) printf "metric transactions_replication_factor %d\n", cfg["transaction.state.log.replication.factor"]
        if (cfg["message.max.bytes"] ~ /^[0-9]+$/) printf "metric message_max_bytes %d\n", cfg["message.max.bytes"]
        # Retention: log.retention.ms, else .minutes, else .hours; -1 is forever.
        h = ""
        if (cfg["log.retention.ms"] ~ /^-?[0-9]+$/) h = (cfg["log.retention.ms"] < 0) ? -1 : cfg["log.retention.ms"] / 3600000
        else if (cfg["log.retention.minutes"] ~ /^-?[0-9]+$/) h = (cfg["log.retention.minutes"] < 0) ? -1 : cfg["log.retention.minutes"] / 60
        else if (cfg["log.retention.hours"] ~ /^-?[0-9]+$/) h = cfg["log.retention.hours"] + 0
        if (h != "") { s = sprintf("%.2f", h); sub(/0+$/, "", s); sub(/\.$/, "", s); printf "metric retention_hours %s\n", s }
        # Listeners without TLS or a login, but for the controllers.
        split(cfg["listener.security.protocol.map"], pm, ",")
        for (i in pm) { split(pm[i], kv, ":"); proto[kv[1]] = kv[2] }
        split(cfg["controller.listener.names"], cn, ","); for (i in cn) ctl[cn[i]] = 1
        n = split(cfg["listeners"], ls, ",")
        for (i = 1; i <= n; i++) { name = ls[i]; sub(/:\/\/.*/, "", name); if (!(name in ctl) && proto[name] == "PLAINTEXT") plain++ }
        printf "metric plaintext_listeners %d\n", plain
        for (k in diff) differ++
        printf "metric settings_differ %d\n", differ
        printf "metric topics_unclean_election %d\nmetric topics_min_isr_ge_rf %d\nmetric topics_min_isr_1 %d\n", unclean, strict, weak
    }'
exit 0
