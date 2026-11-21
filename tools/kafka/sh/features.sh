# The cluster's finalized features against what its brokers support:
#   Feature: metadata.version  SupportedMinVersion: 3.3-IV3  SupportedMaxVersion: 4.4-IV2  FinalizedVersionLevel: 4.4-IV2  Epoch: 594
# A feature below the most its brokers support is one an upgrade has not
# finalized yet (kafka-features upgrade). metadata.version is named; the
# others are levels.
run kafka-features "${conn[@]}" describe || exit 0
printf '%s\n' "$out" | awk '
    /^Feature: / {
        f = $0; sub(/^Feature: */, "", f); sub(/[ \t].*/, "", f)
        mx = $0; sub(/.*SupportedMaxVersion: */, "", mx); sub(/[ \t].*/, "", mx)
        lv = $0; sub(/.*FinalizedVersionLevel: */, "", lv); sub(/[ \t].*/, "", lv)
        if ($0 !~ /FinalizedVersionLevel:/) lv = "-"
        behind = (lv != mx) ? 1 : 0; n++; if (behind) total++
        if (f == "metadata.version") printf "metric metadata_version 1 version=%s supported=%s\n", lv, mx
        else if (lv ~ /^[0-9]+$/ && mx ~ /^[0-9]+$/) printf "metric level %d feature=%s\nmetric supported_level %d feature=%s\n", lv, f, mx, f
        printf "metric behind %d feature=%s\n", behind, f
    }
    END { printf "metric features %d\nmetric features_behind %d\n", n, total }'
exit 0
