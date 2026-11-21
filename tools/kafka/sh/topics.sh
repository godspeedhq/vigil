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

# Each topic's shape, from its description, and its offsets: the end of
# each partition (every message ever written to it, a running total) and
# its start (what retention has removed before it).
run kafka-topics "${conn[@]}" --describe || exit 0
printf '%s\n' "$out" | grep -q '^Topic: ' || no_topics
desc=$(printf '%s\n' "$out" | grep '^Topic: ')
run kafka-get-offsets "${conn[@]}" --time latest || exit 0
latest=$out
run kafka-get-offsets "${conn[@]}" --time earliest || exit 0
earliest=$out
{
    printf '%s\n' "$desc" | awk -F '\t' '
        function val(f,  i) { i = index(f, ": "); return i ? substr(f, i + 2) : "" }
        { t = val($1); rf = 0; pc = 0; c = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^PartitionCount: /) pc = val($i)
              else if ($i ~ /^ReplicationFactor: /) rf = val($i)
              else if ($i ~ /^Configs: / && $i ~ /cleanup\.policy=[a-z,]*compact/) c = 1
          }
          print "D", t, pc, rf, c }'
    # topic:partition:offset; a topic name holds no ":".
    printf '%s\n' "$latest" | awk -F ':' 'NF == 3 && $3 ~ /^[0-9]+$/ { print "L", $1, $3 }'
    printf '%s\n' "$earliest" | awk -F ':' 'NF == 3 && $3 ~ /^[0-9]+$/ { print "E", $1, $3 }'
} | awk '
    $1 == "D" { topics++; pc[$2] = $3; rf[$2] = $4
                if ($2 ~ /^__/) internal++; else if ($4 == 1) rf1++
                if ($5) compacted++; next }
    $1 == "L" { end[$2] += $3; next }
    $1 == "E" { start[$2] += $3 }
    END {
        printf "metric topics %d\nmetric internal_topics %d\nmetric rf1_topics %d\nmetric compacted_topics %d\n", topics, internal, rf1, compacted
        n = 0
        for (t in pc) {
            if (++n > 100) { hidden++; continue }
            printf "metric partitions %d topic=%s\nmetric replication_factor %d topic=%s\n", pc[t], t, rf[t], t
            printf "metric messages_count %.0f topic=%s\nmetric retained_messages %.0f topic=%s\n", end[t], t, end[t] - start[t], t
        }
        printf "metric topics_not_shown %d\n", hidden
    }'
exit 0
