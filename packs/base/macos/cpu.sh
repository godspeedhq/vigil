# cpu.sh - CPU use over one second, from top. The second sample is the real one.
top -l 2 -n 0 -s 1 |
    awk '/^CPU usage/ { idle = $7 + 0 } END { printf "metric used_pct %d\n", 100 - idle }'
