# The quorum's state, then each controller's (and observer's) replication of
# the metadata log. A cluster on ZooKeeper has no quorum: kraft 0.
try kafka-metadata-quorum "${conn[@]}" describe --status
case $? in
    2) exit 0 ;;
    1) echo 'metric kraft 0'; exit 0 ;;
esac
echo 'metric kraft 1'
printf '%s\n' "$out" | awk '
    /^LeaderId:/ { print "metric leader_id " $2 }
    /^LeaderEpoch:/ { print "metric leader_epoch " $2 }
    /^HighWatermark:/ { print "metric high_watermark " $2 }
    /^MaxFollowerLag:/ { print "metric max_follower_lag " $2 }
    # -1 while a follower has not fetched since the leader changed: not known.
    /^MaxFollowerLagTimeMs:/ { if ($2 + 0 >= 0) print "metric max_follower_lag_ms " $2 }
    /^CurrentVoters:/ { print "metric voters " gsub(/"id":/, "") }
    /^CurrentObservers:/ { print "metric observers " gsub(/"id":/, "") }'

# Per node: how far behind the leader's log, and how long since it last
# fetched and last caught up. A time the leader has not seen is -1: left out.
run kafka-metadata-quorum "${conn[@]}" describe --replication || exit 0
now=$(date +%s)
# Columns found by their headers: DirectoryId came in Kafka 3.8.
printf '%s\n' "$out" | awk -v now="$now" '
    $1 == "NodeId" { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $1 ~ /^[0-9]+$/ && ("Lag" in col) {
        node = $1; lag = $col["Lag"]; fetch = $col["LastFetchTimestamp"]; caught = $col["LastCaughtUpTimestamp"]; role = tolower($col["Status"])
        printf "metric node_lag %s node=%s role=%s\n", lag, node, role
        if (fetch ~ /^[0-9]+$/) { a = now - int(fetch / 1000); if (a < 0) a = 0; printf "metric node_fetch_age_seconds %d node=%s role=%s\n", a, node, role }
        if (caught ~ /^[0-9]+$/) { a = now - int(caught / 1000); if (a < 0) a = 0; printf "metric node_caught_up_age_seconds %d node=%s role=%s\n", a, node, role }
    }'
exit 0
