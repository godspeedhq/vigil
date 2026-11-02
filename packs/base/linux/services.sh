# services.sh - failed systemd units. A host without systemd reports nothing.
command -v systemctl > /dev/null 2>&1 || exit 0
n=$(systemctl --failed --no-legend --plain 2> /dev/null | wc -l)
echo "metric failed $((n + 0))"
