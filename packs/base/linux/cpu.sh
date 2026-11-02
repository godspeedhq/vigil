# cpu.sh - CPU use over one second, from /proc/stat.
sample() {
    local name user nice system idle wait irq softirq steal rest
    read -r name user nice system idle wait irq softirq steal rest < /proc/stat
    busy=$((user + nice + system + irq + softirq + ${steal:-0}))
    free=$((idle + wait))
}
sample
b1=$busy f1=$free
sleep 1
sample
total=$((busy - b1 + free - f1))
[ "$total" -gt 0 ] || total=1
echo "metric used_pct $((100 * (busy - b1) / total))"
