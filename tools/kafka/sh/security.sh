# The ACLs, the users with SCRAM credentials, and the quotas: counts only,
# never a principal's or a client's name. An ACL is a line under its
# resource pattern:
#   Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:
#       (principal=User:app, host=*, operation=READ, permissionType=ALLOW)
# With no authorizer, the cluster says so: authorizer 0, and no ACL counts.
if try kafka-acls "${conn[@]}" --list; then
    echo 'metric authorizer 1'
    printf '%s\n' "$out" | awk '
        /resourceType=/ { r = $0; sub(/.*resourceType=/, "", r); sub(/,.*/, "", r); res = tolower(r) }
        /\(principal=/ {
            n++
            p = ($0 ~ /permissionType=DENY/) ? "deny" : "allow"
            by[res SUBSEP p]++
            if ($0 ~ /principal=User:\*,/) wild++
            if ($0 ~ /operation=ALL,/) all++
        }
        END {
            printf "metric all_acls %d\nmetric any_principal_acls %d\nmetric all_operations_acls %d\n", n, wild, all
            for (k in by) { split(k, x, SUBSEP); printf "metric acls %d resource=%s permission=%s\n", by[k], x[1], x[2] }
        }'
else
    [ "$?" = 2 ] && exit 0
    if grep -q 'SecurityDisabledException\|No Authorizer' "$work/err"; then
        echo 'metric authorizer 0'
    else
        echo "@JOB@: kafka-acls failed: $(why)" >&2
        exit 1
    fi
fi
run kafka-configs "${conn[@]}" --describe --entity-type users || exit 0
printf '%s\n' "$out" | awk '
    /^SCRAM credential configs for user-principal / { scram++ }
    /^Quota configs for user-principal / { q++ }
    END { printf "metric scram_users %d\nmetric quotas %d entity=user\n", scram, q }'
run kafka-configs "${conn[@]}" --describe --entity-type clients || exit 0
printf '%s\n' "$out" | awk '/^Quota configs for client-id / { q++ } END { printf "metric quotas %d entity=client\n", q }'
exit 0
