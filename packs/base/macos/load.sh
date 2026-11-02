# load.sh - the load averages.
sysctl -n vm.loadavg |
    awk '{ print "metric load1", $2; print "metric load5", $3; print "metric load15", $4 }'
