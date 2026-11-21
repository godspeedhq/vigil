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

# The brokers, as the cluster lists them.
brokers_list
rc=$?
if [ "$rc" = 2 ]; then echo 'metric up 0'; exit 0; fi
brokers=$out

# KRaft: the quorum names the cluster and its active controller. A cluster
# on ZooKeeper (Kafka 3) has no quorum to ask: its id comes from
# kafka-cluster.
kraft=yes cluster='' controller=''
if try kafka-metadata-quorum "${conn[@]}" describe --status; then
    cluster=$(printf '%s\n' "$out" | sed -n 's/^ClusterId: *//p')
    controller=$(printf '%s\n' "$out" | sed -n 's/^LeaderId: *//p')
else
    [ "$?" = 2 ] && { echo 'metric up 0'; exit 0; }
fi
if [ -z "$cluster" ]; then
    kraft=no
    run kafka-cluster cluster-id "${conn[@]}" || { echo 'metric up 0'; exit 0; }
    cluster=$(printf '%s\n' "$out" | sed -n 's/^Cluster ID: *//p')
fi

echo 'metric up 1'
echo "metric info 1 cluster_id=$(tagv "$cluster") kraft=$kraft"
printf '%s\n' "$brokers" | awk '
    / \(id: [0-9]+ rack: / { n++; if ($0 ~ /isFenced: true/) f++ }
    END { printf "metric brokers %d\nmetric brokers_fenced %d\n", n, f }'
[ -n "$controller" ] && [ "$controller" != -1 ] && echo "metric controller_id $controller"
exit 0
