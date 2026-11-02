# services.sh - launchd jobs that exited with an error and are not running.
launchctl list | awk 'NR > 1 && $1 == "-" && $2 != 0 { n++ } END { printf "metric failed %d\n", n }'
